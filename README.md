# tuned-common

Shared build-tooling functions for the zbrad GB10/RTX40/RTX50 "tuned-builds"
fleet: `pytorch`, `llama.cpp`, `flash-attention`, `flashinfer`, `raft`,
`cuvs`, `faiss`, and downstream consumers that install a tuned torch wheel
into their own venv (`vllm`, `ComfyUI`, `open-webui`, ...).

## Usage

Vendor a pinned copy into your repo (don't fetch at build time — keeps
builds reproducible/offline-capable). Two files land together, both
tracked in git:

- `tuned/common.sh` (or a repo-root `tuned-common.sh` for repos with no
  `tuned/` dir, e.g. ComfyUI/vllm) — the library itself.
- `tuned/sync-common.sh` (same rule for placement) — copy of this repo's
  own `sync-common.sh`, used to check/refresh the sibling `common.sh`
  later. Vendored too rather than fetched fresh each time, so checking is
  itself offline-capable/reproducible.

First-time setup:

```bash
curl -fsSL -o tuned/common.sh \
  https://raw.githubusercontent.com/zbrad/tuned-common/<commit-or-tag>/tuned-common.sh
curl -fsSL -o tuned/sync-common.sh \
  https://raw.githubusercontent.com/zbrad/tuned-common/<commit-or-tag>/sync-common.sh
chmod +x tuned/sync-common.sh
echo "<commit-sha>" > tuned/common.sh.sha
```

Then source `common.sh` from your own `tuned/env.sh`, after setting your
repo-specific device/arch env vars:

```bash
source "${GPU_TUNED_SELF_DIR}/common.sh"
```

## Version style and loud failures

See `docs/VERSIONING.md` for the wheel version-label rule (current date form:
`gpu_tuned_local_version_dated`, `gpu_tuned_date_label`; previous counter form:
`gpu_tuned_local_version`, `gpu_tuned_tuning_label`, still accepted) and the research behind it. Sourcing `tuned-common.sh` also installs
an `ERR` trap so aborts under `set -e` are never silent (opt out: `GPU_TUNED_NO_ERR_TRAP=1`).
Run `bash tests/test_common.sh` before changing the library.
`tools/wheel_version_audit.py` audits published wheels against the rule (tests:
`python3 -m pytest tests/test_wheel_version_audit.py`); latest report: `docs/VERSION_AUDIT_2026-09-18.md`.

## Keeping a vendored copy in sync

```bash
tuned/sync-common.sh check        # exit 1 + a message if stale, no changes made
tuned/sync-common.sh sync         # fetch main's current HEAD, update common.sh + the .sha marker if changed
tuned/sync-common.sh sync <ref>   # pin to a specific commit/tag instead of main
```

`sync` refuses to apply an update that fails a `bash -n` syntax check,
leaving the existing vendored copy untouched. It always prints a diff
before overwriting.

## Functions

- `gpu_tuned_installed_cuda_toolkits` — list installed `/usr/local/cuda-<ver>` toolkits
- `gpu_tuned_resolve_cuda_home` — set `CUDA_HOME`/`PATH`/`CUDA_VERSION_COMPACT`
- `gpu_tuned_assert_platform <expected-uname-m> <label>` — fail loudly on a CPU-arch mismatch
- `gpu_tuned_assert_compute_cap <expected-cc> <label>` — fail loudly on a GPU mismatch (via `nvidia-smi`)
- `gpu_tuned_verify_arch <so> <expected-arch>` — confirm a `.so` embeds exactly one matching cubin arch
- `gpu_tuned_verify_cuda_compat <so> <expected-cuda-ver>` — confirm CUDA runtime major-version compat
- `gpu_tuned_embed_build_info <target> <variant> <package> <version> [hw-label] [repo-url]` — stamp a greppable build-info ELF section
- `gpu_tuned_protect_torch_pin <venv-dir> <exact-torch-version>` — guard a venv's tuned torch against being silently swapped by a companion package's exact pin

- `gpu_tuned_load_toolkit <data-dir> <variant> <toolkit-id>` — select a CUDA toolkit from `toolkits/<id>.env` (+ optional `<variant>-<id>.env`); exports `CUDA_VER`/`CUDA_TAG`/`CUDA_HOME`/`GPU_TUNED_TOOLKIT_LIB_DIR`. With no id it uses the highest *defined* toolkit (by declared CUDA version) and prints the full list and why; it never consults `/usr/local/cuda` or what is installed
- `gpu_tuned_verify_toolkit` — confirm the install matches its definition (nvcc release, libnccl2 package version)
- `gpu_tuned_verify_toolkit_libs <elf>...` — confirm cudart/cublas/cublasLt resolve under `CUDA_HOME` when run with the toolkit's own lib dir on `LD_LIBRARY_PATH`

- `gpu_tuned_load_repo_env <file>` — source a repo's `tuned/repo.env` (CMake flags, paths, extra packages) and fail loudly, listing every key, if it changes, sets or unsets anything the shared device/toolkit files decided

See `tuned-common.sh` itself for full doc comments on each.

## Devices and toolkits (shared data)

- `devices/<variant>.conf` — hardware facts every consumer agrees on (`GPU_TUNED_VARIANT`,
  `GPU_TUNED_PLATFORM`, `GPU_TUNED_CUDA_ARCH`) and the canonical `GPU_TUNED_HW_LABEL` used in
  release titles. Used as is: there are no per-repo local override files. Keys that only one
  repo needs (BLAS paths, AOT flags, wheel URLs) are not part of this file.
- `toolkits/<id>.env` — one file per CUDA toolkit (`cu133`), the toolkit-versioned
  `CUDA_HOME` (never the unversioned `/usr/local/cuda` symlink), the `nvcc` release and the
  library versions the toolkit is built against. `toolkits/<variant>-<id>.env` overrides
  keys where the stack differs per variant. Record only values read from a real install.

Each repo adds its own settings in `tuned/repo.env`, loaded last by `gpu_tuned_load_repo_env`.
It is tracked (a release must be reproducible) and may only add repo-specific keys: any attempt
to change the hardware, toolkit or `CUDA_*` values the shared files set is a loud, all-at-once error.

A consumer vendors these by creating `tuned/common-data/` and running `tuned/sync-common.sh sync`;
without that directory the sync only touches `common.sh`. The sync overwrites files from
upstream, reports local files upstream lacks, and never deletes anything.

`gpu_tuned_verify_toolkit_libs` pins a test run, not a deployed machine: the runtime libs are
deliberately not bundled, so a target resolves them by its own loader configuration. On a host
whose `/usr/local/cuda` symlink follows the newest toolkit, `ld.so.conf` entries can satisfy the
lookup from the wrong version, which is why the check puts the toolkit's lib dir first.
