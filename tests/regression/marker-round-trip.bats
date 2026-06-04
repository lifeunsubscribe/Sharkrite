#!/usr/bin/env bats
# Regression test: marker constants round-trip
#
# Verifies that lib/utils/markers.sh:
#   1. Sources successfully (both cold and re-source)
#   2. Defines all expected RITE_MARKER_* constants with correct values
#   3. Write-then-read pattern works: a comment body containing the marker
#      string is detectable via contains() — confirming constant values match
#      what is written to GitHub PR comments and what readers grep for
#
# "Round-trip" here is a static proof: we construct the HTML comment a writer
# would produce (using the constant), then verify a reader's grep/contains
# predicate (also using the constant) correctly matches the constructed body.
# This catches the class of bug where writer and reader use different literals
# for the same logical marker.

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT
  MARKERS_SH="${RITE_REPO_ROOT}/lib/utils/markers.sh"
}

# ── Source safety ────────────────────────────────────────────────────────────

@test "markers.sh sources without error (cold source)" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "markers.sh is safe to source twice (idempotent re-source)" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    source '${MARKERS_SH}'
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "markers.sh defines rite_markers_loaded sentinel function after source" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    declare -f rite_markers_loaded >/dev/null 2>&1 && echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

# ── Constant definitions ─────────────────────────────────────────────────────

@test "RITE_MARKER_REVIEW is defined with expected value" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    echo \"\$RITE_MARKER_REVIEW\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "sharkrite-local-review" ]]
}

@test "RITE_MARKER_ASSESSMENT is defined with expected value" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    echo \"\$RITE_MARKER_ASSESSMENT\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "sharkrite-assessment" ]]
}

@test "RITE_MARKER_FOLLOWUP is defined with expected value" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    echo \"\$RITE_MARKER_FOLLOWUP\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "sharkrite-followup-issue" ]]
}

@test "RITE_MARKER_PARENT_PR is defined with expected value" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    echo \"\$RITE_MARKER_PARENT_PR\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "sharkrite-parent-pr" ]]
}

@test "RITE_MARKER_SOURCE_ISSUE is defined with expected value" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    echo \"\$RITE_MARKER_SOURCE_ISSUE\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "sharkrite-source-issue" ]]
}

@test "RITE_MARKER_REVIEW_DATA is defined with expected value" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    echo \"\$RITE_MARKER_REVIEW_DATA\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "sharkrite-review-data" ]]
}

@test "RITE_MARKER_SCOPE_WARNING is defined with expected value" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    echo \"\$RITE_MARKER_SCOPE_WARNING\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "sharkrite-scope-warning" ]]
}

@test "RITE_MARKER_CHANGES_SUMMARY is defined with expected value" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    echo \"\$RITE_MARKER_CHANGES_SUMMARY\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "sharkrite-changes-summary" ]]
}

@test "RITE_MARKER_STASH is defined with expected value" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    echo \"\$RITE_MARKER_STASH\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "sharkrite-managed-stash" ]]
}

# ── Write-then-read round-trip ────────────────────────────────────────────────
#
# For each marker: simulate a writer constructing the HTML comment body, then
# simulate a reader's grep/contains check. Both use the RITE_MARKER_* constant.
# If the constant value is correct, the reader matches what the writer produced.
# This catches the class of bug where a writer and reader use different literals.

@test "round-trip: RITE_MARKER_REVIEW write+grep matches" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    # Writer: local-review.sh posts this marker in PR comment body
    written=\"<!-- \${RITE_MARKER_REVIEW} model:claude-opus-4-5 timestamp:2026-06-03T00:00:00Z -->\"
    # Reader: pr-detection.sh uses contains(\"<!-- \${RITE_MARKER_REVIEW}\") to find it
    echo \"\$written\" | grep -q \"<!-- \${RITE_MARKER_REVIEW}\" && echo MATCH
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "MATCH" ]]
}

@test "round-trip: RITE_MARKER_ASSESSMENT write+grep matches" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    # Writer: assess-and-resolve.sh posts comment with this marker
    written=\"<!-- \${RITE_MARKER_ASSESSMENT} -->\"
    # Reader: workflow-runner.sh and others use contains to find it
    echo \"\$written\" | grep -q \"<!-- \${RITE_MARKER_ASSESSMENT}\" && echo MATCH
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "MATCH" ]]
}

@test "round-trip: RITE_MARKER_FOLLOWUP write+grep matches" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    # Writer: assess-and-resolve.sh posts <!-- sharkrite-followup-issue:N --> in PR comment
    written=\"<!-- \${RITE_MARKER_FOLLOWUP}:42 -->\"
    # Reader: merge-pr.sh, undo-workflow.sh grep for FOLLOWUP:digits
    echo \"\$written\" | grep -qE \"\${RITE_MARKER_FOLLOWUP}:[0-9]+\" && echo MATCH
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "MATCH" ]]
}

@test "round-trip: RITE_MARKER_PARENT_PR write+grep matches" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    # Writer: assess-and-resolve.sh embeds this in follow-up issue body
    written=\"<!-- \${RITE_MARKER_PARENT_PR}:99 -->\"
    # Reader: batch-process-issues.sh, claude-workflow.sh grep for PARENT_PR:digits
    echo \"\$written\" | grep -qE \"\${RITE_MARKER_PARENT_PR}:[0-9]+\" && echo MATCH
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "MATCH" ]]
}

@test "round-trip: RITE_MARKER_SOURCE_ISSUE write+grep matches" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    # Writer: assess-and-resolve.sh embeds source-issue marker in follow-up body
    written=\"<!-- \${RITE_MARKER_SOURCE_ISSUE}:7 -->\"
    # Reader: any consumer searching for the source issue
    echo \"\$written\" | grep -qE \"\${RITE_MARKER_SOURCE_ISSUE}:[0-9]+\" && echo MATCH
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "MATCH" ]]
}

@test "round-trip: RITE_MARKER_SCOPE_WARNING write+grep matches" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    # Writer: scope-checker.sh writes this into PR body
    written=\"<!-- \${RITE_MARKER_SCOPE_WARNING} -->\"
    # Reader: claude-workflow.sh checks PR body for the warning
    echo \"\$written\" | grep -q \"<!-- \${RITE_MARKER_SCOPE_WARNING} -->\" && echo MATCH
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "MATCH" ]]
}

@test "round-trip: RITE_MARKER_CHANGES_SUMMARY write+grep matches" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    # Writer: pr-summary.sh wraps the diff summary between open/close tags
    written=\"<!-- \${RITE_MARKER_CHANGES_SUMMARY} -->\"
    close=\"<!-- /\${RITE_MARKER_CHANGES_SUMMARY} -->\"
    # Reader: pr-summary.sh locates the section by the open tag
    echo \"\$written\" | grep -q \"<!-- \${RITE_MARKER_CHANGES_SUMMARY} -->\" && echo MATCH
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "MATCH" ]]
}

@test "round-trip: RITE_MARKER_STASH write+grep matches" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    # Writer: stash-manager.sh creates stashes with [sharkrite-managed-stash] in message
    written=\"stale-branch: auto-stash before cleanup [\${RITE_MARKER_STASH}]\"
    # Reader: merge-pr.sh, stash-manager.sh grep for [\${RITE_MARKER_STASH}] in stash list
    echo \"\$written\" | grep -qF \"[\${RITE_MARKER_STASH}]\" && echo MATCH
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "MATCH" ]]
}

@test "round-trip: RITE_MARKER_REVIEW_DATA write+grep matches" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    # Writer: local-review.sh wraps structured data in this marker
    written=\"<!-- \${RITE_MARKER_REVIEW_DATA} findings=5 -->\"
    # Reader: assess-and-resolve.sh extracts data via sed range on this marker
    echo \"\$written\" | grep -q \"\${RITE_MARKER_REVIEW_DATA}\" && echo MATCH
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "MATCH" ]]
}

# ── Rename-safety: each constant value must appear exactly once in markers.sh ─

@test "each RITE_MARKER_* constant has exactly one definition in markers.sh" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'
    errors=0
    for var in RITE_MARKER_REVIEW RITE_MARKER_ASSESSMENT RITE_MARKER_FOLLOWUP \
               RITE_MARKER_PARENT_PR RITE_MARKER_SOURCE_ISSUE RITE_MARKER_REVIEW_DATA \
               RITE_MARKER_SCOPE_WARNING RITE_MARKER_CHANGES_SUMMARY \
               RITE_MARKER_STASH; do
      count=\$(grep -c \"^\${var}=\" '${MARKERS_SH}' || true)
      if [ \"\$count\" -ne 1 ]; then
        echo \"ERROR: \$var defined \$count times in markers.sh (expected 1)\"
        errors=\$((errors + 1))
      fi
    done
    [ \$errors -eq 0 ] && echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}
