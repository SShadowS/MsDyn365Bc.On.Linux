#!/usr/bin/env bash
# Prepare THIS machine for snapshot mode. Idempotent, and deliberately cautious:
# this is somebody's workstation or build box, not a throwaway CI VM.
#
#   scripts/setup-snapshot-host.sh --check     # report only, change nothing
#   scripts/setup-snapshot-host.sh             # do what is missing, ask before
#                                              # anything disruptive
#   scripts/setup-snapshot-host.sh --yes       # same, unattended
#
# What it will do, only where needed:
#   1. build criu 4.2.1+ from source        (distro packages are too old)
#   2. add {"experimental": true} to        (MERGED into the existing file, and
#      /etc/docker/daemon.json               restarting docker STOPS YOUR
#                                            CONTAINERS — it asks first)
#   3. persist vm.overcommit_memory and     (/etc/sysctl.d/99-bc-snapshot.conf)
#      vm.max_map_count
#   4. write /etc/criu/runc.conf            (runc reads it when the daemon
#                                            invokes criu; no CLI flag reaches it)
#   5. create the snapshot store and        (creating the store IS the
#      artifact cache directories            per-machine opt-in)
#   6. check docker access for this user
#
# 3-5 are why scripts/snapshot.sh itself needs no root: the privileged parts are
# one-time host configuration, done here, rather than repeated on every run.
#
# What it will never do: replace daemon.json, remove anything, or restart docker
# without saying so.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

CHECK_ONLY=0; ASSUME_YES=0
STORE_DIR="${BC_SNAPSHOT_DIR:-/var/cache/bc-linux/snapshots}"
CRIU_MIN=4.2.1
# Overridable, so a caller pinning CRIU_REF is not silently ignored.
CRIU_REF="${CRIU_REF:-v${CRIU_MIN}}"

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --store) STORE_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
todo() { printf '  \033[33mTODO\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
ask() {
  [ "$ASSUME_YES" = 1 ] && return 0
  read -r -p "  -> $1 [y/N] " a </dev/tty
  [ "$a" = y ] || [ "$a" = Y ]
}

NEED=0
echo "checking prerequisites for snapshot mode"

# ── 1. docker, and the current user's access to it ────────────────────────────
if ! command -v docker >/dev/null; then
  bad "docker is not installed"; NEED=1
elif ! docker info >/dev/null 2>&1; then
  bad "cannot talk to the docker daemon as $(id -un) — add yourself to the 'docker' group and re-login"
  NEED=1
else
  ok "docker reachable as $(id -un)"
fi

# ── 2. passwordless sudo ──────────────────────────────────────────────────────
# `sudo -n true` alone is a FALSE PASS in an interactive shell: sudo caches a
# timestamp for a few minutes after you type a password, so it succeeds without
# proving any policy. -k drops that cache first, which is what a CI job's fresh
# session actually faces. The cost is that your next sudo will ask again.
# Only THIS script needs root, and only to write host configuration. The
# per-run path (scripts/snapshot.sh) needs none — see the note in the failure
# branch. So a password prompt here is an inconvenience, not a blocker, and it
# is no longer counted against readiness.
SUDO_OK=0
if sudo -n -k true 2>/dev/null; then
  SUDO_OK=1
  ok "passwordless sudo (verified with a cleared timestamp)"
else
  todo "sudo needs a password — fine for running THIS script interactively,"
  echo "        but it means this script cannot run unattended in CI."
  echo "        scripts/snapshot.sh itself needs no sudo at all: the host config"
  echo "        below is written once, and the root-owned checkpoint is copied"
  echo "        through the docker socket you already have."
fi

# ── 3. criu ───────────────────────────────────────────────────────────────────
CRIU_HAVE=$(criu --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
if [ -n "$CRIU_HAVE" ] && [ "$(printf '%s\n%s\n' "$CRIU_MIN" "$CRIU_HAVE" | sort -V | head -1)" = "$CRIU_MIN" ]; then
  ok "criu $CRIU_HAVE (>= $CRIU_MIN)"
else
  todo "criu ${CRIU_HAVE:-not installed} — need >= $CRIU_MIN (3.17 dumps BC fine then segfaults the restore)"
  if [ "$CHECK_ONLY" = 0 ] && ask "build criu $CRIU_REF from source and install it?"; then
    # Distro-aware, because this is meant for real machines and not everyone is
    # on Debian. Anything unrecognised gets the dependency list rather than a
    # confusing "apt-get: command not found".
    if command -v apt-get >/dev/null; then
      sudo apt-get update -qq
      sudo apt-get install -y -qq build-essential git pkg-config libprotobuf-dev \
        libprotobuf-c-dev protobuf-c-compiler protobuf-compiler python3-protobuf \
        libnl-3-dev libnet-dev libcap-dev libbsd-dev libgnutls28-dev libnftables-dev iproute2 \
        || { bad "could not install build dependencies"; NEED=1; }
    elif command -v pacman >/dev/null; then
      # criu is also in the AUR on Arch; building from source here keeps the
      # version pinned to what this feature is tested against.
      sudo pacman -S --needed --noconfirm base-devel git protobuf protobuf-c \
        python-protobuf libnl libnet libbsd gnutls nftables iproute2 \
        || { bad "could not install build dependencies"; NEED=1; }
    elif command -v dnf >/dev/null; then
      sudo dnf install -y gcc make git protobuf-devel protobuf-c-devel python3-protobuf \
        libnl3-devel libnet-devel libcap-devel libbsd-devel gnutls-devel nftables-devel iproute \
        || { bad "could not install build dependencies"; NEED=1; }
    else
      bad "unknown package manager — install criu's build dependencies manually"
      echo "        see https://criu.org/Installation"
      NEED=1
    fi
    rm -rf /tmp/criu-build
    git clone --depth 1 --branch "$CRIU_REF" https://github.com/checkpoint-restore/criu.git /tmp/criu-build \
      && make -C /tmp/criu-build -j"$(nproc)" >/dev/null 2>&1 \
      && sudo make -C /tmp/criu-build install-criu >/dev/null \
      && { command -v criu >/dev/null || sudo ln -sf /usr/local/sbin/criu /usr/sbin/criu; } \
      && ok "criu $(criu --version 2>/dev/null | head -1) installed" \
      || { bad "criu build failed — see /tmp/criu-build"; NEED=1; }
  else
    NEED=1
  fi
fi

# criu can be installed and still unable to run: on some kernels it cannot parse
# its own vDSO and fails before touching any process. Better to find out now.
if command -v criu >/dev/null && [ "$SUDO_OK" = 0 ]; then
  # Do not blame criu for a sudo problem. The first self-hosted run reported
  # "criu check failed" with no error lines at all, because sudo had exited
  # non-zero for want of a password and criu never ran.
  todo "skipping criu check — it needs sudo, which is not passwordless here"
elif command -v criu >/dev/null; then
  # Judge this by criu's EXIT CODE, not by grepping its output. `criu check`
  # prints "Warn (criu/kerndat.c:...): Can't load /run/criu.kdat" on every first
  # run — the kdat cache simply does not exist yet — and an earlier version of
  # this script matched "kerndat" anywhere and declared the host unusable. It
  # also never showed the reason, which is the same mistake that cost three CI
  # runs elsewhere in this feature.
  if CRIU_CHECK_OUT=$(sudo criu check 2>&1); then
    ok "criu check passes on kernel $(uname -r)"
  else
    bad "criu check failed on kernel $(uname -r):"
    # Fall back to the raw tail when nothing matches Error/Warn. Printing a
    # filtered view that comes out EMPTY is worse than printing nothing --
    # it reads as "no reason given" when the reason was there all along.
    if echo "$CRIU_CHECK_OUT" | grep -qE '^(Error|Warn)'; then
      echo "$CRIU_CHECK_OUT" | grep -E '^(Error|Warn)' | tail -8 | sed 's/^/        /'
    else
      echo "$CRIU_CHECK_OUT" | tail -8 | sed 's/^/        /'
    fi
    if echo "$CRIU_CHECK_OUT" | grep -qiE 'vdso|kerndat_vdso'; then
      echo "        This is the vDSO-parsing failure. It is NOT about kernel age --"
      echo "        criu 4.2.1 checks clean on Arch 7.1.4 and fails on 6.17-azure --"
      echo "        so it tracks the kernel flavour. Try criu from git master, or a"
      echo "        different kernel build."
    fi
    NEED=1
  fi
fi

# ── 4. docker experimental ────────────────────────────────────────────────────
if [ "$(docker info --format '{{.ExperimentalBuild}}' 2>/dev/null)" = "true" ]; then
  ok "docker daemon is in experimental mode"
else
  todo "docker daemon is not experimental — 'docker checkpoint' is unavailable without it"
  if [ "$CHECK_ONLY" = 0 ]; then
    echo "        this MERGES into /etc/docker/daemon.json and then RESTARTS docker,"
    echo "        which stops every running container on this machine."
    if ask "edit daemon.json and restart docker now?"; then
      sudo test -f /etc/docker/daemon.json || echo '{}' | sudo tee /etc/docker/daemon.json >/dev/null
      sudo cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
      sudo python3 -c "import json,sys; p='/etc/docker/daemon.json'; c=json.load(open(p)); c['experimental']=True; json.dump(c,open(p,'w'),indent=2)" \
        && sudo systemctl restart docker \
        && sleep 3 \
        && ok "experimental enabled (previous file backed up alongside it)" \
        || { bad "could not enable experimental mode"; NEED=1; }
    else
      NEED=1
    fi
  else
    NEED=1
  fi
fi

# ── 4b. kernel + criu configuration, PERSISTED ────────────────────────────────
#
# These used to be applied by snapshot.sh on every run, which is the single
# reason the feature looked like it needed root at all: one-time host setup had
# been smuggled into the per-run path. Written once here; snapshot.sh only
# checks them and tells you to run this script if they are missing.
SYSCTL_FILE=/etc/sysctl.d/99-bc-snapshot.conf
if [ "$(cat /proc/sys/vm/overcommit_memory 2>/dev/null)" = "1" ] \
   && [ "$(cat /proc/sys/vm/max_map_count 2>/dev/null)" -ge 1048576 ] 2>/dev/null; then
  ok "vm.overcommit_memory=1, vm.max_map_count>=1048576"
else
  # NST's VmSize is ~263 GB of GC reservations. Heuristic overcommit refuses to
  # recreate that many mappings and the default 65530 map cap is far too low;
  # both surface during restore as ENOMEM, naming nothing about memory policy.
  # RSS is only ~2.4 GB — this is a policy change, not a demand for more RAM.
  todo "kernel needs vm.overcommit_memory=1 and vm.max_map_count>=1048576"
  if [ "$CHECK_ONLY" = 0 ] && ask "write $SYSCTL_FILE and apply it?"; then
    printf 'vm.overcommit_memory = 1\nvm.max_map_count = 1048576\n' | sudo tee "$SYSCTL_FILE" >/dev/null \
      && sudo sysctl -q --load="$SYSCTL_FILE" \
      && ok "sysctls applied and persisted in $SYSCTL_FILE" \
      || { bad "could not apply sysctls"; NEED=1; }
  else
    NEED=1
  fi
fi

# runc reads this when the daemon invokes criu; `docker checkpoint create`
# exposes no flag for any of it. Each option was unlocked by a specific failed
# run -- see PERFORMANCE-IDEAS.md.
if grep -q '^tcp-established' /etc/criu/runc.conf 2>/dev/null \
   && grep -q '^work-dir /var/tmp/criu-work' /etc/criu/runc.conf 2>/dev/null; then
  ok "/etc/criu/runc.conf"
else
  todo "/etc/criu/runc.conf missing the options criu needs for BC"
  if [ "$CHECK_ONLY" = 0 ] && ask "write /etc/criu/runc.conf?"; then
    sudo mkdir -p /etc/criu \
      && printf 'tcp-established\ntcp-close\nfile-locks\next-unix-sk\nlink-remap\nghost-limit 512M\nwork-dir /var/tmp/criu-work\nlog-file criu.log\n' \
         | sudo tee /etc/criu/runc.conf >/dev/null \
      && ok "wrote /etc/criu/runc.conf" \
      || { bad "could not write /etc/criu/runc.conf"; NEED=1; }
  else
    NEED=1
  fi
fi

# ── 5. the store — this is the per-machine opt-in ─────────────────────────────
if [ -d "$STORE_DIR" ] && [ -w "$STORE_DIR" ]; then
  ok "snapshot store $STORE_DIR"
else
  todo "snapshot store $STORE_DIR does not exist — creating it IS the opt-in"
  if [ "$CHECK_ONLY" = 0 ] && ask "create $STORE_DIR owned by $(id -un)?"; then
    sudo install -d -o "$(id -u)" -g "$(id -g)" -m 755 "$STORE_DIR" \
      && ok "created $STORE_DIR" || { bad "could not create $STORE_DIR"; NEED=1; }
  else
    NEED=1
  fi
fi

# Staging for the database backup. Explicitly OFF /tmp: that is a ramdisk on
# Arch and others, and a ~540 MB backup written there on every create and
# restore exhausts it — which is what took down benchmark runs 7 through 11,
# each time wearing a different disguise.
for d in /var/tmp/bc-sqlstage /var/tmp/criu-work; do
  if [ -d "$d" ] && [ -w "$d" ]; then
    ok "staging dir $d"
  else
    mkdir -p "$d" 2>/dev/null && chmod 777 "$d" 2>/dev/null \
      && ok "created $d" || { bad "could not create $d"; NEED=1; }
  fi
  [ "$(stat -f -c %T "$d" 2>/dev/null)" = tmpfs ] \
    && { bad "$d is on tmpfs (RAM) — pick a disk-backed path"; NEED=1; }
done

# The artifact cache is machine-level state too, and creating it here is what
# keeps sudo out of the benchmark job.
ART_DIR="${BC_ARTIFACTS_DIR:-/var/cache/bc-linux/artifacts}"
if [ -d "$ART_DIR" ] && [ -w "$ART_DIR" ]; then
  ok "artifact cache $ART_DIR"
else
  todo "artifact cache $ART_DIR does not exist"
  if [ "$CHECK_ONLY" = 0 ] && ask "create $ART_DIR owned by $(id -un)?"; then
    sudo install -d -o "$(id -u)" -g "$(id -g)" -m 755 "$ART_DIR" \
      && ok "created $ART_DIR" || { bad "could not create $ART_DIR"; NEED=1; }
  else
    NEED=1
  fi
fi

# Filesystem matters more than it looks: the two 2.1 GB checkpoint copies are
# the largest component of a restore, and on btrfs/XFS they become reflinks.
if [ -d "$STORE_DIR" ]; then
  FSTYPE=$(df -T "$STORE_DIR" 2>/dev/null | awk 'NR==2{print $2}')
  case "$FSTYPE" in
    btrfs|xfs) ok "store is on $FSTYPE — checkpoint copies become reflinks, nearly free" ;;
    *)         ok "store is on ${FSTYPE:-unknown} — no reflink, each restore copies 2.1 GB" ;;
  esac
  df -h "$STORE_DIR" | awk 'NR==2{printf "  note  %s free on %s (allow ~3 GB per snapshot)\n", $4, $6}'
fi

echo
if [ "$NEED" = 0 ]; then
  echo "this machine is ready. Verify with:"
  echo "  COMPOSE_FILE=docker-compose.yml:docker-compose.snapshot.yml scripts/snapshot.sh preflight"
else
  echo "not ready yet — rerun without --check to fix the TODO items above."
fi
exit "$NEED"
