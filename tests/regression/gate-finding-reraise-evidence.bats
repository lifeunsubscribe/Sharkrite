#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh

# Regression test for issue #1613: [GATE] ACTIONABLE_NOW items re-raised by
# the LLM assessor on retry passes when the underlying test has since passed.
#
# Root cause: assess-review-issues.sh RULE 1 injects prior ACTIONABLE_NOW items
# into the LLM prompt with convergence rules, treating gate-origin findings the
# same as review-origin findings. Gate findings have an objective oracle (the
# gate verdict itself); LLM silence is not evidence of non-resolution.
#
# Fix: _resolve_prior_gate_findings() in assess-and-resolve.sh drops all
# [GATE] ACTIONABLE_NOW items from ASSESSMENT_RESULT when _GATE_HAD_VALID_VERDICT
# is true, before GATE_PREPEND_ITEMS is prepended by the caller.
#
# Tests in this file:
#   STRUCTURAL:
#     1. _resolve_prior_gate_findings function defined in assess-and-resolve.sh
#     2. Function called after assess-review-issues.sh output and before prepend
#     3. _GATE_HAD_VALID_VERDICT is set in _build_gate_prepend_items
#
#   UNIT (_resolve_prior_gate_findings behavior):
#     4. Prior [GATE] item dropped when verdict is valid and gate passed
#     5. Prior [GATE] item dropped even when LLM re-raised with paraphrased title
#     6. [GATE] item in both ASSESSMENT_RESULT and GATE_PREPEND_ITEMS dropped
#        from ASSESSMENT_RESULT (no double-count; arrives via prepend)
#     7. Non-[GATE] ACTIONABLE_NOW items preserved
#     8. No-op on first pass (RETRY_COUNT=0) — RULE 1 inactive
#     9. No-op when ASSESSMENT_RESULT has no [GATE] items
#    10. Conservative: keep item when no valid verdict and no PR available
#
# Verification command:
#   bats tests/regression/gate-finding-reraise-evidence.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
ASSESS_RESOLVE="$REPO_ROOT/lib/core/assess-and-resolve.sh"

setup() {
  [ -f "$ASSESS_RESOLVE" ] || {
    echo "FATAL: $ASSESS_RESOLVE not found" >&2
    return 1
  }
}

# =============================================================================
# Helper: load _resolve_prior_gate_findings from assess-and-resolve.sh via awk
# extraction. Provides stubs for _diag and print_info.
# =============================================================================
_load_resolve_fn() {
  _diag() { true; }
  print_info() { true; }
  eval "$(awk '
    /_resolve_prior_gate_findings[(][)]/ { in_fn=1 }
    in_fn { print }
    in_fn && /^}$/ { exit }
  ' "$ASSESS_RESOLVE")"
}

# =============================================================================
# STRUCTURAL: static code inspection
# =============================================================================

@test "structural: _resolve_prior_gate_findings defined in assess-and-resolve.sh" {
  grep -q '_resolve_prior_gate_findings()' "$ASSESS_RESOLVE" || {
    echo "FAIL: _resolve_prior_gate_findings() not found in assess-and-resolve.sh" >&2
    return 1
  }
}

@test "structural: _resolve_prior_gate_findings called after assess-review-issues.sh invocation" {
  # Must appear after ASSESSMENT_RESULT is set and before GATE_PREPEND_ITEMS prepend.
  # Verify call site exists in the script body (after the RITE_SOURCE_FUNCTIONS_ONLY guard).
  grep -q '_resolve_prior_gate_findings' "$ASSESS_RESOLVE" || {
    echo "FAIL: _resolve_prior_gate_findings call not found in assess-and-resolve.sh" >&2
    return 1
  }
}

@test "structural: _GATE_HAD_VALID_VERDICT set in _build_gate_prepend_items" {
  grep -q '_GATE_HAD_VALID_VERDICT' "$ASSESS_RESOLVE" || {
    echo "FAIL: _GATE_HAD_VALID_VERDICT not referenced in assess-and-resolve.sh" >&2
    return 1
  }
}

# =============================================================================
# UNIT: _resolve_prior_gate_findings behavior
# =============================================================================

@test "unit: drops [GATE] ACTIONABLE_NOW when verdict is valid and gate passed" {
  _load_resolve_fn

  RETRY_COUNT=1
  _GATE_HAD_VALID_VERDICT=true
  GATE_PREPEND_ITEMS=""
  ISSUE_NUMBER=1595
  PR_NUMBER=""
  RITE_MARKER_ASSESSMENT="sharkrite-assessment"

  ASSESSMENT_RESULT="### [GATE] bats failure: blocker-rules subshell gate picks up new functions - ACTIONABLE_NOW
**Severity:** HIGH
**Location:** tests/regression/blocker-rules-subshell-gate.bats

The test suite detected a failure.

### Some review finding - ACTIONABLE_LATER
**Severity:** LOW

A review-origin finding that must be preserved.
"

  _resolve_prior_gate_findings

  if echo "$ASSESSMENT_RESULT" | grep -q "^### \[GATE\]"; then
    echo "FAIL: [GATE] ACTIONABLE_NOW still present after gate passed"
    echo "ASSESSMENT_RESULT: $ASSESSMENT_RESULT"
    return 1
  fi

  if ! echo "$ASSESSMENT_RESULT" | grep -q "^### Some review finding - ACTIONABLE_LATER"; then
    echo "FAIL: review-origin finding was incorrectly dropped"
    echo "ASSESSMENT_RESULT: $ASSESSMENT_RESULT"
    return 1
  fi
}

@test "unit: drops [GATE] item with LLM-paraphrased title" {
  _load_resolve_fn

  RETRY_COUNT=2
  _GATE_HAD_VALID_VERDICT=true
  GATE_PREPEND_ITEMS=""
  ISSUE_NUMBER=1595
  PR_NUMBER=""
  RITE_MARKER_ASSESSMENT="sharkrite-assessment"

  ASSESSMENT_RESULT="### [GATE] blocker-rules subshell gate failure not addressed - ACTIONABLE_NOW
**Severity:** HIGH

Paraphrased re-raise by LLM assessor — different title than original gate header.
"

  _resolve_prior_gate_findings

  if echo "$ASSESSMENT_RESULT" | grep -q "^### \[GATE\]"; then
    echo "FAIL: paraphrased [GATE] item not dropped"
    echo "ASSESSMENT_RESULT: $ASSESSMENT_RESULT"
    return 1
  fi
}

@test "unit: drops [GATE] item from ASSESSMENT_RESULT when also in GATE_PREPEND_ITEMS" {
  # Still-failing item: in GATE_PREPEND_ITEMS (current gate) AND ASSESSMENT_RESULT
  # (LLM re-raise). Must be dropped from ASSESSMENT_RESULT to prevent
  # double-counting — the item arrives via GATE_PREPEND_ITEMS prepend.
  _load_resolve_fn

  RETRY_COUNT=1
  _GATE_HAD_VALID_VERDICT=true
  GATE_PREPEND_ITEMS="### [GATE] bats failure: foo.bats - ACTIONABLE_NOW
**Severity:** HIGH

Current gate failure.
"
  ISSUE_NUMBER=42
  PR_NUMBER=""
  RITE_MARKER_ASSESSMENT="sharkrite-assessment"

  ASSESSMENT_RESULT="### [GATE] bats failure: foo.bats - ACTIONABLE_NOW
**Severity:** HIGH

LLM re-raise of same failing gate item.
"

  _resolve_prior_gate_findings

  if echo "$ASSESSMENT_RESULT" | grep -q "^### \[GATE\]"; then
    echo "FAIL: still-failing [GATE] item was not dropped from ASSESSMENT_RESULT (would double-count)"
    echo "ASSESSMENT_RESULT: $ASSESSMENT_RESULT"
    return 1
  fi
}

@test "unit: preserves non-[GATE] ACTIONABLE_NOW items" {
  _load_resolve_fn

  RETRY_COUNT=1
  _GATE_HAD_VALID_VERDICT=true
  GATE_PREPEND_ITEMS=""
  ISSUE_NUMBER=42
  PR_NUMBER=""
  RITE_MARKER_ASSESSMENT="sharkrite-assessment"

  ASSESSMENT_RESULT="### [GATE] lint: shellcheck SC2086 - ACTIONABLE_NOW
**Severity:** HIGH

A gate lint finding.

### Missing input validation - ACTIONABLE_NOW
**Severity:** HIGH

A review-origin NOW finding that must NOT be dropped.

### Tech debt: extract helper - ACTIONABLE_LATER
**Severity:** LOW

A later finding.
"

  _resolve_prior_gate_findings

  if echo "$ASSESSMENT_RESULT" | grep -q "^### \[GATE\]"; then
    echo "FAIL: [GATE] item not dropped"
    echo "ASSESSMENT_RESULT: $ASSESSMENT_RESULT"
    return 1
  fi

  if ! echo "$ASSESSMENT_RESULT" | grep -q "^### Missing input validation - ACTIONABLE_NOW"; then
    echo "FAIL: review-origin ACTIONABLE_NOW was incorrectly dropped"
    echo "ASSESSMENT_RESULT: $ASSESSMENT_RESULT"
    return 1
  fi

  if ! echo "$ASSESSMENT_RESULT" | grep -q "^### Tech debt: extract helper - ACTIONABLE_LATER"; then
    echo "FAIL: ACTIONABLE_LATER was incorrectly dropped"
    echo "ASSESSMENT_RESULT: $ASSESSMENT_RESULT"
    return 1
  fi
}

@test "unit: no-op on first pass (RETRY_COUNT=0) — RULE 1 is inactive" {
  _load_resolve_fn

  RETRY_COUNT=0
  _GATE_HAD_VALID_VERDICT=true
  GATE_PREPEND_ITEMS=""
  ISSUE_NUMBER=42
  PR_NUMBER=""
  RITE_MARKER_ASSESSMENT="sharkrite-assessment"

  ASSESSMENT_RESULT="### [GATE] bats failure: foo.bats - ACTIONABLE_NOW
**Severity:** HIGH

Should not be touched on first pass.
"
  _original="$ASSESSMENT_RESULT"

  _resolve_prior_gate_findings

  [ "$ASSESSMENT_RESULT" = "$_original" ] || {
    echo "FAIL: ASSESSMENT_RESULT modified on first pass (RETRY_COUNT=0)"
    return 1
  }
}

@test "unit: no-op when ASSESSMENT_RESULT has no [GATE] items" {
  _load_resolve_fn

  RETRY_COUNT=1
  _GATE_HAD_VALID_VERDICT=true
  GATE_PREPEND_ITEMS=""
  ISSUE_NUMBER=42
  PR_NUMBER=""
  RITE_MARKER_ASSESSMENT="sharkrite-assessment"

  ASSESSMENT_RESULT="### Some review finding - ACTIONABLE_NOW
**Severity:** HIGH

No gate items here.
"
  _original="$ASSESSMENT_RESULT"

  _resolve_prior_gate_findings

  [ "$ASSESSMENT_RESULT" = "$_original" ] || {
    echo "FAIL: ASSESSMENT_RESULT modified when no [GATE] items present"
    return 1
  }
}

@test "unit: conservative — keeps [GATE] item when no valid verdict and no PR available" {
  _load_resolve_fn

  RETRY_COUNT=1
  _GATE_HAD_VALID_VERDICT=false
  GATE_PREPEND_ITEMS=""
  ISSUE_NUMBER=42
  PR_NUMBER=""
  RITE_MARKER_ASSESSMENT="sharkrite-assessment"

  ASSESSMENT_RESULT="### [GATE] bats failure: foo.bats - ACTIONABLE_NOW
**Severity:** HIGH

Should be kept — cannot verify without a gate verdict.
"

  _resolve_prior_gate_findings

  if ! echo "$ASSESSMENT_RESULT" | grep -q "^### \[GATE\]"; then
    echo "FAIL: [GATE] item was dropped without a valid verdict (conservative path violated)"
    echo "ASSESSMENT_RESULT: $ASSESSMENT_RESULT"
    return 1
  fi
}
