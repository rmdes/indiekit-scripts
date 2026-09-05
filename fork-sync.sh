#!/usr/bin/env bash
# fork-sync.sh — merge upstream getindiekit/indiekit into a cut fork
#
#   fork-sync.sh <fork-dir> <upstream-pkg> [baseline-commit]
#
#   First sync of a fork (it has no shared history with upstream yet): pass the
#   upstream commit the fork was cut from. The script grafts the fork's root
#   commit onto the matching commit of `git subtree split -P packages/<pkg>`,
#   so the merge is a real 3-way merge. The graft ref is deleted afterwards;
#   the merge commit keeps the ancestry.
#
#   Later syncs: omit the baseline. The script re-runs the split, fetches it,
#   and merges. Fork-only changes are always `git diff upstream/main...main`.
#
#   Ends on branch `upstream-sync` with the merge committed (clean) or left in
#   conflict for you to resolve. Fast-forward to main after fork-verify.sh.
#
# Env: WORKSPACE (default ~/indiekit), UPSTREAM (default $WORKSPACE/indiekit-origin)
set -euo pipefail
WORKSPACE=${WORKSPACE:-$HOME/indiekit}
U=${UPSTREAM:-$WORKSPACE/indiekit-origin}
FORK=$WORKSPACE/$1; PKG=$2; BASE=${3:-}

[ -d "$U/packages/$PKG" ] || { echo "no packages/$PKG in $U"; exit 1; }
git -C "$U" fetch -q origin
[ "$(git -C "$U" rev-parse HEAD)" = "$(git -C "$U" rev-parse origin/main)" ] \
  || echo "WARN: $U is not at origin/main; the split will be of what is checked out"
git -C "$U" subtree split -P "packages/$PKG" -b "split/$PKG" -q >/dev/null

cd "$FORK"
git fetch -q origin
[ -z "$(git status --short --untracked-files=no)" ] || { echo "DIRTY working tree in $FORK"; exit 1; }
[ "$(git rev-list --count HEAD..origin/main)" = 0 ] || { echo "BEHIND origin/main — pull first"; exit 1; }
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$U"
git config remote.upstream.fetch "+refs/heads/split/$PKG:refs/remotes/upstream/main"
git fetch -q upstream

if ! git merge-base HEAD upstream/main >/dev/null 2>&1; then
  [ -n "$BASE" ] || { echo "no shared history yet: pass the baseline upstream commit"; exit 1; }
  # Match the split commit by tree hash, not by message or date
  BT=$(git -C "$U" rev-parse "$BASE:packages/$PKG")
  SPLIT=""
  for c in $(git rev-list upstream/main); do
    [ "$(git rev-parse "$c^{tree}")" = "$BT" ] && { SPLIT=$c; break; }
  done
  [ -n "$SPLIT" ] || { echo "no split commit matches tree of $BASE:packages/$PKG"; exit 1; }
  ROOT=$(git rev-list --max-parents=0 HEAD | tail -1)
  git replace --graft "$ROOT" "$SPLIT"
  echo "grafted root ${ROOT:0:8} onto split ${SPLIT:0:8} ($(git log -1 --format=%cs "$SPLIT"))"
fi

echo "merge-base $(git merge-base HEAD upstream/main | cut -c1-8) → upstream/main $(git rev-parse --short upstream/main); $(git rev-list --count HEAD..upstream/main) upstream commits to merge"
git checkout -q -B upstream-sync
if git merge --no-edit upstream/main >/dev/null 2>&1; then
  echo "MERGED CLEAN"
else
  echo "CONFLICTS (resolve, then git add + git commit --no-edit):"
  git diff --name-only --diff-filter=U
fi
for r in $(git replace -l); do git replace -d "$r" >/dev/null; done
