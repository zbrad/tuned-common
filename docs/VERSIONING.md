# Wheel version style for tuned builds

**Rule (current, user decision 2026-10-11):** every tuned wheel carries this PEP 440
local-version label, built only by `gpu_tuned_local_version_dated` (in
`tuned-common.sh`), never by hand:

```
<public version>+<variant>.cu<cuda>.<YYYYMMDD>[.<seq>]
e.g.  2.15.0+gb10.cu134.20261010        first build of that day
      2.15.0+gb10.cu134.20261010.1      second build the same day
```

- `<variant>`: lowercase alphanumeric (`gb10`, `rtx50`).
- `cu<cuda>`: CUDA toolkit, digits only, no dot (`cu134` for 13.4).
- `<YYYYMMDD>`: a real calendar date, not starting with `0`, as its **own purely
  numeric segment**. Intended source: the committer date (UTC) of the tuned
  commit, so rebuilding the same commit reproduces the label (the allocator that
  supplies it is a separate piece of work; until it exists the caller passes the
  date). It replaces the commit counter, so the "local `main` must equal
  `upstream/main`" precondition of the old rule does not apply to this form.
- `<seq>`: the build's sequence within that date. `0` is the first build and is
  **omitted**; `1`, `2`, ... are appended. Canonical integer, never zero-padded.
  `.0` is never produced and is not accepted by the parser: PEP 440 sorts
  `<date>.0` above `<date>`, which would be a second spelling of the first
  build. The native release tag renders the same integer in full
  (`v0.<date>.<seq>`, so `.0` there); both come from one sequence value.
- The public version is **upstream's and is not touched**. That is deliberate: a
  version must satisfy what other packages require of the package (see "Why the
  public version and the distribution name stay upstream's").
- Lowercase, dot-separated, letters and digits only. No `-`, no `_`.
- An upstream-derived prefix segment is allowed before the tuned part
  (`+g44a0a3c96.gb10.cu134.20261010`): `setuptools_scm` dev versions (vllm)
  put `g<sha>` there. It must start with a letter, so it can never be a
  purely numeric segment that PEP 440 would rewrite. That prefix already makes
  local-label ordering *across* vllm builds depend on the sha text, which a
  date does not fix.
- The wheel filename, release tag, release title and installed metadata must all
  show the same string. Parse it with `gpu_tuned_date_label` (anchored on the
  preceding `.cu<cuda>.`; a bare digit match would also hit a public
  `2.15.0.dev20260911`), never with a hand-written regex.

### Where the date and sequence come from

`gpu_tuned_allocate_date_label [dir] [remote]` prints the label for a build of `HEAD`:

- **Date:** `gpu_tuned_head_date`, the committer date of `HEAD` in **UTC** (`TZ=UTC` with git's
  `--date=format-local`). Not the wall clock, and not `--date=format:`, which uses the commit's own
  recorded timezone and is a day early for a commit made at 23:30 at UTC-7 (verified in the tests).
- **Sequence:** the **lowest unused** integer for that date, among the date labels on tags in
  `origin` (`git ls-remote --tags`, because a GitHub release is a git tag) and on local tags. It
  is per date across the repo: a second build that day gets `.1` even for a different CUDA tag.
  Legacy counter tags, native `v0.<date>.<seq>-...` tags, plain versions and other dates are ignored.
- **If `origin` cannot be read it fails loudly** and names `GPU_TUNED_LABEL_SEQ=<n>`, which
  chooses the sequence offline (a canonical integer; `0` is the bare date). A dev build that is
  never published sets `GPU_TUNED_LABEL_SEQ=0` and does no lookup.
- `gpu_tuned_label_seq <label>` returns the integer (0 for a bare date), so one value renders both
  the wheel label (0 omitted) and the native tag (`v0.<date>.<seq>`, 0 written).

### Previous rule (2026-09-18 to 2026-10-11), still accepted

`<public version>+<variant>.cu<cuda>.tuning.<N>`, `N` = `git rev-list --count
main..HEAD`, built by `gpu_tuned_local_version`, parsed by `gpu_tuned_tuning_label`.
Those functions and the audit's `conforming` class are kept until every consumer has
migrated. Wheels already published in that form, and the older `tuning.vN` form
(pytorch's tags use `tuning-vN`), are **not renamed** because consumers pin exact URLs.
Why it changed: the counter needed a hand-run `git fetch upstream main:main` before every
build and was inflated by 21-485 when forgotten (found 2026-09-18), and the user wanted a
shorter version string (dropping the `tuning.` marker; the `<variant>` already marks the
wheel as ours) that is meaningful at a glance. Ordering is verified in
`tests/test_wheel_version_audit.py`: every date label sorts above every `tuning.N`,
`tuning.vN` and the bare `+gb10`, and `<date>.2 < <date>.10`.

**Publish-time check (2026-10-11).** `gpu_tuned_publish_release` runs `gpu_tuned_check_wheel_label`
on every `.whl` asset before `gh` is called, and refuses unless the file name carries the date
form. The counter form is accepted only with `GPU_TUNED_ALLOW_COUNTER_LABEL=1`, with a warning,
for a repo not yet migrated; no label, `+cu133`, and `tuning.vN` are always refused. The check
is plain bash, because consumers vendor only `common.sh`, not `tools/`; a pytest case runs it
beside the audit's `DATED` class so the two cannot drift. It reads the file name only.

## Why the public version and the distribution name stay upstream's

Considered and rejected 2026-10-11: giving tuned artifacts their own version space
(`v0.<date>...`) or a `-tuned` distribution name. Tested with `packaging` 26.3 and with
pip and uv 0.11.3:

- A wheel versioned `2.15.0+gb10...` satisfies `==2.15.0`, `>=2.4`, `>=2.13,<2.16`,
  `~=2.15.0` and `==2.15.*`; a `0.20261010.0` wheel fails all five.
- A renamed distribution (`torch-tuned`) that declares `Provides-Dist: torch (==2.15.0)`
  still fails `consumer requires torch==2.15.0` in both pip and uv: neither honors
  `Provides-Dist`. With network access pip would instead fetch PyPI's `torch` and install
  both over the same `torch/` directory (inferred, not tested).
- In `~/gh/vllm/.venv`, 10 installed packages require torch outside of extras: 3 are ours
  (vllm, vllm-flash-attn, flashinfer-python) and 7 are third-party
  (compressed-tensors, humming-kernels, quack-kernels, tilelang, tokenspeed-mla,
  torch_c_dlpack_ext, xgrammar). Renaming would mean forking all seven. vllm itself reads
  the version at runtime in about 50 `is_torch_equal_or_newer` calls (floors up to 2.12).
- So the only way to a clean tuned version number is a two-wheel split (an empty
  upstream-named shim depending on a renamed payload), which doubles every wheel and was
  not built. Not adopted.

## Why (PEP 440 facts, verified with `packaging` 26.2; written for the counter form, still applies)

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

- `gpu_tuned_local_version_dated <variant> <cuda> <YYYYMMDD> [<seq>]` builds the
  current label and **fails loudly** on a bad variant or CUDA tag, an impossible or
  zero-led date, or a non-canonical sequence. `gpu_tuned_valid_date <YYYYMMDD>` is its
  date check. `gpu_tuned_date_label <version>` extracts `<YYYYMMDD>[.<seq>]` (anchored,
  never fails). New wheel scripts call these. Consumers still on the counter form keep
  calling the three functions below until migrated: the shell helpers are not yet wired
  into the consumers, whose `setup.py` files (vllm and others) build the counter label
  themselves, and flashinfer's and vllm's `release.sh` read it back with
  `gpu_tuned_tuning_label`.
- `gpu_tuned_local_version <variant> <cuda> <count>` builds the previous-rule label and
  **fails loudly** on a non-conforming input (wrong characters, zero-padded or
  non-numeric count). All wheel scripts must call it.
- `gpu_tuned_tuning_count [dir]` computes N (`git rev-list --count main..HEAD`) and
  **fails loudly** when local `main` is stale, i.e. when upstream has been merged into
  `HEAD` but `main` was not fast-forwarded, so N would include upstream's commits. The
  error names the fix (`git fetch upstream main:main`). A plain `git fetch upstream`
  without a merge is fine. Override (not recommended): `GPU_TUNED_ALLOW_STALE_MAIN=1`.
  `gpu_tuned_check_main_current [dir]` is the check alone, for repos whose version is
  computed elsewhere (vllm's `setup.py`). All wheel scripts must use these instead of
  running `git rev-list` themselves.
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

The legacy counters are not comparable with `tuning.<N>` beyond ordering: the labels
published 2026-09-11 to 2026-09-18 were computed while local `main` was stale after the
upstream merges (for example flashinfer `v149` includes 118 upstream commits; the same tree
counts 33 once `main` is fast-forwarded). A numeric `tuning.<N>` still sorts above every
legacy `tuning.vN` (verified for the latest release of each repo).

New builds use `tuning.<N>`. A one-time audit of *every* published wheel and tag
(including releases older than the tuning marker) against this rule is a
tracked todo, not yet done.
