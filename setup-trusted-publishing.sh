#!/usr/bin/env bash
# Install templates/publish.yml into @rmdes/* repos and make package.json fit
# for npm trusted publishing. Idempotent: re-run after editing the template.
#
# Which repos: the ones named on the command line, or else every @rmdes/* repo
# that is ALREADY ON NPM and NOT an alpha. Unpublished plugins (bluesky-pds,
# atproto-utils) are never touched — trusted publishing can't be configured for
# a package that doesn't exist yet. Alphas (endpoint-donation) only when named.
#
# Per repo:
#   - copy templates/publish.yml -> .github/workflows/publish.yml (if different)
#   - set repository.url to the GitHub origin. npm refuses an OIDC publish when
#     repository.url does not match the repo the workflow runs in; on 2026-10-10
#     comments, share and site-config had none and indienews pointed at rmendes/.
#   - commit both as one "ci:" commit. --push also pushes it.
#
# It does NOT create the trust config on npmjs.com: a config must see its first
# publish within 2 days or it expires, so publish-all.sh creates it just in time.
#
# Usage: setup-trusted-publishing.sh [--dry-run] [--push] [--root=DIR] [repo...]
#   --root defaults to the workspace this script sits in (indiekit-dev/).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
template=$here/templates/publish.yml
root=$here/..; dry=0; push=0; named=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=1 ;;
    --push)    push=1 ;;
    --root=*)  root=${arg#*=} ;;
    -*)        echo "unknown flag: $arg" >&2; exit 2 ;;
    *)         named+=("${arg%/}") ;;
  esac
done
cd "$root" || exit 1

if [ "${#named[@]}" -gt 0 ]; then repos=("${named[@]}"); else repos=(*/); repos=("${repos[@]%/}"); fi

for repo in "${repos[@]}"; do
  [ -f "$repo/package.json" ] && [ -e "$repo/.git" ] || continue
  # path passed as argv, never spliced into the JS source
  read -r pkg version private cur_url < <(node -p '
    const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")), r=p.repository;
    [p.name||"-", p.version||"-", p.private?"private":"public", (typeof r==="string"?r:r?.url)||"-"].join(" ")
  ' "$repo/package.json" 2>/dev/null) || continue
  case "$pkg" in @rmdes/*) ;; *) continue ;; esac
  [ "$private" = public ] || continue
  if ! curl -sfo /dev/null --max-time 20 "https://registry.npmjs.org/${pkg//\//%2F}"; then
    printf '  %-42s not on npm, skipped\n' "$pkg"; continue
  fi
  if [ "${#named[@]}" -eq 0 ] && [[ $version == *-alpha* ]]; then
    printf '  %-42s alpha (%s), skipped — name it to include\n' "$pkg" "$version"; continue
  fi

  # git@github.com:owner/repo.git | https://github.com/owner/repo(.git) -> owner/repo
  slug=$(git -C "$repo" remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
  [ -n "$slug" ] || { echo "- $pkg: no origin remote, skipped"; continue; }
  want_url="git+https://github.com/$slug.git"
  have_slug=$(printf '%s' "$cur_url" | sed -E 's#^git\+##; s#^(git@github\.com:|https://github\.com/)##; s#\.git$##; s#/$##')

  changes=()
  cmp -s "$template" "$repo/.github/workflows/publish.yml" || changes+=("publish.yml")
  [ "$have_slug" = "$slug" ] || changes+=("repository.url ($cur_url -> $want_url)")

  if [ "${#changes[@]}" -eq 0 ]; then
    printf '  %-42s up to date\n' "$pkg"; continue
  fi
  printf '→ %-42s %s\n' "$pkg" "$(IFS=', '; echo "${changes[*]}")"
  [ "$dry" = 1 ] && continue

  if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
    echo "  uncommitted changes — commit first, skipped"; continue
  fi
  mkdir -p "$repo/.github/workflows"
  cp "$template" "$repo/.github/workflows/publish.yml"
  # delete first: `repository` may be a plain string, which pkg set can't nest into
  [ "$have_slug" = "$slug" ] ||
    ( cd "$repo" && npm pkg delete repository && npm pkg set repository.type=git repository.url="$want_url" )
  git -C "$repo" add .github/workflows/publish.yml package.json
  git -C "$repo" commit -qm "ci: publish to npm via trusted publishing (OIDC)" \
    && echo "  committed"
  if [ "$push" = 1 ]; then git -C "$repo" push -q && echo "  pushed"; fi
done
