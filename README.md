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

See `docs/VERSIONING.md` for the wheel version-label rule (`gpu_tuned_local_version`,
`gpu_tuned_tuning_label`) and the research behind it. Sourcing `tuned-common.sh` also installs
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

See `tuned-common.sh` itself for full doc comments on each.
