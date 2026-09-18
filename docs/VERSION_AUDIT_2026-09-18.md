# Wheel version audit, 2026-09-18

Audit of every wheel published under the `zbrad` and `ZBrad-LLC` GitHub accounts
against the rule in [VERSIONING.md](VERSIONING.md). Run with
`python3 tools/wheel_version_audit.py --markdown` (queries GitHub; ~35 s), or
`--input <tsv>` to re-check a saved list. 83 repos scanned; 33 wheels in 8 repos
(faiss, flash-attention under both accounts, flash-attention-vllm, flashinfer,
pytorch, raft, vllm).

## Result

No published wheel is in the current `tuning.N` form yet: the rule was adopted
after these were built, and the next build of each wheel repo will be the first.

| class | wheels | meaning |
|---|---|---|
| `legacy-v` | 12 | legacy tuning.vN (fused counter; kept, not renamed) |
| `no-local` | 2 | no local version label |
| `platform-only` | 4 | platform tag only, e.g. +cu133 (upstream style) |
| `pre-marker` | 15 | tuned variant but no tuning counter |

| repo | tag | published | wheel | class |
|---|---|---|---|---|
| ZBrad-LLC/flash-attention | `v2.8.4-gb10-cu133` | 2026-09-08 | `flash_attn-2.8.4+gb10.cu133-cp314-cp314-linux_aarch64.whl` | pre-marker |
| ZBrad-LLC/flash-attention | `v2.8.4+gb10.cu133.tuning.v21` | 2026-09-16 | `flash_attn-2.8.4+gb10.cu133.tuning.v21-cp314-cp314-linux_aarch64.whl` | legacy-v |
| ZBrad-LLC/flash-attention | `v2.8.4+gb10.cu134.tuning.v44` | 2026-09-18 | `flash_attn-2.8.4+gb10.cu134.tuning.v44-cp314-cp314-linux_aarch64.whl` | legacy-v |
| zbrad/faiss | `v0.1.0-cuda132` | 2026-03-25 | `faiss-1.14.1-py3-none-manylinux_2_39_x86_64.whl` | no-local |
| zbrad/faiss | `v1.14.1-gpu-cu132` | 2026-03-26 | `faiss_gpu_cu132-1.14.1-py3-none-any.whl` | no-local |
| zbrad/flash-attention | `v2.8.4-gb10-cu133` | 2026-09-08 | `flash_attn-2.8.4+gb10.cu133-cp314-cp314-linux_aarch64.whl` | pre-marker |
| zbrad/flash-attention-vllm | `v2.7.2.post1-gb10-cu133` | 2026-08-07 | `vllm_flash_attn-2.7.2.post1+gb10.cu133-cp314-cp314-linux_aarch64.whl` | pre-marker |
| zbrad/flash-attention-vllm | `v2.7.2.post1+gb10.cu133.tuning.v39` | 2026-09-11 | `vllm_flash_attn-2.7.2.post1+gb10.cu133.tuning.v39-cp314-cp314-linux_aarch64.whl` | legacy-v |
| zbrad/flash-attention-vllm | `v2.7.2.post1+gb10.cu133.tuning.v47` | 2026-09-12 | `vllm_flash_attn-2.7.2.post1+gb10.cu133.tuning.v47-cp314-cp314-linux_aarch64.whl` | legacy-v |
| zbrad/flash-attention-vllm | `v2.7.2.post1+gb10.cu134.tuning.v50` | 2026-09-18 | `vllm_flash_attn-2.7.2.post1+gb10.cu134.tuning.v50-cp314-cp314-linux_aarch64.whl` | legacy-v |
| zbrad/flashinfer | `v0.6.13-gb10` | 2026-07-06 | `flashinfer_jit_cache-0.6.13+gb10-cp39-abi3-manylinux_2_28_aarch64.whl` | pre-marker |
| zbrad/flashinfer | `v0.6.13-gb10` | 2026-07-06 | `flashinfer_python-0.6.13+gb10-py3-none-any.whl` | pre-marker |
| zbrad/flashinfer | `v0.6-gb10-cu133` | 2026-08-07 | `flashinfer_jit_cache-0.6.13+gb10-cp39-abi3-manylinux_2_28_aarch64.whl` | pre-marker |
| zbrad/flashinfer | `v0.6-gb10-cu133` | 2026-08-07 | `flashinfer_python-0.6.13+gb10-py3-none-any.whl` | pre-marker |
| zbrad/flashinfer | `v0.7-gb10-cu133` | 2026-09-11 | `flashinfer_jit_cache-0.7.0+gb10-cp39-abi3-manylinux_2_28_aarch64.whl` | pre-marker |
| zbrad/flashinfer | `v0.7-gb10-cu133` | 2026-09-11 | `flashinfer_python-0.7.0+gb10-py3-none-any.whl` | pre-marker |
| zbrad/flashinfer | `v0.7.0+gb10.cu133.tuning.v28` | 2026-09-12 | `flashinfer_jit_cache-0.7.0+gb10.cu133.tuning.v28-cp39-abi3-manylinux_2_28_aarch64.whl` | legacy-v |
| zbrad/flashinfer | `v0.7.0+gb10.cu133.tuning.v28` | 2026-09-12 | `flashinfer_python-0.7.0+gb10.cu133.tuning.v28-py3-none-any.whl` | legacy-v |
| zbrad/flashinfer | `v0.7.0+gb10.cu134.tuning.v149` | 2026-09-18 | `flashinfer_jit_cache-0.7.0+gb10.cu134.tuning.v149-cp39-abi3-manylinux_2_28_aarch64.whl` | legacy-v |
| zbrad/flashinfer | `v0.7.0+gb10.cu134.tuning.v149` | 2026-09-18 | `flashinfer_python-0.7.0+gb10.cu134.tuning.v149-py3-none-any.whl` | legacy-v |
| zbrad/pytorch | `v2.12.0.dev20260703-gb10-cu133` | 2026-07-03 | `torch-2.12.0.dev20260703+git283e075.gb10.cu133-cp314-cp314-linux_aarch64.whl` | pre-marker |
| zbrad/pytorch | `v2.14.0.dev20260703-gb10-cu133` | 2026-07-04 | `torch-2.14.0.dev20260703+git9dcbe34504.gb10.cu133-cp314-cp314-linux_aarch64.whl` | pre-marker |
| zbrad/pytorch | `v2.14.0.dev20260706-gb10-cu133` | 2026-07-07 | `torch-2.14.0.dev20260706+gitabcaa78d1b.gb10.cu133-cp314-cp314-linux_aarch64.whl` | pre-marker |
| zbrad/pytorch | `v2.14.0.dev20260707-gb10-cu133` | 2026-07-07 | `torch-2.14.0.dev20260707+gitc36325c5ba.gb10.cu133-cp314-cp314-linux_aarch64.whl` | pre-marker |
| zbrad/pytorch | `v2.15.0.dev20260911+git01b0556c7e6.gb10.cu133-gb10-cu133` | 2026-09-11 | `torch-2.15.0.dev20260911+git01b0556c7e6.gb10.cu133-cp314-cp314-linux_aarch64.whl` | pre-marker |
| zbrad/pytorch | `v2.15.0+gb10.cu133.tuning-v29` | 2026-09-12 | `torch-2.15.0+gb10.cu133.tuning.v29-cp314-cp314-linux_aarch64.whl` | legacy-v |
| zbrad/pytorch | `v2.15.0+gb10.cu134.tuning-v34` | 2026-09-18 | `torch-2.15.0+gb10.cu134.tuning.v34-cp314-cp314-linux_aarch64.whl` | legacy-v |
| zbrad/raft | `v26.08.00-aarch64-cuda133-gb10` | 2026-07-07 | `libraft_gb10_cu13-26.8.0+cu133-py3-none-linux_aarch64.whl` | platform-only |
| zbrad/raft | `v26.08.00-aarch64-cuda133-gb10` | 2026-07-07 | `pylibraft_gb10_cu13-26.8.0+cu133-cp311-abi3-linux_aarch64.whl` | platform-only |
| zbrad/raft | `librmm-v26.10.00-x86_64-cuda133` | 2026-07-25 | `librmm_cu13-26.10.0+cu133-py3-none-linux_x86_64.whl` | platform-only |
| zbrad/raft | `librmm-v26.10.00-x86_64-cuda133` | 2026-07-25 | `rmm_cu13-26.10.0+cu133-cp311-abi3-linux_x86_64.whl` | platform-only |
| zbrad/vllm | `v8.4.dev7-gb10-cu133` | 2026-08-07 | `vllm-8.4.dev7+g2b9dcbd29.d20260807.gb10.cu133-cp314-cp314-linux_aarch64.whl` | pre-marker |
| zbrad/vllm | `v0.29.1rc1.dev435+g44a0a3c96.gb10.cu134.tuning.v539` | 2026-09-18 | `vllm-0.29.1rc1.dev435+g44a0a3c96.gb10.cu134.tuning.v539-cp314-cp314-linux_aarch64.whl` | legacy-v |

Class meanings: `legacy-v` is `<variant>.cu<cuda>.tuning.v<N>` (fused counter);
`pre-marker` is a tuned variant with no counter; `platform-only` is an upstream-style
`+cu133`; `no-local` has no local label.

## Findings and dispositions

Nothing was renamed or republished: consumers pin these exact URLs (for example
vllm's `requirements/gb10.txt`), and version ordering within each package stays
correct except for the one case noted below.

| # | Finding | Disposition |
|---|---|---|
| 1 | pytorch tags `v2.15.0+gb10.cu133.tuning-v29` and `...cu134.tuning-v34` use a dash, but the wheel filenames use a dot (PEP 440 normalization). A third, older tag (`v2.15.0.dev20260911+git01b0556c7e6.gb10.cu133-gb10-cu133`) also disagrees with its wheel. | Leave. Fixed going forward: pytorch's wheel script now builds its version through `gpu_tuned_local_version`, so its tag and wheel agree. Verify on the first new pytorch build. |
| 2 | vllm's public version regressed: the 2026-08-07 wheel is `8.4.dev7+...` (a bogus `setuptools_scm` guess) but the 2026-09-18 wheel is `0.29.1rc1.dev435+...`, which sorts *below* it. | No practical effect while consumers pin URLs. It would bite anyone running `pip install -U vllm` against a find-links index of our releases (the older build wins). Do not publish an unpinned index of vllm wheels. Not fixable without an epoch, which we do not want. |
| 3 | flashinfer `flashinfer_python-0.6.13+gb10` and `flashinfer_jit_cache-0.6.13+gb10` are attached to two releases (`v0.6.13-gb10`, `v0.6-gb10-cu133`). | Harmless: identical bytes (same sha256 and size). It is the same build re-tagged when the tag convention changed. |
| 4 | 15 `pre-marker` wheels have a variant and CUDA tag but no counter, so two rebuilds of the same upstream version are indistinguishable. | Leave. This is exactly why the `tuning` counter was introduced (2026-09-10); everything built since has one. |
| 5 | raft's 4 wheels (`libraft`, `pylibraft`, `librmm`, `rmm`) use `+cu133` only (upstream RAPIDS style), and 2 faiss wheels have no local label. They are built by their own scripts, not the shared helper. | Open question: should raft/rmm wheels adopt the counter? They were not in scope for the rule (it covers wheels built by the five repos' `tuned/` scripts), and rebuilds of the same version are currently indistinguishable. Decide when raft wheels are next rebuilt. |

No wheel has a normalization problem (each filename's version equals its
PEP 440 normalized form) and none has a zero-padded numeric segment.

## Next steps

- Verify the first real `tuning.N` build of each wheel repo with
  `python3 tools/wheel_version_audit.py --files dist/*.whl` (exits 1 unless every
  wheel is `conforming`).
- Optionally call that from each release script as a gate.
- Re-run this audit after those builds and periodically; the tool is read-only.
