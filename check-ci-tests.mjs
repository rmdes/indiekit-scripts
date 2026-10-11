// check-ci-tests.mjs — would any repo's `npm test` die on @indiekit-test/*?
//
// Since trusted publishing, `npm test` runs on the publish critical path, so a
// test that cannot run standalone is a failed release rather than a local
// annoyance. @indiekit-test/* are workspace packages private to upstream's
// monorepo and 404 on npm, so any test importing them can only run through
// indiekit-scripts/fork-verify.sh, which overlays the fork onto
// indiekit-origin.
//
// This resolves each repo's test script to the exact file set it executes --
// including node's own discovery for a bare `node --test`, which walks test/
// AND tests/ at any depth -- and fails if any of those files import a helper.
//
// It exists because @rmdes/indiekit-endpoint-syndicate v1.0.0-beta.47 failed to
// publish this way: its script was changed to a bare `node --test`, which then
// discovered three fork-override integration tests that need the helpers.
//
// Convention this enforces, as endpoint-micropub and endpoint-syndicate use it:
//   test/   suites overlaid onto upstream by fork-verify.sh; may use helpers
//   tests/  standalone suites; run by `npm test`; no helpers
// A repo holding both MUST point its test script at tests/ explicitly -- a bare
// `node --test` would discover test/ too.
//
//   node check-ci-tests.mjs    # exit 1 if any repo would fail CI

// For every published plugin repo: resolve exactly which files its `npm test`
// executes, and assert none of them import @indiekit-test/* — those are
// upstream monorepo workspace packages, 404 on npm, so CI dies on them.
import { globSync, readFileSync, existsSync, readdirSync } from "node:fs";
import path from "node:path";

const ROOT = "/home/rick/code/indiekit-dev";
const SKIP = new Set([
  "indiekit", "indiekit-origin", "indiekit-blog", "indiekit-cloudron",
  "indiekit-deploy", "indiekit-eleventy-theme", "indiekit-plugin-registry",
  "indiekit-endpoint-bluesky-pds", "indiekit-atproto-utils",
  "indiekit-endpoint-donation", "indiekit-endpoint-files", "indiekit-scripts",
  "indiekit-mcp-micropub", "documentation-central", "activitypub-tests",
  "indiekit-startup-gate",
]);

const walk = (dir, acc = []) => {
  if (!existsSync(dir)) return acc;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.name === "node_modules") continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, acc);
    else if (/\.(js|mjs)$/.test(e.name)) acc.push(p);
  }
  return acc;
};

let bad = 0;
const rows = [];

for (const repo of readdirSync(ROOT).sort()) {
  if (SKIP.has(repo)) continue;
  const dir = path.join(ROOT, repo);
  if (!existsSync(path.join(dir, "package.json")) || !existsSync(path.join(dir, ".git"))) continue;

  const pkg = JSON.parse(readFileSync(path.join(dir, "package.json"), "utf8"));
  const script = pkg.scripts?.test;
  if (!script) continue;

  // Resolve the file set the script actually runs.
  let files = [];
  const args = script.match(/(?:"[^"]*"|\S+)/g)
    .map((a) => a.replaceAll('"', ""))
    .filter((a) => !a.startsWith("-") && a !== "node" && !/^[A-Z_][A-Z0-9_]*=/.test(a));

  if (args.length === 0) {
    // bare `node --test` -> node's own discovery: test/ and tests/, any depth
    files = [...walk(path.join(dir, "test")), ...walk(path.join(dir, "tests"))]
      .map((f) => path.relative(dir, f));
  } else {
    for (const a of args) {
      try { files.push(...globSync(a, { cwd: dir })); } catch {}
    }
  }
  files = [...new Set(files)];

  const offenders = files.filter((f) => {
    try { return /@indiekit-test\//.test(readFileSync(path.join(dir, f), "utf8")); }
    catch { return false; }
  });

  if (offenders.length) bad++;
  rows.push({ repo, script, n: files.length, offenders });
}

for (const r of rows) {
  const flag = r.offenders.length ? "  <-- WOULD FAIL CI" : "";
  console.log(`${r.repo.padEnd(36)} ${String(r.n).padStart(3)} file(s)  ${r.script}${flag}`);
  for (const o of r.offenders) console.log(`    needs @indiekit-test/*: ${o}`);
}
console.log(`\nrepos whose npm test would hit the helper wall: ${bad}`);
process.exit(bad ? 1 : 0);
