#!/bin/bash
# tools/upstream-sync.sh <plan|sync-default|merge> [options]
#
# Brings a tuned fork up to a named upstream point. Read the policy and the reasons
# in docs/UPSTREAM_SYNC.md. Nothing here ever pushes, forces, or deletes.
#
#   plan          (default) read-only report: the default-branch mirror state, the
#                 chosen target, every gate, and what --apply would do.
#   sync-default  fast-forward the LOCAL default branch to upstream's. Fetch +
#                 fast-forward only. Prints the second hop (origin) instead of doing it.
#   merge         merge a named upstream tag (--tag) or an upstream-main commit (--pin)
#                 into the tuned branch. Dry run unless --apply.
#
# Options:
#   --repo DIR              repo to act on (default: current directory)
#   --branch NAME           the tuned branch (default tuned-builds); never switched to
#   --default-branch NAME   upstream's default branch (default: upstream/HEAD, else asked
#                           of the upstream remote and said so)
#   --upstream-ref REF      what "upstream" means for gates and the stamp
#                           (default upstream/<default-branch>; env GPU_TUNED_UPSTREAM_REF)
#   --tag-re REGEX          stable-tag pattern (env GPU_TUNED_UPSTREAM_TAG_RE,
#                           default '^v[0-9]+\.[0-9]+\.[0-9]+$')
#   --tag-glob GLOB         the tags to FETCH, one '*' only as in a refspec (default 'v*';
#                           never --tags, pytorch has ~12k CI tags)
#   --markers A,B,..        fork-local strings that must survive a merge (env
#                           GPU_TUNED_FORK_MARKERS, default 'gpu_tuned_')
#   --tag TAG | --pin SHA   the merge target (default for plan: newest stable local tag)
#   --fetch                 fetch the default branch and the stable tags first
#   --apply                 (merge) really merge; creates <branch>-backup-<date> first
#   --allow-counter-release-tag
#                           override the counter-label refusal (see the gates)
#
# Exit status: 0 ok, 1 usage, 2 preflight, 3 merge conflict (merge left in progress),
# 4 a gate refused the target, 5 a fork marker was lost (merge staged, NOT committed).
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tuned-common.sh
source "${TOOL_DIR}/../tuned-common.sh"

CMD="plan"; REPO="."; BRANCH="tuned-builds"; DB="${GPU_TUNED_UPSTREAM_DEFAULT_BRANCH:-}"
UP_REF="${GPU_TUNED_UPSTREAM_REF:-}"
TAG_RE="${GPU_TUNED_UPSTREAM_TAG_RE:-^v[0-9]+\.[0-9]+\.[0-9]+\$}"
TAG_GLOB="${GPU_TUNED_UPSTREAM_TAG_GLOB:-v*}"
MARKERS="${GPU_TUNED_FORK_MARKERS:-gpu_tuned_}"
TARGET_TAG=""; TARGET_PIN=""; DO_FETCH=0; APPLY=0; ALLOW_COUNTER=0
FAILED=0; FAIL_RC=4

die()  { echo "ERROR: $*" >&2; exit "${RC:-2}"; }
note() { echo "  $*"; }
gate() { echo "  GATE FAIL: $*" >&2; FAILED=1; }

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
    plan|sync-default|merge) CMD="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
esac
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --default-branch) DB="$2"; shift 2 ;;
        --upstream-ref) UP_REF="$2"; shift 2 ;;
        --tag-re) TAG_RE="$2"; shift 2 ;;
        --tag-glob) TAG_GLOB="$2"; shift 2 ;;
        --markers) MARKERS="$2"; shift 2 ;;
        --tag) TARGET_TAG="$2"; shift 2 ;;
        --pin) TARGET_PIN="$2"; shift 2 ;;
        --fetch) DO_FETCH=1; shift ;;
        --apply) APPLY=1; shift ;;
        --allow-counter-release-tag) ALLOW_COUNTER=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option '$1' (see --help)" >&2; exit 1 ;;
    esac
done
[[ -z "${TARGET_TAG}" || -z "${TARGET_PIN}" ]] || { echo "ERROR: --tag and --pin are exclusive" >&2; exit 1; }

cd "${REPO}" || die 1 "no such directory: ${REPO}"
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || { RC=1 die "not a git repository: ${REPO}"; }
cd "${TOP}"
git remote get-url upstream >/dev/null 2>&1 || { RC=1 die "no 'upstream' remote: this is not a fork"; }

detect_default_branch() {
    [[ -z "${DB}" ]] || return 0
    DB="$(git symbolic-ref -q --short refs/remotes/upstream/HEAD 2>/dev/null | sed 's#^upstream/##' || true)"
    if [[ -z "${DB}" ]]; then
        DB="$(git ls-remote --symref upstream HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}' || true)"
        [[ -z "${DB}" ]] || note "default branch '${DB}' was read from the upstream remote (pass --default-branch to skip the lookup)"
    fi
    [[ -n "${DB}" ]] || RC=2 die "cannot determine upstream's default branch; pass --default-branch"
}
short() { git rev-parse --short=10 --verify -q "$1^{commit}" 2>/dev/null || echo "(missing)"; }
# counts "<only in A> <only in B>" for A...B
rel()   { git rev-list --left-right --count "$1...$2" 2>/dev/null || echo "? ?"; }

fetch_upstream() {
    git fetch -q upstream "+refs/heads/${DB}:refs/remotes/upstream/${DB}" \
        "+refs/tags/${TAG_GLOB}:refs/tags/${TAG_GLOB}" 2>&1 | sed 's/^/  fetch: /' || true
}

report_mirror() {
    echo "== default-branch mirror (${DB})"
    local u l o
    u="$(short "refs/remotes/upstream/${DB}")"; l="$(short "refs/heads/${DB}")"; o="$(short "refs/remotes/origin/${DB}")"
    note "upstream/${DB}  ${u}"
    note "local ${DB}      ${l}   (vs upstream: $(rel "refs/heads/${DB}" "refs/remotes/upstream/${DB}") [local-only upstream-only])"
    note "origin/${DB}    ${o}   (vs local:    $(rel "refs/remotes/origin/${DB}" "refs/heads/${DB}") [origin-only local-only])"
    if git rev-parse -q --verify "refs/remotes/origin/${DB}" >/dev/null &&
       ! git merge-base --is-ancestor "refs/remotes/origin/${DB}" "refs/remotes/upstream/${DB}" 2>/dev/null; then
        note "WARNING: origin/${DB} has commits upstream/${DB} lacks; the fork's mirror is meant to be pure"
    fi
}

origin_hop_hint() {
    local slug
    slug="$(gpu_tuned_public_repo_url "$(git remote get-url origin 2>/dev/null || true)" | sed 's#^https://github.com/##')"
    note "second hop (NOT done by this tool; a remote change, needs your approval each time):"
    note "  gh repo sync ${slug:-<owner/repo>} --branch ${DB}"
}

preflight() {
    local cur
    cur="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
    if [[ "${cur}" != "${BRANCH}" ]]; then
        echo "  PREFLIGHT FAIL: on '${cur:-detached HEAD}', not '${BRANCH}' (the tool never switches branches)" >&2; FAILED=1; FAIL_RC=2
    fi
    if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null || true)" ]]; then
        echo "  PREFLIGHT FAIL: tracked changes in the working tree; commit or stash first" >&2; FAILED=1; FAIL_RC=2
    fi
    if [[ -d "$(git rev-parse --git-dir)/rebase-merge" || -d "$(git rev-parse --git-dir)/rebase-apply" || -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]]; then
        echo "  PREFLIGHT FAIL: a merge or rebase is already in progress" >&2; FAILED=1; FAIL_RC=2
    fi
}

latest_stable_tag() {
    git tag --list | grep -E "${TAG_RE}" | sort -V | tail -1 || true
}
# refs/tags/<t> for every stable upstream tag. Selected by regex, never by glob: our own
# release tags (v0.7.0+gb10..., v26.12-gb10-...) also start with "v" and carry OUR commits.
stable_tag_refs() {
    git tag --list | grep -E "${TAG_RE}" | sed 's#^#refs/tags/#' || true
}

# Commits on upstream's DEFAULT BRANCH that HEAD carries and the target lacks, ignoring ones
# whose patch the target has under another sha (a release branch cherry-picks fixes from main).
# Deliberately not "any upstream commit": a merged release tag leaves release-only commits in
# our history (version bumps, release metadata) that the next release never contains, and
# those are superseded, not lost. What a move to an older target would really drop is
# default-branch work.
carry_loss() {
    local target="$1" ups left
    ups="$(mktemp)"; left="$(mktemp)"
    git rev-list --no-merges "${UP_REF}" | sort > "${ups}"
    git rev-list --no-merges --cherry-pick --left-only "HEAD...${target}" | sort > "${left}"
    comm -12 "${ups}" "${left}"
    rm -f "${ups}" "${left}"
}

uses_counter_label() {
    git grep -qE 'gpu_tuned_tuning_count|gpu_tuned_check_main_current|rev-list --count main\.\.HEAD|tuning_count\(' \
        -- . ':!*common.sh' ':!*.md' ':!tests' 2>/dev/null
}

# Newest stable tag upstream really has (read-only network call), to catch stale local tags.
remote_latest_stable_tag() {
    git ls-remote --tags upstream 2>/dev/null | awk '{print $2}' | sed 's#^refs/tags/##' |
        grep -v '\^{}$' | grep -E "${TAG_RE}" | sort -V | tail -1 || true
}

warn_stale_tags() {
    [[ -z "${TARGET_TAG}" && -z "${TARGET_PIN}" || "${DO_FETCH}" -eq 0 ]] || return 0
    local remote local_latest
    remote="$(remote_latest_stable_tag)"; local_latest="$(latest_stable_tag)"
    if [[ -z "${remote}" ]]; then
        note "WARNING: could not read upstream's tags (offline?); the target below uses LOCAL tags only"
    elif [[ "${remote}" != "${local_latest}" ]]; then
        echo "  WARNING: upstream's newest stable tag is ${remote} but the newest one fetched here is ${local_latest:-none}." >&2
        echo "           The result below is based on the stale local tag. Re-run with --fetch." >&2
        STALE_TAGS=1
    else
        note "local tags are current (newest stable: ${remote})"
    fi
}

resolve_target() {
    TARGET_REF=""; TARGET_LABEL=""
    if [[ -n "${TARGET_PIN}" ]]; then
        TARGET_REF="$(git rev-parse -q --verify "${TARGET_PIN}^{commit}" 2>/dev/null || true)"
        TARGET_LABEL="pin ${TARGET_PIN}"
        [[ -n "${TARGET_REF}" ]] || { gate "pin '${TARGET_PIN}' is not a commit in this repository (fetch first?)"; return; }
        if ! git merge-base --is-ancestor "${TARGET_REF}" "${UP_REF}" 2>/dev/null; then
            gate "pin ${TARGET_PIN} is not an ancestor of ${UP_REF}; only upstream commits may be pinned"
        fi
    else
        local tag="${TARGET_TAG}"
        [[ -n "${tag}" ]] || tag="$(latest_stable_tag)"
        [[ -n "${tag}" ]] || { gate "no local tag matches ${TAG_RE} (try --fetch)"; return; }
        TARGET_LABEL="tag ${tag}"
        TARGET_REF="$(git rev-parse -q --verify "refs/tags/${tag}^{commit}" 2>/dev/null || true)"
        [[ -n "${TARGET_REF}" ]] || { gate "tag '${tag}' not found locally (try --fetch)"; return; }
        if ! [[ "${tag}" =~ ${TAG_RE} ]]; then gate "tag '${tag}' does not match the stable-tag pattern ${TAG_RE}"; fi
        TARGET_TAG="${tag}"
    fi
}

check_target_gates() {
    local lost n
    [[ -n "${TARGET_REF}" ]] || return 0
    if git merge-base --is-ancestor "${TARGET_REF}" HEAD 2>/dev/null; then
        note "target ${TARGET_LABEL} is already contained in ${BRANCH}; nothing to merge"
        ALREADY=1; return 0
    fi
    lost="$(carry_loss "${TARGET_REF}")"
    if [[ -n "${lost}" ]]; then
        n="$(printf '%s\n' "${lost}" | wc -l)"
        gate "${TARGET_LABEL} lacks ${n} upstream commit(s) ${BRANCH} carries. A merge only adds commits, so it cannot move back to it; use --pin <upstream commit> or the manual rebuild on the tag (docs/UPSTREAM_SYNC.md). First few:"
        printf '%s\n' "${lost}" | head -5 | while read -r c; do echo "      $(git log -1 --format='%h %s' "${c}")" >&2; done
    else
        note "carry check ok: ${TARGET_LABEL} contains every upstream commit ${BRANCH} carries"
    fi
    if [[ -n "${TARGET_TAG}" ]] && ! git merge-base --is-ancestor "${TARGET_REF}" "${UP_REF}" 2>/dev/null; then
        n="$(git rev-list --count --no-merges "${TARGET_REF}" "^${UP_REF}")"
        note "${TARGET_LABEL} is on a release branch: ${n} commit(s) are not in ${UP_REF}"
        if uses_counter_label; then
            if [[ "${ALLOW_COUNTER}" -eq 1 ]]; then
                note "WARNING: this repo still computes tuning.N from main..HEAD; those ${n} commit(s) will be counted as ours (override given)"
            else
                gate "this repo still computes the tuning.N counter from main..HEAD; merging a release-branch tag inflates it by ~${n} and gpu_tuned_check_main_current does not notice. Migrate its label to the date form first, or pass --allow-counter-release-tag"
            fi
        fi
    fi
    note "switch cost: gain $(git rev-list --count --no-merges "HEAD..${TARGET_REF}") upstream commit(s)"
}

ALREADY=0; STALE_TAGS=0
do_plan() {
    detect_default_branch; [[ -n "${UP_REF}" ]] || UP_REF="upstream/${DB}"
    [[ "${DO_FETCH}" -eq 0 ]] || fetch_upstream
    echo "== repo: ${TOP##*/}   tuned branch: ${BRANCH}   upstream ref: ${UP_REF}"
    report_mirror
    echo "== preflight"; preflight
    echo "== target"
    warn_stale_tags
    resolve_target
    [[ -z "${TARGET_REF}" ]] || note "${TARGET_LABEL} -> $(short "${TARGET_REF}")  (strategy: $([[ -n "${TARGET_PIN}" ]] && echo pin || echo tag))"
    check_target_gates
    echo "== plan"
    if [[ "${FAILED}" -ne 0 ]]; then
        echo "  would NOT proceed (see the failures above)"; return "${FAIL_RC}"
    elif [[ "${ALREADY}" -eq 1 ]]; then
        echo "  nothing to do"
    else
        echo "  would: back up ${BRANCH} as ${BRANCH}-backup-$(date -u +%F), then 'git merge --no-ff --no-commit ${TARGET_LABEL#* }', verify fork markers (${MARKERS}), then commit. No push."
        [[ "${APPLY}" -eq 1 ]] || echo "  (dry run: pass --apply to do it)"
    fi
}

count_marker() { git grep -I -F -c -e "$1" "${@:2}" -- . 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}'; }

do_merge() {
    local pre backup n lost_markers m before after rev
    local rc=0
    do_plan || rc=$?
    [[ "${rc}" -eq 0 ]] || exit "${rc}"
    [[ "${APPLY}" -eq 1 && "${ALREADY}" -eq 0 ]] || exit 0
    [[ "${STALE_TAGS}" -eq 0 ]] || RC=4 die "refusing to --apply on a stale local tag; re-run with --fetch"
    pre="$(git rev-parse HEAD)"
    backup="${BRANCH}-backup-$(date -u +%F)"; n=1
    while git rev-parse -q --verify "refs/heads/${backup}" >/dev/null; do n=$((n+1)); backup="${BRANCH}-backup-$(date -u +%F)-${n}"; done
    git branch "${backup}" "${pre}"
    echo "== merge   (backup branch: ${backup} at $(short "${pre}"))"
    if ! git merge --no-ff --no-commit "${TARGET_REF}" >/dev/null 2>&1; then
        echo "  MERGE CONFLICT; the merge is left in progress. Conflicted files:" >&2
        git diff --name-only --diff-filter=U | sed 's/^/    /' >&2
        echo "  resolve and 'git commit', or undo with: git merge --abort" >&2
        echo "  then re-run the fork-marker check on the resolved tree before committing (docs/UPSTREAM_SYNC.md)" >&2
        exit 3
    fi
    lost_markers=""
    IFS=',' read -ra ML <<< "${MARKERS}"
    for m in "${ML[@]}"; do
        before="$(count_marker "${m}" "${pre}")"; after="$(count_marker "${m}" --cached)"
        echo "  marker '${m}': ${before} -> ${after} line(s)"
        if [[ "${after}" -lt "${before}" ]]; then lost_markers="${lost_markers} ${m}"; fi
    done
    echo "  files our own commits changed that the merge removed lines from (review; informational):"
    # shellcheck disable=SC2046
    git rev-list --no-merges "${pre}" --not --remotes=upstream $(stable_tag_refs) 2>/dev/null |
        while read -r c; do git diff-tree --no-commit-id --name-only -r "${c}"; done | sort -u > "${TOP}/.git/upstream-sync-forkfiles.$$"
    git diff --cached --numstat "${pre}" | awk -F'\t' 'NR==FNR {f[$0]=1; next} ($3 in f) && $2>0 {printf "    %s  (-%s lines)\n", $3, $2}' "${TOP}/.git/upstream-sync-forkfiles.$$" - | head -15
    rm -f "${TOP}/.git/upstream-sync-forkfiles.$$"
    if [[ -n "${lost_markers}" ]]; then
        echo "  FORK MARKER LOST:${lost_markers}. The merge is staged but NOT committed." >&2
        echo "  Inspect (git diff --cached ${pre} | grep -n marker), restore the lost code (git checkout ${pre} -- <file> or --ours), then commit; or: git merge --abort" >&2
        exit 5
    fi
    git commit -q -m "Merge upstream ${TARGET_LABEL#* } into ${BRANCH}"
    rev="$(git rev-parse --short=10 HEAD)"
    echo "== merged ${TARGET_LABEL} as ${rev}. Not pushed."
    echo "  stamp base would read: $(GPU_TUNED_UPSTREAM_REF="${TARGET_REF}" gpu_tuned_git_provenance | grep -o 'upstream .*')"
}

do_sync_default() {
    detect_default_branch; [[ -n "${UP_REF}" ]] || UP_REF="upstream/${DB}"
    fetch_upstream
    report_mirror
    if ! git rev-parse -q --verify "refs/remotes/upstream/${DB}" >/dev/null; then RC=2 die "upstream/${DB} is not fetched"; fi
    if git rev-parse -q --verify "refs/heads/${DB}" >/dev/null; then
        if ! git merge-base --is-ancestor "refs/heads/${DB}" "refs/remotes/upstream/${DB}"; then
            RC=4 die "local ${DB} has commits upstream/${DB} lacks (not a fast-forward); this mirror must stay pure. Nothing changed."
        fi
        if [[ "$(git symbolic-ref -q --short HEAD 2>/dev/null || true)" == "${DB}" ]]; then
            RC=2 die "${DB} is checked out here; the tool will not move the checked-out branch"
        fi
        if git fetch -q . "refs/remotes/upstream/${DB}:refs/heads/${DB}" 2>&1; then
            note "local ${DB} is now $(short "refs/heads/${DB}")"
        else
            RC=2 die "could not fast-forward ${DB} (checked out in another worktree?)"
        fi
    else
        git branch "${DB}" "refs/remotes/upstream/${DB}"; note "created local ${DB} at $(short "refs/heads/${DB}")"
    fi
    origin_hop_hint
}

case "${CMD}" in
    plan)         do_plan || exit $? ;;
    sync-default) do_sync_default ;;
    merge)        do_merge ;;
esac
