# tuned-common

Shared build-tooling functions for the zbrad GB10/RTX40/RTX50 "tuned-builds"
fleet: `pytorch`, `llama.cpp`, `flash-attention`, `flashinfer`, `raft`,
`cuvs`, `faiss`, and downstream consumers that install a tuned torch wheel
into their own venv (`vllm`, `ComfyUI`, `open-webui`, ...).

## Usage

Vendor a pinned copy into your repo (don't fetch at build time — keeps
builds reproducible/offline-capable):

```bash
curl -fsSL -o tuned/common.sh \
  https://raw.githubusercontent.com/zbrad/tuned-common/<commit-or-tag>/tuned-common.sh
```

Then source it from your own `tuned/env.sh`, after setting your
repo-specific device/arch env vars:

```bash
source "${GPU_TUNED_SELF_DIR}/common.sh"
```

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
