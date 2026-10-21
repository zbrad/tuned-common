#!/bin/bash
# Tests for tools/migrate-fork-to-current.sh on throwaway repos, with a stub gh (no network).
# Usage: bash tests/test_migrate_fork.sh   (exit 0 = all pass)
set -uo pipefail
TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/migrate-fork-to-current.sh"
export DOTFILES_DIR="${DOTFILES_DIR:-$HOME/gh/dotfiles}"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0; FAIL=0
W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT

check() {
    local name="$1" want_rc="$2" err_re="$3" out_re="$4" script="$5" out err rc ok=1
    out="$(mktemp)"; err="$(mktemp)"
    bash -c "${script}" >"${out}" 2>"${err}"; rc=$?
    [[ "${rc}" -eq "${want_rc}" ]] || ok=0
    if [[ "${err_re}" == "-" ]]; then [[ -z "$(grep -v '^dispatch: ' "${err}")" ]] || ok=0; else grep -qE "${err_re}" "${err}" || ok=0; fi
    if [[ "${out_re}" != "-" ]]; then grep -qE "${out_re}" "${out}" || ok=0; fi
    if [[ "${ok}" -eq 1 ]]; then PASS=$((PASS+1)); echo "ok   - ${name}"
    else FAIL=$((FAIL+1)); echo "FAIL - ${name} (rc=${rc}, want ${want_rc})"; sed 's/^/     stderr: /' "${err}"; sed 's/^/     stdout: /' "${out}"; fi
    rm -f "${out}" "${err}"
}

# stub gh: answers what the tool asks; state lives in $GH_STATE
mkdir -p "${W}/bin"
cat > "${W}/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "${GH_STATE}/log"
all="$*"
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr list") echo "${GH_PRS:-0}"; exit 0 ;;
esac
if [[ "$all" == *"-X PATCH"* ]]; then echo current > "${GH_STATE}/default"; git --git-dir "${GH_ORIGIN}" symbolic-ref HEAD refs/heads/current; echo current; exit 0; fi
if [[ "$all" == *"-X PUT"* ]]; then cat > "${GH_STATE}/protection"; echo "https://api.github.com/protection"; exit 0; fi
if [[ "$all" == *actions/permissions* ]]; then echo false; exit 0; fi
if [[ "$all" == *".default_branch"* ]]; then cat "${GH_STATE}/default"; exit 0; fi
if [[ "$all" == *".visibility"* ]]; then echo public; exit 0; fi
echo 4242   # parent id, and the upstream's id
STUB
chmod +x "${W}/bin/gh"

UP="${W}/up.git"
(
    set -e; git init -q --bare -b main "${UP}"; git clone -q "${UP}" "${W}/seed" 2>/dev/null; cd "${W}/seed"; git checkout -q -b main
    printf '# Proj\nbody\n' > README.md; echo upstream-rules > CLAUDE.md; git add -A; git commit -qm c1; git push -q origin main
) >/dev/null 2>&1

newfork() {
    local n="$1"
    git clone -q -o upstream "${UP}" "${W}/$n" >/dev/null 2>&1
    git init -q --bare "${W}/$n-origin.git"
    mkdir -p "${W}/$n.state"; echo main > "${W}/$n.state/default"
    ( cd "${W}/$n"; git remote add origin "${W}/$n-origin.git"; git push -q origin main >/dev/null 2>&1; git checkout -q -b work ) >/dev/null 2>&1
}
env_for() { echo "export PATH='${W}/bin':\"\$PATH\" GH_STATE='${W}/$1.state' GH_ORIGIN='${W}/$1-origin.git' GH_PRS=${2:-0}"; }
MIG="bash '${TOOL}'"
heads() { git --git-dir "${W}/$1-origin.git" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' '; }
export -f heads; export W

newfork a
check "dry run prints the plan and changes nothing" 0 "-" "dry run" \
  "$(env_for a); cd '${W}/a'; ${MIG} --default-branch main; [ \"\$(cat '${W}/a.state/default')\" = main ] && [ \"\$(git --git-dir '${W}/a-origin.git' for-each-ref refs/heads | wc -l)\" = 1 ] && ! git rev-parse -q --verify current"
check "apply: creates upstream_mirror and current on origin, sets the default, protects current" 0 "-" "default branch -> current" \
  "$(env_for a); cd '${W}/a'; ${MIG} --default-branch main --apply && [ \"\$(cat '${W}/a.state/default')\" = current ] && grep -q '\"enforce_admins\":true' '${W}/a.state/protection' && [ \"\$(heads a)\" = 'current main upstream_mirror ' ]"
check "apply: current has the rule file moved, the notice on top, and sits on the mirror" 0 "-" "-" \
  "cd '${W}/a'; t=\$(git --git-dir '${W}/a-origin.git' rev-parse current); git --git-dir '${W}/a-origin.git' show current:rules_advisory/CLAUDE.md >/dev/null && ! git --git-dir '${W}/a-origin.git' cat-file -e current:CLAUDE.md 2>/dev/null && [ \"\$(git --git-dir '${W}/a-origin.git' show current:README.md | sed -n 1p)\" = '<!-- fork-notice -->' ] && git --git-dir '${W}/a-origin.git' merge-base --is-ancestor upstream_mirror current && [ \"\$(git --git-dir '${W}/a-origin.git' rev-parse upstream_mirror)\" = \"\$(git rev-parse upstream/main)\" ]"
check "apply again is harmless" 0 "-" "origin already has current" \
  "$(env_for a); cd '${W}/a'; ${MIG} --default-branch main --apply"
check "retire-old deletes main on origin and locally; current and upstream_mirror stay" 0 "-" "== retire" \
  "$(env_for a); cd '${W}/a'; ${MIG} --default-branch main --apply --retire-old && [ \"\$(heads a)\" = 'current upstream_mirror ' ] && ! git rev-parse -q --verify refs/heads/main"

newfork b
check "retire-old is refused while a PR is open" 2 "refusing: 2 open PR" "-" \
  "$(env_for b 2); cd '${W}/b'; ${MIG} --default-branch main --apply --retire-old"
newfork c
check "retire-old is refused when origin's old branch has commits the mirror lacks" 2 "refusing: origin/main has commits" "-" \
  "$(env_for c); cd '${W}/c'; git checkout -q main; echo extra > extra.txt; git add extra.txt; git commit -qm extra; git push -q origin main; git checkout -q work; ${MIG} --default-branch main --apply --retire-old"
newfork d
check "missing DOTFILES_DIR is refused before anything changes" 2 "DOTFILES_DIR" "-" \
  "$(env_for d); unset DOTFILES_DIR; cd '${W}/d'; ${MIG} --default-branch main --apply; r=\$?; [ \"\$(heads d)\" = 'main ' ] || exit 9; exit \$r"
newfork e
check "a dirty tree is refused" 2 "not clean" "-" \
  "$(env_for e); cd '${W}/e'; echo x > dirty.txt; git add dirty.txt; ${MIG} --default-branch main --apply"

echo; echo "passed=${PASS} failed=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
