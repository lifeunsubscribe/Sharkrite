#!/usr/bin/env bats
# sharkrite-test-covers: tests/helpers/*
# sharkrite-gate-serial
# Self-tests for fault-injection harness
# Demonstrates all fault injection patterns

load 'setup'
load 'gh-mock'
load 'claude-mock'
load 'fault-injection'

setup() {
  export RITE_REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  reset_fault_injection

  # Resolve a timeout command for the hang tests. macOS ships no timeout(1);
  # coreutils provides gtimeout (and links timeout unprefixed). Mirrors the
  # claude-timeout.bats precedent: resolve via lib/utils/timeout.sh, and the
  # hang tests skip when neither is installed instead of failing with 127.
  source "${RITE_REPO_ROOT}/lib/utils/timeout.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests; keep -e
  ensure_timeout_cmd
}

# =============================================================================
# Empty stdout tests
# =============================================================================

@test "inject_claude_empty_output returns empty response" {
  inject_claude_empty_output

  run mock_claude --print "fix the bug"

  [ "$status" -eq 0 ]
  # Extract text from stream - should be empty
  text=$(echo "$output" | extract_claude_text)
  [ -z "$text" ]
}

# =============================================================================
# Exit code tests
# =============================================================================

@test "inject_gh_failure_nth causes exit 1 on specified call" {
  inject_gh_failure_nth 2 1

  # First call succeeds
  run mock_gh pr list
  [ "$status" -eq 0 ]

  # Second call fails
  run mock_gh pr view 123
  [ "$status" -eq 1 ]
  [[ "$output" =~ "mock failure" ]]

  # Third call succeeds
  run mock_gh issue list
  [ "$status" -eq 0 ]
}

@test "inject_gh_usage_cap returns exit 5" {
  inject_gh_usage_cap

  run mock_gh api /rate_limit
  [ "$status" -eq 5 ]
  [[ "$output" =~ "Usage limit exceeded" ]]
}

@test "inject_claude_timeout returns exit 124" {
  inject_claude_timeout

  run mock_claude --print "analyze this"
  [ "$status" -eq 124 ]
}

@test "inject_stderr_failure adds custom error message" {
  inject_stderr_failure "gh" "API error: not found" 1

  run mock_gh pr view 999
  [ "$status" -eq 1 ]
  # stderr captured in output by bats run
  [[ "$output" =~ "API error: not found" ]]
}

# =============================================================================
# Rate limit tests
# =============================================================================

@test "inject_gh_rate_limit returns rate limit JSON" {
  inject_gh_rate_limit

  run mock_gh pr list
  [ "$status" -eq 1 ]
  [[ "$output" =~ "API rate limit exceeded" ]]
  [[ "$output" =~ "documentation_url" ]]
}

# =============================================================================
# Hang tests
# =============================================================================

@test "inject_command_hang causes timeout for gh" {
  [ -n "${RITE_TIMEOUT_CMD:-}" ] || skip "No timeout command available (install coreutils)"
  inject_command_hang "gh"

  # The external timeout binary cannot invoke a bash function directly, so
  # export the function and run it through a child shell.
  export -f mock_gh
  run "$RITE_TIMEOUT_CMD" 1 bash -c 'mock_gh pr list'
  # timeout exits with 124 when command times out
  [ "$status" -eq 124 ]
}

@test "inject_command_hang with duration hangs for specified time" {
  [ -n "${RITE_TIMEOUT_CMD:-}" ] || skip "No timeout command available (install coreutils)"
  inject_command_hang "claude" 2

  # The external timeout binary cannot invoke a bash function directly, so
  # export the function and run it through a child shell.
  export -f mock_claude
  start_time=$(date +%s)
  run "$RITE_TIMEOUT_CMD" 3 bash -c 'mock_claude --print "task"'
  end_time=$(date +%s)

  duration=$((end_time - start_time))
  # Should hang for ~2 seconds (allow 1s variance for timing)
  [ "$duration" -ge 1 ]
  [ "$duration" -le 3 ]
}

# =============================================================================
# Nth-call retry pattern tests
# =============================================================================

@test "nth-call pattern simulates transient failures" {
  # Simulate: fail on 1st call, succeed on retry
  inject_gh_failure_nth 1 1

  # First call fails
  run mock_gh pr list
  [ "$status" -eq 1 ]

  # Reset to allow retry
  reset_gh_mock

  # Retry succeeds (fresh call counter)
  run mock_gh pr list
  [ "$status" -eq 0 ]
}

@test "nth-call pattern with multiple failures" {
  inject_claude_failure_nth 2 1

  # First call succeeds
  run mock_claude --print "task 1"
  [ "$status" -eq 0 ]

  # Second call fails
  run mock_claude --print "task 2"
  [ "$status" -eq 1 ]

  # Third call succeeds
  run mock_claude --print "task 3"
  [ "$status" -eq 0 ]
}

# =============================================================================
# State reset tests
# =============================================================================

@test "reset_fault_injection clears all state" {
  # Set multiple fault modes
  inject_gh_failure_nth 1 5
  inject_claude_timeout
  inject_command_hang "gh"

  # Reset everything
  reset_fault_injection

  # Verify gh works normally
  run mock_gh pr list
  [ "$status" -eq 0 ]

  # Verify claude works normally
  run mock_claude --print "test"
  [ "$status" -eq 0 ]

  # Verify no hang — route through a child shell so the external timeout
  # binary can reach the exported bash function. Skip is placed here (not at
  # the top) so the mock_gh/mock_claude reset assertions above still run on
  # machines without a timeout command.
  [ -n "${RITE_TIMEOUT_CMD:-}" ] || skip "No timeout command available (install coreutils)"
  export -f mock_gh
  run "$RITE_TIMEOUT_CMD" 1 bash -c 'mock_gh issue list'
  [ "$status" -eq 0 ]
}

# =============================================================================
# Fixture override tests
# =============================================================================

@test "CLAUDE_MOCK_FIXTURE_OVERRIDE uses custom fixture" {
  inject_claude_empty_output

  # Verify it uses the fault fixture
  [ "$CLAUDE_MOCK_FIXTURE_OVERRIDE" = "${RITE_REPO_ROOT}/tests/fixtures/faults/claude-empty.jsonl" ]

  run mock_claude --print "test"
  text=$(echo "$output" | extract_claude_text)
  [ -z "$text" ]
}

@test "GH_MOCK_FIXTURE_OVERRIDE uses custom fixture" {
  inject_gh_rate_limit

  # Verify it uses the fault fixture
  [ "$GH_MOCK_FIXTURE_OVERRIDE" = "${RITE_REPO_ROOT}/tests/fixtures/faults/gh-rate-limit.json" ]

  run mock_gh pr list
  [[ "$output" =~ "rate limit" ]]
}

# =============================================================================
# Environment verification tests
# =============================================================================

@test "verify_fault_injection_env detects missing setup" {
  unset RITE_REPO_ROOT

  run verify_fault_injection_env
  [ "$status" -ne 0 ]
  [[ "$output" =~ "RITE_REPO_ROOT not set" ]]
}

@test "verify_fault_injection_env succeeds when properly configured" {
  run verify_fault_injection_env
  [ "$status" -eq 0 ]
}
