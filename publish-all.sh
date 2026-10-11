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
#   3. TRUST      — `npm trust github`, ONLY for packages that have neither
#                   published a version via trusted publishing (the registry
#                   records that in _npmUser.trustedPublisher, and a validated
#                   config never expires) NOR a matching config already listed
#                   by `npm trust list`. The second check matters because a
#                   FAILED first CI publish leaves a config behind that no
#                   published version points at, so without it every retry
#                   costs another passkey approval and answers 409 Conflict.
#                   So a package costs one passkey approval on its first
#                   CI release and none after; several first-timers share one
#                   approval if you tick "skip 2FA for 5 minutes". Done here, not
#                   in setup, because a new config expires unused after 2 days.
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
#   publish-all.sh [repo...] [--dry-run] [--skip-auth-check] [--repair-tags]
#                  [--timeout=900] [--root=DIR]
#
# repo...  only consider these repos (e.g. indiekit-endpoint-posts); default all.
# --root   the workspace holding the repos; default the one this script sits in.
#          (A positional DIR without a package.json is still taken as --root.)
#
# Already-published versions are skipped, so re-running after a failure retries
# only what is missing. A package still missing is listed with its CI run URL.
#
# Expired trust config (ENEEDAUTH in the CI log): `npm trust list <pkg>`, then
# `npm trust revoke <pkg> --id=<id>`, then re-run.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd); dry=0; auth_check=1; repair_tags=0; timeout=900; named=()
for arg in "$@"; do
  case "$arg" in
    --dry-run)          dry=1 ;;
    --skip-auth-check)  auth_check=0 ;;
    --repair-tags)      repair_tags=1 ;;
    --timeout=*)        timeout=${arg#*=} ;;
    --root=*)           root=${arg#*=} ;;
    -*)                 echo "unknown flag: $arg" >&2; exit 2 ;;
    *)  if [ -d "$arg" ] && [ ! -f "$arg/package.json" ]; then root=$arg; else named+=("${arg%/}"); fi ;;
  esac
done
cd "$root" || exit 1
if [ "${#named[@]}" -gt 0 ]; then
  for repo in "${named[@]}"; do
    [ -f "$repo/package.json" ] || { echo "no such repo in $PWD: $repo" >&2; exit 2; }
  done
  repos=("${named[@]}")
else
  repos=(*/); repos=("${repos[@]%/}")
fi

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
  registry_json "$1" | node -p 'try{!!JSON.parse(require("fs").readFileSync(0,"utf8")).versions[process.argv[1]]}catch(e){false}' "$2" 2>/dev/null
}
run_for_tag() {    # slug tag jq -> field of the newest publish.yml run for that tag
  gh run list --repo "$1" --workflow publish.yml --branch "$2" --limit 1 \
    --json status,conclusion,url -q "$3" 2>/dev/null
}
origin_slug() {    # repo dir -> owner/repo
  git -C "$1" remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##'
}

# Does a usable trust config already exist? `npm trust list` is read-only and
# costs no passkey, unlike `npm trust github`.
#
# A config can exist while no version has yet been published through it, so the
# registry's _npmUser.trustedPublisher does not see it. That is exactly what a
# FAILED first CI publish leaves behind: endpoint-syndicate beta.47 created the
# config, then CI died in `npm test`, and every retry re-created it — one
# passkey approval each time, answered with 409 Conflict.
#
# Match on BOTH file and repository: a config pointing at another workflow or
# another repo would not authorise this publish. Several configs may be listed,
# so reset per `type:` block. Note `npm trust list` exits 0 and prints
# "No trust configurations found" when there are none — the output is the
# signal, not the status.
trust_config_exists() {    # pkg slug -> 0 if a matching config is already there
  timeout 60 npm trust list "$1" 2>/dev/null | awk -v want_repo="$2" '
    /^type:/       { f=""; r="" }
    /^file:/       { f=$2 }
    /^repository:/ { r=$2 }
    f == "publish.yml" && r == want_repo { ok=1 }
    END { exit ok ? 0 : 1 }
  '
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
needs_trust=()   # packages never yet published via trusted publishing
needs_trust_for() { [[ " ${needs_trust[*]} " == *" $1 "* ]]; }
skipped=0

for repo in "${repos[@]}"; do
  [ -f "$repo/package.json" ] || continue

  read -r pkg version private < <(
    node -p '
      const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      [p.name||"-", p.version||"-", p.private?"private":"public"].join(" ")
    ' "$repo/package.json" 2>/dev/null
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

  # trusted: some version was already published via trusted publishing, so the
  # config exists and is validated (validated configs don't expire) — the trust
  # step, and its passkey prompt, can be skipped for this package.
  read -r exists cur_latest cur_beta trusted < <(
    printf '%s' "$json" | node -p '
      const d=JSON.parse(require("fs").readFileSync(0,"utf8"));
      const t=Object.values(d.versions).some(v=>v._npmUser?.trustedPublisher);
      [!!d.versions[process.argv[1]], d["dist-tags"].latest||"-", d["dist-tags"].beta||"-", t].join(" ")
    ' "$version" 2>/dev/null
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

  slug=$(origin_slug "$repo")
  plan+=("$pkg|$version|$repo|$slug|publish")
  if [ "$trusted" != true ] && ! trust_config_exists "$pkg" "$slug"; then
    needs_trust+=("$pkg")
  fi
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
    note=""; needs_trust_for "$pkg" && note=" ${warn}(first CI publish — passkey once)${off}"
    printf '  %-42s v%s → CI in %s%b\n' "$pkg" "$version" "$slug" "$note"; n_pub=$((n_pub + 1))
  fi
done
echo

if [ "$dry" = 1 ]; then
  printf '%d to publish, %d dist-tag repair(s), %d skipped. (--dry-run)\n' "$n_pub" "$n_tag" "$skipped"
  exit 0
fi

# ─── Phase 3: trust configs ───
untrusted=()
is_untrusted() { [[ " ${untrusted[*]} " == *" $1 "* ]]; }
trust_err=$(mktemp); trap 'rm -f "$trust_err"' EXIT
if [ "${#needs_trust[@]}" -gt 0 ]; then
  printf '%s── trusted publisher configs for %d first-time package(s) (approve once, tick "skip for 5 minutes") ──%s\n' \
    "$dim" "${#needs_trust[@]}" "$off"
  for entry in "${plan[@]}"; do
    IFS='|' read -r pkg version repo slug mode <<<"$entry"
    [ "$mode" = publish ] || continue
    needs_trust_for "$pkg" || continue
    # stdin/stdout must stay on the terminal: npm only offers the browser
    # (passkey) flow when they are a TTY, and fails with EOTP when captured —
    # which is how the first real run (frontend beta.56, 2026-10-10) reached CI
    # with no trust config and got E404. Only stderr is copied, to spot
    # "already exists".
    npm trust github "$pkg" --file publish.yml --repo "$slug" --allow-publish --yes 2> >(tee "$trust_err" >&2)
    rc=$?; wait $! 2>/dev/null   # let tee finish writing before grepping its file
    if [ "$rc" = 0 ]; then
      printf '%s✓ %-42s trusts %s publish.yml%s\n' "$ok" "$pkg" "$slug" "$off"
    elif grep -qiE 'already|exist|409|conflict' "$trust_err"; then
      printf '%s  %-42s already configured%s\n' "$dim" "$pkg" "$off"
    else
      # No trust = a guaranteed E404 in CI; keep the tag for a re-run instead.
      printf '%s✗ %-42s npm trust failed — not tagging it, re-run to retry%s\n' "$bad" "$pkg" "$off"
      untrusted+=("$pkg")
    fi
    sleep 2   # npm's own advice for bulk trust calls: avoid rate limiting
  done
fi

# ─── Phase 4: tags ───
[ "$n_pub" -gt 0 ] && printf '\n%s── pushing tags ──%s\n' "$dim" "$off"
for entry in "${plan[@]}"; do
  IFS='|' read -r pkg version repo slug mode <<<"$entry"
  [ "$mode" = publish ] || continue
  is_untrusted "$pkg" && continue
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
  # Sleep FIRST: right after a re-dispatch the newest run for the tag is still
  # the old failed one, which would end the wait before the new run registers.
  while sleep 20; do
    missing=0
    for entry in "${plan[@]}"; do
      IFS='|' read -r pkg version _ slug mode <<<"$entry"
      [ "$mode" = publish ] || continue
      is_untrusted "$pkg" && continue
      [ "$(registry_has "$pkg" "$version")" = true ] && continue
      # Its CI run for this tag already failed: nothing more is coming.
      [ "$(run_for_tag "$slug" "v$version" '.[0].conclusion')" = failure ] && continue
      missing=$((missing + 1))
    done
    if [ "$missing" -eq 0 ] || [ "$SECONDS" -ge "$deadline" ]; then break; fi
    printf '%s  %d pending…%s\n' "$dim" "$missing" "$off"
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
  elif is_untrusted "$pkg"; then
    printf '%s✗ %-42s %s not tagged — npm trust failed%s\n' "$bad" "$pkg" "$version" "$off"
    failed=$((failed + 1))
  elif [ "$(registry_has "$pkg" "$version")" = true ]; then
    printf '%s✓ %-42s %s live%s\n' "$ok" "$pkg" "$version" "$off"; published=$((published + 1))
  else
    run=$(run_for_tag "$slug" "v$version" '.[0] | "\(.status)/\(.conclusion) \(.url)"')
    printf '%s✗ %-42s %s NOT on npm%s %s\n' "$bad" "$pkg" "$version" "$off" "${run:-(no CI run found)}"
    failed=$((failed + 1))
  fi
done

printf '\n%d published, %d skipped, %d still missing' "$published" "$skipped" "$failed"
[ "$tags_wrong" -gt 0 ] && printf ', %d dist-tag(s) not moved' "$tags_wrong"
printf '\n'
[ "$failed" -eq 0 ] && [ "$tags_wrong" -eq 0 ]
