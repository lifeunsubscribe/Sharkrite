#!/usr/bin/env bash
# Common test setup for all bats tests
#
# Usage: source this file in your test's setup() function
#
# Provides:
# - RITE_TEST_TMPDIR: Unique temp directory for this test
# - RITE_REPO_ROOT: Path to the sharkrite repo root
# - Helper loading functions

# Determine repo root (tests/ is always one level down from root)
RITE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export RITE_REPO_ROOT

# Create unique temp directory for this test
# Will be cleaned up automatically by bats after test completes
#
# Also exports RITE_LOCK_DIR pointing inside the test tmpdir so that any lib
# sourced after this call (including config.sh and issue-lock.sh) resolves the
# lock/evidence directory to the test tmpdir rather than the real .rite/locks/.
# Must be set before sourcing config.sh (which uses the :- default).
setup_test_tmpdir() {
  export RITE_TEST_TMPDIR="$(mktemp -d "${BATS_TEST_TMPDIR}/rite-test.XXXXXX")"
  export RITE_LOCK_DIR="${RITE_TEST_TMPDIR}/locks"
  cd "$RITE_TEST_TMPDIR"
}

# Load a sharkrite library file
# Usage: load_lib utils/config.sh
load_lib() {
  local lib_file="$1"
  # shellcheck disable=SC1090
  source "${RITE_REPO_ROOT}/lib/${lib_file}"
}

# Load a test helper
# Usage: load_helper git-fixtures
load_helper() {
  local helper_name="$1"
  # shellcheck disable=SC1090
  source "${RITE_REPO_ROOT}/tests/helpers/${helper_name}.bash"
}

# Load a provider (wrapper for provider-interface.sh load_provider)
# Usage: load_provider "gemini-mock"
# Requires: RITE_LIB_DIR must be set
load_provider() {
  local provider_name="$1"

  # Ensure provider-interface.sh is sourced (check for _LOADED_PROVIDER variable)
  if [ -z "${_LOADED_PROVIDER+x}" ]; then
    # shellcheck disable=SC1091
    source "${RITE_LIB_DIR}/providers/provider-interface.sh"
  fi

  # Call the actual load_provider from provider-interface.sh
  # Use the sourced function directly
  local provider_file="${RITE_LIB_DIR}/providers/${provider_name}.sh"

  # Check if provider file exists (support both real and mock providers)
  if [ ! -f "$provider_file" ]; then
    # Try tests/fixtures/providers for mocks
    provider_file="${RITE_REPO_ROOT}/tests/fixtures/providers/${provider_name}.sh"
    if [ ! -f "$provider_file" ]; then
      echo "Unknown provider: $provider_name" >&2
      return 1
    fi
  fi

  # Source the provider file
  # shellcheck disable=SC1090
  source "$provider_file"

  # Alias provider functions (replicate provider-interface.sh logic)
  local fn
  for fn in \
    detect_cli validate_cli \
    run_agentic_session run_prompt run_prompt_with_timeout \
    run_streaming_prompt run_classify run_uncached \
    detect_error \
    supports_tool_restrictions build_tool_restrictions \
    dev_session_preamble exit_instructions \
    resolve_model name; do
    eval "provider_${fn}() { ${provider_name//-/_}_provider_${fn} \"\$@\"; }"
  done
}

# Return a provably-dead PID from a completed subshell.
#
# Why not hardcode 99999 / 99999999?
#   On Linux hosts with pid_max > 99999 (containers, custom kernel configs)
#   those values may be live processes, causing flaky test failures.
#   A subshell PID is guaranteed dead after wait returns — no assumption
#   about the kernel's PID ceiling is required.
#
# Usage:
#   _dead=$(get_dead_pid)
#   echo "$_dead" > some-lock/pid
get_dead_pid() {
  local _pid
  ( true ) &
  _pid=$!
  wait "$_pid" 2>/dev/null || true
  echo "$_pid"
}

# Common cleanup (called automatically by bats teardown if defined)
teardown_test_tmpdir() {
  if [ -n "${RITE_TEST_TMPDIR:-}" ] && [ -d "$RITE_TEST_TMPDIR" ]; then
    rm -rf "$RITE_TEST_TMPDIR"
  fi
}
