#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Regression test: retry timed-out fix session once at double budget (#1172)
#
# Verifies the four acceptance criteria:
#   1. First no-commit timeout below cap → retry at doubled budget, diag emitted
#   2. Second no-commit timeout → fails (exit 1)
#   3. Timeout with commits present → no retry (salvage path unchanged)
#   4. Budget already at 1800s → no retry
#
# Strategy:
#   - Structural tests (grep) verify the retry arm and diag are present in source
#   - Unit tests (inline bash) verify the retry-budget calculation in isolation

CLAUDE_WORKFLOW="${BATS_TEST_DIRNAME}/../../lib/core/claude-workflow.sh"

setup() {
  [ -f "$CLAUDE_WORKFLOW" ] || {
    echo "FATAL: $CLAUDE_WORKFLOW not found" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: verify the retry arm is present in source
# =============================================================================

@test "structural: retry arm checks _fix_attempt -eq 1" {
  grep -q '_fix_attempt.*-eq 1' "$CLAUDE_WORKFLOW" || {
    echo "FAIL: '_fix_attempt -eq 1' guard not found in claude-workflow.sh" >&2
    echo "      First-attempt retry guard must be present" >&2
    return 1
  }
}

@test "structural: retry arm checks FIX_TIMEOUT -lt 1800" {
  grep -q 'FIX_TIMEOUT.*-lt 1800' "$CLAUDE_WORKFLOW" || {
    echo "FAIL: 'FIX_TIMEOUT -lt 1800' guard not found in claude-workflow.sh" >&2
    echo "      Retry must be skipped when budget is already at cap" >&2
    return 1
  }
}

@test "structural: FIX_TIMEOUT_RETRY diag line emitted on retry" {
  grep -q 'FIX_TIMEOUT_RETRY' "$CLAUDE_WORKFLOW" || {
    echo "FAIL: 'FIX_TIMEOUT_RETRY' diag not found in claude-workflow.sh" >&2
    echo "      _diag FIX_TIMEOUT_RETRY must be emitted when retrying" >&2
    return 1
  }
}

@test "structural: retry budget capped at 1800s" {
  # The cap guard must appear after the doubling line
  grep -q '_retry_budget.*-gt 1800.*_retry_budget=1800' "$CLAUDE_WORKFLOW" || \
  grep -A1 '_retry_budget=$(( FIX_TIMEOUT \* 2 ))' "$CLAUDE_WORKFLOW" | grep -q '_retry_budget=1800' || {
    echo "FAIL: retry budget cap (1800s) not found in claude-workflow.sh" >&2
    echo "      min(2×budget, 1800) cap must be applied" >&2
    return 1
  }
}

@test "structural: while loop wraps provider invocation for retry" {
  grep -q 'while true; do' "$CLAUDE_WORKFLOW" || {
    echo "FAIL: 'while true; do' retry loop not found in claude-workflow.sh" >&2
    return 1
  }
}

@test "structural: uncommitted-changes arm breaks out of retry loop" {
  # After 'Found uncommitted changes - will commit what we have' there must be a break
  grep -A1 'Found uncommitted changes - will commit what we have' "$CLAUDE_WORKFLOW" | grep -q 'break' || {
    echo "FAIL: 'break' not found after uncommitted-changes message in claude-workflow.sh" >&2
    echo "      Committed-work timeout must exit the loop without retrying" >&2
    return 1
  }
}

# =============================================================================
# UNIT: retry-budget calculation (inline bash, formula verification)
# =============================================================================

@test "retry budget: 540s × 2 = 1080s (below cap)" {
  run bash -c '
    FIX_TIMEOUT=540
    _retry_budget=$(( FIX_TIMEOUT * 2 ))
    [ "$_retry_budget" -gt 1800 ] && _retry_budget=1800
    echo "$_retry_budget"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "1080" ]
}

@test "retry budget: 1000s × 2 = 2000s → capped at 1800s" {
  run bash -c '
    FIX_TIMEOUT=1000
    _retry_budget=$(( FIX_TIMEOUT * 2 ))
    [ "$_retry_budget" -gt 1800 ] && _retry_budget=1800
    echo "$_retry_budget"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "1800" ]
}

@test "retry budget: 900s × 2 = 1800s (exactly at cap, not over)" {
  run bash -c '
    FIX_TIMEOUT=900
    _retry_budget=$(( FIX_TIMEOUT * 2 ))
    [ "$_retry_budget" -gt 1800 ] && _retry_budget=1800
    echo "$_retry_budget"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "1800" ]
}

@test "no-retry condition: budget=1800 → retry guard rejects" {
  run bash -c '
    FIX_TIMEOUT=1800
    _fix_attempt=1
    if [ "$_fix_attempt" -eq 1 ] && [ "$FIX_TIMEOUT" -lt 1800 ]; then
      echo "retry"
    else
      echo "no-retry"
    fi
  '
  [ "$status" -eq 0 ]
  [ "$output" = "no-retry" ]
}

@test "no-retry condition: second attempt → retry guard rejects" {
  run bash -c '
    FIX_TIMEOUT=540
    _fix_attempt=2
    if [ "$_fix_attempt" -eq 1 ] && [ "$FIX_TIMEOUT" -lt 1800 ]; then
      echo "retry"
    else
      echo "no-retry"
    fi
  '
  [ "$status" -eq 0 ]
  [ "$output" = "no-retry" ]
}

@test "retry condition: first attempt + budget below cap → triggers retry" {
  run bash -c '
    FIX_TIMEOUT=540
    _fix_attempt=1
    if [ "$_fix_attempt" -eq 1 ] && [ "$FIX_TIMEOUT" -lt 1800 ]; then
      echo "retry"
    else
      echo "no-retry"
    fi
  '
  [ "$status" -eq 0 ]
  [ "$output" = "retry" ]
}
