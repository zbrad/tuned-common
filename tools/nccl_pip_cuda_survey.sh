#!/bin/bash
# tools/nccl_pip_cuda_survey.sh <python> <work-dir> <version>... -- for each nvidia-nccl-cu13 release, download the wheel
# for this platform, read the "NCCL version X+cudaY" string out of libnccl.so.2, print one line, delete the wheel.
# Needs the network; each wheel is about 300 MB. <python> is any interpreter with pip. Output: "<version> <wheel> <string>".
set -uo pipefail
PY="${1:?usage: nccl_pip_cuda_survey.sh <python> <work-dir> <version>...}" D="${2:?}"
shift 2
mkdir -p "${D}"
for v in "$@"; do
    "${PY}" -m pip download --no-deps --quiet --disable-pip-version-check --dest "${D}" "nvidia-nccl-cu13==${v}" > /dev/null 2>&1 \
        || { echo "${v} download-failed"; continue; }
    w="$(ls "${D}"/nvidia_nccl_cu13-"${v}"-*.whl | head -1)"
    s="$("${PY}" -I - "${w}" <<'PYEOF'
import re, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
name = [n for n in z.namelist() if n.endswith("libnccl.so.2")][0]
m = re.search(rb"NCCL version [0-9.]+\+cuda[0-9.]+", z.read(name))
print(m.group(0).decode() if m else "no-version-string")
PYEOF
)"
    echo "${v} $(basename "${w}") ${s}"
    rm -f "${w}"
done
