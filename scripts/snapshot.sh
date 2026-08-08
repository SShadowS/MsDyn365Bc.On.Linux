#!/usr/bin/env bash
# Boot BC from a CRIU checkpoint instead of starting the service tier.
#
# OPT-IN PER MACHINE. Inert unless the operator has set this machine up (see
# "opt-in is a property of the MACHINE" below); no pipeline change enables or
# disables it. Where it is on, a hit replaces a ~135s cold boot with a ~47s
# restore, and a miss boots normally and leaves a snapshot behind for next time.
#
# WHAT A SNAPSHOT IS
# ------------------
# Two files that are only valid TOGETHER:
#
#   checkpoint/          the frozen NST process image (~2.1 GB)
#   cronus.bak           the database it was booted against (~540 MB)
#   bc-snapshot:<key>    a docker image holding the container read-write layer,
#                        because criu re-opens files by path and some of them
#                        (the /tmp/bc-stdin FIFO NST holds as stdin) are not in
#                        any volume
#
# Neither restores on its own. The checkpoint holds a process whose memory
# refers to that database's schema, its published-app metadata and its license;
# hand it a different database and you get a BC that looks alive and is wrong.
# They are written and read as a pair, under one key, and the key is the whole
# safety story — see docs/SNAPSHOT.md for what it covers and why.
#
# WHERE THIS IS WORTH USING
# -------------------------
# Self-hosted runners and dev boxes, i.e. anywhere the store is a directory that
# survives between runs. On a GitHub-hosted runner it is a pessimisation: the
# 2.6 GB would have to travel through the Actions cache on every job, which is
# the artifact-caching ban in CLAUDE.md verbatim, and creating the snapshot
# costs more than the boot it saves. The store being empty is not a failure —
# it just boots normally.
#
# SAFETY MODEL
# ------------
# A stale or unusable snapshot must never produce a subtly wrong BC. So:
#   - the key must match exactly, or it is a miss;
#   - a restore is verified (OData 200) before being accepted;
#   - any failure tears the attempt down, discards the snapshot, and returns
#     non-zero so the caller cold-boots.
# There is no path where a failed restore leaves a half-restored BC running.
set -euo pipefail

STAMP_NAME=".bc-snapshot-stamp"

log()  { echo "[snapshot] $*" >&2; }
die()  { echo "[snapshot] ERROR: $*" >&2; exit 1; }

# ─── opt-in is a property of the MACHINE, not of the pipeline ─────────────────
#
# A pipeline should not have to know whether the runner it landed on can do
# this. The operator sets a machine up once and every pipeline that runs there
# benefits; on a GitHub-hosted runner nothing is set up, so every command here
# turns into "disabled" and the caller cold-boots exactly as before.
#
# Two ways to enable a machine, checked in order:
#
#   1. BC_SNAPSHOT_DIR in the environment. On an Actions runner put it in
#      actions-runner/.env, which applies to every job the runner takes.
#   2. One of the well-known directories below EXISTS. Creating it is the
#      opt-in:  sudo install -d -o "$(id -u)" -m 755 /var/cache/bc-linux/snapshots
#
# Presence rather than a config flag, because the directory has to exist and be
# writable for the feature to work at all — so anything else would be a second
# source of truth that can disagree with the first.
SNAPSHOT_DIR_DEFAULTS="/var/cache/bc-linux/snapshots ${HOME:-/root}/.cache/bc-linux/snapshots"

_resolve_store_root() {
  if [ -n "${BC_SNAPSHOT_DIR:-}" ]; then
    mkdir -p "$BC_SNAPSHOT_DIR" 2>/dev/null || return 1
    [ -w "$BC_SNAPSHOT_DIR" ] || return 1
    echo "$BC_SNAPSHOT_DIR"; return 0
  fi
  local d
  for d in $SNAPSHOT_DIR_DEFAULTS; do
    # Deliberately NOT created here: an existing directory is the operator's
    # opt-in, and creating it would opt every machine in silently.
    [ -d "$d" ] && [ -w "$d" ] && { echo "$d"; return 0; }
  done
  return 1
}

# ─── key ──────────────────────────────────────────────────────────────────────
#
# Every component is here because changing it makes the checkpoint WRONG, not
# merely stale. Read docs/SNAPSHOT.md before adding or removing one.
_compose_json() { docker compose config --format json 2>/dev/null; }

_project_name() {
  _compose_json | python3 -c 'import sys,json;print(json.load(sys.stdin).get("name",""))'
}

_bc_image_ref() {
  _compose_json | python3 -c 'import sys,json;print(json.load(sys.stdin)["services"]["bc"].get("image",""))'
}

_bc_image_id() {
  local ref id; ref=$(_bc_image_ref)
  [ -n "$ref" ] || { echo "unknown"; return; }
  # `docker image inspect --format` prints an empty LINE and then fails when the
  # image is not present locally, so `... || echo absent` yields "\nabsent" and
  # the key grows a blank component. Check the value, not the exit code.
  id=$(docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null | head -1) || true
  [ -n "$id" ] && echo "$id" || echo "absent"
}

# The artifact half comes from download-artifacts.sh's own stamp, which records
# the RESOLVED urls rather than the requested version. That is deliberate and it
# is the single biggest lever a user has over hit rate: ask for "28.1" and
# Microsoft's newest hotfix under that prefix changes the url several times a
# day, so the key moves with it; pin a full version and the key stops moving.
_artifact_key() {
  local dir="${BC_ARTIFACTS_DIR:-}"
  # Returns non-zero rather than calling die(): this runs inside a command
  # substitution, where an exit would only kill the subshell and leave the
  # caller printing a key with one component silently blank. Callers check.
  [ -n "$dir" ] && [ -f "$dir/.bc-artifact-cache" ] || return 1
  local k; k=$(sed -n 's|^key=||p' "$dir/.bc-artifact-cache" | head -1)
  [ -n "$k" ] || return 1
  printf '%s' "$k"
}

_no_artifact_key_msg() {
  cat <<'MSG'
BC_ARTIFACTS_DIR must point at a host directory already populated by
scripts/download-artifacts.sh — its .bc-artifact-cache stamp is where the
RESOLVED artifact urls come from.

Snapshot mode cannot key on a named volume, and it deliberately does not key on
the version you REQUESTED: ask for "28.1" and Microsoft's newest hotfix under
that prefix moves the url several times a day, so keying on the request would
let a checkpoint built from different binaries be reused silently.
MSG
}

# How bc is launched: image ref, environment, ports, volumes, network mode. NST
# holds the resolved values in memory and keeps using them after a restore
# whatever the environment says then — point a restored checkpoint at a
# different SQL host or a different database user and it will carry on talking
# to the old one.
#
# Taken from compose's own resolved config rather than from this shell's
# environment, so it reflects what bc will ACTUALLY get, including anything an
# overlay changes.
#
# Two kinds of thing are removed, both because they are keyed better elsewhere
# and hashing them twice only costs hit rate:
#   build      describes how the image would be produced; the image itself is
#              keyed by digest.
#   the app    BC_KEEP_APP_IDS is a comma list whose ORDER is not meaningful, so
#   variables  hashing it raw made "aaa,bbb" and "bbb,aaa" different keys for an
#              identical snapshot. apps= carries them sorted and deduped.
#   volume    the HOST side of every mount is normalised away, keeping the
#   sources   target and mode. What the checkpoint depends on is what BC sees
#             at /bc/artifacts, not which directory on this machine was mounted
#             there — and the artifact CONTENTS are keyed by artifact=, the
#             license by license=, and the service volume is checked against its
#             own stamp at restore time. Without this, two repositories on one
#             runner get different keys purely because each passes its own
#             ${{ github.workspace }}/artifact-cache, and each rebuilds a 2.6 GB
#             snapshot the other could have used.
_config_fp() {
  _compose_json | python3 -c '
import sys, json, hashlib
bc = json.load(sys.stdin)["services"]["bc"]
bc.pop("build", None)
for k in ("BC_KEEP_APP_IDS", "BC_CLEAR_ALL_APPS", "BC_TEST_APPS"):
    bc.get("environment", {}).pop(k, None)
for v in bc.get("volumes", []):
    if isinstance(v, dict):
        v["source"] = "<host>"
print(hashlib.sha256(json.dumps(bc, sort_keys=True).encode()).hexdigest()[:16])'
}

# The license is imported into the database before NST starts and NST caches it,
# so a different license is a different checkpoint. Hashed, never stored.
_license_fp() {
  local f="${BC_LICENSE_HOST_PATH:-}"
  if [ -n "$f" ] && [ -f "$f" ]; then sha256sum "$f" | cut -c1-16; else echo "artifact-default"; fi
}

# The app set the snapshot was taken with. BC_KEEP_APP_IDS is the consumer's
# transitive dependency closure, so it changes when dependencies change and NOT
# on every commit — which is exactly what makes this cacheable at all.
_apps_fp() {
  local ids; ids=$(printf '%s' "${BC_KEEP_APP_IDS:-}" | tr ',' '\n' | tr -d ' ' | sort -u | paste -sd, -)
  local ta="none"
  # BC_TEST_APPS bakes the named apps INTO the snapshot, so their contents have
  # to be part of the key. That makes the key move on every rebuild of those
  # apps. Publish your own apps after restore instead — see docs/SNAPSHOT.md.
  if [ -n "${BC_TEST_APPS:-}" ]; then
    ta=$(printf '%s' "$BC_TEST_APPS" | tr ',' '\n' | while read -r p; do
           [ -f "$p" ] && sha256sum "$p" || echo "missing:$p"
         done | sort | sha256sum | cut -c1-16)
  fi
  printf '%s|%s|%s' "${BC_CLEAR_ALL_APPS:-false}" "${ids:-none}" "$ta" | sha256sum | cut -c1-16
}

# criu's image format is version-coupled, and a checkpoint carries the CPU
# feature set it was taken with — restoring on a machine that lacks one fails.
# Architecture is in the key; CPU heterogeneity within an arch is documented as
# a restore-time failure that falls back to a cold boot, because encoding a cpu
# model would fragment the store on machines where restore would have worked.
_runtime_fp() {
  printf '%s|%s' "$(criu --version 2>/dev/null | head -1 | tr -d ' ')" "$(uname -m)"
}

snapshot_key_long() {
  local art
  art=$(_artifact_key) || { _no_artifact_key_msg >&2; return 1; }
  printf 'v1
artifact=%s
image=%s
apps=%s
config=%s
license=%s
runtime=%s
' "$art" "$(_bc_image_id)" "$(_apps_fp)" "$(_config_fp)" "$(_license_fp)" "$(_runtime_fp)"
}

snapshot_key() {
  local long; long=$(snapshot_key_long) || return 1
  printf '%s' "$long" | sha256sum | cut -c1-32
}

_store() {
  local root; root=$(_resolve_store_root) || return 1
  local k; k=$(snapshot_key) || return 1
  echo "${root%/}/$k"
}

# ─── preflight ────────────────────────────────────────────────────────────────
#
# Reasons this host cannot do checkpoint/restore at all. Each one was a failed
# probe run; see PERFORMANCE-IDEAS.md for which.
preflight() {
  local ok=0
  command -v criu >/dev/null || { log "criu not installed"; ok=1; }
  if command -v criu >/dev/null; then
    local v; v=$(criu --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    # 3.17 dumps BC cleanly and segfaults the restored task. Three probe runs
    # went into theories about BC for a failure that was entirely criu's age.
    [ -n "$v" ] && [ "$(printf '%s\n4.2.1\n' "$v" | sort -V | head -1)" = "4.2.1" ] \
      || { log "criu $v is too old — 4.2.1 or newer is required (3.17 restores into a SIGSEGV)"; ok=1; }
  fi
  [ "$(docker info --format '{{.ExperimentalBuild}}' 2>/dev/null)" = "true" ] \
    || { log "dockerd is not in experimental mode — needs {\"experimental\": true} in /etc/docker/daemon.json"; ok=1; }
  # Docker cannot rebuild a bridge netns on restore (it bind-mounts
  # /proc/<init-pid>/ns/net, and on restore that pid is 0), so bc must be on
  # host networking. docker-compose.snapshot.yml is what sets that.
  _compose_json | python3 -c '
import sys,json
bc=json.load(sys.stdin)["services"]["bc"]
sys.exit(0 if bc.get("network_mode")=="host" else 1)' 2>/dev/null \
    || { log "bc is not on host networking — add -f docker-compose.snapshot.yml"; ok=1; }
  [ "$ok" = 0 ] && log "preflight ok (criu $(criu --version 2>/dev/null | head -1))"
  return $ok
}

# Machine configuration is NOT this script's job. It used to sysctl and write
# /etc/criu/runc.conf on every run, which is why the whole feature appeared to
# need root: one-time host setup had been smuggled into the per-run path.
# scripts/setup-snapshot-host.sh writes both, persistently. Here we only CHECK.
_verify_host_config() {
  local bad=0
  # NST's VmSize is ~263 GB of GC reservations. Heuristic overcommit refuses to
  # recreate that many mappings and the default 65530 map cap is far too low;
  # both surface as ENOMEM during restore, naming nothing about memory policy.
  [ "$(cat /proc/sys/vm/overcommit_memory)" = "1" ] \
    || { log "vm.overcommit_memory is $(cat /proc/sys/vm/overcommit_memory), needs 1"; bad=1; }
  [ "$(cat /proc/sys/vm/max_map_count)" -ge 1048576 ] \
    || { log "vm.max_map_count is $(cat /proc/sys/vm/max_map_count), needs >= 1048576"; bad=1; }
  # runc reads this; `docker checkpoint create` exposes no flag for any of it.
  grep -q '^tcp-established' /etc/criu/runc.conf 2>/dev/null \
    || { log "/etc/criu/runc.conf missing or lacks tcp-established"; bad=1; }
  [ "$bad" = 0 ] || { log "run scripts/setup-snapshot-host.sh once on this machine"; return 1; }
  # Ours to create, as ourselves. criu runs as root and writes its log here with
  # a default umask, so it stays readable without privilege. /var/tmp rather
  # than /tmp because /tmp is a ramdisk on many distros.
  mkdir -p /var/tmp/criu-work 2>/dev/null && chmod 777 /var/tmp/criu-work 2>/dev/null || true
  # A stale runc.conf still naming /tmp would send criu's scratch back into RAM.
  grep -q 'work-dir /var/tmp/criu-work' /etc/criu/runc.conf 2>/dev/null \
    || log "NOTE: /etc/criu/runc.conf does not point work-dir at /var/tmp/criu-work — re-run scripts/setup-snapshot-host.sh"
  return 0
}

# ── files the docker DAEMON owns ─────────────────────────────────────────────
#
# The checkpoint lands under <docker-root>/containers/<id>/checkpoints as
# root:700, and no amount of tidying changes that. But this user already talks
# to the docker socket — which is root-equivalent by construction — so the copy
# can go through THAT authority instead of sudo. The bc image is used because it
# is certainly present and has GNU cp, so --reflink still applies.
# Print a root-owned file we have no sudo for. Same authority as the checkpoint
# copies. Run 10's dump log sat at a containerd path readable only by root, and
# a bare `[ -r ]` test skipped it without a word — so the failure reported
# "(no /var/tmp/criu-work/criu.log)" and stopped there.
_root_read() {
  local dir base; dir=$(dirname "$1"); base=$(basename "$1")
  [ -d "$dir" ] || return 1
  docker run --rm -v "$dir":/r:ro --entrypoint sh "$(_bc_image_ref)" -c \
    "cat '/r/$base'" 2>/dev/null
}

# containerd stages every `docker checkpoint create` in /tmp/ctrd-checkpoint<rand>
# and does NOT remove it afterwards. Each one holds a full copy of the
# checkpoint (~2.1 GB), and on a distro where /tmp is a tmpfs they accumulate in
# RAM: seven of them were found after this benchmark series, roughly 15 GB, on a
# machine whose tmpfs is about that size. Moving our OWN staging to /var/tmp did
# nothing about these, because containerd picks the path from the daemon's
# TMPDIR, not ours.
#
# They are root-owned, so reap them through the docker socket. The glob is
# anchored to containerd's own prefix; a no-match leaves the literal string,
# which rm -rf ignores.
_reap_ctrd_staging() {
  local dir="${TMPDIR:-/tmp}"
  docker run --rm -v "$dir":/t --entrypoint sh "$(_bc_image_ref)" -c \
    'for d in /t/ctrd-checkpoint*; do case "$d" in */ctrd-checkpoint\*) ;; *) rm -rf "$d";; esac; done' \
    >/dev/null 2>&1 || true
}

_export_checkpoint() {  # <container-id> <dest-dir>   result is owned by us
  docker run --rm -v "$(_ckpt_path "$1")":/src:ro -v "$2":/dst \
    --entrypoint sh "$(_bc_image_ref)" -c \
    "cp -a --reflink=auto /src/cp1 /dst/cp1 && chown -R $(id -u):$(id -g) /dst/cp1"
}

_import_checkpoint() {  # <store-checkpoint-dir> <container-id>
  docker run --rm -v "$1":/src:ro -v "$(dirname "$(_ckpt_path "$2")")":/dst \
    --entrypoint sh "$(_bc_image_ref)" -c \
    "mkdir -p /dst/checkpoints && rm -rf /dst/checkpoints/cp1 && cp -a --reflink=auto /src/cp1 /dst/checkpoints/cp1"
}

# -b is load-bearing: WITHOUT it sqlcmd exits 0 even when the T-SQL fails. The
# first end-to-end run had BACKUP DATABASE fail on a permission error, return
# success, and the problem only surfaced two lines later as "cp: cannot stat".
# A silently-failed RESTORE would have been far worse than a noisy one.
_sqlcmd() { docker compose exec -T sql /opt/mssql-tools18/bin/sqlcmd -b -S localhost -U sa -P "${SA_PASSWORD:-Passw0rd123!}" -C -No "$@"; }

# The bind-mount source docker creates for /sqlsnap is owned by root and mode
# 755, and SQL Server runs as uid 10001 — so BACKUP TO DISK lands on EACCES
# unless the directory is prepared first. Same reasoning as the chmod 644 on the
# staged ISV license (CLAUDE.md).
# Armed by create() the moment the checkpoint stops bc. Anything that fails from
# there on would otherwise leave the caller with no BC at all, plus a
# half-written snapshot that the next run would treat as a hit.
_create_failed() {
  local rc=$?
  trap - EXIT
  [ "$rc" -eq 0 ] && return 0
  log "create failed — discarding the partial snapshot and bringing bc back"
  [ -n "${CREATE_STORE:-}" ] && _rm_store "$CREATE_STORE"
  # The stamp may not exist yet, so _rm_store cannot have found the image name.
  docker image rm -f "bc-snapshot:$(snapshot_key 2>/dev/null || echo none)" >/dev/null 2>&1 || true
  _reap_ctrd_staging
  docker compose up -d --wait >/dev/null 2>&1 || true
  return "$rc"
}

_prepare_sqldir() {
  local d="${BC_SNAPSHOT_SQLDIR:-/var/tmp/bc-sqlstage}"
  # SQL Server writes the backup here as uid 10001, so it has to be
  # world-writable. Creating it ourselves before docker ever mounts it is the
  # normal path; but a directory left root-owned by an earlier run (docker
  # auto-creates a missing bind-mount source as root) cannot be chmod'd by us.
  # Repair it through the docker socket rather than reaching for sudo — same
  # authority the checkpoint copies use.
  local base; base=$(basename "$d")
  mkdir -p "$d" 2>/dev/null || true
  chmod 777 "$d" 2>/dev/null || true
  if [ ! -d "$d" ] || [ ! -w "$d" ] || ! stat -c '%a' "$d" 2>/dev/null | grep -q '7$'; then
    [ -n "$base" ] && [ "$base" != "." ] && [ "$base" != "/" ] \
      || die "refusing to repair a suspicious staging path: $d"
    log "repairing $d (owner $(stat -c %U "$d" 2>/dev/null || echo unknown)) via the docker socket"
    # IN PLACE. Recreating the directory (rm -rf + mkdir) detaches any running
    # container's bind mount: sql keeps the old, now-unlinked inode and its
    # writes land in a directory nothing else can see. Fixing the mode on the
    # existing inode leaves every mount intact.
    docker run --rm -v "$d":/s --entrypoint sh "$(_bc_image_ref)" -c \
      "chmod 777 /s && chown $(id -u):$(id -g) /s" >/dev/null 2>&1 || true
  fi
  [ -w "$d" ] || die "cannot write $d — remove it and retry: sudo rm -rf $d"
  # SQL Server wrote the previous backup as uid 10001 mode 640. cp TRUNCATES an
  # existing file, which needs write permission on the FILE — a 777 directory
  # does not help. Remove it first; unlink only needs the directory.
  rm -f "$d/cronus.bak" 2>/dev/null || true
}

# The store is ours: _export_checkpoint chowns the copied checkpoint to the
# invoking user, so deleting and sizing it need no privilege. (Stores written
# before that change hold a root-owned checkpoint and must be removed by hand;
# the message below says so rather than silently reaching for sudo.)
# The store is only half of a snapshot; the other half is the committed rootfs
# image. Dropping one without the other leaves either a snapshot that cannot
# restore or an image nothing will ever use, so they go together.
_rm_store() {
  [ -n "${1:-}" ] || return 0
  # The stamp is usually absent here — _rm_store's whole job is clearing a store
  # that is missing, partial, or being rebuilt. `sed` exits 2 on an unreadable
  # file, and under `set -e` an assignment from a command substitution carries
  # that status straight out of the script: run 7 died at exit 2 with no message
  # before it ever reached the checkpoint. Guard the read, do not silence it.
  local img=""
  [ -f "$1/$STAMP_NAME" ] && img=$(sed -n 's|^rootfs_image=||p' "$1/$STAMP_NAME" | head -1)
  [ -n "$img" ] && docker image rm -f "$img" >/dev/null 2>&1 || true
  rm -rf "${1:?}" 2>/dev/null || log "could not remove $1 — if it predates the sudo-free rewrite it may be root-owned; remove it by hand"
}
_du_store() { du -sh "$1" 2>/dev/null | cut -f1 || echo "?"; }

# Returns the HTTP code, or 000. Any error text goes to a file rather than
# /dev/null, because "000" on its own has now twice been the only thing a
# failure said for itself.
_bc_odata() {
  local code
  code=$(docker compose exec -T bc curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -u BCRUNNER:Admin123! http://localhost:7048/BC/ODataV4/Company 2>/tmp/snapshot-odata.err) || true
  printf '%s' "${code:-000}"
}

# Everything known about why BC is not answering. Called wherever a non-200
# would otherwise be reported as a bare number.
_odata_diagnosis() {
  log "  docker compose exec stderr: $(head -c 300 /tmp/snapshot-odata.err 2>/dev/null | tr '\n' ' ')"
  log "  bc container: $(docker compose ps --format '{{.Name}} {{.State}} {{.Health}}' bc 2>/dev/null | head -1)"
  log "  host port 7048: $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -u BCRUNNER:Admin123! http://localhost:7048/BC/ODataV4/Company 2>/dev/null || echo unreachable)"
  log "  --- bc log tail ---"
  docker compose logs bc --tail 12 2>&1 | cut -c1-160 >&2 || true
}

# ─── docker will not restore from a custom checkpoint directory ───────────────
#
# `docker checkpoint create --checkpoint-dir` is accepted, but the matching
# `docker start --checkpoint-dir` is NOT: the daemon answers
#
#   Error response from daemon: custom checkpointdir is not supported
#
# so a checkpoint written straight into the store can never be restored from
# there. The flag exists on the CLI and is unimplemented in the daemon's start
# path; it is not a criu limitation and no criu option changes it.
#
# The way through is to let docker keep the checkpoint where it expects —
# <docker-root>/containers/<cid>/checkpoints/<name> — and move it in and out of
# the store ourselves. Restore copies it into the NEW container's directory,
# which is a different path because it is a different container id.
_docker_root() { docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker; }
_ckpt_path()   { echo "$(_docker_root)/containers/$1/checkpoints"; }

# A snapshot needs ~3 GB in the store and room for criu's scratch. Running out
# does NOT announce itself: across runs 7-11 it appeared as a failed restore, a
# bare "criu failed: type DUMP", a missing criu log, and "bc is not serving
# OData" whose real text was "write /tmp/runc-process...: no space left on
# device". Check first and say so plainly.
_check_space() {
  local ok=0 store dockroot sqldir
  store=$(_resolve_store_root 2>/dev/null || echo /var/tmp)
  dockroot=$(_docker_root)
  sqldir="${BC_SNAPSHOT_SQLDIR:-/var/tmp/bc-sqlstage}"
  # Nothing of ours should sit on a tmpfs: it is RAM, and a 540 MB backup plus
  # criu scratch will exhaust it long before the disk.
  local d
  for d in "$store" "$sqldir" /var/tmp/criu-work; do
    [ -d "$d" ] || continue
    [ "$(stat -f -c %T "$d" 2>/dev/null)" = tmpfs ] \
      && log "WARNING: $d is on tmpfs (RAM). Set BC_SNAPSHOT_SQLDIR to a disk-backed path."
  done
  local where
  for where in "$store" "$sqldir" "$dockroot"; do
    [ -d "$where" ] || continue
    local free_mb; free_mb=$(df -Pm "$where" 2>/dev/null | awk 'NR==2{print $4}')
    [ -n "$free_mb" ] || continue
    if [ "$free_mb" -lt 4096 ]; then
      log "only $((free_mb/1024)) GB free on $where (need ~4 GB) — $(df -Ph "$where" | awk 'NR==2{print $1" "$5" used"}')"
      ok=1
    fi
  done
  [ "$ok" = 0 ] || log "free space: $(df -Ph "$store" /tmp 2>/dev/null | awk 'NR>1{printf "%s=%s free  ", $6, $4}')"
  return $ok
}

# ─── status ───────────────────────────────────────────────────────────────────
status() {
  local root
  if ! root=$(_resolve_store_root); then
    echo "disabled (this machine is not set up for snapshots — see docs/SNAPSHOT.md)"
    return 1
  fi
  local s
  # A key that cannot be computed is a miss, not an error: the caller's next
  # move is a cold boot either way, and snapshot mode must never be the reason
  # a build fails.
  s=$(_store 2>/dev/null) || { echo "unavailable (cannot compute a key — run 'key' to see why)"; return 1; }
  if [ "${BC_SNAPSHOT_REFRESH:-}" = "1" ]; then echo "refresh forced $s"; return 1; fi
  # The stamp is written LAST by create(), so its presence is what distinguishes
  # a complete pair from one interrupted halfway. A torn snapshot is a miss.
  if [ -f "$s/$STAMP_NAME" ] && [ -s "$s/cronus.bak" ] && [ -d "$s/checkpoint/cp1" ]; then
    echo "hit $s"; return 0
  fi
  echo "miss $s"; return 1
}

# ─── create ───────────────────────────────────────────────────────────────────
#
# Call this against a BC that is healthy and has NOT yet had the consumer's own
# apps published — the point of the boot where the state is still generic.
create() {
  _resolve_store_root >/dev/null || die "this machine is not set up for snapshots — see docs/SNAPSHOT.md"
  preflight || die "host cannot checkpoint (see above)"
  _verify_host_config || die "host configuration incomplete"
  local s cid t0
  s=$(_store) || die "cannot compute a snapshot key (run: scripts/snapshot.sh key)"
  cid=$(docker compose ps -q bc || true)
  [ -n "$cid" ] || die "no running bc container"
  _check_space || die "not enough free space to take a snapshot"
  local odata; odata=$(_bc_odata)
  if [ "$odata" != "200" ]; then
    log "bc is not serving OData (HTTP $odata) — refusing to snapshot an unhealthy BC"
    # The caller's own readiness probe had just passed against the same URL on
    # the host, so the disagreement itself is the clue: a different container
    # answering the host port, or exec failing rather than curl.
    _odata_diagnosis
    die "bc not healthy at snapshot time"
  fi

  _rm_store "$s"; mkdir -p "$s/checkpoint"
  CREATE_STORE="$s"
  # From the checkpoint onwards bc is STOPPED, so every later failure has to put
  # it back. Without this a backup error leaves the caller with no BC at all and
  # a half-written snapshot that would be picked up as a hit next run.
  trap _create_failed EXIT
  t0=$(date +%s)
  # --leave-running=false: the process must really stop, otherwise the backup
  # below races a BC that is still writing and the two halves disagree.
  # The daemon's own message says only "criu failed: type DUMP" and names a log
  # path. THAT file has the reason, and create() was the last place in this
  # script still not printing it — restore() has done so since the segfault
  # hunt. runc.conf pins work-dir to /var/tmp/criu-work, so the log is there;
  # containerd's task dir is checked too because the daemon quotes that path.
  if ! docker checkpoint create --leave-running=false "$cid" cp1 2>/tmp/snapshot-dump.err; then
    _reap_ctrd_staging
    log "docker checkpoint create failed:"
    sed -n 1,3p /tmp/snapshot-dump.err >&2
    log "--- criu dump log ---"
    # Two candidate locations, and the containerd one needs the docker socket to
    # read. runc.conf pins work-dir to /var/tmp/criu-work, but run 10 found nothing
    # there while the daemon pointed at containerd's copy -- which suggests
    # runc.conf may not have been honoured at all, and that would ALSO mean
    # tcp-established was not applied, which is exactly what makes a BC dump
    # fail. Print whichever exists.
    local dumped=0
    if [ -s /var/tmp/criu-work/criu.log ]; then
      log "(from /var/tmp/criu-work/criu.log)"
      { grep -hE "Error \(|Warn \(" /var/tmp/criu-work/criu.log || tail -20 /var/tmp/criu-work/criu.log; } \
        | tail -20 >&2; dumped=1
    fi
    local tasklog="/run/containerd/io.containerd.runtime.v2.task/moby/$cid/criu-dump.log"
    local tl; tl=$(_root_read "$tasklog" || true)
    if [ -n "$tl" ]; then
      log "(from $tasklog)"
      printf '%s\n' "$tl" | grep -E "Error \(|Warn \(" | tail -20 >&2 \
        || printf '%s\n' "$tl" | tail -20 >&2
      dumped=1
      # If criu logged HERE rather than in the configured work-dir, runc did not
      # apply /etc/criu/runc.conf, and none of its options -- tcp-established
      # above all -- reached this dump.
      [ -s /var/tmp/criu-work/criu.log ] || \
        log "NOTE: criu did not use the work-dir from /etc/criu/runc.conf, so its options may not have applied either"
    fi
    [ "$dumped" = 1 ] || log "(no criu log found in either location)"
    die "checkpoint failed — see the criu log above"
  fi
  [ "$(docker inspect --format '{{.State.Status}}' "$cid")" = "exited" ] \
    || die "bc still running after checkpoint — nothing was captured"
  log "checkpoint written in $(( $(date +%s) - t0 ))s"
  # Reap before the copy, so the peak is one staged copy rather than two.
  _reap_ctrd_staging
  # Copied rather than written in place; see _ckpt_path above for why. The
  # daemon writes it root:700, so the copy goes through a container on the
  # docker socket -- authority this caller already has -- instead of sudo.
  # --reflink=auto: a copy-on-write clone on btrfs/XFS (near-instant, no extra
  # space) and an ordinary copy everywhere else. The two 2.1 GB copies are the
  # largest single component of restore time on a fast disk, so this is worth
  # the one word even though it is a no-op on ext4.
  _export_checkpoint "$cid" "$s/checkpoint"
  [ -d "$s/checkpoint/cp1" ] || die "checkpoint did not copy into the store"

  # The checkpoint is only half of what the process needs: criu references open
  # files by PATH and re-opens them on restore, and some of those live in the
  # container's read-write layer rather than in a volume. The entrypoint's
  # /tmp/bc-stdin FIFO is one — NST holds it as stdin and the entrypoint keeps
  # fd 3 on it — so restoring into a freshly created container failed with
  #
  #   Can't open fake fifo [tmp/bc-stdin]: No such file or directory
  #
  # Committing the stopped container captures that layer, and restore creates
  # its container from the commit instead of from the bc-runner image. This is
  # general: it also covers /tmp/bc-ready and anything else BC wrote outside a
  # volume, rather than enumerating files we happen to know about.
  local img prev
  img="bc-snapshot:$(snapshot_key)"
  # Committing over an existing tag leaves the PREVIOUS image dangling, and
  # nothing was reaping it: eleven benchmark runs left eleven multi-GB orphans.
  prev=$(docker image inspect --format '{{.Id}}' "$img" 2>/dev/null | head -1) || true
  docker commit "$cid" "$img" >/dev/null
  if [ -n "${prev:-}" ] && [ "$prev" != "$(docker image inspect --format '{{.Id}}' "$img" 2>/dev/null | head -1)" ]; then
    docker image rm -f "$prev" >/dev/null 2>&1 || true
  fi
  log "rootfs committed as $img"

  # AFTER the checkpoint, so the database matches the frozen process exactly.
  _prepare_sqldir
  # NOT >/dev/null: sqlcmd reports T-SQL errors on stdout, so discarding it
  # throws away the only explanation of a failed backup. -b makes the exit code
  # meaningful; this makes the reason visible.
  local bkout
  if ! bkout=$(_sqlcmd -Q "BACKUP DATABASE [CRONUS] TO DISK='/sqlsnap/cronus.bak' WITH COPY_ONLY, INIT, COMPRESSION" 2>&1); then
    log "BACKUP DATABASE failed:"; echo "$bkout" | tail -6 >&2
    die "could not back up the database"
  fi
  # Streamed out through the container rather than copied on the host: SQL
  # writes the backup as uid 10001 mode 640, which the runner user cannot read.
  docker compose exec -T sql cat /sqlsnap/cronus.bak > "$s/cronus.bak"
  [ -s "$s/cronus.bak" ] || die "database backup came out empty"

  # Written last: the stamp is what makes the pair readable, so it must not
  # exist until both halves are on disk. A torn snapshot is a miss, not a
  # half-hit.
  { snapshot_key_long
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "service_stamp=$(_service_volume_stamp)"
    echo "rootfs_image=$img"
  } > "$s/$STAMP_NAME"
  log "snapshot stored in $s ($(_du_store "$s"))"

  # --leave-running=false left bc STOPPED, and `docker compose start bc` would
  # run the entrypoint and cold-boot it all over again. Resume from the
  # checkpoint we just took instead: the caller asked for a snapshot, not for
  # their BC to be taken away.
  if docker start --checkpoint cp1 "$cid" 2>/tmp/snapshot-resume.err; then
    _mark_ready
    log "bc resumed from the checkpoint it just wrote"
  else
    # Never swallow this. A resume that fails silently looks identical to one
    # that was never attempted, and it is the same code path restore() uses --
    # so whatever breaks here breaks the feature, not just this convenience.
    log "could not resume from the fresh checkpoint — cold booting so the caller is not left without a BC"
    sed -n 1,5p /tmp/snapshot-resume.err >&2 || true
    grep -E "Error \\(|killed by signal" /var/tmp/criu-work/criu.log 2>/dev/null | tail -5 >&2 || true
    docker compose up -d --wait
  fi
  trap - EXIT
}

# The healthcheck tests for /tmp/bc-ready, which the entrypoint writes — and the
# entrypoint does not run on a resumed process. On a container that was
# recreated it is missing entirely, so docker would report the container
# unhealthy forever while BC serves perfectly. Everything downstream
# (wait-for-bc-healthy.sh, compose --wait) keys off that healthcheck.
_mark_ready() { docker compose exec -T bc touch /tmp/bc-ready 2>/dev/null || true; }

# /bc/service is a VOLUME, and criu references mapped files by path — the
# restored NST re-opens the same DLLs. So the volume has to be present and
# patched by the same image. `docker compose down -v` destroys it and
# invalidates every snapshot on the host.
_service_volume_stamp() {
  local vol; vol="$(_project_name)_bc-service"
  docker run --rm -v "$vol:/s" --entrypoint cat "$(_bc_image_ref)" /s/.bc-service-stamp 2>/dev/null || echo "absent"
}

# ─── restore ──────────────────────────────────────────────────────────────────
restore() {
  local s; s=$(_store) || die "cannot compute a snapshot key (run: scripts/snapshot.sh key)"
  status >/dev/null || { log "no snapshot for this key — cold boot"; log "  key: $s"; return 1; }
  preflight || { log "host cannot restore — cold boot"; return 1; }

  local want have
  want=$(sed -n 's|^service_stamp=||p' "$s/$STAMP_NAME" 2>/dev/null | head -1 || true)
  have=$(_service_volume_stamp)
  if [ "$want" != "$have" ]; then
    log "the bc-service volume does not match this snapshot — cold boot"
    log "  snapshot: $want"
    log "  volume:   $have"
    log "  (docker compose down -v destroys this volume and invalidates snapshots)"
    return 1
  fi

  _verify_host_config || return 1
  local t0; t0=$(date +%s)

  # SQL first: the restored NST wakes holding a connection pool whose peer is
  # gone, and reconnects on first use — but only if there is something to
  # reconnect TO, with the database it expects.
  _prepare_sqldir
  cp "$s/cronus.bak" "${BC_SNAPSHOT_SQLDIR:-/var/tmp/bc-sqlstage}/cronus.bak"
  chmod 644 "${BC_SNAPSHOT_SQLDIR:-/var/tmp/bc-sqlstage}/cronus.bak"
  docker compose up -d sql
  local i
  for i in $(seq 1 90); do
    [ "$(docker compose ps --format '{{.Health}}' sql 2>/dev/null)" = healthy ] && break
    sleep 2
  done
  [ "$(docker compose ps --format '{{.Health}}' sql 2>/dev/null)" = healthy ] \
    || { log "sql never became healthy — cold boot"; return 1; }

  # master went with the previous container (the data dir is a tmpfs), so the
  # BC login has to be recreated exactly as entrypoint.sh Step 3 makes it.
  local dbu="${BC_DB_USER:-bctest}" dbp="${BC_DB_PASSWORD:-Test1234}"
  _sqlcmd -Q "
    IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$dbu')
        CREATE LOGIN [$dbu] WITH PASSWORD = '$dbp', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
    ALTER SERVER ROLE sysadmin ADD MEMBER [$dbu];" >/dev/null 2>&1 || {
      log "could not create the BC login on the fresh sql container — cold boot"; return 1; }
  local d l
  d=$(_sqlcmd -h -1 -s $'\t' -W -Q "SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK='/sqlsnap/cronus.bak'" 2>/dev/null | head -1 | cut -f1 || true)
  l=$(_sqlcmd -h -1 -s $'\t' -W -Q "SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK='/sqlsnap/cronus.bak'" 2>/dev/null | head -2 | tail -1 | cut -f1 || true)
  if [ -z "$d" ] || [ -z "$l" ]; then
    log "could not read the backup's file list — cold boot"
    return 1
  fi
  local rsout
  if ! rsout=$(_sqlcmd -Q "
    RESTORE DATABASE [CRONUS] FROM DISK='/sqlsnap/cronus.bak'
    WITH MOVE '$d' TO '/var/opt/mssql/data/CRONUS.mdf',
         MOVE '$l' TO '/var/opt/mssql/data/CRONUS_log.ldf', REPLACE" 2>&1); then
    log "RESTORE DATABASE failed — cold boot:"; echo "$rsout" | tail -6 >&2
    return 1
  fi
  log "database restored (sql up + login + restore: $(( $(date +%s) - t0 ))s)"
  local t_db; t_db=$(date +%s)

  # The container has to exist with the same configuration before its process
  # image can be restored into it, and it must not be STARTED — starting it
  # would run the entrypoint and cold-boot BC.
  #
  # It is created from the committed rootfs, not the bc-runner image, so the
  # files criu will re-open are present (see create()). BC_RUNNER_IMAGE is set
  # for THIS COMMAND ONLY and deliberately not exported: it appears in bc's
  # compose service, so exporting it would change the config component of the
  # key and every later run would miss.
  local img; img=$(sed -n 's|^rootfs_image=||p' "$s/$STAMP_NAME" | head -1)
  if [ -z "$img" ] || ! docker image inspect "$img" >/dev/null 2>&1; then
    log "the snapshot's rootfs image ${img:-<none>} is not on this machine — cold boot"
    log "  (docker image prune removes it; the snapshot alone is not enough)"
    return 1
  fi
  BC_RUNNER_IMAGE="$img" docker compose create bc >/dev/null
  local cid; cid=$(docker compose ps -aq bc)
  [ -n "$cid" ] || { log "could not create the bc container — cold boot"; return 1; }
  # The new container has a new id, so its checkpoint directory is a new path.
  _import_checkpoint "$s/checkpoint" "$cid"
  log "checkpoint staged into the new container ($(( $(date +%s) - t_db ))s)"
  local t_cp; t_cp=$(date +%s)
  if ! docker start --checkpoint cp1 "$cid" 2>/tmp/snapshot-restore.err; then
    log "restore failed — cold boot:"; sed -n 1,5p /tmp/snapshot-restore.err >&2
    grep -E 'Error \(|killed by signal' /var/tmp/criu-work/criu.log 2>/dev/null | tail -5 >&2 || true
    _discard "$s" "restore failed"
    return 1
  fi

  # A restore that returns 0 is not a working BC. Nothing downstream may run
  # until OData actually answers.
  for i in $(seq 1 60); do
    [ "$(_bc_odata)" = "200" ] && break
    sleep 2
  done
  if [ "$(_bc_odata)" != "200" ]; then
    log "restored bc never served OData — cold boot"
    _odata_diagnosis
    _discard "$s" "restored bc did not serve OData"
    return 1
  fi
  _mark_ready
  log "criu restore + OData ready: $(( $(date +%s) - t_cp ))s"
  log "restored and serving in $(( $(date +%s) - t0 ))s"
}

# A snapshot that failed to restore will fail again the same way, and leaving it
# turns one bad run into every subsequent run.
_discard() {
  log "discarding snapshot ($2): $1"
  docker compose rm -sf bc >/dev/null 2>&1 || true
  _rm_store "$1"
}

case "${1:-}" in
  key)       snapshot_key_long; echo "sha=$(snapshot_key)" ;;
  status)    status ;;
  preflight) preflight ;;
  create)    create ;;
  restore)   restore ;;
  *) cat >&2 <<USAGE
usage: scripts/snapshot.sh <command>

  key        print the key and every component of it
  status     hit / miss / disabled for the current key
  preflight  can this host checkpoint at all
  create     checkpoint a healthy BC + back up its database into the store
  restore    bring BC up from the store; non-zero means "cold boot instead"

Opt-in per MACHINE, not per pipeline: enabled when BC_SNAPSHOT_DIR is set or one
of these directories exists and is writable --
  /var/cache/bc-linux/snapshots
  $HOME/.cache/bc-linux/snapshots
Otherwise every command reports "disabled" and the caller should cold-boot.
See docs/SNAPSHOT.md.
USAGE
     exit 2 ;;
esac
