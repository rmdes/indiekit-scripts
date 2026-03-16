#!/usr/bin/env bash
# upstream-sync.sh — Compare @rmdes/* forks against upstream indiekit packages
#
# Usage:
#   upstream-sync.sh                            # Generate sync report
#   upstream-sync.sh --mark-synced <fork> <tag> # Record a new sync baseline tag
#
# Requirements: bash >=4.4, git, jq, diff
# Report output: $report_dir/upstream-sync-YYYY-MM-DD.md

set -Eeuo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly STATE_FILE="${SCRIPT_DIR}/sync-state.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_info()  { printf '[INFO]  %s\n' "$*" >&2; }
log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

die() {
  log_error "$*"
  exit 1
}

require_cmd() {
  command -v "$1" &>/dev/null || die "Required command not found: $1"
}

# ---------------------------------------------------------------------------
# Load state file
# ---------------------------------------------------------------------------

[[ -f "$STATE_FILE" ]] || die "State file not found: $STATE_FILE"

UPSTREAM_REPO="$(jq -r '.upstream_repo' "$STATE_FILE")"
WORKSPACE="$(jq -r '.workspace'   "$STATE_FILE")"
REPORT_DIR="$(jq -r '.report_dir' "$STATE_FILE")"

# ---------------------------------------------------------------------------
# --mark-synced handler (Tasks 2 — argument parsing)
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--mark-synced" ]]; then
  [[ $# -ge 3 ]] || die "Usage: $0 --mark-synced <fork-name> <tag>"

  FORK_NAME="$2"
  NEW_TAG="$3"

  # Validate the fork exists in the state file
  FORK_EXISTS="$(jq -r --arg f "$FORK_NAME" '.forks[$f] // empty' "$STATE_FILE")"
  [[ -n "$FORK_EXISTS" ]] || die "Fork '$FORK_NAME' not found in sync-state.json"

  # Write updated tag using a temp file (atomic replace)
  TMP_FILE="$(mktemp "${STATE_FILE}.tmp.XXXXXXXX")"
  trap 'rm -f -- "$TMP_FILE"' EXIT

  jq --arg f "$FORK_NAME" --arg t "$NEW_TAG" \
    '.forks[$f].last_synced_tag = $t' \
    "$STATE_FILE" > "$TMP_FILE"
  mv -- "$TMP_FILE" "$STATE_FILE"
  trap - EXIT

  printf 'Updated %s last_synced_tag → %s\n' "$FORK_NAME" "$NEW_TAG"
  exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

require_cmd git
require_cmd jq
require_cmd diff

[[ -d "$UPSTREAM_REPO" ]]      || die "Upstream repo not found: $UPSTREAM_REPO"
[[ -d "${UPSTREAM_REPO}/.git" ]] || die "Not a git repo: $UPSTREAM_REPO"

# ---------------------------------------------------------------------------
# Task 3 — Fetch upstream tags, detect latest, set up report file
# ---------------------------------------------------------------------------

log_info "Fetching upstream tags from ${UPSTREAM_REPO} ..."
git -C "$UPSTREAM_REPO" fetch --tags --quiet 2>/dev/null || log_warn "git fetch failed — working with local tags"

LATEST_TAG="$(git -C "$UPSTREAM_REPO" tag --sort=-version:refname | head -1)"
[[ -n "$LATEST_TAG" ]] || die "No tags found in upstream repo"
log_info "Latest upstream tag: $LATEST_TAG"

TODAY="$(date +%Y-%m-%d)"
NOW="$(date +%Y-%m-%dT%H:%M:%S)"
REPORT_FILE="${REPORT_DIR}/upstream-sync-${TODAY}.md"

mkdir -p "$REPORT_DIR"
log_info "Report will be written to: $REPORT_FILE"

# ---------------------------------------------------------------------------
# Task 4 — Collect per-fork data, build summary and detail sections
# ---------------------------------------------------------------------------

# Summary table rows (collected while processing each fork)
SUMMARY_ROWS=""

# Detail sections (collected while processing each fork)
DETAIL_SECTIONS=""

# Read all fork keys sorted
mapfile -t FORK_NAMES < <(jq -r '.forks | keys_unsorted | sort[]' "$STATE_FILE")

for FORK_NAME in "${FORK_NAMES[@]}"; do
  UPSTREAM_PKG="$(jq -r --arg f "$FORK_NAME" '.forks[$f].upstream_package' "$STATE_FILE")"
  LAST_TAG="$(    jq -r --arg f "$FORK_NAME" '.forks[$f].last_synced_tag'   "$STATE_FILE")"

  FORK_PATH="${WORKSPACE}/${FORK_NAME}"
  UPSTREAM_PKG_PATH="${UPSTREAM_REPO}/packages/${UPSTREAM_PKG}"

  log_info "Processing ${FORK_NAME} (upstream: ${UPSTREAM_PKG}, since: ${LAST_TAG}) ..."

  # Validate paths
  if [[ ! -d "$FORK_PATH" ]]; then
    log_warn "Fork directory not found: $FORK_PATH — skipping"
    SUMMARY_ROWS+="| \`${FORK_NAME}\` | ${LAST_TAG} | — | — | — | MISSING FORK DIR |\n"
    continue
  fi
  if [[ ! -d "$UPSTREAM_PKG_PATH" ]]; then
    log_warn "Upstream package not found: $UPSTREAM_PKG_PATH — skipping"
    SUMMARY_ROWS+="| \`${FORK_NAME}\` | ${LAST_TAG} | — | — | — | MISSING UPSTREAM |\n"
    continue
  fi

  # Count upstream commits since last sync tag for this package's subdirectory
  UPSTREAM_COMMITS="$(git -C "$UPSTREAM_REPO" log --oneline \
    "${LAST_TAG}..HEAD" -- "packages/${UPSTREAM_PKG}/" 2>/dev/null | wc -l | tr -d ' ')"

  # Count changed files in upstream since last sync
  UPSTREAM_CHANGED_FILES="$(git -C "$UPSTREAM_REPO" diff --name-only \
    "${LAST_TAG}..HEAD" -- "packages/${UPSTREAM_PKG}/" 2>/dev/null | wc -l | tr -d ' ')"

  # Tags behind (how many tags after LAST_TAG)
  TAGS_BEHIND="$(git -C "$UPSTREAM_REPO" tag --sort=version:refname \
    | awk -v last="$LAST_TAG" 'found{count++} $0==last{found=1} END{print count+0}')"

  if [[ "$UPSTREAM_COMMITS" -eq 0 ]]; then
    SUMMARY_ROWS+="| \`${FORK_NAME}\` | ${LAST_TAG} | 0 | 0 | 0 | Up to date |\n"
    continue
  fi

  # -------------------------------------------------------------------------
  # Task 5 — Generate per-fork detail sections
  # -------------------------------------------------------------------------

  SECTION=""
  CONFLICT_COUNT=0
  CONFLICT_FILES=""

  SECTION+="## ${FORK_NAME}\n\n"
  SECTION+="> **Upstream package:** \`packages/${UPSTREAM_PKG}\`  \n"
  SECTION+="> **Last synced tag:** \`${LAST_TAG}\`  \n"
  SECTION+="> **Upstream commits since sync:** ${UPSTREAM_COMMITS}  \n"
  SECTION+="> **Files changed upstream:** ${UPSTREAM_CHANGED_FILES}\n\n"

  # ---- Section 5.1: Upstream commits ----
  SECTION+="### Upstream Commits Since Last Sync\n\n"
  COMMIT_LOG="$(git -C "$UPSTREAM_REPO" log \
    --format='%h — %s (%an)' \
    "${LAST_TAG}..HEAD" -- "packages/${UPSTREAM_PKG}/" 2>/dev/null)"

  if [[ -n "$COMMIT_LOG" ]]; then
    while IFS= read -r line; do
      # Extract hash (first word) and wrap it in backticks
      HASH="${line%% *}"
      REST="${line#* }"
      SECTION+="- \`${HASH}\` — ${REST}\n"
    done <<< "$COMMIT_LOG"
  else
    SECTION+="_No commits found for this package path._\n"
  fi
  SECTION+="\n"

  # ---- Section 5.2: Changed files with conflict risk ----
  SECTION+="### Upstream Changed Files with Conflict Risk\n\n"
  SECTION+="| File | Insertions | Deletions | Conflict Risk |\n"
  SECTION+="|------|------------|-----------|---------------|\n"

  mapfile -t CHANGED_FILES < <(git -C "$UPSTREAM_REPO" diff --name-only \
    "${LAST_TAG}..HEAD" -- "packages/${UPSTREAM_PKG}/" 2>/dev/null)

  for UPSTREAM_FILE in "${CHANGED_FILES[@]}"; do
    # Strip packages/<name>/ prefix to get relative path
    REL_FILE="${UPSTREAM_FILE#packages/${UPSTREAM_PKG}/}"

    # Get numstat for this file (insertions deletions)
    NUMSTAT="$(git -C "$UPSTREAM_REPO" diff --numstat \
      "${LAST_TAG}..HEAD" -- "$UPSTREAM_FILE" 2>/dev/null | head -1)"
    INS="${NUMSTAT%%	*}"
    DEL_REST="${NUMSTAT#*	}"
    DEL="${DEL_REST%%	*}"
    [[ -z "$INS" ]] && INS=0
    [[ -z "$DEL" ]] && DEL=0

    # Check conflict risk: does fork also differ from upstream HEAD for this file?
    FORK_FILE="${FORK_PATH}/${REL_FILE}"
    CONFLICT="NO"
    if [[ -f "$FORK_FILE" ]]; then
      UPSTREAM_HEAD_CONTENT="$(git -C "$UPSTREAM_REPO" show \
        "HEAD:packages/${UPSTREAM_PKG}/${REL_FILE}" 2>/dev/null || true)"
      FORK_CONTENT="$(cat -- "$FORK_FILE" 2>/dev/null || true)"
      if [[ -n "$UPSTREAM_HEAD_CONTENT" && "$UPSTREAM_HEAD_CONTENT" != "$FORK_CONTENT" ]]; then
        CONFLICT="**YES**"
        (( CONFLICT_COUNT++ )) || true
        CONFLICT_FILES+="  - \`${REL_FILE}\`\n"
      fi
    fi

    SECTION+="| \`${REL_FILE}\` | +${INS} | -${DEL} | ${CONFLICT} |\n"
  done
  SECTION+="\n"

  # ---- Section 5.3: Conflict risk details ----
  if [[ $CONFLICT_COUNT -gt 0 ]]; then
    SECTION+="### Conflict Risk Details\n\n"
    SECTION+="_Files where both upstream and fork have diverged from the sync baseline:_\n\n"
    SECTION+="${CONFLICT_FILES}\n"

    for UPSTREAM_FILE in "${CHANGED_FILES[@]}"; do
      REL_FILE="${UPSTREAM_FILE#packages/${UPSTREAM_PKG}/}"
      FORK_FILE="${FORK_PATH}/${REL_FILE}"
      [[ -f "$FORK_FILE" ]] || continue

      UPSTREAM_HEAD_CONTENT="$(git -C "$UPSTREAM_REPO" show \
        "HEAD:packages/${UPSTREAM_PKG}/${REL_FILE}" 2>/dev/null || true)"
      FORK_CONTENT="$(cat -- "$FORK_FILE" 2>/dev/null || true)"
      [[ "$UPSTREAM_HEAD_CONTENT" == "$FORK_CONTENT" ]] && continue

      SECTION+="#### \`${REL_FILE}\`\n\n"
      SECTION+="\`\`\`diff\n"
      DIFF_OUTPUT="$(diff -u \
        <(printf '%s\n' "$UPSTREAM_HEAD_CONTENT") \
        <(printf '%s\n' "$FORK_CONTENT") 2>/dev/null | head -50 || true)"
      SECTION+="${DIFF_OUTPUT}\n"
      SECTION+="\`\`\`\n\n"
    done
  fi

  # ---- Section 5.4: Fork-only files ----
  SECTION+="### Fork-Only Files (not in upstream)\n\n"
  FORK_ONLY_FILES=""
  while IFS= read -r -d '' FFILE; do
    REL="${FFILE#${FORK_PATH}/}"
    UPSTREAM_EQUIV="${UPSTREAM_PKG_PATH}/${REL}"
    if [[ ! -f "$UPSTREAM_EQUIV" ]]; then
      FORK_ONLY_FILES+="- \`${REL}\`\n"
    fi
  done < <(find "$FORK_PATH" \
    -not -path '*/.git/*' \
    -not -path '*/node_modules/*' \
    -type f -print0)

  if [[ -n "$FORK_ONLY_FILES" ]]; then
    SECTION+="${FORK_ONLY_FILES}\n"
  else
    SECTION+="_None — all fork files have upstream equivalents._\n\n"
  fi

  # ---- Section 5.5: Fork modifications to upstream files ----
  SECTION+="### Fork Modifications to Upstream Files\n\n"
  SECTION+="| File | Lines Differ |\n"
  SECTION+="|------|--------------|\n"
  MOD_FOUND=0

  while IFS= read -r -d '' UFILE; do
    REL="${UFILE#${UPSTREAM_PKG_PATH}/}"
    FORK_FILE="${FORK_PATH}/${REL}"
    [[ -f "$FORK_FILE" ]] || continue

    UPSTREAM_CONTENT="$(cat -- "$UFILE" 2>/dev/null || true)"
    FORK_CONTENT="$(cat -- "$FORK_FILE" 2>/dev/null || true)"
    [[ "$UPSTREAM_CONTENT" == "$FORK_CONTENT" ]] && continue

    DIFF_LINES="$(diff <(printf '%s\n' "$UPSTREAM_CONTENT") \
      <(printf '%s\n' "$FORK_CONTENT") 2>/dev/null | grep -c '^[<>]' || true)"
    SECTION+="| \`${REL}\` | ${DIFF_LINES} |\n"
    MOD_FOUND=1
  done < <(find "$UPSTREAM_PKG_PATH" -type f -print0)

  if [[ $MOD_FOUND -eq 0 ]]; then
    # Remove the table header lines and replace with a note
    # Strip the last two lines of SECTION (| File | ... and |----)
    SECTION="${SECTION%| File | Lines Differ |*}"
    SECTION+="_No differences found between fork and upstream HEAD files._\n\n"
  else
    SECTION+="\n"
  fi

  # ---- Section 5.6: Dependency drift ----
  SECTION+="### Dependency Drift\n\n"

  FORK_PKG_JSON="${FORK_PATH}/package.json"
  UPSTREAM_PKG_JSON="${UPSTREAM_PKG_PATH}/package.json"

  if [[ -f "$FORK_PKG_JSON" && -f "$UPSTREAM_PKG_JSON" ]]; then
    SECTION+="| Dependency | Fork Version | Upstream Version | Type |\n"
    SECTION+="|-----------|--------------|-----------------|------|\n"
    DRIFT_FOUND=0

    # Merge dependencies and devDependencies from both package.json files
    # For each package name, compare versions
    ALL_DEPS="$(jq -r '
      [(.dependencies // {}), (.devDependencies // {})] |
      add // {} |
      keys[]
    ' "$UPSTREAM_PKG_JSON" "$FORK_PKG_JSON" 2>/dev/null | sort -u)"

    while IFS= read -r DEP; do
      [[ -z "$DEP" ]] && continue

      FORK_VER="$(jq -r --arg d "$DEP" \
        '(.dependencies[$d] // .devDependencies[$d]) // ""' \
        "$FORK_PKG_JSON" 2>/dev/null)"
      UP_VER="$(jq -r --arg d "$DEP" \
        '(.dependencies[$d] // .devDependencies[$d]) // ""' \
        "$UPSTREAM_PKG_JSON" 2>/dev/null)"

      [[ "$FORK_VER" == "$UP_VER" ]] && continue
      [[ -z "$FORK_VER" && -z "$UP_VER" ]] && continue

      # Determine dep type from fork (fallback to upstream)
      DEP_TYPE="$(jq -r --arg d "$DEP" \
        'if .dependencies[$d] then "dep" elif .devDependencies[$d] then "devDep" else "" end' \
        "$FORK_PKG_JSON" 2>/dev/null)"
      [[ -z "$DEP_TYPE" ]] && DEP_TYPE="$(jq -r --arg d "$DEP" \
        'if .dependencies[$d] then "dep" elif .devDependencies[$d] then "devDep" else "?" end' \
        "$UPSTREAM_PKG_JSON" 2>/dev/null)"

      FORK_DISPLAY="${FORK_VER:-_(not present)_}"
      UP_DISPLAY="${UP_VER:-_(not present)_}"
      SECTION+="| \`${DEP}\` | ${FORK_DISPLAY} | ${UP_DISPLAY} | ${DEP_TYPE} |\n"
      DRIFT_FOUND=1
    done <<< "$ALL_DEPS"

    if [[ $DRIFT_FOUND -eq 0 ]]; then
      SECTION="${SECTION%| Dependency *}"
      SECTION+="_No dependency drift detected._\n\n"
    else
      SECTION+="\n"
    fi
  else
    SECTION+="_Could not compare package.json files (one or both missing)._\n\n"
  fi

  SECTION+="\n---\n\n"

  # Accumulate detail section and summary row (with real conflict count)
  DETAIL_SECTIONS+="$SECTION"
  SUMMARY_ROWS+="| \`${FORK_NAME}\` | ${LAST_TAG} | ${UPSTREAM_COMMITS} | ${UPSTREAM_CHANGED_FILES} | ${TAGS_BEHIND} | ${CONFLICT_COUNT} conflict(s) |\n"

  log_info "  ${FORK_NAME}: ${UPSTREAM_COMMITS} commit(s), ${UPSTREAM_CHANGED_FILES} file(s), ${CONFLICT_COUNT} conflict(s)"
done

# ---------------------------------------------------------------------------
# Task 4 — Write report header + summary table, then append detail sections
# ---------------------------------------------------------------------------

log_info "Writing report to ${REPORT_FILE} ..."

{
  printf '# Upstream Sync Report\n\n'
  printf '**Generated:** %s  \n' "$NOW"
  printf '**Upstream repo:** `%s`  \n' "$UPSTREAM_REPO"
  printf '**Latest upstream tag:** `%s`  \n\n' "$LATEST_TAG"

  printf '## Summary\n\n'
  printf '| Fork | Last Synced Tag | Upstream Commits | Changed Files | Tags Behind | Status |\n'
  printf '|------|----------------|-----------------|---------------|-------------|--------|\n'

  # Print collected summary rows (interpret escape sequences)
  printf '%b' "$SUMMARY_ROWS"

  printf '\n---\n\n'
  printf '## Fork Details\n\n'
  printf '_Only forks with upstream changes since the last sync tag are shown below._\n\n'

  # Print all detail sections
  printf '%b' "$DETAIL_SECTIONS"

} > "$REPORT_FILE"

printf '\nReport written to: %s\n' "$REPORT_FILE"
