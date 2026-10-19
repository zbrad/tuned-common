#!/bin/bash
# Tests for tools/tuned_compliance.sh on throwaway repos (no network). Every mechanical check is
# shown to PASS on a good fixture and to FAIL (or go UNKNOWN) on a bad one, as H4 requires.
# Usage: bash tests/test_tuned_compliance.sh   (exit 0 = all pass)
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT

# A private copy of tuned-common (working tree, committed) so the tool's reference commit is exactly this tree.
TC="${W}/tc"; mkdir -p "${TC}/tools"
cp -r "${SRC}/tuned-common.sh" "${SRC}/sync-common.sh" "${SRC}/toolkits" "${SRC}/devices" "${TC}/"
cp "${SRC}/tools/tuned_compliance.sh" "${TC}/tools/"
( cd "${TC}" && git init -q -b main && git add -A && git commit -qm base ) || { echo "fixture failed"; exit 1; }
TOOL="${TC}/tools/tuned_compliance.sh"
export GPU_TUNED_COMPLIANCE_REF=HEAD
TC_SHA="$(git -C "${TC}" rev-parse HEAD)"

GOOD="${W}/good"; mkdir -p "${GOOD}/tuned/releases" "${GOOD}/tuned/common-data"
(
    set -e; cd "${GOOD}"; git init -q -b main
    cp "${TC}/tuned-common.sh" tuned/common.sh; cp "${TC}/sync-common.sh" tuned/sync-common.sh
    echo "${TC_SHA}" > tuned/common.sh.sha
    cp -r "${TC}/toolkits" "${TC}/devices" tuned/common-data/
    printf '%s\n' 'source "$(dirname "$0")/common.sh"' 'gpu_tuned_load_toolkit' 'gpu_tuned_verify_toolkit' 'gpu_tuned_load_repo_env' > tuned/env.sh
    echo 'MY_KEY=1' > tuned/repo.env
    for s in build full_test; do echo "# $s" > "tuned/${s}.sh"; done
    echo 'gpu_tuned_embed_build_info_json x' >> tuned/build.sh
    printf '%s\n' 'echo package-info.txt' 'sha256sum t > t.sha256' > tuned/package.sh
    echo 'gpu_tuned_verify_resolves_in a b c' > tuned/smoke_test.sh
    echo 'gpu_tuned_publish_ready "$marker"' > tuned/publish.sh
    printf '%s\n' 'echo "run bash tuned/package.sh first" >&2' 'grep SMOKE_RESULTS x; grep package-info y; grep DRAFT z' > tuned/release.sh
    echo "notes" > tuned/releases/RELEASE_NOTES_0.20261016.0-gb10-cu133.md
    git add -A; git commit -qm good
) >/dev/null 2>&1 || { echo "good fixture failed"; exit 1; }

# run <name> <id> <want-status> <mutation shell> [extra tool args]: mutate a copy, commit, run, compare one row.
run() {
    local name="$1" id="$2" want="$3" mut="$4"; shift 4
    local d="${W}/case"; rm -rf "${d}"; cp -r "${GOOD}" "${d}"
    ( cd "${d}" && bash -c "${mut}" && git add -A && git commit -qm "case ${name}" --allow-empty ) >/dev/null 2>&1
    local out row; out="$(bash "${TOOL}" "${d}" "$@" 2>&1)"; row="$(echo "${out}" | grep -E "^${id}[[:space:]]" | head -1)"
    if [[ "${row}" =~ ^${id}[[:space:]]+${want}([[:space:]]|$) ]]; then PASS=$((PASS+1)); echo "ok   - ${name}"
    else FAIL=$((FAIL+1)); echo "FAIL - ${name}: want ${id} ${want}, got: ${row:-<no row>}"; fi
}

run 'baseline A1 passes'                  A1 PASS 'true'
run 'A1 edited common.sh fails'           A1 FAIL 'echo "# local edit" >> tuned/common.sh'
run 'A1 missing sha file fails'         A1 FAIL 'rm tuned/common.sh.sha'
run 'A2 passes'                           A2 PASS 'true'
run 'A2 changed sync-common.sh fails'     A2 FAIL 'echo "# x" >> tuned/sync-common.sh'
run 'A2 missing toolkit fails'            A2 FAIL 'rm tuned/common-data/toolkits/cu133.env'
run 'A3 passes'                           A3 PASS 'true'
run 'A3 select_toolkit alone satisfies the toolkit calls' A3 PASS "printf '%s\\n' 'source \"\$(dirname \"\$0\")/common.sh\"' 'gpu_tuned_select_toolkit' 'gpu_tuned_load_repo_env' > tuned/env.sh"
run 'A3 select_toolkit without repo.env loading fails' A3 FAIL "printf '%s\\n' 'gpu_tuned_select_toolkit' > tuned/env.sh"
run 'A3 no repo.env fails'                A3 FAIL 'rm tuned/repo.env'
run 'A3 loader only in a comment fails'   A3 FAIL "sed -i 's/^gpu_tuned_load_toolkit/# gpu_tuned_load_toolkit/' tuned/env.sh"
run 'A4 passes'                           A4 PASS 'true'
run 'A4 repo.env sets CUDA_HOME fails'    A4 FAIL 'echo "CUDA_HOME=/x" >> tuned/repo.env'
run 'A5 passes'                           A5 PASS 'true'
run 'A5 err trap off fails'               A5 FAIL 'echo "export GPU_TUNED_NO_ERR_TRAP=1" >> tuned/build.sh'
run 'A6 passes'                           A6 PASS 'true'
run 'A6 toolkit lacks NCCL key fails'     A6 FAIL "sed -i '/^TOOLKIT_NCCL_VERSION=/d' tuned/common-data/toolkits/cu134.env"
run 'A7 passes'                           A7 PASS 'true'
run 'A7 local gpu_tuned_ function fails'  A7 FAIL 'printf "gpu_tuned_my_helper() {\\n  :\\n}\\n" >> tuned/env.sh'
run 'A7 repo-prefixed helper passes'      A7 PASS 'printf "cuvs_my_helper() {\\n  :\\n}\\n" >> tuned/env.sh'
run 'B1 passes'                           B1 PASS 'true'
run 'B1 missing smoke_test.sh fails'      B1 FAIL 'rm tuned/smoke_test.sh'
run 'B1 missing publish.sh fails'         B1 FAIL 'rm tuned/publish.sh'
run 'B3 passes (message naming package.sh is not a call)' B3 PASS 'true'
run 'B3 package.sh publishes fails'       B3 FAIL 'echo "gh release create v1" >> tuned/package.sh'
run 'B3 release.sh packages fails'        B3 FAIL 'printf "  bash tuned/package.sh gb10\n" >> tuned/release.sh'
run 'B4 passes'                           B4 PASS 'true'
run 'B4 comment mention passes'           B4 PASS 'echo "# /usr/local/cuda is not used" >> tuned/build.sh'
run 'B4 fallback to /usr/local/cuda fails' B4 FAIL 'echo "export CUDA_HOME=/usr/local/cuda" >> tuned/build.sh'
run 'B4 /usr/local/cuda-* scan fails'     B4 FAIL 'echo "for d in /usr/local/cuda-*; do :; done" >> tuned/build.sh'
run 'B4 installed-toolkit helper fails'   B4 FAIL 'echo "v=\$(gpu_tuned_installed_cuda_toolkits | tail -1)" >> tuned/build.sh'
run 'B4 nvcc on PATH as selector fails'   B4 FAIL 'echo "command -v nvcc && :" >> tuned/build.sh'
run 'B4 literal CUDA_TAG default fails'   B4 FAIL 'echo "CUDA_TAG=\"\${CUDA_TAG:-cu132}\"" >> tuned/build.sh'
run 'B4 literal CUDA_VER default fails'   B4 FAIL 'echo "x=\"\${FAISS_CUDA_VER:-13.3}\"" >> tuned/build.sh'
run 'B4 empty default passes'             B4 PASS 'echo "x=\"\${CUDA_HOME:-}\"" >> tuned/build.sh'
run 'B4 alias to another variable passes' B4 PASS 'echo "x=\"\${FAISS_CUDA_TAG:-\${CUDA_TAG:-}}\"" >> tuned/build.sh'
run 'B4 versioned toolkit path passes'    B4 PASS 'echo "x=/usr/local/cuda-13.3/bin" >> tuned/build.sh'
run 'C5 passes'                           C5 PASS 'true'
run 'C5 bare nproc fails'                 C5 FAIL 'echo "make -j\$(nproc)" >> tuned/build.sh'
run 'C5 gpu_tuned_jobs line passes'       C5 PASS 'echo "j=\$(gpu_tuned_jobs) # not nproc" >> tuned/build.sh'
run 'E6 commit count is flagged for a person' E6 UNKNOWN 'echo "n=\$(git rev-list --count HEAD)" >> tuned/build.sh'
run 'G5 passes'                           G5 PASS 'true'
run 'G5 without resolves_in is UNKNOWN'   G5 UNKNOWN 'echo "# nothing" > tuned/smoke_test.sh'
run 'H1 passes'                           H1 PASS 'true'
run 'H1 the shared sidecar helper passes'    H1 PASS 'printf "%s\\n" "echo package-info.txt" "gpu_tuned_write_sha256_sidecar x" > tuned/package.sh'
run 'H1 no sha256 sidecar fails'          H1 FAIL 'echo "echo package-info.txt" > tuned/package.sh'
run 'H7 passes'                           H7 PASS 'true'
run 'H7 the shared stamp helper passes'     H7 PASS "sed -i 's/gpu_tuned_embed_build_info_json/gpu_tuned_stamp_lib_json/' tuned/build.sh"
run 'H7 the file writer for non-ELF artifacts passes' H7 PASS "sed -i 's/gpu_tuned_embed_build_info_json/gpu_tuned_write_build_info_json/' tuned/build.sh"
run 'H7 free-text stamp fails'            H7 FAIL "sed -i '/gpu_tuned_embed_build_info_json/d' tuned/build.sh"
run 'I1 passes'                           I1 PASS 'true'
run 'I1 release.sh without DRAFT gate fails' I1 FAIL "sed -i 's/DRAFT//' tuned/release.sh"
run 'I5 release and publish split passes'    I5 PASS 'true'
run 'I5 release.sh publishing fails'        I5 FAIL 'printf "gpu_tuned_publish_release a b c d e\n" >> tuned/release.sh'
run 'I5 release.sh creating a release fails' I5 FAIL 'printf "gh release create v1\n" >> tuned/release.sh'
run 'I5 publish.sh without the marker call fails' I5 FAIL 'echo "echo hi" > tuned/publish.sh'
run 'I5 missing publish.sh fails'           I5 FAIL 'rm tuned/publish.sh'
run 'I2 passes'                           I2 PASS 'true'
run 'I2 DRAFT notes fail'                 I2 FAIL 'echo DRAFT >> tuned/releases/RELEASE_NOTES_0.20261016.0-gb10-cu133.md'
run 'I2 old-form notes only fail'         I2 FAIL 'git mv tuned/releases/RELEASE_NOTES_0.20261016.0-gb10-cu133.md tuned/releases/RELEASE_NOTES_26.12_gb10_cu133.md'
run 'J1 passes'                           J1 PASS 'true'
run 'J1 Co-Authored-By trailer fails'     J1 FAIL 'echo x > tuned/x.txt; git add -A; git commit -qm "m

Co-Authored-By: Someone <s@s>"'
run 'J3 passes'                           J3 PASS 'true'
run 'J3 real hostname fails'              J3 FAIL 'echo "ssh zspark-1" > tuned/note.txt'
run 'kinds: wheel check N/A on native'    B2 N/A 'true'
run 'kinds: wheel script makes B2 apply'  B2 PASS 'echo "# w" > tuned/wheel.sh'
run 'D1 is UNKNOWN until attested'        D1 UNKNOWN 'true'

# exceptions, attestations and the config itself
run 'exception turns a FAIL into EXCEPTION' B4 EXCEPTION 'echo "export CUDA_HOME=/usr/local/cuda" >> tuned/build.sh; echo "exception: B4 | fallback kept until toolkit loader lands | 2026-10-16" > tuned/compliance.conf'
run 'exception on an unchecked (UNKNOWN) row shows as EXCEPTION' D1 EXCEPTION 'echo "exception: D1 | the pairing is kept elsewhere | 2026-10-18" > tuned/compliance.conf'
run 'exception without a reason is a CONF failure' CONF FAIL 'echo "exception: B4 | | 2026-10-16" > tuned/compliance.conf'
run 'exception without a date is a CONF failure' CONF FAIL 'echo "exception: B4 | because" > tuned/compliance.conf'
run 'exception does not hide a PASS'      B4 PASS 'echo "exception: B4 | unused | 2026-10-16" > tuned/compliance.conf'
run 'na record turns a row N/A'           D1 N/A 'echo "na: D1 | llama.cpp consumes no tuned repo | 2026-10-16" > tuned/compliance.conf'
C="$(git -C "${GOOD}" rev-parse HEAD)"
run 'valid attestation gives ATTESTED'    D1 ATTESTED "echo 'attest: D1 | read build.sh | 2026-10-16 | ${C}' > tuned/compliance.conf"
run 'attestation goes stale when tuned/ code changes' D1 UNKNOWN "echo 'attest: D1 | read build.sh | 2026-10-16 | ${C}' > tuned/compliance.conf; echo '# changed' >> tuned/build.sh"
run 'attestation survives a notes-only change' D1 ATTESTED "echo 'attest: D1 | read build.sh | 2026-10-16 | ${C}' > tuned/compliance.conf; echo more >> tuned/releases/RELEASE_NOTES_0.20261016.0-gb10-cu133.md"
run 'attestation with an unknown commit is UNKNOWN' D1 UNKNOWN "echo 'attest: D1 | x | 2026-10-16 | deadbeef' > tuned/compliance.conf"

# exit codes
d="${W}/rc"; rm -rf "${d}"; cp -r "${GOOD}" "${d}"
bash "${TOOL}" "${d}" >/dev/null 2>&1; rc=$?
[[ "${rc}" -eq 1 || "${rc}" -eq 2 ]] && { PASS=$((PASS+1)); echo "ok   - exit status is non-zero while any row is FAIL/UNKNOWN (${rc})"; } || { FAIL=$((FAIL+1)); echo "FAIL - exit status ${rc}"; }
bash "${TOOL}" /nonexistent >/dev/null 2>&1; rc=$?
[[ "${rc}" -eq 64 ]] && { PASS=$((PASS+1)); echo "ok   - bad path is a usage error (64)"; } || { FAIL=$((FAIL+1)); echo "FAIL - bad path rc ${rc}"; }

echo; echo "passed ${PASS}, failed ${FAIL}"; [[ "${FAIL}" -eq 0 ]]
