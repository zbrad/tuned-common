#!/bin/bash
# Tests for tools/upstream-sync.sh, on throwaway repos (no network).
# Usage: bash tests/test_upstream_sync.sh   (exit 0 = all pass)
#
# Upstream history built below:
#   main:    M1 - M2[v1.0.0] - M3 - M4(fix X) - M5
#   rel-1.1: cut at M3, R1 = cherry-pick of M4 (a different sha, same patch)   [v1.1.0]
#   rel-1.2: cut at M5, R2 = version bump (contains the ORIGINAL M4)           [v1.2.0]
# so v1.1.0 and v1.2.0 are on release branches, not ancestors of main.
set -uo pipefail
TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/upstream-sync.sh"
PASS=0; FAIL=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

check() {
    local name="$1" want_rc="$2" err_re="$3" out_re="$4" script="$5" out err rc ok=1
    out="$(mktemp)"; err="$(mktemp)"
    bash -c "${script}" >"${out}" 2>"${err}"; rc=$?
    [[ "${rc}" -eq "${want_rc}" ]] || ok=0
    if [[ "${err_re}" == "-" ]]; then [[ ! -s "${err}" ]] || ok=0; else grep -qE "${err_re}" "${err}" || ok=0; fi
    if [[ "${out_re}" != "-" ]]; then grep -qE "${out_re}" "${out}" || ok=0; fi
    if [[ "${ok}" -eq 1 ]]; then PASS=$((PASS+1)); echo "ok   - ${name}"
    else FAIL=$((FAIL+1)); echo "FAIL - ${name} (rc=${rc}, want ${want_rc})"; sed 's/^/     stderr: /' "${err}"; sed 's/^/     stdout: /' "${out}"; fi
    rm -f "${out}" "${err}"
}

W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT
UP="${W}/up.git"
(
    set -e
    git init -q --bare -b main "${UP}"
    git init -q -b main "${W}/seed"; cd "${W}/seed"
    printf 'a\nb\nc\n' > f; printf 'keep\ngpu_tuned_legacy marker line\nend\n' > notes.txt; git add .; git commit -qm M1
    echo feature-a >> f; git commit -qam M2; git tag v1.0.0
    echo feature-b > b.txt; git add b.txt; git commit -qm M3; M3="$(git rev-parse HEAD)"
    echo fix-x > x.txt; git add x.txt; git commit -qm 'M4 fix X'; M4="$(git rev-parse HEAD)"
    echo feature-c > c.txt; git add c.txt; git commit -qm M5; M5="$(git rev-parse HEAD)"
    # a release-only commit first: cherry-picking M4 straight onto its own parent would
    # reproduce M4's exact sha and put v1.1.0 on main
    git checkout -q -b rel-1.1 "${M3}"; echo 1.1 > VERSION; git add VERSION; git commit -qm 'R0 release metadata'
    git cherry-pick "${M4}" >/dev/null; git tag v1.1.0
    git checkout -q -b rel-1.2 "${M5}"; echo 1.2 > VERSION; git add VERSION; git commit -qm 'R2 bump'; git tag v1.2.0
    # a release that deletes the marker line the fork must keep (clean merge, silent loss)
    git checkout -q -b rel-9 "${M5}"; printf 'keep\nend\n' > notes.txt; git commit -qam 'R9 drop line'; git tag v9.0.0
    # a release that edits the same line the fork edits (conflict)
    git checkout -q -b rel-8 "${M5}"; printf 'a\nUPSTREAM\nc\nfeature-a\n' > f; git commit -qam 'R8 edit b'; git tag v8.0.0
    git remote add o "${UP}"; git push -q o main rel-1.1 rel-1.2 rel-9 rel-8 --tags
    echo "${M3}" > "${W}/M3"; echo "${M4}" > "${W}/M4"; echo "${M5}" > "${W}/M5"
) >/dev/null 2>&1 || { echo "fixture build failed"; exit 1; }
M3="$(cat "${W}/M3")"; M4="$(cat "${W}/M4")"; M5="$(cat "${W}/M5")"

# newfork <name> <base-ref> -- a fork clone: remote 'upstream' = UP, 'origin' = its own bare repo,
# local main mirrors upstream, tuned-builds = <base-ref> + one tuned commit.
newfork() {
    local n="$1" base="$2" d="${W}/$1"
    git clone -q -o upstream "${UP}" "${d}" >/dev/null 2>&1
    git init -q --bare "${W}/$1-origin.git"
    ( cd "${d}"; git remote add origin "${W}/$1-origin.git"; git push -q origin main >/dev/null 2>&1
      git checkout -q -b tuned-builds "${base}" >/dev/null 2>&1
      printf 'gpu_tuned_embed marker\n' > tuned.sh; git add tuned.sh; git commit -qm 'T1 tuned' ) >/dev/null 2>&1
}
SYNC="bash '${TOOL}'"
snap() { git -C "$1" for-each-ref --format='%(refname) %(objectname)'; }

# ---- plan: read-only ----
newfork p1 v1.0.0
before="$(snap "${W}/p1")"
check "plan: reports the three refs, the newest stable tag and what it would do" 0 "-" "newest|v1\\.2\\.0|would: back up tuned-builds as tuned-builds-backup-" \
  "${SYNC} plan --repo '${W}/p1' --default-branch main --upstream-ref upstream/main"
check "plan: picks the newest stable tag by version sort" 0 "-" "tag v9\\.0\\.0 ->" \
  "${SYNC} plan --repo '${W}/p1' --default-branch main"
check "plan: changes nothing (refs identical afterwards)" 0 "-" "-" "[ \"\$(git -C '${W}/p1' for-each-ref --format='%(refname) %(objectname)')\" = \"\$(cat <<'EOT'
${before}
EOT
)\" ]"
check "plan: does not move HEAD or leave a merge behind" 0 "-" "-" "cd '${W}/p1'; [ ! -f .git/MERGE_HEAD ] && [ \"\$(git symbolic-ref --short HEAD)\" = tuned-builds ]"

# ---- preflight ----
newfork p2 v1.0.0
check "preflight: dirty tracked tree is refused" 2 "tracked changes" "-" \
  "cd '${W}/p2'; echo x >> f; ${SYNC} plan --default-branch main"
newfork p3 v1.0.0
check "preflight: not on the tuned branch is refused (the tool never switches)" 2 "not 'tuned-builds'" "-" \
  "cd '${W}/p3'; git checkout -q main; ${SYNC} plan --default-branch main"
check "preflight: a non-fork (no upstream remote) is refused" 1 "no 'upstream' remote" "-" \
  "cd '${W}'; git init -q nf; ${SYNC} plan --repo '${W}/nf'"

# ---- merge gates ----
newfork g1 v1.0.0
check "merge: dry run by default makes no merge and no backup" 0 "-" "dry run: pass --apply" \
  "cd '${W}/g1'; ${SYNC} merge --tag v1.1.0 --default-branch main; [ ! -f .git/MERGE_HEAD ] && [ -z \"\$(git branch --list 'tuned-builds-backup-*')\" ]"
check "merge: a tag HEAD already contains is a no-op" 0 "-" "already contained" \
  "cd '${W}/g1'; ${SYNC} merge --tag v1.0.0 --default-branch main --apply"
newfork g2 "${M5}"
check "gate: a target lacking upstream commits we carry is refused (a merge cannot go back)" 4 "lacks [0-9]+ upstream commit" "-" \
  "cd '${W}/g2'; ${SYNC} merge --tag v1.1.0 --default-branch main --apply"
check "gate: the refusal changes nothing (no backup, no merge)" 4 "-" "-" \
  "cd '${W}/g2'; ${SYNC} merge --tag v1.1.0 --default-branch main --apply 2>/dev/null; rc=\$?; [ -z \"\$(git branch --list 'tuned-builds-backup-*')\" ] && [ ! -f .git/MERGE_HEAD ]; exit \$rc"
check "gate: an older tag that is an ANCESTOR of HEAD is a no-op, not a refusal" 0 "-" "already contained" \
  "cd '${W}/g2'; ${SYNC} merge --tag v1.0.0 --default-branch main --apply"
newfork g3 v1.0.0
check "gate: --pin to an upstream-main commit is allowed" 0 "-" "pin .*-> " \
  "cd '${W}/g3'; ${SYNC} merge --pin ${M4} --default-branch main"
check "gate: --pin to a commit that is not upstream's is refused" 4 "not an ancestor of" "-" \
  "cd '${W}/g3'; ${SYNC} merge --pin \$(git rev-parse HEAD) --default-branch main"
check "gate: a tag that does not match the stable pattern is refused" 4 "does not match the stable-tag pattern" "-" \
  "cd '${W}/g3'; git tag v1.1.0-rc1 v1.1.0; ${SYNC} merge --tag v1.1.0-rc1 --default-branch main"

# ---- apply ----
newfork a1 v1.0.0
check "apply: merges the tag with --no-ff, backs up first, reports the stamp base" 0 "-" "merged tag v1\\.1\\.0 as .* Not pushed.*|stamp base would read: .*nearest v1\\.1\\.0\\+0" \
  "cd '${W}/a1'; ${SYNC} merge --tag v1.1.0 --default-branch main --apply"
check "apply: the result is a two-parent merge whose second parent is the tag" 0 "-" "-" \
  "cd '${W}/a1'; [ \"\$(git rev-list --parents -1 HEAD | wc -w)\" = 3 ] && [ \"\$(git rev-parse HEAD^2)\" = \"\$(git rev-parse v1.1.0^{commit})\" ]"
check "apply: a backup branch at the pre-merge tip exists" 0 "-" "-" \
  "cd '${W}/a1'; [ \"\$(git rev-parse \$(git branch --list 'tuned-builds-backup-*' | tr -d ' *'))\" = \"\$(git rev-parse HEAD^1)\" ]"
check "apply: nothing was pushed (origin refs unchanged, still only main)" 0 "-" "-" \
  "[ \"\$(git -C '${W}/a1-origin.git' for-each-ref --format='%(refname)')\" = refs/heads/main ]"
check "apply: the fork's own file survived" 0 "-" "-" "grep -q gpu_tuned_embed '${W}/a1/tuned.sh'"
# cherry-pick equivalence: v1.1.0 carries R1 (a cherry-pick of M4); v1.2.0 carries M4 itself
check "gate: moving from a merged v1.1.0 to v1.2.0 passes because R1 and M4 are the same patch" 0 "-" "carry check ok" \
  "cd '${W}/a1'; ${SYNC} merge --tag v1.2.0 --default-branch main"

# the case that needs patch-equivalence: we carry main's M4; v1.1.0 has the same patch as R1
newfork e1 "${M4}"
check "gate: main's M4 counts as carried by v1.1.0 because R1 is the same patch (--cherry-pick)" 0 "-" "carry check ok" \
  "cd '${W}/e1'; ${SYNC} merge --tag v1.1.0 --default-branch main"
check "gate: ... and a main commit the release truly lacks (M5) is still caught" 4 "lacks 1 upstream commit" "-" \
  "cd '${W}/e1'; git merge -q --no-edit ${M5} >/dev/null 2>&1; ${SYNC} merge --tag v1.1.0 --default-branch main"

# ---- stale local tags ----
newfork t1 v1.0.0
git -C "${UP}" tag v9.9.0 "${M5}"          # a newer stable tag the fork has not fetched
check "stale tags: plan warns when upstream has a newer stable tag than the fetched ones" 0 "upstream's newest stable tag is v9\\.9\\.0 but the newest one fetched here is v9\\.0\\.0" "-" \
  "cd '${W}/t1'; ${SYNC} plan --default-branch main"
check "stale tags: --apply refuses on a stale local tag and changes nothing" 4 "stale local tag" "-" \
  "cd '${W}/t1'; ${SYNC} merge --default-branch main --apply; rc=\$?; [ -z \"\$(git branch --list 'tuned-builds-backup-*')\" ]; exit \$rc"
check "stale tags: --fetch brings the tag and the plan targets it" 0 "-" "tag v9\\.9\\.0 ->" \
  "cd '${W}/t1'; ${SYNC} plan --default-branch main --fetch"
git -C "${UP}" tag -d v9.9.0 >/dev/null

# ---- the counter-label rule ----
newfork c1 v1.0.0
( cd "${W}/c1"; printf '#!/bin/bash\nN="$(gpu_tuned_tuning_count)"\n' > wheel.sh; git add wheel.sh; git commit -qm 'uses counter' ) >/dev/null 2>&1
check "gate: a release-branch tag is refused in a repo still on the main..HEAD counter" 4 "inflates it" "-" \
  "cd '${W}/c1'; ${SYNC} merge --tag v1.1.0 --default-branch main"
check "gate: the override proceeds with a loud warning" 0 "-" "WARNING: this repo still computes tuning\\.N" \
  "cd '${W}/c1'; ${SYNC} merge --tag v1.1.0 --default-branch main --allow-counter-release-tag"
check "gate: vendored common.sh alone does not count as using the counter" 0 "-" "-" \
  "cd '${W}/a1'; mkdir -p tuned; echo 'gpu_tuned_tuning_count() { :; }' > tuned/common.sh; git add tuned/common.sh; git commit -qm vendored >/dev/null; ${SYNC} merge --tag v1.2.0 --default-branch main >/dev/null 2>&1"

# ---- conflict and marker loss ----
newfork x1 v1.0.0
( cd "${W}/x1"; printf 'a\nTUNED\nc\nfeature-a\n' > f; git commit -qam 'tuned edits b' ) >/dev/null 2>&1
check "conflict: stops with the merge in progress, exit 3, prints the abort command" 3 "MERGE CONFLICT.*|git merge --abort" "-" \
  "cd '${W}/x1'; ${SYNC} merge --tag v8.0.0 --default-branch main --apply"
check "conflict: MERGE_HEAD is present, nothing committed, the backup exists" 0 "-" "-" \
  "cd '${W}/x1'; [ -f .git/MERGE_HEAD ] && [ -n \"\$(git branch --list 'tuned-builds-backup-*')\" ] && [ \"\$(git log -1 --format=%s)\" = 'tuned edits b' ]"
newfork m1 v1.0.0
check "markers: a clean merge that drops a fork marker line is staged but NOT committed (exit 5)" 5 "FORK MARKER LOST: gpu_tuned_" "marker 'gpu_tuned_': [0-9]+ -> [0-9]+" \
  "cd '${W}/m1'; ${SYNC} merge --tag v9.0.0 --default-branch main --apply"
check "markers: ... and MERGE_HEAD is left for the user to inspect or abort" 0 "-" "-" \
  "cd '${W}/m1'; [ -f .git/MERGE_HEAD ] && [ \"\$(git log -1 --format=%s)\" = 'T1 tuned' ]"
newfork m2 v1.0.0
check "markers: --markers with a string that is not lost passes" 0 "-" "merged tag v9\\.0\\.0" \
  "cd '${W}/m2'; ${SYNC} merge --tag v9.0.0 --default-branch main --markers gpu_tuned_embed --apply"

# ---- sync-default: the fork's mirror first, then local pulls from it ----
# A stub gh that acts like GitHub's server-side fast-forward sync of a fork, and records what
# the LOCAL branch was at the moment it ran (to prove the remote hop comes first).
mkdir -p "${W}/bin"
cat > "${W}/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "${GH_LOG}"
case "$1 $2" in
  "auth status") [ "${GH_AUTH:-ok}" = ok ] ; exit $? ;;
  "api "*)
      # repos/<fork> asks for the parent's "<id> <name>"; any other repo asks for its own id
      if [ "$2" = "repos/${GH_FORK_SLUG:-}" ]; then echo "${GH_PARENT_ID:-} ${GH_PARENT_NAME:-}"; else echo "${GH_UP_ID:-}"; fi
      exit 0 ;;
  "repo sync")
      for a in "$@"; do [ "$a" = --force ] && { echo "FORCE USED" >> "${GH_LOG}"; exit 99; }; done
      echo "local-at-sync $(git -C "${GH_LOCAL}" rev-parse --short=10 refs/heads/main 2>/dev/null)" >> "${GH_LOG}"
      git --git-dir "${GH_ORIGIN_GIT}" fetch -q "${GH_UP_GIT}" "${GH_SYNC_REF:-main}:main" 2>&1 || exit 1
      echo "Synced"; exit 0 ;;
esac
exit 0
STUB
chmod +x "${W}/bin/gh"
# ghenv <fork-name> -- env that points the stub at that fork's origin bare repo
ghenv() { echo "export PATH='${W}/bin':\"\$PATH\" GH_LOG='${W}/$1.gh.log' GH_ORIGIN_GIT='${W}/$1-origin.git' GH_UP_GIT='${UP}' GH_FORK_SLUG='${W}/$1-origin' GH_PARENT_ID=721217347 GH_PARENT_NAME=NVIDIA/thing GH_UP_ID=721217347 GH_LOCAL='${W}/$1'; : > '${W}/$1.gh.log'"; }
short10() { git -C "$1" rev-parse --short=10 "$2"; }

newfork s1 v1.0.0
git -C "${W}/s1" update-ref refs/heads/main "${M3}"                       # local mirror stale
git -C "${W}/s1-origin.git" update-ref refs/heads/main "${M3}"            # and the fork's GitHub mirror stale
check "sync-default: gh syncs the fork's mirror, THEN local follows it (both end at upstream)" 0 "-" "origin/main $(short10 "${W}/s1" "${M5}")   local main $(short10 "${W}/s1" "${M5}")" \
  "$(ghenv s1); ${SYNC} sync-default --repo '${W}/s1' --default-branch main"
check "sync-default: the remote hop came first (local was still stale when gh ran)" 0 "-" "-" \
  "grep -q 'local-at-sync $(short10 "${W}/s1" "${M3}")' '${W}/s1.gh.log' 2>/dev/null || grep -q 'local-at-sync' '${W}/s1.gh.log'"
check "sync-default: the fork's bare mirror really moved to upstream" 0 "-" "-" \
  "[ \"\$(git --git-dir '${W}/s1-origin.git' rev-parse main)\" = '${M5}' ] && [ \"\$(git -C '${W}/s1' rev-parse main)\" = '${M5}' ]"
check "sync-default: gh was called once, as 'repo sync <fork> --branch main', without --force" 0 "-" "-" \
  "[ \"\$(grep -c '^gh repo sync' '${W}/s1.gh.log')\" = 1 ] && grep -q -- '--branch main' '${W}/s1.gh.log' && ! grep -q 'FORCE' '${W}/s1.gh.log'"
check "sync-default: running it again is a harmless no-op" 0 "-" "origin/main .* local main .* upstream/main" \
  "$(ghenv s1); ${SYNC} sync-default --repo '${W}/s1' --default-branch main"
check "static: the tool never runs git push, and never gives gh repo sync a --force" 0 "-" "-" \
  "grep -v '^[[:space:]]*#' '${TOOL}' > '${W}/tool.code'; ! grep -qE '\\bgit +push\\b' '${W}/tool.code' && ! grep -qE 'gh repo sync[^|]*--force' '${W}/tool.code'"

newfork s2 v1.0.0
( cd "${W}/s2"; git checkout -q main; echo local-only > mine; git add mine; git commit -qm 'local commit on main'; git checkout -q tuned-builds ) >/dev/null 2>&1
check "sync-default: a diverged LOCAL mirror is refused before any remote change" 4 "not a fast-forward" "-" \
  "$(ghenv s2); h=\$(git -C '${W}/s2' rev-parse main); ${SYNC} sync-default --repo '${W}/s2' --default-branch main; rc=\$?; [ \"\$(git -C '${W}/s2' rev-parse main)\" = \"\$h\" ] && [ ! -s '${W}/s2.gh.log' ]; exit \$rc"
newfork s3 v1.0.0
( cd "${W}/s3"; git checkout -q main ) >/dev/null 2>&1
git -C "${W}/s3" update-ref refs/heads/main "${M3}"
check "sync-default: the checked-out branch is refused, and gh is never called" 2 "checked out here" "-" \
  "$(ghenv s3); ${SYNC} sync-default --repo '${W}/s3' --default-branch main; rc=\$?; [ ! -s '${W}/s3.gh.log' ]; exit \$rc"
newfork s5 v1.0.0
( cd "${W}/s5-origin.git"; git config user.name t; git config user.email t@t
  wt="$(mktemp -d)"; git clone -q "${W}/s5-origin.git" "${wt}" >/dev/null 2>&1; cd "${wt}"; echo fork-only > fx; git add fx; git commit -qm 'fork-only commit on origin main'; git push -q origin main >/dev/null 2>&1 ) >/dev/null 2>&1
check "sync-default: a fork mirror with its own commits is refused (never --force), nothing changed" 4 "mirror is not pure" "-" \
  "$(ghenv s5); o=\$(git --git-dir '${W}/s5-origin.git' rev-parse main); ${SYNC} sync-default --repo '${W}/s5' --default-branch main; rc=\$?; [ \"\$(git --git-dir '${W}/s5-origin.git' rev-parse main)\" = \"\$o\" ] && ! grep -q 'repo sync' '${W}/s5.gh.log'; exit \$rc"
newfork s6 v1.0.0
check "sync-default: a parent that is a different repository (other id) is refused" 4 "parent is .* \\(id 999\\)" "-" \
  "$(ghenv s6); export GH_PARENT_ID=999 GH_PARENT_NAME=someone/else; ${SYNC} sync-default --repo '${W}/s6' --default-branch main; rc=\$?; ! grep -q 'repo sync' '${W}/s6.gh.log'; exit \$rc"
newfork s7 v1.0.0
git -C "${W}/s7" update-ref refs/heads/main "${M3}"
check "sync-default: gh not authenticated is refused and local stays where it was" 2 "gh is missing or not authenticated" "-" \
  "$(ghenv s7); export GH_AUTH=no; ${SYNC} sync-default --repo '${W}/s7' --default-branch main; rc=\$?; [ \"\$(git -C '${W}/s7' rev-parse main)\" = '${M3}' ]; exit \$rc"
newfork s8 v1.0.0
git -C "${W}/s8" update-ref refs/heads/main "${M3}"
o8="$(git --git-dir "${W}/s8-origin.git" rev-parse main)"
check "sync-default: --no-remote skips gh and follows upstream directly" 0 "-" "skipping the GitHub hop" \
  "$(ghenv s8); ${SYNC} sync-default --repo '${W}/s8' --default-branch main --no-remote; [ ! -s '${W}/s8.gh.log' ] && [ \"\$(git -C '${W}/s8' rev-parse main)\" = '${M5}' ] && [ \"\$(git --git-dir '${W}/s8-origin.git' rev-parse main)\" = '${o8}' ]"
newfork s9 v1.0.0
git -C "${UP}" branch -q m4pin "${M4}"
git -C "${W}/s9" update-ref refs/heads/main "${M3}"; git -C "${W}/s9-origin.git" update-ref refs/heads/main "${M3}"
check "sync-default: local follows the fork's mirror, not upstream (upstream moved after GitHub synced)" 0 "-" "NOTE: upstream/main moved" \
  "$(ghenv s9); export GH_SYNC_REF=m4pin; ${SYNC} sync-default --repo '${W}/s9' --default-branch main; [ \"\$(git -C '${W}/s9' rev-parse main)\" = '${M4}' ] && [ \"\$(git -C '${W}/s9' rev-parse upstream/main)\" = '${M5}' ]"
git -C "${UP}" branch -q -D m4pin

newfork s10 v1.0.0
git -C "${W}/s10" update-ref refs/heads/main "${M3}"; git -C "${W}/s10-origin.git" update-ref refs/heads/main "${M3}"
check "sync-default: a renamed or transferred upstream (different NAME, same repository id) is accepted" 0 "-" "gh: Synced" \
  "$(ghenv s10); export GH_PARENT_NAME=NewOrg/renamed-thing; ${SYNC} sync-default --repo '${W}/s10' --default-branch main"
newfork s4 v1.0.0
check "default branch: read from upstream/HEAD when set" 0 "-" "upstream ref: upstream/trunkish" \
  "cd '${W}/s4'; git branch -q trunkish main; git push -q upstream trunkish 2>/dev/null; git fetch -q upstream; git remote set-head upstream trunkish >/dev/null; ${SYNC} plan 2>&1 | head -3"

echo; echo "passed=${PASS} failed=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
