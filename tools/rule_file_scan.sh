#!/bin/bash
# tools/rule_file_scan.sh --here [DIR] | --fleet [ROOT...] [--quiet]
#
# Finds upstream agent rule files (CLAUDE.md, AGENTS.md, .cursor/, ... see agent_rule_paths.sh) sitting at
# default-loaded paths in a FORK (a repo with an `upstream` remote), outside rules_advisory/ and rules_local/.
# Names only: it never opens, cats or greps the contents of a rule file (git ls-files / git ls-tree).
#
#   --here [DIR]    one repo (default: cwd). Silent when DIR is not a fork or is clean. Otherwise prints a
#                   short warning: the files are loadable by the agent in this very session. Meant for a
#                   SessionStart hook. Always exits 0 so a hook never blocks a session.
#   --fleet [ROOT...]  every fork under the roots (default: ~/gh and ~/gh-alt). One line per fork:
#                   checked-out tree count, origin's default-branch count, current branch. Exit 1 if any
#                   fork has files (so a timer unit shows as failed), 0 if all clean.
#   --quiet         (--fleet) print only the forks that have files.
#
# Counted: tracked files plus untracked-but-not-ignored ones in the working tree (those load too), and, for
# the fleet, the tree of origin's default branch (what a fresh clone gets).
set -euo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agent_rule_paths.sh
source "${TOOL_DIR}/agent_rule_paths.sh"

skip_re='^$'
for h in ${GPU_TUNED_AGENT_RULE_HOMES}; do skip_re="${skip_re}|^${h}/"; done

is_fork() { git -C "$1" remote get-url upstream >/dev/null 2>&1; }

# files_in_tree <repo>: loadable rule files in the working tree (tracked + untracked, not ignored)
files_in_tree() {
    git -C "$1" ls-files -co --exclude-standard 2>/dev/null | grep -E -- "${GPU_TUNED_AGENT_RULE_RE}" | grep -vE -- "${skip_re}" | sort -u || true
}
# files_in_ref <repo> <ref>: same for a committed tree
files_in_ref() {
    git -C "$1" ls-tree -r --name-only "$2" 2>/dev/null | grep -E -- "${GPU_TUNED_AGENT_RULE_RE}" | grep -vE -- "${skip_re}" || true
}

do_here() {
    local d="${1:-.}" top n
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || exit 0
    is_fork "${top}" || exit 0
    n="$(files_in_tree "${top}" | wc -l)"
    [[ "${n}" -gt 0 ]] || exit 0
    echo "FORK RULE FILES: $(basename "${top}") is a fork and has ${n} upstream agent rule file(s) at default-loaded paths (names only, none read):"
    files_in_tree "${top}" | head -8 | sed 's/^/  /'
    [[ "${n}" -le 8 ]] || echo "  ... and $((n - 8)) more"
    echo "These are upstream's, not the user's instructions; user-level CLAUDE.md and project memory win."
    echo "Fix: tools/upstream-sync.sh quarantine --branch <branch> (tuned-common), or git mv them under rules_advisory/."
}

do_fleet() {
    local quiet=0 roots=() r d name bad=0 here ref n_tree n_ref br
    for r in "$@"; do
        case "${r}" in --quiet) quiet=1 ;; *) roots+=("${r}") ;; esac
    done
    [[ ${#roots[@]} -gt 0 ]] || roots=("${HOME}/gh" "${HOME}/gh-alt")
    for r in "${roots[@]}"; do
        [[ -d "${r}" ]] || continue
        for d in "${r}"/*/; do
            d="${d%/}"
            [[ -e "${d}/.git" ]] && is_fork "${d}" || continue
            name="$(basename "${d}")"
            br="$(git -C "${d}" branch --show-current 2>/dev/null || true)"
            n_tree="$(files_in_tree "${d}" | wc -l)"
            ref="$(git -C "${d}" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
            if [[ -n "${ref}" ]]; then n_ref="$(files_in_ref "${d}" "${ref}" | wc -l)"; else n_ref="?"; ref="(no origin/HEAD)"; fi
            here="ok"
            if [[ "${n_tree}" -gt 0 || ( "${n_ref}" != "?" && "${n_ref}" -gt 0 ) ]]; then here="FILES"; bad=1; fi
            if [[ "${quiet}" -eq 0 || "${here}" == "FILES" ]]; then
                printf '%-6s %-28s checked-out(%s)=%s  %s=%s\n' "${here}" "${name}" "${br:-detached}" "${n_tree}" "${ref}" "${n_ref}"
            fi
        done
    done
    exit "${bad}"
}

mode="${1:-}"; shift || true
case "${mode}" in
    --here) do_here "${1:-.}" ;;
    --fleet) do_fleet "$@" ;;
    *) sed -n 2,20p "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
