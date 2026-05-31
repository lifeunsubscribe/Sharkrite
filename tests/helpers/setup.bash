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
setup_test_tmpdir() {
  export RITE_TEST_TMPDIR="$(mktemp -d "${BATS_TEST_TMPDIR}/rite-test.XXXXXX")"
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

# Common cleanup (called automatically by bats teardown if defined)
teardown_test_tmpdir() {
  if [ -n "${RITE_TEST_TMPDIR:-}" ] && [ -d "$RITE_TEST_TMPDIR" ]; then
    rm -rf "$RITE_TEST_TMPDIR"
  fi
}
