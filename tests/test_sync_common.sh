#!/bin/bash
# Regression tests for sync-common.sh's three-way merge and its report.
# Usage: bash tests/test_sync_common.sh   (exit 0 = all pass)
#
# No network: the script's GitHub endpoints are overridden to a local tree served
# over file:// (GPU_TUNED_SYNC_RAW_BASE) plus a canned tree listing
# (GPU_TUNED_SYNC_TREE_JSON), so each case is a real end-to-end run of the script.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="${SRC}/sync-common.sh"
PASS=0; FAIL=0

ok() { PASS=$((PASS+1)); echo "ok   - $1"; }
no() { FAIL=$((FAIL+1)); echo "FAIL - $1"; [[ $# -lt 2 ]] || printf '     %s\n' "$2"; }
# want_rc <name> <want> <got>
want_rc() { [[ "$3" -eq "$2" ]] && ok "$1" || no "$1" "exit $3, want $2"; }
# has <name> <file> <extended-regex>
has() { grep -qE "$3" "$2" && ok "$1" || no "$1" "'$3' not in $2: $(tr '\n' '|' < "$2")"; }
# hasnt <name> <file> <extended-regex>
hasnt() { grep -qE "$3" "$2" && no "$1" "'$3' unexpectedly in $2" || ok "$1"; }
# file_is <name> <file> <expected-content-file>
file_is() { cmp -s "$2" "$3" && ok "$1" || no "$1" "$2 differs from the expected content"; }
exists() { [[ -e "$2" ]] && ok "$1" || no "$1" "$2 does not exist"; }
absent() { [[ -e "$2" ]] && no "$1" "$2 still exists" || ok "$1"; }

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

BASE_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222

# --- the fake upstream: the same repo at two commits ------------------------------
mkdir -p "${ROOT}/raw/${BASE_SHA}/devices" "${ROOT}/raw/${NEW_SHA}/devices" "${ROOT}/raw/${NEW_SHA}/toolkits"
conf() { printf '# gb10 device\nA=%s\nB=2\nC=3\nD=4\nE=5\nF=6\nG=7\nH=8\nI=9\nJ=10\nZ=%s\n' "$1" "$2"; }
conf 1 26   > "${ROOT}/raw/${BASE_SHA}/devices/gb10.conf"
conf 11 26  > "${ROOT}/raw/${NEW_SHA}/devices/gb10.conf"
# dropped at NEW_SHA: only the base has it
conf 1 26   > "${ROOT}/raw/${BASE_SHA}/devices/old.conf"
printf 'TOOLKIT_NCCL_VERSION=none\n' > "${ROOT}/raw/${NEW_SHA}/toolkits/cu134.env"
printf '# lib v1\nf() { echo one; }\n' > "${ROOT}/raw/${BASE_SHA}/tuned-common.sh"
printf '# lib v2\nf() { echo two; }\n' > "${ROOT}/raw/${NEW_SHA}/tuned-common.sh"
cat > "${ROOT}/tree.json" <<'JSON'
{"tree":[{"type":"blob","path":"tuned-common.sh"},
         {"type":"blob","path":"devices/gb10.conf"},
         {"type":"blob","path":"toolkits/cu134.env"},
         {"type":"blob","path":"README.md"}]}
JSON

export GPU_TUNED_SYNC_RAW_BASE="file://${ROOT}/raw"
export GPU_TUNED_SYNC_TREE_JSON="${ROOT}/tree.json"

# new_consumer <name> [<sha-to-record>|none] -- a vendored checkout at the base
# version, with sync-common.sh beside it, as a real consumer has it.
new_consumer() {
    local d="${ROOT}/$1" sha="${2:-${BASE_SHA}}"
    mkdir -p "${d}/tuned/common-data/devices"
    cp "${ROOT}/raw/${BASE_SHA}/tuned-common.sh" "${d}/tuned/common.sh"
    cp "${SYNC}" "${d}/tuned/sync-common.sh"
    cp "${ROOT}/raw/${BASE_SHA}/devices/gb10.conf" "${d}/tuned/common-data/devices/gb10.conf"
    cp "${ROOT}/raw/${BASE_SHA}/devices/old.conf" "${d}/tuned/common-data/devices/old.conf"
    [[ "${sha}" == none ]] || echo "${sha}" > "${d}/tuned/common.sh.sha"
    echo "${d}"
}
run_sync() { ( cd "$1/tuned" && bash ./sync-common.sh sync "${NEW_SHA}" ) > "$1/out.txt" 2>&1; }

# --- 1. fast-forward: nothing was edited locally ----------------------------------
c="$(new_consumer ff)"; run_sync "${c}"; rc=$?
rep="${c}/tuned/common.sh.sync-report"
want_rc "fast-forward: exits 0" 0 "${rc}"
file_is "fast-forward: the library is now upstream's" "${c}/tuned/common.sh" "${ROOT}/raw/${NEW_SHA}/tuned-common.sh"
file_is "fast-forward: the device file is now upstream's" "${c}/tuned/common-data/devices/gb10.conf" "${ROOT}/raw/${NEW_SHA}/devices/gb10.conf"
has "fast-forward: the report records the library as updated" "${rep}" '^updated +tuned-common\.sh$'
has "fast-forward: the report records the device file as updated" "${rep}" '^updated +devices/gb10\.conf$'
has "fast-forward: a file only upstream has is added" "${rep}" '^added +toolkits/cu134\.env$'
exists "fast-forward: the added file is on disk" "${c}/tuned/common-data/toolkits/cu134.env"
has "fast-forward: the sha is advanced" "${c}/tuned/common.sh.sha" "^${NEW_SHA}$"
has "fast-forward: the report names both commits" "${rep}" "^base: +${BASE_SHA}$"
has "fast-forward: README.md is not vendored" "${rep}" '.'
hasnt "fast-forward: only data files and the library are touched" "${rep}" 'README\.md'

# --- 2. a stale vendored file: removed only when it is provably untouched ----------
has "stale: an untouched dropped file is removed" "${rep}" '^removed +devices/old\.conf'
absent "stale: and it is gone from disk" "${c}/tuned/common-data/devices/old.conf"

c="$(new_consumer stale_edited)"
printf 'LOCAL=1\n' >> "${c}/tuned/common-data/devices/old.conf"
run_sync "${c}"; rc=$?
rep="${c}/tuned/common.sh.sync-report"
want_rc "stale: an edited dropped file does not fail the run" 0 "${rc}"
has "stale: an edited dropped file is kept" "${rep}" '^kept +devices/old\.conf'
exists "stale: and it is still on disk" "${c}/tuned/common-data/devices/old.conf"

# --- 3. a clean three-way merge: local edit far from upstream's --------------------
c="$(new_consumer merge_clean)"
conf 1 99 > "${c}/tuned/common-data/devices/gb10.conf"   # local changed Z, upstream changed A
run_sync "${c}"; rc=$?
rep="${c}/tuned/common.sh.sync-report"
conf 11 99 > "${ROOT}/want-merged.conf"                  # both changes
want_rc "clean merge: exits 0" 0 "${rc}"
has "clean merge: the report says merged" "${rep}" '^merged +devices/gb10\.conf'
file_is "clean merge: upstream's change and the local one are both in" "${c}/tuned/common-data/devices/gb10.conf" "${ROOT}/want-merged.conf"
exists "clean merge: the previous local content is saved beside it" "${c}/tuned/common-data/devices/gb10.conf.local-${NEW_SHA:0:7}"
has "clean merge: the sha is advanced" "${c}/tuned/common.sh.sha" "^${NEW_SHA}$"

# --- 4. a conflict: refused, nothing touched, run fails ---------------------------
c="$(new_consumer merge_conflict)"
conf 42 26 > "${c}/tuned/common-data/devices/gb10.conf"  # local changed the same line upstream did
cp "${c}/tuned/common-data/devices/gb10.conf" "${ROOT}/want-conflict.conf"
run_sync "${c}"; rc=$?
rep="${c}/tuned/common.sh.sync-report"
want_rc "conflict: the run exits 1" 1 "${rc}"
has "conflict: the report says CONFLICT" "${rep}" '^CONFLICT +devices/gb10\.conf'
file_is "conflict: the local file is byte-for-byte as it was" "${c}/tuned/common-data/devices/gb10.conf" "${ROOT}/want-conflict.conf"
exists "conflict: upstream's version is saved beside it" "${c}/tuned/common-data/devices/gb10.conf.upstream-${NEW_SHA:0:7}"
has "conflict: the sha is NOT advanced" "${c}/tuned/common.sh.sha" "^${BASE_SHA}$"
has "conflict: the report says the sha was not advanced" "${rep}" 'REFUSED'
has "conflict: stdout says how to retry" "${c}/out.txt" 'run sync again'
file_is "conflict: files that did merge still moved" "${c}/tuned/common.sh" "${ROOT}/raw/${NEW_SHA}/tuned-common.sh"

# --- 5. no merge base recorded: overwrite, but keep the old content ---------------
c="$(new_consumer no_base none)"
conf 42 26 > "${c}/tuned/common-data/devices/gb10.conf"
run_sync "${c}"; rc=$?
rep="${c}/tuned/common.sh.sync-report"
want_rc "no base: exits 0" 0 "${rc}"
has "no base: the report says why it could not merge" "${rep}" '^updated +devices/gb10\.conf +-- no merge base'
has "no base: the report records the unknown base" "${rep}" '^base: +unknown$'
exists "no base: the previous local content is saved" "${c}/tuned/common-data/devices/gb10.conf.local-${NEW_SHA:0:7}"

# --- 6. local edits, upstream unchanged: kept, not reverted -----------------------
# Its own tree listing: at BASE_SHA there is no toolkits/cu134.env yet, and a listing
# has to describe the commit it claims to (case 9 covers one that does not).
cat > "${ROOT}/tree-base.json" <<'JSON'
{"tree":[{"type":"blob","path":"tuned-common.sh"},
         {"type":"blob","path":"devices/gb10.conf"},
         {"type":"blob","path":"devices/old.conf"}]}
JSON
c="$(new_consumer local_only)"
printf 'LOCAL=1\n' >> "${c}/tuned/common.sh"
cp "${c}/tuned/common.sh" "${ROOT}/want-local.sh"
( cd "${c}/tuned" && GPU_TUNED_SYNC_TREE_JSON="${ROOT}/tree-base.json" \
    bash ./sync-common.sh sync "${BASE_SHA}" ) > "${c}/out.txt" 2>&1; rc=$?
rep="${c}/tuned/common.sh.sync-report"
want_rc "local only: exits 0" 0 "${rc}"
has "local only: the report says kept" "${rep}" '^kept +tuned-common\.sh +-- local edits'
file_is "local only: the local edit survives" "${c}/tuned/common.sh" "${ROOT}/want-local.sh"

# --- 7. a fetched file that is not valid bash is refused, never installed ---------
BAD_SHA=3333333333333333333333333333333333333333
mkdir -p "${ROOT}/raw/${BAD_SHA}/devices" "${ROOT}/raw/${BAD_SHA}/toolkits"
printf '# lib v1\nf() { echo one; }\n' > "${ROOT}/raw/${BAD_SHA}/tuned-common.sh"
printf 'A=1\nif [ -z\n' > "${ROOT}/raw/${BAD_SHA}/devices/gb10.conf"   # unterminated
printf 'TOOLKIT_NCCL_VERSION=none\n' > "${ROOT}/raw/${BAD_SHA}/toolkits/cu134.env"
c="$(new_consumer bad_syntax)"
cp "${c}/tuned/common-data/devices/gb10.conf" "${ROOT}/want-untouched.conf"
( cd "${c}/tuned" && bash ./sync-common.sh sync "${BAD_SHA}" ) > "${c}/out.txt" 2>&1; rc=$?
rep="${c}/tuned/common.sh.sync-report"
want_rc "bad syntax: the run exits 1" 1 "${rc}"
has "bad syntax: the report says REFUSED" "${rep}" '^REFUSED +devices/gb10\.conf'
file_is "bad syntax: the local file is untouched" "${c}/tuned/common-data/devices/gb10.conf" "${ROOT}/want-untouched.conf"
has "bad syntax: the sha is NOT advanced" "${c}/tuned/common.sh.sha" "^${BASE_SHA}$"

# --- 8. rerunning after a resolved conflict completes the sync --------------------
c="$(new_consumer retry)"
conf 42 26 > "${c}/tuned/common-data/devices/gb10.conf"
run_sync "${c}" || true
cp "${ROOT}/raw/${NEW_SHA}/devices/gb10.conf" "${c}/tuned/common-data/devices/gb10.conf"   # resolved by taking upstream
run_sync "${c}"; rc=$?
rep="${c}/tuned/common.sh.sync-report"
want_rc "retry: the second run exits 0" 0 "${rc}"
has "retry: the resolved file is unchanged" "${rep}" '^unchanged +devices/gb10\.conf$'
has "retry: the sha is advanced now" "${c}/tuned/common.sh.sha" "^${NEW_SHA}$"

# --- 9. an aborted run still leaves the record of what it had done ----------------
# The listing names a file the raw endpoint does not have at that commit: the script
# refuses to guess, but the report must still say what happened before that.
cat > "${ROOT}/tree-bogus.json" <<'JSON'
{"tree":[{"type":"blob","path":"tuned-common.sh"},
         {"type":"blob","path":"devices/gb10.conf"},
         {"type":"blob","path":"devices/not-there.conf"}]}
JSON
c="$(new_consumer aborted)"
( cd "${c}/tuned" && GPU_TUNED_SYNC_TREE_JSON="${ROOT}/tree-bogus.json" \
    bash ./sync-common.sh sync "${NEW_SHA}" ) > "${c}/out.txt" 2>&1; rc=$?
rep="${c}/tuned/common.sh.sync-report"
want_rc "aborted: the run exits 1" 1 "${rc}"
has "aborted: it says what it refused to guess at" "${c}/out.txt" 'devices/not-there\.conf is listed'
exists "aborted: a report is still written" "${rep}"
has "aborted: the report says it aborted" "${rep}" '^result: ABORTED part-way'
has "aborted: and records the work it had already done" "${rep}" '^updated +tuned-common\.sh$'
has "aborted: the sha is NOT advanced" "${c}/tuned/common.sh.sha" "^${BASE_SHA}$"

echo
echo "passed=${PASS} failed=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
