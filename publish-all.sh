#!/usr/bin/env bash
# Publish every @rmdes/* package whose local version is not yet on npm.
# Discovery is a glob — there is no list to maintain.
#
# Tagging rules (derived from each package's own history, not hardcoded):
#   stable version (1.2.3)        -> npm publish
#   prerelease   (1.0.0-beta.37)  -> npm publish --tag beta
#                                    ...then, IF that package's current `latest`
#                                    is itself a prerelease, also move `latest`.
#   That last rule preserves each package's existing convention: auth/micropub
#   keep latest on their betas; syndicate/frontend/preset keep latest on stable.
#
# Usage:
#   publish-all.sh [dir] [--dry-run] [--latest-always|--latest-never]
#
# Each npm publish prompts for its own OTP. Already-published versions are
# skipped, so re-running after a failure only retries what is missing.
set -uo pipefail

root=.; dry=0; latest_mode=auto
for arg in "$@"; do
  case "$arg" in
    --dry-run)       dry=1 ;;
    --latest-always) latest_mode=always ;;
    --latest-never)  latest_mode=never ;;
    -*)              echo "unknown flag: $arg" >&2; exit 2 ;;
    *)               root=$arg ;;
  esac
done
cd "$root" || exit 1

if [ -t 1 ]; then
  ok=$'\e[32m'; warn=$'\e[33m'; bad=$'\e[31m'; dim=$'\e[2m'; off=$'\e[0m'
else
  ok=; warn=; bad=; dim=; off=
fi

published=0 skipped=0 failed=0 planned=0

# Ask the registry directly. `npm view` reads a local cache that can lag a
# publish by seconds — that staleness has already caused one false "publish
# failed" diagnosis, so never trust it here.
registry_json() {
  curl -sf --max-time 20 "https://registry.npmjs.org/${1//\//%2F}" 2>/dev/null
}

for dir in */; do
  repo=${dir%/}
  [ -f "$repo/package.json" ] || continue

  read -r pkg version private < <(
    node -p "
      const p=require('./$repo/package.json');
      [p.name||'-', p.version||'-', p.private?'private':'public'].join(' ')
    " 2>/dev/null
  ) || continue

  case "$pkg" in @rmdes/*) ;; *) continue ;; esac
  if [ "$private" = "private" ]; then
    printf '%s- %-42s private, never published%s\n' "$dim" "$pkg" "$off"
    skipped=$((skipped + 1)); continue
  fi

  json=$(registry_json "$pkg")
  if [ -z "$json" ]; then
    printf '%s- %-42s not on npm at all (first publish — do it by hand)%s\n' "$warn" "$pkg" "$off"
    skipped=$((skipped + 1)); continue
  fi

  read -r exists cur_latest < <(
    printf '%s' "$json" | node -p "
      const d=JSON.parse(require('fs').readFileSync(0,'utf8'));
      [!!d.versions['$version'], d['dist-tags'].latest||'-'].join(' ')
    " 2>/dev/null
  ) || { printf '%s✗ %-42s could not parse registry response%s\n' "$bad" "$pkg" "$off"; failed=$((failed+1)); continue; }

  if [ "$exists" = "true" ]; then
    printf '%s  %-42s %s already published%s\n' "$dim" "$pkg" "$version" "$off"
    skipped=$((skipped + 1)); continue
  fi

  # Publishing a dirty tree ships files that are in no commit. Refuse.
  if [ -e "$repo/.git" ] && [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
    printf '%s- %-42s uncommitted changes — commit first%s\n' "$warn" "$pkg" "$off"
    skipped=$((skipped + 1)); continue
  fi

  # A '-' in the version means prerelease (1.0.0-beta.37).
  case "$version" in
    *-*) prerelease=1 ;;
    *)   prerelease=0 ;;
  esac

  move_latest=0
  if [ "$prerelease" = 1 ]; then
    tag=beta
    case "$latest_mode" in
      always) move_latest=1 ;;
      never)  move_latest=0 ;;
      auto)   case "$cur_latest" in *-*) move_latest=1 ;; *) move_latest=0 ;; esac ;;
    esac
  else
    tag=latest
  fi

  planned=$((planned + 1))
  label="$version --tag $tag"
  [ "$move_latest" = 1 ] && label="$label + dist-tag latest"

  if [ "$dry" = 1 ]; then
    printf '%s→ %-42s WOULD publish %s%s\n' "$ok" "$pkg" "$label" "$off"
    continue
  fi

  printf '\n%s→ %s %s%s\n' "$ok" "$pkg" "$label" "$off"
  if ! ( cd "$repo" && npm publish --tag "$tag" ); then
    printf '%s✗ %-42s publish failed%s\n' "$bad" "$pkg" "$off"
    failed=$((failed + 1)); continue
  fi

  if [ "$move_latest" = 1 ]; then
    if ! npm dist-tag add "$pkg@$version" latest; then
      printf '%s✗ %-42s published, but dist-tag latest failed%s\n' "$bad" "$pkg" "$off"
      failed=$((failed + 1)); continue
    fi
  fi

  # Confirm against the registry rather than assuming the command told the truth.
  # npm itself warns "may take a few minutes to become available", so a single
  # immediate check reports false failures on a publish that actually worked.
  # Retry with backoff; only give up after ~1 minute of absence.
  live=false
  for attempt in 1 2 3 4 5 6; do
    if [ "$(registry_json "$pkg" | node -p "try{!!JSON.parse(require('fs').readFileSync(0,'utf8')).versions['$version']}catch(e){false}")" = "true" ]; then
      live=true; break
    fi
    [ "$attempt" -lt 6 ] && sleep $((attempt * 4))
  done

  if [ "$live" = true ]; then
    printf '%s✓ %-42s %s live%s\n' "$ok" "$pkg" "$version" "$off"
    published=$((published + 1))
  else
    printf '%s? %-42s published, not visible yet — recheck before pinning%s\n' "$warn" "$pkg" "$off"
    failed=$((failed + 1))
  fi
done

if [ "$dry" = 1 ]; then
  printf '\n%d would publish, %d skipped, %d failed\n' "$planned" "$skipped" "$failed"
else
  printf '\n%d published, %d skipped, %d failed\n' "$published" "$skipped" "$failed"
fi
[ "$failed" -eq 0 ]
