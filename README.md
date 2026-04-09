# indiekit-scripts

Operational scripts for managing an [Indiekit](https://getindiekit.com) development workspace with forked upstream packages.

## Script overview

| Script | Purpose |
|---|---|
| [`upstream-sync.sh`](#upstream-syncsh) | **Audit** — compare each `@rmdes/*` plugin fork against its upstream `packages/<name>/` counterpart and emit a Markdown sync report. Non-destructive. |
| [`reset-fork-to-upstream.sh`](#reset-fork-to-upstreamsh) | **Mirror** — hard-reset the full `rmdes/indiekit` fork's `main` branch to match `upstream/main`. Destructive; drops any fork-only commits. |

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
