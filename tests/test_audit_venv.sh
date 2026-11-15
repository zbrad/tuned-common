#!/bin/bash
# Tests for gpu_tuned_audit_venv (H14) on throwaway venvs. NEEDS THE NETWORK: it installs packages and pip-audit from PyPI
# and queries PyPI's advisory data, so it is not part of any offline run.
# Jinja2==3.1.4 has known advisories fixed in 3.1.5 / 3.1.6; 3.1.6 is the clean case.
# Usage: bash tests/test_audit_venv.sh   (exit 0 = all pass)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tuned-common.sh
GPU_TUNED_NO_ERR_TRAP=1 source "${HERE}/../tuned-common.sh"
PASS=0; FAIL=0
W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT
: > "${W}/empty.txt"

mkvenv() { # mkvenv <dir> <pip-args...>
    local d="$1"; shift
    python3 -m venv "${d}" && "${d}/bin/python" -m pip install --quiet --disable-pip-version-check "$@" \
        || { echo "cannot build the test venv ${d} (network?)" >&2; exit 1; }
}
check() { # check <name> <venv> <want-rc> <log-regex> <allow-file>
    local name="$1" venv="$2" want="$3" re="$4" allow="$5" rc out
    out="$(GPU_TUNED_AUDIT_ALLOW_FILE="${allow}" gpu_tuned_audit_venv "${venv}" "${W}/log.txt" 2>&1)"; rc=$?
    [[ "${rc}" -eq "${want}" ]] && grep -qE "${re}" <<< "${out}" && grep -qE "${re}" "${W}/log.txt" \
        && { PASS=$((PASS + 1)); echo "ok:   ${name}"; } \
        || { FAIL=$((FAIL + 1)); echo "FAIL: ${name} (rc=${rc}, wanted ${want}, pattern ${re})"; sed 's/^/        /' <<< "${out}" | head -20; }
}

mkvenv "${W}/vuln" "Jinja2==3.1.4"
check "a vulnerable package with a fix available fails" "${W}/vuln" 1 'VIOLATION: jinja2==3.1.4 .* fixed in: 3\.1\.[56]' "${W}/empty.txt"
check "pip and setuptools are in the audit (freeze --all)" "${W}/vuln" 1 'audited [0-9]+ packages: .*pip==' "${W}/empty.txt"

IDS="$(GPU_TUNED_AUDIT_ALLOW_FILE="${W}/empty.txt" gpu_tuned_audit_venv "${W}/vuln" "${W}/log.txt" 2>&1 | sed -n 's/^VIOLATION: \(\S*\) \(\S*\) .*/\2/p' | sort -u)"
[[ -n "${IDS}" ]] || { echo "FAIL: no advisory ids to build the allow file from" >&2; exit 1; }
sed 's/$/  accepted by the test/' <<< "${IDS}" > "${W}/allow.txt"
check "every advisory accepted with a reason passes" "${W}/vuln" 0 'ACCEPTED: jinja2==3.1.4 .*accepted by the test' "${W}/allow.txt"

mkvenv "${W}/clean" "Jinja2==3.1.6" "pip>=25.3" "setuptools>=84.2"
check "a venv with no fixable advisory passes" "${W}/clean" 0 '^RESULT: no vulnerable package has a fix available$' "${W}/empty.txt"

# A local version (like torch 2.11.0+cpu) is audited as its base version, with a note.
mkdir -p "${W}/lsrc/markupsafe-2.1.5+local/markupsafe-2.1.5+local.dist-info" "${W}/lout"
printf 'Metadata-Version: 2.1\nName: MarkupSafe\nVersion: 2.1.5+local\n' > "${W}/lsrc/markupsafe-2.1.5+local/markupsafe-2.1.5+local.dist-info/METADATA"
printf 'Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n' > "${W}/lsrc/markupsafe-2.1.5+local/markupsafe-2.1.5+local.dist-info/WHEEL"
"${W}/clean/bin/python" -m pip install --quiet --disable-pip-version-check wheel \
    && "${W}/clean/bin/python" -m wheel pack "${W}/lsrc/markupsafe-2.1.5+local" --dest-dir "${W}/lout" > /dev/null \
    && "${W}/clean/bin/python" -m pip install --quiet --disable-pip-version-check --no-deps --force-reinstall "${W}/lout/"*.whl \
    || { echo "cannot build the local-version wheel" >&2; exit 1; }
check "a local-version wheel installed from a file is audited as its base version, with a note" "${W}/clean" 0 'audited as MarkupSafe==2\.1\.5 \(installed from markupsafe-2\.1\.5\+local-py3-none-any\.whl\)' "${W}/empty.txt"

mkdir -p "${W}/notvenv"
check "a directory that is not a venv fails" "${W}/notvenv" 1 'not a venv' "${W}/empty.txt"

echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
