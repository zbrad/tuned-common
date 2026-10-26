#!/bin/bash
# Tests for gpu_tuned_install_setuptools (tuned-common.sh) in a throwaway venv. NEEDS THE NETWORK (PyPI).
# The venv starts with setuptools 80.10.2, the version vllm's <81 cap used to leave in its build venv.
# Usage: bash tests/test_setuptools.sh   (exit 0 = all pass)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tuned-common.sh
GPU_TUNED_NO_ERR_TRAP=1 source "${HERE}/../tuned-common.sh"
PASS=0; FAIL=0
W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT

python3 -m venv "${W}/venv" && "${W}/venv/bin/python" -m pip install --quiet --disable-pip-version-check "setuptools==80.10.2" \
    || { echo "cannot build the test venv (network?)" >&2; exit 1; }

ver() { PATH="${W}/venv/bin:${PATH}" python3 -c 'import setuptools; print(setuptools.__version__)'; }

check() { # check <name> <want-rc> <output-regex> <min>
    local name="$1" want="$2" re="$3" min="$4" rc out
    out="$(PATH="${W}/venv/bin:${PATH}" GPU_TUNED_SETUPTOOLS_MIN="${min}" gpu_tuned_install_setuptools 2>&1)"; rc=$?
    [[ "${rc}" -eq "${want}" ]] && grep -qE "${re}" <<< "${out}" \
        && { PASS=$((PASS + 1)); echo "ok:   ${name}"; } \
        || { FAIL=$((FAIL + 1)); echo "FAIL: ${name} (rc=${rc}, wanted ${want}, pattern ${re})"; sed 's/^/        /' <<< "${out}" | head -8; }
}

[[ "$(ver)" == "80.10.2" ]] || { echo "FAIL: test venv does not start at 80.10.2 ($(ver))"; exit 1; }
check "an old setuptools is upgraded to the current release" 0 'setuptools [0-9.]+ \(current release; minimum 84\.2\)' "84.2"
[[ "$(ver)" != "80.10.2" ]] && { PASS=$((PASS + 1)); echo "ok:   the venv no longer has 80.10.2 ($(ver))"; } || { FAIL=$((FAIL + 1)); echo "FAIL: venv still at 80.10.2"; }
check "a minimum above any release fails" 1 'could not install setuptools>=9999' "9999"

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
