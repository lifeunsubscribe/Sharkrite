#!/usr/bin/env bash
# Fault-injection harness for bats tests
#
# Extends gh-mock.bash and claude-mock.bash with configurable failure modes
# for testing error handling, retry logic, and edge cases.
#
# Usage:
#   source tests/helpers/fault-injection.bash
#   inject_gh_failure_nth 2 5  # Fail on 2nd call with exit code 5
#   inject_claude_empty_output # Return empty response
#   inject_gh_rate_limit       # Return rate-limit JSON
#   reset_fault_injection      # Clear all fault state
#
# See tests/helpers/README.md for full documentation and examples.

# Inject gh failure on Nth call
# Args: call_number exit_code
# Example: inject_gh_failure_nth 2 5  # Fail on 2nd call with exit 5
inject_gh_failure_nth() {
  local call_number="${1:?Call number required}"
  local exit_code="${2:-1}"

  export GH_MOCK_FAIL_NTH="$call_number"
  export GH_MOCK_EXIT_CODE="$exit_code"
}

# Inject claude failure on Nth call
# Args: call_number exit_code
# Example: inject_claude_failure_nth 1 124  # Timeout on 1st call
inject_claude_failure_nth() {
  local call_number="${1:?Call number required}"
  local exit_code="${2:-1}"

  export CLAUDE_MOCK_FAIL_NTH="$call_number"
  export CLAUDE_MOCK_EXIT_CODE="$exit_code"
}

# Make claude return empty output
# Claude will run but produce no text deltas (simulates empty response)
inject_claude_empty_output() {
  export CLAUDE_MOCK_SCENARIO="empty"
  export CLAUDE_MOCK_FIXTURE_OVERRIDE="${RITE_REPO_ROOT}/tests/fixtures/faults/claude-empty.jsonl"
}

# Make claude exit with timeout code (124)
# Simulates command timeout via timeout(1) wrapper
inject_claude_timeout() {
  export CLAUDE_MOCK_EXIT_CODE=124
  export CLAUDE_MOCK_SCENARIO="timeout"
}

# Make gh return rate-limit error response
# Returns proper JSON error structure with rate limit message
inject_gh_rate_limit() {
  export GH_MOCK_RATE_LIMIT=1
  export GH_MOCK_EXIT_CODE=1
  export GH_MOCK_FIXTURE_OVERRIDE="${RITE_REPO_ROOT}/tests/fixtures/faults/gh-rate-limit.json"
}

# Make gh return usage cap error (exit 5)
# GitHub CLI returns exit 5 for usage/quota exceeded
inject_gh_usage_cap() {
  export GH_MOCK_EXIT_CODE=5
  export GH_MOCK_FIXTURE_OVERRIDE="${RITE_REPO_ROOT}/tests/fixtures/faults/gh-usage-cap.json"
}

# Make a command hang indefinitely
# Args: command_name
# Example: inject_command_hang "claude"
# Note: Tests using this should use timeout(1) wrapper or background execution
inject_command_hang() {
  local command="${1:?Command name required}"

  export MOCK_HANG_COMMAND="$command"
  export MOCK_HANG_DURATION="${2:-infinity}"  # seconds, or "infinity"
}

# Inject pip failure (for venv/dependency issues)
# Args: exit_code
inject_pip_failure() {
  local exit_code="${1:-1}"

  export PIP_MOCK_EXIT_CODE="$exit_code"
}

# Inject stderr output with exit failure
# Args: command error_message exit_code
# Example: inject_stderr_failure "gh" "API error: not found" 1
inject_stderr_failure() {
  local command="${1:?Command name required}"
  local error_message="${2:?Error message required}"
  local exit_code="${3:-1}"

  case "$command" in
    gh)
      export GH_MOCK_STDERR="$error_message"
      export GH_MOCK_EXIT_CODE="$exit_code"
      ;;
    claude)
      export CLAUDE_MOCK_STDERR="$error_message"
      export CLAUDE_MOCK_EXIT_CODE="$exit_code"
      ;;
    *)
      echo "Warning: inject_stderr_failure for '$command' not implemented" >&2
      return 1
      ;;
  esac
}

# Reset all fault injection state
# Call this in test setup() to ensure clean state
reset_fault_injection() {
  # gh mock state
  unset GH_MOCK_FAIL_NTH
  unset GH_MOCK_EXIT_CODE
  unset GH_MOCK_RATE_LIMIT
  unset GH_MOCK_FIXTURE_OVERRIDE
  unset GH_MOCK_STDERR

  # claude mock state
  unset CLAUDE_MOCK_FAIL_NTH
  unset CLAUDE_MOCK_EXIT_CODE
  unset CLAUDE_MOCK_SCENARIO
  unset CLAUDE_MOCK_FIXTURE_OVERRIDE
  unset CLAUDE_MOCK_STDERR

  # Generic mock state
  unset MOCK_HANG_COMMAND
  unset MOCK_HANG_DURATION
  unset PIP_MOCK_EXIT_CODE

  # Reset call counters (if mocks are already loaded)
  if declare -p _GH_MOCK_CALL_COUNT &>/dev/null; then
    _GH_MOCK_CALL_COUNT=0
  fi
  if declare -p _CLAUDE_MOCK_CALL_COUNT &>/dev/null; then
    _CLAUDE_MOCK_CALL_COUNT=0
  fi
}

# Verify fault injection is working
# Returns 0 if environment is correctly configured, 1 otherwise
verify_fault_injection_env() {
  local errors=0

  # Check RITE_REPO_ROOT is set
  if [ -z "${RITE_REPO_ROOT:-}" ]; then
    echo "Error: RITE_REPO_ROOT not set" >&2
    errors=$((errors + 1))
  fi

  # Check fault fixtures directory exists
  if [ ! -d "${RITE_REPO_ROOT:-/nonexistent}/tests/fixtures/faults" ]; then
    echo "Error: tests/fixtures/faults directory not found" >&2
    errors=$((errors + 1))
  fi

  # Check mock helpers are available
  if ! declare -f mock_gh &>/dev/null; then
    echo "Warning: mock_gh function not found (source gh-mock.bash first)" >&2
  fi

  if ! declare -f mock_claude &>/dev/null; then
    echo "Warning: mock_claude function not found (source claude-mock.bash first)" >&2
  fi

  return $errors
}
