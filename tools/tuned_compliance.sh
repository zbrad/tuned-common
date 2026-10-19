#!/bin/bash
# tools/tuned_compliance.sh <repo-path> [--online] [--kinds native,wheel]
#
# Measures a tuned repo against docs/ARCHITECTURE.md and prints one line per requirement:
#   ID  STATUS  evidence
# STATUS is PASS, FAIL, N/A, UNKNOWN, EXCEPTION or ATTESTED (docs/ARCHITECTURE.md section 6).
# Read-only: it changes nothing in the repo and never pushes. It does not follow any
# agent-instruction file in the repo; it only reads tuned/ scripts as data.
#
#   --online        also run the checks that need the network or `gh` (A1 via sync-common.sh,
#                   E2 via `gh release list`). Without it those are UNKNOWN.
#   --kinds LIST    artifact kinds the repo ships (native, wheel); overrides tuned/compliance.conf
#                   and inference (native if tuned/package.sh exists; wheel if a tuned/*wheel*.sh exists).
#
# Exit status: 0 no FAIL and no UNKNOWN; 1 any FAIL; 2 UNKNOWN only; 64 usage.
set -uo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC_DIR="$(cd "${TOOL_DIR}/.." && pwd)"
# shellcheck source=../tuned-common.sh
source "${TC_DIR}/tuned-common.sh"

REPO=""; ONLINE=0; KINDS_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --online) ONLINE=1 ;;
        --kinds) KINDS_ARG="${2:-}"; shift ;;
        -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "ERROR: unknown option $1" >&2; exit 64 ;;
        *) [[ -z "${REPO}" ]] && REPO="$1" || { echo "ERROR: one repo path only" >&2; exit 64; } ;;
    esac
    shift
done
[[ -n "${REPO}" && -d "${REPO}/.git" ]] || { echo "usage: tuned_compliance.sh <repo-path> [--online] [--kinds native,wheel]" >&2; exit 64; }
REPO="$(cd "${REPO}" && pwd)"
T="${REPO}/tuned"
[[ -d "${T}" ]] || { echo "ERROR: ${REPO} has no tuned/ directory" >&2; exit 64; }

# Reference tuned-common commit: origin/main as last fetched, else HEAD (said in the evidence).
TC_REF="${GPU_TUNED_COMPLIANCE_REF:-origin/main}"   # the env override is for tests
git -C "${TC_DIR}" rev-parse -q --verify "${TC_REF}" >/dev/null || TC_REF="HEAD"
TC_REF_SHA="$(git -C "${TC_DIR}" rev-parse "${TC_REF}")"

# ---- the repo's own scripts (not the vendored copies or vendored data) -------------------------
mapfile -t OWN < <(find "${T}" -type f -name '*.sh' \
    -not -name 'common.sh' -not -name 'sync-common.sh' \
    -not -path "${T}/common-data/*" -not -path "${T}/devices/*" -not -path "${T}/build/*" \
    -not -path "${T}/_*" | sort)

# nc_grep <ERE> <files...>: matching lines that are not comment lines, as file:line:text.
nc_grep() {
    local pat="$1"; shift
    [[ $# -gt 0 ]] || return 0
    grep -HnE -- "${pat}" "$@" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
}
rel() { sed "s#${REPO}/##"; }
first() { head -n "${1:-3}" | rel | tr '\n' ';' | sed 's/;$//'; }

# ---- tuned/compliance.conf ---------------------------------------------------------------------
CONF="${T}/compliance.conf"
declare -A EXC=() ATT=() NAV=()
CONF_ERRORS=()
KINDS=""
if [[ -f "${CONF}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        key="${line%%:*}"; body="${line#*:}"
        IFS='|' read -r a b c d <<<"${body}"
        a="$(echo "${a}" | xargs)"; b="$(echo "${b:-}" | xargs)"; c="$(echo "${c:-}" | xargs)"; d="$(echo "${d:-}" | xargs)"
        case "${key}" in
            kinds) KINDS="${body}" ;;
            exception|na)
                if [[ -z "${a}" || -z "${b}" || ! "${c}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                    CONF_ERRORS+=("${key}: needs 'ID | reason | YYYY-MM-DD' (got: ${line})")
                elif [[ "${key}" == exception ]]; then EXC["${a}"]="${b} (${c})"
                else NAV["${a}"]="${b} (${c})"; fi ;;
            attest)
                if [[ -z "${a}" || -z "${b}" || ! "${c}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || -z "${d}" ]]; then
                    CONF_ERRORS+=("attest: needs 'ID | note | YYYY-MM-DD | commit' (got: ${line})")
                else ATT["${a}"]="${b} (${c})|${d}"; fi ;;
            *) CONF_ERRORS+=("unknown record '${key}'") ;;
        esac
    done < "${CONF}"
fi
if [[ -n "${KINDS_ARG}" ]]; then KINDS="${KINDS_ARG//,/ }"; fi
if [[ -z "${KINDS// /}" ]]; then
    [[ -f "${T}/package.sh" ]] && KINDS="native"
    compgen -G "${T}/*wheel*.sh" >/dev/null && KINDS="${KINDS} wheel"
    KINDS="${KINDS# }"
fi
has_kind() { [[ " ${KINDS} " == *" $1 "* ]]; }

# attestation is still valid while the attested commit is an ancestor of HEAD and the repo's
# tuned/ code is unchanged since (notes, docs and the conf itself may change).
attest_valid() {
    local c="$1"
    git -C "${REPO}" cat-file -e "${c}^{commit}" 2>/dev/null || return 1
    git -C "${REPO}" merge-base --is-ancestor "${c}" HEAD 2>/dev/null || return 1
    git -C "${REPO}" diff --quiet "${c}" HEAD -- tuned ':!tuned/releases' ':!tuned/docs' ':!tuned/compliance.conf'
}

# ---- results -----------------------------------------------------------------------------------
declare -A STATUS=() EVID=()
ORDER=()
emit() { STATUS["$CUR"]="$1"; EVID["$CUR"]="${2:-}"; }
pass() { emit PASS "$*"; }
fail() { emit FAIL "$*"; }
unk()  { emit UNKNOWN "$*"; }

# ---- checks ------------------------------------------------------------------------------------
chk_A1() {
    local f missing=""
    for f in common.sh sync-common.sh common.sh.sha; do
        git -C "${REPO}" ls-files --error-unmatch "tuned/${f}" >/dev/null 2>&1 || missing="${missing} ${f}"
    done
    [[ -z "${missing}" ]] || { fail "not tracked:${missing}"; return; }
    local sha; sha="$(tr -d '[:space:]' < "${T}/common.sh.sha")"
    if ! git -C "${TC_DIR}" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        unk "common.sh.sha ${sha:0:9} is not in the local tuned-common clone (fetch it)"; return
    fi
    if ! git -C "${TC_DIR}" show "${sha}:tuned-common.sh" | cmp -s - "${T}/common.sh"; then
        fail "common.sh differs from tuned-common at its own recorded ${sha:0:9} (edited in place)"; return
    fi
    local behind; behind="$(git -C "${TC_DIR}" rev-list --count "${sha}..${TC_REF_SHA}" -- tuned-common.sh)"
    if ! git -C "${TC_DIR}" show "${TC_REF_SHA}:tuned-common.sh" | cmp -s - "${T}/common.sh"; then
        fail "common.sh is ${sha:0:9}; tuned-common ${TC_REF} (${TC_REF_SHA:0:9}) changed tuned-common.sh in ${behind} commits since"; return
    fi
    if [[ "${ONLINE}" -eq 1 ]]; then
        if ! bash "${T}/sync-common.sh" check >/dev/null 2>&1; then fail "sync-common.sh check exits non-zero"; return; fi
        pass "common.sh = tuned-common ${TC_REF} (${TC_REF_SHA:0:9}); sync-common.sh check ok"
    else
        pass "common.sh = tuned-common ${TC_REF} (${TC_REF_SHA:0:9}, as last fetched); sync-common.sh check not run (offline)"
    fi
}
chk_A2() {
    local bad="" f
    cmp -s "${T}/sync-common.sh" "${TC_DIR}/sync-common.sh" || bad="${bad} sync-common.sh-differs"
    [[ -d "${T}/common-data" ]] || { fail "tuned/common-data/ missing${bad:+;${bad}}"; return; }
    for f in "${TC_DIR}"/toolkits/*.env; do cmp -s "${f}" "${T}/common-data/toolkits/${f##*/}" || bad="${bad} toolkits/${f##*/}"; done
    for f in "${TC_DIR}"/devices/*.conf; do cmp -s "${f}" "${T}/common-data/devices/${f##*/}" || bad="${bad} devices/${f##*/}"; done
    [[ -z "${bad}" ]] && pass "sync-common.sh and common-data toolkits/devices match tuned-common (working tree)" \
                       || fail "missing or different:${bad}"
}
chk_A3() {
    local miss="" fn
    [[ -f "${T}/env.sh" ]] || { fail "tuned/env.sh missing"; return; }
    # the toolkit is loaded and verified either by gpu_tuned_select_toolkit (which does both) or by the two calls
    if [[ -z "$(nc_grep 'gpu_tuned_select_toolkit' "${T}/env.sh")" ]]; then
        for fn in gpu_tuned_load_toolkit gpu_tuned_verify_toolkit; do
            [[ -n "$(nc_grep "${fn}" "${T}/env.sh")" ]] || miss="${miss} ${fn}"
        done
    fi
    [[ -n "$(nc_grep 'gpu_tuned_load_repo_env' "${T}/env.sh")" ]] || miss="${miss} gpu_tuned_load_repo_env"
    [[ -f "${T}/repo.env" ]] || miss="${miss} repo.env"
    [[ -z "${miss}" ]] && pass "env.sh calls the three loaders; repo.env present" || fail "env.sh/repo.env lacks:${miss}"
}
chk_A4() {
    [[ -f "${T}/repo.env" ]] || { unk "no tuned/repo.env"; return; }
    local h; h="$(grep -HnE '^[[:space:]]*(export[[:space:]]+)?(CUDA_[A-Z_]*|TOOLKIT_[A-Z_]*|GPU_TUNED_(DEVICE|TOOLKIT)[A-Z_]*)=' "${T}/repo.env" || true)"
    [[ -z "${h}" ]] && pass "repo.env sets no device/toolkit/CUDA_* key" || fail "$(echo "${h}" | first 3)"
}
chk_A5() {
    local h; h="$(nc_grep 'GPU_TUNED_NO_ERR_TRAP' "${OWN[@]}" "${T}/env.sh" "${T}/repo.env")"
    [[ -z "${h}" ]] && pass "GPU_TUNED_NO_ERR_TRAP not set in the repo's scripts" || fail "$(echo "${h}" | first 3)"
}
chk_A6() {
    compgen -G "${T}/common-data/toolkits/*.env" >/dev/null || { unk "no vendored toolkits (see A2)"; return; }
    local f bad=""
    for f in "${T}"/common-data/toolkits/*.env; do grep -qE '^TOOLKIT_NCCL_VERSION=' "${f}" || bad="${bad} ${f##*/}"; done
    [[ -z "${bad}" ]] && pass "every vendored toolkit defines TOOLKIT_NCCL_VERSION" || fail "missing TOOLKIT_NCCL_VERSION:${bad}"
}
chk_A7() {
    local h; h="$(nc_grep '^[[:space:]]*(function[[:space:]]+)?gpu_tuned_[A-Za-z0-9_]+[[:space:]]*(\(\))?[[:space:]]*\{' "${OWN[@]}" "${T}/env.sh")"
    [[ -z "${h}" ]] && pass "no gpu_tuned_* function defined outside the vendored common.sh" || fail "$(echo "${h}" | sort -u | first 3)"
}
chk_B1() {
    local s miss=""
    for s in build full_test package smoke_test release publish; do [[ -f "${T}/${s}.sh" ]] || miss="${miss} ${s}.sh"; done
    [[ -z "${miss}" ]] && pass "the six entry points exist (no-default-toolkit behaviour is B4/A3)" || fail "missing:${miss}"
}
chk_B2() {
    compgen -G "${T}/*wheel*.sh" >/dev/null && pass "wheel script(s): $(cd "${T}" && ls ./*wheel*.sh | tr '\n' ' ')(test/release stage order is read by a person)" \
        || fail "no tuned/*wheel*.sh"
}
chk_B3() {
    [[ -f "${T}/package.sh" && -f "${T}/release.sh" ]] || { unk "package.sh or release.sh missing (see B1)"; return; }
    local p r
    # a command invocation starts the line (after indentation); messages, greps and fail/ok calls do not
    p="$(nc_grep 'gh release|git tag|git push|gpu_tuned_publish_release' "${T}/package.sh" | grep -vE 'echo|die |printf|>&2|refus|grep ')"
    r="$(nc_grep '^[[:space:]]*((bash|source|exec)[[:space:]]+)?[^[:space:]]*(package|build|full_test)\.sh([[:space:]]|$)|^[[:space:]]*(cmake[[:space:]]+--build|ctest)([[:space:]]|$)' "${T}/release.sh")"
    if [[ -n "${p}${r}" ]]; then fail "package.sh publishes: $(echo "${p}" | first 2); release.sh builds/packages: $(echo "${r}" | first 2)"
    else pass "package.sh does not tag/publish; release.sh does not build/test/package (pattern check; stage order still read by a person)"; fi
}
chk_B4() {
    # no toolkit chosen by guessing: the unversioned /usr/local/cuda, a /usr/local/cuda-* scan, "what is installed"
    # helpers, nvcc on PATH as a selector, or a CUDA_TAG/CUDA_VER/CUDA_HOME default naming a literal value
    local h; h="$(nc_grep '/usr/local/cuda([^-0-9]|$)|/usr/local/cuda-(\*|\[)|gpu_tuned_installed_cuda_toolkits|command[[:space:]]+-v[[:space:]]+nvcc|which[[:space:]]+nvcc|\$\{(FAISS_)?CUDA_(TAG|VER|HOME):?[-=][^}$]' "${OWN[@]}" "${T}/env.sh" | grep -vE 'echo|printf|>&2')"
    [[ -z "${h}" ]] && pass "no toolkit guessed or defaulted outside the toolkit data" || fail "$(echo "${h}" | sort -u | first 3)"
}
chk_C5() {
    local h; h="$(nc_grep '\$\(nproc|\$\{?NPROC|nproc\)' "${OWN[@]}" | grep -v gpu_tuned_jobs)"
    [[ -z "${h}" ]] && pass "no bare nproc default" || fail "$(echo "${h}" | wc -l) bare nproc use(s): $(echo "${h}" | first 3)"
}
chk_E2() {
    [[ "${ONLINE}" -eq 1 ]] || { unk "needs gh (rerun with --online)"; return; }
    local slug tags newest total bad
    slug="$(git -C "${REPO}" remote get-url origin 2>/dev/null | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')"
    tags="$(gh release list --repo "${slug}" --limit 200 --json tagName -q '.[].tagName' 2>/dev/null)" \
        || { unk "gh release list failed for ${slug}"; return; }
    [[ -n "${tags}" ]] || { unk "no releases on ${slug}"; return; }
    newest="$(echo "${tags}" | head -1)"; total="$(echo "${tags}" | wc -l)"
    bad="$(while read -r t; do gpu_tuned_check_release_tag "${t}" >/dev/null 2>&1 || echo "${t}"; done <<<"${tags}" | tr '\n' ' ')"
    if ! gpu_tuned_check_release_tag "${newest}" >/dev/null 2>&1; then fail "newest release ${newest} has no date label (older-form tags: ${bad})"
    else pass "newest release ${newest} is a date label (${total} releases; older-form kept per E7: ${bad:-none})"; fi
}
chk_E6() {
    local h; h="$(nc_grep 'rev-list[[:space:]]+--count' "${OWN[@]}")"
    [[ -z "${h}" ]] && pass "no commit count in the repo's scripts" \
                     || unk "commit count used, a person must confirm it is information only: $(echo "${h}" | first 3)"
}
chk_G5() {
    [[ -f "${T}/smoke_test.sh" ]] || { unk "no smoke_test.sh (see B1)"; return; }
    [[ -n "$(nc_grep 'gpu_tuned_verify_resolves_in' "${T}/smoke_test.sh")" ]] && pass "smoke_test.sh calls gpu_tuned_verify_resolves_in" \
        || unk "no gpu_tuned_verify_resolves_in call (a Python repo may prove it by mapped libraries; a person reads it)"
}
chk_H1() {
    [[ -f "${T}/package.sh" ]] || { unk "no package.sh"; return; }
    local miss=""
    [[ -n "$(nc_grep 'package-info.txt' "${T}/package.sh")" ]] || miss="${miss} package-info.txt"
    [[ -n "$(nc_grep '\.sha256|gpu_tuned_write_sha256_sidecar' "${T}/package.sh")" ]] || miss="${miss} sha256-sidecar"
    [[ -z "${miss}" ]] && pass "package.sh writes package-info.txt and a .sha256 (the checks themselves are read by a person)" || fail "package.sh does not mention:${miss}"
}
chk_H7() {
    local h; h="$(nc_grep 'gpu_tuned_embed_build_info_json|gpu_tuned_stamp_lib_json|gpu_tuned_write_build_info_json' "${OWN[@]}")"
    [[ -n "${h}" ]] && pass "$(echo "${h}" | first 2)" || fail "no gpu_tuned_stamp_lib_json / gpu_tuned_embed_build_info_json call (free-text stamp)"
}
chk_I1() {
    [[ -f "${T}/release.sh" ]] || { unk "no release.sh"; return; }
    local miss="" k
    # the common gates (smoke log, package-info, DRAFT, notes committed, only-notes-changed) live in gpu_tuned_release_gates
    if [[ -n "$(nc_grep 'gpu_tuned_release_gates' "${T}/release.sh")" ]]; then
        pass "release.sh runs gpu_tuned_release_gates (smoke log, package-info, DRAFT and the other common gates)"; return
    fi
    for k in 'SMOKE_RESULTS' 'package-info' 'DRAFT'; do [[ -n "$(nc_grep "${k}" "${T}/release.sh")" ]] || miss="${miss} ${k}"; done
    [[ -z "${miss}" ]] && pass "release.sh mentions the smoke log, package-info and the DRAFT gate (dry run is NYI here)" || fail "release.sh does not mention:${miss}"
}
chk_I2() {
    local notes bad=""; notes="$(git -C "${REPO}" ls-files 'tuned/releases/RELEASE_NOTES_0.*.md' | grep -E 'RELEASE_NOTES_0\.[0-9]{8}\.[0-9]+-[a-z0-9]+-cu[0-9]+\.md$' || true)"
    [[ -n "${notes}" ]] || { fail "no tracked RELEASE_NOTES_0.<date>.<seq>-<variant>-<cuda>.md"; return; }
    while read -r n; do grep -q 'DRAFT' "${REPO}/${n}" && bad="${bad} ${n##*/}"; done <<<"${notes}"
    [[ -z "${bad}" ]] && pass "$(echo "${notes}" | wc -l) tracked date-label notes, none DRAFT" || fail "tracked notes still DRAFT:${bad}"
}
chk_I5() {
    [[ -f "${T}/release.sh" && -f "${T}/publish.sh" ]] || { fail "release.sh and publish.sh are both required (release gates, publish publishes)"; return; }
    local r p
    r="$(nc_grep 'gpu_tuned_publish_release|gpu_tuned_publish_ready|gh[[:space:]]+release[[:space:]]+create|git[[:space:]]+(tag|push)' "${T}/release.sh" | grep -vE 'echo|printf|>&2|^[^:]*:[0-9]+:[[:space:]]*#' || true)"
    p="$(nc_grep 'gpu_tuned_publish_ready' "${T}/publish.sh" || true)"
    if [[ -n "${r}" ]]; then fail "release.sh publishes or tags: $(echo "${r}" | first 2)"
    elif [[ -z "${p}" ]]; then fail "publish.sh does not call gpu_tuned_publish_ready"
    else pass "release.sh cannot publish; publish.sh publishes only from the ready-marker (gpu_tuned_publish_ready)"; fi
}
chk_J1() {
    local n; n="$(git -C "${REPO}" log -60 --format=%B -- tuned | grep -ciE '^co-authored-by:' || true)"
    [[ "${n}" -eq 0 ]] && pass "no Co-Authored-By in the last 60 commits touching tuned/" || fail "${n} Co-Authored-By trailer(s) in the last 60 tuned/ commits"
}
chk_J3() {
    local h; h="$(git -C "${REPO}" grep -nE 'zspark-[0-9]+|zbrad-(duo|ven[0-9]*)' -- tuned docs 2>/dev/null || true)"
    [[ -z "${h}" ]] && pass "no real hostnames in tuned/ or docs/" || fail "$(echo "${h}" | wc -l) hit(s): $(echo "${h}" | first 2)"
}

# ---- the requirement register: ID | kinds it applies to (any, native, wheel) ---------------------
REG="A1:any A2:any A3:any A4:any A5:any A6:any A7:any B1:native B2:wheel B3:native B4:any
C1:any C2:native C3:native C4:native C5:any C6:native C7:native D1:native D2:native D3:native
E1:wheel E2:native E3:any E4:any E5:any E6:any E7:any E8:any F1:native F2:native F3:native F4:wheel
G1:any G2:any G3:any G4:any G5:native G6:native H1:native H2:native H3:native H4:any H5:native H6:native H7:any H8:native
I1:native I2:native I3:native I4:native I5:native J1:any J2:any J3:any J4:any"

applies() {  # applies <kind-needed>
    case "$1" in any) [[ -n "${KINDS}" ]] ;; *) has_kind "$1" ;; esac
}

for entry in ${REG}; do
    id="${entry%%:*}"; need="${entry##*:}"; CUR="${id}"; ORDER+=("${id}")
    if [[ -n "${NAV[${id}]:-}" ]]; then emit N/A "declared: ${NAV[${id}]}"; continue; fi
    if ! applies "${need}"; then emit N/A "repo ships kinds: ${KINDS:-none}; ${id} applies to ${need}"; continue; fi
    if declare -F "chk_${id}" >/dev/null; then "chk_${id}"
    else unk "no mechanical check; a person reads it and attests (compliance.conf)"; fi
    # overrides: a recorded exception stands in for a FAIL; a valid attestation stands in for UNKNOWN
    if [[ ( "${STATUS[${id}]}" == FAIL || "${STATUS[${id}]}" == UNKNOWN ) && -n "${EXC[${id}]:-}" ]]; then
        emit EXCEPTION "${EXC[${id}]} -- was: ${EVID[${id}]}"
    elif [[ "${STATUS[${id}]}" == UNKNOWN && -n "${ATT[${id}]:-}" ]]; then
        a="${ATT[${id}]}"; c="${a##*|}"
        if attest_valid "${c}"; then emit ATTESTED "${a%|*}, commit ${c:0:9}"
        else emit UNKNOWN "attestation commit ${c:0:9} is stale or not an ancestor; tuned/ changed since -- read it again"; fi
    fi
done
for e in "${CONF_ERRORS[@]}"; do CUR="CONF"; ORDER+=("CONF"); emit FAIL "compliance.conf: ${e}"; done

# ---- report ------------------------------------------------------------------------------------
echo "tuned compliance: $(git -C "${REPO}" remote get-url origin 2>/dev/null || echo "${REPO}")"
echo "  date          $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  repo commit   $(git -C "${REPO}" rev-parse --short=12 HEAD)$(git -C "${REPO}" diff --quiet HEAD -- tuned || echo ' (tuned/ has uncommitted changes)')"
echo "  tuned-common  $(git -C "${TC_DIR}" rev-parse --short=12 HEAD) tool, ${TC_REF} ${TC_REF_SHA:0:12} reference"
echo "  kinds         ${KINDS:-none}   mode: $([[ ${ONLINE} -eq 1 ]] && echo online || echo offline)"
echo
declare -A COUNT=()
for id in "${ORDER[@]}"; do
    s="${STATUS[${id}]}"; COUNT["${s}"]=$(( ${COUNT[${s}]:-0} + 1 ))
    printf '%-5s %-9s %s\n' "${id}" "${s}" "${EVID[${id}]}"
done
echo
printf 'PASS %d  FAIL %d  EXCEPTION %d  ATTESTED %d  UNKNOWN %d  N/A %d\n' \
    "${COUNT[PASS]:-0}" "${COUNT[FAIL]:-0}" "${COUNT[EXCEPTION]:-0}" "${COUNT[ATTESTED]:-0}" "${COUNT[UNKNOWN]:-0}" "${COUNT[N/A]:-0}"
if   [[ "${COUNT[FAIL]:-0}" -gt 0 ]]; then exit 1
elif [[ "${COUNT[UNKNOWN]:-0}" -gt 0 ]]; then exit 2
fi
exit 0
