#!/usr/bin/env bash
set -euo pipefail

# reset-fork-to-upstream.sh
#
# DESTRUCTIVE: hard-resets a fork's `main` branch to match `upstream/main`.
# Use this when the fork-only commits have already been merged upstream
# (often under different SHAs) and you want to drop the duplicates.
#
# Usage:
#   reset-fork-to-upstream.sh [--push] [repo-path]
#   INDIEKIT_REPO=/path/to/fork reset-fork-to-upstream.sh [--push]
#
# If no path is given, defaults to the current working directory.
# With --push, the script force-with-lease pushes main to origin after reset.
#
# Requirements:
#   - fork repo must have an `origin` remote pointing at rmdes/indiekit
#   - fork repo must have an `upstream` remote pointing at getindiekit/indiekit
#   - working tree must be clean (commit or stash first)

PUSH=false
REPO_DIR="${INDIEKIT_REPO:-}"

for arg in "$@"; do
  case "$arg" in
    --push) PUSH=true ;;
    --help|-h)
      sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "ERROR: unknown flag: $arg" >&2
      exit 2
      ;;
    *)
      REPO_DIR="$arg"
      ;;
  esac
done

REPO_DIR="${REPO_DIR:-$PWD}"
if ! cd "$REPO_DIR" 2>/dev/null; then
  echo "ERROR: cannot cd to $REPO_DIR" >&2
  exit 1
fi

# Ensure we're in the right repo
REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
if [[ "$REMOTE_URL" != *"rmdes/indiekit"* ]]; then
  echo "ERROR: Not in the rmdes/indiekit fork ($REPO_DIR → origin: $REMOTE_URL)" >&2
  exit 1
fi

# Ensure upstream remote exists
if ! git remote get-url upstream &>/dev/null; then
  echo "ERROR: No 'upstream' remote in $REPO_DIR. Add it with:" >&2
  echo "  git -C $REPO_DIR remote add upstream https://github.com/getindiekit/indiekit.git" >&2
  exit 1
fi

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: Working tree in $REPO_DIR has uncommitted changes. Commit or stash first." >&2
  exit 1
fi

# Remember current branch
CURRENT_BRANCH=$(git branch --show-current)

echo "Fetching upstream..."
git fetch upstream

# Show what's new
NEW_COMMITS=$(git rev-list --count origin/main..upstream/main 2>/dev/null || echo 0)
if [[ "$NEW_COMMITS" -eq 0 ]]; then
  echo "Already up to date. origin/main matches upstream/main."
  exit 0
fi

echo ""
echo "New upstream commits ($NEW_COMMITS):"
git log --oneline origin/main..upstream/main
echo ""

# Check for fork-only commits that would be lost
FORK_COMMITS=$(git rev-list --count upstream/main..origin/main 2>/dev/null || echo 0)
if [[ "$FORK_COMMITS" -gt 0 ]]; then
  echo "WARNING: origin/main has $FORK_COMMITS commit(s) not in upstream:"
  git log --oneline upstream/main..origin/main
  echo ""
  read -rp "These will be REMOVED from main. Continue? [y/N] " confirm
  if [[ "$confirm" != [yY] ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# Reset main to upstream/main
git checkout main
git reset --hard upstream/main
echo ""
echo "main reset to upstream/main ($(git log --oneline -1))"

if [[ "$PUSH" == true ]]; then
  echo "Pushing to origin..."
  git push --force-with-lease origin main
  echo "Done. origin/main is now synced with upstream."
else
  echo ""
  echo "Local main is synced. To push, run:"
  echo "  git -C $REPO_DIR push --force-with-lease origin main"
  echo ""
  echo "Or re-run with: $(basename "$0") --push $REPO_DIR"
fi

# Return to original branch
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  git checkout "$CURRENT_BRANCH"
fi
