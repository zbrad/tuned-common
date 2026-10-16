# Tuned build and versioning architecture

The one design every repo in the tuned-builds fleet is measured against. Each requirement has an
ID, says what a repo MUST do, which repos it applies to, and how to check it. A repo's compliance
is the list of requirement IDs it passes, fails, or does not apply to, each with evidence.

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
  flash-attention-vllm, flashinfer). **consumer**: installs a tuned artifact and builds
  nothing of its own to publish (ComfyUI, open-webui). Applicability below uses these words.
- **label**: `<YYYYMMDD>[.<seq>]`, the build identity (section 5).
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

Legend: **N** native, **W** wheel, **C** consumer, **All** every repo with a `tuned/` directory.

### A. Vendoring and shared data

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| A1 | `tuned/common.sh`, `tuned/sync-common.sh` and `tuned/common.sh.sha` are tracked, and `tuned/sync-common.sh check` exits 0 (the vendored copy is tuned-common's current `main`, or a pin the repo states). | All | run the check | README, "Keeping a vendored copy in sync" |
| A2 | `tuned/common-data/` is vendored (devices, toolkits, `toolkits/DEFAULT`), refreshed by the same sync; the repo's own `sync-common.sh` is current (an old one skips new data files such as `DEFAULT`). | All | `diff tuned/sync-common.sh <tuned-common>/sync-common.sh`; `ls tuned/common-data/toolkits/DEFAULT` | README; found 2026-10-15 |
| A3 | `tuned/env.sh` sources `common.sh`, asserts the platform, loads the toolkit with `gpu_tuned_load_toolkit` and verifies it (`gpu_tuned_verify_toolkit`), and loads repo settings with `gpu_tuned_load_repo_env` from `tuned/repo.env`. | All | read `env.sh` | README |
| A4 | `tuned/repo.env` only adds repo-specific keys; it never sets a device, toolkit or `CUDA_*` value. | All | `gpu_tuned_load_repo_env` fails loudly on any such key | README |
| A5 | The ERR trap is left on (`GPU_TUNED_NO_ERR_TRAP` unset). | All | grep | VERSIONING.md |

### B. Entry points and stage order

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| B1 | A native repo provides `tuned/build.sh`, `tuned/full_test.sh`, `tuned/package.sh`, `tuned/smoke_test.sh` and `tuned/release.sh`, each taking `<variant>` and selecting the toolkit by `CUDA_TAG`/`CUDA_VER`, else `toolkits/DEFAULT`. | N | `ls`; run each with no args and read the usage | practice 2026-10-15 (raft, cuvs, faiss, llama.cpp) |
| B2 | A wheel repo provides a wheel build script, a full test script and a release script with the same stage order and gates (E, G, I apply). | W | `ls` | practice; wheel scripts predate this, compliance unmeasured |
| B3 | The order is build, test, package, smoke test, (review and commit notes), release. `release.sh` never builds, tests or packages; `package.sh` never tags, publishes or finalises notes. | N | read both scripts; `grep -n 'gh release\|git tag' package.sh` is empty | practice 2026-10-15; requested by the user 2026-10-15 ("split packaging and release") |
| B4 | No stage selects a toolkit from `/usr/local/cuda` or from what is installed. | All | grep for `/usr/local/cuda\b` outside `toolkits/*.env` | README |

### C. Layout and isolation

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| C1 | Each toolkit (and variant, where trees would otherwise mix) has its own build tree, tarball directory and test log. | N, W | the paths contain the cuda tag | `gpu_tuned_cuda_subdir` header |
| C2 | The canonical tree is `tuned/build/<cuda-tag>/` from `gpu_tuned_out_dir` (`cmake/`, `dist/`, `releases/`, `ccache/`), with a variant claim (`gpu_tuned_claim_toolkit_tree`). A repo that cannot use it records why and its layout in its docs. **Open:** faiss uses `build_output/` + `_build/` and llama.cpp `build-tuned/<cuda>/<variant>/`; whether to converge is undecided. | N | path check; `docs` records any deviation | `gpu_tuned_out_dir` header; deviations observed 2026-10-15 |
| C3 | Before configuring, an existing CMake cache is checked against the toolkit's nvcc and the source tree; a mismatch fails and names the directory to remove. | N | read `build.sh` | practice (cuvs `env.sh`, llama.cpp `build.sh`) |
| C4 | ccache is per toolkit (`CCACHE_DIR` inside the toolkit tree) with an explicit size. | N | grep `CCACHE_DIR` | practice (cuvs, llama.cpp) |
| C5 | Default build parallelism is `gpu_tuned_jobs` (largest prime <= nproc-2); an environment override wins. | All | grep: no bare `$(nproc)` as a default | rollout 2026-10-15 |
| C6 | Tuned builds never write to the repo's everyday dev build directory (the one local services may run). | N | path check | practice 2026-10-15 (llama.cpp `build/`) |
| C7 | Pip-installed CMake packages (RAPIDS wheels, nvtx3) are kept out of native builds (`gpu_tuned_cmake_ignore_pip_prefixes`) and the configured cache is checked (`gpu_tuned_verify_no_pip_cmake_deps`). | N that build against RAPIDS | read `build.sh` | tuned-common commits 72430ce, c928ac7 |

### D. Dependencies on other tuned repos

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| D1 | A consumer of another tuned repo's tarball fetches that repo's newest release (`gpu_tuned_newest_release_tag`: the highest date label, ranked as numbers, never list order; an older-form tag only as a noted fallback) and re-fetches whenever the newest tag differs from the one it unpacked (marker file); a stale unpacked copy is never reused silently. | N consuming N (cuvs<-raft, faiss<-cuvs) | `.release_tag` marker present and compared | faiss bug found 2026-10-15 |
| D2 | The dependency's package must carry everything its CMake config needs (nvtx3 included); the packager proves it with a consumer configure against the package alone (`gpu_tuned_verify_consumer_configure`). | N that ship a CMake package | package-time gate present | tuned-common 3b5f4d0 |
| D3 | The producer->consumer pairing is recorded and test-run (`tuned/docs/RELEASE_PINS.md` for the RAPIDS chain), including which releases are superseded or deleted. | raft, cuvs | file present, row per release | practice |

### E. Identity and versioning

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| E1 | A wheel carries `<public version>+<variant>.cu<cuda>.<YYYYMMDD>[.<seq>]`, built only by `gpu_tuned_local_version_dated`/`gpu_tuned_build_local_version`, never by hand. The public version is upstream's. | W | `gpu_tuned_date_label` parses the wheel name | VERSIONING.md (user decision 2026-10-11) |
| E2 | A native release tag is `v0.<YYYYMMDD>.<seq>-<variant>-<cuda-tag>` (the sequence always written, `0` for the first), built by `gpu_tuned_native_tag`. | N | `gpu_tuned_date_label <tag>` returns a label | VERSIONING.md; `docs/upstream-vs-tuned-versions.json` `scheme.native_tag`; user 2026-10-15 ("back to UTC dates ... build count per date") |
| E3 | The date is the UTC committer date of the tuned `HEAD` (`gpu_tuned_head_date`); the sequence is the lowest unused for that date among the repo's tags (`gpu_tuned_allocate_date_label`). Never the wall clock, never a commit count or a sha. | All | read the label source | VERSIONING.md |
| E4 | The label is allocated once, at the earliest stage that bakes it into an artifact, and recorded in a file the later stages read: `package-info.txt` for native tarballs whose identity is stamped at packaging (raft, cuvs, faiss), `<build>/release-label` for llama.cpp, whose label is compiled into the binary at build time, and the wheel script for wheels. Later stages never recompute it (a notes commit moves `HEAD` and its date). Nothing reserves a label before publish, so the full commit stays in the build info and the release gate checks the tag is free. | N, W | the recorded file; `release.sh` reads it | practice 2026-10-15 (llama.cpp, user: "build info ... release version more relevant") |
| E5 | Tag, tarball name, release title, notes file name and the artifact's own metadata show the same label. | All | compare | VERSIONING.md |
| E6 | A commit count may be reported and checked, but identifies nothing: it is repo-relative (llama.cpp's `--version` "build N" is this fork's history count, not upstream's) and rises with every commit. It appears only as `fork.commit_count` in the build info. | All | grep `rev-list --count` outside a version check | user 2026-10-15; decisions/2026-09-10 superseded |
| E7 | Releases published in an older form are not renamed (consumers pin URLs). Consumers accept both forms and rank any date-label tag above an older one. | All | consumer tag parsers | VERSIONING.md; practice 2026-10-15 (llama.cpp `install.sh`) |
| E8 | Tooling refuses a wrong identity before `gh`: `gpu_tuned_publish_release` checks every release tag (`gpu_tuned_check_release_tag`: a native or wheel date label, else refused) and every `.whl` asset's label. `GPU_TUNED_ALLOW_COUNTER_LABEL=1` lets a not-yet-migrated repo publish an older form, loudly. | All | `tests/test_common.sh` (release_tag, publish_release cases) | tuned-common d17e0f9, 2026-10-15 |

### F. Names that cannot collide with stock

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| F1 | Every shared object we ship has a unique `-tuned` name, SONAME and NEEDED entries (`gpu_tuned_rename_package`), with the hyphen form `lib<name>-tuned.so`. | N | package gate; `readelf -d` | decisions/2026-10-15-tuned-shared-object-suffix-hyphen (revalidate 2027-10-15) |
| F2 | The package gate fails if a stock library name is NEEDED or any shared object is neither ours nor a recorded system library. | N | gate present | tuned-common helpers |
| F3 | Shipped executables carry the `-tuned` suffix (`llama-server-tuned`). | N that ship executables | tarball listing | practice (llama.cpp 6de6e9dac) |
| F4 | Wheels' shared objects: the plain `librmm-cu13` style names in the raft wheel scripts are **undecided**. | raft wheels | decision pending | handoff 2026-10-14 |

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
| H7 | The shipped binaries carry the JSON build info (section 3, "Build info"): one line of strict JSON in `.tuned_build_info`, written with `gpu_tuned_embed_build_info_json` on the staged copies, readable with `gpu_tuned_read_build_info | jq`, verified after any rewrite (`gpu_tuned_verify_build_info_json`), and shipped as `BUILD_INFO.json` beside the binaries where the tarball is installed by a script. The older free-text stamp is accepted until a repo migrates. | N, W | `jq .release` on a shipped binary | user 2026-10-15 ("semi json ... traceability"); llama.cpp migrated |
| H5 | `package.sh` writes a DRAFT release-notes file if the tracked notes do not exist; it does not finalise them. | N | draft banner | practice 2026-10-15 |

### I. Release

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| I1 | `release.sh` gates, all reported together: clean tree and `HEAD` pushed; passing test log newer than the build artifacts (compared against the build tree, not staged copies); tarball newer than the test log; a passing smoke log newer than the tarball; `package-info.txt` for this toolkit; only the tracked release notes changed since the packaged commit; notes not a DRAFT. | N | read, run a dry run | practice 2026-10-15; raft, cuvs, faiss, llama.cpp |
| I2 | Release notes are a tracked file `tuned/releases/RELEASE_NOTES_<label>_<variant>_<cuda>.md`, reviewed by the maintainer and committed before release; the DRAFT line is the gate. | N | file tracked | practice (raft, cuvs) |
| I3 | Publishing goes through `gpu_tuned_publish_release`, attaching the tarball, its checksum, the notes, the test log and the smoke log. | N | read | tuned-common |
| I4 | A superseded release that is defective (not merely old) is deleted with its tag; the pins table says so. | raft, cuvs | pins table | practice 2026-10-15 |
| I5 | `release.sh` runs without publishing unless told (`--publish`) where the release has a second remote effect (a source tag). | N with a source tag (llama.cpp) | read | llama.cpp |

### J. Repository hygiene (global rules, listed so they are measured too)

| ID | Requirement | Applies | Check | Source |
|---|---|---|---|---|
| J1 | Commits carry `Assisted-by: Claude`, never `Co-Authored-By:`. | All | `git log` trailers | global CLAUDE.md |
| J2 | Forks run no repo git hooks, have Actions disabled when public, and an upstream's agent rule files are never loaded. | forks | `gh api .../actions/permissions`; hook dispatcher | global CLAUDE.md |
| J3 | No real hostnames in public repos or release notes (`geo-<g>-node-<variant>-<n>`). | All | grep | global CLAUDE.md |
| J4 | Docs describe the flow (`docs/.../release.md` or `tuned/README`) and are updated in the same slice as the scripts. | All | doc names the scripts that exist | practice |

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
| ComfyUI, open-webui | C | A and J only |

## 5. Identity, worked

```
HEAD committed 2026-10-15T23:40-07:00  ->  UTC date 20261016
no tag with date 20261016 yet            ->  label 20261016        (seq 0)
second build the same UTC date           ->  label 20261016.1      (seq 1)

native tag      v0.20261016.0-gb10-cu133        v0.20261016.1-gb10-cu133
tarball         <repo>-0.20261016.0-gb10-cu133.tar.gz
wheel version   2.15.0+gb10.cu133.20261016      2.15.0+gb10.cu133.20261016.1
```

The upstream version is not part of the identity. It may appear in the release title and notes
(`llama.cpp build 11258, base ...`), as information.

## 6. Measuring compliance

**Method.** For each repo, and for each requirement that applies, record PASS, FAIL, N/A or
UNKNOWN, with the evidence (command and output, or file and line). UNKNOWN is a result: it means
nobody has looked. A repo's score is passes over applicable requirements; the list of FAILs is
the work. The report is regenerated, not edited by hand.

**Tool (not yet written).** `tools/tuned_compliance.sh <repo-path>` would run the mechanical
checks above (A1, A2, B1, B3, C5, E2 for the newest release tag, E6, H1 presence, I1 presence, J1
trailers) and print the matrix; the rest need a person to read the script and say so. Until it
exists the matrix is built by hand, and the date and commit it was built at are recorded.

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
  or pin), `install.sh`-based smoke test (G5), `relabel.sh` (G6), tuned-common synced (E8). Open: the Patch B idea (a `release` field in
  `/props`), and that `--version` build is still the fork's commit count (E6: information only).
- **H7 elsewhere:** raft, cuvs and faiss still stamp the free-text form (raft's `package.sh` reads `@ <sha>` from it) and do not ship
  `BUILD_INFO.json`; the wheel repos stamp their own forms. Migrate one at a time with the reader changed first.
- **C2:** faiss and llama.cpp use their own trees (open). **F4:** undecided.
- **H6 is weaker where the build records no commit:** cuvs and faiss use the test log's commit, which proves what was tested, not what
  was built.
- **Not measured at all:** nccl, ollama, the wheel repos against B2/G/H/I, ComfyUI, open-webui.

## 7. Changing this document

A requirement changes only with a dated note here saying who decided it and why; a requirement
that a repo cannot meet is recorded as a deviation in that repo's docs, not by quietly dropping
the check. Add the check, or say why none exists. When tooling starts enforcing a requirement,
change its Check column to name the function.
