# NCCL and the CUDA 13.x toolkits

Surveyed 2026-10-28 on an aarch64 (GB10) Linux host with CUDA toolkits 13.0 to 13.4 installed under `/usr/local`.

## The toolkits do not ship NCCL

None of the toolkit trees (`/usr/local/cuda-13.0` ... `13.4`) contains any file with `nccl` in its name (`find <tree> -iname '*nccl*'`, empty
for all five). NCCL always arrives separately, from one of three places:

| Source | Version | Built for CUDA | How it was read |
|---|---|---|---|
| NVIDIA apt packages `libnccl2` / `libnccl-dev` | 2.31.2 | 13.3 | dpkg version `2.31.2-1+cuda13.3`; the string in `libnccl.so.2.31.2` agrees |
| `nvidia-nccl-cu13` pip wheels (table below) | 2.27.7 to 2.32.3 | 13.0 to 13.4 | string inside each wheel's `libnccl.so.2` |
| A pinned release of our own (`zbrad/nccl`, e.g. `v0.20261012.0-gb10-cu134`) | see that release | its own toolkit | its `BUILD_INFO` |

The tuned builds use only the third: `gpu_tuned` fails a build that finds a system NCCL ("no system NCCL, a pinned zbrad/nccl release is the only NCCL").
The raft and cuvs Python wheels are the exception: `raft-dask` links the `nvidia-nccl-cu13` wheel (`USE_NCCL_RUNTIME_WHEEL=ON`).

## `nvidia-nccl-cu13` releases (aarch64)

The CUDA version is the `+cudaY` in the `NCCL version X+cudaY` string compiled into `libnccl.so.2`. The wheel metadata says nothing about it
(`Requires-Python: >=3` and no `Requires-Dist`), so a pip requirement on this package cannot select a CUDA minor.

| NCCL | Built for CUDA |
|---|---|
| 2.32.3 | 13.4 |
| 2.31.2 | 13.3 |
| 2.30.7 | 13.3 |
| 2.30.4 | 13.2 |
| 2.30.3 | 13.2 |
| 2.29.7 | 13.2 |
| 2.29.3 | 13.1 |
| 2.29.2 | 13.1 |
| 2.28.9 | 13.0 |
| 2.28.7 | 13.0 |
| 2.28.3 | 13.0 |
| 2.27.7 | 13.0 |

So 2.32.3 is the only release built for 13.4 as of this survey; every earlier release was built for an older minor.

## What this means for our wheels

- `libnccl.so.2` itself lists no CUDA libraries as needed (CUDA runtime is linked statically), so the CUDA minor shows only in this string.
- `raft-dask` currently requires `nvidia-nccl-cu13>=2.19`, which admits every row above. A wheel built against 2.32.3 (CUDA 13.4) and a
  single-architecture sm_121a build therefore does not stop pip choosing an NCCL built for 13.0. To require 13.4, the pin has to be
  `nvidia-nccl-cu13>=2.32.3`, taken from the NCCL in the build venv.
- Not established here: whether an NCCL built for an older CUDA minor actually fails with a 13.4 caller. The survey reads build strings; it does not run NCCL.

## Reproduce

    tools/nccl_pip_cuda_survey.sh <python-with-pip> <scratch-dir> 2.32.3 2.31.2 2.30.7 2.30.4 2.30.3 2.29.7 2.29.3 2.29.2 2.28.9 2.28.7 2.28.3 2.27.7

Version list from `pip index versions nvidia-nccl-cu13`; apt row from `dpkg -l | grep nccl`. Results depend on the platform tag (aarch64 here); an x86_64 host may show different build strings.
