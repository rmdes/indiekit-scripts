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
node -e 'process.exit(typeof require("node:crypto").randomUUIDv7 === "function" ? 0 : 1)' || {
  echo "ERROR: this Node ($(node -v)) has no crypto.randomUUIDv7, which upstream's"
  echo "       util/endpoint-media/endpoint-micropub import. Upstream pins $(cat .nvmrc 2>/dev/null || echo '24.17')."
  echo "       Run: nvm install $(cat .nvmrc 2>/dev/null || echo '24.17') && nvm use $(cat .nvmrc 2>/dev/null || echo '24.17')"
  exit 1; }
LINKED=()
restore(){
  git checkout -q -- "packages/$PKG"; git clean -qfd "packages/$PKG"
  for l in "${LINKED[@]:-}"; do [ -n "$l" ] && rm -f "node_modules/$l"; done
  echo "restored: $(git status --short "packages/$PKG" | wc -l) dirty"
}
trap restore EXIT
# FV_FULL=1 keeps the whole reporter output — needed to see WHY a test failed,
# since the summary grep throws the assertion diff away.
run(){ shopt -s globstar nullglob
  if [ -n "${FV_FULL:-}" ]; then node --test --test-reporter=spec packages/$PKG/test/**/*.js packages/$PKG/test/*.js 2>&1
  else node --test --test-reporter=spec packages/$PKG/test/**/*.js packages/$PKG/test/*.js 2>&1 | grep -E '✖|ℹ (tests|pass|fail)'; fi; }
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
