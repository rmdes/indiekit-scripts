#!/usr/bin/env bash
# Publish every @rmdes/* package whose local version is not yet on npm.
# Discovery is a glob — there is no list to maintain.
#
# Publishing happens in GitHub Actions via npm TRUSTED PUBLISHING (OIDC):
# this script decides what ships, then pushes a `v<version>` tag per package;
# each repo's .github/workflows/publish.yml (from templates/, installed by
# setup-trusted-publishing.sh) does the `npm publish`. No npm token anywhere,
# no per-publish passkey approval, and provenance is attached automatically.
#
# Phases:
#   1. PREFLIGHT  — npm credential (only needed to create trust configs) and gh.
#   2. PLAN       — ask the registry what exists, refuse dirty/unpushed trees and
#                   repos without publish.yml. Prints the plan before anything ships.
#   3. TRUST      — `npm trust github` for each package being published. One
#                   passkey approval; tick "skip 2FA for 5 minutes" and the rest
#                   go through. Done here, not in setup, because a new trust
#                   config expires if it does not see a publish within 2 days.
#                   An existing config makes this a harmless "already exists".
#   4. TAG        — push v<version>; the tag push triggers the workflow. If the
#                   tag is already on the remote at HEAD, re-dispatch instead.
#   5. DIST-TAGS  — --repair-tags only: `npm dist-tag add latest`, run LOCALLY
#                   (passkey). OIDC dist-tag needs "Allow npm dist-tag" ticked on
#                   the website per package; local is simpler for a rare repair.
#   6. VERIFY     — poll the registry until every version lands or the timeout.
#                   Only the registry is believed (npm's `+ pkg@ver` line once
#                   lied about syndicator-mastodon@1.1.4), and a fresh version can
#                   take minutes to appear, hence a poll and not one check.
#
# Tagging rules live in templates/publish.yml: stable -> latest; prerelease ->
# beta, or straight to latest when the current `latest` is itself a prerelease
# (as of 2026-10-10: auth, micropub, syndicate, frontend, preset-eleventy).
#
# Usage:
#   publish-all.sh [dir] [--dry-run] [--skip-auth-check] [--repair-tags] [--timeout=900]
#
# Already-published versions are skipped, so re-running after a failure retries
# only what is missing. A package still missing is listed with its CI run URL.
#
# Expired trust config (ENEEDAUTH in the CI log): `npm trust list <pkg>`, then
# `npm trust revoke <pkg> --id=<id>`, then re-run.
set -uo pipefail

root=.; dry=0; auth_check=1; repair_tags=0; timeout=900
for arg in "$@"; do
  case "$arg" in
    --dry-run)          dry=1 ;;
    --skip-auth-check)  auth_check=0 ;;
    --repair-tags)      repair_tags=1 ;;
    --timeout=*)        timeout=${arg#*=} ;;
    -*)                 echo "unknown flag: $arg" >&2; exit 2 ;;
    *)                  root=$arg ;;
  esac
done
cd "$root" || exit 1

if [ -t 1 ]; then
  ok=$'\e[32m'; warn=$'\e[33m'; bad=$'\e[31m'; dim=$'\e[2m'; off=$'\e[0m'
else
  ok=; warn=; bad=; dim=; off=
fi

# Ask the registry directly. `npm view` reads a local cache that can lag a
# publish by seconds — that staleness has already caused one false "publish
# failed" diagnosis, so never trust it here.
registry_json() {
  curl -sf --max-time 20 "https://registry.npmjs.org/${1//\//%2F}" 2>/dev/null
}
registry_has() {   # pkg version -> "true"/"false"
  registry_json "$1" | node -p "try{!!JSON.parse(require('fs').readFileSync(0,'utf8')).versions['$2']}catch(e){false}" 2>/dev/null
}
origin_slug() {    # repo dir -> owner/repo
  git -C "$1" remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##'
}

# ─── Phase 1: preflight ───
#
# npm is only needed for `npm trust` and --repair-tags; the publish itself uses
# CI's OIDC identity. gh is needed to re-dispatch and to find failed runs.
if [ "$auth_check" = 1 ]; then
  if whoami_out=$(npm whoami 2>&1); then
    printf '%s✓ npm: authenticated as %s%s\n' "$ok" "$whoami_out" "$off"
  else
    printf '%s✗ npm: no valid credential%s %s(%s)%s\n' "$bad" "$off" "$dim" "$(printf '%s' "$whoami_out" | head -1)" "$off"
    if [ "$dry" = 1 ]; then
      printf '%s  continuing anyway — --dry-run publishes nothing%s\n' "$warn" "$off"
    else
      printf '  Run %snpm login%s first (needed for npm trust), then re-run.\n' "$ok" "$off"
      exit 1
    fi
  fi
  if gh auth status >/dev/null 2>&1; then
    printf '%s✓ gh: authenticated%s\n' "$ok" "$off"
  else
    printf '%s! gh: not authenticated — re-dispatch and CI run links unavailable%s\n' "$warn" "$off"
  fi
fi

# ─── Phase 2: plan ───
plan=()          # pkg|version|repo|slug|mode   (mode: publish | tag-only)
skipped=0

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
    # Trusted publishing can only be configured on a package that exists.
    printf '%s- %-42s not on npm at all (first publish — do it by hand)%s\n' "$warn" "$pkg" "$off"
    skipped=$((skipped + 1)); continue
  fi

  read -r exists cur_latest cur_beta < <(
    printf '%s' "$json" | node -p "
      const d=JSON.parse(require('fs').readFileSync(0,'utf8'));
      [!!d.versions['$version'], d['dist-tags'].latest||'-', d['dist-tags'].beta||'-'].join(' ')
    " 2>/dev/null
  ) || { printf '%s✗ %-42s could not parse registry response%s\n' "$bad" "$pkg" "$off"; skipped=$((skipped+1)); continue; }

  # Already on npm — but a dist-tag move can fail separately from its publish
  # (micropub beta.39 and preset beta.41 on 2026-10-10 left `latest` on the
  # previous beta). Detect it; repair only when asked, because on a package like
  # endpoint-donation `latest` sits on alpha.1 deliberately. Guarded by
  # `cur_beta = version`: only ever move latest to the CURRENT beta head.
  if [ "$exists" = "true" ]; then
    case "$version:$cur_latest" in
      *-*:*-*)
        if [ "$cur_beta" = "$version" ] && [ "$cur_latest" != "$version" ]; then
          if [ "$repair_tags" = 1 ]; then
            printf '%s! %-42s %s on npm, latest is %s — will repair%s\n' "$warn" "$pkg" "$version" "$cur_latest" "$off"
            plan+=("$pkg|$version|$repo|-|tag-only")
          else
            printf '%s! %-42s %s on npm, latest is %s %s(--repair-tags to fix)%s\n' \
              "$warn" "$pkg" "$version" "$cur_latest" "$dim" "$off"
            skipped=$((skipped + 1))
          fi
          continue
        fi ;;
    esac
    printf '%s  %-42s %s already published%s\n' "$dim" "$pkg" "$version" "$off"
    skipped=$((skipped + 1)); continue
  fi

  # Publishing a dirty tree ships files that are in no commit. Refuse.
  if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    printf '%s- %-42s uncommitted changes — commit first%s\n' "$warn" "$pkg" "$off"
    skipped=$((skipped + 1)); continue
  fi
  if ! git -C "$repo" cat-file -e HEAD:.github/workflows/publish.yml 2>/dev/null; then
    printf '%s- %-42s no committed publish.yml — run setup-trusted-publishing.sh%s\n' "$warn" "$pkg" "$off"
    skipped=$((skipped + 1)); continue
  fi
  # CI builds the tagged commit; it must already be on a GitHub branch, not a
  # local-only commit smuggled out by the tag push.
  git -C "$repo" fetch -q origin 2>/dev/null
  if [ -z "$(git -C "$repo" branch -r --contains HEAD 2>/dev/null)" ]; then
    printf '%s- %-42s HEAD not pushed — git push first%s\n' "$warn" "$pkg" "$off"
    skipped=$((skipped + 1)); continue
  fi

  plan+=("$pkg|$version|$repo|$(origin_slug "$repo")|publish")
done

echo
if [ "${#plan[@]}" -eq 0 ]; then
  printf 'Nothing to publish. %d skipped.\n' "$skipped"
  exit 0
fi

printf '%sPlan — %d package(s):%s\n' "$ok" "${#plan[@]}" "$off"
n_pub=0; n_tag=0
for entry in "${plan[@]}"; do
  IFS='|' read -r pkg version repo slug mode <<<"$entry"
  if [ "$mode" = tag-only ]; then
    printf '  %-42s %s — move latest only (version is on npm)\n' "$pkg" "$version"; n_tag=$((n_tag + 1))
  else
    printf '  %-42s v%s → CI in %s\n' "$pkg" "$version" "$slug"; n_pub=$((n_pub + 1))
  fi
done
echo

if [ "$dry" = 1 ]; then
  printf '%d to publish, %d dist-tag repair(s), %d skipped. (--dry-run)\n' "$n_pub" "$n_tag" "$skipped"
  exit 0
fi

# ─── Phase 3: trust configs ───
if [ "$n_pub" -gt 0 ]; then
  printf '%s── trusted publisher configs (approve once, tick "skip for 5 minutes") ──%s\n' "$dim" "$off"
  for entry in "${plan[@]}"; do
    IFS='|' read -r pkg version repo slug mode <<<"$entry"
    [ "$mode" = publish ] || continue
    if out=$(npm trust github "$pkg" --file publish.yml --repo "$slug" --allow-publish --yes 2>&1); then
      printf '%s✓ %-42s trusts %s publish.yml%s\n' "$ok" "$pkg" "$slug" "$off"
    elif printf '%s' "$out" | grep -qiE 'already|exist|409|conflict'; then
      printf '%s  %-42s already configured%s\n' "$dim" "$pkg" "$off"
    else
      printf '%s! %-42s npm trust failed — CI will tell: %s%s\n' "$warn" "$pkg" "$(printf '%s' "$out" | grep -m1 'npm error')" "$off"
    fi
    sleep 2   # npm's own advice for bulk trust calls: avoid rate limiting
  done
fi

# ─── Phase 4: tags ───
[ "$n_pub" -gt 0 ] && printf '\n%s── pushing tags ──%s\n' "$dim" "$off"
for entry in "${plan[@]}"; do
  IFS='|' read -r pkg version repo slug mode <<<"$entry"
  [ "$mode" = publish ] || continue
  t="v$version"; head=$(git -C "$repo" rev-parse HEAD)
  # For an annotated tag ls-remote prints the peeled `^{}` line last: the commit.
  remote_sha=$(git -C "$repo" ls-remote origin "refs/tags/$t" "refs/tags/$t^{}" | awk 'END{print $1}')

  if [ -n "$remote_sha" ] && [ "$remote_sha" != "$head" ]; then
    printf '%s✗ %-42s %s already on origin at another commit — bump the version%s\n' "$bad" "$pkg" "$t" "$off"
  elif [ -n "$remote_sha" ]; then
    # A tag push only triggers once; dispatch the workflow for the existing tag.
    printf '%s→ %s %s exists, re-dispatching%s\n' "$ok" "$pkg" "$t" "$off"
    gh workflow run publish.yml --repo "$slug" --ref "$t" \
      || printf '%s✗ %s dispatch failed%s\n' "$warn" "$pkg" "$off"
  else
    git -C "$repo" rev-parse -q --verify "refs/tags/$t" >/dev/null || git -C "$repo" tag "$t"
    printf '%s→ %s %s%s\n' "$ok" "$pkg" "$t" "$off"
    git -C "$repo" push -q origin "refs/tags/$t" \
      || printf '%s✗ %s tag push failed%s\n' "$warn" "$pkg" "$off"
  fi
done

# ─── Phase 5: dist-tag repairs (local, passkey) ───
if [ "$n_tag" -gt 0 ]; then
  printf '\n%s── moving dist-tag latest (%d) ──%s\n' "$dim" "$n_tag" "$off"
  for entry in "${plan[@]}"; do
    IFS='|' read -r pkg version _ _ mode <<<"$entry"
    [ "$mode" = tag-only ] || continue
    printf '%s→ latest = %s@%s%s\n' "$ok" "$pkg" "$version" "$off"
    npm dist-tag add "$pkg@$version" latest || printf '%s✗ %s dist-tag failed%s\n' "$warn" "$pkg" "$off"
  done
fi

# ─── Phase 6: verify ───
if [ "$n_pub" -gt 0 ]; then
  printf '\n%s── waiting for the registry (up to %ss) ──%s\n' "$dim" "$timeout" "$off"
  deadline=$((SECONDS + timeout))
  while :; do
    missing=0
    for entry in "${plan[@]}"; do
      IFS='|' read -r pkg version _ _ mode <<<"$entry"
      [ "$mode" = publish ] && [ "$(registry_has "$pkg" "$version")" != true ] && missing=$((missing + 1))
    done
    if [ "$missing" -eq 0 ] || [ "$SECONDS" -ge "$deadline" ]; then break; fi
    printf '%s  %d pending…%s\n' "$dim" "$missing" "$off"
    sleep 20
  done
fi

published=0; failed=0; tags_wrong=0
for entry in "${plan[@]}"; do
  IFS='|' read -r pkg version repo slug mode <<<"$entry"
  if [ "$mode" = tag-only ]; then
    cur=$(registry_json "$pkg" | node -p "try{JSON.parse(require('fs').readFileSync(0,'utf8'))['dist-tags'].latest}catch(e){'?'}")
    if [ "$cur" = "$version" ]; then
      printf '%s✓ %-42s latest = %s%s\n' "$ok" "$pkg" "$version" "$off"
    else
      printf '%s✗ %-42s latest still %s%s\n' "$bad" "$pkg" "$cur" "$off"; tags_wrong=$((tags_wrong + 1))
    fi
  elif [ "$(registry_has "$pkg" "$version")" = true ]; then
    printf '%s✓ %-42s %s live%s\n' "$ok" "$pkg" "$version" "$off"; published=$((published + 1))
  else
    run=$(gh run list --repo "$slug" --workflow publish.yml --limit 1 --json status,conclusion,url \
      -q '.[0] | "\(.status)/\(.conclusion) \(.url)"' 2>/dev/null)
    printf '%s✗ %-42s %s NOT on npm%s %s\n' "$bad" "$pkg" "$version" "$off" "${run:-(no CI run found)}"
    failed=$((failed + 1))
  fi
done

printf '\n%d published, %d skipped, %d still missing' "$published" "$skipped" "$failed"
[ "$tags_wrong" -gt 0 ] && printf ', %d dist-tag(s) not moved' "$tags_wrong"
printf '\n'
[ "$failed" -eq 0 ] && [ "$tags_wrong" -eq 0 ]
