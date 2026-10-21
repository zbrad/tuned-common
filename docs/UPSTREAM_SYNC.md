# Syncing a tuned fork with its upstream

How a tuned fork moves to a newer upstream point, and the tool that automates the safe
parts: `tools/upstream-sync.sh`. The reasoning comes from
[upstream-vs-tuned-versions.json](upstream-vs-tuned-versions.json) (how each upstream tags
and versions, a snapshot) and the real `plan` runs recorded below.

**The tool never runs `git push`, forces, deletes, or switches your branch.** `plan` changes
nothing. `merge` is a dry run unless `--apply`. The one remote change it makes is
`sync-default`'s server-side fast-forward of the fork's default branch (`gh repo sync`, never
`--force`); everything else only moves local refs.

## The model

Two things are called "sync", and they are separate:

1. **The mirror.** The fork's default branch (`main`/`master`) is kept a pure copy of
   upstream's. It exists so `git diff main..tuned-builds` shows only our work. It moves
   *fast-forward only*, **GitHub first, then local**: `gh repo sync` updates the fork's
   mirror on GitHub, then the local branch just pulls from `origin`. The fork's mirror is the
   authority and local only follows it, so local can never run ahead of it.
2. **The tuned branch** (`tuned-builds`) moves to a *named upstream point* by a merge: a
   stable **tag**, or a **pinned commit** of upstream's default branch.

### Why tags, and not "the release branch"

Seven of the ten upstreams cut releases on a branch that is not their default branch, so a
release tag is **not** an ancestor of main (vllm, pytorch, flashinfer, both flash-attentions,
cuvs, raft). Tags exist for every upstream; release branch names differ and for vllm I could
not find one. So the unit of sync is the tag. A patch release is just the next tag.

### A merge can only add commits

Merging `v2.14.1` into a branch that already carries 2.15-dev work does not make it 2.14.1;
it adds 45 cherry-picks to main. So a merge is only a valid "move to this release" when the
tag already contains everything we carry from upstream's default branch. The tool checks
exactly that (the **carry gate**). Where it fails, you have two real options:

- **Pin** an upstream-main commit (`--pin <sha>`): merge a specific, named point of main.
- **Rebuild on the tag** (manual, below): a cherry-pick rewrite of our commits, then a
  force-push. Not automated; each push needs your approval.

## Per-repo policy, from `plan --fetch` on 2026-10-11

| Repo | Strategy | Newest stable tag | Result today |
|---|---|---|---|
| llama.cpp | tag | v0.6.0 | **ready**: carry ok, gain 238 |
| ollama | tag | v0.40.3 | **ready**: carry ok, gain 229 |
| faiss | tag | v1.15.1 | already contained, nothing to merge |
| vllm | tag | v0.31.0 | carry ok (gain 514), **blocked by the counter-label rule** (~27 inflation) |
| flashinfer | tag | v0.7.1 | carry ok (gain 262), **blocked by the counter-label rule** (~49) |
| cuvs | pin (main alpha) | v26.10.00 | tag lacks 15 main commits; move together with raft and faiss |
| raft | pin (main alpha) | v26.10.00 | tag lacks 9 main commits; move together with cuvs and faiss |
| flash-attention | pin | v2.8.3.post1 | tag lacks 577 main commits; also counter-label |
| flash-attention-vllm | undecided | v2.6.2 | tag lacks only 20 (patch-aware; 1001 by sha: upstream rewrote main); also dirty tree + counter |
| pytorch | pin | v2.14.1 | tag lacks 1920 main commits; also dirty tree + counter |

Decisions this table does **not** settle (they are yours): pytorch's pin commit (needs a look
at which main-only commits GB10 depends on); whether cuvs/raft/faiss move together to the
26.12 line or stay on a pin; flash-attention-vllm's tag-versus-pin.

### The counter-label rule

Repos whose wheel label still comes from `git rev-list --count main..HEAD` count a release
tag's cherry-picks as "ours", because they are in neither `main` nor `upstream/main`.
`gpu_tuned_check_main_current` does not notice. The tool refuses a release-branch tag merge in
such a repo until its label is migrated to the date form (`docs/VERSIONING.md`). Override:
`--allow-counter-release-tag`, with the inflation printed.

## Procedure for one repo

Do this on the repo's owner node (tracked changes are made only there; see your fleet
ownership list). Replace `<repo>` and the options with the repo's row above.

```bash
T=~/gh/tuned-common/tools/upstream-sync.sh

# 1. Look first. Fetches the default branch and the stable tags, changes nothing else.
$T plan --repo ~/gh/<repo> --fetch [--default-branch master] [--tag-re REGEX]

# 2. Refresh the mirror: the fork on GitHub first (gh repo sync), then local pulls from origin.
#    All local checks run before anything is changed; the GitHub hop is a fast-forward only.
$T sync-default --repo ~/gh/<repo>          # --no-remote skips GitHub and follows upstream directly

# 3. Dry-run the merge, then do it.
$T merge --repo ~/gh/<repo> --tag vX.Y.Z            # or --pin <sha>
$T merge --repo ~/gh/<repo> --tag vX.Y.Z --apply

# 4. Build and verify (the repo's own build and release scripts), then push with approval.
```

`merge --apply` does, in order: refuses unless the tree is clean and you are on the tuned
branch; creates `tuned-builds-backup-<date>`; `git merge --no-ff --no-commit <tag>`; checks the
fork markers; commits only if they pass. It then runs the dotfiles repo's
`common/quarantine-instructions.sh --apply` on the result, which moves any agent rule file the
merge brought back to `rules_advisory/` or `rules_local/` in a commit of its own (J5). That script
is a hard dependency: `merge --apply` exits 2 before changing anything if `DOTFILES_DIR` is unset
or the script is missing. It then prints the stamp base, which reads
`nearest <tag>+0` because the upstream ref is now the tag itself. It never pushes.

### Default branch of a quarantined fork (decided 2026-10-21)

A fork's published default branch must not ship upstream's agent rule files, so it carries a
quarantine commit and is no longer a pure mirror. Sync it the way `tuned-builds` is synced:

```bash
$T merge --repo ~/gh/<repo> --branch <default> --pin upstream/<default> --apply   # merge, then quarantine
# push <default> to origin with approval; gh repo sync would refuse (the fork has its own commits)
```

`sync-default` refuses such a branch (exit 4) and says so. After the quarantine, `merge --apply`
puts a fork notice at the top of `README.md` (marker `<!-- fork-notice -->`, own commit,
added once); a repo without `README.md` is told to add it by hand. If upstream edits the README's
first lines the merge conflicts there: keep both and re-run to restore the notice.

### The gates, and the exit status

| Exit | Meaning |
|---|---|
| 0 | ok (or nothing to do) |
| 1 | usage, or not a fork |
| 2 | preflight: dirty tracked tree, not on the tuned branch, or a merge already in progress; for `sync-default`: `gh` missing or not authenticated, or the checked-out branch is the default branch |
| 3 | merge conflict. The merge is **left in progress**; resolve and commit, or `git merge --abort`. Then re-check the fork markers on the resolved tree by hand |
| 4 | a gate refused: the carry gate, the counter-label rule, a pin that is not upstream's, a tag not matching the stable pattern, a stale local tag; for `sync-default`: a diverged local mirror, a fork mirror that is not a pure ancestor of upstream, or a GitHub parent that is not the upstream remote |
| 5 | a fork marker was lost. The merge is **staged but not committed** |

- **Carry gate:** every commit on upstream's default branch that `HEAD` carries must be in
  the target, compared by patch (so a release branch's cherry-pick of a main fix counts as the
  same commit). Release-only commits of an earlier tag (version bumps) are not counted: they
  are superseded, not lost.
- **Pin gate:** a pin must be an ancestor of the upstream ref.
- **Stale tags:** `plan` asks upstream for its newest stable tag and warns when the fetched
  one is older; `--apply` refuses on a stale tag. Re-run with `--fetch`.
- **`sync-default` checks** (all before the GitHub hop, so a refusal changes nothing): the local
  default branch is only behind upstream's (never ahead or diverged) and is not the checked-out
  branch; `origin/<default>` is an ancestor of `upstream/<default>` (a pure mirror: a fork's own
  commits make a fast-forward sync impossible, and `--force` is never used); and GitHub's
  recorded parent of the fork is the same repository as the `upstream` remote, compared by
  repository **id** (names change: `rapidsai/cuvs` is now `NVIDIA/cuvs`, same id). If upstream
  moves between GitHub's sync and the local pull, it says so and the mirror is one sync behind.
- **Fork markers:** `--markers a,b` (default `gpu_tuned_`). For each, the line count in the
  merged index must not fall below its count before the merge. Add the strings your fork
  keeps in upstream-owned files (seed list from past incidents: `_wheel_kind`,
  `gb10_build`, `tuning_count`, `gpu_tuned_`). This exists because git has silently dropped
  fork-local code outside the marked conflict region on large merges (flashinfer and vllm,
  2026-09-18). A clean merge is not evidence nothing was lost.

### Settings

CLI flag, or the environment variable (later: keys in each repo's `tuned/repo.env`):

| Flag | Variable | Default |
|---|---|---|
| `--default-branch` | `GPU_TUNED_UPSTREAM_DEFAULT_BRANCH` | `upstream/HEAD`, else asked of the upstream remote |
| `--upstream-ref` | `GPU_TUNED_UPSTREAM_REF` | `upstream/<default-branch>` |
| `--tag-re` | `GPU_TUNED_UPSTREAM_TAG_RE` | `^v[0-9]+\.[0-9]+\.[0-9]+$` |
| `--tag-glob` | `GPU_TUNED_UPSTREAM_TAG_GLOB` | `v*` (used only to choose which tags to fetch; never `--tags`: pytorch has about 12,000 CI tags) |
| `--markers` | `GPU_TUNED_FORK_MARKERS` | `gpu_tuned_` |

Per-repo patterns used above: flash-attention `^v[0-9]+(\.[0-9]+)+(\.post[0-9]+)?$`,
flash-attention-vllm `^v2\.[0-9.]+(\.post[0-9]+)?$`, cuvs/raft `^v[0-9]{2}\.[0-9]{2}\.[0-9]{2}$`,
faiss `^v1\.[0-9]+\.[0-9]+$`; default branch `master` for llama.cpp.

## Manual: rebuilding the tuned branch on a tag (not automated)

For a repo whose carry gate fails and where you decide the release is the right base
(a possible fate of pytorch, flash-attention, flash-attention-vllm). This rewrites
`tuned-builds` history and needs a force-push, so every step that touches a remote needs your
explicit approval, as the 2026-09-22 rewrite did.

1. `plan` shows which main commits the tag lacks. Decide that you can live without them (or
   that the tuned work does not depend on them).
2. Back up: `git branch tuned-builds-backup-<date> tuned-builds`.
3. List our own commits (those no upstream ref or stable tag contains):
   `git rev-list --reverse --no-merges tuned-builds --not --remotes=upstream <the stable tags>`.
4. `git switch -c tuned-builds-new <tag>`, then `git cherry-pick` those commits; resolve
   conflicts; check the fork markers by hand across the whole tree (grep, do not trust "no
   conflict").
5. Build and verify. Only then rename `tuned-builds-new` over `tuned-builds`, and push with
   `--force-with-lease` after approval.

## Prerequisites still open

- **Counter-label migration** for vllm, flashinfer, flash-attention, flash-attention-vllm and
  pytorch (their `setup.py`/`wheel.sh` still build `tuning.N`): until done, none of them can
  take a release-branch tag through this tool.
- **Dirty trees:** pytorch (4 tracked files in `tuned/`) and flash-attention-vllm (a submodule
  pointer) fail preflight. Commit or restore them first.
- **Per-repo settings** are not yet in each repo's `tuned/repo.env`; that is a tracked change
  in ten repos and a separate step.
