# Tuned build and versioning architecture

The one design every repo in the tuned-builds fleet is measured against. Each requirement has an
ID, says what a repo MUST do, which repos it applies to, and how to check it. A repo's compliance
is the list of requirement IDs it passes, fails, or does not apply to, each with evidence.

**NYI** means not yet implemented: described here, but nothing exists to run or measure.

**Status: PROPOSED, written 2026-10-15; not yet ratified as a whole.** Two rules in it are the user's own decisions of 2026-10-15 and already in force: native releases are named by the UTC date label (E2: "that's the wrong form, it should be date-based", about the `-g<sha>` tags), and package and release are separate stages (B3). It consolidates rules that already
exist in one place or another (`README.md`, `docs/VERSIONING.md`, `docs/UPSTREAM_SYNC.md`,
`tuned-common.sh`) and the build/test/package/release practice settled while rebuilding raft,
cuvs, faiss and llama.cpp. Every requirement carries a **Source**; "practice 2026-10-15" means
adopted in that work but not previously written down or decided. Where this document and a
shorter rule elsewhere disagree, fix one of them: do not leave both.

## 1. Vocabulary

- **variant**: a hardware target (`gb10`, `rtx40`, `rtx50`); facts in `devices/<variant>.conf`.
- **toolkit**: one CUDA toolkit, named `cu<digits>` (`cu133`); facts in `toolkits/<id>.env`.
  A build uses exactly one variant and one toolkit.
- **native repo**: ships a tarball of binaries/libraries (raft, cuvs, faiss, llama.cpp, nccl,
  ollama). **wheel repo**: ships Python wheels (pytorch, vllm, flash-attention,
  flash-attention-vllm, flashinfer). **deployment repo**: installs tuned artifacts and is intended to
  provide a frozen deployment of particular releases as pre-built binaries (ComfyUI, open-webui). The fleet has **not built any yet**
  (user, 2026-10-15); only what upstream does is precedent. A web search the same day (attributed, not run here) found: ComfyUI ships a
  Windows portable build and a desktop app (docs.comfy.org; no official Docker image was confirmed); Open WebUI ships official container
  images at `ghcr.io/open-webui/open-webui` with `vX.Y.Z` and `git-<sha>` tags (docs.openwebui.com/deployment/docker-images). The
  zbrad forks' GitHub releases publish nothing of their own (open-webui's mirror upstream's notes with no assets, ComfyUI lists none).
  What a fleet deployment is (archive, container image, both) and where it is published are open, to be decided when the first is built. Applicability below uses these words.
- **label**: `<YYYYMMDD>[.<seq>]`, the build identity (section 5). As a value inside the tooling (`gpu_tuned_date_label`) sequence 0
  reads as the bare date; in a tag, tarball name or wheel version the sequence is always written (`.0`, E1/E2).
- **artifact kind**: `native` (a tarball) or `wheel`. A repo ships one or more kinds and each requirement applies to the kinds it
  names, so raft, cuvs and faiss (tarballs and wheels) are measured once per kind. A repo declares its kinds, exceptions and
  attestations in `tuned/compliance.conf` (section 6).
- **vendored**: a pinned copy of tuned-common files committed in the consumer repo.

## 2. Principles

1. **One source for shared logic.** Anything two repos need goes in `tuned-common.sh` and is
   vendored, not re-written. Repos keep only what is specific to them (`tuned/repo.env`).
2. **Fail loudly.** A wrong toolkit, a stale cache, a missing test log or a foreign library is an
   error that names the fix, never a silent fallback.
3. **Isolation per toolkit.** Two toolkits never share a build tree, cache, test log, tarball or
   dependency directory.
4. **Nothing is published untested.** A release needs a passing test log newer than the thing it
   releases, and a package checked as a consumer receives it.
5. **Identity is a date, not a count.** Commit counts and shas never name a release.
6. **Our artifacts cannot be mistaken for stock ones**, by name, SONAME or loader resolution.
7. **Provenance is recorded**: what was built, tested and shipped is written down next to it.

## 3. Requirements

Legend: **N** native, **W** wheel, **D** deployment repo, **All** every repo with a `tuned/` directory.

### A. Vendoring and shared data

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| A1 | `tuned/common.sh`, `tuned/sync-common.sh` and `tuned/common.sh.sha` are tracked, and `tuned/sync-common.sh check` exits 0 (the vendored copy is tuned-common's current `main`; there is no pin file, so a repo that must stay behind records an exception in `tuned/compliance.conf` with the reason). `common.sh` must also equal tuned-common's file at the commit in `common.sh.sha`. | All | `tuned_compliance.sh`: byte comparison against tuned-common `origin/main` (as last fetched) and the sha'd commit; `sync-common.sh check` with `--online` | README, "Keeping a vendored copy in sync" |
| A2 | `tuned/common-data/` is vendored (devices, toolkits), refreshed by the same sync; the repo's own `sync-common.sh` is current (an old one skips new data files). | All | `diff tuned/sync-common.sh <tuned-common>/sync-common.sh`; `tuned/common-data/toolkits/*.env` and `devices/*.conf` match tuned-common's lists (there is no `toolkits/DEFAULT` since 2026-10-16) | README; found 2026-10-15 |
| A3 | `tuned/env.sh` sources `common.sh`, asserts the platform, loads the toolkit with `gpu_tuned_load_toolkit` and verifies it (`gpu_tuned_verify_toolkit`), and loads repo settings with `gpu_tuned_load_repo_env` from `tuned/repo.env`. | All | read `env.sh` | README |
| A4 | `tuned/repo.env` only adds repo-specific keys; it never sets a device, toolkit or `CUDA_*` value. | All | `gpu_tuned_load_repo_env` fails loudly on any such key | README |
| A5 | The ERR trap is left on (`GPU_TUNED_NO_ERR_TRAP` unset). | All | grep | VERSIONING.md |
| A6 | Every `toolkits/<id>.env` defines every key, including `TOOLKIT_NCCL_VERSION` (a pinned system version, or `none` when no system NCCL is supported for that toolkit), so adding a toolkit forces the question to be answered. | All | `tests/test_common.sh` checks it | found 2026-10-16: cu134 shipped a libnccl built for 13.3 because the key was simply absent |
| A7 | No `gpu_tuned_*` function is defined outside the vendored `common.sh` (Principle 1): logic two repos need goes in tuned-common. A repo-specific helper takes a repo prefix (`cuvs_`, `raft_`, `faiss_`) and stays in the repo. | All | `tuned_compliance.sh` A7: no `gpu_tuned_*() {` definition in the repo's own scripts | review of 2026-10-17 (raft/cuvs/faiss defined `gpu_tuned_assert_cmake_cache_consistent`, `gpu_tuned_verify_pin_honored`, `gpu_tuned_verify_cccl_toolkit_match` locally); owner decision 2026-10-17 |

### B. Entry points and stage order

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| B1 | A native repo provides `tuned/build.sh`, `tuned/full_test.sh`, `tuned/package.sh`, `tuned/smoke_test.sh`, `tuned/release.sh` and `tuned/publish.sh`, each taking `<variant>` and selecting the toolkit by `CUDA_TAG`/`CUDA_VER`, never defaulted or guessed (with none named the loader fails and lists the defined toolkits; at a terminal it asks). | N | `ls`; run each with no args and read the usage | practice 2026-10-15 (raft, cuvs, faiss, llama.cpp) |
| B2 | A wheel repo provides a wheel build script, a full test script and a release script with the same stage order and gates (E, G, I apply). | W | `ls` | practice; wheel scripts predate this, compliance unmeasured |
| B3 | The order is build, test, package, smoke test, (review and commit notes), release, publish. `release.sh` never builds, tests or packages and never publishes; `package.sh` never tags, publishes or finalises notes. | N | read both scripts; `grep -n 'gh release\|git tag' package.sh` is empty | practice 2026-10-15; requested by the user 2026-10-15 ("split packaging and release") |
| B4 | No stage selects a toolkit from `/usr/local/cuda`, from what is installed, or by a default; the toolkit is the one specified. | All | grep for `/usr/local/cuda\b` outside `toolkits/*.env` | README |

### C. Layout and isolation

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| C1 | Each toolkit (and variant, where trees would otherwise mix) has its own build tree, tarball directory and test log. | N, W | the paths contain the cuda tag | `gpu_tuned_cuda_subdir` header |
| C2 | The canonical tree is `<repo>/tuned/build/<cuda-tag>/` from `gpu_tuned_out_dir` and **has no variant level** (`cmake/` objects, `dist/` tarballs and wheels, `releases/` test and smoke logs and checksums, `ccache/`, plus repo-specific siblings): a variant is built on its own machine or checkout, never beside another in the same storage, and `gpu_tuned_claim_toolkit_tree` refuses a mix-up. **Decided 2026-10-18.** Done in raft, cuvs and (2026-10-18) nccl, whose root is `build/<cuda>/` at the repo root (upstream gitignores `/build*`) rather than `tuned/build/<cuda>/`; **NYI** in faiss (`build_output/ _build/ _libfaiss_stage/ dist/` each with `<cuda>/<variant>/`), llama.cpp (`build-tuned/<cuda>/<variant>/`): each keeps a recorded exception in its `tuned/compliance.conf` until it moves. | N | path check; `docs` records any deviation | `gpu_tuned_out_dir` header; owner decision 2026-10-18 (variants do not share build storage) |
| C3 | Before configuring, an existing CMake cache is checked against the toolkit's nvcc and the source tree; a mismatch fails and names the directory to remove. | N | read `build.sh` | practice (cuvs `env.sh`, llama.cpp `build.sh`) |
| C4 | ccache is per toolkit (`CCACHE_DIR` inside the toolkit tree) with an explicit size. | N | grep `CCACHE_DIR` | practice (cuvs, llama.cpp) |
| C5 | Default build parallelism is `gpu_tuned_jobs` (largest prime <= nproc-2); an environment override wins. | All | grep: no bare `$(nproc)` as a default | rollout 2026-10-15 |
| C6 | Tuned builds never write to the repo's everyday dev build directory (the one local services may run). | N | path check | practice 2026-10-15 (llama.cpp `build/`) |
| C7 | Pip-installed CMake packages (RAPIDS wheels, nvtx3) are kept out of native builds (`gpu_tuned_cmake_ignore_pip_prefixes`) and the configured cache is checked (`gpu_tuned_verify_no_pip_cmake_deps`). | N that build against RAPIDS | read `build.sh` | tuned-common commits 72430ce, c928ac7 |
| C8 | A build that installs Python packages ends its `pip install` section with `gpu_tuned_install_setuptools`: the current setuptools release, at least `GPU_TUNED_SETUPTOOLS_MIN`, installed last because upstream's requirement files cap it (vllm `<81`, torch `<82`) and a later `pip install -r` pulls it back down. The version is printed, so the build log records it. A build.sh that installs no Python packages passes with a note. | N, W | `gpu_tuned_install_setuptools` call in `tuned/build.sh` | user 2026-10-26 ("make it most current, setuptools is a critical component"); the audit of the vllm wheel found setuptools 80.10.2 held back by the `<81` cap |
| C9 | A build.sh that uses a Python venv gets it from `gpu_tuned_setup_build_venv <venv-dir> <repo-root>`, not from its own copy of the sequence: `GPU_TUNED_CLEAN_VENV=1` removal, create or (for an existing venv) `gpu_tuned_verify_venv`, activate, upgrade pip, and the current setuptools (`gpu_tuned_install_setuptools`), so setuptools is never missing or old for what the build installs next. The build still ends its pip section with the C8 call, since a later `pip install -r` can pull setuptools back down. A build.sh with no Python venv passes with a note. | N, W | `gpu_tuned_setup_build_venv` call in `tuned/build.sh`; a hand-rolled venv or pip install without it fails | user 2026-10-26 ("update common-tools and common-tests and common-gates to expect to use a build-venv setup"); five repos each carried the same create/verify/activate block |

#### Layout today

Surveyed with `ls` on 2026-10-18 (zspark-1); the 2026-10-12 decision is from commit `3cf4a64`. What is **tracked** is the tooling and the reviewed
release notes; everything under a build tree is **generated** and gitignored.

```
<repo>/
  tuned/                              TRACKED: the tooling, one flow for every repo
    build.sh  full_test.sh  package.sh  smoke_test.sh  release.sh  publish.sh    stage scripts, each takes <variant>
    env.sh  repo.env  compliance.conf                                  toolkit/device selection, repo settings, exceptions
    common.sh  sync-common.sh  common.sh.sha  common-data/{devices,toolkits}/    vendored from tuned-common (A1, A2)
    releases/RELEASE_NOTES_<label>-<variant>-<cuda>.md                 TRACKED, reviewed before a release (I2); drafts are untracked
    <variant>/  (raft: gb10/ rtx40/ rtx50/)                            optional per-variant wrapper scripts; one set per variant
    build/<cuda>/                     GENERATED, one tree per toolkit  (raft, cuvs; C2)
      cmake/            the one fixed compile path, so ccache hits and ninja's log is kept
      dist/             tarballs / wheels            dist-shared/  wheels shared by all variants (raft, a sibling of dist/)
      releases/         generated release inputs: TEST_RESULTS_<variant>.log, SMOKE_RESULTS_<variant>.log, CHECKSUMS
      ccache/           per toolkit (C4)             raft/<tag>/   (cuvs) the extracted raft release this build linked
```

| Axis that runs in parallel | raft, cuvs | faiss | llama.cpp | nccl |
|---|---|---|---|---|
| **Toolkit** (cu133 beside cu134) | yes: `tuned/build/<cuda>/` | yes: `<dir>/<cuda>/<variant>/` | yes: `build-tuned/<cuda>/<variant>/` | yes: `build/<cuda>/` |
| **Variant** (gb10 beside rtx40) | **no**: `.variant` claim refuses a tree used by another variant | yes: `build_output/`, `_build/`, `_libfaiss_stage/`, `dist/` all have `<cuda>/<variant>/` | yes | **no**: `.variant` claim |
| **Source state** (several commits at once) | no: one fixed tree | no | no | no (since 2026-10-18): one tree `build/<cuda>/{ccache,work,nccl,dist,releases}`; the source a build came from is recorded in `nccl/.params` and checked by `nccl_tuned_assert_build_current` |
| **Branch** | one branch | one branch | one branch | **one branch per toolkit**: `tuned-builds-cu133`, `tuned-builds-cu134`, each based on the upstream release NVIDIA ships for that CUDA |

Notes:
- **The variant level was dropped for raft and cuvs on 2026-10-12** (they previously built into `cpp/build/<cuda>/<variant>` and `dist/<cuda>/<variant>`, so
  several variants could sit side by side in one checkout). The commit gives the reason as one fixed compile path per toolkit so that ccache hits and
  ninja's log is kept. Consequence: a second variant needs a separate checkout (or machine); `gpu_tuned_claim_toolkit_tree` refuses a mix-up rather than
  silently mixing objects. This was not recorded in this document until now.
- **faiss, llama.cpp and nccl deviate from C2** (their own roots, a variant level in faiss and llama.cpp, source-state-named trees in nccl); each
  records the reason in its `tuned/compliance.conf`. **Decided 2026-10-18: they converge on the raft/cuvs shape** (`<cuda>/` only, no variant level;
  see C2). Not yet done; the table above shows the layouts as they are today.
- **nccl used to keep one `<describe>/` tree per source state** (they accumulated, some `-dirty`) and no longer does: it moved to the flat
  per-toolkit shape on 2026-10-18. Without the directory name to tell a stale build apart, the check is explicit: the build records its exact source in
  `.params` and `full_test.sh` and `package.sh` refuse a build that is dirty or whose source outside `tuned/` differs from HEAD (H6). The old
  trees are left on disk; clearing them is the maintainer's call.
- **Variant staging for wheels** (`wheel-src/` under the build tree, generated per variant and never edited in place) is described in
  `~/.claude/design/variant-build-staging-pattern.md`.

### D. Dependencies on other tuned repos

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| D1 | A consumer of another tuned repo's tarball fetches that repo's newest release (`gpu_tuned_newest_release_tag`: the highest date label, ranked as numbers, never list order; an older-form tag only as a noted fallback) and never reuses an unpacked copy whose tag differs from the newest, silently (the property; a marker file such as faiss's `.release_tag`, or a directory named by the tag as in cuvs, are both acceptable mechanisms). | N consuming N (cuvs<-raft, faiss<-cuvs) | human read, then attested in `compliance.conf`; a fixture test of the lookup is NYI | faiss bug found 2026-10-15 |
| D2 | The dependency's package must carry everything its CMake config needs (nvtx3 included); the packager proves it with a consumer configure against the package alone (`gpu_tuned_verify_consumer_configure`). | N that ship a CMake package | package-time gate present | tuned-common 3b5f4d0 |
| D3 | The producer->consumer pairing is recorded and test-run (`tuned/docs/RELEASE_PINS.md` for the RAPIDS chain), including which releases are superseded or deleted. | raft, cuvs | file present, row per release | practice |

### E. Identity and versioning

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| E1 | A wheel carries `<public version>+<variant>.cu<cuda>.<YYYYMMDD>.<seq>` (the sequence always written, `0` for the first, as in E2), built only by `gpu_tuned_local_version_dated`/`gpu_tuned_build_local_version`, never by hand. The public version is upstream's. Wheels published before 2026-10-16 with the bare date are not renamed and read as sequence 0. | W | `gpu_tuned_date_label` parses the wheel name | VERSIONING.md (user decision 2026-10-11; `.0` written, user decision 2026-10-16) |
| E2 | A native release tag is `v0.<YYYYMMDD>.<seq>-<variant>-<cuda-tag>` (the sequence always written, `0` for the first), built by `gpu_tuned_native_tag`. | N | `gpu_tuned_date_label <tag>` returns a label | VERSIONING.md; `docs/upstream-vs-tuned-versions.json` `scheme.native_tag`; user 2026-10-15 ("back to UTC dates ... build count per date") |
| E3 | The date is the UTC committer date of the tuned `HEAD` (`gpu_tuned_head_date`); the sequence is the lowest unused for that date among the repo's tags (`gpu_tuned_allocate_date_label`). Never the wall clock, never a commit count or a sha. | All | read the label source | VERSIONING.md |
| E4 | The label is allocated once, at the earliest stage that bakes it into an artifact, and recorded in a file the later stages read: `package-info.txt` for native tarballs whose identity is stamped at packaging (raft, cuvs, faiss), `<build>/release-label` for llama.cpp and nccl, whose label is compiled into the binary or library at build time (nccl: `<build root>/release-label`; its version line reads `NCCL version 2.32.3-gb10-cu134.20261018.0+cuda13.4`), and the wheel script for wheels. Later stages never recompute it (a notes commit moves `HEAD` and its date). Nothing reserves a label before publish, so the full commit stays in the build info and the release gate checks the tag is free. **If two packages were built for one date and the tag is taken, the gate fails and the maintainer repackages to get the next sequence (decided 2026-10-17: no automatic relabel, no reserving tag).** | N, W | the recorded file; `release.sh` reads it | practice 2026-10-15 (llama.cpp, user: "build info ... release version more relevant") |
| E5 | Tag, tarball name, release title, notes file name and the artifact's own metadata show the same label. | All | compare | VERSIONING.md |
| E6 | A commit count may be reported and checked, but identifies nothing: it is repo-relative (llama.cpp's `--version` "build N" is this fork's history count, not upstream's) and rises with every commit. It appears only as `fork.commit_count` in the build info. | All | grep `rev-list --count` outside a version check | user 2026-10-15; decisions/2026-09-10 superseded |
| E7 | Releases published in an older form are not renamed (consumers pin URLs). Consumers accept both forms and rank any date-label tag above an older one. | All | consumer tag parsers | VERSIONING.md; practice 2026-10-15 (llama.cpp `install.sh`) |
| E8 | Tooling refuses a wrong identity before `gh`: `gpu_tuned_publish_release` checks every release tag (`gpu_tuned_check_release_tag`: a native or wheel date label, else refused) and every `.whl` asset's label. `GPU_TUNED_ALLOW_COUNTER_LABEL=1` lets a not-yet-migrated repo publish an older form, loudly. | All | `tests/test_common.sh` (release_tag, publish_release cases) | tuned-common d17e0f9, 2026-10-15 |

### F. Names that cannot collide with stock

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| F1 | Every shared object we ship has a unique name that carries exactly the axes its contents depend on, and the same name is its file name, SONAME and every NEEDED entry: a library **with device code** (cubin or PTX per `cuobjdump --list-elf`/`--list-ptx`), **or one that NEEDs a library carrying the variant** (a wrapper such as `libfaiss_c` or `libcuvs_c`; the variant is transitive), is `lib<name>-<variant>-<toolkit>.so` (`libraft-gb10-cu133.so`); any other is `lib<name>-<toolkit>.so` (`librmm-cu133.so`). The test is mechanical, never "neutral by inspection". **NYI:** `gpu_tuned_rename_package`, `gpu_tuned_tuned_so_name` and the `-tuned` mark still implement the superseded generic form; librmm, librapids_logger and llama.cpp's libraries ship `-tuned` names today. | N | package gate (device-code classifier NYI); `readelf -d`, `cuobjdump` | owner decision 2026-10-17 (`decisions/2026-10-17-shared-object-names-carry-their-axes.md`; supersedes decisions/2026-10-15-tuned-shared-object-suffix-hyphen for shared objects; revalidate 2027-10-15) |
| F2 | The package gate fails if a stock library name is NEEDED or any shared object is neither ours nor a recorded system library. | N | gate present | tuned-common helpers |
| F3 | Shipped executables carry the `-tuned` suffix (`llama-server-tuned`). | N that ship executables | tarball listing | practice (llama.cpp 6de6e9dac) |
| F4 | Wheels' shared objects follow F1 (torch's `libtorch_cuda` -> `libtorch_cuda-<variant>-<toolkit>.so`, its host-only libraries -> `-<toolkit>.so`; `librmm-<toolkit>.so`, `librapids_logger-<toolkit>.so`); the wheel's local version and build info carry the same variant and toolkit. A wheel that ships a library must also ship every `-<toolkit>`/`-<variant>-<toolkit>` library it NEEDS (the stock rapids-logger wheel carries the stock name). **NYI:** torch's libraries and the raft wheels still ship the stock names; every consumer linking torch by name is rebuilt, and its names change on every toolkit bump (todo list). Per-library classification for torch is to be measured with `cuobjdump`. | W, raft wheels | `readelf -d` and `cuobjdump` on the wheel's libraries | owner decisions 2026-10-16 (generic `-tuned`) and 2026-10-17 (axis rule, supersedes it; `decisions/2026-10-17-shared-object-names-carry-their-axes.md`) |

### G. Testing

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| G1 | `full_test.sh` runs the complete suite for one toolkit, against the artifacts it will ship, and writes a log in that toolkit's tree whose last summary line states pass or fail (a fixed phrase `release.sh` greps). Skips by design are named in the log header. | N, W | log exists, phrase present | practice (raft, cuvs, faiss, llama.cpp) |
| G2 | Tests resolve libraries from this toolkit only: the toolkit lib dir first on `LD_LIBRARY_PATH` (`gpu_tuned_verify_toolkit_libs`), nothing pip-installed into site-packages, and the mapped-library check for Python repos. | N, W | gate present | tuned-common README; faiss `full_test.sh` |
| G3 | A suite that is expensive or needs network still runs in full for a release. A narrower gate is a recorded decision, not a default. | All | log lists test count | user 2026-10-15 (llama.cpp ctest, all labels) |
| G5 | A package smoke test (`tuned/smoke_test.sh`) extracts the tarball and runs at least three real tests from the repo against the package's own libraries, after a sha256 check and, where there is a CMake package, a consumer configure. That the package's libraries are the ones running is proved, not assumed (`gpu_tuned_verify_resolves_in`, or the mapped libraries of an import). Its log is `SMOKE_RESULTS_<variant>.log`; **a pass needs positive evidence** (the run reached its end marker), so an abort cannot read as a pass. | N | log and marker present | user 2026-10-15 ("run 1-3 tests ... that the repackaged version is working"); raft, cuvs, faiss |
| G6 | A label-only change needs the same tested commit, mechanical proof that nothing but the label (and derived sections such as the build id) differs from the tested build, the package checks, a smoke test and the gates; not the full suite. Where the label is compiled in it is a fixed-width buffer and the proof is a section-by-section comparison of every ELF file (llama.cpp: `tuned/relabel.sh` + `tuned/elf_section_diff.py`, a valid `relabel.json` standing in for a test log newer than the build); where it is not, a repackage is the whole change. | N | `relabel.json` or a repackage | user 2026-10-15 ("a rebuild for label only just needs to pass gates and smoke test"); proven on 110 ELF files of llama.cpp |
| G4 | Numbers quoted in notes (counts, timings) come from the attached log and name what was skipped. | All | notes vs log | Provenance of Claims (global rules) |

### H. Packaging

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| H1 | `package.sh` writes a tarball, a `.sha256` sidecar and `package-info.txt` (tarball name, release tag, build identity, toolkit, variant), and checks the tarball as a consumer gets it (extract, checksum, NEEDED/`ldd`, RUNPATH `$ORIGIN`, toolkit libraries, reported version; for CMake packages, a consumer configure). | N | read `package.sh` | practice 2026-10-15; raft, cuvs |
| H2 | `package-info.txt` is removed first and written last, only if every package check passed. | N | read | practice 2026-10-15 |
| H3 | Build-info stamping and any rewrite (`patchelf`, `objcopy`) apply to **staged copies**, never to the build tree, so the build tree stays older than its test log. | N | build tree mtimes unchanged by packaging | found 2026-10-15 (llama.cpp) |
| H4 | A package check that cannot run is a failure, not a skip (a check that errors out silently passes nothing). Regexes use portable tools; a gate is proven by showing it fails on a bad input. | All | negative test recorded | found 2026-10-15 (llama.cpp RUNPATH `grep -P`) |
| H6 | `package.sh` refuses to package a build made from other source than HEAD: the commit the build (or its test log) records may differ from HEAD only in `tuned/`. | N | gate present | practice 2026-10-15 (raft: build-tree lib stamp; cuvs, faiss: test-log commit) |
| H7 | The shipped binaries carry the JSON build info (section 3, "Build info"): one line of strict JSON in `.tuned_build_info`, written with `gpu_tuned_embed_build_info_json` on the staged copies, readable with `gpu_tuned_read_build_info | jq`, verified after any rewrite (`gpu_tuned_verify_build_info_json`), and shipped as `BUILD_INFO.json` beside the binaries where the tarball is installed by a script. An artifact that is not an ELF (a static archive) carries the same object only as `BUILD_INFO.json`, written with `gpu_tuned_write_build_info_json`. The older free-text stamp is accepted until a repo migrates. | N, W | `jq .release` on a shipped binary | user 2026-10-15 ("semi json ... traceability"); llama.cpp migrated |
| H8 | A system library a package bundles must have the CUDA flavour of the toolkit it is for (`gpu_tuned_verify_bundled_cuda_flavor`: a `+cuda13.3` Debian package in a cu134 package is refused). NCCL for a toolkit with `TOOLKIT_NCCL_VERSION=none` comes from a pinned `zbrad/nccl` release (`tuned/nccl.pins`, `gpu_tuned_fetch_nccl_release`), linked statically, never from the host. | N | package gate present | found 2026-10-16 (llama.cpp cu134) |
| H9 | The packaging step audits the Python packages the wheel's metadata pulls in (`gpu_tuned_audit_deps`: pip resolves Requires-Dist in a throwaway venv, `pip-audit` checks the result). A known-vulnerable version that has a fixed release fails the package (a pin or bound is holding it back); one with no fix is a warning. `tuned/audit_allow.txt` accepts an advisory with a required reason, and each accepted id is printed. A check that cannot run (no network, resolver or pip-audit failure) is a failure (H4). It audits what ships, not upstream's CI, test or UI manifests. | W | `gpu_tuned_audit_deps` call present in the packaging script | user 2026-10-25 ("running the audit as a pre-package test"); Dependabot on a fork mostly reports upstream's non-shipped manifests |
| H10 | The packaging step checks the build venv's setuptools (`gpu_tuned_check_venv_setuptools <venv-dir>`): at least `GPU_TUNED_SETUPTOOLS_MIN`, read from the venv's own python. A wheel built in a reused venv that predates the minimum, or one never set up by `gpu_tuned_setup_build_venv`, fails the package, and the version is printed so the package log records it. | W | `gpu_tuned_check_venv_setuptools` call in the packaging script | user 2026-10-26; a reused venv skips the build-time install, so the build.sh check alone cannot prove the wheel's build venv |
| H5 | `package.sh` writes a DRAFT release-notes file if the tracked notes do not exist; it does not finalise them. | N | draft banner | practice 2026-10-15 |

### I. Release

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| I1 | `release.sh` gates, all reported together: clean tree and `HEAD` pushed; passing test log newer than the build artifacts (compared against the build tree, not staged copies); tarball newer than the test log; a passing smoke log newer than the tarball; `package-info.txt` for this toolkit; only the tracked release notes changed since the packaged commit; notes not a DRAFT. | N | read, run a dry run | practice 2026-10-15; raft, cuvs, faiss, llama.cpp |
| I2 | Release notes are a tracked file `tuned/releases/RELEASE_NOTES_<native tag without the leading v>.md` (`RELEASE_NOTES_0.20261015.0-gb10-cu133.md`), reviewed by the maintainer and committed before release; the DRAFT line is the gate. | N | file tracked | practice (raft, cuvs) |
| I3 | Publishing is `publish.sh` only, through `gpu_tuned_publish_ready` (which calls `gpu_tuned_publish_release`), attaching the tarball, its checksum, the notes, the test log and the smoke log. | N | read | tuned-common |
| I4 | A superseded release that is defective (not merely old) is deleted with its tag; the pins table says so. | raft, cuvs | pins table | practice 2026-10-15 |
| I5 | `release.sh` never publishes or tags: it runs the gates (`gpu_tuned_release_gates` plus any repo-specific ones) and, only if all pass, writes a ready-marker (`gpu_tuned_release_ready`); `publish.sh` publishes only from that marker and only while HEAD, the notes and every asset are unchanged (`gpu_tuned_publish_ready`), then marks it spent. | N | `tuned_compliance.sh` I5; `tests/test_common.sh` | user 2026-10-19 (three releases published by a `release.sh` run meant as a dry run) |

### J. Repository hygiene (global rules, listed so they are measured too)

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| J1 | Commits carry `Assisted-by: Claude`, never `Co-Authored-By:`. | All | `git log` trailers | global CLAUDE.md |
| J2 | Forks run no repo git hooks, and have Actions disabled when public (agent rule files: J5). | forks | `gh api .../actions/permissions`; hook dispatcher | global CLAUDE.md |
| J3 | No real hostnames in public repos or release notes (`geo-<g>-node-<variant>-<n>`). | All | grep | global CLAUDE.md |
| J4 | Docs describe the flow (`docs/.../release.md` or `tuned/README`) and are updated in the same slice as the scripts. | All | doc names the scripts that exist | practice |
| J5 | A fork tracks no agent rule file (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.claude/`, `.agents/`, `.cursor/`, `.cursorrules`, `.windsurfrules`, `.github/copilot-instructions.md`, `.mcp.json`) at a default-loaded path. Upstream's unmodified copies are `git mv`ed to `rules_advisory/<same relative path>`, ones changed locally to `rules_local/<same relative path>`; they are reference material and are named as upstream's when they inform work. `upstream-sync.sh merge --apply` re-moves any a merge brings back, by calling the dotfiles repo's `common/quarantine-instructions.sh` (a hard dependency; needs `DOTFILES_DIR`). | forks | `tuned_compliance.sh` J5 (`git ls-files` outside the two homes) | user 2026-10-20 |

### Build info

The identity of a shipped artifact must be readable from the artifact. One line of strict JSON in the ELF section
`.tuned_build_info` (and `BUILD_INFO.json` beside the files of a tarball an installer lays out), schema
`tuned-build-info/1`, keys in lower case, dotted names nesting:

| Field | Meaning |
|---|---|
| `release` | the identity: the native tag or wheel label (E2), first in the object |
| `package`, `component` | the project and the file stamped (`llama.cpp`, `llama-server-tuned`) |
| `variant`, `hardware`, `arch` | `gb10`, its release-title label, `sm_121a` |
| `cuda.tag`, `cuda.version`, `cuda.nvcc` | `cu133`, `13.3`, the exact nvcc (`13.3.73`) |
| `fork.url`, `fork.commit`, `fork.dirty`, `fork.commit_count` | this repo, the full 40-hex commit, tracked files differing from it, the repo-relative count (information only, E6) |
| `upstream.url`, `.ref`, `.base`, `.nearest_tag`, `.declared_version` | the declared upstream ref (null if undeclared), the merge-base, the nearest upstream tag with distance, the version upstream's source declares |
| `deps.*` | what the artifact bundles or was built from, per repo (llama.cpp: `deps.ui.name`, `.tarball_sha256`) |
| `built` | UTC time of stamping |

Not in it: the tarball's sha256 and the test results, which cannot exist before the artifact does; they live in
`package-info.txt` and the release. Writing is only through `gpu_tuned_build_info_json` (python3's `json`; never
hand-built); reading through `gpu_tuned_read_build_info`, which wraps a legacy text stamp as JSON so old artifacts
stay readable.

## 4. Applicability by repo (as understood 2026-10-15)

| Repo | Kind | Notes |
|---|---|---|
| raft, cuvs | N | RAPIDS chain: D1-D3 apply; wheel scripts exist beside the native flow (F4) |
| faiss | N | consumes cuvs; also builds a wheel (`wheel.sh`) |
| llama.cpp | N | has a source tag and a dry-run release (I5) |
| nccl | N | build/package/release scripts; not re-audited |
| ollama | N | consumes llama.cpp releases; own tags |
| pytorch, flash-attention, flash-attention-vllm, flashinfer, vllm | W | E1; B2 |
| ComfyUI, open-webui | D (NYI) | A and J today; no deployment exists to measure. When the first is built, the identity, pairing and release requirements apply to it: which dependency releases the deployment pins (D3), its own label (E), build info (H7) with the pinned releases under `deps`, a smoke test of the deployment as installed (G5), and the release gates (I). |

## 5. Identity, worked

```
HEAD committed 2026-10-15T23:40-07:00  ->  UTC date 20261016
no tag with date 20261016 yet            ->  label 20261016        (seq 0)
second build the same UTC date           ->  label 20261016.1      (seq 1)

native tag      v0.20261016.0-gb10-cu133        v0.20261016.1-gb10-cu133
tarball         <repo>-0.20261016.0-gb10-cu133.tar.gz
wheel version   2.15.0+gb10.cu133.20261016.0    2.15.0+gb10.cu133.20261016.1
```

The upstream version is not part of the identity. It may appear in the release title and notes
(`llama.cpp build 11258, base ...`), as information.

## 6. Measuring compliance

**Method.** For each repo, and for each requirement that applies, record PASS, FAIL, N/A or
UNKNOWN, with the evidence (command and output, or file and line). UNKNOWN is a result: it means
nobody has looked. A repo's score is passes over applicable requirements; the list of FAILs is
the work. The report is regenerated, not edited by hand.

**Tool.** `tools/tuned_compliance.sh <repo-path> [--online] [--kinds native,wheel]` prints the matrix
(ID, status, evidence), the date, and the commits of the repo and of tuned-common. Statuses:
PASS; FAIL; N/A (the requirement names a kind the repo does not ship); UNKNOWN (not looked at: the
check needs the network, `gh`, a GPU or a person); EXCEPTION (a recorded, reasoned deviation; it stands in for a FAIL, or for an UNKNOWN row that has no mechanical check);
ATTESTED (a person read it and said so). Without `--online` the checks that need `gh` or the network
are UNKNOWN. Exit 0 only with no FAIL and no UNKNOWN; 1 with any FAIL; 2 with UNKNOWN only. A repo
is called compliant only on exit 0 from an `--online` run.

**`tuned/compliance.conf`** (tracked in the repo, read by the tool; one record per line, `#` comments):

```
kinds: native wheel
exception: C2 | faiss keeps build_output/ + _build/; convergence deferred until raft and cuvs comply | 2026-10-17
attest: D1 | cuvs extracts into a directory named by the tag, read build.sh:79 | 2026-10-17 | <repo commit read>
```

An `exception:` or `attest:` line without a reason or a date is itself a FAIL. An exception is
a decision recorded, not a way to silence a check: the reason says why, and the date lets it be
reviewed. Attestations name the commit that was read; the tool reports ATTESTED only while that
commit is an ancestor of the repo's HEAD and the files the check reads are unchanged since (otherwise
UNKNOWN again). Requirements without a mechanical check in the tool are UNKNOWN until attested.

**Known gaps (2026-10-15; each verified in the session unless stated).** Compliance has not been measured; these
are what was already in view.

- **Fixed 2026-10-15:** raft, cuvs and faiss now publish date-label releases (`v0.20261015.0-gb10-cu133` and `-cu134` each, repackaged
  from the existing builds, smoke-tested as packaged); the old `v<ver>-<variant>-<cuda>-g<sha>` releases remain until deleted and
  their pins rows say superseded. The producer lookups (cuvs<-raft, faiss<-cuvs) rank by date label; the tag gate (E8) is in tuned-common.
- **E1, raft wheels:** `tuned/wheel.sh` and `tuned/raft_wheel_librmm_shared.sh` publish wheels under tags that are not date labels
  (`v<ver>-aarch64-cuda133-gb10`, `librmm-v...`). With a tuned-common that has the E8 gate they are refused until migrated.
- **E1, wheel repos:** the newest published wheels in the 2026-10-11 snapshot are in the counter form (`tuning.N`) (from
  `docs/upstream-vs-tuned-versions.json`; not re-checked).
- **E7 / consumers:** zbrad/ollama `scripts/precheck-tuned.sh` and `scripts/lib/llama-cpp-release.sh` match only
  `v<N>-<variant>-cu<N>` and will not see a date-label llama.cpp release. Recorded as a future todo.
- **llama.cpp:** done 2026-10-15: release label compiled in at build time (five-line patch to `common/build-info.cpp.in`, `--version`
  only), JSON build info (H7) with `BUILD_INFO.json`, `install.sh` fetching helper files from the release tag (no `tuning-*` source tag
  or pin), `install.sh`-based smoke test (G5), `relabel.sh` (G6), tuned-common synced (E8). Open: Patch B (NYI: a `release` field in
  `/props`), and that `--version` build is still the fork's commit count (E6: information only).
- **H7 elsewhere (NYI):** raft, cuvs and faiss still stamp the free-text form (raft's `package.sh` reads `@ <sha>` from it) and do not ship
  `BUILD_INFO.json`; the wheel repos stamp their own forms. Migrate one at a time with the reader changed first.
- **C2:** faiss and llama.cpp use their own trees (open). **F4:** decided 2026-10-16 (generic `-tuned` for wheels too), not yet implemented in torch or the raft wheels.
- **H6 is weaker where the build records no commit:** cuvs and faiss use the test log's commit, which proves what was tested, not what
  was built.
- **Not measured at all:** nccl, ollama, the wheel repos against B2/G/H/I, ComfyUI, open-webui (no deployments built yet).

## 7. Changing this document

A requirement changes only with a dated note here saying who decided it and why; a requirement
that a repo cannot meet is recorded as a deviation in that repo's docs, not by quietly dropping
the check. Add the check, or say why none exists. When tooling starts enforcing a requirement,
change its Check column to name the function.

**Decision log** (who decided, when, why):

- 2026-10-17, owner, after an independent (Opus) review of this document: (1) a same-date label collision
  fails the release gate and the maintainer repackages (E4); no auto-relabel, no reserving tag. (2) A check
  that cannot run is UNKNOWN and blocks "compliant" until run online or attested (section 6). (3) Applicability
  is per artifact kind (section 1). (4) C2 stays canonical with recorded exceptions for faiss and llama.cpp.
- 2026-10-17, review corrections of fact, no policy change: A2's check no longer names the removed
  `toolkits/DEFAULT`; I2 names the notes files as they exist; D1 states the property, not the marker file;
  A1 has no pin file (exceptions instead); the stale "omitted on wheel labels" text in `tuned-common.sh` and
  `upstream-vs-tuned-versions.json` now agrees with E1/E2.
- 2026-10-17, owner, during the raft/cuvs/faiss compliance work: (5) H1/I3 stand as written: the release attaches a
  `<tarball>.sha256` sidecar (the owner first chose to change H1 to "sha256 in package-info.txt", then reversed it
  on seeing that the release carried no checksum asset at all); raft, cuvs and faiss now write and attach it.
  (6) faiss's display-only `$(nproc)` was changed to `gpu_tuned_jobs`, not excepted (C5). (7) llama.cpp's
  `LLAMA_TUNED_BUILD_NUMBER` commit count is to be removed from its flow (E6); NYI.
- 2026-10-17, correction of my own record: the entries above and the C2/E4 rows were first dated 2026-10-16 in error
  (the decisions were made on 2026-10-17); they now say 2026-10-17.
- 2026-10-17, owner: (8) A7 added; the three local helpers moved into tuned-common.sh (the repos adopt them on their
  next sync).
- 2026-10-17, owner: (9) shared-object names carry the axes the library depends on: `-<variant>-<toolkit>` with
  device code, `-<toolkit>` without (F1/F4), superseding the generic `-tuned` suffix for shared objects; executables
  (F3) unchanged. Reason: librmm was measured on cu133 vs cu134 (no device code; exported symbols identical, code
  and shipped CCCL-typed headers differ), so it is variant-neutral but toolkit-bound; neutrality is not inferred
  from a NEEDED list. Nothing implemented. Details and costs: the decision file.
- 2026-10-17, owner: (10) the variant is transitive (F1): a library without device code that NEEDs a variant-named library
  also takes `-<variant>-<toolkit>` (so `libfaiss_c-gb10-cu133.so` stays, `libcuvs_c` becomes `libcuvs_c-gb10-cu133.so`),
  otherwise two variants' packages in one directory would collide on the wrapper's name while pointing at different libraries.
  Found by classifying the real libraries: `libcuvs_c` and `libfaiss_c` have no device code.
- 2026-10-17, owner: (11) NCCL is pinned per toolkit in a per-toolkit directory and never taken from the system package
  (`libnccl2` is one dpkg package and one file, resolved through the linker cache, so a flavour swap is silent; `apt` offered
  the cuda13.4 flavour over the installed cuda13.3 one). Each toolkit file will pin a `zbrad/nccl` release instead of
  `TOOLKIT_NCCL_VERSION` (A6, H8); NYI for cu133. Containers as the isolation mechanism are future work; for now paths and
  venvs. Details, steps and the NCCL 2.30.7 vs 2.31.2 version question: `decisions/2026-10-17-toolkit-nccl-pinned-per-toolkit-not-system.md`.
- 2026-10-18, owner: (12) a library's own version string names the variant, the toolkit and the release label: for NCCL
  `<nccl version>-<variant>-<toolkit>.<date>.<seq>` (was `-tuned`, which named neither, while the tag, tarball and BUILD_INFO did).
  The label is therefore allocated at build time and recorded (E4); the suffix change cost 5 ccache misses of 335 units, not a full rebuild.
  Applies to nccl now; the other native repos' libraries carry the variant and toolkit in their file names (F1) and their
  JSON build info, not in a version string of their own.
  NCCL itself appends `+cuda<major>.<minor>` after the suffix (upstream `src/init.cc`, also printed by NVIDIA's package); it repeated
  the toolkit in another spelling, and the owner decided (2026-10-18, after first leaving it) to drop it: a one-line patch in
  `src/init.cc` (marker `zbrad/nccl tuned-builds: version line`, in GPU_TUNED_FORK_MARKERS so a merge that loses it is refused). The
  library now prints exactly `NCCL version 2.32.3-gb10-cu134.20261018.0`; build, full_test and smoke_test require that exact line. NCCL's
  separate RAS status text ("compiled with CUDA 13.4") is left as upstream has it. It is a second fork patch in an upstream-tracked file,
  to be re-applied on each upstream update (the sync tool's marker check catches a loss).
- 2026-10-18, owner: (13) no variant level in the build tree. Asked whether raft and cuvs should regain one (so variants could build side by
  side), the owner decided against it: variants are unlikely to be built on the same hardware or build storage, so the layout is
  `<build>/<cuda>/{ccache, objects, tars, ...}` only. raft and cuvs already have that shape and do not change; faiss and llama.cpp (variant
  level) and nccl (per-commit `<describe>/` trees, which also accumulate) are to converge on it. This confirms the 2026-10-12 decision (`3cf4a64`),
  now with its reason recorded. NYI for those three repos.
- Review findings not yet acted on: the H5/I1/H6 sequence for committing the DRAFT
  notes is unspecified; ID order (G5, G6, G4; H6, H7, H8, H9, H5) is not numeric.
