# Sourced by tuned_compliance.sh (J5) and upstream-sync.sh. Not run on its own.
# Paths where coding agents load rule files by default. Upstream's copies in a fork are
# moved under tuned/advisory_rules/ (unmodified) or tuned/local_modified_rules/ (changed
# locally), at the same relative path. docs/ARCHITECTURE.md J5.
GPU_TUNED_AGENT_RULE_RE='(^|/)(CLAUDE|AGENTS|GEMINI)\.md$|(^|/)\.claude/|(^|/)\.agents/|(^|/)\.cursor/|(^|/)\.cursorrules$|(^|/)\.windsurfrules$|(^|/)\.github/copilot-instructions\.md$|(^|/)\.mcp\.json$'
GPU_TUNED_AGENT_RULE_HOMES='tuned/advisory_rules tuned/local_modified_rules'

# gpu_tuned_agent_rule_files <repo>: tracked files at default-loaded paths, one per line.
gpu_tuned_agent_rule_files() {
    local h skip='^$'
    for h in ${GPU_TUNED_AGENT_RULE_HOMES}; do skip="${skip}|^${h}/"; done
    git -C "$1" ls-files | grep -E -- "${GPU_TUNED_AGENT_RULE_RE}" | grep -vE -- "${skip}" || true
}
