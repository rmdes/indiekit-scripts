#!/usr/bin/env bash
#
# check-peer-ranges.sh — find @indiekit/* version ranges that cannot resolve.
#
# Upstream publishes only prereleases (1.0.0-beta.N). An npm range does NOT match
# a prerelease unless the range itself names one, so a range like "1.x" can never
# be satisfied and a fresh `npm install` fails with ETARGET:
#
#     semver.satisfies("1.0.0-beta.29", "1.x")             === false
#     semver.satisfies("1.0.0-beta.29", ">=1.0.0-beta.25") === true
#     semver.satisfies("1.0.0-beta.29", "1.0.0-beta.25")   === false   (exact pin)
#
# Reads package.json from each repo's default branch on GitHub, NOT from the local
# clone — local clones go stale and will report a range you have already fixed.
#
# Usage:
#   ./check-peer-ranges.sh              # every rmdes/indiekit-* repo
#   ./check-peer-ranges.sh --local      # local clones under ~/indiekit instead
#   ./check-peer-ranges.sh repo [repo…] # just these repos
#
# Requires: gh (authenticated), node.
set -uo pipefail

WORKSPACE="${INDIEKIT_WORKSPACE:-$HOME/indiekit}"
MODE=github
REPOS=()

for arg in "$@"; do
  case "$arg" in
    --local) MODE=local ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) REPOS+=("$arg") ;;
  esac
done

if [ ${#REPOS[@]} -eq 0 ]; then
  if [ "$MODE" = github ]; then
    mapfile -t REPOS < <(gh repo list rmdes --limit 200 --json name --jq '.[].name' | grep -E '^indiekit' | sort)
  else
    mapfile -t REPOS < <(cd "$WORKSPACE" && ls -d indiekit-*/ 2>/dev/null | tr -d '/' | sort)
  fi
fi

# A range is usable only if it names a prerelease AND is open-ended (^ ~ >=).
# An exact "1.0.0-beta.25" resolves, but pins you to one old release, so flag it too.
read -r -d '' CLASSIFY <<'NODE'
let s="";
process.stdin.on("data", d => s += d).on("end", () => {
  const repo = process.argv[1];
  let p; try { p = JSON.parse(s); } catch { console.log(`  ${repo.padEnd(42)} MANIFEST UNREADABLE`); return; }
  const rows = [];
  for (const field of ["peerDependencies", "dependencies", "devDependencies"]) {
    for (const [name, range] of Object.entries(p[field] || {})) {
      if (!name.startsWith("@indiekit/")) continue;
      const namesPrerelease = /-(beta|alpha|rc)/.test(range);
      const openEnded = /^[\^~]|^>=/.test(range);
      let verdict = "ok";
      if (!namesPrerelease) verdict = "BROKEN — cannot match a prerelease";
      else if (!openEnded) verdict = "PINNED — exact, will not pick up newer betas";
      if (verdict !== "ok") rows.push(`  ${repo.padEnd(42)} ${field}: ${name}@${range}  <- ${verdict}`);
    }
  }
  if (rows.length) console.log(rows.join("\n"));
});
NODE

echo "Checking @indiekit/* ranges (${MODE}) across ${#REPOS[@]} repos…"
echo

found=0
for r in "${REPOS[@]}"; do
  if [ "$MODE" = github ]; then
    manifest=$(gh api "repos/rmdes/$r/contents/package.json" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
  else
    manifest=$(cat "$WORKSPACE/$r/package.json" 2>/dev/null)
  fi
  [ -z "$manifest" ] && continue    # no package.json — nothing to check
  out=$(printf '%s' "$manifest" | node -e "$CLASSIFY" "$r")
  if [ -n "$out" ]; then echo "$out"; found=$((found+1)); fi
done

echo
if [ "$found" -eq 0 ]; then
  echo "No unusable @indiekit/* ranges found."
else
  cat <<'ADVICE'
Repo(s) above need attention.

Pick the floor from what the package ACTUALLY needs, not from what its siblings
happen to declare. Most of ours say ">=1.0.0-beta.25", but several also depend on
@indiekit/util@^1.0.0-beta.29 — so that floor claims support for a release the
code would break on. Check the package's own @indiekit/* dependencies first:

    gh api repos/rmdes/<repo>/contents/package.json --jq '.content' | base64 -d \
      | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
          const p=JSON.parse(s);
          console.log("peer:", p.peerDependencies);
          console.log("deps:", p.dependencies);
        })'

Latest published upstream: npm view @indiekit/indiekit version
ADVICE
fi
