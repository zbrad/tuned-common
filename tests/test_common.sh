#!/bin/bash
# Regression tests for tuned-common.sh: loud failures + version-style helpers.
# Usage: bash tests/test_common.sh   (exit 0 = all pass)
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tuned-common.sh"
PASS=0; FAIL=0; SKIPPED=0
# skip <name> <reason> -- a test that could not run is reported, never counted as passed
skip() { SKIPPED=$((SKIPPED+1)); echo "SKIP - $1 ($2)"; }

# check <name> <want-exit> <stderr-must-match|-> <stdout-must-match|-> <script...>
check() {
    local name="$1" want_rc="$2" err_re="$3" out_re="$4" script="$5" out err rc
    out="$(mktemp)"; err="$(mktemp)"
    # The toolkit tests run without the host's own CUDA directories (/etc/profile.d/nv_paths.sh) on PATH, which the
    # toolkit PATH gate would report; the other tests keep the host PATH (some need its nvcc).
    local p="${PATH}"
    [[ "${name}" =~ ^(select|verify|load)_toolkit ]] && p="$(tr ':' '\n' <<< "${PATH}" | grep -v '/cuda[^:]*/bin' | paste -sd:)"
    PATH="${p}" bash -c "${script}" >"${out}" 2>"${err}"; rc=$?
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
    git init -q --bare -b tuned-builds "${gate}/origin.git"; git remote add origin "${gate}/origin.git"; git push -q origin tuned-builds
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
# --- publish gate: wheel version label ---
w="torch-2.15.0%s-cp314-cp314-linux_aarch64.whl"
wl() { printf "$w" "$1"; }
check "wheel_label: a date label passes" 0 "-" "-" "${pre}; gpu_tuned_check_wheel_label /x/$(wl +gb10.cu134.20261011)"
check "wheel_label: a date label with a sequence passes" 0 "-" "-" "${pre}; gpu_tuned_check_wheel_label $(wl +gb10.cu134.20261011.2)"
check "wheel_label: an scm segment before the variant passes" 0 "-" "-" "${pre}; gpu_tuned_check_wheel_label $(wl +g97106f879.gb10.cu133.20261011)"
check "wheel_label: no local version is refused" 1 "no local version label" "-" "${pre}; gpu_tuned_check_wheel_label torch-2.15.0-cp314-cp314-linux_aarch64.whl"
check "wheel_label: platform-only +cu133 is refused" 1 "is not <variant>" "-" "${pre}; gpu_tuned_check_wheel_label $(wl +cu133)"
check "wheel_label: the counter is refused by default" 1 "is not <variant>" "-" "${pre}; gpu_tuned_check_wheel_label $(wl +gb10.cu134.tuning.62)"
check "wheel_label: the counter passes with the override, loudly" 0 "retired tuning.N counter" "-" "${pre}; GPU_TUNED_ALLOW_COUNTER_LABEL=1 gpu_tuned_check_wheel_label $(wl +gb10.cu134.tuning.62)"
check "wheel_label: legacy tuning.vN is refused even with the override" 1 "is not <variant>" "-" "${pre}; GPU_TUNED_ALLOW_COUNTER_LABEL=1 gpu_tuned_check_wheel_label $(wl +gb10.cu134.tuning.v34)"
check "wheel_label: an impossible calendar date is refused" 1 "not a real calendar date" "-" "${pre}; gpu_tuned_check_wheel_label $(wl +gb10.cu134.20260230)"
check "wheel_label: a .0 sequence is accepted (first build of the date)" 0 "-" "-" "${pre}; gpu_tuned_check_wheel_label $(wl +gb10.cu134.20261011.0)"
check "wheel_label: a zero-padded sequence is refused" 1 "is not <variant>" "-" "${pre}; gpu_tuned_check_wheel_label $(wl +gb10.cu134.20261011.01)"
check "wheel_label: a non-wheel name is refused" 1 "not a wheel file name" "-" "${pre}; gpu_tuned_check_wheel_label model.tar.gz"
# --- smoke test of a built wheel (toy wheels; the GPU part needs a real torch wheel) ---
toy="$(mktemp -d)"
python3 - "${toy}" <<'PY'
import sys, zipfile
out = sys.argv[1]
def make(dist, filever, modver, tag="py3-none-any", metaver=None):
    name = f"{out}/{dist}-{filever}-{tag}.whl"
    di = f"{dist}-{filever}.dist-info"
    files = {
        f"{dist}/__init__.py": f'__version__ = "{modver}"\n',
        f"{di}/METADATA": f"Metadata-Version: 2.1\nName: {dist}\nVersion: {metaver or filever}\n",
        f"{di}/WHEEL": "Wheel-Version: 1.0\nGenerator: toy\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    }
    files[f"{di}/RECORD"] = "".join(f"{p},,\n" for p in [*files, f"{di}/RECORD"])
    with zipfile.ZipFile(name, "w") as z:
        for p, c in files.items():
            z.writestr(p, c)
make("toysmoke", "1.0+gb10.cu134.20261011", "1.0+gb10.cu134.20261011")
make("toydrift", "1.0+gb10.cu134.20261011", "1.0+gb10.cu134.20261010")
make("toyold", "1.0+gb10.cu134.tuning.62", "1.0+gb10.cu134.tuning.62")
make("toyabi", "1.0+gb10.cu134.20261011", "1.0+gb10.cu134.20261011", tag="cp27-cp27mu-manylinux1_x86_64")
make("toymeta", "1.0+gb10.cu134.20261011", "1.0+gb10.cu134.20261011", metaver="1.0+gb10.cu134.20261010")
make("toystatic", "1.0+gb10.cu134.20261011", "1.0")
PY
mkdir "${toy}/none"
smoke="${pre}; export GPU_TUNED_SMOKE_FIND_LINKS='${toy}/none'"
check "smoke: a clean wheel installs, loads, and reports one matching dist" 0 "-" "OK: gpu_tuned_smoke_wheel: toysmoke-1.0.* installs and loads cleanly" \
  "${smoke}; gpu_tuned_smoke_wheel '${toy}/toysmoke-1.0+gb10.cu134.20261011-py3-none-any.whl' toysmoke toysmoke"
check "smoke: a module whose __version__ differs from the file name is refused" 1 "__version__ is '1.0\\+gb10.cu134.20261010'" "-" \
  "${smoke}; gpu_tuned_smoke_wheel '${toy}/toydrift-1.0+gb10.cu134.20261011-py3-none-any.whl' toydrift toydrift"
check "smoke: installed metadata that disagrees with the file name is refused" 1 "installed toymeta versions are '1.0\\+gb10.cu134.20261010'" "-" \
  "${smoke}; gpu_tuned_smoke_wheel '${toy}/toymeta-1.0+gb10.cu134.20261011-py3-none-any.whl' toymeta toymeta"
check "smoke: a static __version__ without the local label is refused by default" 1 "__version__ is '1.0', expected '1.0\\+gb10.cu134.20261011'" "-" \
  "${smoke}; gpu_tuned_smoke_wheel '${toy}/toystatic-1.0+gb10.cu134.20261011-py3-none-any.whl' toystatic toystatic"
check "smoke: GPU_TUNED_SMOKE_MODULE_VERSION=base accepts the base version" 0 "-" "OK: gpu_tuned_smoke_wheel" \
  "${smoke}; GPU_TUNED_SMOKE_MODULE_VERSION=base gpu_tuned_smoke_wheel '${toy}/toystatic-1.0+gb10.cu134.20261011-py3-none-any.whl' toystatic toystatic"
check "smoke: base mode still refuses a module on a different base version" 1 "__version__ is '1.0\\+gb10.cu134.20261010', expected '1.0'" "-" \
  "${smoke}; GPU_TUNED_SMOKE_MODULE_VERSION=base gpu_tuned_smoke_wheel '${toy}/toydrift-1.0+gb10.cu134.20261011-py3-none-any.whl' toydrift toydrift"
check "smoke: the retired counter label is refused before any install" 1 "is not <variant>" "-" \
  "${smoke}; gpu_tuned_smoke_wheel '${toy}/toyold-1.0+gb10.cu134.tuning.62-py3-none-any.whl' toyold toyold"
check "smoke: skipping the label check is printed as SKIP" 0 "-" "SKIP: gpu_tuned_smoke_wheel: version label check" \
  "${smoke}; GPU_TUNED_SMOKE_SKIP_LABEL=1 gpu_tuned_smoke_wheel '${toy}/toyold-1.0+gb10.cu134.tuning.62-py3-none-any.whl' toyold toyold"
check "smoke: a wheel built for another python is refused up front" 1 "is built for cp27" "-" \
  "${smoke}; gpu_tuned_smoke_wheel '${toy}/toyabi-1.0+gb10.cu134.20261011-cp27-cp27mu-manylinux1_x86_64.whl' toyabi toyabi"
check "smoke: a stamp library that is not in the wheel is refused" 1 "stamp library libnope.so not found" "-" \
  "${smoke}; gpu_tuned_smoke_wheel '${toy}/toysmoke-1.0+gb10.cu134.20261011-py3-none-any.whl' toysmoke toysmoke some_section libnope.so"
check "smoke: a pin that the wheel satisfies is installed and named" 0 "-" "pinned: toysmoke==1.0\\+gb10.cu134.20261011" \
  "${smoke}; GPU_TUNED_SMOKE_PIN='toysmoke==1.0+gb10.cu134.20261011' gpu_tuned_smoke_wheel '${toy}/toysmoke-1.0+gb10.cu134.20261011-py3-none-any.whl' toysmoke toysmoke"
check "smoke: a pin that nothing can satisfy fails the install" 1 "pip could not install" "-" \
  "${smoke}; GPU_TUNED_SMOKE_PIN='toysmoke==9.9' gpu_tuned_smoke_wheel '${toy}/toysmoke-1.0+gb10.cu134.20261011-py3-none-any.whl' toysmoke toysmoke"
check "smoke: a missing wheel and missing arguments are refused" 1 "usage" "-" "${pre}; gpu_tuned_smoke_wheel"
check "smoke: the throwaway venv is removed on success" 0 "-" "^OK$" \
  "${smoke}; mkdir '${toy}/tmp'; TMPDIR='${toy}/tmp' gpu_tuned_smoke_wheel '${toy}/toysmoke-1.0+gb10.cu134.20261011-py3-none-any.whl' toysmoke toysmoke >/dev/null && [ -z \"\$(ls -A '${toy}/tmp')\" ] && echo OK"
rm -rf "${toy}"
# --- gpu_tuned_jobs ---
for pair in 20:17 12:7 8:5 4:2 3:1 1:1 5:3 64:61; do
  check "jobs: ${pair%%:*} cores -> ${pair##*:}" 0 "-" "^${pair##*:}$" \
    "${pre}; GPU_TUNED_NPROC=${pair%%:*} gpu_tuned_jobs"
done

# --- ninja timing (gpu_tuned_ninja_timing) ---
nt="$(mktemp -d)"
printf '# ninja log v7\n0\t100\t1\told.cu.o\th\n' > "${nt}/log"
nt_off="$(wc -c < "${nt}/log")"
printf '10\t5010\t2\tCMakeFiles/x.dir/a.cu.o\th1\n20\t1020\t3\tCMakeFiles/x.dir/b.cpp.o\th2\n5020\t6020\t4\t_x.abi3.so\th3\n' >> "${nt}/log"
check "ninja_timing: only targets after the offset are reported, with their kind" 0 "-" "^Timing: 3 units, wall 6s, summed unit time 7s$" \
  "${pre}; gpu_tuned_ninja_timing '${nt}/log' ${nt_off} '${nt}/out.tsv' | grep '^Timing'"
check "ninja_timing: the TSV has seconds, kind, name, status; the strip prefix is removed" 0 "-" "^5.0	nvcc	x.dir/a.cu.o	0$" \
  "${pre}; gpu_tuned_ninja_timing '${nt}/log' ${nt_off} '${nt}/out.tsv' CMakeFiles/ >/dev/null; sed -n 1p '${nt}/out.tsv'"
check "ninja_timing: an earlier run's targets (before the offset) are not counted" 0 "-" "^3$" \
  "${pre}; gpu_tuned_ninja_timing '${nt}/log' ${nt_off} '${nt}/out.tsv' >/dev/null; wc -l < '${nt}/out.tsv' | tr -d ' '"
check "ninja_timing: a no-op build (nothing after the offset) fails and writes no file" 1 "no targets were built" "-" \
  "${pre}; rm -f '${nt}/noop.tsv'; rc=0; gpu_tuned_ninja_timing '${nt}/log' \$(wc -c < '${nt}/log') '${nt}/noop.tsv' || rc=\$?; [ ! -e '${nt}/noop.tsv' ] && exit \$rc"
check "ninja_timing: a log shorter than the offset (replaced during the build) fails" 1 "smaller" "-" \
  "${pre}; gpu_tuned_ninja_timing '${nt}/log' 99999 '${nt}/x.tsv'"
check "ninja_timing: a missing log fails" 1 "no ninja log" "-" "${pre}; gpu_tuned_ninja_timing '${nt}/none' 0 '${nt}/x.tsv'"
# --- verify_venv with a leftover .egg-info and a fresh venv, under set -euo pipefail ---
vv="$(mktemp -d)"
python3 -m venv "${vv}/venv" >/dev/null 2>&1
mkdir -p "${vv}/repo/leftover.egg-info"
printf 'Metadata-Version: 2.1\nName: leftover\nVersion: 1.0\n' > "${vv}/repo/leftover.egg-info/PKG-INFO"
check "verify_venv: a fresh venv without the package passes under set -euo pipefail" 0 "-" "^OK$" \
  "set -euo pipefail; ${pre}; gpu_tuned_verify_venv '${vv}/venv' '${vv}/repo' >/dev/null; echo OK"
mkdir -p "${vv}/repo2/leftover.egg-info"
printf 'Metadata-Version: 2.1\nName: leftover\nVersion: 2.0\n' > "${vv}/repo2/leftover.egg-info/PKG-INFO"
# an installed "leftover 1.0" in the venv: a dist-info directory is all pip show needs
sp="$("${vv}/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
mkdir -p "${sp}/leftover-1.0.dist-info"
printf 'Metadata-Version: 2.1\nName: leftover\nVersion: 1.0\n' > "${sp}/leftover-1.0.dist-info/METADATA"
check "verify_venv: a real version mismatch is still refused" 1 "does not match" "-" \
  "set -euo pipefail; ${pre}; gpu_tuned_verify_venv '${vv}/venv' '${vv}/repo2'"
rm -rf "${vv}"
rm -rf "${nt}"
check "publish_release: a bad wheel label is refused before gh is called" 1 "no local version label" "-" \
  "${pre}; ${ingate}; rc=0; gpu_tuned_publish_release o/r v0.20261011.0-gb10-cu134 title notes 'torch-2.15.0-cp314-cp314-linux_aarch64.whl#w' || rc=\$?; [ ! -s '${gate}/gh.log' ] && exit \$rc"
check "publish_release: a good wheel label reaches gh, label suffix ignored" 0 "-" "OK: published" \
  "${pre}; ${ingate}; gpu_tuned_publish_release o/r v0.20261011.0-gb10-cu134 title notes '$(wl +gb10.cu134.20261011)#torch'; grep -q 'release create v0.20261011.0-gb10-cu134' '${gate}/gh.log'"
check "publish_release: a non-wheel asset is not label-checked" 0 "-" "OK: published" \
  "${pre}; ${ingate}; gpu_tuned_publish_release o/r v0.20261011.0-gb10-cu134 title notes 'llama-cpp-1-gb10.tar.gz'"
# --- JSON build-info stamp ---
bi="$(mktemp -d)"
printf 'int main(void){return 0;}\n' > "${bi}/m.c"; gcc -o "${bi}/m" "${bi}/m.c"
git init -q "${bi}/repo"; ( cd "${bi}/repo" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one )
check "build_info_json: nested, typed fields" 0 "-" '^\{"schema":"tuned-build-info/1","release":"v0\.20261011\.0-gb10-cu134","n":3,"ok":true,"cuda":\{"tag":"cu134"\},"gone":null\}$' \
  "${pre}; gpu_tuned_build_info_json release=v0.20261011.0-gb10-cu134 n:int=3 ok:bool=true cuda.tag=cu134 gone:null="
check "build_info_json: quotes, backslashes and unicode survive a round trip" 0 "-" "-" \
  "${pre}; gpu_tuned_build_info_json 'x=a \"q\" \\\\ b é' | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"x\"]==\"a \\\"q\\\" \\\\\\\\ b é\"'"
check "build_info_json: a control character is refused" 1 "control character" "-" "${pre}; gpu_tuned_build_info_json \$'x=a\\nb'"
check "build_info_json: a non-canonical int is refused" 1 "canonical integer" "-" "${pre}; gpu_tuned_build_info_json n:int=007"
check "build_info_json: a bad bool is refused" 1 "true or false" "-" "${pre}; gpu_tuned_build_info_json b:bool=yes"
check "build_info_json: a duplicate field is refused" 1 "duplicate" "-" "${pre}; gpu_tuned_build_info_json a=1 a=2"
check "build_info_json: a value that is also a parent is refused" 1 "both a value and a parent" "-" "${pre}; gpu_tuned_build_info_json a=1 a.b=2"
check "build_info_json: an upper-case or dashed field name is refused" 1 "bad field name" "-" "${pre}; gpu_tuned_build_info_json Bad-Name=1"
check "build_info_json: an argument without = is refused" 1 "not name=value" "-" "${pre}; gpu_tuned_build_info_json lonely"
check "embed_json: stamps an ELF and reads back as valid JSON with git fields" 0 "-" '"fork":\{"url":"[^"]*","commit":"[0-9a-f]{40}","dirty":false,"commit_count":1\}' \
  "${pre}; cp '${bi}/m' '${bi}/a'; cd '${bi}/repo'; gpu_tuned_embed_build_info_json '${bi}/a' release=v0.20261011.0-gb10-cu134 && gpu_tuned_read_build_info '${bi}/a'"
check "embed_json: the stamped binary still runs" 0 "-" "-" "${pre}; cd '${bi}/repo'; gpu_tuned_embed_build_info_json '${bi}/a' release=r && '${bi}/a'"
check "embed_json: stamping twice leaves exactly one section" 0 "-" "^1$" \
  "${pre}; cd '${bi}/repo'; gpu_tuned_embed_build_info_json '${bi}/a' release=r1; gpu_tuned_embed_build_info_json '${bi}/a' release=r2; readelf -S -W '${bi}/a' | grep -c '\\.tuned_build_info'"
check "embed_json: the second stamp replaces the first" 0 "-" '"release":"r2"' "${pre}; gpu_tuned_read_build_info '${bi}/a'"
check "embed_json: a caller field overrides an automatic one" 0 "-" '"url":"https://example.org/x"' \
  "${pre}; cd '${bi}/repo'; gpu_tuned_embed_build_info_json '${bi}/a' fork.url=https://example.org/x && gpu_tuned_read_build_info '${bi}/a'"
check "embed_json: a dirty tracked file is marked dirty" 0 "-" '"dirty":true' \
  "${pre}; cd '${bi}/repo'; echo x > f; git add f; git -c user.email=t@t -c user.name=t commit -q -m two; echo y >> f; gpu_tuned_embed_build_info_json '${bi}/a' release=r; gpu_tuned_read_build_info '${bi}/a'; git checkout -q f"
check "embed_json: an upstream remote adds its url and a declared ref" 0 "-" '"upstream":\{"url":"https://github.com/o/r","ref":"upstream/main"' \
  "${pre}; cd '${bi}/repo'; git remote add upstream https://github.com/o/r.git; git update-ref refs/remotes/upstream/main HEAD; GPU_TUNED_UPSTREAM_REF=upstream/main gpu_tuned_embed_build_info_json '${bi}/a' release=r; gpu_tuned_read_build_info '${bi}/a'"
check "embed_json: an undeclared upstream ref is null, not omitted" 0 "-" '"ref":null' \
  "${pre}; cd '${bi}/repo'; gpu_tuned_embed_build_info_json '${bi}/a' release=r; gpu_tuned_read_build_info '${bi}/a'"
check "embed_json: a file that is not there is refused" 1 "is not a file" "-" "${pre}; gpu_tuned_embed_build_info_json '${bi}/nope' release=r"
check "read_build_info: a legacy text stamp is wrapped as JSON" 0 "-" '"schema":"text".*"section":".legacy_build_info".*legacy stamp' \
  "${pre}; cp '${bi}/m' '${bi}/l'; printf 'legacy stamp v1\\n' > '${bi}/l.txt'; objcopy --add-section .legacy_build_info='${bi}/l.txt' '${bi}/l'; gpu_tuned_read_build_info '${bi}/l'"
check "read_build_info: a file with no stamp is refused" 1 "has no .tuned_build_info" "-" "${pre}; gpu_tuned_read_build_info '${bi}/m'"
check "read_build_info: does not rewrite the file it reads" 0 "-" "-" \
  "${pre}; a=\$(sha256sum '${bi}/a'); gpu_tuned_read_build_info '${bi}/a' >/dev/null; [ \"\$a\" = \"\$(sha256sum '${bi}/a')\" ]"
check "verify_json: matching fields pass, with types" 0 "-" "-" \
  "${pre}; cd '${bi}/repo'; gpu_tuned_embed_build_info_json '${bi}/a' release=r n:int=5 k.ok:bool=true; gpu_tuned_verify_build_info_json '${bi}/a' release=r n:int=5 k.ok:bool=true"
check "verify_json: a wrong field names it and both values" 1 "field release is 'r', expected 'other'" "-" "${pre}; gpu_tuned_verify_build_info_json '${bi}/a' release=other"
check "verify_json: a missing field fails" 1 "field nothing.here is None" "-" "${pre}; gpu_tuned_verify_build_info_json '${bi}/a' nothing.here=x"
rm -rf "${bi}"
# --- smoke: libraries resolve inside the extracted package ---
sm="$(mktemp -d)"; mkdir -p "${sm}/pkg/lib" "${sm}/other"
printf 'int foo(void){return 7;}\n' > "${sm}/foo.c"; printf 'int foo(void); int main(void){return foo()==7?0:1;}\n' > "${sm}/main.c"
gcc -shared -fPIC -Wl,-soname,libfoo-tuned.so -o "${sm}/pkg/lib/libfoo-tuned.so" "${sm}/foo.c"
cp "${sm}/pkg/lib/libfoo-tuned.so" "${sm}/other/libfoo-tuned.so"
gcc -o "${sm}/main" "${sm}/main.c" -L"${sm}/other" -lfoo-tuned -Wl,-rpath,"${sm}/other"
check "resolves_in: a library found inside the package passes" 0 "-" "-" "${pre}; gpu_tuned_verify_resolves_in '${sm}/pkg' '${sm}/main' '^libfoo-tuned'"
check "resolves_in: a library absent from the package resolves outside and is refused" 1 "resolves outside" "-" \
  "${pre}; mkdir -p '${sm}/empty/lib'; gpu_tuned_verify_resolves_in '${sm}/empty' '${sm}/main' '^libfoo-tuned'"
check "resolves_in: a regex that matches nothing is refused" 1 "does not list a library" "-" \
  "${pre}; gpu_tuned_verify_resolves_in '${sm}/pkg' '${sm}/main' '^libnothing'"
rm -rf "${sm}"
# --- newest release tag ---
nt="v26.12-gb10-cu134-g0fa8a51f\nv0.20261015.2-gb10-cu134\nv0.20261015.10-gb10-cu134\nv0.20261016.0-gb10-cu133\nv0.20261014.0-gb10-cu134"
check "newest_tag: a sequence ranks as a number (.10 above .2), not by list order" 0 "-" "^v0\\.20261015\\.10-gb10-cu134$" \
  "${pre}; printf '${nt}\n' | gpu_tuned_newest_release_tag gb10 cu134"
check "newest_tag: another toolkit's tag is not picked" 0 "-" "^v0\\.20261016\\.0-gb10-cu133$" \
  "${pre}; printf '${nt}\n' | gpu_tuned_newest_release_tag gb10 cu133"
check "newest_tag: a date-label tag beats an older-form tag listed first" 0 "-" "^v0\\.20261015" \
  "${pre}; printf 'v26.12-gb10-cu134-g0fa8a51f\nv0.20261015.0-gb10-cu134\n' | gpu_tuned_newest_release_tag gb10 cu134"
check "newest_tag: with no date-label tag it falls back to the older form, noting it" 0 "-" "older-form tag v26.12-gb10-cu134-g0fa8a51f" \
  "${pre}; printf 'v26.12-gb10-cu134-g0fa8a51f\nv26.12-gb10-cu134-g3a508503\n' | gpu_tuned_newest_release_tag gb10 cu134 2>&1"
check "newest_tag: no matching tag returns 1" 1 "." "-" "${pre}; printf 'v0.20261015.0-rtx50-cu134\n' | gpu_tuned_newest_release_tag gb10 cu134"
check "release_tag: a native date tag passes" 0 "-" "-" "${pre}; gpu_tuned_check_release_tag v0.20261011.0-gb10-cu134"
check "release_tag: a native date tag with a sequence passes" 0 "-" "-" "${pre}; gpu_tuned_check_release_tag v0.20261011.3-gb10-cu134"
check "release_tag: a wheel tag with a date label passes" 0 "-" "-" "${pre}; gpu_tuned_check_release_tag v2.15.0+gb10.cu134.20261011"
check "release_tag: the sha form is refused" 1 "carries no date label" "-" "${pre}; gpu_tuned_check_release_tag v26.12-gb10-cu134-g0fa8a51f"
check "release_tag: a commit-count tag is refused" 1 "carries no date label" "-" "${pre}; gpu_tuned_check_release_tag v11258-gb10-cu133"
check "release_tag: an impossible date is refused" 1 "carries no date label" "-" "${pre}; gpu_tuned_check_release_tag v0.20260230.0-gb10-cu134"
check "release_tag: a hyphenated sequence is refused" 1 "carries no date label" "-" "${pre}; gpu_tuned_check_release_tag v0-20261011-0-gb10-cu134"
check "release_tag: the counter form passes only with the override, loudly" 0 "-" "carries no date label" \
  "${pre}; GPU_TUNED_ALLOW_COUNTER_LABEL=1 gpu_tuned_check_release_tag v11258-gb10-cu133 2>&1"
check "publish_release: a sha-form tag is refused before gh is called" 1 "carries no date label" "-" \
  "${pre}; ${ingate}; rc=0; gpu_tuned_publish_release o/r v26.12-gb10-cu134-g0fa8a51f title notes 'a.tar.gz#a' || rc=\$?; [ ! -s '${gate}/gh.log' ] && exit \$rc"
check "publish_release: a dirty tree is refused before gh is ever called" 1 "dirty tree" "-" \
  "${pre}; ${ingate}; echo 2 >> tracked; rc=0; gpu_tuned_publish_release o/r v0.20261011.0-gb10-cu134 title notes asset || rc=\$?; git checkout -q tracked; [ ! -s '${gate}/gh.log' ] && exit \$rc"
check "require_pushed: a pushed HEAD passes" 0 "-" "OK: HEAD [0-9a-f]{9} is on origin" "${pre}; ${ingate}; gpu_tuned_require_pushed"
check "require_pushed: an unpushed commit is refused" 1 "not on any origin branch" "-" \
  "${pre}; ${ingate}; echo u >> tracked; git commit -qam unpushed; rc=0; gpu_tuned_require_pushed || rc=\$?; git reset -q --hard HEAD~1; exit \$rc"
check "require_pushed: no origin remote is refused" 1 "no 'origin' remote" "-" \
  "${pre}; rm -rf '${gate}/noremote'; git init -q -b main '${gate}/noremote'; cd '${gate}/noremote'; git -c user.name=t -c user.email=t@t commit -q --allow-empty -m x; gpu_tuned_require_pushed"
check "publish_release: an unpushed commit is refused before gh is called" 1 "not on any origin branch" "-" \
  "${pre}; ${ingate}; echo u >> tracked; git commit -qam unpushed; rc=0; gpu_tuned_publish_release o/r v0.20261011.0-gb10-cu134 title notes asset || rc=\$?; git reset -q --hard HEAD~1; [ ! -s '${gate}/gh.log' ] && exit \$rc"
check "publish_release: the release targets the pushed HEAD commit, not a branch name" 0 "-" "-" \
  "${pre}; ${ingate}; gpu_tuned_publish_release o/r v0.20261011.0-gb10-cu134 title notes asset >/dev/null; grep -q -- \"--target \$(git rev-parse HEAD)\" '${gate}/gh.log'"
check "publish_release: GPU_TUNED_RELEASE_TARGET overrides the target" 0 "-" "-" \
  "${pre}; ${ingate}; GPU_TUNED_RELEASE_TARGET=somebranch gpu_tuned_publish_release o/r v0.20261011.0-gb10-cu134 title notes asset >/dev/null; grep -q -- '--target somebranch' '${gate}/gh.log'"
check "publish_release: a clean tree reaches gh create" 0 "-" "OK: published o/r@v0.20261011.0-gb10-cu134" \
  "${pre}; ${ingate}; gpu_tuned_publish_release o/r v0.20261011.0-gb10-cu134 title notes asset; grep -q 'release create v0.20261011.0-gb10-cu134' '${gate}/gh.log'"
rm -rf "${gate}"

# --- date-form wheel label ---
check "dated label: the first build of the day is written .0" 0 "-" "^gb10\.cu134\.20261010\.0$" \
  "${pre}; gpu_tuned_local_version_dated gb10 134 20261010"
check "dated label: seq 0 is the same as omitted" 0 "-" "^gb10\.cu134\.20261010\.0$" \
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
check "date_label: a .0 sequence reads as the bare date" 0 "-" "^20261010$" \
  "${pre}; gpu_tuned_date_label '0.7.0+gb10.cu134.20261010.0'"
check "date_label: a zero-padded sequence is not a label" 0 "-" "^\\[\\]$" \
  "${pre}; X=\"\$(gpu_tuned_date_label '0.7.0+gb10.cu134.20261010.01')\"; echo \"[\${X}]\""
check "date_label: an impossible date is not a label" 0 "-" "^\\[\\]$" \
  "${pre}; X=\"\$(gpu_tuned_date_label '0.7.0+gb10.cu134.20260230')\"; echo \"[\${X}]\""
check "date_label: a native tag with seq 0 reads as the bare date" 0 "-" "^20261011$" "${pre}; gpu_tuned_date_label 'v0.20261011.0-gb10-cu134'"
check "date_label: a native tag with seq 3 reads date.seq" 0 "-" "^20261011\\.3$" "${pre}; gpu_tuned_date_label 'v0.20261011.3-gb10-cu134'"
check "date_label: a native tag with an impossible date is not a label" 0 "-" "^\\[\\]$" \
  "${pre}; X=\"\$(gpu_tuned_date_label 'v0.20260230.0-gb10-cu134')\"; echo \"[\${X}]\""
check "date_label: a native tag with a leading-zero seq is not a label" 0 "-" "^\\[\\]$" \
  "${pre}; X=\"\$(gpu_tuned_date_label 'v0.20261011.01-gb10-cu134')\"; echo \"[\${X}]\""
check "date_label: an old v<N>-<variant>-cu tag is not a label" 0 "-" "^\\[\\]$" \
  "${pre}; X=\"\$(gpu_tuned_date_label 'v11243-gb10-cu133')\"; echo \"[\${X}]\""
check "native_tag: bare date writes seq 0" 0 "-" "^v0\\.20261011\\.0-gb10-cu134$" "${pre}; gpu_tuned_native_tag gb10 cu134 20261011"
check "native_tag: date.seq keeps the seq" 0 "-" "^v0\\.20261011\\.2-gb10-cu134$" "${pre}; gpu_tuned_native_tag gb10 cu134 20261011.2"
check "native_tag: round-trips through date_label" 0 "-" "^20261011\\.2$" "${pre}; gpu_tuned_date_label \"\$(gpu_tuned_native_tag gb10 cu134 20261011.2)\""
check "native_tag: a bad label, cuda tag or variant is refused" 1 "gpu_tuned_native_tag" "-" "${pre}; gpu_tuned_native_tag gb10 cu134 20261011.0"
check "native_tag: a cuda value without the cu prefix is refused" 1 "gpu_tuned_native_tag" "-" "${pre}; gpu_tuned_native_tag gb10 134 20261011"
check "native_tag: sequence allocation sees native tags as taken" 0 "-" "^1$" \
  "${pre}; printf 'v0.20261011.0-gb10-cu134\\nv0.20260101.0-gb10-cu133\\n' | while read t; do gpu_tuned_date_label \"\$t\"; done | gpu_tuned_next_seq 20261011"
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
mkdir -p "${al}/cuda-13.4/bin"; printf '#!/bin/sh\nprintf "Cuda compilation tools, release 13.4, V13.4.48\\n"\n' > "${al}/cuda-13.4/bin/nvcc"; chmod +x "${al}/cuda-13.4/bin/nvcc"
check "build_local_version: the whole suffix, from nvcc, HEAD's UTC date and the next free sequence" 0 "-" "^gb10\\.cu134\\.20261011\\.2$" \
  "${pre}; ${aw}; CUDA_HOME='${al}/cuda-13.4' gpu_tuned_build_local_version gb10 ."
check "build_local_version: GPU_TUNED_LABEL_SEQ=0 is the dev-build form, no lookup" 0 "-" "^gb10\\.cu134\\.20261011\\.0$" \
  "${pre}; ${aw}; CUDA_HOME='${al}/cuda-13.4' GPU_TUNED_LABEL_SEQ=0 gpu_tuned_build_local_version gb10 . nowhere"
check "build_local_version: no CUDA_HOME is a loud error" 1 "CUDA_HOME is not set" "-" \
  "${pre}; ${aw}; unset CUDA_HOME; gpu_tuned_build_local_version gb10 ."
check "build_local_version: an unreadable remote is a loud error, not a guessed label" 1 "cannot read tags from remote" "-" \
  "${pre}; ${aw}; CUDA_HOME='${al}/cuda-13.4' gpu_tuned_build_local_version gb10 . nowhere"
check "build_local_version: its output is read back by gpu_tuned_date_label" 0 "-" "^20261011\\.2$" \
  "${pre}; ${aw}; V=\"\$(CUDA_HOME='${al}/cuda-13.4' gpu_tuned_build_local_version gb10 .)\"; gpu_tuned_date_label \"0.1+\${V}\""
rm -rf "${al}"

# --- unique shared-object identities (rename + fail-closed gate + coexistence) ---
check "so_name: versioned name" 0 "-" "^libggml-tuned\\.so\\.0\\.23\\.0$" "${pre}; gpu_tuned_tuned_so_name libggml.so.0.23.0"
check "so_name: hyphenated stem, soname form" 0 "-" "^libggml-base-tuned\\.so\\.0$" "${pre}; gpu_tuned_tuned_so_name libggml-base.so.0"
check "so_name: unversioned impl library" 0 "-" "^libllama-server-impl-tuned\\.so$" "${pre}; gpu_tuned_tuned_so_name libllama-server-impl.so"
check "so_name: idempotent" 0 "-" "^libfoo-tuned\\.so\\.1$" "${pre}; gpu_tuned_tuned_so_name libfoo-tuned.so.1"
check "so_name: a non-library name is refused" 1 "not a lib\\*\\.so" "-" "${pre}; gpu_tuned_tuned_so_name notalib.txt"
check "so_name: the mark is one constant" 0 "-" "^libx_T\\.so$" "${pre}; GPU_TUNED_SO_MARK=_T; gpu_tuned_tuned_so_name libx.so"

if ! command -v gcc >/dev/null 2>&1 || ! command -v patchelf >/dev/null 2>&1; then
    skip "unique identities: rename, gate and coexistence" "needs gcc and patchelf; NOT verified on this machine"
else
co="$(mktemp -d)"; mkdir -p "${co}/ours" "${co}/up" "${co}/sys"
(
    set -e; cd "${co}"
    printf 'int demo_which(void){return 1;}\n' > up.c
    printf 'int demo_which(void){return 2;}\n' > ours.c
    printf 'int demo_which(void); int demo_extra(void){return demo_which()+10;}\n' > extra.c
    printf 'int sys_val(void){return 100;}\n' > sys.c
    printf 'int demo_which(void); int demo_extra(void); int sys_val(void);\nint main(void){int w=demo_which(); if (sys_val()!=100||demo_extra()!=w+10) return 99; return w;}\n' > app.c
    printf 'int demo_which(void);\nint main(void){return demo_which();}\n' > stock.c
    gcc -shared -fPIC -Wl,-soname,libdemo.so.0 up.c -o up/libdemo.so.0                 # upstream's: answers 1
    gcc stock.c -o up/app -L up -l:libdemo.so.0                                        # a stock app, no RUNPATH
    gcc -shared -fPIC -Wl,-soname,libsys.so.2 sys.c -o sys/libsys.so.2                 # a bundled system library
    gcc -shared -fPIC -Wl,-soname,libdemo.so.0 ours.c -o ours/libdemo.so.0.1           # ours, SAME soname as upstream's
    cp ours/libdemo.so.0.1 ours/libdemo.so.0                                           # package.sh stages a copy under the soname too
    gcc -shared -fPIC -Wl,-soname,libdemo-extra.so extra.c -o ours/libdemo-extra.so -L ours -l:libdemo.so.0
    cp sys/libsys.so.2 ours/
    gcc app.c -o ours/app -L ours -l:libdemo.so.0 -l:libdemo-extra.so -l:libsys.so.2 -Wl,--no-as-needed -Wl,-rpath,'$ORIGIN' -Wl,--enable-new-dtags
    printf 'libdemo.so.0.1\nlibdemo.so.0\nlibdemo-extra.so\n' > ours.manifest
    printf 'libsys.so.2\n' > sys.manifest
) >/dev/null 2>&1
ruN() { ( cd "$1"; LD_LIBRARY_PATH="${2:-}" ./app >/dev/null 2>&1; echo -n "$?" ); }
GATE="gpu_tuned_verify_unique_sonames '${co}/ours' '${co}/sys.manifest' '' '^libc\\.so'"

check "gate: an unrenamed stage fails closed and names the shared identities" 1 "VIOLATION: libdemo\\.so\\.0 is not tuned" "-" "${pre}; ${GATE}"
check "gate: ... including the library that links it" 1 "VIOLATION: libdemo-extra\\.so is not tuned" "-" "${pre}; ${GATE}"
check "A. today's defence, clean environment: our app uses our library" 0 "-" "^2$" "$(declare -f ruN); ruN '${co}/ours' ''"
check "B. LD_LIBRARY_PATH at upstream's dir: RUNPATH loses, our app binds upstream's" 0 "-" "^1$" "$(declare -f ruN); ruN '${co}/ours' '${co}/up'"

check "rename: renames our files and prints each" 0 "-" "libdemo\\.so\\.0\\.1 -> libdemo-tuned\\.so\\.0\\.1" "${pre}; gpu_tuned_rename_sonames '${co}/ours' '${co}/ours.manifest'"
check "rename: files are renamed, a bundled system library is not" 0 "-" "-" \
  "cd '${co}/ours'; [ -f libdemo-tuned.so.0.1 ] && [ -f libdemo-tuned.so.0 ] && [ -f libdemo-extra-tuned.so ] && [ -f libsys.so.2 ] && [ ! -e libdemo.so.0 ] && [ ! -e libdemo-extra.so ]"
check "rename: SONAMEs carry the mark" 0 "-" "^libdemo-tuned\\.so\\.0 libdemo-extra-tuned\\.so libsys\\.so\\.2$" \
  "cd '${co}/ours'; echo \"\$(patchelf --print-soname libdemo-tuned.so.0.1) \$(patchelf --print-soname libdemo-extra-tuned.so) \$(patchelf --print-soname libsys.so.2)\""
check "rename: the executable's DT_NEEDED is rewritten, the system library's is not" 0 "-" "libdemo-tuned\\.so\\.0" \
  "cd '${co}/ours'; patchelf --print-needed app | tr '\n' ' '; patchelf --print-needed app | grep -q '^libsys.so.2$'"
check "rename: a library's own DT_NEEDED on another renamed library is rewritten" 0 "-" "^libdemo-tuned\\.so\\.0$" \
  "cd '${co}/ours'; patchelf --print-needed libdemo-extra-tuned.so | grep -E 'libdemo' | head -1"
check "gate: the renamed stage passes" 0 "-" "-" "${pre}; ${GATE}"
check "rename: running it again changes nothing and the gate still passes" 0 "-" "-" \
  "${pre}; gpu_tuned_rename_sonames '${co}/ours' '${co}/ours.manifest' >/dev/null; ${GATE}"
check "C. renamed: our app uses our library even with LD_LIBRARY_PATH at upstream's dir" 0 "-" "^2$" "$(declare -f ruN); ruN '${co}/ours' '${co}/up'"
check "D1. renamed: a STOCK app is unaffected with our dir listed BEFORE upstream's" 0 "-" "^1$" "$(declare -f ruN); ruN '${co}/up' '${co}/ours:${co}/up'"
check "D2. ... and with upstream's first" 0 "-" "^1$" "$(declare -f ruN); ruN '${co}/up' '${co}/up:${co}/ours'"
check "E. one directory: the tuned and the stock library coexist under different names" 0 "-" "^1 2$" \
  "mkdir -p '${co}/shared'; cp '${co}/ours/'libdemo-tuned.so.0 '${co}/up/libdemo.so.0' '${co}/shared/'; cp '${co}/up/app' '${co}/shared/stock'; cp '${co}/ours/app' '${co}/shared/tunedapp'; cp '${co}/ours/'libdemo-extra-tuned.so '${co}/ours/libsys.so.2' '${co}/shared/'; cd '${co}/shared'; LD_LIBRARY_PATH=. ./stock; a=\$?; patchelf --remove-rpath tunedapp; LD_LIBRARY_PATH=. ./tunedapp; echo \"\$a \$?\""

# the gate must fail closed
cp -r "${co}/ours" "${co}/ours-bad"
printf '' > "${co}/ours-bad/libnew.so.0"; cp "${co}/ours/libsys.so.2" "${co}/ours-bad/libnew.so.0"
check "gate: a library upstream adds later (not in the manifest) is a violation, not a pass" 1 "VIOLATION: libnew\\.so\\.0 is not tuned" "-" \
  "${pre}; gpu_tuned_verify_unique_sonames '${co}/ours-bad' '${co}/sys.manifest' '' '^libc\\.so'"
rm -f "${co}/ours-bad/libdemo-tuned.so.0"
check "gate: a needed tuned library missing from the stage is a violation" 1 "needs libdemo-tuned\\.so\\.0, which is not in the stage" "-" \
  "${pre}; gpu_tuned_verify_unique_sonames '${co}/ours-bad' '${co}/sys.manifest' '' '^libc\\.so'"
check "gate: a needed library neither staged nor assumed present is a violation (closure)" 1 "neither in the stage nor assumed present" "-" \
  "${pre}; gpu_tuned_verify_unique_sonames '${co}/ours' '${co}/sys.manifest' '' '^nothing$'"
check "gate: a renamed file whose SONAME was not rewritten is a violation" 1 "its SONAME is" "-" \
  "cp -r '${co}/ours' '${co}/ours-soname'; patchelf --set-soname libdemo.so.0 '${co}/ours-soname/libdemo-tuned.so.0.1'; ${pre}; gpu_tuned_verify_unique_sonames '${co}/ours-soname' '${co}/sys.manifest' '' '^libc\\.so'"
check "rename: a manifest entry that is not in the stage is an error" 1 "not in" "-" \
  "printf 'libghost.so.1\n' > '${co}/ghost.manifest'; ${pre}; gpu_tuned_rename_sonames '${co}/ours' '${co}/ghost.manifest'"
# keep-regex (a build that loads backends by filename)
mkdir -p "${co}/k"; cp "${co}/sys/libsys.so.2" "${co}/k/"; rm -rf "${co}/k2"; cp -r "${co}/up" "${co}/k2" >/dev/null 2>&1
check "rename: --keep leaves matching names alone (and the gate accepts them as kept)" 0 "-" "-" \
  "cd '${co}'; rm -rf kk; mkdir kk; cp up/libdemo.so.0 kk/libplug.so.0; printf 'libplug.so.0\n' > kk.manifest; ${pre}; gpu_tuned_rename_sonames kk kk.manifest '^libplug'; [ -f kk/libplug.so.0 ] && gpu_tuned_verify_unique_sonames kk - '^libplug' '^libc\\.so'"
# gpu_tuned_rename_package: rename + CMake/pkg-config repoint + gates in one call
(
    set -e; cd "${co}"; rm -rf pk; mkdir -p pk/lib/cmake/demo pk/lib/pkgconfig
    gcc -shared -fPIC -Wl,-soname,libdemo.so.0 ours.c -o pk/lib/libdemo.so.0
    gcc -shared -fPIC -Wl,-soname,libdemo-extra.so extra.c -o pk/lib/libdemo-extra.so -L pk/lib -l:libdemo.so.0
    gcc -shared -fPIC -Wl,-soname,libkeep.so keep.c -o pk/lib/libkeep.so 2>/dev/null || { printf 'int keep_v(void){return 3;}\n' > keep.c; gcc -shared -fPIC -Wl,-soname,libkeep.so keep.c -o pk/lib/libkeep.so; }
    printf 'set(P "${_IMPORT_PREFIX}/lib/libdemo.so.0")\nset(Q "libdemo-extra.so")\nset(K "libkeep.so")\n' > pk/lib/cmake/demo/t.cmake
    printf 'Libs: -ldemo-extra -l:libdemo.so.0\n' > pk/lib/pkgconfig/demo.pc
    printf 'libdemo.so.0\nlibdemo-extra.so\nlibkeep.so\n' > pk.manifest
) >/dev/null 2>&1
PKG="gpu_tuned_rename_package '${co}/pk/lib' '${co}/pk.manifest' - '^libkeep\\.so\$' '^libc\\.so' '${co}/pk/lib/cmake' '${co}/pk/lib/pkgconfig' '${co}/pk/lib/nowhere'"
check "rename_package: renames, repoints, prints, passes the gate" 0 "-" "libdemo\\.so\\.0 -> libdemo-tuned\\.so\\.0" "${pre}; ${PKG}"
check "rename_package: the CMake file names the tuned libraries" 0 "-" 'lib/libdemo-tuned\.so\.0"\).*libdemo-extra-tuned\.so' \
  "tr '\n' ' ' < '${co}/pk/lib/cmake/demo/t.cmake'"
check "rename_package: a kept library's reference is untouched" 0 "-" 'set\(K "libkeep\.so"\)' "cat '${co}/pk/lib/cmake/demo/t.cmake'"
check "rename_package: pkg-config's -l:<file> form is repointed, a bare -l<name> is not a file name and is left alone" 0 "-" "Libs: -ldemo-extra -l:libdemo-tuned\\.so\\.0" "cat '${co}/pk/lib/pkgconfig/demo.pc'"
check "rename_package: running it again changes nothing and still passes" 0 "-" "-" "${pre}; ${PKG}"
check "rename_package: a stock name in a file added later is repointed on the next run" 0 "-" "x libdemo-tuned\\.so\\.0" \
  "${pre}; printf 'x libdemo.so.0\n' > '${co}/pk/lib/cmake/demo/late.txt'; ${PKG} >/dev/null; cat '${co}/pk/lib/cmake/demo/late.txt'"
rm -rf "${co}"
fi

# --- gpu_tuned_cmake_ignore_pip_prefixes ---
ip="$(mktemp -d)"
mkdir -p "${ip}/home/.local/lib/python3.14/site-packages/pkgA/lib64/cmake/a" "${ip}/home/.local/lib/python3.14/site-packages/pkgB/include" "${ip}/home/.local/lib/python3.14/site-packages/pkgC/share/cmake/c" "${ip}/empty"
check "ignore_pip_prefixes: lists site-packages and packages that ship CMake config" 0 "-" "^${ip}/home/.local/lib/python3.14/site-packages;${ip}/home/.local/lib/python3.14/site-packages/pkgA;${ip}/home/.local/lib/python3.14/site-packages/pkgC$" "HOME='${ip}/home' VIRTUAL_ENV='' bash -c \"source '${LIB}'; gpu_tuned_cmake_ignore_pip_prefixes\"; echo"
check "ignore_pip_prefixes: a package without CMake config is not listed" 0 "-" "^0$" "HOME='${ip}/home' VIRTUAL_ENV='' bash -c \"source '${LIB}'; gpu_tuned_cmake_ignore_pip_prefixes\" | grep -c pkgB || true"
mkdir -p "${ip}/venv/lib/python3.14/site-packages/pkgV/lib/cmake/v" "${ip}/venv/lib/python3.14/site-packages/pkgW/include"
check "ignore_pip_prefixes: an active VIRTUAL_ENV's site-packages and CMake-shipping packages are listed too" 0 "-" "^${ip}/venv/lib/python3.14/site-packages;${ip}/venv/lib/python3.14/site-packages/pkgV$" "HOME='${ip}/empty' VIRTUAL_ENV='${ip}/venv' bash -c \"source '${LIB}'; gpu_tuned_cmake_ignore_pip_prefixes\" | tr ';' '\\n' | paste -sd';'"
check "ignore_pip_prefixes: no user site-packages prints nothing" 0 "-" "^\\[\\]$" "echo \"[\$(HOME='${ip}/empty' VIRTUAL_ENV='' bash -c \"source '${LIB}'; gpu_tuned_cmake_ignore_pip_prefixes\")]\""
mkdir -p "${ip}/home/.local/lib/python3.14/site-packages/librmm_cu13-1.0.dist-info"
printf 'pkgA/lib64/cmake/a/a.cmake,,\n' > "${ip}/home/.local/lib/python3.14/site-packages/librmm_cu13-1.0.dist-info/RECORD"
check "warn_pip_cmake_packages: names the wheel and the uninstall command" 0 "pip uninstall -y librmm_cu13$" "-" "HOME='${ip}/home' VIRTUAL_ENV='' bash -c \"source '${LIB}'; gpu_tuned_warn_pip_cmake_packages\""
mkdir -p "${ip}/home/.local/lib/python3.14/site-packages/torch-2.0.dist-info"
printf 'pkgC/share/cmake/c/c.cmake,,\n' > "${ip}/home/.local/lib/python3.14/site-packages/torch-2.0.dist-info/RECORD"
check "warn_pip_cmake_packages: an unrelated wheel is never suggested for removal" 0 "-" "^0$" "HOME='${ip}/home' VIRTUAL_ENV='' bash -c \"source '${LIB}'; gpu_tuned_warn_pip_cmake_packages\" 2>&1 | grep -c torch || true"
printf 'nvtx3_DIR:PATH=%s/home/.local/lib/python3.14/site-packages/pkgA/lib64/cmake/nvtx3\nrmm_DIR:PATH=/opt/ok/rmm\nPython_EXECUTABLE:FILEPATH=%s/home/.local/lib/python3.14/site-packages/x/python\n' "${ip}" "${ip}" > "${ip}/bad.cache"
printf 'nvtx3_DIR:PATH=nvtx3_DIR-NOTFOUND\nrmm_DIR:PATH=/opt/ok/rmm\nCMAKE_ROOT:INTERNAL=%s/home/.local/lib/python3.14/site-packages/cmake/data/share/cmake-4.3\n' "${ip}" > "${ip}/good.cache"
check "verify_no_pip_cmake_deps: a _DIR into a pip wheel fails and names it" 1 "nvtx3_DIR from a pip wheel|resolved nvtx3_DIR" "-" "HOME='${ip}/home' bash -c \"source '${LIB}'; gpu_tuned_verify_no_pip_cmake_deps '${ip}/bad.cache'\""
check "verify_no_pip_cmake_deps: an nvtx3 from a wheel says it is not the tuned copy" 1 "NOT the tuned copy" "-" "HOME='${ip}/home' bash -c \"source '${LIB}'; gpu_tuned_verify_no_pip_cmake_deps '${ip}/bad.cache'\""
check "warn_pip_cmake_packages: a librmm wheel gets the nvtx3 not-tuned note" 0 "NOT the tuned copy" "-" "HOME='${ip}/home' VIRTUAL_ENV='' bash -c \"source '${LIB}'; gpu_tuned_warn_pip_cmake_packages\""
check "verify_no_pip_cmake_deps: only the pip entry is reported" 0 "-" "^1$" "HOME='${ip}/home' bash -c \"source '${LIB}'; gpu_tuned_verify_no_pip_cmake_deps '${ip}/bad.cache'\" 2>&1 | grep -c 'resolved'"
check "verify_no_pip_cmake_deps: a clean cache passes" 0 "-" "-" "HOME='${ip}/home' bash -c \"source '${LIB}'; gpu_tuned_verify_no_pip_cmake_deps '${ip}/good.cache'\""
check "verify_no_pip_cmake_deps: a missing cache file fails" 1 "no such cache file" "-" "bash -c \"source '${LIB}'; gpu_tuned_verify_no_pip_cmake_deps '${ip}/none'\""
check "warn_pip_cmake_packages: nothing installed prints nothing" 0 "-" "^\\[\\]$" "echo \"[\$(HOME='${ip}/empty' VIRTUAL_ENV='' bash -c \"source '${LIB}'; gpu_tuned_warn_pip_cmake_packages\" 2>&1)]\""
rm -rf "${ip}"

# --- gpu_tuned_verify_consumer_configure ---
if ! command -v cmake >/dev/null 2>&1 || ! command -v c++ >/dev/null 2>&1; then
    skip "verify_consumer_configure" "needs cmake and a C++ compiler; NOT verified on this machine"
else
cc="$(mktemp -d)"
mkdir -p "${cc}/bad/lib/cmake/foo" "${cc}/good/lib/cmake/foo" "${cc}/good/lib/cmake/nvtx3"
printf 'include(CMakeFindDependencyMacro)\nfind_dependency(nvtx3)\n' | tee "${cc}/bad/lib/cmake/foo/foo-config.cmake" > "${cc}/good/lib/cmake/foo/foo-config.cmake"
printf 'set(nvtx3_FOUND TRUE)\n' > "${cc}/good/lib/cmake/nvtx3/nvtx3-config.cmake"
check "verify_consumer_configure: a package that needs nvtx3 and lacks it fails" 1 "cannot configure" "-" "bash -c \"source '${LIB}'; gpu_tuned_verify_consumer_configure '${cc}/bad' foo\""
check "verify_consumer_configure: a package that ships nvtx3 passes" 0 "-" "-" "bash -c \"source '${LIB}'; gpu_tuned_verify_consumer_configure '${cc}/good' foo\""
check "verify_consumer_configure: no package name is an error" 1 "need <package-dir>" "-" "bash -c \"source '${LIB}'; gpu_tuned_verify_consumer_configure '${cc}/good'\""
rm -rf "${cc}"
fi

# --- build-time -tuned names via a CMake include (gpu_tuned_so_names_cmake) ---
if ! command -v cmake >/dev/null 2>&1 || ! command -v gcc >/dev/null 2>&1 || ! command -v patchelf >/dev/null 2>&1; then
    skip "so_names_cmake: build-time names" "needs cmake, gcc and patchelf; NOT verified on this machine"
else
sn="$(mktemp -d)"; mkdir -p "${sn}/src/dep" "${sn}/src/dep2"
(
    set -e; cd "${sn}"
    printf 'int dep_v(void){return 5;}\n' > src/dep/dep.c
    printf 'int dep_v(void);\nint dep2_v(void){return dep_v()+1;}\n' > src/dep2/dep2.c
    printf 'int dep_v(void);\nint main(void){return dep_v()==5?0:1;}\n' > src/main.c
    printf 'project(dep C)\nadd_library(dep SHARED dep.c)\nset_target_properties(dep PROPERTIES VERSION 1.2 SOVERSION 1)\n' > src/dep/CMakeLists.txt
    printf 'project(dep2 C)\nadd_library(dep2 SHARED dep2.c)\nset_target_properties(dep2 PROPERTIES OUTPUT_NAME dep2-gb10)\ntarget_link_libraries(dep2 PUBLIC dep)\nadd_library(dep3 STATIC dep2.c)\n' > src/dep2/CMakeLists.txt
    printf 'cmake_minimum_required(VERSION 3.24)\nproject(top C)\nadd_subdirectory(dep)\nadd_subdirectory(dep2)\nadd_executable(app main.c)\ntarget_link_libraries(app dep)\n' > src/CMakeLists.txt
    bash -c "source '${LIB}'; gpu_tuned_so_names_cmake '${sn}/names.cmake'"
    cmake -S src -B b -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES="${sn}/names.cmake" "-DTUNED_SO_TARGETS=dep;dep2;dep3;absent"
    cmake --build b
) >"${sn}/log" 2>&1 || { cat "${sn}/log"; }
check "so_names_cmake: a versioned library gets the mark in file name and SONAME" 0 "-" "^libdep-tuned\\.so\\.1$" "ls '${sn}/b/dep' | grep -E '^libdep-tuned\\.so\\.1\$'; patchelf --print-soname '${sn}/b/dep/libdep-tuned.so.1'"
check "so_names_cmake: a library with an OUTPUT_NAME keeps it and adds the mark" 0 "-" "^libdep2-gb10-tuned\\.so$" "patchelf --print-soname '${sn}/b/dep2/libdep2-gb10-tuned.so'"
check "so_names_cmake: a dependent's DT_NEEDED names the tuned library" 0 "-" "^libdep-tuned\\.so\\.1$" "patchelf --print-needed '${sn}/b/dep2/libdep2-gb10-tuned.so' | grep dep"
check "so_names_cmake: the executable links the tuned library and runs" 0 "-" "^0$" "cd '${sn}/b'; patchelf --print-needed app | grep -q libdep-tuned && LD_LIBRARY_PATH='${sn}/b/dep' ./app; echo \$?"
check "so_names_cmake: a static archive and an absent target are left alone" 0 "-" "^libdep3\\.a$" "ls '${sn}/b/dep2' | grep -E '^libdep3'"
check "so_names_cmake: no output file is an error" 1 "need an output file" "-" "${pre}; gpu_tuned_so_names_cmake"
rm -rf "${sn}"
fi

# --- axis names (decisions/2026-10-17): mark argument, device-code classification, rename, gates ---
check "so_name mark: no device code -> -<toolkit>" 0 "-" "^librmm-cu133\.so$" "${pre}; gpu_tuned_tuned_so_name librmm.so -cu133"
check "so_name mark: device code -> -<variant>-<toolkit>, a versioned name keeps its suffix" 0 "-" "^libraft-gb10-cu133\.so\.1$" "${pre}; gpu_tuned_tuned_so_name libraft.so.1 -gb10-cu133"
check "so_name mark: a name that already ends in the mark is unchanged" 0 "-" "^libraft-gb10-cu133\.so$" "${pre}; gpu_tuned_tuned_so_name libraft-gb10-cu133.so -gb10-cu133"
check "so_name mark: the legacy -tuned mark is replaced, never stacked" 0 "-" "^librmm-cu133\.so$" "${pre}; gpu_tuned_tuned_so_name librmm-tuned.so -cu133"
check "so_name mark: without a mark argument the generic mark still applies" 0 "-" "^libx-tuned\.so$" "${pre}; gpu_tuned_tuned_so_name libx.so"
if ! command -v gcc >/dev/null 2>&1 || ! command -v nvcc >/dev/null 2>&1 || ! command -v cuobjdump >/dev/null 2>&1 || ! command -v patchelf >/dev/null 2>&1; then
    skip "axis names: classification, rename and gates" "needs gcc, nvcc, cuobjdump and patchelf; NOT verified on this machine"
else
ax="$(mktemp -d)"; mkdir -p "${ax}/s" "${ax}/sys"
(
    set -e; cd "${ax}"
    printf 'int host_f(void){return 1;}\n' > host.c
    gcc -shared -fPIC -Wl,-soname,libhost.so host.c -o s/libhost.so
    printf 'extern "C" int host_f(void);\n__global__ void k(int*p){*p=1;}\nextern "C" int dev_f(void){return host_f()+1;}\n' > dev.cu
    nvcc -shared -Xcompiler -fPIC -gencode arch=compute_80,code=compute_80 -Xlinker -soname,libdev.so -Xlinker -rpath,'$ORIGIN' dev.cu -o s/libdev.so -L s -l:libhost.so
    printf 'int sys_f(void){return 3;}\n' > sys.c
    gcc -shared -fPIC -Wl,-soname,libsysx.so.1 sys.c -o sys/libsysx.so.1
    # a host-only wrapper bound to the device library: no device code of its own, but it NEEDs libdev
    mkdir -p w; cp s/libdev.so s/libhost.so w/
    printf 'extern int dev_f(void);\nint wrap_f(void){return dev_f();}\n' > wrap.c
    gcc -shared -fPIC -Wl,-soname,libwrap.so wrap.c -o w/libwrap.so -L w -l:libdev.so -Wl,-rpath,'$ORIGIN' -Wl,--no-as-needed
) >"${ax}/log" 2>&1 || cat "${ax}/log"
check "has_device_code: a library with a kernel is yes" 0 "-" "-" "${pre}; gpu_tuned_so_has_device_code '${ax}/s/libdev.so'"
check "has_device_code: a host-only library is no" 1 "-" "-" "${pre}; set +e; gpu_tuned_so_has_device_code '${ax}/s/libhost.so'; exit \$?"
check "has_device_code: a missing file cannot be classified" 2 "no such file" "-" "${pre}; gpu_tuned_so_has_device_code '${ax}/nothing.so'"
check "has_device_code: a non-ELF file cannot be classified" 2 "could not classify" "-" "echo hi > '${ax}/t.txt'; ${pre}; gpu_tuned_so_has_device_code '${ax}/t.txt'"
check "has_device_code: no cuobjdump is a failure, not a no" 2 "cuobjdump not found" "-" "${pre}; CUDA_HOME=/nonexistent PATH=/usr/bin:/bin gpu_tuned_so_has_device_code '${ax}/s/libhost.so'"
check "mark_for: device code -> -<variant>-<toolkit>" 0 "-" "^-gb10-cu133$" "${pre}; gpu_tuned_so_mark_for '${ax}/s/libdev.so' gb10 cu133"
check "mark_for: no device code -> -<toolkit>" 0 "-" "^-cu133$" "${pre}; gpu_tuned_so_mark_for '${ax}/s/libhost.so' gb10 cu133"
check "mark_for: a bad toolkit is refused" 1 "need <elf> <variant> <cuNNN>" "-" "${pre}; gpu_tuned_so_mark_for '${ax}/s/libhost.so' gb10 13.3"

AXM="${ax}/axes.manifest"
check "axes_manifest: writes '<name> <mark>' by contents" 0 "-" "^libdev\.so -gb10-cu133$" "${pre}; gpu_tuned_axes_manifest '${ax}/s' gb10 cu133 '${AXM}' libdev.so libhost.so && cat '${AXM}'"
check "axes_manifest: the other line is the toolkit-only one" 0 "-" "^libhost\.so -cu133$" "cat '${AXM}'"
check "axes_manifest: a name in neither form is refused" 1 "is not in" "-" "${pre}; gpu_tuned_axes_manifest '${ax}/s' gb10 cu133 '${ax}/x.manifest' libghost.so"
check "axes_manifest: an unrenamed stage fails the axes gate and names both libraries" 1 "VIOLATION: libhost\.so must end in '-cu133'" "-" "${pre}; gpu_tuned_verify_so_axes '${ax}/s' gb10 cu133 -"
check "axes gate: ... and the device-code one" 1 "VIOLATION: libdev\.so must end in '-gb10-cu133'" "-" "${pre}; gpu_tuned_verify_so_axes '${ax}/s' gb10 cu133 -"
check "rename by axes: each library gets the mark its contents need" 0 "-" "libdev\.so -> libdev-gb10-cu133\.so" "${pre}; gpu_tuned_rename_sonames '${ax}/s' '${AXM}'"
check "rename by axes: the host-only one gets the toolkit mark" 0 "-" "^libhost-cu133\.so$" "ls '${ax}/s' | grep host"
check "rename by axes: SONAMEs carry the same marks" 0 "-" "^libdev-gb10-cu133\.so libhost-cu133\.so$" "echo \$(patchelf --print-soname '${ax}/s/libdev-gb10-cu133.so') \$(patchelf --print-soname '${ax}/s/libhost-cu133.so')"
check "rename by axes: the device library's DT_NEEDED follows the rename" 0 "-" "^libhost-cu133\.so$" "patchelf --print-needed '${ax}/s/libdev-gb10-cu133.so' | grep libhost"
check "axes gate: the renamed stage passes" 0 "-" "-" "${pre}; gpu_tuned_verify_so_axes '${ax}/s' gb10 cu133 -"
check "rename by axes: running it again changes nothing" 0 "-" "-" "${pre}; gpu_tuned_rename_sonames '${ax}/s' '${AXM}' && gpu_tuned_verify_so_axes '${ax}/s' gb10 cu133 -"
check "axes_manifest: a renamed stage gives the same manifest" 0 "-" "^libdev\.so -gb10-cu133$" "${pre}; gpu_tuned_axes_manifest '${ax}/s' gb10 cu133 '${ax}/again.manifest' libdev.so libhost.so && cat '${ax}/again.manifest'"
check "unique_sonames with the axis mark: the renamed stage passes" 0 "-" "-" "${pre}; gpu_tuned_verify_unique_sonames '${ax}/s' - '' '^(libc\.so|libm\.so|libstdc\+\+|libgcc_s|libdl|libpthread|librt|ld-linux)' '-(gb10-)?cu133'"
check "unique_sonames with the generic default: the axis names are not tuned" 1 "is not tuned" "-" "${pre}; gpu_tuned_verify_unique_sonames '${ax}/s' - '' '^(libc\.so|libm\.so|libstdc\+\+|libgcc_s|libdl|libpthread|librt|ld-linux)'"
check "axes gate: a device library named toolkit-only fails" 1 "VIOLATION: libdev-cu133\.so must end in '-gb10-cu133'" "-" \
  "rm -rf '${ax}/n1'; cp -r '${ax}/s' '${ax}/n1'; mv '${ax}/n1/libdev-gb10-cu133.so' '${ax}/n1/libdev-cu133.so'; ${pre}; gpu_tuned_verify_so_axes '${ax}/n1' gb10 cu133 -"
check "axes gate: a host-only library carrying the variant fails" 1 "no device code, so it must not carry the variant" "-" \
  "rm -rf '${ax}/n2'; cp -r '${ax}/s' '${ax}/n2'; mv '${ax}/n2/libhost-cu133.so' '${ax}/n2/libhost-gb10-cu133.so'; ${pre}; gpu_tuned_verify_so_axes '${ax}/n2' gb10 cu133 -"
check "axes gate: a SONAME with the wrong mark fails" 1 "has SONAME 'libhost\.so'" "-" \
  "rm -rf '${ax}/n3'; cp -r '${ax}/s' '${ax}/n3'; patchelf --set-soname libhost.so '${ax}/n3/libhost-cu133.so'; ${pre}; gpu_tuned_verify_so_axes '${ax}/n3' gb10 cu133 -"
check "axes gate: a recorded system library is exempt" 0 "-" "-" \
  "rm -rf '${ax}/n4'; cp -r '${ax}/s' '${ax}/n4'; cp '${ax}/sys/libsysx.so.1' '${ax}/n4/'; printf 'libsysx.so.1\n' > '${ax}/n4.sys'; ${pre}; gpu_tuned_verify_so_axes '${ax}/n4' gb10 cu133 '${ax}/n4.sys'"
check "axes gate: an unrecorded extra library fails" 1 "VIOLATION: libsysx\.so\.1 must end in" "-" \
  "rm -rf '${ax}/n5'; cp -r '${ax}/s' '${ax}/n5'; cp '${ax}/sys/libsysx.so.1' '${ax}/n5/'; ${pre}; gpu_tuned_verify_so_axes '${ax}/n5' gb10 cu133 -"
check "axes gate: a library that cannot be classified is a failure" 1 "cannot be classified" "-" \
  "${pre}; CUDA_HOME=/nonexistent PATH=/usr/bin:/bin gpu_tuned_verify_so_axes '${ax}/s' gb10 cu133 -"
check "transitive: the wrapper has no device code" 1 "-" "-" "${pre}; set +e; gpu_tuned_so_has_device_code '${ax}/w/libwrap.so'; exit \$?"
check "transitive manifest: a wrapper of a device library takes the variant, a host library does not" 0 "-" "^libwrap\.so -gb10-cu133$" \
  "${pre}; gpu_tuned_axes_manifest '${ax}/w' gb10 cu133 '${ax}/w.manifest' libwrap.so libdev.so libhost.so && grep '^libwrap' '${ax}/w.manifest'"
check "transitive manifest: ... and the host-only dependency stays toolkit-only" 0 "-" "^libhost\.so -cu133$" "grep '^libhost' '${ax}/w.manifest'"
check "transitive manifest: the order of the names does not matter" 0 "-" "^libwrap\.so -gb10-cu133$" \
  "${pre}; gpu_tuned_axes_manifest '${ax}/w' gb10 cu133 '${ax}/w2.manifest' libhost.so libwrap.so libdev.so && grep '^libwrap' '${ax}/w2.manifest'"
check "transitive: rename by that manifest passes the axes gate" 0 "-" "^libwrap-gb10-cu133\.so$" \
  "${pre}; gpu_tuned_rename_sonames '${ax}/w' '${ax}/w.manifest' >/dev/null && gpu_tuned_verify_so_axes '${ax}/w' gb10 cu133 - && ls '${ax}/w' | grep wrap"
check "transitive: mark_for judges a renamed wrapper by its final NEEDED names" 0 "-" "^-gb10-cu133$" "${pre}; gpu_tuned_so_mark_for '${ax}/w/libwrap-gb10-cu133.so' gb10 cu133"
check "transitive gate: a wrapper named toolkit-only fails" 1 "VIOLATION: libwrap-cu133\.so must end in '-gb10-cu133'" "-" \
  "rm -rf '${ax}/n6'; cp -r '${ax}/w' '${ax}/n6'; mv '${ax}/n6/libwrap-gb10-cu133.so' '${ax}/n6/libwrap-cu133.so'; ${pre}; gpu_tuned_verify_so_axes '${ax}/n6' gb10 cu133 -"
check "rename_package by axes: renames, repoints a CMake file, passes both gates" 0 "-" "libhost-cu133\.so" \
  "rm -rf '${ax}/pk'; mkdir -p '${ax}/pk/lib/cmake'; cp '${ax}/s/libhost-cu133.so' '${ax}/pk/lib/libhost.so'; patchelf --set-soname libhost.so '${ax}/pk/lib/libhost.so'; printf 'set(L \"lib/libhost.so\")\n' > '${ax}/pk/lib/cmake/t.cmake'; ${pre}; printf 'libhost.so -cu133\n' > '${ax}/pk.manifest'; gpu_tuned_rename_package '${ax}/pk/lib' '${ax}/pk.manifest' - '' '^(libc\.so|libm\.so|libstdc\+\+|libgcc_s)' '${ax}/pk/lib/cmake' >/dev/null 2>&1; cat '${ax}/pk/lib/cmake/t.cmake'"
rm -rf "${ax}"
fi
if ! command -v cmake >/dev/null 2>&1 || ! command -v gcc >/dev/null 2>&1; then
    skip "so_names_cmake: axis marks" "needs cmake and gcc; NOT verified on this machine"
else
sa="$(mktemp -d)"; mkdir -p "${sa}/src"
(
    set -e; cd "${sa}"
    printf 'int h(void){return 1;}\n' > src/h.c
    printf 'int d(void){return 2;}\n' > src/d.c
    printf 'cmake_minimum_required(VERSION 3.24)\nproject(top C)\nadd_library(hostl SHARED h.c)\nadd_library(devl SHARED d.c)\nadd_library(plain SHARED h.c)\n' > src/CMakeLists.txt
    bash -c "source '${LIB}'; gpu_tuned_so_names_cmake '${sa}/names.cmake'"
    cmake -S src -B b -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES="${sa}/names.cmake" "-DTUNED_SO_TARGETS=hostl" "-DTUNED_SO_MARK=-cu133" "-DTUNED_SO_DEVICE_TARGETS=devl" "-DTUNED_SO_DEVICE_MARK=-gb10-cu133"
    cmake --build b
) >"${sa}/log" 2>&1 || cat "${sa}/log"
check "so_names_cmake axes: TUNED_SO_TARGETS take TUNED_SO_MARK" 0 "-" "^libhostl-cu133\.so$" "ls '${sa}/b' | grep hostl"
check "so_names_cmake axes: TUNED_SO_DEVICE_TARGETS take TUNED_SO_DEVICE_MARK" 0 "-" "^libdevl-gb10-cu133\.so$" "ls '${sa}/b' | grep devl"
check "so_names_cmake axes: an unlisted target is left alone" 0 "-" "^libplain\.so$" "ls '${sa}/b' | grep plain"
rm -rf "${sa}"
fi

# --- shared helpers: sha256 sidecar, toolkit selection, JSON stamp of a library (A7) ---
sc="$(mktemp -d)"; echo payload > "${sc}/pkg.tar.gz"
check "sidecar: written in sha256sum format with the base name" 0 "-" "^Checksum: pkg\.tar\.gz\.sha256$" "${pre}; gpu_tuned_write_sha256_sidecar '${sc}/pkg.tar.gz'"
check "sidecar: the file is '<digest>  <name>'" 0 "-" "^[0-9a-f]{64}  pkg\.tar\.gz$" "cat '${sc}/pkg.tar.gz.sha256'"
check "sidecar: verify passes on a match" 0 "-" "-" "${pre}; gpu_tuned_verify_sha256_sidecar '${sc}/pkg.tar.gz'"
check "sidecar: verify detects a changed tarball" 1 "does not match pkg\.tar\.gz" "-" "cp -r '${sc}' '${sc}2'; echo tamper >> '${sc}2/pkg.tar.gz'; ${pre}; gpu_tuned_verify_sha256_sidecar '${sc}2/pkg.tar.gz'"
check "sidecar: verify names a missing sidecar" 1 "pkg\.tar\.gz\.sha256 not found" "-" "rm -f '${sc}2/pkg.tar.gz.sha256'; ${pre}; gpu_tuned_verify_sha256_sidecar '${sc}2/pkg.tar.gz'"
check "sidecar: write refuses a missing file" 1 "no such file" "-" "${pre}; gpu_tuned_write_sha256_sidecar '${sc}/nothing'"
rm -rf "${sc}" "${sc}2"
if [ ! -d /usr/local/cuda-13.3 ]; then
    skip "select_toolkit: loads and verifies a named toolkit" "needs /usr/local/cuda-13.3; NOT verified on this machine"
else
tkenv="${pre}; export GPU_TUNED_PLATFORM=\$(uname -m); D='${LIB%/*}'"
check "select_toolkit: CUDA_TAG names it" 0 "-" "^cu133 13.3 /usr/local/cuda-13.3$" "${tkenv}; CUDA_TAG=cu133 gpu_tuned_select_toolkit \"\$D\" gb10 >/dev/null; echo \"\$CUDA_TAG \$CUDA_VER \$CUDA_HOME\""
check "select_toolkit: CUDA_VER names it" 0 "-" "^cu133$" "${tkenv}; CUDA_VER=13.3 gpu_tuned_select_toolkit \"\$D\" gb10 >/dev/null; echo \"\$CUDA_TAG\""
check "select_toolkit: a repo prefix is consulted first" 0 "-" "^cu133$" "${tkenv}; GPU_TUNED_TOOLKIT_ENV_PREFIX=FAISS_ FAISS_CUDA_TAG=cu133 gpu_tuned_select_toolkit \"\$D\" gb10 >/dev/null; echo \"\$CUDA_TAG\""
check "select_toolkit: a tag and a version that disagree are refused" 1 "conflicts with toolkit cu133" "-" "${tkenv}; CUDA_TAG=cu133 CUDA_VER=13.4 gpu_tuned_select_toolkit \"\$D\" gb10"
check "select_toolkit: none named is an error that lists the toolkits (no default)" 1 "no toolkit specified" "-" "${tkenv}; env -u CUDA_TAG -u CUDA_VER bash -c \"source '${LIB}'; gpu_tuned_select_toolkit \\\"\$D\\\" gb10\" </dev/null"
fi
if ! command -v gcc >/dev/null 2>&1 || ! command -v objcopy >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    skip "stamp_lib_json: stamp, drop the legacy section, verify" "needs gcc, objcopy and python3; NOT verified on this machine"
else
sl="$(mktemp -d)"
(
    set -e; cd "${sl}"
    printf 'int f(void){return 1;}\n' > f.c
    gcc -shared -fPIC f.c -o libf.so
    printf 'legacy text\n' > legacy.txt
    objcopy --add-section .oldinfo_build_info=legacy.txt libf.so
) >/dev/null 2>&1
senv="${pre}; export GPU_TUNED_VARIANT=gb10 GPU_TUNED_HW_LABEL=hw GPU_TUNED_CUDA_ARCH=121a CUDA_TAG=cu133 CUDA_VER=13.3 CUDA_HOME=/usr/local/cuda-13.3"
wj="$(mktemp -d)"
check "write_build_info_json: writes one line of JSON, release first, with the git fields and built" 0 "-" '^1 release=v0\.1-gb10-cu133 fork=1 built=1$' \
  "${pre}; cd '${wj}'; git init -q -b main .; git -c user.name=t -c user.email=t@t commit -q --allow-empty -m x; gpu_tuned_write_build_info_json '${wj}/BUILD_INFO.json' release=v0.1-gb10-cu133 package=demo; python3 -c 'import json; d=json.load(open(\"${wj}/BUILD_INFO.json\")); print(len(open(\"${wj}/BUILD_INFO.json\").read().strip().splitlines()), \"release=\"+d[\"release\"], \"fork=\"+str(int(\"commit\" in d[\"fork\"])), \"built=\"+str(int(\"built\" in d)))'"
check "write_build_info_json: a caller-given field wins over the automatic one" 0 "-" '^https://example/x$' \
  "${pre}; cd '${wj}'; gpu_tuned_write_build_info_json '${wj}/b2.json' package=demo release=v0.1-x-cu1 fork.url=https://example/x; python3 -c 'import json; print(json.load(open(\"${wj}/b2.json\"))[\"fork\"][\"url\"])'"
check "verify_build_info_json_file: matching fields pass" 0 "-" "-" \
  "${pre}; printf '{\"release\":\"v0.1-x-cu1\",\"cuda\":{\"tag\":\"cu1\"}}\n' > '${wj}/vf.json'; gpu_tuned_verify_build_info_json_file '${wj}/vf.json' release=v0.1-x-cu1 cuda.tag=cu1"
check "verify_build_info_json_file: a wrong field is named" 1 "field cuda.tag is 'cu1', expected 'cu2'" "-" \
  "${pre}; gpu_tuned_verify_build_info_json_file '${wj}/vf.json' release=v0.1-x-cu1 cuda.tag=cu2"
check "verify_build_info_json_file: a missing file is refused" 1 "missing or empty" "-" "${pre}; gpu_tuned_verify_build_info_json_file '${wj}/none.json'"
check "write_build_info_json: no output file is an error" 1 "need an output file" "-" "${pre}; gpu_tuned_write_build_info_json"
rm -rf "${wj}"
check "stamp_lib_json: stamps and reads back the release first" 0 "-" '^"release": "v0\.20261017\.0-gb10-cu133"$' \
  "${senv}; gpu_tuned_stamp_lib_json '${sl}/libf.so' demo v0.20261017.0-gb10-cu133 .oldinfo_build_info deps.x=1 && gpu_tuned_read_build_info '${sl}/libf.so' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(\"\\\"release\\\": \\\"\"+d[\"release\"]+\"\\\"\")'"
check "stamp_lib_json: the legacy section is gone" 0 "-" "^0$" "readelf -S '${sl}/libf.so' | grep -c oldinfo_build_info || true"
check "stamp_lib_json: the new section is there" 0 "-" "^1$" "readelf -S '${sl}/libf.so' | grep -c tuned_build_info || true"
check "stamp_lib_json: extra fields are kept" 0 "-" "^1$" "${senv}; gpu_tuned_read_build_info '${sl}/libf.so' | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"deps\"][\"x\"])'"
check "stamp_lib_json: a missing file is refused" 1 "need <elf> <package> <release-tag>" "-" "${senv}; gpu_tuned_stamp_lib_json '${sl}/none.so' demo v0.20261017.0-gb10-cu133"
rm -rf "${sl}"
fi

# --- CUDA-version-specific output dirs ---
check "out_dir build: one fixed cmake dir per toolkit under tuned/build/<cuda>" 0 "-" "^/r/tuned/build/cu133/cmake$" \
  "${pre}; gpu_tuned_out_dir build /r cu133 gb10"
check "out_dir build: two toolkits never share a dir" 0 "-" "^/r/tuned/build/cu134/cmake$" \
  "${pre}; gpu_tuned_out_dir build /r cu134 gb10"
check "out_dir build: there is no variant level (same path for any variant)" 0 "-" "^/r/tuned/build/cu133/cmake$" \
  "${pre}; gpu_tuned_out_dir build /r cu133 rtx40"
check "out_dir dist: tuned/build/<cuda>/dist" 0 "-" "^/r/tuned/build/cu133/dist$" \
  "${pre}; gpu_tuned_out_dir dist /r cu133 gb10"
check "out_dir dist: the shared pseudo-variant is a SIBLING of dist, never inside it" 0 "-" "^/r/tuned/build/cu133/dist-shared$" \
  "${pre}; gpu_tuned_out_dir dist /r cu133 shared"
check "out_dir dist: shared is not a path prefix of dist (a rm -rf of dist cannot delete it)" 0 "-" "^OK$" \
  "${pre}; a=\$(gpu_tuned_out_dir dist /r cu133 gb10); b=\$(gpu_tuned_out_dir dist /r cu133 shared); case \"\$b/\" in \"\$a\"/*) echo BAD;; *) echo OK;; esac"
check "out_dir releases: generated release inputs under the toolkit tree" 0 "-" "^/r/tuned/build/cu133/releases$" \
  "${pre}; gpu_tuned_out_dir releases /r cu133 gb10"
check "out_dir: bad cuda tag fails" 1 "not of the form cu<digits>" "-" \
  "${pre}; gpu_tuned_out_dir build /r 13.3 gb10"
check "out_dir build: the variant is optional now" 0 "-" "^/r/tuned/build/cu133/cmake$" \
  "${pre}; gpu_tuned_out_dir build /r cu133"
check "out_dir: a malformed variant fails" 1 "malformed" "-" \
  "${pre}; gpu_tuned_out_dir build /r cu133 'Bad Variant'"
check "out_dir: unknown kind fails" 1 "unknown kind 'logs'" "-" \
  "${pre}; gpu_tuned_out_dir logs /r cu133 gb10"
ct="$(mktemp -d)"
check "claim_toolkit_tree: first claim creates the tree and records the variant" 0 "-" "^gb10$" \
  "${pre}; gpu_tuned_claim_toolkit_tree '${ct}' cu134 gb10 && cat '${ct}/tuned/build/cu134/.variant'"
check "claim_toolkit_tree: the same variant again is fine" 0 "-" "-" \
  "${pre}; gpu_tuned_claim_toolkit_tree '${ct}' cu134 gb10"
check "claim_toolkit_tree: another variant on the same toolkit tree is refused" 1 "was built for variant 'gb10', not 'rtx40'" "-" \
  "${pre}; gpu_tuned_claim_toolkit_tree '${ct}' cu134 rtx40"
check "claim_toolkit_tree: another toolkit gets its own tree and owner" 0 "-" "^rtx40$" \
  "${pre}; gpu_tuned_claim_toolkit_tree '${ct}' cu133 rtx40 && cat '${ct}/tuned/build/cu133/.variant'"
check "claim_toolkit_tree: a variant is required" 1 "a variant is required" "-" \
  "${pre}; gpu_tuned_claim_toolkit_tree '${ct}' cu134 ''"
rm -rf "${ct}"
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
# no id: an error that names how to choose and lists what is defined; nothing is defaulted or guessed
printf '%s\n' 'TOOLKIT_ID="cu139"' 'TOOLKIT_CUDA_VER="13.9"' 'TOOLKIT_CUDA_HOME="/x"' 'TOOLKIT_NVCC_RELEASE="13.9"' > "${tk}/dflt/toolkits/cu139.env"
printf '%s\n' 'TOOLKIT_ID="cu1310"' 'TOOLKIT_CUDA_VER="13.10"' 'TOOLKIT_CUDA_HOME="/y"' 'TOOLKIT_NVCC_RELEASE="13.10"' > "${tk}/dflt/toolkits/cu1310.env"
printf '%s\n' 'TOOLKIT_NVCC_RELEASE="0"' > "${tk}/dflt/toolkits/gb10-cu139.env"
ld="${pre}; export GPU_TUNED_PLATFORM=aarch64; gpu_tuned_load_toolkit '${tk}/dflt' gb10"
check "load_toolkit: no id is an error that says the toolkit is never defaulted" 1 "no toolkit specified.*never defaulted" "-" "${ld}"
check "load_toolkit: no id names CUDA_TAG and CUDA_VER as the way to choose" 1 "CUDA_TAG=cu133.*CUDA_VER=13\\.3" "-" "${ld}"
check "load_toolkit: no id lists every defined toolkit with its CUDA version" 1 "available toolkits:.*cu139\\(13\\.9\\).*cu1310\\(13\\.10\\)|available toolkits:.*cu1310\\(13\\.10\\).*cu139\\(13\\.9\\)" "-" "${ld}"
check "load_toolkit: a per-variant file is not counted as a toolkit in the list" 0 "-" "-" \
  "out=\"\$(${ld} 2>&1 || true)\"; [[ \"\${out}\" != *gb10-cu139* ]]"
check "load_toolkit: no id exports nothing, so a caller cannot carry on with a guess" 0 "-" "^$" \
  "${ld} 2>/dev/null || true; echo \"\${CUDA_TAG:-}\""
# interactive: with a terminal on stdin and stderr it asks which listed toolkit to use (script(1) supplies the pty)
cat > "${tk}/prompt.sh" <<EOF
set -uo pipefail
source '${LIB}'
export GPU_TUNED_PLATFORM=aarch64
gpu_tuned_load_toolkit '${tk}/dflt' gb10 && echo "CHOSEN=\${CUDA_TAG} \${CUDA_VER}"
echo "RC=\$?"
EOF
check "load_toolkit: at a terminal it lists the toolkits and takes a number" 0 "-" "CHOSEN=cu139 13\\.9" "ask() { printf '%s\\n' \"\$1\" | script -qec \"bash '${tk}/prompt.sh'\" /dev/null 2>&1 | tr -d '\\r'; }; ask 2"
check "load_toolkit: at a terminal it takes an id" 0 "-" "CHOSEN=cu1310 13\\.10" "ask() { printf '%s\\n' \"\$1\" | script -qec \"bash '${tk}/prompt.sh'\" /dev/null 2>&1 | tr -d '\\r'; }; ask cu1310"
check "load_toolkit: at a terminal the prompt shows each version and install state" 0 "-" "1\\) cu1310  CUDA 13\\.10  NOT installed \\(/y\\)" "ask() { printf '%s\\n' \"\$1\" | script -qec \"bash '${tk}/prompt.sh'\" /dev/null 2>&1 | tr -d '\\r'; }; ask 1"
check "load_toolkit: at a terminal an empty answer is an error, not a guess" 0 "-" "no toolkit chosen.*\\n?.*" "ask() { printf '%s\\n' \"\$1\" | script -qec \"bash '${tk}/prompt.sh'\" /dev/null 2>&1 | tr -d '\\r'; }; ask ''"
check "load_toolkit: at a terminal an out-of-range number is an error" 0 "-" "no toolkit chosen \\('7'\\)" "ask() { printf '%s\\n' \"\$1\" | script -qec \"bash '${tk}/prompt.sh'\" /dev/null 2>&1 | tr -d '\\r'; }; ask 7"
check "load_toolkit: at a terminal a wrong answer leaves no toolkit set" 0 "-" "^none$" "ask() { printf '%s\\n' \"\$1\" | script -qec \"bash '${tk}/prompt.sh'\" /dev/null 2>&1 | tr -d '\\r'; }; ask 9 | grep -c CHOSEN | grep -qx 0 && echo none"
check "load_toolkit: a stray toolkits/DEFAULT file is ignored, not obeyed" 1 "no toolkit specified" "-" \
  "printf 'cu139\\n' > '${tk}/dflt/toolkits/DEFAULT'; rc=0; ${ld} || rc=\$?; rm -f '${tk}/dflt/toolkits/DEFAULT'; exit \$rc"
check "load_toolkit: an explicit id selects that toolkit, not the highest" 0 "-" "^cu139 13\\.9$" \
  "${pre}; export GPU_TUNED_PLATFORM=aarch64; gpu_tuned_load_toolkit '${tk}/dflt' gb10 cu139; echo \"\${CUDA_TAG} \${CUDA_VER}\""
check "load_toolkit: the real data dir defines cu133 and cu134 and picks neither unasked" 1 "no toolkit specified" "-" \
  "${pre}; export GPU_TUNED_PLATFORM=aarch64; D='${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}'; [ -f \"\$D/toolkits/cu133.env\" ] && [ -f \"\$D/toolkits/cu134.env\" ] && gpu_tuned_load_toolkit \"\$D\" gb10"
check "load_toolkit: no id and no toolkit files is an error" 1 "none defined" "-" \
  "${pre}; mkdir -p '${tk}/empty/toolkits'; gpu_tuned_load_toolkit '${tk}/empty' gb10"
# every real toolkit file must answer the NCCL question (a pinned system version, or "none"), so a new toolkit cannot be added without deciding it
check "toolkit files: every toolkit defines TOOLKIT_NCCL_VERSION (a version, or none)" 0 "-" "^ok$" \
  "D='${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}'; bad=0; for f in \"\$D\"/toolkits/*.env; do b=\$(basename \$f .env); case \$b in *-cu*) continue;; esac; grep -qE '^TOOLKIT_NCCL_VERSION=\"[^\"]+\"' \$f || { echo \"missing in \$f\" >&2; bad=1; }; done; [ \$bad -eq 0 ] && echo ok"
check "verify_toolkit: TOOLKIT_NCCL_VERSION=none skips the system NCCL check and says so" 0 "-" "no system NCCL" \
  "${pre}; mkdir -p '${tk}/n/bin'; printf '#!/bin/sh\\necho \"Cuda compilation tools, release 99.9, V99.9.1\"\\n' > '${tk}/n/bin/nvcc'; chmod +x '${tk}/n/bin/nvcc'; TOOLKIT_ID=cu999 TOOLKIT_CUDA_HOME='${tk}/n' CUDA_HOME='${tk}/n' TOOLKIT_NVCC_RELEASE=99.9 TOOLKIT_NCCL_VERSION=none PATH='${tk}/n/bin':\$PATH gpu_tuned_verify_toolkit"
# bundled CUDA flavour (dpkg stubbed on PATH)
mkdir -p "${tk}/stubs"
cat > "${tk}/stubs/dpkg" <<'EOF'
#!/bin/sh
[ "$1" = "-S" ] && { case "$2" in *libnccl*) echo "libnccl2:arm64: $2";; *libplain*) echo "libplain:arm64: $2";; esac; exit 0; }
exit 1
EOF
cat > "${tk}/stubs/dpkg-query" <<'EOF'
#!/bin/sh
case "$3" in libnccl2) printf '2.31.2-1+cuda13.3';; libplain) printf '1.0-1';; esac
EOF
chmod +x "${tk}/stubs/dpkg" "${tk}/stubs/dpkg-query"; : > "${tk}/libnccl.so.2"; : > "${tk}/libplain.so.1"
check "bundled_cuda_flavor: a package built for another CUDA is refused, naming both" 1 "libnccl2 2.31.2-1\\+cuda13.3, built for CUDA 13.3, but this package is for CUDA 13.4" "-" \
  "PATH='${tk}/stubs':\$PATH; ${pre}; gpu_tuned_verify_bundled_cuda_flavor 13.4 '${tk}/libnccl.so.2'"
check "bundled_cuda_flavor: the matching CUDA flavour passes" 0 "-" "-" \
  "PATH='${tk}/stubs':\$PATH; ${pre}; gpu_tuned_verify_bundled_cuda_flavor 13.3 '${tk}/libnccl.so.2'"
check "bundled_cuda_flavor: a package with no CUDA flavour is not judged" 0 "-" "-" \
  "PATH='${tk}/stubs':\$PATH; ${pre}; gpu_tuned_verify_bundled_cuda_flavor 13.4 '${tk}/libplain.so.1'"
check "bundled_cuda_flavor: a bad CUDA version argument is refused" 1 "must look like 13.4" "-" "${pre}; gpu_tuned_verify_bundled_cuda_flavor 134 '${tk}/libplain.so.1'"
# fetch (gh stubbed: builds a release tarball in the shape zbrad/nccl publishes)
cat > "${tk}/stubs/gh" <<'EOF'
#!/bin/bash
# gh release download <tag> --repo zbrad/nccl --pattern ... --pattern ... --dir <dir>
tag="$3"; dir=""; while [ $# -gt 0 ]; do [ "$1" = "--dir" ] && dir="$2"; shift; done
[ -n "${FAKE_GH_FAIL:-}" ] && exit 1
w="$(mktemp -d)"; n="nccl-tuned-2.30.7-gb10-cu134-20261012"; mkdir -p "$w/$n/lib" "$w/$n/include"
: > "$w/$n/lib/libnccl_static.a"; : > "$w/$n/include/nccl.h"
echo "tag=${FAKE_GH_TAG:-$tag}" > "$w/$n/BUILD_INFO"
tar -czf "$dir/$n.tar.gz" -C "$w" "$n"
(cd "$dir" && sha256sum "$n.tar.gz" > "$n.tar.gz.sha256")
[ -n "${FAKE_GH_BADSUM:-}" ] && echo "0000  $n.tar.gz" > "$dir/$n.tar.gz.sha256"
exit 0
EOF
chmod +x "${tk}/stubs/gh"
check "fetch_nccl: downloads, verifies and extracts into dest" 0 "-" "^ok$" \
  "PATH='${tk}/stubs':\$PATH; ${pre}; gpu_tuned_fetch_nccl_release v0.20261012.0-gb10-cu134 '${tk}/b/cu134/nccl/v0.20261012.0-gb10-cu134' 2>/dev/null && [ -f '${tk}/b/cu134/nccl/v0.20261012.0-gb10-cu134/lib/libnccl_static.a' ] && [ \"\$(cat '${tk}/b/cu134/nccl/v0.20261012.0-gb10-cu134/.tag')\" = v0.20261012.0-gb10-cu134 ] && echo ok"
check "fetch_nccl: a destination already holding the tag is left alone (no gh call)" 0 "-" "^ok$" \
  "PATH='${tk}/stubs':\$PATH; FAKE_GH_FAIL=1; export FAKE_GH_FAIL; ${pre}; gpu_tuned_fetch_nccl_release v0.20261012.0-gb10-cu134 '${tk}/b/cu134/nccl/v0.20261012.0-gb10-cu134' && echo ok"
check "fetch_nccl: a checksum mismatch is refused and leaves nothing behind" 1 "does not match its published sha256" "-" \
  "PATH='${tk}/stubs':\$PATH; FAKE_GH_BADSUM=1; export FAKE_GH_BADSUM; ${pre}; gpu_tuned_fetch_nccl_release vX '${tk}/c/cu134/nccl/vX'; rc=\$?; [ ! -e '${tk}/c/cu134/nccl/vX' ]; exit \$rc"
check "fetch_nccl: a BUILD_INFO naming another tag is refused" 1 "does not say tag=" "-" \
  "PATH='${tk}/stubs':\$PATH; FAKE_GH_TAG=other; export FAKE_GH_TAG; ${pre}; gpu_tuned_fetch_nccl_release vY '${tk}/d/cu134/nccl/vY'"
check "fetch_nccl: a destination without an nccl component is refused" 1 "no /nccl/ component" "-" \
  "PATH='${tk}/stubs':\$PATH; ${pre}; gpu_tuned_fetch_nccl_release v1 '${tk}/e/somewhere/v1'"
check "fetch_nccl: a failed download is an error" 1 "could not download" "-" \
  "PATH='${tk}/stubs':\$PATH; FAKE_GH_FAIL=1; export FAKE_GH_FAIL; ${pre}; gpu_tuned_fetch_nccl_release vZ '${tk}/f/cu134/nccl/vZ'"
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
mkdir -p "${tk}/other/bin"; printf '#!/bin/sh\necho x\n' > "${tk}/other/bin/nvcc"; chmod +x "${tk}/other/bin/nvcc"
check "verify_toolkit: the first nvcc on PATH outside CUDA_HOME is rejected" 1 "first nvcc on PATH is .*other/bin/nvcc" "-" \
  "${lt} rtx40 cu999; PATH='${tk}/other/bin':\$PATH; gpu_tuned_check_toolkit_path"
check "verify_toolkit: another toolkit's nvcc further down PATH is a warning" 0 "shadowed by .*cuda-99.9/bin.*other/bin" "-" \
  "${lt} rtx40 cu999; PATH=\"\$PATH:${tk}/other/bin\"; gpu_tuned_check_toolkit_path"
check "verify_toolkit: GPU_TUNED_STRICT_TOOLKIT_PATH=1 makes that warning a failure" 1 "shadowed by" "-" \
  "${lt} rtx40 cu999; PATH=\"\$PATH:${tk}/other/bin\"; GPU_TUNED_STRICT_TOOLKIT_PATH=1 gpu_tuned_check_toolkit_path"
check "verify_toolkit: a PATH with only CUDA_HOME's nvcc is silent" 0 "-" "-" \
  "${lt} rtx40 cu999; gpu_tuned_check_toolkit_path"
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

# --- helpers moved from the consumers' env.sh (A7) ---
hc="$(mktemp -d)"
mkdir -p "${hc}/repo/cpp" "${hc}/b1" "${hc}/b2" "${hc}/cuda-13.3/x" "${hc}/cuda-13.2/x" "${hc}/cuda-12.9/x"
printf 'CMAKE_CUDA_COMPILER:FILEPATH=/usr/local/cuda-13.3/bin/nvcc\nCMAKE_HOME_DIRECTORY:INTERNAL=%s/repo/cpp\n' "${hc}" > "${hc}/b1/CMakeCache.txt"
printf 'CMAKE_CUDA_COMPILER:FILEPATH=/usr/local/cuda-13.3/bin/nvcc\nCMAKE_HOME_DIRECTORY:INTERNAL=/elsewhere/cpp\n' > "${hc}/b2/CMakeCache.txt"
henv="${pre}; export CUDA_HOME=/usr/local/cuda-13.3 GPU_TUNED_REPO_ROOT='${hc}/repo'"
check "cache_consistent: no cache yet passes" 0 "-" "-" "${henv}; gpu_tuned_assert_cmake_cache_consistent '${hc}/none'"
check "cache_consistent: matching compiler and source passes" 0 "-" "-" "${henv}; gpu_tuned_assert_cmake_cache_consistent '${hc}/b1'"
check "cache_consistent: another toolkit's nvcc fails" 1 "was configured with" "-" \
  "${pre}; export CUDA_HOME=/usr/local/cuda-13.4 GPU_TUNED_REPO_ROOT='${hc}/repo'; gpu_tuned_assert_cmake_cache_consistent '${hc}/b1'"
check "cache_consistent: another source tree fails" 1 "source tree /elsewhere/cpp" "-" "${henv}; gpu_tuned_assert_cmake_cache_consistent '${hc}/b2'"
check "cache_consistent: GPU_TUNED_CMAKE_SOURCE_DIR overrides the source tree" 0 "-" "-" \
  "${henv}; GPU_TUNED_CMAKE_SOURCE_DIR=/elsewhere/cpp gpu_tuned_assert_cmake_cache_consistent '${hc}/b2'"
check "pin_honored: nothing pinned passes" 0 "-" "-" "${pre}; gpu_tuned_verify_pin_honored CUB '' '${hc}/cuda-13.3'"
check "pin_honored: the pinned directory was used" 0 "-" "OK: CUB used" "${pre}; gpu_tuned_verify_pin_honored CUB '${hc}/cuda-13.3' '${hc}/cuda-13.3/'"
check "pin_honored: a silent override is fatal" 1 "silently overridden" "-" "${pre}; gpu_tuned_verify_pin_honored CUB '${hc}/cuda-13.3' '${hc}/cuda-13.2'"
check "cccl_match: same version passes" 0 "-" "matches this build" "${pre}; gpu_tuned_verify_cccl_toolkit_match '${hc}/cuda-13.3/x' CCCL 13.3"
check "cccl_match: major mismatch is fatal" 1 "MAJOR version" "-" "${pre}; gpu_tuned_verify_cccl_toolkit_match '${hc}/cuda-12.9/x' CCCL 13.3"
check "cccl_match: minor mismatch only warns" 0 "minor version differs" "-" "${pre}; gpu_tuned_verify_cccl_toolkit_match '${hc}/cuda-13.2/x' CCCL 13.3"
check "cccl_match: minor mismatch is fatal when strict" 1 "exact major.minor" "-" "${pre}; GPU_TUNED_STRICT_TOOLKIT_MATCH=1 gpu_tuned_verify_cccl_toolkit_match '${hc}/cuda-13.2/x' CCCL 13.3"
check "cccl_match: no directory is skipped" 0 "no resolved directory" "-" "${pre}; gpu_tuned_verify_cccl_toolkit_match '' CCCL 13.3"
rm -rf "${hc}"

# --- release vs publish: gates, ready-marker, publish only from the marker ---
rp="$(mktemp -d)"
(
    set -e; export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q -b tuned-builds "${rp}/r"; cd "${rp}/r"
    mkdir -p tuned/releases tuned/build/cu134/dist tuned/build/cu134/releases
    echo src > src.c; git add src.c; git commit -qm c1
    git init -q --bare -b tuned-builds "${rp}/origin.git"; git remote add origin "${rp}/origin.git"; git push -q origin tuned-builds
    echo built > tuned/build/cu134/libx.so; sleep 1
    echo "All binaries passed." > tuned/build/cu134/releases/TEST.log; sleep 1
    echo tarball > tuned/build/cu134/dist/x-0.20261011.0-gb10-cu134.tar.gz
    (cd tuned/build/cu134/dist && sha256sum x-0.20261011.0-gb10-cu134.tar.gz > x-0.20261011.0-gb10-cu134.tar.gz.sha256)
    sha="$(sha256sum tuned/build/cu134/dist/x-0.20261011.0-gb10-cu134.tar.gz | awk '{print $1}')"
    printf 'release_tag=v0.20261011.0-gb10-cu134\ncuda_tag=cu134\nvariant=gb10\nsha256=%s\n' "${sha}" > tuned/build/cu134/dist/package-info.txt
    sleep 1; echo "=== Smoke test summary: passed ===" > tuned/build/cu134/releases/SMOKE.log
    packaged="$(git rev-parse HEAD)"; echo "${packaged}" > "${rp}/packaged"
    echo "# notes" > tuned/releases/RELEASE_NOTES_0.20261011.0-gb10-cu134.md; git add tuned/releases; git commit -qm notes; git push -q origin tuned-builds
    mkdir "${rp}/bin"; printf '#!/bin/sh\necho gh-called "$@" >> "%s/gh.log"\n' "${rp}" > "${rp}/bin/gh"; chmod +x "${rp}/bin/gh"
) >/dev/null 2>&1
B=tuned/build/cu134
inrp="cd '${rp}/r'; export PATH='${rp}/bin':\"\$PATH\"; : > '${rp}/gh.log'; PK=\$(cat '${rp}/packaged')"
GATES="gpu_tuned_release_gates tag=v0.20261011.0-gb10-cu134 variant=gb10 cuda=cu134 info=${B}/dist/package-info.txt built=${B}/libx.so test_log=${B}/releases/TEST.log 'test_pass=All binaries passed' tarball=${B}/dist/x-0.20261011.0-gb10-cu134.tar.gz smoke_log=${B}/releases/SMOKE.log notes=tuned/releases/RELEASE_NOTES_0.20261011.0-gb10-cu134.md packaged=\$PK"
check "release_gates: a fully valid layout passes every gate" 0 "-" "smoke test of this tarball passed" "${pre}; ${inrp}; ${GATES}"
check "release_gates: a stale test log (build newer) fails" 1 "newer than" "-" "${pre}; ${inrp}; touch -r ${B}/libx.so ${rp}/ref; touch ${B}/libx.so; rc=0; ${GATES} || rc=\$?; touch -r ${rp}/ref ${B}/libx.so; exit \$rc"
check "release_gates: a log without the pass phrase fails" 1 "does not show a clean pass" "-" "${pre}; ${inrp}; ${GATES/All binaries passed/NOPE}"
check "release_gates: a missing smoke log fails" 1 "smoke log not found" "-" "${pre}; ${inrp}; ${GATES/SMOKE.log/none.log}"
check "release_gates: a DRAFT banner in the notes fails" 1 "still a draft" "-" \
  "${pre}; ${inrp}; f=tuned/releases/RELEASE_NOTES_0.20261011.0-gb10-cu134.md; cp \$f \$f.keep; echo '<!-- DRAFT — not yet published: x -->' >> \$f; rc=0; ${GATES} || rc=\$?; cp \$f.keep \$f; rm -f \$f.keep; exit \$rc"
check "release_gates: a code change since the packaged commit fails" 1 "files other than tuned/releases/ changed" "-" \
  "${pre}; ${inrp}; echo more >> src.c; git commit -qam later; git push -q origin tuned-builds; rc=0; ${GATES} || rc=\$?; git reset -q --hard HEAD~1; git push -q -f origin tuned-builds; exit \$rc"
check "release_gates: an unknown key is an error" 2 "unknown key" "-" "${pre}; gpu_tuned_release_gates bogus=1"
RM="${B}/releases/RELEASE_READY_gb10"
ASSETS="${B}/dist/x-0.20261011.0-gb10-cu134.tar.gz#tarball ${B}/releases/TEST.log#tests"
READY="gpu_tuned_release_ready ${RM} o/r v0.20261011.0-gb10-cu134 title tuned/releases/RELEASE_NOTES_0.20261011.0-gb10-cu134.md ${ASSETS}"
check "release_ready: writes a marker and never calls gh" 0 "-" "nothing was published" \
  "${pre}; ${inrp}; ${READY}; test -f ${RM}; [ ! -s '${rp}/gh.log' ]"
check "publish_ready: no marker is refused before gh is called" 1 "no ready-marker" "-" \
  "${pre}; ${inrp}; rm -f ${RM}; rc=0; gpu_tuned_publish_ready ${RM} || rc=\$?; [ ! -s '${rp}/gh.log' ] && exit \$rc"
check "publish_ready: a marker with its assets intact publishes and is spent" 0 "-" "OK: published" \
  "${pre}; ${inrp}; ${READY} >/dev/null; gpu_tuned_publish_ready ${RM}; grep -q 'release create v0.20261011.0-gb10-cu134' '${rp}/gh.log'; test -f ${RM}.published; test ! -f ${RM}"
check "publish_ready: the same marker cannot publish twice" 1 "no ready-marker" "-" "${pre}; ${inrp}; gpu_tuned_publish_ready ${RM}"
check "publish_ready: HEAD moved since the gates is refused" 1 "HEAD moved" "-" \
  "${pre}; ${inrp}; ${READY} >/dev/null; echo n >> src.c; git commit -qam moved; git push -q origin tuned-builds; rc=0; gpu_tuned_publish_ready ${RM} || rc=\$?; git reset -q --hard HEAD~1; git push -q -f origin tuned-builds; [ ! -s '${rp}/gh.log' ] && exit \$rc"
check "publish_ready: a changed asset is refused" 1 "changed or vanished" "-" \
  "${pre}; ${inrp}; ${READY} >/dev/null; echo tampered >> ${B}/releases/TEST.log; rc=0; gpu_tuned_publish_ready ${RM} || rc=\$?; [ ! -s '${rp}/gh.log' ] && exit \$rc"
check "publish_ready: changed notes are refused" 1 "notes changed" "-" \
  "${pre}; ${inrp}; echo 'All binaries passed.' > ${B}/releases/TEST.log; ${READY} >/dev/null; f=tuned/releases/RELEASE_NOTES_0.20261011.0-gb10-cu134.md; cp \$f \$f.keep; echo x >> \$f; rc=0; gpu_tuned_publish_ready ${RM} || rc=\$?; cp \$f.keep \$f; rm -f \$f.keep; [ ! -s '${rp}/gh.log' ] && exit \$rc"
check "release_marker_clear: removes a marker so a failing run leaves none" 0 "-" "-" \
  "${pre}; ${inrp}; ${READY} >/dev/null; gpu_tuned_release_marker_clear ${RM}; test ! -f ${RM}"
rm -rf "${rp}"

echo; echo "passed=${PASS} failed=${FAIL} skipped=${SKIPPED}"
[[ "${FAIL}" -eq 0 ]]
