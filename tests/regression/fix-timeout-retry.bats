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

_btest_tmpdir=""

setup() {
  [ -f "$CLAUDE_WORKFLOW" ] || {
    echo "FATAL: $CLAUDE_WORKFLOW not found" >&2
    return 1
  }
}

teardown() {
  rm -rf "${_btest_tmpdir:-}"
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

# =============================================================================
# BEHAVIORAL: verify the retry loop actually fires with a doubled budget
# =============================================================================

# =============================================================================
# DEV SESSION — structural, unit, and behavioral mirrors of the fix-session tests
# =============================================================================

@test "dev-structural: retry arm checks _dev_attempt -eq 1" {
  grep -q '_dev_attempt.*-eq 1' "$CLAUDE_WORKFLOW" || {
    echo "FAIL: '_dev_attempt -eq 1' guard not found in claude-workflow.sh" >&2
    echo "      First-attempt retry guard must be present in dev session" >&2
    return 1
  }
}

@test "dev-structural: retry arm fires on first attempt at any budget (no budget cap guard)" {
  # Dev session default is 7200s — no fixed cap like fix session's 1800s — so the
  # retry must fire unconditionally on the first attempt without a budget threshold.
  if grep -q 'CLAUDE_TIMEOUT.*-lt 1800' "$CLAUDE_WORKFLOW"; then
    echo "FAIL: dev session has a CLAUDE_TIMEOUT -lt 1800 budget cap guard" >&2
    echo "      This guard makes retry dead code at the 7200s default budget" >&2
    return 1
  fi
  grep -q '_dev_attempt.*-eq 1' "$CLAUDE_WORKFLOW" || {
    echo "FAIL: '_dev_attempt -eq 1' first-attempt guard not found in claude-workflow.sh" >&2
    return 1
  }
}

@test "dev-structural: DEV_TIMEOUT_RETRY diag line emitted on retry" {
  grep -q 'DEV_TIMEOUT_RETRY' "$CLAUDE_WORKFLOW" || {
    echo "FAIL: 'DEV_TIMEOUT_RETRY' diag not found in claude-workflow.sh" >&2
    echo "      _diag DEV_TIMEOUT_RETRY must be emitted when dev session retries" >&2
    return 1
  }
}

@test "dev-structural: dev session retry budget capped at 14400s" {
  grep -A1 '_retry_budget=$(( CLAUDE_TIMEOUT \* 2 ))' "$CLAUDE_WORKFLOW" | grep -q '_retry_budget=14400' || \
  grep -q '_retry_budget.*-gt 14400.*_retry_budget=14400' "$CLAUDE_WORKFLOW" || {
    echo "FAIL: dev session retry budget cap (14400s) not found in claude-workflow.sh" >&2
    echo "      min(2×budget, 14400) cap must be applied to dev session retry" >&2
    return 1
  }
}

@test "dev-structural: uncommitted-changes arm breaks out of dev retry loop" {
  # After 'Found uncommitted changes - committing before exit' there must be a break
  grep -A1 'Found uncommitted changes - committing before exit' "$CLAUDE_WORKFLOW" | grep -q 'break' || {
    echo "FAIL: 'break' not found after uncommitted-changes message in dev session" >&2
    echo "      Committed-work timeout must exit the loop without retrying" >&2
    return 1
  }
}

@test "behavioral: fix first no-commit timeout retries at double budget; second timeout exits 1" {
  _btest_tmpdir=$(mktemp -d)
  _budgets="$_btest_tmpdir/budgets"
  _calls="$_btest_tmpdir/calls"
  touch "$_budgets" "$_calls"
  export _RITE_TEST_BUDGETS="$_budgets"
  export _RITE_TEST_CALLS="$_calls"

  # Harness contains the verbatim retry loop from lib/core/claude-workflow.sh
  # (lines 1326-1377) with stubbed dependencies so control flow can be asserted.
  cat > "$_btest_tmpdir/harness.sh" << 'HARNESS'
#!/bin/bash
set -uo pipefail

provider_run_agentic_session() {
  echo "$2" >> "$_RITE_TEST_BUDGETS"
  echo "call" >> "$_RITE_TEST_CALLS"
  return 124
}
provider_name()                       { echo "stub"; }
provider_supports_tool_restrictions() { return 0; }
print_status()  { :; }
print_warning() { :; }
print_info()    { :; }
print_error()   { :; }
_diag()         { :; }
_timer_start()  { :; }
git() {
  if [ "${1:-}" = "status" ]; then printf ''; return 0; fi
  command git "$@"
}

AUTO_MODE=true
FIX_PROMPT="test prompt"
ISSUE_NUMBER=99
FIX_TIMEOUT=540

_fix_attempt=0
while true; do
  _fix_attempt=$(( _fix_attempt + 1 ))
  set +e
  FIX_STDERR_FILE=$(mktemp)
  provider_run_agentic_session "$FIX_PROMPT" "$FIX_TIMEOUT" true "$FIX_STDERR_FILE"
  FIX_EXIT_CODE=$?
  rm -f "$FIX_STDERR_FILE"
  set -e
  if [ $FIX_EXIT_CODE -eq 124 ]; then
    if [ "$(git status --porcelain | grep -vE '^\?\?' | { grep -v '\.gitignore$' || true; } | wc -l | tr -d ' ')" -gt 0 ]; then
      print_info "Found uncommitted changes - will commit what we have"
      break
    else
      if [ "$_fix_attempt" -eq 1 ] && [ "$FIX_TIMEOUT" -lt 1800 ]; then
        _retry_budget=$(( FIX_TIMEOUT * 2 ))
        [ "$_retry_budget" -gt 1800 ] && _retry_budget=1800
        _diag "FIX_TIMEOUT_RETRY issue=${ISSUE_NUMBER:-} budget=${_retry_budget}s"
        print_info "No fixes before timeout — retrying at double budget (${_retry_budget}s)..."
        FIX_TIMEOUT=$_retry_budget
        continue
      fi
      print_error "No fixes made before timeout"
      exit 1
    fi
  elif [ $FIX_EXIT_CODE -ne 0 ]; then
    :
  fi
  break
done
HARNESS

  chmod +x "$_btest_tmpdir/harness.sh"
  run bash "$_btest_tmpdir/harness.sh"

  [ "$status" -eq 1 ]

  _call_count=$(wc -l < "$_calls" | tr -d ' ')
  [ "$_call_count" -eq 2 ]

  _b1=$(sed -n '1p' "$_budgets")
  _b2=$(sed -n '2p' "$_budgets")
  [ "$_b2" -eq $(( _b1 * 2 )) ]
}

@test "behavioral: dev first no-commit timeout retries at double budget; second timeout exits 1" {
  _btest_tmpdir=$(mktemp -d)
  _budgets="$_btest_tmpdir/budgets"
  _calls="$_btest_tmpdir/calls"
  touch "$_budgets" "$_calls"
  export _RITE_TEST_BUDGETS="$_budgets"
  export _RITE_TEST_CALLS="$_calls"

  # Harness mirrors the dev-session while loop from lib/core/claude-workflow.sh
  # with stubbed dependencies so control flow can be asserted.
  cat > "$_btest_tmpdir/harness.sh" << 'HARNESS'
#!/bin/bash
set -uo pipefail

provider_run_agentic_session() {
  echo "$2" >> "$_RITE_TEST_BUDGETS"
  echo "call" >> "$_RITE_TEST_CALLS"
  return 124
}
provider_name()                       { echo "stub"; }
provider_supports_tool_restrictions() { return 0; }
print_status()  { :; }
print_warning() { :; }
print_info()    { :; }
print_error()   { :; }
_diag()         { :; }
_timer_start()  { :; }
git() {
  if [ "${1:-}" = "status" ]; then printf ''; return 0; fi
  command git "$@"
}

AUTO_MODE=true
CLAUDE_PROMPT="test prompt"
ISSUE_NUMBER=99
CLAUDE_TIMEOUT=540
CLAUDE_STDERR_FILE=""

_dev_attempt=0
while true; do
  _dev_attempt=$(( _dev_attempt + 1 ))
  rm -f "${CLAUDE_STDERR_FILE:-}" 2>/dev/null || true
  CLAUDE_STDERR_FILE=$(mktemp)
  set +e
  provider_run_agentic_session "$CLAUDE_PROMPT" "$CLAUDE_TIMEOUT" "$AUTO_MODE" "$CLAUDE_STDERR_FILE"
  CLAUDE_EXIT_CODE=$?
  set -e
  if [ $CLAUDE_EXIT_CODE -eq 124 ]; then
    if [ "$(git status --porcelain | { grep -v '\.gitignore$' || true; } | wc -l | tr -d ' ')" -gt 0 ]; then
      print_warning "Found uncommitted changes - committing before exit"
      break
    else
      if [ "$_dev_attempt" -eq 1 ]; then
        _retry_budget=$(( CLAUDE_TIMEOUT * 2 ))
        [ "$_retry_budget" -gt 14400 ] && _retry_budget=14400
        _diag "DEV_TIMEOUT_RETRY issue=${ISSUE_NUMBER:-} budget=${_retry_budget}s"
        print_info "No changes before timeout — retrying at double budget (${_retry_budget}s)..."
        CLAUDE_TIMEOUT=$_retry_budget
        continue
      fi
      print_error "No changes detected - workflow failed"
      exit 1
    fi
  elif [ $CLAUDE_EXIT_CODE -ne 0 ]; then
    :
  fi
  break
done
HARNESS

  chmod +x "$_btest_tmpdir/harness.sh"
  run bash "$_btest_tmpdir/harness.sh"

  [ "$status" -eq 1 ]

  _call_count=$(wc -l < "$_calls" | tr -d ' ')
  [ "$_call_count" -eq 2 ]

  _b1=$(sed -n '1p' "$_budgets")
  _b2=$(sed -n '2p' "$_budgets")
  [ "$_b2" -eq $(( _b1 * 2 )) ]
}
