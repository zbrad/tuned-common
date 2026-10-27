#!/bin/bash
# Tests for gpu_tuned_setup_build_venv and gpu_tuned_check_venv_setuptools (tuned-common.sh) on throwaway venvs.
# NEEDS THE NETWORK (PyPI). Usage: bash tests/test_build_venv.sh   (exit 0 = all pass)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tuned-common.sh
GPU_TUNED_NO_ERR_TRAP=1 source "${HERE}/../tuned-common.sh"
PASS=0; FAIL=0
W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT

ok() { PASS=$((PASS + 1)); echo "ok:   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [[ -z "${2:-}" ]] || sed 's/^/        /' <<< "$2" | head -8; }
ver() { "$1/bin/python" -c 'import setuptools; print(setuptools.__version__)' 2>/dev/null; }
# in_subshell <cmd...>: run in a subshell so the venv activation does not leak into the next case.
in_subshell() { ( "$@" ) 2>&1; }

# 1. a fresh venv comes out activated, with setuptools at the minimum
V1="${W}/fresh"; mkdir -p "${W}/repo1"
out="$(in_subshell bash -c 'GPU_TUNED_NO_ERR_TRAP=1 source "$1"; gpu_tuned_setup_build_venv "$2" "$3" && which python3 && echo "VIRTUAL_ENV=${VIRTUAL_ENV}"' _ "${HERE}/../tuned-common.sh" "${V1}" "${W}/repo1")"; rc=$?
[[ ${rc} -eq 0 && "${out}" == *"${V1}/bin/python3"* && "${out}" == *"VIRTUAL_ENV=${V1}"* ]] && ok "a fresh venv is created and activated" || bad "fresh venv (rc=${rc})" "${out}"
printf '%s\n%s\n' "${GPU_TUNED_SETUPTOOLS_MIN}" "$(ver "${V1}")" | sort -V -C && ok "the fresh venv has setuptools $(ver "${V1}") (minimum ${GPU_TUNED_SETUPTOOLS_MIN})" || bad "fresh venv setuptools is $(ver "${V1}")"

# 2. a reused venv with an old setuptools is upgraded
"${V1}/bin/python" -m pip install --quiet --disable-pip-version-check "setuptools==80.10.2" || { echo "cannot downgrade the test venv" >&2; exit 1; }
out="$(gpu_tuned_check_venv_setuptools "${V1}" 2>&1)"; rc=$?
[[ ${rc} -ne 0 && "${out}" == *"older than the minimum"* ]] && ok "the package gate fails a venv with setuptools 80.10.2" || bad "gate on old setuptools (rc=${rc})" "${out}"
out="$(in_subshell bash -c 'GPU_TUNED_NO_ERR_TRAP=1 source "$1"; gpu_tuned_setup_build_venv "$2" "$3"' _ "${HERE}/../tuned-common.sh" "${V1}" "${W}/repo1")"; rc=$?
[[ ${rc} -eq 0 && "$(ver "${V1}")" != "80.10.2" ]] && ok "a reused venv is upgraded past 80.10.2 (now $(ver "${V1}"))" || bad "reused venv upgrade (rc=${rc})" "${out}"
out="$(gpu_tuned_check_venv_setuptools "${V1}" 2>&1)"; rc=$?
[[ ${rc} -eq 0 && "${out}" == "build venv setuptools "* ]] && ok "the package gate passes after the upgrade" || bad "gate after upgrade (rc=${rc})" "${out}"

# 3. the gate fails when there is no venv, and when setuptools is missing
out="$(gpu_tuned_check_venv_setuptools "${W}/none" 2>&1)"; rc=$?
[[ ${rc} -ne 0 && "${out}" == *"no build venv python"* ]] && ok "the package gate fails when there is no venv" || bad "gate with no venv (rc=${rc})" "${out}"
python3 -m venv --without-pip "${W}/nopip"
out="$(gpu_tuned_check_venv_setuptools "${W}/nopip" 2>&1)"; rc=$?
[[ ${rc} -ne 0 && "${out}" == *"no importable setuptools"* ]] && ok "the package gate fails a venv without setuptools" || bad "gate with no setuptools (rc=${rc})" "${out}"

# 4. GPU_TUNED_CLEAN_VENV=1 removes a marker file in the venv
touch "${V1}/MARKER"
out="$(in_subshell bash -c 'GPU_TUNED_NO_ERR_TRAP=1 source "$1"; GPU_TUNED_CLEAN_VENV=1 gpu_tuned_setup_build_venv "$2" "$3"' _ "${HERE}/../tuned-common.sh" "${V1}" "${W}/repo1")"; rc=$?
[[ ${rc} -eq 0 && ! -e "${V1}/MARKER" && "${out}" == *"removing ${V1}"* ]] && ok "GPU_TUNED_CLEAN_VENV=1 rebuilds the venv" || bad "clean venv (rc=${rc})" "${out}"

# 5. a venv copied from another path is refused (pip's shebang points elsewhere)
cp -a "${V1}" "${W}/copied" 2>/dev/null
out="$(in_subshell bash -c 'GPU_TUNED_NO_ERR_TRAP=1 source "$1"; gpu_tuned_setup_build_venv "$2" "$3"' _ "${HERE}/../tuned-common.sh" "${W}/copied" "${W}/repo1")"; rc=$?
[[ ${rc} -ne 0 ]] && ok "a venv copied from another path is refused" || bad "copied venv accepted" "${out}"

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
