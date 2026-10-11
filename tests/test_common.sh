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

# --- build-info stamp: fork + upstream commits ---
# Fixture: bare "upstream" with c1 (tag v1.0), c2, c3; a fork on top of c3 with
# two commits. A tuning-* tag sits ON the upstream base (c3), so it would be
# the "nearest" tag if it were not excluded.
prov="$(mktemp -d)"
(
    set -e; export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b main "${prov}/up.git"
    git init -q -b main "${prov}/seed"; cd "${prov}/seed"
    echo 1 > f; git add f; git commit -qm c1; git tag v1.0
    echo 2 > f; git commit -qam c2; echo 3 > f; git commit -qam c3
    git tag tuning-9                       # on the upstream base itself
    git remote add o "${prov}/up.git"; git push -q o main --tags
    git init -q -b tuned "${prov}/fork"; cd "${prov}/fork"
    git remote add origin git@github.com:zbrad/thing.git
    git remote add upstream "${prov}/up.git"; git fetch -q upstream --tags
    git reset -q --hard upstream/main
    echo a > g; git add g; git commit -qm f1; echo b > g; git commit -qam f2
) >/dev/null 2>&1
fork_sha="$(git -C "${prov}/fork" rev-parse HEAD)"
base_sha="$(git -C "${prov}/fork" rev-parse upstream/main)"
inrepo="cd '${prov}/fork'"
check "provenance: fork sha is the full 40-char HEAD" 0 "-" "fork https://github\\.com/zbrad/thing sha ${fork_sha}[ ,]" \
  "${pre}; ${inrepo}; GPU_TUNED_UPSTREAM_REF=upstream/main gpu_tuned_git_provenance"
check "provenance: origin ssh remote is stamped as a public https url" 0 "-" "fork https://github\\.com/zbrad/thing sha" \
  "${pre}; ${inrepo}; gpu_tuned_git_provenance"
check "provenance: upstream base is the merge-base (full sha)" 0 "-" "base ${base_sha} nearest" \
  "${pre}; ${inrepo}; GPU_TUNED_UPSTREAM_REF=upstream/main gpu_tuned_git_provenance"
check "provenance: nearest upstream tag + distance; our tuning-* tag is excluded" 0 "-" "nearest v1\\.0\\+2$" \
  "${pre}; ${inrepo}; GPU_TUNED_UPSTREAM_REF=upstream/main gpu_tuned_git_provenance"
check "provenance: an undeclared upstream ref is marked, not guessed" 0 "-" "upstream .* ref undeclared$" \
  "${pre}; ${inrepo}; unset GPU_TUNED_UPSTREAM_REF; gpu_tuned_git_provenance"
check "provenance: upstream/HEAD is used when git has one" 0 "-" "ref upstream/main base ${base_sha}" \
  "${pre}; ${inrepo}; git remote set-head upstream main >/dev/null; unset GPU_TUNED_UPSTREAM_REF; gpu_tuned_git_provenance; git symbolic-ref -q --delete refs/remotes/upstream/HEAD"
check "provenance: an unresolvable ref says base unknown and exits 0 quietly" 0 "-" "ref upstream/nope base unknown$" \
  "${pre}; ${inrepo}; GPU_TUNED_UPSTREAM_REF=upstream/nope gpu_tuned_git_provenance"
check "provenance: no upstream remote stamps 'upstream none'" 0 "-" "upstream none$" \
  "${pre}; cd '${prov}'; git init -q -b m nofork; cd nofork; git remote add origin https://tok:secret@github.com/o/r.git; git -c user.name=t -c user.email=t@t commit -q --allow-empty -m x; out=\"\$(gpu_tuned_git_provenance)\"; echo \"\$out\"; ! grep -q secret <<< \"\$out\""
check "provenance: a tuning-* tag already on HEAD is picked up" 0 "-" "sha ${fork_sha} tag tuning-20261010," \
  "${pre}; ${inrepo}; git tag tuning-20261010; GPU_TUNED_UPSTREAM_REF=upstream/main gpu_tuned_git_provenance; git tag -d tuning-20261010 >/dev/null"
check "provenance: GPU_TUNED_BUILD_INFO_TAG is stamped before any tag exists" 0 "-" "sha ${fork_sha} tag tuning-20261011\\.1," \
  "${pre}; ${inrepo}; GPU_TUNED_BUILD_INFO_TAG=tuning-20261011.1 GPU_TUNED_UPSTREAM_REF=upstream/main gpu_tuned_git_provenance"
check "provenance: a tracked-file change is marked dirty" 0 "-" "sha ${fork_sha} dirty," \
  "${pre}; ${inrepo}; echo x >> g; GPU_TUNED_UPSTREAM_REF=upstream/main gpu_tuned_git_provenance; git checkout -q g"
check "provenance: outside a git repo it is a marker, exit 0, silent" 0 "-" "^fork sha unknown, upstream unknown$" \
  "${pre}; cd /; gpu_tuned_git_provenance"
check "public_repo_url: scp-style, org alias, https token, ssh://" 0 "-" "^OK$" \
  "${pre}; [ \"\$(gpu_tuned_public_repo_url git@github.com:a/b.git)\" = https://github.com/a/b ] && [ \"\$(gpu_tuned_public_repo_url org-16943930@github.com:facebookresearch/faiss.git)\" = https://github.com/facebookresearch/faiss ] && [ \"\$(gpu_tuned_public_repo_url https://u:tok@github.com/a/b.git)\" = https://github.com/a/b ] && [ \"\$(gpu_tuned_public_repo_url ssh://git@github.com/a/b)\" = https://github.com/a/b ] && echo OK"
check "embed_build_info: stamp carries fork+upstream hashes ahead of ', commit '" 0 "-" \
  "fork https://github\\.com/zbrad/thing sha ${fork_sha}, upstream .* base ${base_sha} nearest v1\\.0\\+2, commit [0-9a-f]+, built " \
  "${pre}; ${stamp}; ${inrepo}; GPU_TUNED_UPSTREAM_REF=upstream/main gpu_tuned_embed_build_info \"\$T\" gb10 pkg 1.0 HW; ${read_stamp}"
rm -rf "${prov}"

# --- publish gate: clean tracked tree ---
gate="$(mktemp -d)"
(
    set -e; export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q -b tuned-builds "${gate}/r"; cd "${gate}/r"
    echo 1 > tracked; git add tracked; git commit -qm c1
    mkdir "${gate}/bin"; printf '#!/bin/sh\necho gh-called "$@" >> "%s/gh.log"\n' "${gate}" > "${gate}/bin/gh"; chmod +x "${gate}/bin/gh"
) >/dev/null 2>&1
ingate="cd '${gate}/r'; export PATH='${gate}/bin':\"\$PATH\"; : > '${gate}/gh.log'"
check "clean_tree: a clean tree passes and names the tree it checked" 0 "-" "OK: clean tracked tree at .*/r " \
  "${pre}; ${ingate}; gpu_tuned_require_clean_tree"
check "clean_tree: untracked files do not make the tree dirty" 0 "-" "^OK" \
  "${pre}; ${ingate}; echo junk > build-output.o; gpu_tuned_require_clean_tree; rm -f build-output.o"
check "clean_tree: a modified tracked file is refused and listed" 1 "refusing to publish from a dirty tree" "-" \
  "${pre}; ${ingate}; echo 2 >> tracked; rc=0; gpu_tuned_require_clean_tree || rc=\$?; git checkout -q tracked; exit \$rc"
check "clean_tree: the refusal lists the changed file" 1 " M tracked" "-" \
  "${pre}; ${ingate}; echo 2 >> tracked; rc=0; gpu_tuned_require_clean_tree || rc=\$?; git checkout -q tracked; exit \$rc"
check "clean_tree: a staged change is refused too" 1 "dirty tree" "-" \
  "${pre}; ${ingate}; echo 3 >> tracked; git add tracked; rc=0; gpu_tuned_require_clean_tree || rc=\$?; git reset -q --hard; exit \$rc"
check "clean_tree: outside a git checkout is refused" 1 "not inside a git checkout" "-" \
  "${pre}; cd /; gpu_tuned_require_clean_tree"
check "publish_release: a dirty tree is refused before gh is ever called" 1 "dirty tree" "-" \
  "${pre}; ${ingate}; echo 2 >> tracked; rc=0; gpu_tuned_publish_release o/r tag title notes asset || rc=\$?; git checkout -q tracked; [ ! -s '${gate}/gh.log' ] && exit \$rc"
check "publish_release: a clean tree reaches gh create" 0 "-" "OK: published o/r@tag" \
  "${pre}; ${ingate}; gpu_tuned_publish_release o/r tag title notes asset; grep -q 'release create tag' '${gate}/gh.log'"
rm -rf "${gate}"

# --- date-form wheel label ---
check "dated label: first build of the day has no sequence suffix" 0 "-" "^gb10\.cu134\.20261010$" \
  "${pre}; gpu_tuned_local_version_dated gb10 134 20261010"
check "dated label: seq 0 is the same as omitted" 0 "-" "^gb10\.cu134\.20261010$" \
  "${pre}; gpu_tuned_local_version_dated gb10 134 20261010 0"
check "dated label: later builds append .N" 0 "-" "^gb10\.cu134\.20261010\.2$" \
  "${pre}; gpu_tuned_local_version_dated gb10 134 20261010 2"
check "dated label: an impossible calendar date is refused" 1 "real calendar date" "-" \
  "${pre}; gpu_tuned_local_version_dated gb10 134 20260230"
check "dated label: a leading-zero date is refused" 1 "not starting with 0" "-" \
  "${pre}; gpu_tuned_local_version_dated gb10 134 02061010"
check "dated label: a zero-padded sequence is refused" 1 "canonical integer" "-" \
  "${pre}; gpu_tuned_local_version_dated gb10 134 20261010 01"
check "dated label: a non-numeric sequence is refused" 1 "canonical integer" "-" \
  "${pre}; gpu_tuned_local_version_dated gb10 134 20261010 x"
check "dated label: bad variant is refused" 1 "variant" "-" "${pre}; gpu_tuned_local_version_dated GB10 134 20261010"
check "dated label: bad cuda tag is refused" 1 "cuda-compact" "-" "${pre}; gpu_tuned_local_version_dated gb10 13.4 20261010"
check "date_label: reads a bare date" 0 "-" "^20261010$" "${pre}; gpu_tuned_date_label '0.7.0+gb10.cu134.20261010'"
check "date_label: reads date and sequence" 0 "-" "^20261010\.12$" "${pre}; gpu_tuned_date_label '0.7.0+gb10.cu134.20261010.12'"
check "date_label: reads it through vllm's setuptools_scm g<sha> prefix" 0 "-" "^20261010$" \
  "${pre}; gpu_tuned_date_label '0.29.1rc1.dev441+gd9d8249e9.gb10.cu134.20261010'"
check "date_label: the old tuning.N counter is not a date label (empty, exit 0, silent)" 0 "-" "^\\[\\]$" \
  "${pre}; X=\"\$(gpu_tuned_date_label '0.7.0+gb10.cu134.tuning.62')\"; echo \"[\${X}]\""
check "date_label: a CUDA-only local is not a date label" 0 "-" "^\\[\\]$" \
  "${pre}; X=\"\$(gpu_tuned_date_label '0.7.0+gb10.cu134')\"; echo \"[\${X}]\""
check "date_label: a .0 sequence is not a label" 0 "-" "^\\[\\]$" \
  "${pre}; X=\"\$(gpu_tuned_date_label '0.7.0+gb10.cu134.20261010.0')\"; echo \"[\${X}]\""
check "date_label: an impossible date is not a label" 0 "-" "^\\[\\]$" \
  "${pre}; X=\"\$(gpu_tuned_date_label '0.7.0+gb10.cu134.20260230')\"; echo \"[\${X}]\""
check "date_label: a public .dev<date> version is not mistaken for a label" 0 "-" "^\\[\\]$" \
  "${pre}; X=\"\$(gpu_tuned_date_label '2.15.0.dev20260911')\"; echo \"[\${X}]\""
check "date_label: a date with no <variant>.cu<cuda>. before it is not a label" 0 "-" "^\\[\\]$" \
  "${pre}; X=\"\$(gpu_tuned_date_label '0.7.0+gb10.20261010')\"; echo \"[\${X}]\""
check "date_label: round-trips what local_version_dated builds" 0 "-" "^20261010\.3$" \
  "${pre}; L=\"\$(gpu_tuned_local_version_dated gb10 134 20261010 3)\"; gpu_tuned_date_label \"0.7.0+\${L}\""
check "legacy gpu_tuned_local_version is unchanged" 0 "-" "^gb10\.cu134\.tuning\.149$" \
  "${pre}; gpu_tuned_local_version gb10 134 149"
check "legacy gpu_tuned_tuning_label is unchanged" 0 "-" "^tuning\.149$" \
  "${pre}; gpu_tuned_tuning_label '0.7.0+gb10.cu134.tuning.149'"

# --- nvcc -> compact cuda tag ---
nv="$(mktemp -d)"; mkdir -p "${nv}/cuda-13.4/bin" "${nv}/cuda-12.10/bin" "${nv}/broken/bin"
mknvcc() { printf '#!/bin/sh\nprintf "nvcc: NVIDIA (R) Cuda compiler driver\\nCuda compilation tools, release %s, V%s.48\\n"\n' "$2" "$2" > "$1/bin/nvcc"; chmod +x "$1/bin/nvcc"; }
mknvcc "${nv}/cuda-13.4" 13.4; mknvcc "${nv}/cuda-12.10" 12.10
printf '#!/bin/sh\necho "no version here"\n' > "${nv}/broken/bin/nvcc"; chmod +x "${nv}/broken/bin/nvcc"
check "nvcc_compact: 13.4 -> 134" 0 "-" "^134$" "${pre}; gpu_tuned_nvcc_compact '${nv}/cuda-13.4'"
check "nvcc_compact: two-digit minor is kept whole, not cut to three characters" 0 "-" "^1210$" "${pre}; gpu_tuned_nvcc_compact '${nv}/cuda-12.10'"
check "nvcc_compact: defaults to CUDA_HOME" 0 "-" "^134$" "${pre}; CUDA_HOME='${nv}/cuda-13.4' gpu_tuned_nvcc_compact"
check "nvcc_compact: the argument wins over CUDA_HOME" 0 "-" "^1210$" "${pre}; CUDA_HOME='${nv}/cuda-13.4' gpu_tuned_nvcc_compact '${nv}/cuda-12.10'"
check "nvcc_compact: no cuda home at all is a loud error" 1 "CUDA_HOME is not set" "-" "${pre}; unset CUDA_HOME; gpu_tuned_nvcc_compact"
check "nvcc_compact: a missing nvcc is a loud error" 1 "is not an executable" "-" "${pre}; gpu_tuned_nvcc_compact '${nv}/nowhere'"
check "nvcc_compact: unreadable nvcc output is a loud error, not an empty tag" 1 "cannot read a 'release X.Y'" "-" "${pre}; gpu_tuned_nvcc_compact '${nv}/broken'"
rm -rf "${nv}"

# --- allocator: HEAD date (UTC) and lowest unused sequence ---
al="$(mktemp -d)"
(
    set -e; export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b main "${al}/remote.git"
    git init -q -b main "${al}/w"; cd "${al}/w"
    # 23:30 on Oct 10 at UTC-7 is already Oct 11 in UTC
    GIT_AUTHOR_DATE="2026-10-10T23:30:00-0700" GIT_COMMITTER_DATE="2026-10-10T23:30:00-0700" git commit -q --allow-empty -m c1
    git remote add origin "${al}/remote.git"
    git push -q origin main
    git init -q -b main "${al}/empty"
) >/dev/null 2>&1
aw="cd '${al}/w'"
tag_remote() { git -C "${al}/w" tag "$1" && git -C "${al}/w" push -q origin "$1" >/dev/null 2>&1; }
check "head_date: UTC committer date, not the commit's own timezone" 0 "-" "^20261011$" "${pre}; ${aw}; gpu_tuned_head_date"
check "head_date: the environment's TZ cannot change it" 0 "-" "^20261011$" "${pre}; ${aw}; TZ=Pacific/Auckland gpu_tuned_head_date; TZ=America/Los_Angeles gpu_tuned_head_date | head -1"
check "head_date: a repo with no commit is a loud error" 1 "cannot read a valid HEAD commit date" "-" "${pre}; gpu_tuned_head_date '${al}/empty'"
check "head_date: takes a directory argument" 0 "-" "^20261011$" "${pre}; cd /; gpu_tuned_head_date '${al}/w'"
check "next_seq: nothing taken -> 0" 0 "-" "^0$" "${pre}; printf '' | gpu_tuned_next_seq 20261011"
check "next_seq: the bare date taken -> 1" 0 "-" "^1$" "${pre}; printf '20261011\n' | gpu_tuned_next_seq 20261011"
check "next_seq: bare and .1 taken -> 2" 0 "-" "^2$" "${pre}; printf '20261011\n20261011.1\n' | gpu_tuned_next_seq 20261011"
check "next_seq: it is the LOWEST unused, so a gap is filled" 0 "-" "^1$" "${pre}; printf '20261011\n20261011.2\n' | gpu_tuned_next_seq 20261011"
check "next_seq: other dates and prefixes do not count" 0 "-" "^0$" "${pre}; printf '20261010\n20261012.1\n202610111\n' | gpu_tuned_next_seq 20261011"
check "next_seq: a bad date is refused" 1 "not a valid YYYYMMDD" "-" "${pre}; printf '' | gpu_tuned_next_seq 20261301"
check "label_seq: bare date is 0, a suffix is its integer" 0 "-" "^0 3 12$" \
  "${pre}; echo \"\$(gpu_tuned_label_seq 20261011) \$(gpu_tuned_label_seq 20261011.3) \$(gpu_tuned_label_seq 20261011.12)\""
check "allocate: first build of the date is the bare date" 0 "-" "^20261011$" "${pre}; ${aw}; gpu_tuned_allocate_date_label"
tag_remote "v0.29.1rc1.dev441+gabc.gb10.cu134.20261011"
check "allocate: a published wheel tag for that date makes the next one .1" 0 "-" "^20261011\\.1$" "${pre}; ${aw}; gpu_tuned_allocate_date_label"
tag_remote "v0.29.1rc1.dev442+gdef.gb10.cu134.20261011.1"
check "allocate: ... and then .2" 0 "-" "^20261011\\.2$" "${pre}; ${aw}; gpu_tuned_allocate_date_label"
tag_remote "v0.7.0+gb10.cu134.tuning.62"; tag_remote "v0.20261011.0-gb10-cu134"; tag_remote "v1.2.3"; tag_remote "v0.29+gb10.cu134.20261010"
check "allocate: legacy counter tags, native tags, plain versions and other dates are ignored" 0 "-" "^20261011\\.2$" "${pre}; ${aw}; gpu_tuned_allocate_date_label"
git -C "${al}/w" tag -d "v0.29.1rc1.dev441+gabc.gb10.cu134.20261011" >/dev/null 2>&1
check "allocate: tags on the REMOTE count even when the local tag is gone" 0 "-" "^20261011\\.2$" "${pre}; ${aw}; gpu_tuned_allocate_date_label"
git -C "${al}/w" tag "v9+gb10.cu134.20261011.2"
check "allocate: a LOCAL-only tag counts too (an unpushed release in progress): .2 exists only locally, so .3" 0 "-" "^20261011\\.3$" "${pre}; ${aw}; gpu_tuned_allocate_date_label"
git -C "${al}/w" tag -d "v9+gb10.cu134.20261011.2" >/dev/null 2>&1
check "allocate: an unreachable remote is a loud error naming the override, never a guess" 1 "cannot read tags from remote 'nowhere'.*GPU_TUNED_LABEL_SEQ" "-" \
  "${pre}; ${aw}; gpu_tuned_allocate_date_label . nowhere"
check "allocate: GPU_TUNED_LABEL_SEQ works offline and skips the lookup" 0 "-" "^20261011\\.3$" \
  "${pre}; ${aw}; GPU_TUNED_LABEL_SEQ=3 gpu_tuned_allocate_date_label . nowhere"
check "allocate: GPU_TUNED_LABEL_SEQ=0 is the bare date, even when it is taken (dev builds)" 0 "-" "^20261011$" \
  "${pre}; ${aw}; GPU_TUNED_LABEL_SEQ=0 gpu_tuned_allocate_date_label . nowhere"
check "allocate: a non-canonical GPU_TUNED_LABEL_SEQ is refused" 1 "canonical integer" "-" \
  "${pre}; ${aw}; GPU_TUNED_LABEL_SEQ=01 gpu_tuned_allocate_date_label"
check "allocate: the result round-trips through local_version_dated and date_label" 0 "-" "^20261011\\.2$" \
  "${pre}; ${aw}; L=\"\$(gpu_tuned_allocate_date_label)\"; V=\"\$(gpu_tuned_local_version_dated gb10 134 \"\$(gpu_tuned_head_date)\" \"\$(gpu_tuned_label_seq \"\$L\")\")\"; gpu_tuned_date_label \"0.1+\${V}\""
rm -rf "${al}"

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
check "cuda_subdir: base, tag and variant" 0 "-" "^/r/_build/cu134/gb10$" \
  "${pre}; gpu_tuned_cuda_subdir /r/_build cu134 gb10"
check "cuda_subdir: variant is optional" 0 "-" "^/r/_stage/cu133$" \
  "${pre}; gpu_tuned_cuda_subdir /r/_stage cu133"
check "cuda_subdir: bad tag fails" 1 "not of the form cu<digits>" "-" \
  "${pre}; gpu_tuned_cuda_subdir /r/_build 13.4 gb10"
check "cuda_subdir: malformed variant fails" 1 "malformed" "-" \
  "${pre}; gpu_tuned_cuda_subdir /r/_build cu133 'gb 10'"
check "cuda_subdir: empty base fails" 1 "base dir is empty" "-" \
  "${pre}; gpu_tuned_cuda_subdir '' cu133 gb10"

# --- protect_torch_pin: version+variant derived from the venv, not typed in ---
# fake_venv <dir> <torch-version-to-report>|- : a bin/python stub that answers
# `-c 'import torch; print(torch.__version__)'` with the given version, or
# fails (like torch not being importable) when the version is "-".
fake_venv() {
    local d="$1" ver="$2"
    mkdir -p "${d}/bin"
    if [[ "${ver}" == "-" ]]; then
        printf '#!/bin/bash\nexit 1\n' > "${d}/bin/python"
    else
        printf '#!/bin/bash\necho %q\n' "${ver}" > "${d}/bin/python"
    fi
    chmod +x "${d}/bin/python"
}
ptp_dir="$(mktemp -d)"
fake_venv "${ptp_dir}/.venv" "0.7.0+gb10.cu134.tuning.35"
check "protect_torch_pin: derives the version from the venv" 0 "-" \
  "^OK: pinned torch==0\\.7\\.0\\+gb10\\.cu134\\.tuning\\.35 .*constraints-gb10\\.txt\\)$" \
  "${pre}; gpu_tuned_protect_torch_pin '${ptp_dir}/.venv'"
check "protect_torch_pin: writes the derived version, not a stale one" 0 "-" \
  "^torch==0\\.7\\.0\\+gb10\\.cu134\\.tuning\\.35$" \
  "${pre}; gpu_tuned_protect_torch_pin '${ptp_dir}/.venv' >/dev/null; grep '^torch==' '${ptp_dir}/constraints-gb10.txt'"
rm -rf "${ptp_dir}"

ptp_dir="$(mktemp -d)"
fake_venv "${ptp_dir}/.venv" "2.14.0.dev20260707+gitc36325c5ba.gb10.cu133"
check "protect_torch_pin: legacy dev-form version still yields the right variant file" 0 "-" \
  "constraints-gb10\\.txt" \
  "${pre}; gpu_tuned_protect_torch_pin '${ptp_dir}/.venv' >/dev/null; ls '${ptp_dir}'/constraints-gb10.txt"
rm -rf "${ptp_dir}"

ptp_dir="$(mktemp -d)"
fake_venv "${ptp_dir}/.venv" "2.5.0+rtx40.cu134.tuning.9"
check "protect_torch_pin: variant is not hardcoded to gb10" 0 "-" \
  "constraints-rtx40\\.txt" \
  "${pre}; gpu_tuned_protect_torch_pin '${ptp_dir}/.venv' >/dev/null; ls '${ptp_dir}'/constraints-rtx40.txt"
rm -rf "${ptp_dir}"

ptp_dir="$(mktemp -d)"
fake_venv "${ptp_dir}/.venv" "2.5.0+rtx40.cu134.tuning.9"
check "protect_torch_pin: an explicit version overrides venv introspection" 0 "-" \
  "^torch==9\\.9\\.9\\+rtx40\\.cu999\\.tuning\\.1$" \
  "${pre}; gpu_tuned_protect_torch_pin '${ptp_dir}/.venv' '9.9.9+rtx40.cu999.tuning.1' >/dev/null; cat '${ptp_dir}/constraints-rtx40.txt' | tail -1"
rm -rf "${ptp_dir}"

ptp_dir="$(mktemp -d)"
fake_venv "${ptp_dir}/.venv" "-"
check "protect_torch_pin: torch not importable is a loud error" 1 \
  "produced no version -- is torch installed" "-" \
  "${pre}; gpu_tuned_protect_torch_pin '${ptp_dir}/.venv'"
rm -rf "${ptp_dir}"

ptp_dir="$(mktemp -d)"
fake_venv "${ptp_dir}/.venv" "2.13.0"
check "protect_torch_pin: a version with no variant marker is a loud error" 1 \
  "no '<variant>\\.cu<digits>' marker found" "-" \
  "${pre}; gpu_tuned_protect_torch_pin '${ptp_dir}/.venv'"
rm -rf "${ptp_dir}"

check "protect_torch_pin: missing venv dir is a loud error" 1 \
  "no such venv dir" "-" \
  "${pre}; gpu_tuned_protect_torch_pin '/nonexistent-venv-dir'"

# --- toolkit loader / verifier (fake toolkit tree, fake dpkg-query and ldd) ---
tk="$(mktemp -d)"
mkdir -p "${tk}/data/toolkits" "${tk}/dflt/toolkits" "${tk}/cuda-99.9/bin" "${tk}/cuda-98.0/lib" "${tk}/fakebin"
printf '%s\n' '#!/bin/bash' 'echo "Cuda compilation tools, release 99.9, V99.9.1"' > "${tk}/cuda-99.9/bin/nvcc"
printf '%s\n' '#!/bin/bash' 'echo -n "${FAKE_NCCL:-1.0-1}"' > "${tk}/fakebin/dpkg-query"
printf '%s\n' '#!/bin/bash' 'cat "${FAKE_LDD_OUT}"' > "${tk}/fakebin/ldd"
chmod +x "${tk}/cuda-99.9/bin/nvcc" "${tk}/fakebin/dpkg-query" "${tk}/fakebin/ldd"
printf '%s\n' 'TOOLKIT_ID="cu999"' 'TOOLKIT_CUDA_VER="99.9"' "TOOLKIT_CUDA_HOME=\"${tk}/cuda-99.9\"" \
  'TOOLKIT_NVCC_RELEASE="99.9"' 'TOOLKIT_NCCL_VERSION="1.0-1"' > "${tk}/data/toolkits/cu999.env"
printf '%s\n' 'TOOLKIT_NVCC_RELEASE="98.0"' > "${tk}/data/toolkits/gb10-cu999.env"
printf '%s\n' 'TOOLKIT_ID="cu111"' 'TOOLKIT_CUDA_VER="1.1"' 'TOOLKIT_CUDA_HOME="/x"' 'TOOLKIT_NVCC_RELEASE="1.1"' > "${tk}/data/toolkits/cu112.env"
lt="${pre}; export GPU_TUNED_PLATFORM=aarch64; gpu_tuned_load_toolkit '${tk}/data'"

check "load_toolkit: unknown id is an error that lists the available ones" 1 \
  "no toolkit file.*cu000" "-" "${lt} rtx40 cu000 2>&1 >&2 | cat >&2; gpu_tuned_load_toolkit '${tk}/data' rtx40 cu000"
check "load_toolkit: available toolkits are listed" 1 "available toolkits:.*cu999" "-" \
  "${lt} rtx40 cu000"
check "load_toolkit: exports CUDA_VER/CUDA_TAG/CUDA_HOME/lib dir" 0 "-" \
  "^99\\.9 cu999 ${tk}/cuda-99.9 ${tk}/cuda-99.9/targets/sbsa-linux/lib$" \
  "${lt} rtx40 cu999; echo \"\${CUDA_VER} \${CUDA_TAG} \${CUDA_HOME} \${GPU_TUNED_TOOLKIT_LIB_DIR}\""
# default: highest by declared CUDA version, not by name (13.10 > 13.9; cu1310 sorts below cu139 by name)
printf '%s\n' 'TOOLKIT_ID="cu139"' 'TOOLKIT_CUDA_VER="13.9"' 'TOOLKIT_CUDA_HOME="/x"' 'TOOLKIT_NVCC_RELEASE="13.9"' > "${tk}/dflt/toolkits/cu139.env"
printf '%s\n' 'TOOLKIT_ID="cu1310"' 'TOOLKIT_CUDA_VER="13.10"' 'TOOLKIT_CUDA_HOME="/y"' 'TOOLKIT_NVCC_RELEASE="13.10"' > "${tk}/dflt/toolkits/cu1310.env"
printf '%s\n' 'TOOLKIT_NVCC_RELEASE="0"' > "${tk}/dflt/toolkits/gb10-cu139.env"
ld="${pre}; export GPU_TUNED_PLATFORM=aarch64; gpu_tuned_load_toolkit '${tk}/dflt' gb10"
check "load_toolkit: no id uses the highest declared CUDA version" 0 "using cu1310 \\(CUDA 13\\.10\\)" "^cu1310 13\\.10 /y$" \
  "${ld}; echo \"\${CUDA_TAG} \${CUDA_VER} \${CUDA_HOME}\""
check "load_toolkit: the default states the full list and the reason" 0 \
  "available:.*cu139\\(13\\.9\\).*cu1310\\(13\\.10\\)|available:.*cu1310\\(13\\.10\\).*cu139\\(13\\.9\\)" "-" "${ld}"
check "load_toolkit: the default message says how to choose another" 0 "set CUDA_TAG" "-" "${ld}"
check "load_toolkit: a per-variant file is not counted as a toolkit in the list" 0 "-" "-" \
  "out=\"\$(${ld} 2>&1)\"; [[ \"\${out}\" != *gb10-cu139* ]]"
check "load_toolkit: no id and no toolkit files is an error" 1 "none defined" "-" \
  "${pre}; mkdir -p '${tk}/empty/toolkits'; gpu_tuned_load_toolkit '${tk}/empty' gb10"
check "load_toolkit: a <variant>-<toolkit>.env overrides the base file" 0 "-" "^98\\.0$" \
  "${lt} gb10 cu999; echo \"\${TOOLKIT_NVCC_RELEASE}\""
check "load_toolkit: the base file applies when no variant file exists" 0 "-" "^99\\.9$" \
  "${lt} rtx40 cu999; echo \"\${TOOLKIT_NVCC_RELEASE}\""
check "load_toolkit: an inherited CUDA_HOME that differs is rejected" 1 "CUDA_HOME is '/usr/local/cuda'" "-" \
  "export CUDA_HOME=/usr/local/cuda; ${lt} rtx40 cu999"
check "load_toolkit: a file whose TOOLKIT_ID disagrees with its name is rejected" 1 "sets TOOLKIT_ID=cu111, expected cu112" "-" \
  "${lt} rtx40 cu112"
check "verify_toolkit: matching nvcc and NCCL pass" 0 "-" "^OK: toolkit cu999: nvcc 99\\.9" \
  "${lt} rtx40 cu999; PATH='${tk}/fakebin':\$PATH gpu_tuned_verify_toolkit"
check "verify_toolkit: an nvcc release mismatch is rejected" 1 "reports release '99\\.9', toolkit cu999 declares 98\\.0" "-" \
  "${lt} gb10 cu999; PATH='${tk}/fakebin':\$PATH gpu_tuned_verify_toolkit"
check "verify_toolkit: a foreign libnccl2 is rejected" 1 "libnccl2 is '2\\.0-9'" "-" \
  "${lt} rtx40 cu999; FAKE_NCCL=2.0-9 PATH='${tk}/fakebin':\$PATH gpu_tuned_verify_toolkit"
check "verify_toolkit: refuses to run before a toolkit is loaded" 1 "no toolkit loaded" "-" \
  "${pre}; gpu_tuned_verify_toolkit"
printf '%s\n' "	libcudart.so.99 => ${tk}/cuda-99.9/lib/libcudart.so.99 (0x1)" "	libc.so.6 => /lib/libc.so.6 (0x2)" > "${tk}/ldd.good"
printf '%s\n' "	libcudart.so.99 => ${tk}/cuda-98.0/lib/libcudart.so.99 (0x1)" > "${tk}/ldd.bad"
mkdir -p "${tk}/cuda-99.9/lib"; : > "${tk}/cuda-99.9/lib/libcudart.so.99"; : > "${tk}/cuda-98.0/lib/libcudart.so.99"
check "verify_toolkit_libs: libs resolving under CUDA_HOME pass" 0 "-" "-" \
  "${lt} rtx40 cu999; FAKE_LDD_OUT='${tk}/ldd.good' PATH='${tk}/fakebin':\$PATH gpu_tuned_verify_toolkit_libs /bin/true"
check "verify_toolkit_libs: libcudart from another tree is rejected" 1 "libcudart.so.99 resolves to .*cuda-98.0.*not under" "-" \
  "${lt} rtx40 cu999; FAKE_LDD_OUT='${tk}/ldd.bad' PATH='${tk}/fakebin':\$PATH gpu_tuned_verify_toolkit_libs /bin/true"
rm -rf "${tk}"

# --- repo.env: repo-specific settings must not change shared definitions ---
re="$(mktemp -d)"
printf '%s\n' 'GGML_FLAGS="-DGGML_CUDA_FA=ON"' 'REPO_BINARIES="llama-server llama-quantize"' > "${re}/ok.env"
printf '%s\n' 'GPU_TUNED_CUDA_ARCH="120"' 'GGML_FLAGS="x"' > "${re}/one.env"
printf '%s\n' 'GPU_TUNED_CUDA_ARCH="120"' 'GPU_TUNED_HW_LABEL="other"' 'CUDA_HOME=/usr/local/cuda' > "${re}/many.env"
printf '%s\n' 'unset GPU_TUNED_PLATFORM' > "${re}/unset.env"
printf '%s\n' 'TOOLKIT_NCCL_VERSION="9.9"' > "${re}/newkey.env"
base="${pre}; export GPU_TUNED_VARIANT=gb10 GPU_TUNED_PLATFORM=aarch64 GPU_TUNED_CUDA_ARCH=121a GPU_TUNED_HW_LABEL=lbl CUDA_HOME=/usr/local/cuda-13.3"
check "repo_env: repo-specific keys load and are visible" 0 "-" "^-DGGML_CUDA_FA=ON llama-server llama-quantize$" \
  "${base}; gpu_tuned_load_repo_env '${re}/ok.env'; echo \"\${GGML_FLAGS} \${REPO_BINARIES}\""
check "repo_env: changing a protected key is a loud error naming old and new" 1 \
  "GPU_TUNED_CUDA_ARCH: '121a' -> '120'" "-" "${base}; gpu_tuned_load_repo_env '${re}/one.env'"
check "repo_env: every conflict is listed, not just the first" 1 \
  "GPU_TUNED_HW_LABEL: 'lbl' -> 'other'" "-" "${base}; gpu_tuned_load_repo_env '${re}/many.env'"
check "repo_env: CUDA_HOME pointed at the unversioned symlink is flagged" 1 \
  "CUDA_HOME: '/usr/local/cuda-13.3' -> '/usr/local/cuda'" "-" "${base}; gpu_tuned_load_repo_env '${re}/many.env'"
check "repo_env: unsetting a protected key is flagged" 1 "GPU_TUNED_PLATFORM: 'aarch64' -> \(unset\)" "-" \
  "${base}; gpu_tuned_load_repo_env '${re}/unset.env'"
check "repo_env: newly setting a protected key that was unset is flagged" 1 \
  "TOOLKIT_NCCL_VERSION: was unset" "-" "${base}; gpu_tuned_load_repo_env '${re}/newkey.env'"
check "repo_env: a missing file is an error" 1 "no such file" "-" "${base}; gpu_tuned_load_repo_env '${re}/none.env'"
rm -rf "${re}"

echo; echo "passed=${PASS} failed=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
