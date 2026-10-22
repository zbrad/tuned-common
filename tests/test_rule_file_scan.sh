#!/bin/bash
# Tests for tools/rule_file_scan.sh on throwaway repos.
# Usage: bash tests/test_rule_file_scan.sh   (exit 0 = all pass)
set -uo pipefail
TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/rule_file_scan.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0; FAIL=0
W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT

check() {
    local name="$1" want_rc="$2" out_re="$3" script="$4" out rc ok=1
    out="$(mktemp)"
    bash -c "${script}" >"${out}" 2>&1; rc=$?
    [[ "${rc}" -eq "${want_rc}" ]] || ok=0
    if [[ "${out_re}" == "-" ]]; then [[ -z "$(grep -v '^dispatch: ' "${out}")" ]] || ok=0; else grep -qE "${out_re}" "${out}" || ok=0; fi
    if [[ "${ok}" -eq 1 ]]; then PASS=$((PASS+1)); echo "ok   - ${name}"
    else FAIL=$((FAIL+1)); echo "FAIL - ${name} (rc=${rc}, want ${want_rc})"; sed 's/^/     out: /' "${out}"; fi
    rm -f "${out}"
}

mk() { # mk <name> [fork]: a repo with one commit; "fork" adds an upstream remote
    local d="${W}/$1"; git init -q -b main "${d}"
    ( cd "${d}"; echo x > f; git add f; git commit -qm c0 ) >/dev/null 2>&1
    [[ "${2:-}" == "fork" ]] && git -C "${d}" remote add upstream "${W}/none.git"
    return 0
}

mk plain                                   # not a fork, has a CLAUDE.md: its own, normal
echo mine > "${W}/plain/CLAUDE.md"; git -C "${W}/plain" add CLAUDE.md
mk clean fork
mk dirty fork
mkdir -p "${W}/dirty/.cursor/rules"; echo a > "${W}/dirty/AGENTS.md"; echo b > "${W}/dirty/.cursor/rules/r.mdc"
git -C "${W}/dirty" add -A
mk homed fork
mkdir -p "${W}/homed/rules_advisory"; echo a > "${W}/homed/rules_advisory/AGENTS.md"; git -C "${W}/homed" add -A
mk loose fork
echo a > "${W}/loose/GEMINI.md"                                    # untracked, not ignored: loads too

check "here: a non-fork with its own CLAUDE.md is silent"               0 "-"                          "'${TOOL}' --here '${W}/plain'"
check "here: a clean fork is silent"                                    0 "-"                          "'${TOOL}' --here '${W}/clean'"
check "here: files under rules_advisory/ are not flagged"               0 "-"                          "'${TOOL}' --here '${W}/homed'"
check "here: a fork with loadable files warns, names them, exits 0"     0 "FORK RULE FILES: dirty.*2 upstream" "'${TOOL}' --here '${W}/dirty'"
check "here: an untracked loadable file counts"                         0 "FORK RULE FILES: loose.*1 upstream" "'${TOOL}' --here '${W}/loose'"
check "here: outside any repo is silent"                                0 "-"                          "'${TOOL}' --here '${W}'"
check "here: it names the files" 0 "^  AGENTS\\.md" "'${TOOL}' --here '${W}/dirty'"
check "here: it never prints file contents"                             0 "-" "! '${TOOL}' --here '${W}/dirty' | grep -q '^  *a\$'"
check "fleet: exit 1 and lists the dirty forks"                         1 "FILES +dirty" "'${TOOL}' --fleet '${W}'"
check "fleet: --quiet hides clean forks"                                1 "-" "'${TOOL}' --fleet --quiet '${W}' | grep -q 'clean'"
check "fleet: clean roots exit 0"                                       0 "ok +c " "mkdir -p '${W}/r2'; git clone -q '${W}/clean' '${W}/r2/c' >/dev/null 2>&1; git -C '${W}/r2/c' remote add upstream '${W}/none.git'; '${TOOL}' --fleet '${W}/r2'"

echo; echo "passed=${PASS} failed=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
