#!/usr/bin/env bash
#
# workspace-state.sh — one-screen status of the indiekit workspace.
#
# Answers "what is actually open right now" without opening fifteen tabs:
#   A. open PRs across every rmdes/indiekit-* repo, with merge state
#   B. @indiekit/* ranges that cannot resolve (delegates to check-peer-ranges.sh)
#   C. Renovate / CI coverage per repo
#   D. upstream items we are waiting on or blocking
#
# Everything is read from GitHub, never from local clones — a local clone can be
# several releases behind its own main and will report state you have already fixed.
#
# Usage:
#   ./workspace-state.sh            # all sections
#   ./workspace-state.sh prs        # one section: prs | ranges | coverage | upstream
#
# Requires: gh (authenticated), node.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECTION="${1:-all}"

repos() {
  gh repo list rmdes --limit 200 --json name --jq '.[].name' | grep -E '^indiekit' | sort
}

section_prs() {
  echo "=== A. Open PRs ==="
  local any=0
  for r in $(repos); do
    out=$(gh pr list --repo "rmdes/$r" --state open --limit 20 \
          --json number,title,mergeStateStatus,isDraft \
          --jq '.[] | "    #\(.number) \(.mergeStateStatus)\(if .isDraft then "/draft" else "" end)  \(.title[0:64])"' 2>/dev/null)
    if [ -n "$out" ]; then echo "  $r"; echo "$out"; any=1; fi
  done
  [ "$any" -eq 0 ] && echo "  (none)"
  echo
  echo "  UNSTABLE is often just a Renovate stability gate, not a failure —"
  echo "  check with: gh pr checks <n> --repo rmdes/<repo>"
}

section_ranges() {
  echo "=== B. Unusable @indiekit/* ranges ==="
  if [ -x "$HERE/check-peer-ranges.sh" ]; then
    "$HERE/check-peer-ranges.sh"
  else
    echo "  check-peer-ranges.sh not found alongside this script"
  fi
}

section_coverage() {
  echo "=== C. Renovate / CI coverage ==="
  printf '  %-40s %-10s %-9s %s\n' REPO RENOVATE CI TESTS
  for r in $(repos); do
    ren=$(gh api "repos/rmdes/$r/contents/renovate.json" --jq '.name' 2>&1 | grep -q 'Not Found' && echo "-" || echo "yes")
    ci=$(gh api "repos/rmdes/$r/contents/.github/workflows" --jq '[.[].name]|join(",")' 2>&1 | grep -q 'Not Found' && echo "-" || echo "yes")
    tst=$(gh api "repos/rmdes/$r/contents/package.json" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null | \
          node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const p=JSON.parse(s);const t=p.scripts&&p.scripts.test;console.log(!t||/no test specified/.test(t)?"-":"yes")}catch(e){console.log("-")}})' 2>/dev/null)
    printf '  %-40s %-10s %-9s %s\n' "$r" "$ren" "$ci" "${tst:--}"
  done
  echo
  echo "  CI absent + tests present = a PR reporting CLEAN means 'no checks configured'."
}

section_upstream() {
  echo "=== D. Upstream (getindiekit/indiekit) ==="
  for n in "$@"; do
    gh pr view "$n" --repo getindiekit/indiekit \
      --json number,title,state,isDraft,mergeStateStatus,headRepositoryOwner \
      --jq '"  #\(.number) PR \(.state)\(if .isDraft then "/draft" else "" end) \(.mergeStateStatus) head=\(.headRepositoryOwner.login)  \(.title[0:52])"' 2>/dev/null \
    || gh issue view "$n" --repo getindiekit/indiekit --json number,title,state \
        --jq '"  #\(.number) issue \(.state)  \(.title[0:52])"' 2>/dev/null \
    || echo "  #$n  (discussion, or not found)"
  done
  echo
  echo "  head=rmdes means the PR was opened from the fork: CI cannot reach the"
  echo "  Localazy secret, so the suite never runs. Branch on getindiekit/indiekit."
}

case "$SECTION" in
  prs)      section_prs ;;
  ranges)   section_ranges ;;
  coverage) section_coverage ;;
  upstream) section_upstream 893 916 880 879 902 885 843 860 ;;
  all)
    section_prs; echo
    section_ranges; echo
    section_upstream 893 916 880 879 902 885 843 860; echo
    echo "(run './workspace-state.sh coverage' for the Renovate/CI matrix — it is slower)"
    ;;
  *) echo "unknown section: $SECTION (use prs | ranges | coverage | upstream)"; exit 1 ;;
esac
