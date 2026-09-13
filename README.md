# indiekit-scripts

Operational scripts for managing an [Indiekit](https://getindiekit.com) development workspace with forked upstream packages.

## Script overview

| Script | Purpose |
|---|---|
| [`upstream-sync.sh`](#upstream-syncsh) | **Audit** — compare each `@rmdes/*` plugin fork against its upstream `packages/<name>/` counterpart and emit a Markdown sync report. Non-destructive. |
| [`reset-fork-to-upstream.sh`](#reset-fork-to-upstreamsh) | **Mirror** — hard-reset the full `rmdes/indiekit` fork's `main` branch to match `upstream/main`. Destructive; drops any fork-only commits. |
| [`fork-sync.sh`](#fork-syncsh) | **Sync** — merge upstream into a cut fork (`@rmdes/indiekit-endpoint-*` etc.) as a real git merge, grafting shared history the first time. Supersedes `upstream-sync.sh`'s tag bookkeeping. |
| [`fork-verify.sh`](#fork-verifysh) | **Verify** — run upstream's own test suite, typecheck (upstream CI gates on it since 2026-09-12), eslint and prettier against a fork by overlaying it into `indiekit-origin`, then restore. |
| `fork-resolve-conflicts.py`, `fork-resolve-package-json.py` | Helpers for resolving the merge conflicts `fork-sync.sh` leaves behind. |

## upstream-sync.sh

Compares your forked `@rmdes/*` packages against their upstream equivalents in the Indiekit monorepo. Generates a Markdown report with:

- **Summary table** — which forks are behind, how many commits/files changed
- **Upstream commits** — what changed since your last sync
- **Conflict risk** — files changed in both upstream and your fork (need careful merging)
- **Fork-only files** — your custom additions that upstream doesn't have (do not overwrite)
- **Fork modifications** — your custom patches to upstream files
- **Dependency drift** — version mismatches in `package.json`

### Requirements

- Bash >= 4.4
- git
- jq
- diff

### Setup

```bash
cp sync-state.example.json sync-state.json
```

Edit `sync-state.json` to set your paths:

- `upstream_repo` — path to your local clone of `getindiekit/indiekit`
- `workspace` — path to your workspace containing all fork repos
- `report_dir` — where reports are written

Adjust the `forks` entries to match your forked packages. Each fork needs:

- `upstream_package` — the package directory name under `packages/` in the upstream monorepo
- `last_synced_tag` — the upstream git tag your fork was last synced to

### Usage

```bash
# Generate a sync report
./upstream-sync.sh

# After syncing a fork, record the new baseline
./upstream-sync.sh --mark-synced indiekit-endpoint-auth v1.0.0-beta.28
```

The report is written to `$report_dir/upstream-sync-YYYY-MM-DD.md`.

### How it works

The script uses **tag-based tracking**. Each fork records the last upstream tag it was synced to. When you run the script, it diffs from that tag to upstream HEAD for each package subdirectory, then compares the fork's working tree against upstream HEAD to detect conflicts.

This approach works because the forks are standalone repos (not git forks with upstream remotes) — they mirror the contents of a `packages/<name>/` subdirectory from the Indiekit Lerna monorepo.

## reset-fork-to-upstream.sh

Hard-resets the `rmdes/indiekit` fork's `main` branch to match `upstream/main` (i.e. `getindiekit/indiekit`). Use this when upstream has absorbed your fork-only commits (often under new SHAs after upstream rebased or squashed), and you want to drop the stale duplicates so your fork mirrors upstream exactly.

> [!WARNING]
> This is destructive. Any commits on `main` that are not in `upstream/main` will be lost. The script prompts before proceeding if it detects fork-only commits.

### Requirements

- `origin` remote on the target repo points at `rmdes/indiekit`
- `upstream` remote on the target repo points at `getindiekit/indiekit`
- Working tree clean (commit or stash first)

### Usage

```bash
# From inside the fork repo
cd ~/code/indiekit-dev/indiekit
~/code/indiekit-dev/indiekit-scripts/reset-fork-to-upstream.sh            # local-only reset
~/code/indiekit-dev/indiekit-scripts/reset-fork-to-upstream.sh --push     # reset + force-with-lease push

# From anywhere, by passing the repo path
~/code/indiekit-dev/indiekit-scripts/reset-fork-to-upstream.sh --push ~/code/indiekit-dev/indiekit

# Or via environment variable
INDIEKIT_REPO=~/code/indiekit-dev/indiekit \
  ~/code/indiekit-dev/indiekit-scripts/reset-fork-to-upstream.sh --push
```

Without `--push` the script stops after the local reset and prints the exact push command for you to run manually.

## Cut forks: sync with upstream, verify, and send fixes back

The `@rmdes/indiekit-*` forks that were extracted from `indiekit-origin/packages/<pkg>/`
(endpoint-auth, endpoint-posts, endpoint-micropub, endpoint-syndicate, endpoint-files,
endpoint-share, frontend, preset-eleventy, syndicator-mastodon, syndicator-bluesky,
endpoint-webmention-io) are standalone repos. Since 2026-09-05 each one shares real git
history with upstream: its `upstream` remote points at `indiekit-origin` and fetches
`git subtree split -P packages/<pkg>` as `upstream/main`. That makes two things plain git:

- **Take upstream changes:** `git merge upstream/main` (what `fork-sync.sh` does).
- **See what the fork adds:** `git diff upstream/main...main` — the exact patch set to
  send upstream, with none of upstream's lint churn in it.

The forks are the **test bed**: a fix is written in the fork, published to npm, pinned in
`indiekit-cloudron`, deployed and exercised on a live site, and only then sent upstream as a
PR. Once the PR merges, the next sync pulls the upstream form of the fix back into the fork
and the fork-only diff shrinks by that much. Requirements: `bash`, `git`, `jq`, a Node 24
toolchain, and `indiekit-origin` with `node_modules` installed.

### fork-sync.sh

```bash
fork-sync.sh <fork-dir> <upstream-pkg> [baseline-commit]
```

- **First sync** of a fork (no shared history yet): pass the upstream commit it was cut
  from. Find it by diffing the fork's root commit against upstream history — the last
  upstream commit touching `packages/<pkg>` before the extraction date. The script grafts
  the fork's root commit onto the split commit with the identical tree, merges, and deletes
  the graft ref; the merge commit's second parent carries the ancestry from then on.
- **Every later sync:** omit the baseline. `fork-sync.sh indiekit-endpoint-share endpoint-share`.

It refuses to run on a dirty tree or a clone behind its own `origin/main` — always pull
first; forks are released from more than one machine. It ends on branch `upstream-sync`
with the merge either committed or in conflict.

Resolving conflicts, in the order they usually appear:

```bash
fork-resolve-package-json.py            # fork name/version, upstream dependencies
git checkout --theirs CHANGELOG.md      # upstream's changelog
git checkout --ours README.md           # the fork's README
git checkout upstream/main -- test      # if the fork had deleted upstream's tests
fork-resolve-conflicts.py lib/x.js ours theirs @fixed.txt   # one spec per conflict block
git add -A && git commit --no-edit
```

Merge policy: take upstream's lint, dependency and Node-version churn wholesale so future
diffs stay small; keep the fork's behaviour where it is deliberate; never let `git add -A`
sweep in `.claude/` or a lockfile (put them in `.git/info/exclude`).

### fork-verify.sh

```bash
fork-verify.sh <fork-dir> <upstream-pkg> [baseline]
```

Fork tests import `@indiekit-test/*` from the monorepo and cannot run standalone. The script
copies the fork's `lib`, `views`, `locales`, `test` (and the frontend's `components`,
`layouts`, `scripts`, `styles`) over `packages/<pkg>/` in `indiekit-origin`, runs that
package's suite with `NODE_ENV=test SECRET=test PASSWORD_SECRET=test`, then eslint and
prettier, and restores the pristine tree. `baseline` runs the untouched upstream suite
first so a failure can be attributed: same failure on baseline means the test is wrong,
new failure means the fork is. Some forks legitimately fail upstream tests where their
behaviour differs (endpoint-posts reads posts from MongoDB, endpoint-syndicate checks the
live site); those are documented in
`documentation-central/reports/2026-09-05-fork-upstream-sync.md`.

### After a sync

```bash
git checkout main && git merge --ff-only upstream-sync && git branch -d upstream-sync
npm version --no-git-tag-version <next>      # prerelease: 1.0.0-beta.N+1; stable: bump minor
git commit -am "chore: bump version to <next>" && git push origin main
# on the deploy laptop:
npm publish --tag beta && npm dist-tag add @rmdes/<pkg>@<next> latest   # prereleases
npm publish                                                             # stable versions
```

Then pin: the seven overridden defaults (auth, posts, micropub, syndicate, files, share,
frontend) in `indiekit-cloudron/package.json` → `overrides`; everything else in
`indiekit-plugin-registry/plugin-registry.yaml`. Rebuild each site.

### Sending a fix upstream

Never open the PR from the fork. Branch in `indiekit-origin` from `origin/main`, port the
hunk from `git diff upstream/main...main`, write the failing test first, run
`fork-verify.sh`-style checks on the package, then:

```bash
gh issue create -R getindiekit/indiekit …          # one issue per PR, source lines + repro
git push git@github.com:getindiekit/indiekit.git HEAD:<branch>
gh pr create -R getindiekit/indiekit --head <branch> …   # body: "Fixes #N"
```

A PR opened from `rmdes/indiekit` never runs upstream's tests (the Localazy secret is
withheld from fork PRs); one opened from a `getindiekit/indiekit` branch does.

## workspace-state.sh — what is open right now

One screen instead of fifteen tabs: open PRs across every `rmdes/indiekit-*` repo,
unusable `@indiekit/*` ranges, Renovate/CI coverage, and the upstream items we are
waiting on or blocking.

```bash
./workspace-state.sh            # PRs, ranges and upstream
./workspace-state.sh prs        # one section: prs | ranges | coverage | upstream
./workspace-state.sh coverage   # Renovate/CI/test matrix (slower, one API call per repo)
```

Everything is read from GitHub, never from a local clone — a clone can be several
releases behind its own `main` and will report state you have already fixed. That
bit us on `syndicator-bluesky`.

Reading the output:

- `UNSTABLE` on a Renovate PR is usually just the `minimumReleaseAge` stability gate,
  not a failure. Confirm with `gh pr checks <n> --repo rmdes/<repo>`.
- `head=rmdes` on an upstream PR means it was opened from the fork, so upstream CI
  never runs the tests. See "Sending a fix upstream" above.
- CI absent while tests exist is the dangerous row: a dependency PR reporting `CLEAN`
  there only means *no checks are configured*.

## check-peer-ranges.sh — find `@indiekit/*` ranges that cannot resolve

Upstream publishes only prereleases (`1.0.0-beta.N`), and an npm range does not match a
prerelease unless the range itself names one. So `"1.x"` can never be satisfied and a
fresh `npm install` dies with `ETARGET` — which is exactly how
`@rmdes/indiekit-syndicator-bluesky@1.1.0` shipped broken.

```bash
./check-peer-ranges.sh                     # every repo, read from GitHub
./check-peer-ranges.sh --local             # local clones instead
./check-peer-ranges.sh indiekit-endpoint-cv  # just one
```

Flags two cases: `BROKEN` (cannot match any published version) and `PINNED` (an exact
prerelease, so it never picks up newer betas).

**Choose the floor from what the package actually needs.** Most of ours declare
`>=1.0.0-beta.25`, but several also depend on `@indiekit/util@^1.0.0-beta.29` — that
floor advertises support for a release the code would break on. Check the package's own
`@indiekit/*` dependencies before copying a sibling's range.
