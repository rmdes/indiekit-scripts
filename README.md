# indiekit-scripts

Operational scripts for managing an [Indiekit](https://getindiekit.com) development workspace with forked upstream packages.

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
