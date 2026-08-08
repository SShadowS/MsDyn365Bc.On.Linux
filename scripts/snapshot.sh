#!/usr/bin/env bash
# Boot BC from a CRIU checkpoint instead of starting the service tier.
#
# OPT-IN. Everything here is inert unless BC_SNAPSHOT_DIR is set. With it set,
# a hit replaces a ~140s cold boot with a ~25-30s restore; a miss boots normally
# and leaves a snapshot behind for next time.
#
# WHAT A SNAPSHOT IS
# ------------------
# Two files that are only valid TOGETHER:
#
#   checkpoint/   the frozen NST process image (~2.1 GB)
#   cronus.bak    the database it was booted against (~540 MB)
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

# Resolved so the script works from any cwd; compose commands run where the
# caller is, which is the repo root in every documented flow.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STAMP_NAME=".bc-snapshot-stamp"

log()  { echo "[snapshot] $*" >&2; }
die()  { echo "[snapshot] ERROR: $*" >&2; exit 1; }

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
_config_fp() {
  _compose_json | python3 -c '
import sys, json, hashlib
bc = json.load(sys.stdin)["services"]["bc"]
bc.pop("build", None)
for k in ("BC_KEEP_APP_IDS", "BC_CLEAR_ALL_APPS", "BC_TEST_APPS"):
    bc.get("environment", {}).pop(k, None)
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
  [ -n "${BC_SNAPSHOT_DIR:-}" ] || return 1
  local k; k=$(snapshot_key) || return 1
  echo "${BC_SNAPSHOT_DIR%/}/$k"
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

_apply_sysctls() {
  # NST's VmSize is ~263 GB of GC reservations. Heuristic overcommit refuses to
  # recreate that many mappings and the default 65530 map cap is far too low;
  # both show up as ENOMEM during restore, not as anything mentioning memory
  # pressure. RSS is only ~2.4 GB, so this is a policy change, not a demand for
  # more RAM.
  sudo sysctl -qw vm.overcommit_memory=1 vm.max_map_count=1048576
  sudo mkdir -p /etc/criu
  # runc reads this; `docker checkpoint create` exposes no flags for any of it.
  printf 'tcp-established\ntcp-close\nfile-locks\next-unix-sk\nlink-remap\nghost-limit 512M\nwork-dir /tmp/criu-work\nlog-file criu.log\n' \
    | sudo tee /etc/criu/runc.conf >/dev/null
  sudo mkdir -p /tmp/criu-work && sudo chmod 777 /tmp/criu-work
}

_sqlcmd() { docker compose exec -T sql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "${SA_PASSWORD:-Passw0rd123!}" -C -No "$@"; }

_bc_odata() {
  docker compose exec -T bc curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -u BCRUNNER:Admin123! http://localhost:7048/BC/ODataV4/Company 2>/dev/null || echo 000
}

# ─── status ───────────────────────────────────────────────────────────────────
status() {
  if [ -z "${BC_SNAPSHOT_DIR:-}" ]; then echo "disabled"; return 1; fi
  local s
  # A key that cannot be computed is a miss, not an error: the caller's next
  # move is a cold boot either way, and snapshot mode must never be the reason
  # a build fails.
  s=$(_store 2>/dev/null) || { echo "unavailable (cannot compute a key — run 'key' to see why)"; return 1; }
  if [ "${BC_SNAPSHOT_REFRESH:-}" = "1" ]; then echo "refresh forced $s"; return 1; fi
  # The stamp is written LAST by create(), so its presence is what distinguishes
  # a complete pair from one interrupted halfway. A torn snapshot is a miss.
  if [ -f "$s/$STAMP_NAME" ] && [ -f "$s/cronus.bak" ] && [ -d "$s/checkpoint" ]; then
    echo "hit $s"; return 0
  fi
  echo "miss $s"; return 1
}

# ─── create ───────────────────────────────────────────────────────────────────
#
# Call this against a BC that is healthy and has NOT yet had the consumer's own
# apps published — the point of the boot where the state is still generic.
create() {
  [ -n "${BC_SNAPSHOT_DIR:-}" ] || die "BC_SNAPSHOT_DIR is not set"
  preflight || die "host cannot checkpoint (see above)"
  _apply_sysctls
  local s cid t0
  s=$(_store) || die "cannot compute a snapshot key (run: scripts/snapshot.sh key)"
  cid=$(docker compose ps -q bc)
  [ -n "$cid" ] || die "no running bc container"
  [ "$(_bc_odata)" = "200" ] || die "bc is not serving OData — refusing to snapshot a BC that is not healthy"

  rm -rf "$s"; mkdir -p "$s/checkpoint"
  t0=$(date +%s)
  # --leave-running=false: the process must really stop, otherwise the backup
  # below races a BC that is still writing and the two halves disagree.
  docker checkpoint create --checkpoint-dir "$s/checkpoint" --leave-running=false "$cid" cp1
  [ "$(docker inspect --format '{{.State.Status}}' "$cid")" = "exited" ] \
    || die "bc still running after checkpoint — nothing was captured"
  log "checkpoint written in $(( $(date +%s) - t0 ))s"

  # AFTER the checkpoint, so the database matches the frozen process exactly.
  local bak_in_sql="/sqlsnap/cronus.bak"
  _sqlcmd -Q "BACKUP DATABASE [CRONUS] TO DISK='$bak_in_sql' WITH COPY_ONLY, INIT, COMPRESSION" >/dev/null
  cp "${BC_SNAPSHOT_SQLDIR:-/tmp/sqlsnap}/cronus.bak" "$s/cronus.bak"

  # Written last: the stamp is what makes the pair readable, so it must not
  # exist until both halves are on disk. A torn snapshot is a miss, not a
  # half-hit.
  { snapshot_key_long
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "service_stamp=$(_service_volume_stamp)"
  } > "$s/$STAMP_NAME"
  log "snapshot stored in $s ($(du -sh "$s" | cut -f1))"

  # --leave-running=false left bc STOPPED, and `docker compose start bc` would
  # run the entrypoint and cold-boot it all over again. Resume from the
  # checkpoint we just took instead: the caller asked for a snapshot, not for
  # their BC to be taken away.
  if docker start --checkpoint-dir "$s/checkpoint" --checkpoint cp1 "$cid" 2>/dev/null; then
    _mark_ready
    log "bc resumed from the checkpoint it just wrote"
  else
    log "could not resume from the fresh checkpoint — cold booting so the caller is not left without a BC"
    docker compose up -d --wait
  fi
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
  [ -n "${BC_SNAPSHOT_DIR:-}" ] || die "BC_SNAPSHOT_DIR is not set"
  local s; s=$(_store) || die "cannot compute a snapshot key (run: scripts/snapshot.sh key)"
  status >/dev/null || { log "no snapshot for this key — cold boot"; log "  key: $s"; return 1; }
  preflight || { log "host cannot restore — cold boot"; return 1; }

  local want have
  want=$(sed -n 's|^service_stamp=||p' "$s/$STAMP_NAME" | head -1)
  have=$(_service_volume_stamp)
  if [ "$want" != "$have" ]; then
    log "the bc-service volume does not match this snapshot — cold boot"
    log "  snapshot: $want"
    log "  volume:   $have"
    log "  (docker compose down -v destroys this volume and invalidates snapshots)"
    return 1
  fi

  _apply_sysctls
  local t0; t0=$(date +%s)

  # SQL first: the restored NST wakes holding a connection pool whose peer is
  # gone, and reconnects on first use — but only if there is something to
  # reconnect TO, with the database it expects.
  mkdir -p "${BC_SNAPSHOT_SQLDIR:-/tmp/sqlsnap}" && chmod 777 "${BC_SNAPSHOT_SQLDIR:-/tmp/sqlsnap}"
  cp "$s/cronus.bak" "${BC_SNAPSHOT_SQLDIR:-/tmp/sqlsnap}/cronus.bak"
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
    ALTER SERVER ROLE sysadmin ADD MEMBER [$dbu];" >/dev/null
  local d l
  d=$(_sqlcmd -h -1 -s $'\t' -W -Q "SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK='/sqlsnap/cronus.bak'" | head -1 | cut -f1)
  l=$(_sqlcmd -h -1 -s $'\t' -W -Q "SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK='/sqlsnap/cronus.bak'" | head -2 | tail -1 | cut -f1)
  _sqlcmd -Q "
    RESTORE DATABASE [CRONUS] FROM DISK='/sqlsnap/cronus.bak'
    WITH MOVE '$d' TO '/var/opt/mssql/data/CRONUS.mdf',
         MOVE '$l' TO '/var/opt/mssql/data/CRONUS_log.ldf', REPLACE" >/dev/null
  log "database restored"

  # The container has to exist with the same configuration before its process
  # image can be restored into it, and it must not be STARTED — starting it
  # would run the entrypoint and cold-boot BC.
  docker compose create bc >/dev/null
  local cid; cid=$(docker compose ps -aq bc)
  [ -n "$cid" ] || { log "could not create the bc container — cold boot"; return 1; }
  if ! docker start --checkpoint-dir "$s/checkpoint" --checkpoint cp1 "$cid" 2>/tmp/snapshot-restore.err; then
    log "restore failed — cold boot:"; sed -n 1,5p /tmp/snapshot-restore.err >&2
    sudo grep -E 'Error \(|killed by signal' /tmp/criu-work/criu.log 2>/dev/null | tail -5 >&2 || true
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
    _discard "$s" "restored bc did not serve OData"
    return 1
  fi
  _mark_ready
  log "restored and serving in $(( $(date +%s) - t0 ))s"
}

# A snapshot that failed to restore will fail again the same way, and leaving it
# turns one bad run into every subsequent run.
_discard() {
  log "discarding snapshot ($2): $1"
  docker compose rm -sf bc >/dev/null 2>&1 || true
  rm -rf "${1:?}"
}

case "${1:-}" in
  key)       snapshot_key_long; echo "sha=$(snapshot_key)" ;;
  status)    status ;;
  preflight) preflight ;;
  create)    create ;;
  restore)   restore ;;
  *) cat >&2 <<USAGE
usage: BC_SNAPSHOT_DIR=<dir> scripts/snapshot.sh <command>

  key        print the key and every component of it
  status     hit / miss / disabled for the current key
  preflight  can this host checkpoint at all
  create     checkpoint a healthy BC + back up its database into the store
  restore    bring BC up from the store; non-zero means "cold boot instead"

Opt-in: with BC_SNAPSHOT_DIR unset every command except key/preflight is inert.
See docs/SNAPSHOT.md.
USAGE
     exit 2 ;;
esac
