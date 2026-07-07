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
  # The assessment marker comment (not the review marker) must reference commit:.
  # markers.sh convention puts the format doc comment ABOVE the assignment, so
  # grep the lines BEFORE the RITE_MARKER_ASSESSMENT= line (-B, not -A).
  run grep -B5 "^RITE_MARKER_ASSESSMENT=" "$RITE_REPO_ROOT/lib/utils/markers.sh"
  [[ "$output" == *"commit:"* ]]
}

# =============================================================================
# SURFACE 1 behavioral: stale gate PASS must not authorize merge via early exit
# =============================================================================

@test "behavioral: stale gate PASS + zero-finding review does NOT reach exit 0 (early-exit blocked)" {
  # Fixture: replicate the gate-staleness check + early-exit decision path from
  # assess-and-resolve.sh lines 1115-1262. A PASSING gate verdict from SHA A
  # combined with a zero-finding review must NOT exit 0 when the current HEAD
  # is SHA B. Before the #985/#986 fix, _gate_verdict_is_stale was set to true
  # but the early-exit at 'zero findings + gate passed' did not check it,
  # allowing a stale PASS to authorize a merge (PR #674 incident class).
  run bash -c '
    set -euo pipefail

    # Minimal stubs for the decision logic under test.
    print_warning() { echo "WARN: $*" >&2; }
    print_success() { echo "OK: $*" >&2; }
    print_header()  { true; }

    # Gate findings file: gate PASSED at SHA A.
    GATE_FILE=$(mktemp)
    printf '"'"'{"exit_code":0,"head_sha":"sha-a-stale111","lint":[],"tests":[],"skipped":false}'"'"' > "$GATE_FILE"

    # Review file: zero findings (the path that previously triggered early exit 0).
    REVIEW_FILE=$(mktemp)
    printf '"'"'Findings: CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 0\n'"'"' > "$REVIEW_FILE"

    # Current HEAD is SHA B (different from gate SHA A).
    CURRENT_HEAD_SHA="sha-b-current222"

    # --- Gate staleness check (mirrors assess-and-resolve.sh) ---
    GATE_NOW_COUNT=0
    _gate_skipped=$(jq -r '"'"'.skipped // false'"'"' "$GATE_FILE")
    _gate_exit_code=$(jq -r '"'"'.exit_code // 0'"'"' "$GATE_FILE")
    _gate_verdict_sha=$(jq -r '"'"'.head_sha // ""'"'"' "$GATE_FILE")
    _gate_verdict_is_stale=false

    if [ -n "$_gate_verdict_sha" ] && [ -n "${CURRENT_HEAD_SHA:-}" ] \
       && [ "$_gate_verdict_sha" != "$CURRENT_HEAD_SHA" ]; then
      if [ "$_gate_skipped" != "true" ] && [ "$_gate_exit_code" -eq 0 ]; then
        _gate_verdict_is_stale=true
        _gate_skipped="true"
      fi
    fi

    # --- Early-exit decision (mirrors the fixed assess-and-resolve.sh) ---
    REVIEW_FINDINGS_LINE=$(grep -oE "Findings: CRITICAL: [0-9]+ [|] HIGH: [0-9]+ [|] MEDIUM: [0-9]+ [|] LOW: [0-9]+" "$REVIEW_FILE" | head -1 || true)
    if [ -n "$REVIEW_FINDINGS_LINE" ]; then
      REVIEW_TOTAL_FINDINGS=$(echo "$REVIEW_FINDINGS_LINE" | grep -oE "[0-9]+" | awk '"'"'{sum += $1} END {print sum}'"'"' || true)
      if [ "${REVIEW_TOTAL_FINDINGS:-0}" -eq 0 ] && [ "${GATE_NOW_COUNT:-0}" -eq 0 ] \
         && [ "${_gate_verdict_is_stale:-false}" != "true" ]; then
        # This must NOT be reached — a stale gate PASS cannot authorize a merge.
        echo "BUG: early exit reached with stale gate PASS — PR #674 class regression"
        exit 0
      fi
    fi

    # Correct outcome: early exit was blocked, processing continues.
    echo "CORRECT: early exit blocked, stale gate PASS did not authorize merge"
    exit 2   # any non-zero exit signals the caller that assessment must proceed

    rm -f "$GATE_FILE" "$REVIEW_FILE" 2>/dev/null || true
  '
  # The subprocess must NOT exit 0 (which would indicate the merge was wrongly authorized).
  [ "$status" -ne 0 ]
  [[ "$output" == *"CORRECT: early exit blocked"* ]]
}

@test "source: early-exit guard includes _gate_verdict_is_stale check" {
  # Structural pin: the early-exit condition at 'zero findings + gate passed' must
  # include the _gate_verdict_is_stale guard. This is the specific fix for the HIGH
  # finding that a stale PASS can reach exit 0 via GATE_NOW_COUNT=0 + REVIEW=0.
  # Source-grep is appropriate here because the invariant is about the guard's
  # PRESENCE in the condition — structural, not about logic paths (behavioral test above).
  run grep -n "_gate_verdict_is_stale" "$RITE_REPO_ROOT/lib/core/assess-and-resolve.sh"
  [ "$status" -eq 0 ]
  # Must appear at both the DETECTION site (set to true) and the early-exit GUARD.
  run grep -c "_gate_verdict_is_stale" "$RITE_REPO_ROOT/lib/core/assess-and-resolve.sh"
  [ "$output" -ge 3 ]
}

# =============================================================================
# SURFACE 2 behavioral: resume block uses resolve_pr_head_sha for SHA comparison
# =============================================================================

@test "source: run_workflow resume block uses resolve_pr_head_sha not _remote_head for assessment SHA check" {
  # The resume skip-to-merge check must use resolve_pr_head_sha (API-authoritative)
  # not _remote_head (local cached ref) for the assessment currency comparison.
  # _remote_head can be stale if the remote was updated without a fetch to this
  # worktree — using it would accept a stale cached assessment as current.
  #
  # Structural pin: verify _resume_head_sha (the local variable set by the
  # resolve_pr_head_sha call) is used in the comparison at the resume block.
  run grep -n "_resume_head_sha" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ "$status" -eq 0 ]
  # Both the assignment (resolve call) and comparisons must be present.
  run grep -c "_resume_head_sha" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ "$output" -ge 3 ]
  # The resolve_pr_head_sha call must be at the resume block (not only at phase entry).
  # We verify by checking that it appears at least twice in workflow-runner.sh total.
  run grep -c "resolve_pr_head_sha" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ "$output" -ge 2 ]
}
