#!/usr/bin/env bash
# Fast-forward pull every git repo in a directory. New repos are picked up
# automatically — discovery is a glob, there is no list to maintain.
#
# Usage: pull-all.sh [dir]   (default: current directory)
set -uo pipefail

root=${1:-.}
cd "$root" || exit 1

if [ -t 1 ]; then
  ok=$'\e[32m'; warn=$'\e[33m'; bad=$'\e[31m'; dim=$'\e[2m'; off=$'\e[0m'
else
  ok=; warn=; bad=; dim=; off=
fi

pulled=0 skipped=0 failed=0

for dir in */; do
  repo=${dir%/}
  # .git is a dir in normal repos, a file in submodules/worktrees.
  [ -e "$repo/.git" ] || continue

  branch=$(git -C "$repo" symbolic-ref --short -q HEAD) || {
    printf '%s- %-38s detached HEAD%s\n' "$warn" "$repo" "$off"
    skipped=$((skipped + 1)); continue
  }

  if ! git -C "$repo" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
    printf '%s- %-38s no upstream (%s)%s\n' "$warn" "$repo" "$branch" "$off"
    skipped=$((skipped + 1)); continue
  fi

  # ponytail: tracked changes only. Untracked files can't break a fast-forward,
  # and if an incoming commit adds that same path git aborts on its own.
  if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
    printf '%s- %-38s uncommitted changes%s\n' "$warn" "$repo" "$off"
    skipped=$((skipped + 1)); continue
  fi

  before=$(git -C "$repo" rev-parse HEAD)
  if out=$(git -C "$repo" pull --ff-only --quiet 2>&1); then
    after=$(git -C "$repo" rev-parse HEAD)
    if [ "$before" = "$after" ]; then
      printf '%s  %-38s up to date%s\n' "$dim" "$repo" "$off"
    else
      printf '%s✓ %-38s %s..%s%s\n' "$ok" "$repo" "${before:0:7}" "${after:0:7}" "$off"
      pulled=$((pulled + 1))
    fi
  else
    printf '%s✗ %-38s %s%s\n' "$bad" "$repo" "${out//$'\n'/ }" "$off"
    failed=$((failed + 1))
  fi
done

printf '\n%d pulled, %d skipped, %d failed\n' "$pulled" "$skipped" "$failed"
[ "$failed" -eq 0 ]
