#!/usr/bin/env bash
# Regression guard for the snapshot cache key.
#
# The key is the entire safety story of snapshot mode: a component that fails to
# invalidate means a checkpoint gets reused against state it does not match, and
# BC comes back looking alive and being wrong. A component that invalidates when
# it should not is merely wasteful, but it is what makes the feature not worth
# turning on — see docs/SNAPSHOT.md.
#
# Needs neither docker daemon nor BC: it only exercises key computation, so it
# runs in about a second. Requires the `docker` CLI (for `compose config`).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMP=$(mktemp -d); TMP2=$(mktemp -d); trap 'rm -rf "$TMP" "$TMP2"' EXIT
printf 'key=v1|https://x/sandbox/28.1.49838.53507/w1|https://x/sandbox/28.1.49838.53507/platform\n' \
  > "$TMP/.bc-artifact-cache"

export COMPOSE_FILE=docker-compose.yml:docker-compose.snapshot.yml
export BC_ARTIFACTS_DIR="$TMP" BC_SNAPSHOT_DIR="$TMP/store"

key() { env "$@" ./scripts/snapshot.sh key 2>/dev/null | sed -n 's/^sha=//p'; }

FAIL=0
BASE=$(key BC_KEEP_APP_IDS=aaa,bbb)
[ -n "$BASE" ] || { echo "FAIL: could not compute a baseline key at all"; exit 1; }

# $1 stable|invalidates, $2 description, rest: env for the variant
check() {
  local want=$1 desc=$2; shift 2
  local got; got=$(key "$@")
  local same=no; [ "$BASE" = "$got" ] && same=yes
  if { [ "$want" = stable ] && [ "$same" = yes ]; } || { [ "$want" = invalidates ] && [ "$same" = no ]; }; then
    printf '  ok    %-12s %s\n' "$want" "$desc"
  else
    printf '  FAIL  %-12s %s (key %s)\n' "$want" "$desc" "$([ "$same" = yes ] && echo unchanged || echo changed)"
    FAIL=1
  fi
}

echo "snapshot key behaviour:"
# Must NOT invalidate — each of these is the same snapshot by any honest reading,
# and treating it as different is what makes a cache useless in practice.
check stable "keep-app-ids reordered"          BC_KEEP_APP_IDS=bbb,aaa
check stable "keep-app-ids duplicated"         BC_KEEP_APP_IDS=aaa,bbb,aaa
check stable "unrelated variable in the shell" BC_KEEP_APP_IDS=aaa,bbb SOME_UNRELATED_VAR=1

# The whole point of sharing a snapshot between two apps, or two repositories,
# on one runner. Each repo passes its own ${{ github.workspace }}/artifact-cache,
# and if that host path reached the key they would each rebuild a 2.6 GB
# snapshot the other could have used. Only the artifact CONTENT may matter.
cp "$TMP/.bc-artifact-cache" "$TMP2/.bc-artifact-cache"
check stable "a different artifact-cache host path" BC_KEEP_APP_IDS=aaa,bbb BC_ARTIFACTS_DIR="$TMP2"

# An app's own identity is not in the key: resolve-keep-app-ids.py seeds from
# declared DEPENDENCIES and never from the app's own id, so two different apps
# with the same closure produce the same BC_KEEP_APP_IDS and share a snapshot.
# This asserts the key end of that; the resolver end is its own concern.

# Must invalidate — each changes what is actually inside the checkpoint or the
# database it is paired with.
check invalidates "a dependency added to the closure" BC_KEEP_APP_IDS=aaa,bbb,ccc
check invalidates "a published port moved"            BC_KEEP_APP_IDS=aaa,bbb BC_ODATA_PORT=17048
check invalidates "a .NET GC tuning knob"             BC_KEEP_APP_IDS=aaa,bbb DOTNET_GCHeapCount=2
check invalidates "the SQL password"                  BC_KEEP_APP_IDS=aaa,bbb SA_PASSWORD=Different1!
check invalidates "BC_TEST_APPS set"                  BC_KEEP_APP_IDS=aaa,bbb BC_TEST_APPS=/tmp/x.app

# Localization. The country lives in the resolved APP url (the platform url is
# country-independent) AND in BC_COUNTRY on bc's environment, so it is keyed
# twice over. Asserted on the artifact path here and the env path below, because
# either one alone is sufficient and a refactor could plausibly drop one of them
# without anything else noticing.
printf 'key=v1|https://x/sandbox/28.1.49838.53507/de|https://x/sandbox/28.1.49838.53507/platform\n' \
  > "$TMP2/.bc-artifact-cache"
check invalidates "a different country in the artifact url" BC_KEEP_APP_IDS=aaa,bbb BC_ARTIFACTS_DIR="$TMP2"
check invalidates "a different BC_COUNTRY"                  BC_KEEP_APP_IDS=aaa,bbb BC_COUNTRY=de
check invalidates "a different BC_TYPE"                     BC_KEEP_APP_IDS=aaa,bbb BC_TYPE=onprem

# The one that matters most for hit rate: a Microsoft hotfix under the same
# short version resolves to a new url, and that has to be a miss.
printf 'key=v1|https://x/sandbox/28.1.49999.99999/w1|https://x/sandbox/28.1.49999.99999/platform\n' \
  > "$TMP/.bc-artifact-cache"
check invalidates "a BC hotfix under the same 28.1"   BC_KEEP_APP_IDS=aaa,bbb

[ "$FAIL" = 0 ] && echo "all key checks passed" || echo "KEY CHECKS FAILED"
exit $FAIL
