# Wheel version style for tuned builds

**Rule:** every tuned wheel carries this PEP 440 local-version label, built only
by `gpu_tuned_local_version` (in `tuned-common.sh`), never by hand:

```
<public version>+<variant>.cu<cuda>.tuning.<N>
e.g.  0.7.0+gb10.cu134.tuning.149
```

- `<variant>`: lowercase alphanumeric (`gb10`, `rtx50`).
- `cu<cuda>`: CUDA toolkit, digits only, no dot (`cu134` for 13.4).
- `tuning.<N>`: `N` is the number of tuned-builds commits ahead of `main`, as its
  **own purely numeric segment**, canonical decimal, **never zero-padded**.
- Lowercase, dot-separated, letters and digits only. No `-`, no `_`.
- An upstream-derived prefix segment is allowed before the tuned part
  (`+g44a0a3c96.gb10.cu134.tuning.539`): `setuptools_scm` dev versions (vllm)
  put `g<sha>` there. It must start with a letter, so it can never be a
  purely numeric segment that PEP 440 would rewrite.
- The wheel filename, release tag, release title and installed metadata must all
  show the same string. Parse it with `gpu_tuned_tuning_label` (matches
  `tuning\.[0-9]+`), never with a hand-written regex.

Older wheels use the legacy form `tuning.vN` (and pytorch's tags use
`tuning-vN`); see "Backfill" below.

## Why (PEP 440 facts, verified with `packaging` 26.2)

1. **Allowed characters.** A local label is ASCII letters, digits and `.`. `-` and
   `_` are accepted on input but normalized to `.`, and case is lowercased. So
   `tuning-v34` and `tuning.v34` are the same version, and a wheel filename
   always shows the dotted form (a raw `-` can't appear in a filename anyway,
   because `-` separates the filename fields). Any script that builds a tag or
   greps for the dashed form disagrees with the wheel it just built.
2. **Ordering.** The label is split on `.` into segments. A purely numeric
   segment compares as an integer and sorts *above* any alphanumeric segment;
   an alphanumeric segment compares as text. So a counter fused with letters
   (`v9`, `tuned9`) misorders at digit boundaries: `tuning.v10 < tuning.v9`
   and `tuned100 < tuned10` (both verified). `tuning.9 < tuning.10 < tuning.100`
   sorts correctly. We are already at 149 (flashinfer) and 539 (vllm).
3. **Numeric segments are normalized, so leading zeros are dangerous.**
   `1.0+x.tuning.007` normalizes to `1.0+x.tuning.7` (verified), while an
   alphanumeric segment such as `v007` is left alone. A filename containing
   `007` then no longer matches the version in its own metadata. This is a
   real-world failure: NVIDIA's Jetson torch wheels
   (`2.5.0a0+872d972e41.nv24.08.17622132`) were rejected by `uv` with "wheel
   version does not match filename" in a
   [forum thread](https://forums.developer.nvidia.com/t/installing-pytorch-on-our-jetson-agx-orin-fails-with-wheel-version-does-not-match-filename/378289).
   The thread only reports the mismatch (the user renamed the wheel); the
   leading-zero cause is our inference, confirmed by the normalization test
   above (`nv24.08` -> `nv24.8`).
4. Switching from `tuning.vN` to `tuning.N` stays monotonic: a numeric segment
   sorts above the old alphanumeric `vN` one (verified), and a higher `cuNNN`
   segment wins regardless of the counter.

## What other packages do (research, 2026-09-18)

| package | local label | style |
|---|---|---|
| PyTorch ([uv docs](https://docs.astral.sh/uv/guides/integration/pytorch/)) | `2.11.0+cu130`, `+cpu` | one fused platform tag |
| vLLM (`setup.py`) | `+cu129`, `+rocm…`, `+cpu`, `+tpu`, `+precompiled`; dev builds `+g<sha>` | one fused tag |
| FlashInfer (release CI) | `FLASHINFER_LOCAL_VERSION=<cuda label>`, e.g. `cu130` | one fused tag |
| flash-attention (Dao-AILab CI) | `+cu12torch2.8cxx11abiFALSE` | fused letters and digits |
| Astral GPU indexes ([uv docs](https://docs.astral.sh/uv/guides/integration/pytorch/)) | `+cu.12.8.torch.2.11` | dot-separated, numeric segments |
| NVIDIA Jetson torch ([docs](https://docs.nvidia.com/deeplearning/frameworks/install-pytorch-jetson-platform/index.html)) | `2.5.0a0+872d972e41.nv24.08.17622132` | sha + `nv<YY>.<MM>` + build number |
| Debian/Ubuntu Python packages | `1.7+build1`, `2.7.7+ubuntu5.2` | Debian style |

Most projects use one fused tag and none carries a running counter, so there is
no ecosystem convention to copy for the counter; the rules above come from
PEP 440 itself ([spec](https://peps.python.org/pep-0440/); further reading:
[Quansight overview](https://labs.quansight.org/blog/python-wheels-from-tags-to-variants)).

## Known limitations

- `cu<cuda>` is a fused alphanumeric segment (the ecosystem convention), so it
  compares as text: `cu1310` (CUDA 13.10) sorts below `cu134` (verified). Not a
  problem until CUDA reaches two-digit minors; revisit then (`cu.13.10`).
- Non-wheel artifacts (raft/cuvs/faiss tarballs and their `-g<sha>` tags) are
  outside PEP 440 and follow their own tag convention.

## Enforcement

- `gpu_tuned_local_version <variant> <cuda> <count>` builds the label and
  **fails loudly** on a non-conforming input (wrong characters, zero-padded or
  non-numeric count). All wheel scripts must call it.
- `gpu_tuned_tuning_label <version>` extracts `tuning.<N>` and never fails.
- Both are covered by `tests/test_common.sh` (run it before every change to this
  library).
- This library also installs a loud-failure `ERR` trap when sourced, so any
  abort under `set -euo pipefail` prints the failing command and call stack
  instead of exiting silently. Opt out with `GPU_TUNED_NO_ERR_TRAP=1`.

## Backfill (existing releases that predate this rule)

Published tuning-marked releases as of 2026-09-18 (none is renamed: consumers pin
these exact URLs):

| repo | tags |
|---|---|
| pytorch | `v2.15.0+gb10.cu133.tuning-v29`, `v2.15.0+gb10.cu134.tuning-v34` (tag dashed, wheel filename dotted) |
| flash-attention | `…cu133.tuning.v21`, `…cu134.tuning.v44` |
| flash-attention-vllm | `…cu133.tuning.v39`, `…cu133.tuning.v47`, `…cu134.tuning.v50` |
| flashinfer | `…cu133.tuning.v28`, `…cu134.tuning.v149` |
| vllm | `…cu134.tuning.v539` |

New builds use `tuning.<N>`. A one-time audit of *every* published wheel and tag
(including releases older than the tuning marker) against this rule is a
tracked todo, not yet done.
