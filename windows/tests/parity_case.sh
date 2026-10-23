#!/usr/bin/env bash
# Runs one tuned-common.sh function for test_parity.ps1: parity_case.sh <function> <args-file>
# The arguments come one per line from <args-file> (UTF-8, LF), so quotes, backslashes and
# non-ASCII text arrive intact instead of being re-parsed by wsl.exe. gpu_tuned_next_seq takes
# its date as the first line and the taken labels (its stdin) as the rest.
set -uo pipefail
export GPU_TUNED_NO_ERR_TRAP=1
# a scratch repo made by Windows is owned by another user as far as WSL's git can tell
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${here}/../../tuned-common.sh"
fn="$1"
mapfile -t args < "$2"
if [ "${fn}" = gpu_tuned_next_seq ]; then
    printf '%s\n' "${args[@]:1}" | gpu_tuned_next_seq "${args[0]}"
else
    "${fn}" "${args[@]+"${args[@]}"}"
fi
