#!/usr/bin/env python3
"""Format bench-snapshot.sh's results.

Reads a file of "rung<TAB>space separated seconds (or FAIL)" lines and prints a
table with medians and spreads. Separate from the shell script for the same
reason as pick-runner.py: multi-line Python inside a `run:`/heredoc block is a
recurring source of breakage in this repo.

Medians rather than means, because a single slow iteration — a background
`docker pull`, a laptop dropping to a lower power state — should not move the
headline. The spread is printed next to it so a noisy run is visible rather
than averaged away.
"""
import statistics
import sys


def main() -> int:
    try:
        lines = [l for l in open(sys.argv[1]) if l.strip()]
    except (IndexError, OSError) as e:
        print(f"  cannot read results ({e})")
        return 1
    if not lines:
        print("  (no results)")
        return 1

    rows = []
    for line in lines:
        name, _, vals = line.rstrip("\n").partition("\t")
        parts = vals.split()
        nums = [int(v) for v in parts if v.isdigit()]
        rows.append((name, nums, len(parts) - len(nums)))

    print(f"  {'rung':<34}{'median':>8}{'min':>7}{'max':>7}   speedup")
    base = None
    for name, nums, failed in rows:
        if not nums:
            print(f"  {name:<34}{'every iteration failed':>28}")
            continue
        med = statistics.median(nums)
        if base is None:
            base, rel = med, "baseline"
        elif med < base:
            rel = f"{base / med:.1f}x faster"
        else:
            rel = f"{med / base:.1f}x slower"
        note = f"   ({failed} failed)" if failed else ""
        print(f"  {name:<34}{med:>7.0f}s{min(nums):>6}s{max(nums):>6}s   {rel}{note}")

    print()
    print("  The first rung is the baseline. Quote the ratio AND the spread — a")
    print("  single pair of runs proved misleading more than once while building")
    print("  this; see docs/SNAPSHOT.md, 'Measurements'.")

    # A run where iterations failed is not a result, and must not leave CI green.
    # Run 7 reported "1.2x faster (2 failed)" inside a job that exited 0.
    failed = sum(f for _, _, f in rows)
    if failed:
        print(f"\n  {failed} iteration(s) FAILED — these medians are not trustworthy.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
