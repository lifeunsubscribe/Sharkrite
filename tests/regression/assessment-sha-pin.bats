#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, lib/core/assess-and-resolve.sh, lib/core/workflow-runner.sh, lib/utils/review-helper.sh
# Regression for #985/#986: gate verdict and assessment cache must be pinned to
# the HEAD SHA that produced them. A passing verdict from SHA A must not authorize
# a merge or phase-skip when the PR is now at SHA B.
#
# Two surfaces:
#   1. Gate verdict SHA-pin: _gate_write_json embeds head_sha; assess-and-resolve.sh
#      discards a stale PASS (exit_code=0 + head_sha != CURRENT_HEAD_SHA).
#   2. Assessment cache SHA-pin: extract_assessment_sha extracts the commit: attribute;
#      workflow-runner.sh refuses to skip assessment when assessment SHA != HEAD.
#
# Live incidents: PR #674 (gate PASS at 10:49 → merged at 10:53 over 10:52 RED);
#   PR #710 (assessment "0 ACTIONABLE_NOW" from pre-clobber commit → phase skipped).

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export RITE_REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  RITE_MARKER_ASSESSMENT="sharkrite-assessment"
  export RITE_MARKER_ASSESSMENT
}

# =============================================================================
# SURFACE 1: Gate verdict SHA-pinning
# =============================================================================

@test "behavioral: _gate_write_json embeds head_sha in non-skipped verdict JSON" {
  # Fixture: call _gate_write_json with a SHA and verify it appears in the output.
  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_LIB_DIR"'"
    RITE_MARKER_ASSESSMENT="sharkrite-assessment"; export RITE_MARKER_ASSESSMENT
    _diag() { true; }
    source "$RITE_LIB_DIR/utils/test-gate.sh"
    f=$(mktemp)
    _gate_write_json "$f" "[]" "[]" "0" "false" "" "abc1234def5678"
    cat "$f"
    rm -f "$f"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"head_sha":"abc1234def5678"'* ]]
}

@test "behavioral: _gate_write_json does NOT embed head_sha in skipped sentinel JSON" {
  # Skipped sentinels must not carry a SHA (they do not represent a PASS verdict).
  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_LIB_DIR"'"
    RITE_MARKER_ASSESSMENT="sharkrite-assessment"; export RITE_MARKER_ASSESSMENT
    _diag() { true; }
    source "$RITE_LIB_DIR/utils/test-gate.sh"
    f=$(mktemp)
    _gate_write_json "$f" "[]" "[]" "0" "true" "missing_runner" "abc1234def5678"
    cat "$f"
    rm -f "$f"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"skipped":true'* ]]
  [[ "$output" != *'"head_sha"'* ]]
}

@test "behavioral: _gate_write_json embeds head_sha when reason is also present (FAILED path)" {
  # A failing gate with both a reason and a SHA must include both fields.
  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_LIB_DIR"'"
    RITE_MARKER_ASSESSMENT="sharkrite-assessment"; export RITE_MARKER_ASSESSMENT
    _diag() { true; }
    source "$RITE_LIB_DIR/utils/test-gate.sh"
    f=$(mktemp)
    _gate_write_json "$f" "[]" "[]" "1" "false" "runner_unavailable" "aaa111bbb222"
    cat "$f"
    rm -f "$f"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"head_sha":"aaa111bbb222"'* ]]
  [[ "$output" == *'"reason":"runner_unavailable"'* ]]
}

@test "source: gate final write passes head_sha to _gate_write_json" {
  # Assert the capture-and-pass pattern is present in run_test_gate's exit block.
  run grep -n "_gate_head_sha" "$RITE_REPO_ROOT/lib/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  # Both the capture and the pass must be present.
  run grep -c "_gate_head_sha" "$RITE_REPO_ROOT/lib/utils/test-gate.sh"
  [ "$output" -ge 2 ]
}

@test "source: assess-and-resolve.sh reads head_sha from gate JSON and detects mismatch" {
  # Assert the SHA-check block exists in the gate-findings consumption section.
  run grep -n "_gate_verdict_sha" "$RITE_REPO_ROOT/lib/core/assess-and-resolve.sh"
  [ "$status" -eq 0 ]
  run grep -n "_gate_verdict_is_stale" "$RITE_REPO_ROOT/lib/core/assess-and-resolve.sh"
  [ "$status" -eq 0 ]
}

@test "source: stale PASS verdict forces _gate_skipped=true before failure-processing block" {
  # The staleness-handling code must set _gate_skipped=true for a PASS verdict mismatch.
  # This prevents the failure-processing loop from firing and GATE_NOW_COUNT from rising.
  run grep -n '_gate_skipped="true"' "$RITE_REPO_ROOT/lib/core/assess-and-resolve.sh"
  [ "$status" -eq 0 ]
  # The gate-verdict staleness assignment must appear BEFORE the failure-processing loop.
  stale_line=$(grep -n '_gate_verdict_is_stale=true' "$RITE_REPO_ROOT/lib/core/assess-and-resolve.sh" | head -1 | cut -d: -f1)
  fail_loop=$(grep -n "Build \[GATE\] ACTIONABLE_NOW items from lint failures" "$RITE_REPO_ROOT/lib/core/assess-and-resolve.sh" | head -1 | cut -d: -f1)
  [ "$stale_line" -lt "$fail_loop" ]
}

# =============================================================================
# SURFACE 2: Assessment cache SHA-pinning
# =============================================================================

@test "behavioral: extract_assessment_sha returns SHA from well-formed marker" {
  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_LIB_DIR"'"
    RITE_MARKER_ASSESSMENT="sharkrite-assessment"
    export RITE_MARKER_ASSESSMENT
    # Avoid network: source only function definitions
    RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_LIB_DIR/utils/review-helper.sh"
    set +u; set +o pipefail
    BODY="<!-- sharkrite-assessment pr:42 iteration:1 timestamp:2026-07-01T10:00:00Z commit:abc123def456 -->
## Assessment

### Some finding - ACTIONABLE_NOW"
    extract_assessment_sha "$BODY"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "abc123def456" ]
}

@test "behavioral: extract_assessment_sha returns empty for pre-#986 marker (no commit: attr)" {
  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_LIB_DIR"'"
    RITE_MARKER_ASSESSMENT="sharkrite-assessment"
    export RITE_MARKER_ASSESSMENT
    RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_LIB_DIR/utils/review-helper.sh"
    set +u; set +o pipefail
    BODY="<!-- sharkrite-assessment pr:42 iteration:1 timestamp:2026-07-01T10:00:00Z -->
## Assessment"
    extract_assessment_sha "$BODY"
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "behavioral: extract_assessment_sha does not capture commit: from assessment body text" {
  # A commit: reference in the assessment body text (not the marker line) must not
  # be returned — the function anchors to the marker prefix.
  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_LIB_DIR"'"
    RITE_MARKER_ASSESSMENT="sharkrite-assessment"
    export RITE_MARKER_ASSESSMENT
    RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_LIB_DIR/utils/review-helper.sh"
    set +u; set +o pipefail
    # Marker has no commit: attr; body text contains "commit:badbadbadbad"
    BODY="<!-- sharkrite-assessment pr:99 iteration:1 timestamp:2026-07-01T10:00:00Z -->
**Reasoning:** The change references commit:badbadbadbad in the PR description."
    extract_assessment_sha "$BODY"
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "source: assess-review-issues.sh embeds _ASSESSMENT_SHA_ATTR in assessment marker" {
  # The marker format must include the SHA attribute variable.
  run grep -n "_ASSESSMENT_SHA_ATTR" "$RITE_REPO_ROOT/lib/core/assess-review-issues.sh"
  [ "$status" -eq 0 ]
  # Both the variable assignment and its inclusion in the marker must be present.
  run grep -c "_ASSESSMENT_SHA_ATTR" "$RITE_REPO_ROOT/lib/core/assess-review-issues.sh"
  [ "$output" -ge 2 ]
}

@test "source: _post_gate_fallback_assessment_comment accepts head_sha as 5th arg" {
  # The function signature must declare _head_sha and use it in the marker.
  run grep -n "_head_sha" "$RITE_REPO_ROOT/lib/core/assess-and-resolve.sh"
  [ "$status" -eq 0 ]
  run grep -c "_head_sha" "$RITE_REPO_ROOT/lib/core/assess-and-resolve.sh"
  [ "$output" -ge 3 ]
}

@test "source: workflow-runner.sh uses extract_assessment_sha at phase_assess_and_resolve entry" {
  run grep -n "extract_assessment_sha" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ "$status" -eq 0 ]
  # Must appear in both the phase-skip check and the resume skip-to-merge check.
  run grep -c "extract_assessment_sha" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ "$output" -ge 2 ]
}

@test "source: workflow-runner.sh SHA mismatch causes re-assess not skip-to-merge" {
  # Assert the staleness-warning message exists (confirms the mismatch branch was added).
  run grep -n "Cached assessment is stale" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ "$status" -eq 0 ]
  # Must appear at both the phase-skip-check location AND the resume-skip-to-merge location.
  run grep -c "Cached assessment is stale" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ "$output" -ge 2 ]
}

@test "source: pre-#986 assessment (no SHA) triggers re-assess warning in workflow-runner.sh" {
  run grep -n "predates SHA embedding" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ "$status" -eq 0 ]
  run grep -c "predates SHA embedding" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ "$output" -ge 2 ]
}

@test "source: review-helper.sh exports extract_assessment_sha" {
  run grep -n "export -f extract_assessment_sha" "$RITE_REPO_ROOT/lib/utils/review-helper.sh"
  [ "$status" -eq 0 ]
}

@test "source: markers.sh documents the commit: attribute in the assessment marker format" {
  run grep -n "commit:" "$RITE_REPO_ROOT/lib/utils/markers.sh"
  [ "$status" -eq 0 ]
  # The assessment marker comment (not the review marker) must reference commit:
  run grep -A5 "RITE_MARKER_ASSESSMENT" "$RITE_REPO_ROOT/lib/utils/markers.sh"
  [[ "$output" == *"commit:"* ]]
}
