#!/usr/bin/env bash
# Does reducing the NST's memory reservations make the criu restore faster?
#
# criu restore time tracks the NUMBER of memory mappings, not the size of the
# checkpoint: 2.2 GB of pages is a second or two of NVMe, yet the restore takes
# ~18s. The NST needs vm.max_map_count >= 2^20 and carries a ~263 GB VmSize
# that is nearly all Server GC per-heap reservation. If those are many small
# mappings, cutting them should cut the restore; if they are a handful of large
# ones, this changes nothing and the remaining route is criu lazy-pages.
#
# Every configuration runs in ONE job, back to back, so they share the machine's
# state. That matters here: criu measured 27s, then 23-24s, then 18s across
# three earlier runs with no change to its code path, so comparing numbers
# ACROSS jobs cannot support a conclusion.
#
#   scripts/bench-criu-gc.sh [-n iterations]
#
# WHAT IT DOES TO THE MACHINE: for each configuration it boots BC, seeds a
# snapshot (~3.2 GB in the store), restores it n times, then discards that
# snapshot. Peak extra disk is one store, not one per configuration.
set -euo pipefail
cd "$(dirname "$0")/.."

ITER=3
while [ $# -gt 0 ]; do
  case "$1" in
    -n) ITER=$2; shift 2 ;;
    *)  echo "usage: $0 [-n iterations]" >&2; exit 2 ;;
  esac
done

ODATA_URL=${ODATA_URL:-http://localhost:7048/BC/ODataV4/Company}
log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# Same readiness test everywhere, for the same reason bench-snapshot.sh has one.
wait_odata() {
  local deadline=$(( $(date +%s) + 900 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
         -u BCRUNNER:Admin123! "$ODATA_URL" 2>/dev/null)" = "200" ] && return 0
    sleep 1
  done
  return 1
}

# label : environment
# gcServer=0 is Workstation GC — one heap instead of one per core, so the
# reservation count should fall hard. It is the aggressive end and is expected
# to cost throughput during extension compilation, which is exactly why
# DOTNET_gcServer=1 is the default; a win here is a trade, not a free lunch.
# GCHeapCount=2 keeps Server GC but caps the heaps, which is the version worth
# shipping if it recovers most of the time.
CONFIGS=(
  "baseline (gcServer=1, heaps=ncpu)|"
  "server GC, 2 heaps|DOTNET_GCHeapCount=2"
  "server GC, 1 heap|DOTNET_GCHeapCount=1"
  "workstation GC|DOTNET_gcServer=0"
)

RESULTS=$(mktemp); trap 'rm -f "$RESULTS"' EXIT

log "machine"
printf '  cpu    : %s x %s\n' "$(nproc)" "$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo)"
printf '  memory : %s GB\n' "$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))"
printf '  criu   : %s\n' "$(criu --version 2>/dev/null | head -1)"

./scripts/snapshot.sh preflight || { echo "host cannot checkpoint — nothing to measure" >&2; exit 1; }

for entry in "${CONFIGS[@]}"; do
  label=${entry%%|*}
  envs=${entry#*|}

  log "$label"
  # Unset every knob first: these persist across loop iterations otherwise, and
  # configuration 3 would silently inherit configuration 2's heap count.
  unset DOTNET_gcServer DOTNET_GCHeapCount
  if [ -n "$envs" ]; then
    for kv in $envs; do export "${kv?}"; done
  fi
  echo "  env: ${envs:-<none>}"

  docker compose down --remove-orphans >/dev/null 2>&1 || true
  if ! docker compose up -d >/dev/null 2>&1 || ! wait_odata; then
    echo "  BOOT FAILED — skipping this configuration" >&2
    printf '%s\tBOOT-FAIL\t-\t-\n' "$label" >> "$RESULTS"
    continue
  fi

  # create logs the mapping count and the checkpoint's shape; keep them, they
  # are the independent variable this whole sweep is about.
  cr=$(./scripts/snapshot.sh create 2>&1) || {
    echo "  CREATE FAILED" >&2
    printf '%s\tCREATE-FAIL\t-\t-\n' "$label" >> "$RESULTS"
    printf '%s\n' "$cr" | tail -5 >&2
    continue
  }
  vmas=$(printf '%s\n' "$cr" | sed -n 's/.*nst mappings: \([0-9]*\) vmas.*/\1/p' | head -1)
  vmsz=$(printf '%s\n' "$cr" | sed -n 's/.*VmSize:[[:space:]]*\([0-9]*\) kB.*/\1/p' | head -1)
  ckpt=$(printf '%s\n' "$cr" | sed -n 's/.*checkpoint: \(.*\)$/\1/p' | head -1)
  printf '  mappings: %s vmas, VmSize %s GB\n' "${vmas:-?}" \
    "$( [ -n "${vmsz:-}" ] && echo $(( vmsz / 1024 / 1024 )) || echo '?' )"
  printf '  checkpoint: %s\n' "${ckpt:-?}"

  # Keep sql up between restores: that is the configuration a self-hosted runner
  # would use, and it isolates the criu phase from database rebuild time.
  export BC_SNAPSHOT_KEEP_ON_FAIL=1
  criu_times="" total_times=""
  for i in $(seq 1 "$ITER"); do
    docker compose rm -sf bc >/dev/null 2>&1 || true
    out=$(./scripts/snapshot.sh restore 2>&1) || { criu_times="$criu_times FAIL"; continue; }
    c=$(printf '%s\n' "$out" | sed -n 's/.*criu restore returned in \([0-9]*\)s.*/\1/p' | head -1)
    t=$(printf '%s\n' "$out" | sed -n 's/.*restored and serving in \([0-9]*\)s.*/\1/p' | head -1)
    criu_times="$criu_times ${c:-?}"; total_times="$total_times ${t:-?}"
    printf '  restore %d: criu %ss, total %ss\n' "$i" "${c:-?}" "${t:-?}"
  done
  printf '%s\t%s\t%s\t%s\n' "$label" "${vmas:-?}" "${criu_times# }" "${total_times# }" >> "$RESULTS"

  # One store at a time: four configurations would otherwise leave ~13 GB behind.
  ./scripts/snapshot.sh discard >/dev/null 2>&1 || true
done

log "results"
python3 - "$RESULTS" <<'PY'
import statistics, sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
print(f"  {'configuration':<32}{'vmas':>10}{'criu':>9}{'total':>9}")
base = None
for r in rows:
    label, vmas = r[0], r[1]
    if vmas in ("BOOT-FAIL", "CREATE-FAIL"):
        print(f"  {label:<32}{vmas:>10}"); continue
    def med(s):
        v = [int(x) for x in s.split() if x.isdigit()]
        return statistics.median(v) if v else None
    c, t = med(r[2]), med(r[3])
    if c is None:
        print(f"  {label:<32}{vmas:>10}{'all failed':>18}"); continue
    rel = ""
    if base is None:
        base = c
    elif c < base:
        rel = f"   criu {base - c:.0f}s faster"
    elif c > base:
        rel = f"   criu {c - base:.0f}s SLOWER"
    print(f"  {label:<32}{vmas:>10}{c:>8.0f}s{(t or 0):>8.0f}s{rel}")
print()
print("  vmas is the count at checkpoint time. If it barely moves, the GC")
print("  reservations are a few large mappings and this route is a dead end —")
print("  criu lazy-pages is then the only remaining lever on the restore.")
print()
print("  A win here is a TRADE: Server GC is the default because it speeds up")
print("  the parallel Roslyn compile during boot and extension publish. Before")
print("  adopting anything, measure test wall clock on a real suite.")
PY
