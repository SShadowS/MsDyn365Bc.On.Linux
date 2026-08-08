#!/usr/bin/env python3
"""Decide whether a self-hosted runner is available for a given label set.

Reads GitHub's runner-list JSON on stdin (the body of
`GET /repos/{owner}/{repo}/actions/runners`, or the org equivalent) and prints
one line:

    <count> <human-readable reason>

Exit status is 0 when at least one runner matches, 1 when none does, so callers
can branch on it directly.

Lives in a file rather than inline in the workflow on purpose: multi-line Python
inside a `run: |` block terminates the YAML block scalar the moment a line
starts at column 0, and indenting it to stay inside the scalar is a Python
syntax error at top level. Every attempt to inline this has to pick one of those
two failures.
"""
import argparse
import json
import sys


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--labels", required=True,
                    help='A single label ("self-hosted") or a JSON array '
                         '\'["self-hosted","linux"]\'. ALL must be present on one '
                         'runner, which is how runs-on itself matches.')
    ap.add_argument("--require-idle", action="store_true",
                    help="Only count runners that are not currently busy.")
    args = ap.parse_args()

    want = args.labels.strip()
    want = set(json.loads(want)) if want.startswith("[") else {want}

    try:
        runners = json.load(sys.stdin).get("runners", [])
    except (json.JSONDecodeError, AttributeError) as e:
        print(f"0 could not parse the runner list ({e})")
        return 1

    # A runner matches when it is online and carries every requested label.
    # "busy" is a separate axis: a busy runner still satisfies runs-on, the job
    # just queues behind the current one — which on a fleet of one is usually
    # preferable to a hosted runner, because that machine holds the warm caches.
    matching = [r for r in runners
                if r.get("status") == "online"
                and want <= {l["name"] for l in r.get("labels", [])}
                and (not args.require_idle or not r.get("busy"))]

    qualifier = " and are idle" if args.require_idle else ""
    print(f"{len(matching)} {len(matching)}/{len(runners)} registered runners "
          f"carry {sorted(want)} and are online{qualifier}")
    return 0 if matching else 1


if __name__ == "__main__":
    sys.exit(main())
