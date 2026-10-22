#!/bin/bash
# tools/migrate-fork-to-current.sh [--repo DIR] [--default-branch NAME] [--apply] [--retire-old]
#
# Moves one fork to the branch model in docs/UPSTREAM_SYNC.md ("Branches of a quarantined fork"):
#   upstream_mirror  a pure copy of upstream's default branch
#   current          upstream_mirror + the quarantine commit + the README fork notice;
#                    the fork's GitHub default, protected (pull request required, admins too)
# Dry run unless --apply: prints every check and the plan, changes nothing.
#
# --apply: creates upstream_mirror and current locally (current in a scratch worktree, so the
#          checkout is not disturbed), pushes both as NEW branches (plain push, never --force),
#          sets current as the GitHub default, protects it, sets origin/HEAD locally.
# --retire-old: also deletes the old mirror branch (the one named like upstream's default, e.g.
#          main/master) on origin and locally. Refused unless its tip is contained in
#          upstream_mirror and no pull request is open. The GitHub default is never deleted.
#
# The checkout itself is never touched (current is built in a scratch worktree), so a dirty tree
# does not matter.
# Needs DOTFILES_DIR (the quarantine script), gh authenticated, an `upstream` remote and a
# GitHub origin. Every step checks its own state, so a half-finished run can be re-run.
# Exit: 0 ok, 1 usage, 2 a check failed (nothing changed past that point).
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tuned-common.sh
source "${TOOL_DIR}/../tuned-common.sh"

REPO="."; DB=""; APPLY=0; RETIRE=0; MIRROR="upstream_mirror"; CUR="current"
die()  { echo "ERROR: $*" >&2; exit "${RC:-2}"; }
note() { echo "  $*"; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --default-branch) DB="$2"; shift 2 ;;
        --apply) APPLY=1; shift ;;
        --retire-old) RETIRE=1; shift ;;
        -h|--help) sed -n 2,20p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) RC=1 die "unknown option '$1' (see --help)" ;;
    esac
done

cd "${REPO}" || RC=1 die "no such directory: ${REPO}"
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || RC=1 die "not a git repository: ${REPO}"
cd "${TOP}"
echo "== repo: $(basename "${TOP}")"

echo "== checks"
git remote get-url upstream >/dev/null 2>&1 || die "no 'upstream' remote: not a fork"
git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote"
[[ "$(git rev-parse --is-shallow-repository)" == false ]] || die "shallow clone: git fetch --unshallow upstream first"
[[ -n "${DOTFILES_DIR:-}" && -x "${DOTFILES_DIR}/common/quarantine-instructions.sh" ]] ||
    die "DOTFILES_DIR is unset or lacks common/quarantine-instructions.sh"
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 || die "gh is missing or not authenticated"
SLUG="$(gpu_tuned_public_repo_url "$(git remote get-url origin)" | sed 's#^https://github.com/##')"
UP_SLUG="$(gpu_tuned_public_repo_url "$(git remote get-url upstream)" | sed 's#^https://github.com/##')"
parent="$(gh api "repos/${SLUG}" --jq '(.parent.id // empty | tostring)' 2>/dev/null || true)"
up_id="$(gh api "repos/${UP_SLUG}" --jq '.id | tostring' 2>/dev/null || true)"
[[ -n "${parent}" && "${parent}" == "${up_id}" ]] || die "GitHub's parent of ${SLUG} (id '${parent}') is not the upstream remote ${UP_SLUG} (id '${up_id:-unknown}')"
if [[ -z "${DB}" ]]; then
    DB="$(git symbolic-ref -q --short refs/remotes/upstream/HEAD 2>/dev/null | sed 's#^upstream/##' || true)"
    [[ -n "${DB}" ]] || DB="$(git ls-remote --symref upstream HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}' || true)"
    [[ -n "${DB}" ]] || die "cannot determine upstream's default branch; pass --default-branch"
fi
git fetch -q --no-recurse-submodules upstream "+refs/heads/${DB}:refs/remotes/upstream/${DB}" || die "cannot fetch upstream/${DB}"
GH_DEFAULT="$(gh api "repos/${SLUG}" --jq .default_branch)"
VIS="$(gh api "repos/${SLUG}" --jq .visibility)"
ACTIONS="$(gh api "repos/${SLUG}/actions/permissions" --jq .enabled 2>/dev/null || echo unknown)"
OPEN_PRS="$(gh pr list -R "${SLUG}" --state open --json number --jq length 2>/dev/null || echo unknown)"
remote_heads="$(git ls-remote --heads origin "${MIRROR}" "${CUR}" "${DB}")"
has_remote() { grep -q "refs/heads/$1\$" <<< "${remote_heads}"; }
note "fork ${SLUG} (${VIS}); upstream ${UP_SLUG} default '${DB}' at $(git rev-parse --short=10 "refs/remotes/upstream/${DB}")"
note "GitHub default branch now: ${GH_DEFAULT}; open PRs: ${OPEN_PRS}; Actions enabled: ${ACTIONS}"
[[ "${VIS}" != public || "${ACTIONS}" != true ]] || note "WARNING: Actions is enabled on a public fork; CLAUDE.md says it should be off (not changed here)"
for b in "${MIRROR}" "${CUR}"; do
    if has_remote "${b}"; then note "origin already has ${b}"; fi
done
if [[ "${GH_DEFAULT}" == "${DB}" ]]; then note "the GitHub default is the old mirror branch '${DB}'"; fi

echo "== plan"
note "1. ${MIRROR} = upstream/${DB} (local, then pushed as a new branch)"
note "2. ${CUR} = ${MIRROR} + quarantine commit + README fork notice (scratch worktree), pushed as a new branch"
note "3. GitHub default -> ${CUR}; protect ${CUR} (pull request required, enforce_admins, no force push or deletion)"
if [[ "${RETIRE}" -eq 1 ]]; then note "4. delete '${DB}' on origin and locally if contained in ${MIRROR} and no PR is open"; else note "4. (the old '${DB}' is kept; pass --retire-old to delete it)"; fi
[[ "${APPLY}" -eq 1 ]] || { echo "  (dry run: pass --apply)"; exit 0; }

echo "== apply"
if git rev-parse -q --verify "refs/heads/${MIRROR}" >/dev/null; then
    git fetch -q . "refs/remotes/upstream/${DB}:refs/heads/${MIRROR}" 2>/dev/null ||
        [[ "$(git rev-parse "refs/heads/${MIRROR}")" == "$(git rev-parse "refs/remotes/upstream/${DB}")" ]] ||
        die "local ${MIRROR} is not a fast-forward of upstream/${DB}; the mirror must stay pure"
else
    git branch "${MIRROR}" "refs/remotes/upstream/${DB}"
fi
note "local ${MIRROR} at $(git rev-parse --short=10 "refs/heads/${MIRROR}")"
if ! git rev-parse -q --verify "refs/heads/${CUR}" >/dev/null; then
    has_remote "${CUR}" && die "origin has ${CUR} but local does not: fetch it first (git fetch origin ${CUR}:${CUR})"
    wt="$(mktemp -d)"
    git worktree add -q -b "${CUR}" "${wt}/w" "${MIRROR}"
    bash "${TOOL_DIR}/upstream-sync.sh" quarantine --repo "${wt}/w" --branch "${CUR}" --default-branch "${DB}" --apply ||
        { git worktree remove --force "${wt}/w"; git branch -D "${CUR}" >/dev/null; die "quarantine failed; ${CUR} not created"; }
    git worktree remove --force "${wt}/w"
    rmdir "${wt}"
fi
note "local ${CUR} at $(git rev-parse --short=10 "refs/heads/${CUR}")"
git push origin "${MIRROR}:refs/heads/${MIRROR}" "${CUR}:refs/heads/${CUR}" 2>&1 | grep -v '^dispatch:' | sed 's/^/  push: /' || true
git ls-remote --heads origin "${MIRROR}" "${CUR}" | wc -l | grep -qx 2 || die "origin lacks ${MIRROR} or ${CUR} after the push"
git branch -q --set-upstream-to="origin/${MIRROR}" "${MIRROR}" 2>/dev/null || true
git branch -q --set-upstream-to="origin/${CUR}" "${CUR}" 2>/dev/null || true
if [[ "${GH_DEFAULT}" != "${CUR}" ]]; then
    gh api -X PATCH "repos/${SLUG}" -f default_branch="${CUR}" --jq .default_branch | sed 's/^/  default branch -> /'
fi
gh api -X PUT "repos/${SLUG}/branches/${CUR}/protection" --jq .url --input - <<'EOF' | sed 's/^/  protected: /'
{"required_status_checks":null,"enforce_admins":true,"required_pull_request_reviews":{"required_approving_review_count":0},"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}
EOF
git fetch -q --no-recurse-submodules origin
git remote set-head origin -a >/dev/null

if [[ "${RETIRE}" -eq 1 ]]; then
    echo "== retire '${DB}'"
    [[ "${DB}" != "${CUR}" && "${DB}" != "${MIRROR}" ]] || die "refusing: '${DB}' is one of the new branches"
    [[ "$(gh api "repos/${SLUG}" --jq .default_branch)" == "${CUR}" ]] || die "refusing: the GitHub default is not ${CUR}"
    [[ "${OPEN_PRS}" == 0 ]] || die "refusing: ${OPEN_PRS} open PR(s) (unknown counts as unsafe)"
    if has_remote "${DB}"; then
        git fetch -q --no-recurse-submodules origin "+refs/heads/${DB}:refs/remotes/origin/${DB}"
        git merge-base --is-ancestor "refs/remotes/origin/${DB}" "refs/heads/${MIRROR}" || die "refusing: origin/${DB} has commits ${MIRROR} lacks"
        git push origin --delete "${DB}" 2>&1 | grep -v '^dispatch:' | sed 's/^/  push: /' || true
        [[ -z "$(git ls-remote --heads origin "${DB}")" ]] || die "origin still has '${DB}' after the delete; local '${DB}' left alone"
    else
        note "origin has no '${DB}'"
    fi
    if git rev-parse -q --verify "refs/heads/${DB}" >/dev/null; then
        if [[ "$(git symbolic-ref -q --short HEAD || true)" == "${DB}" ]]; then note "local ${DB} is checked out; left"
        elif git merge-base --is-ancestor "refs/heads/${DB}" "refs/heads/${MIRROR}"; then git branch -q -D "${DB}"; note "deleted local ${DB}"
        else note "local ${DB} has commits ${MIRROR} lacks; left"; fi
    fi
    git fetch -q --no-recurse-submodules --prune origin
fi
echo "== done (nothing else pushed). Next: sync ${MIRROR} with 'upstream-sync.sh sync-default', update ${CUR} by pull request."
