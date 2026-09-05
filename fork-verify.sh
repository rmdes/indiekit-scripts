#!/usr/bin/env bash
# fork-verify.sh — run upstream's test suite, eslint and prettier against a fork
#
#   fork-verify.sh <fork-dir> <upstream-pkg> [baseline]
#
#   Fork tests import the monorepo's @indiekit-test/* helpers and cannot run
#   standalone, so the fork's lib/views/locales/test/… are copied over
#   packages/<pkg>/ in indiekit-origin, the package suite is run, and the
#   pristine tree is restored (git checkout + git clean on that package only).
#   Pass `baseline` to first run the untouched upstream suite for comparison.
#
# Env: WORKSPACE (default ~/indiekit), UPSTREAM (default $WORKSPACE/indiekit-origin)
set -uo pipefail
WORKSPACE=${WORKSPACE:-$HOME/indiekit}
U=${UPSTREAM:-$WORKSPACE/indiekit-origin}
F=$WORKSPACE/$1; PKG=$2
cd "$U"
export NODE_ENV=test SECRET=test PASSWORD_SECRET=test
restore(){ git checkout -q -- "packages/$PKG"; git clean -qfd "packages/$PKG"; echo "restored: $(git status --short "packages/$PKG" | wc -l) dirty"; }
trap restore EXIT
run(){ node --test --test-reporter=spec packages/$PKG/test/**/*.js packages/$PKG/test/*.js 2>&1 | grep -E '✖|ℹ (tests|pass|fail)'; }
if [ "${3:-}" = "baseline" ]; then echo "--- baseline (pristine upstream) ---"; run; fi
for d in lib views locales assets components layouts scripts styles helpers index.js test; do
  [ -e "$F/$d" ] && { rm -rf "packages/$PKG/$d"; cp -r "$F/$d" "packages/$PKG/"; }
done
echo "--- fork overlay ---"; run
echo "--- eslint ---"; npx eslint "packages/$PKG" --ignore-pattern '**/test/**' >/dev/null && echo ok \
  || npx eslint "packages/$PKG" --ignore-pattern '**/test/**' 2>&1 | grep -E 'error|warning' | head -20
echo "--- prettier ---"; npx prettier --check "packages/$PKG/**/*.{js,json}" 2>&1 | tail -1
