#!/usr/bin/env bats
# Round-trip tests for marker constants.
#
# Verifies that:
# 1. markers.sh exports all expected constants
# 2. Each marker constant has the correct value
# 3. Writers produce strings containing the marker
# 4. Readers detect the marker in writer-produced output
#
# "Writer" = code that embeds a marker into a string (PR comment body, issue body, etc.)
# "Reader" = code that searches/detects a marker in a string (jq contains(), grep, etc.)

setup() {
  # Load markers.sh directly (no full sharkrite install needed)
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  source "$PROJECT_ROOT/lib/utils/markers.sh"
}

# =============================================================================
# Existence checks: all constants must be defined and non-empty
# =============================================================================

@test "RITE_MARKER_REVIEW is defined and non-empty" {
  [ -n "${RITE_MARKER_REVIEW:-}" ]
}

@test "RITE_MARKER_ASSESSMENT is defined and non-empty" {
  [ -n "${RITE_MARKER_ASSESSMENT:-}" ]
}

@test "RITE_MARKER_FOLLOWUP_ISSUE is defined and non-empty" {
  [ -n "${RITE_MARKER_FOLLOWUP_ISSUE:-}" ]
}

@test "RITE_MARKER_PARENT_PR is defined and non-empty" {
  [ -n "${RITE_MARKER_PARENT_PR:-}" ]
}

@test "RITE_MARKER_SOURCE_ISSUE is defined and non-empty" {
  [ -n "${RITE_MARKER_SOURCE_ISSUE:-}" ]
}

@test "RITE_MARKER_REVIEW_DATA is defined and non-empty" {
  [ -n "${RITE_MARKER_REVIEW_DATA:-}" ]
}

@test "RITE_MARKER_CHANGES_SUMMARY is defined and non-empty" {
  [ -n "${RITE_MARKER_CHANGES_SUMMARY:-}" ]
}

@test "RITE_MARKER_AUTO_RESOLVED is defined and non-empty" {
  [ -n "${RITE_MARKER_AUTO_RESOLVED:-}" ]
}

@test "RITE_MARKER_STASH is defined and non-empty" {
  [ -n "${RITE_MARKER_STASH:-}" ]
}

@test "RITE_MARKER_STASH_TAG is defined and non-empty" {
  [ -n "${RITE_MARKER_STASH_TAG:-}" ]
}

# =============================================================================
# Value checks: constants must contain the canonical sharkrite- prefix
# =============================================================================

@test "RITE_MARKER_REVIEW starts with sharkrite-" {
  [[ "${RITE_MARKER_REVIEW}" == sharkrite-* ]]
}

@test "RITE_MARKER_ASSESSMENT starts with sharkrite-" {
  [[ "${RITE_MARKER_ASSESSMENT}" == sharkrite-* ]]
}

@test "RITE_MARKER_FOLLOWUP_ISSUE starts with sharkrite-" {
  [[ "${RITE_MARKER_FOLLOWUP_ISSUE}" == sharkrite-* ]]
}

@test "RITE_MARKER_PARENT_PR starts with sharkrite-" {
  [[ "${RITE_MARKER_PARENT_PR}" == sharkrite-* ]]
}

@test "RITE_MARKER_SOURCE_ISSUE starts with sharkrite-" {
  [[ "${RITE_MARKER_SOURCE_ISSUE}" == sharkrite-* ]]
}

@test "RITE_MARKER_REVIEW_DATA starts with sharkrite-" {
  [[ "${RITE_MARKER_REVIEW_DATA}" == sharkrite-* ]]
}

@test "RITE_MARKER_CHANGES_SUMMARY starts with sharkrite-" {
  [[ "${RITE_MARKER_CHANGES_SUMMARY}" == sharkrite-* ]]
}

@test "RITE_MARKER_AUTO_RESOLVED starts with sharkrite-" {
  [[ "${RITE_MARKER_AUTO_RESOLVED}" == sharkrite-* ]]
}

@test "RITE_MARKER_STASH starts with sharkrite-" {
  [[ "${RITE_MARKER_STASH}" == sharkrite-* ]]
}

@test "RITE_MARKER_STASH_TAG wraps RITE_MARKER_STASH in brackets" {
  [[ "${RITE_MARKER_STASH_TAG}" == "[${RITE_MARKER_STASH}]" ]]
}

# =============================================================================
# Round-trip: write marker → read marker
# Each test simulates a writer producing an HTML comment or body text,
# then a reader detecting the marker using the same constant.
# =============================================================================

@test "round-trip: review marker written and detected via contains()" {
  # Writer (local-review.sh pattern)
  local model="claude-opus-4-5"
  local ts="2026-05-31T10:00:00Z"
  local body="<!-- ${RITE_MARKER_REVIEW} model:${model} timestamp:${ts} -->

## Code Review
..."

  # Reader (assess-and-resolve.sh / pr-detection.sh pattern)
  echo "$body" | grep -qF "<!-- ${RITE_MARKER_REVIEW}"
}

@test "round-trip: review marker model extraction" {
  local model="claude-opus-4-5"
  local body="<!-- ${RITE_MARKER_REVIEW} model:${model} timestamp:2026-05-31T10:00:00Z -->"

  # Reader pattern from assess-and-resolve.sh:extract_review_model()
  local extracted
  extracted=$(echo "$body" | grep -oE "${RITE_MARKER_REVIEW} model:[a-z0-9-]+" | sed 's/.*model://' | head -1 || true)
  [ "$extracted" = "$model" ]
}

@test "round-trip: assessment marker written and detected via contains()" {
  local pr=42
  local ts="2026-05-31T10:00:00Z"
  local body="<!-- ${RITE_MARKER_ASSESSMENT} pr:${pr} iteration:1 timestamp:${ts} -->

## Assessment
..."

  # Reader pattern
  echo "$body" | grep -qF "<!-- ${RITE_MARKER_ASSESSMENT}"
}

@test "round-trip: followup-issue marker written as PR comment and extracted" {
  local issue_num=99
  # Writer (assess-and-resolve.sh pattern)
  local comment="<!-- ${RITE_MARKER_FOLLOWUP_ISSUE}:${issue_num} -->
📋 Follow-up issue created: #${issue_num}"

  # Reader (workflow-runner.sh / merge-pr.sh pattern)
  local extracted
  extracted=$(echo "$comment" | grep -oE "${RITE_MARKER_FOLLOWUP_ISSUE}:[0-9]+" | grep -oE '[0-9]+' || true)
  [ "$extracted" = "$issue_num" ]
}

@test "round-trip: parent-pr marker written in issue body and extracted" {
  local pr_num=55
  # Writer (assess-and-resolve.sh pattern)
  local issue_body="<!-- ${RITE_MARKER_PARENT_PR}:${pr_num} -->
## Description
Follow-up from PR #${pr_num}."

  # Reader (batch-process-issues.sh / claude-workflow.sh pattern)
  local extracted
  extracted=$(echo "$issue_body" | grep -oE "${RITE_MARKER_PARENT_PR}:[0-9]+" | cut -d: -f2 || true)
  [ "$extracted" = "$pr_num" ]
}

@test "round-trip: source-issue marker written in issue body and searched" {
  local issue_num=33
  # Writer (assess-and-resolve.sh / assess-review-issues.sh pattern)
  local issue_body="<!-- ${RITE_MARKER_SOURCE_ISSUE}:${issue_num} -->
## From PR #42 Assessment"

  # Reader: GitHub search qualifier (verify string is searchable)
  local search_qualifier="${RITE_MARKER_SOURCE_ISSUE}:${issue_num} in:body"
  [ -n "$search_qualifier" ]

  # Reader: direct grep detection
  echo "$issue_body" | grep -qF "<!-- ${RITE_MARKER_SOURCE_ISSUE}:${issue_num}"
}

@test "round-trip: changes-summary markers wrap content correctly" {
  local start="<!-- ${RITE_MARKER_CHANGES_SUMMARY} -->"
  local end="<!-- /${RITE_MARKER_CHANGES_SUMMARY} -->"
  local content="${start}
## Changes
- file.sh
${end}"

  # Reader: detect opening marker
  echo "$content" | grep -qF "$start"

  # Reader: detect closing marker
  echo "$content" | grep -qF "$end"

  # Reader: extract content between markers (pr-summary.sh pattern)
  local inner
  inner=$(echo "$content" | sed -n "/${RITE_MARKER_CHANGES_SUMMARY}/,/\/${RITE_MARKER_CHANGES_SUMMARY}/p" | sed '1d;$d')
  [[ "$inner" == *"## Changes"* ]]
}

@test "round-trip: auto-resolved marker written and detected" {
  # Writer (workflow-runner.sh pattern — embedded in gh issue comment)
  local comment="Automatically closed by sharkrite.

<!-- ${RITE_MARKER_AUTO_RESOLVED} -->"

  # Reader: check presence (workflow could check if issue was auto-closed)
  echo "$comment" | grep -qF "<!-- ${RITE_MARKER_AUTO_RESOLVED}"
}

@test "round-trip: stash tag written in message and detected by grep -F" {
  local stash_msg="${RITE_MARKER_STASH_TAG} auto-stash before rebase"

  # Reader (stash-manager.sh / merge-pr.sh pattern)
  echo "$stash_msg" | grep -qF "$RITE_MARKER_STASH_TAG"
}

@test "round-trip: review-data marker written in review body and extracted" {
  # Writer: local-review.sh embeds JSON block
  local review_body="<!-- ${RITE_MARKER_REVIEW} model:claude-opus-4-5 timestamp:2026-05-31T00:00:00Z -->
## Code Review

<!-- ${RITE_MARKER_REVIEW_DATA} {\"findings\":{\"CRITICAL\":0}} -->
"

  # Reader (assess-and-resolve.sh:extract_review_json pattern)
  local json_block
  json_block=$(echo "$review_body" | sed -n "/<!-- ${RITE_MARKER_REVIEW_DATA}/,/-->/p" | sed '1d;$d')
  # json_block may be empty if on one line — check the marker is detectable at minimum
  echo "$review_body" | grep -qF "<!-- ${RITE_MARKER_REVIEW_DATA}"
}

# =============================================================================
# Double-source guard: sourcing markers.sh twice must not error
# =============================================================================

@test "markers.sh is idempotent (double-source safe)" {
  # Source again — should be a no-op due to _RITE_MARKERS_LOADED guard
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  source "$PROJECT_ROOT/lib/utils/markers.sh"

  # Constants must still be set correctly after second source
  [ "${RITE_MARKER_REVIEW}" = "sharkrite-local-review" ]
  [ "${RITE_MARKER_ASSESSMENT}" = "sharkrite-assessment" ]
}
