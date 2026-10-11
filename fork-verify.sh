#!/usr/bin/env bash
# fork-verify.sh — run upstream's test suite, typecheck, eslint and prettier against a fork
#
#   fork-verify.sh <fork-dir> <upstream-pkg> [baseline]
#
#   Fork tests import the monorepo's @indiekit-test/* helpers and cannot run
#   standalone, so the fork's lib/views/locales/… are copied over
#   packages/<pkg>/ in indiekit-origin, the package suite is run, and the
#   pristine tree is restored (git checkout + git clean on that package only).
#   Pass `baseline` to first run the untouched upstream suite for comparison.
#
#   The fork's test/ is MERGED on top of upstream's, not swapped in, so a fork
#   only needs to hold the suites that are actually its own. Keeping a copy of
#   upstream's tests in a fork buys nothing and rots: the copy wins, and tests
#   upstream adds later never run.
#
#   Run ONE AT A TIME. Every invocation overlays the same indiekit-origin tree,
#   so two concurrent runs corrupt each other's package and each other's restore.
#
#   Env: FV_FULL=1 full reporter output (needed to see WHY a test failed)
#        FV_EXCLUDE=<regex> skip matching test files
#        FV_TIMEOUT=<ms> per-test timeout (default 120000)
#        FV_WALL=<s> wall clock for the whole run (default 300)
#
#   syndicator-bluesky needs FV_EXCLUDE='test/index\.js$': that file's before()
#   hook calls TestNetworkNoAppView.create(), which never resolves here, and a
#   hanging hook is not bounded by --test-timeout.
#
# Env: WORKSPACE (default ~/indiekit), UPSTREAM (default $WORKSPACE/indiekit-origin)
set -uo pipefail
WORKSPACE=${WORKSPACE:-$HOME/indiekit}
U=${UPSTREAM:-$WORKSPACE/indiekit-origin}
F=$WORKSPACE/$1; PKG=$2
cd "$U"
export NODE_ENV=test SECRET=test PASSWORD_SECRET=test

# Preflight. Both of these fail as a wall of unrelated test errors rather than as
# themselves, so check them up front: a missing workspace install made every
# suite report "Cannot find package '@indiekit-test/server'", and a Node without
# crypto.randomUUIDv7 makes upstream's own code fail to parse.
[ -e node_modules/@indiekit-test/server ] || {
  echo "ERROR: $U has no workspace install — @indiekit-test/* are not linked."
  echo "       Run: (cd $U && npm ci)   # ci, not install: package-lock.json is tracked here"
  exit 1; }
# Upstream's util/endpoint-media/endpoint-micropub import crypto.randomUUIDv7,
# which landed in 24.17 (upstream's .nvmrc) — 22, 23, 24.8, 24.13 and 25.5 all
# lack it, and without it upstream's own code fails to PARSE, so every suite
# dies on a SyntaxError that names none of this. Rather than make the caller
# manage PATH (Homebrew's node shadows nvm's here, and it owns the cloudron
# CLI so it cannot simply be removed), find the pinned runtime and use it.
has_uuidv7(){ "$1" -e 'process.exit(typeof require("node:crypto").randomUUIDv7==="function"?0:1)' 2>/dev/null; }
if ! has_uuidv7 node; then
  WANT=$(cat .nvmrc 2>/dev/null || echo 24.17)
  for c in "$HOME/.nvm/versions/node/v$WANT"*/bin; do
    [ -x "$c/node" ] && has_uuidv7 "$c/node" && { PATH="$c:$PATH"; export PATH; break; }
  done
fi
has_uuidv7 node || {
  echo "ERROR: no Node with crypto.randomUUIDv7, which upstream's util,"
  echo "       endpoint-media and endpoint-micropub import. Active: $(node -v)."
  echo "       Upstream pins $(cat .nvmrc 2>/dev/null || echo 24.17)."
  echo "       Run: nvm install $(cat .nvmrc 2>/dev/null || echo 24.17)"
  exit 1; }
echo "node: $(node -v)"
LINKED=()
restore(){
  git checkout -q -- "packages/$PKG"; git clean -qfd "packages/$PKG"
  for l in "${LINKED[@]:-}"; do [ -n "$l" ] && rm -f "node_modules/$l"; done
  echo "restored: $(git status --short "packages/$PKG" | wc -l) dirty"
}
trap restore EXIT
# FV_FULL=1 keeps the whole reporter output — needed to see WHY a test failed,
# since the summary grep throws the assertion diff away.
#
# Two things here are load-bearing:
#  - Bail out when the globs match nothing. `node --test` with no path argument
#    falls back to discovering the WHOLE monorepo, so a package without tests
#    (post-type-page) silently ran every other package's suite instead.
#  - `--test-timeout`. Upstream runs with no timeout, and
#    syndicator-bluesky/test/index.js hangs forever on
#    `TestNetworkNoAppView.create()` (it wants a Postgres that nothing starts),
#    so a run would burn its entire budget and report nothing at all.
#    FV_TIMEOUT overrides; 120000ms is well clear of a slow integration test.
run(){ shopt -s globstar nullglob
  local all=(packages/$PKG/test/**/*.js packages/$PKG/test/*.js) files=() f
  for f in "${all[@]}"; do
    if [ -n "${FV_EXCLUDE:-}" ] && [[ "$f" =~ $FV_EXCLUDE ]]; then echo "(excluded: $f)"; continue; fi
    files+=("$f")
  done
  if [ ${#files[@]} -eq 0 ]; then echo "(no test files to run in packages/$PKG/test)"; return 0; fi

  # --test-timeout bounds a TEST; it does not bound a hanging before() hook, so
  # the wall clock is the real safety net. Without it a hang reports nothing at
  # all — no summary, no failure — and looks identical to a package that has no
  # tests. FV_WALL overrides.
  local wall="${FV_WALL:-300}" rc=0
  if [ -n "${FV_FULL:-}" ]; then
    timeout "$wall" node --test --test-reporter=spec --test-timeout="${FV_TIMEOUT:-120000}" "${files[@]}" 2>&1
    rc=$?
  else
    timeout "$wall" node --test --test-reporter=spec --test-timeout="${FV_TIMEOUT:-120000}" "${files[@]}" 2>&1 \
      | grep -E '✖|ℹ (tests|pass|fail)'
    rc=${PIPESTATUS[0]}
  fi
  [ "$rc" = 124 ] && echo "TIMED OUT after ${wall}s — a test or a hook is hanging, see FV_EXCLUDE"
  return 0
}
if [ "${3:-}" = "baseline" ]; then echo "--- baseline (pristine upstream) ---"; run; fi
for d in lib views locales assets components layouts scripts styles helpers index.js; do
  [ -e "$F/$d" ] && { rm -rf "packages/$PKG/$d"; cp -r "$F/$d" "packages/$PKG/"; }
done
# test/ MERGES, it does not replace: a fork carries only its own suites and lets
# upstream's come from upstream. Replacing the directory froze a snapshot, so any
# test upstream added afterwards was silently dropped from the run.
[ -e "$F/test" ] && { mkdir -p "packages/$PKG/test"; cp -r "$F/test/." "packages/$PKG/test/"; }
# A fork may depend on packages upstream does not have (e.g. alpinejs); link
# them in so the typechecker can resolve them, and unlink on exit.
for dep in $(node -p "Object.keys(require('$F/package.json').dependencies || {}).join(' ')"); do
  [ -e "node_modules/$dep" ] || [ ! -e "$F/node_modules/$dep" ] && continue
  mkdir -p "node_modules/$(dirname "$dep")"; ln -s "$F/node_modules/$dep" "node_modules/$dep"; LINKED+=("$dep")
done
echo "--- fork overlay ---"; run
# Upstream CI runs `npm run typecheck` before the tests (since 2026-09-12);
# tsc checks the whole repo, so keep only this package's lines.
echo "--- typecheck ---"; npm run typecheck 2>&1 | grep "^packages/$PKG/" > /tmp/fork-verify-tsc.$$ || true
if [ -s /tmp/fork-verify-tsc.$$ ]; then echo "$(wc -l < /tmp/fork-verify-tsc.$$) errors"; head -20 /tmp/fork-verify-tsc.$$; else echo ok; fi
rm -f /tmp/fork-verify-tsc.$$
echo "--- eslint ---"; npx eslint "packages/$PKG" --ignore-pattern '**/test/**' >/dev/null && echo ok \
  || npx eslint "packages/$PKG" --ignore-pattern '**/test/**' --quiet 2>&1 | head -20
echo "--- prettier ---"; npx prettier --check "packages/$PKG/**/*.{js,json}" 2>&1 | tail -1
