#!/usr/bin/env bash
# Benchmark BC time-to-ready on THIS machine, across the caching ladder.
#
# The numbers in docs/SNAPSHOT.md come from GitHub-hosted runners, which can
# only prove the restore is CORRECT — the store does not survive the job there,
# and the cold-boot figure has a 35s spread. On a real machine the answer is
# different, and probably better: the two 2.1 GB checkpoint copies are the
# largest single component of a restore, they behave completely differently on
# NVMe, and on btrfs/XFS they become reflinks and cost almost nothing.
#
# Three rungs, all with an identical compose configuration so only the cache
# state varies:
#
#   cold      no volumes, no snapshot   — a machine that has never run BC
#   warm      volumes kept, no snapshot — what a self-hosted runner does today
#   restore   volumes kept, snapshot    — snapshot mode
#
# Every rung is timed the same way: from the moment the command is issued until
# GET /BC/ODataV4/Company returns 200. That is "BC is usable", not "the
# container started".
#
#   scripts/bench-snapshot.sh                 # warm vs restore, 3 iterations
#   scripts/bench-snapshot.sh -n 5            # more iterations
#   scripts/bench-snapshot.sh --include-cold  # add the cold rung (slow, wipes volumes)
#
# Artifacts are never touched: re-downloading 2 GB from Microsoft would measure
# Microsoft's CDN, not this repo.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ITERATIONS=3
INCLUDE_COLD=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--iterations) ITERATIONS="$2"; shift 2 ;;
    --include-cold)  INCLUDE_COLD=1; shift ;;
    -h|--help)       sed -n '2,28p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml:docker-compose.snapshot.yml}"
: "${BC_ARTIFACTS_DIR:?set BC_ARTIFACTS_DIR to a host directory populated by scripts/download-artifacts.sh}"
ODATA_URL="http://localhost:${BC_ODATA_PORT:-7048}/BC/ODataV4/Company"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# Identical readiness test on every rung. Anything else compares apples to
# pears: `docker compose up --wait` polls on the healthcheck interval, and the
# snapshot path does not go through compose at all.
wait_odata() {
  local deadline=$(( $(date +%s) + 900 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
         -u BCRUNNER:Admin123! "$ODATA_URL" 2>/dev/null)" = "200" ] && return 0
    sleep 1
  done
  return 1
}

# NOTE: there is deliberately no output-swallowing helper here any more. The
# first version ran the timed command as `"$@" >/dev/null 2>&1`, which threw
# away both the per-phase timings this benchmark exists to collect AND the
# reason any failed iteration failed. run_rung keeps a per-iteration log.

cold_boot()    { docker compose down -v --remove-orphans; docker compose up -d; }
warm_boot()    { docker compose down --remove-orphans;    docker compose up -d; }
snap_restore() { docker compose down --remove-orphans;    ./scripts/snapshot.sh restore; }
# Removes ONLY bc, so the sql container — and with it the database snapshot,
# which lives in a tmpfs and dies with the container — survives into the next
# restore. That is the difference between reverting the database and rebuilding
# it from a 539 MB backup, and it is the shape a self-hosted runner can
# actually have: one long-lived sql, a bc replaced per job.
snap_restore_warmsql() { docker compose rm -sf bc >/dev/null 2>&1; ./scripts/snapshot.sh restore; }

# ── environment: these numbers are only comparable within one machine ─────────
say "machine"
printf '  cpu      : %s x %s\n' "$(nproc)" "$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
printf '  memory   : %s GB\n'   "$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)"
printf '  kernel   : %s\n'      "$(uname -r)"
printf '  criu     : %s\n'      "$(criu --version 2>/dev/null | head -1 || echo 'NOT INSTALLED')"
STORE=$(./scripts/snapshot.sh status 2>/dev/null | awk '{print $2}')
if [ -n "${STORE:-}" ] && [ "$STORE" != "(this" ]; then
  FSTYPE=$(df -T "$(dirname "$STORE")" 2>/dev/null | awk 'NR==2{print $2}')
  printf '  store fs : %s' "${FSTYPE:-unknown}"
  case "$FSTYPE" in
    btrfs|xfs) printf '  (reflink-capable — the 2.1 GB copies are near-free)\n' ;;
    *)         printf '  (no reflink — every restore copies 2.1 GB for real)\n' ;;
  esac
fi
./scripts/snapshot.sh preflight || echo "  preflight FAILED — the restore rung will not work" >&2

# Results go to a file, one "rung<TAB>values" line each, rather than through a
# bash associative array interpolated into a heredoc. The clever version worked
# right up until it did not, which is the story of this whole feature.
RESULTS=$(mktemp); trap 'rm -f "$RESULTS"' EXIT

run_rung() {  # run_rung <name> <fn>
  local name=$1 fn=$2 i r t0 lg vals=""
  say "$name  (n=$ITERATIONS)"
  for i in $(seq 1 "$ITERATIONS"); do
    lg=$(mktemp)
    t0=$(date +%s)
    if "$fn" >"$lg" 2>&1 && wait_odata; then r=$(( $(date +%s) - t0 )); else r=FAIL; fi
    printf '  iteration %d: %ss\n' "$i" "$r"
    # The phase breakdown is in this output, and so is the explanation of a
    # failure. Both were being discarded.
    # Anchored right after "[snapshot] ", so it must match how the lines
    # actually start. "sql up" matched nothing: that phase logs as "database
    # restored (sql up + login + restore: Ns)", so the two phases that bracket
    # criu were silently missing from run 17's breakdown.
    grep -aE '\[snapshot\] (database restored|database reverted|checkpoint staged|criu restore|bc answered|restored and serving)' "$lg" \
      | sed 's/^/      /' || true
    if [ "$r" = FAIL ]; then
      echo "      ---- why it failed (last 15 lines) ----"
      tail -15 "$lg" | sed 's/^/      /'
    fi
    rm -f "$lg"
    vals="$vals $r"
  done
  printf '%s\t%s\n' "$name" "${vals# }" >> "$RESULTS"
}

say "preparing — boot once and seed a snapshot"
docker compose down --remove-orphans >/dev/null 2>&1 || true
docker compose up -d >/dev/null 2>&1 && wait_odata \
  || { echo "could not boot BC to seed the snapshot — check: docker compose logs bc" >&2; exit 1; }
./scripts/snapshot.sh create || { echo "snapshot create failed" >&2; exit 1; }

[ "$INCLUDE_COLD" = 1 ] && run_rung "cold (no volumes, no snapshot)" cold_boot
run_rung "warm (volumes, no snapshot)" warm_boot

# The cold rung's `down -v` destroys the service volume the checkpoint depends
# on, so re-seed if anything invalidated the snapshot before timing restores.
if ! ./scripts/snapshot.sh status >/dev/null 2>&1; then
  say "re-seeding the snapshot (the cold rung invalidated it)"
  docker compose up -d >/dev/null 2>&1 && wait_odata && ./scripts/snapshot.sh create
fi
# Keep the snapshot even when a restore fails. Without this, iteration 1's
# failure deletes the store and iterations 2 and 3 report "no snapshot for this
# key" — three FAILs describing one event, and no second look at the real one.
# A benchmark is exactly the place to observe a failure repeatedly; the
# production default (discard) stays untouched.
export BC_SNAPSHOT_KEEP_ON_FAIL=1
run_rung "restore (snapshot mode)" snap_restore
# Ordered second on purpose: it depends on the sql container left running by
# the rung above, and it is the configuration a self-hosted runner would use.
run_rung "restore (snapshot mode, sql kept)" snap_restore_warmsql

say "results — seconds to OData 200"
python3 scripts/bench-report.py "$RESULTS"
