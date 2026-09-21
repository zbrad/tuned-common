#!/bin/bash
# Regression tests for tuned-common.sh: loud failures + version-style helpers.
# Usage: bash tests/test_common.sh   (exit 0 = all pass)
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tuned-common.sh"
PASS=0; FAIL=0

# check <name> <want-exit> <stderr-must-match|-> <stdout-must-match|-> <script...>
check() {
    local name="$1" want_rc="$2" err_re="$3" out_re="$4" script="$5" out err rc
    out="$(mktemp)"; err="$(mktemp)"
    bash -c "${script}" >"${out}" 2>"${err}"; rc=$?
    local ok=1
    [[ "${rc}" -eq "${want_rc}" ]] || ok=0
    if [[ "${err_re}" == "-" ]]; then [[ ! -s "${err}" ]] || ok=0; else grep -qE "${err_re}" "${err}" || ok=0; fi
    if [[ "${out_re}" != "-" ]]; then grep -qE "${out_re}" "${out}" || ok=0; fi
    if [[ "${ok}" -eq 1 ]]; then PASS=$((PASS+1)); echo "ok   - ${name}"
    else FAIL=$((FAIL+1)); echo "FAIL - ${name} (rc=${rc}, want ${want_rc})"; sed 's/^/     stderr: /' "${err}"; sed 's/^/     stdout: /' "${out}"; fi
    rm -f "${out}" "${err}"
}
pre="set -euo pipefail; source '${LIB}'"

# --- loud failures ---
check "no-match grep in \$(...) under pipefail aborts LOUDLY" 1 \
  "\[tuned\] ERROR: command failed \(exit 1\).*grep" "-" \
  "${pre}; X=\"\$(echo a | grep -oE b | head -1)\"; echo unreachable"
tmp_script="$(mktemp --suffix=.sh)"
# shellcheck disable=SC2016 # the single-quoted $(...) must reach the child script unexpanded
printf '%s\n' "set -euo pipefail" "source '${LIB}'" 'X="$(echo a | grep -oE b | head -1)"' > "${tmp_script}"
check "the failing script file:line is reported" 1 "at ${tmp_script}:3 \\(main\\)" "-" "bash '${tmp_script}'"
rm -f "${tmp_script}"
check "failure inside a function reports the call stack" 1 "\(inner\)|\(outer\)" "-" \
  "${pre}
inner() { false; }
outer() { inner; }
outer"
check "|| true is silent and the script continues" 0 "-" "continued" \
  "${pre}; X=\"\$(echo a | grep -oE b | head -1 || true)\"; echo continued"
check "if-guarded failure is silent" 0 "-" "handled" \
  "${pre}; if ! false; then echo handled; fi"
check "set +e region is silent" 0 "-" "rc=1" \
  "${pre}; set +e; false; echo rc=\$?; set -e"
check "opt-out GPU_TUNED_NO_ERR_TRAP=1 leaves the old silent behavior" 1 "-" "-" \
  "GPU_TUNED_NO_ERR_TRAP=1; ${pre}; false; echo unreachable"
check "an existing ERR trap is not overridden" 1 "custom-trap" "-" \
  "set -euo pipefail; trap 'echo custom-trap >&2' ERR; source '${LIB}'; false"
check "sourcing without errexit produces no output" 0 "-" "fine" \
  "source '${LIB}'; false; echo fine"

# --- version helpers ---
lv() { echo "source '${LIB}'; gpu_tuned_local_version $*"; }
check "local_version canonical" 0 "-" "^gb10\.cu134\.tuning\.34$" "$(lv gb10 134 34)"
check "local_version count 0 is allowed" 0 "-" "^gb10\.cu134\.tuning\.0$" "$(lv gb10 134 0)"
check "local_version rejects leading zero" 1 "leading zeros" "-" "$(lv gb10 134 007)"
check "local_version rejects a v-prefixed count" 1 "canonical decimal" "-" "$(lv gb10 134 v34)"
check "local_version rejects empty count" 1 "canonical decimal" "-" "$(lv gb10 134 '""')"
check "local_version rejects dotted cuda" 1 "digits only" "-" "$(lv gb10 13.4 5)"
check "local_version rejects uppercase variant" 1 "lowercase" "-" "$(lv GB10 134 5)"
tl() { echo "set -euo pipefail; source '${LIB}'; x=\"\$(gpu_tuned_tuning_label '$1')\"; echo \"[\${x}]\""; }
check "tuning_label extracts the marker" 0 "-" "^\[tuning\.149\]$" "$(tl '0.7.0+gb10.cu134.tuning.149')"
check "tuning_label is empty (not an error) when absent" 0 "-" "^\[\]$" "$(tl '0.7.0+gb10.cu134')"
check "tuning_label ignores the legacy v-form" 0 "-" "^\[\]$" "$(tl '0.7.0+gb10.cu133.tuning.v28')"

# --- main-behind-upstream helper ---
# mkrepo <dir> <scenario>: an upstream bare repo + a clone with main and tuned-builds
mkrepo() {
    local d="$1" scenario="$2"
    git init -q --bare -b main "${d}/up.git" && git init -q -b main "${d}/seed" && (
        cd "${d}/seed" && git config user.email t@t && git config user.name t
        echo 1 > f && git add f && git commit -qm base
        git remote add origin "${d}/up.git" && git push -q origin main
    ) && git clone -q -b main "${d}/up.git" "${d}/w" && (
        cd "${d}/w" && git config user.email t@t && git config user.name t
        git remote rename origin upstream
        git checkout -q -b tuned-builds
        for i in 1 2 3; do echo "o$i" > "o$i"; git add "o$i"; git commit -qm "ours $i"; done
        case "${scenario}" in
          clean) ;;
          fetched-not-merged)
            (cd "${d}/seed" && for i in 1 2; do echo "u$i" > "u$i"; git add "u$i"; git commit -qm "up $i"; done && git push -q origin main)
            git fetch -q upstream ;;
          merged-not-ff)
            (cd "${d}/seed" && for i in 1 2; do echo "u$i" > "u$i"; git add "u$i"; git commit -qm "up $i"; done && git push -q origin main)
            git fetch -q upstream && git merge -q --no-edit upstream/main ;;
          merged-then-ff)
            (cd "${d}/seed" && for i in 1 2; do echo "u$i" > "u$i"; git add "u$i"; git commit -qm "up $i"; done && git push -q origin main)
            git fetch -q upstream main:main && git merge -q --no-edit upstream/main ;;
          no-upstream) git remote remove upstream ;;
          no-main) git branch -q -D main 2>/dev/null; git checkout -q --detach; git branch -q -D main 2>/dev/null; true ;;
        esac
    )
}
gh_case() { # name want-exit err-re out-re scenario [env-prefix]
    local d; d="$(mktemp -d)"; mkrepo "${d}" "$5" >/dev/null 2>&1
    check "$1" "$2" "$3" "$4" "${6:-} source '${LIB}'; gpu_tuned_tuning_count '${d}/w'"
    rm -rf "${d}"
}
gh_case "tuning_count: clean repo prints our commit count" 0 "-" "^3$" clean
gh_case "tuning_count: plain fetch without merge does not trip the check" 0 "-" "^3$" fetched-not-merged
gh_case "tuning_count: upstream merged but main not fast-forwarded fails loudly" 1 "would include 2 upstream commit.*only 4 are ours" "-" merged-not-ff
gh_case "tuning_count: stale-main error names the fix command" 1 "git fetch upstream main:main" "-" merged-not-ff
gh_case "tuning_count: override warns loudly and still returns the count" 0 "GPU_TUNED_ALLOW_STALE_MAIN is set" "^6$" merged-not-ff "GPU_TUNED_ALLOW_STALE_MAIN=1;"
gh_case "tuning_count: after fast-forwarding main it counts only our commits" 0 "-" "^4$" merged-then-ff
gh_case "tuning_count: no upstream remote warns and still counts" 0 "no 'upstream' remote" "^3$" no-upstream
gh_case "tuning_count: missing local main is an error" 1 "no local 'main' branch" "-" no-main
mkrepo_dir="$(mktemp -d)"; mkrepo "${mkrepo_dir}" merged-not-ff >/dev/null 2>&1
check "tuning_count: stale main prints nothing on stdout" 0 "-" "^\\[\\]$" "source '${LIB}'; X=\"\$(gpu_tuned_tuning_count '${mkrepo_dir}/w' 2>/dev/null)\" || true; echo \"[\${X}]\""
check "check_main_current alone: stale main returns 1" 1 "local 'main' is stale" "-" "source '${LIB}'; gpu_tuned_check_main_current '${mkrepo_dir}/w'"
check "check_main_current under set -e reports via the ERR trap too" 1 "\\[tuned\\] ERROR: command failed" "-" "set -euo pipefail; source '${LIB}'; X=\"\$(gpu_tuned_tuning_count '${mkrepo_dir}/w')\"; echo unreachable"
rm -rf "${mkrepo_dir}"

# --- build-info stamp: optional deps field ---
# Stamp a throwaway copy of a real ELF, then read the section back.
stamp="T=\"\$(mktemp)\"; cp /bin/true \"\$T\"; trap 'rm -f \"\$T\"' EXIT"
read_stamp="readelf -p .pkg_build_info \"\$T\" | grep -o 'pkg-gb10 build.*'"
check "embed_build_info: GPU_TUNED_BUILD_INFO_DEPS is recorded as ', deps ...'" 0 "-" \
  "commit [0-9a-f]+, deps kvikio 26\\.12\\.00, raft v26\\.12, built " \
  "${pre}; ${stamp}; GPU_TUNED_BUILD_INFO_DEPS='kvikio 26.12.00, raft v26.12' gpu_tuned_embed_build_info \"\$T\" gb10 pkg 1.0 HW https://example.invalid/r; ${read_stamp}"
check "embed_build_info: without the variable the stamp has no deps field" 0 "-" \
  "commit [0-9a-f]+, built " \
  "${pre}; ${stamp}; unset GPU_TUNED_BUILD_INFO_DEPS; gpu_tuned_embed_build_info \"\$T\" gb10 pkg 1.0 HW https://example.invalid/r; ${read_stamp}"
check "embed_build_info: a multi-line deps value collapses to one line" 0 "-" \
  "deps a b, built " \
  "${pre}; ${stamp}; GPU_TUNED_BUILD_INFO_DEPS=\$'a\\nb' gpu_tuned_embed_build_info \"\$T\" gb10 pkg 1.0 HW https://example.invalid/r; ${read_stamp}"
check "embed_build_info: re-stamping replaces the previous deps, not appends" 0 "-" \
  "deps second, built " \
  "${pre}; ${stamp}; GPU_TUNED_BUILD_INFO_DEPS=first gpu_tuned_embed_build_info \"\$T\" gb10 pkg 1.0 HW; GPU_TUNED_BUILD_INFO_DEPS=second gpu_tuned_embed_build_info \"\$T\" gb10 pkg 1.0 HW; S=\"\$(${read_stamp})\"; echo \"\$S\"; ! grep -q first <<< \"\$S\""

# --- CUDA-version-specific output dirs ---
check "out_dir build: cuda tag then variant under cpp/build" 0 "-" "^/r/cpp/build/cu133/gb10$" \
  "${pre}; gpu_tuned_out_dir build /r cu133 gb10"
check "out_dir build: two toolkits never share a dir" 0 "-" "^/r/cpp/build/cu134/gb10$" \
  "${pre}; gpu_tuned_out_dir build /r cu134 gb10"
check "out_dir dist: accepts the shared pseudo-variant" 0 "-" "^/r/dist/cu133/shared$" \
  "${pre}; gpu_tuned_out_dir dist /r cu133 shared"
check "out_dir releases: cuda tag only, variant ignored" 0 "-" "^/r/tuned/releases/cu133$" \
  "${pre}; gpu_tuned_out_dir releases /r cu133 gb10"
check "out_dir: bad cuda tag fails" 1 "not of the form cu<digits>" "-" \
  "${pre}; gpu_tuned_out_dir build /r 13.3 gb10"
check "out_dir build: missing variant fails" 1 "needs a variant" "-" \
  "${pre}; gpu_tuned_out_dir build /r cu133"
check "out_dir: unknown kind fails" 1 "unknown kind 'logs'" "-" \
  "${pre}; gpu_tuned_out_dir logs /r cu133 gb10"

echo; echo "passed=${PASS} failed=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
