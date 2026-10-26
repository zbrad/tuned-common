#!/bin/bash
# Tests for gpu_tuned_audit_deps (tuned-common.sh (gpu_tuned_audit_deps)) on throwaway wheels. NEEDS THE NETWORK: it installs
# pip-audit from PyPI and queries PyPI's advisory data, so it is not part of any offline run.
# The fake wheel pins Jinja2==3.1.4, which has known advisories fixed in 3.1.5 / 3.1.6.
# Usage: bash tests/test_audit_deps.sh   (exit 0 = all pass)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tuned-common.sh
GPU_TUNED_NO_ERR_TRAP=1 source "${HERE}/../tuned-common.sh"
PASS=0; FAIL=0
W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT

mkdir -p "${W}/src/fake-1.0/fake-1.0.dist-info" "${W}/out"
printf 'Metadata-Version: 2.1\nName: fake\nVersion: 1.0\nRequires-Dist: Jinja2==3.1.4\n' > "${W}/src/fake-1.0/fake-1.0.dist-info/METADATA"
printf 'Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n' > "${W}/src/fake-1.0/fake-1.0.dist-info/WHEEL"
python3 -m venv "${W}/packer" && "${W}/packer/bin/python" -m pip install --quiet --disable-pip-version-check wheel \
    && "${W}/packer/bin/python" -m wheel pack "${W}/src/fake-1.0" --dest-dir "${W}/out" > /dev/null \
    || { echo "cannot build the fake wheel (network?)" >&2; exit 1; }
WHEEL="${W}/out/fake-1.0-py3-none-any.whl"

check() { # check <name> <want-rc> <log-regex> <allow-file or ->
    local name="$1" want="$2" re="$3" allow="$4" rc out
    out="$(GPU_TUNED_AUDIT_ALLOW_FILE="${allow}" gpu_tuned_audit_deps "${WHEEL}" "${W}/log.txt" 2>&1)"; rc=$?
    [[ "${rc}" -eq "${want}" ]] && grep -qE "${re}" <<< "${out}" \
        && { PASS=$((PASS + 1)); echo "ok:   ${name}"; } \
        || { FAIL=$((FAIL + 1)); echo "FAIL: ${name} (rc=${rc}, wanted ${want}, pattern ${re})"; sed 's/^/        /' <<< "${out}" | head -20; }
}

: > "${W}/empty.txt"
check "vulnerable pin with a fix available fails" 1 'VIOLATION: jinja2==3.1.4 .* fixed in: 3\.1\.[56]' "${W}/empty.txt"

IDS="$(GPU_TUNED_AUDIT_ALLOW_FILE="${W}/empty.txt" gpu_tuned_audit_deps "${WHEEL}" "${W}/log.txt" 2>&1 | sed -n 's/^VIOLATION: jinja2==3.1.4 \(\S*\) .*/\1/p' | sort -u)"
[[ -n "${IDS}" ]] || { echo "FAIL: no advisory ids to build the allow file from" >&2; exit 1; }
sed 's/$/  accepted by the test/' <<< "${IDS}" > "${W}/allow.txt"
check "every advisory accepted with a reason passes" 0 'ACCEPTED: jinja2==3.1.4 .*accepted by the test' "${W}/allow.txt"

sed 's/  accepted by the test$//' "${W}/allow.txt" > "${W}/noreason.txt"
check "an allow line without a reason fails" 1 "has no reason" "${W}/noreason.txt"

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
