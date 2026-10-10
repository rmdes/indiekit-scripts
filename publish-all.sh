#!/usr/bin/env bash
# Publish every @rmdes/* package whose local version is not yet on npm.
# Discovery is a glob — there is no list to maintain.
#
# Phases, in this order and for these reasons:
#   1. PREFLIGHT  — confirm npm still has a credential; stop if not.
#   2. PLAN       — ask the registry what exists, refuse dirty trees, decide each
#                   package's dist-tag. Prints the whole plan before anything
#                   ships, so an unexpected package is caught before the first OTP.
#   3. PUBLISH    — every `npm publish`, back to back.
#   4. DIST-TAGS  — every `npm dist-tag add`, grouped AFTER the publishes.
#   5. VERIFY     — ONE registry sweep at the end.
#
# Phases 4 and 5 are separate from 3 on purpose; see AUTH and VERIFY below.
#
# ─── AUTH: why a 10-package round costs 15 browser round-trips ───
#
# This account authenticates with a PASSKEY (WebAuthn, held in Bitwarden). There
# is no TOTP authenticator on it. That constrains the options:
#
#   --auth-type=web     (THE DEFAULT, and the only one that works here) npm prints
#                       Authenticate your account at: https://www.npmjs.com/auth/cli/<uuid>
#                       and polls /-/v1/done?authId=… until the browser flow
#                       completes. Session TTL is ~5 minutes.
#   --auth-type=legacy  Prompts for a 6-digit code at the terminal. USELESS on a
#                       passkey-only account — there is no code to type. Do not
#                       set it here hoping for speed; an earlier revision of this
#                       script defaulted to it and would simply have blocked
#                       every publish.
#
# So the cost is one browser approval per operation, and operations are what to
# reduce. On 2026-10-10 a ten-package round needed FIFTEEN: ten publishes plus
# five `dist-tag add latest` moves. Five sessions expired mid-round, each failing
# with E404 on /-/v1/done?authId=… at almost exactly 5-minute intervals, and the
# round took ~25 minutes for 6 of 10 landed.
#
# Two ways to cut the round-trips:
#
#   1. --latest-never  halves them when `latest` does not matter. It usually does
#      not: indiekit-cloudron pins forked defaults to an EXACT version in
#      package.json overrides, and the plugin registry pins the rest to an
#      explicit range. Neither reads dist-tags. `latest` only affects a bare
#      `npm install @rmdes/...`. Five fewer approvals, and the tags can be
#      repaired later in one pass with --repair-tags.
#
#   2. A GRANULAR ACCESS TOKEN — zero approvals, the real fix. On npmjs.com:
#      Access Tokens -> Generate New Token -> Granular, scope it to @rmdes with
#      Read and write, and set "Bypass 2FA for automation" (that setting is what
#      makes it skip the passkey flow). Then:
#        npm config set //registry.npmjs.org/:_authToken npm_xxxxx
#      Keep the token in Bitwarden alongside the passkey. The trade is real: a
#      publish-capable credential then sits in ~/.npmrc, so anything running as
#      you can publish. That is why this script does not create one for you.
#
# ─── VERIFY: why it is one sweep at the end, not a poll per package ───
#
# npm warns a new version "may take a few minutes to become available", so an
# immediate check reports a false failure on a publish that worked. The previous
# version polled with backoff for up to a minute per package — up to 10 minutes
# of waiting, and it STILL reported "published, not visible yet" for five
# packages that had in fact landed. Verifying once, after every publish is done,
# gives propagation the time it needs for free.
#
# Note also that npm printing `+ pkg@version` is NOT proof: on 2026-10-10 it
# printed that line for syndicator-mastodon@1.1.4, which never reached the
# registry. Only the final sweep is believed.
#
# Usage:
#   publish-all.sh [dir] [--dry-run] [--latest-always|--latest-never]
#                        [--skip-auth-check] [--repair-tags]
#                        [--auth-type=web|legacy] [--otp=123456]
#
# --auth-type defaults to web; legacy needs a TOTP code this account does not
# have. --otp= is only useful on a TOTP account.
#
# Already-published versions are skipped, so re-running after a failure retries
# only what is missing. That is the supported recovery path — just run it again.
#
# Tagging rules (derived from each package's own history, not hardcoded):
#   stable version (1.2.3)        -> npm publish --tag latest
#   prerelease   (1.0.0-beta.37)  -> npm publish --tag beta
#                                    ...then, IF that package's current `latest`
#                                    is itself a prerelease, also move `latest`.
#   Derived from the registry at run time on purpose: as of 2026-10-10 auth,
#   micropub, syndicate, frontend AND preset-eleventy all have `latest` on a
#   prerelease, so all five move it. An earlier version of this comment asserted
#   syndicate/frontend/preset kept latest on stable — true once, then silently
#   not. Do not re-hardcode it; read `npm view <pkg> dist-tags.latest`.
set -uo pipefail

root=.; dry=0; latest_mode=auto; auth_check=1; auth_type=web; otp=""; repair_tags=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)          dry=1 ;;
    --latest-always)    latest_mode=always ;;
    --latest-never)     latest_mode=never ;;
    --skip-auth-check)  auth_check=0 ;;
    --repair-tags)      repair_tags=1 ;;
    --auth-type=*)      auth_type=${arg#*=} ;;
    --otp=*)            otp=${arg#*=} ;;
    -*)                 echo "unknown flag: $arg" >&2; exit 2 ;;
    *)                  root=$arg ;;
  esac
done
cd "$root" || exit 1

case "$auth_type" in
  web|legacy) ;;
  *) echo "--auth-type must be web or legacy" >&2; exit 2 ;;
esac

npm_args=(--auth-type="$auth_type")
[ -n "$otp" ] && npm_args+=(--otp="$otp")

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

# ─── Phase 1: preflight ───
#
# `npm whoami` resolves the token in .npmrc against the registry: the cheapest
# proof that a publish will not fail on auth. It proves IDENTITY, not publish
# rights on a given package — a token can be valid and still lack @rmdes access
# — so per-package failures are still handled below.
npm_registry=${NPM_REGISTRY:-https://registry.npmjs.org/}

if [ "$auth_check" = 1 ]; then
  if whoami_out=$(npm whoami --registry="$npm_registry" 2>&1); then
    printf '%s✓ npm: authenticated as %s%s %s(%s, auth-type=%s)%s\n' \
      "$ok" "$whoami_out" "$off" "$dim" "$npm_registry" "$auth_type" "$off"
  else
    printf '%s✗ npm: no valid credential for %s%s\n' "$bad" "$npm_registry" "$off"
    printf '%s  %s%s\n' "$dim" "$(printf '%s' "$whoami_out" | head -1)" "$off"
    if [ "$dry" = 1 ]; then
      printf '%s  continuing anyway — --dry-run publishes nothing%s\n' "$warn" "$off"
    else
      printf '  Run %snpm login%s first, then re-run this script.\n' "$ok" "$off"
      exit 1
    fi
  fi
fi

# ─── Phase 2: plan ───
plan=()          # pkg|version|repo|tag|move_latest
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
    printf '%s- %-42s not on npm at all (first publish — do it by hand)%s\n' "$warn" "$pkg" "$off"
    skipped=$((skipped + 1)); continue
  fi

  read -r exists cur_latest cur_beta < <(
    printf '%s' "$json" | node -p "
      const d=JSON.parse(require('fs').readFileSync(0,'utf8'));
      [!!d.versions['$version'], d['dist-tags'].latest||'-', d['dist-tags'].beta||'-'].join(' ')
    " 2>/dev/null
  ) || { printf '%s✗ %-42s could not parse registry response%s\n' "$bad" "$pkg" "$off"; skipped=$((skipped+1)); continue; }

  # Already on npm — but that is NOT necessarily nothing to do. A publish can
  # succeed while its dist-tag move fails separately: on 2026-10-10 micropub
  # beta.39 and preset beta.41 both landed and both left `latest` on the previous
  # beta, because the dist-tag auth round-trip timed out after the publish had
  # gone through. Treating "published" as "done" made that unrepairable by
  # re-running, which is the one recovery path this script promises. So check the
  # tag here and queue a tag-only repair.
  #
  # Guarded by `cur_beta = version`: only ever move `latest` to the CURRENT beta
  # head, never backwards onto an older prerelease.
  if [ "$exists" = "true" ]; then
    needs_tag=0
    case "$version" in
      *-*)
        if [ "$cur_beta" = "$version" ] && [ "$cur_latest" != "$version" ]; then
          case "$latest_mode" in
            always) needs_tag=1 ;;
            never)  needs_tag=0 ;;
            auto)   case "$cur_latest" in *-*) needs_tag=1 ;; esac ;;
          esac
        fi
        ;;
    esac
    if [ "$needs_tag" = 1 ]; then
      if [ "$repair_tags" = 1 ]; then
        printf '%s! %-42s %s on npm, latest is %s — will repair%s\n' "$warn" "$pkg" "$version" "$cur_latest" "$off"
        plan+=("$pkg|$version|$repo|-|1|tag-only")
      else
        # Reported, not acted on. A dist-tag move is a mutation on a package that
        # may have nothing to do with this round: on 2026-10-10 the detector
        # correctly flagged endpoint-donation, a pre-alpha package whose `latest`
        # has sat on alpha.1 deliberately. Keeping the script's blast radius equal
        # to "publish what I have committed" means the repair has to be asked for.
        printf '%s! %-42s %s on npm, latest is %s %s(--repair-tags to fix)%s\n' \
          "$warn" "$pkg" "$version" "$cur_latest" "$dim" "$off"
        skipped=$((skipped + 1))
      fi
    else
      printf '%s  %-42s %s already published%s\n' "$dim" "$pkg" "$version" "$off"
      skipped=$((skipped + 1))
    fi
    continue
  fi

  # Publishing a dirty tree ships files that are in no commit. Refuse.
  if [ -e "$repo/.git" ] && [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
    printf '%s- %-42s uncommitted changes — commit first%s\n' "$warn" "$pkg" "$off"
    skipped=$((skipped + 1)); continue
  fi

  case "$version" in *-*) prerelease=1 ;; *) prerelease=0 ;; esac

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

  plan+=("$pkg|$version|$repo|$tag|$move_latest|publish")
done

echo
if [ "${#plan[@]}" -eq 0 ]; then
  printf 'Nothing to publish. %d skipped.\n' "$skipped"
  exit 0
fi

printf '%sPlan — %d package(s):%s\n' "$ok" "${#plan[@]}" "$off"
for entry in "${plan[@]}"; do
  IFS='|' read -r pkg version repo tag move_latest mode <<<"$entry"
  if [ "$mode" = tag-only ]; then
    label="$version — move latest only (version is on npm)"
  else
    label="$version --tag $tag"
    [ "$move_latest" = 1 ] && label="$label, then move latest"
  fi
  printf '  %-42s %s\n' "$pkg" "$label"
done
echo

n_pub=0; n_tag=0
for entry in "${plan[@]}"; do
  IFS='|' read -r _ _ _ _ _ mode <<<"$entry"
  if [ "$mode" = tag-only ]; then n_tag=$((n_tag + 1)); else n_pub=$((n_pub + 1)); fi
done

if [ "$dry" = 1 ]; then
  printf '%d to publish, %d dist-tag repair(s), %d skipped. (--dry-run)\n' "$n_pub" "$n_tag" "$skipped"
  exit 0
fi

# ─── Phase 3: publish ───
printf '%s── publishing ──%s\n' "$dim" "$off"
publish_count=0
for entry in "${plan[@]}"; do
  IFS='|' read -r pkg version repo tag move_latest mode <<<"$entry"
  [ "$mode" = tag-only ] && continue
  publish_count=$((publish_count + 1))
  printf '\n%s→ %s %s --tag %s%s\n' "$ok" "$pkg" "$version" "$tag" "$off"
  ( cd "$repo" && npm publish --tag "$tag" "${npm_args[@]}" ) \
    || printf '%s✗ %s publish command failed — the final sweep decides%s\n' "$warn" "$pkg" "$off"
done
[ "$publish_count" -eq 0 ] && printf '%s  (nothing to publish — dist-tag repairs only)%s\n' "$dim" "$off"


# ─── Phase 4: dist-tag moves, grouped ───
#
# Grouped after the publishes so the auth prompts come together rather than
# interleaved, and so a failed dist-tag never looks like a failed publish —
# which is exactly how the 2026-10-10 run misreported micropub and preset.
tag_pending=()
for entry in "${plan[@]}"; do
  IFS='|' read -r pkg version repo tag move_latest mode <<<"$entry"
  [ "$move_latest" = 1 ] && tag_pending+=("$pkg|$version")
done

if [ "${#tag_pending[@]}" -gt 0 ]; then
  printf '\n%s── moving dist-tag latest (%d) ──%s\n' "$dim" "${#tag_pending[@]}" "$off"
  for entry in "${tag_pending[@]}"; do
    IFS='|' read -r pkg version <<<"$entry"
    # Only if the publish actually landed; tagging a missing version 404s.
    if [ "$(registry_has "$pkg" "$version")" != "true" ]; then
      printf '%s- %-42s not on npm yet, skipping dist-tag%s\n' "$warn" "$pkg" "$off"
      continue
    fi
    printf '%s→ latest = %s@%s%s\n' "$ok" "$pkg" "$version" "$off"
    npm dist-tag add "$pkg@$version" latest "${npm_args[@]}" \
      || printf '%s✗ %s dist-tag failed%s\n' "$warn" "$pkg" "$off"
  done
fi

# ─── Phase 5: verify once ───
printf '\n%s── verifying against the registry ──%s\n' "$dim" "$off"
published=0; failed=0; tags_wrong=0
for entry in "${plan[@]}"; do
  IFS='|' read -r pkg version repo tag move_latest mode <<<"$entry"
  if [ "$(registry_has "$pkg" "$version")" = "true" ]; then
    note=""
    if [ "$move_latest" = 1 ]; then
      cur=$(registry_json "$pkg" | node -p "try{JSON.parse(require('fs').readFileSync(0,'utf8'))['dist-tags'].latest}catch(e){'?'}")
      if [ "$cur" != "$version" ]; then
        note=" ${warn}(latest still $cur — run: npm dist-tag add $pkg@$version latest)${off}"
        tags_wrong=$((tags_wrong + 1))
      fi
    fi
    printf '%s✓ %-42s %s live%s%b\n' "$ok" "$pkg" "$version" "$off" "$note"
    published=$((published + 1))
  else
    printf '%s✗ %-42s %s NOT on npm — re-run to retry%s\n' "$bad" "$pkg" "$version" "$off"
    failed=$((failed + 1))
  fi
done

printf '\n%d published, %d skipped, %d still missing' "$published" "$skipped" "$failed"
[ "$tags_wrong" -gt 0 ] && printf ', %d dist-tag(s) not moved' "$tags_wrong"
printf '\n'
[ "$failed" -eq 0 ] && [ "$tags_wrong" -eq 0 ]
