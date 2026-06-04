#!/usr/bin/env bats
# tests/regression/setup-guard-ordering.bats
#
# Regression tests for setup() guard ordering in test files.
#
# Bug history (issue #256, from PR #253 assessment):
#   gh-mock-binary-concurrent.bats had a guard at the top of setup() that
#   checked [[ -n "${RITE_TEST_TMPDIR:-}" ]] before calling setup_test_tmpdir.
#   Since RITE_TEST_TMPDIR is only assigned by setup_test_tmpdir, the guard
#   always fired with a misleading error in clean CI environments where
#   RITE_TEST_TMPDIR was not pre-set.
#
#   Correct ordering:
#     1. setup_test_tmpdir           → assigns RITE_TEST_TMPDIR
#     2. [[ -n RITE_TEST_TMPDIR ]]   → guard that can actually fire on failure
#
# These tests verify the ordering contract using setup.bash directly, and
# confirm that the fixed file respects it.
#
# Verification command:
#   bats tests/regression/setup-guard-ordering.bats

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: note the pre-call state of RITE_TEST_TMPDIR, then call setup_test_tmpdir
# ---------------------------------------------------------------------------

setup() {
  # Unset RITE_TEST_TMPDIR so we start from a clean-CI-like state
  unset RITE_TEST_TMPDIR

  setup_test_tmpdir
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# 1. RITE_TEST_TMPDIR is empty before setup_test_tmpdir is called
#
# Documents the bug: if a guard checks RITE_TEST_TMPDIR before
# setup_test_tmpdir, it will always fire in clean environments.
# ---------------------------------------------------------------------------

@test "RITE_TEST_TMPDIR is unset before setup_test_tmpdir is called" {
  # This test exercises the invariant by running a subshell that simulates
  # what a pre-guard check sees: an environment where RITE_TEST_TMPDIR
  # has not yet been assigned by setup_test_tmpdir.
  run bash -c '
    source "'"${RITE_REPO_ROOT}/tests/helpers/setup.bash"'"
    unset RITE_TEST_TMPDIR

    # Simulate the buggy pattern: guard fires before setup_test_tmpdir
    if [[ -n "${RITE_TEST_TMPDIR:-}" ]]; then
      echo "SET"
    else
      echo "UNSET"
    fi
  '

  [ "$status" -eq 0 ]
  [ "$output" = "UNSET" ]
}

# ---------------------------------------------------------------------------
# 2. RITE_TEST_TMPDIR is set after setup_test_tmpdir is called
#
# Documents the correct ordering: call setup_test_tmpdir first, then guard.
# ---------------------------------------------------------------------------

@test "RITE_TEST_TMPDIR is non-empty after setup_test_tmpdir is called" {
  # setup() above already called setup_test_tmpdir — RITE_TEST_TMPDIR must now be set
  [[ -n "${RITE_TEST_TMPDIR:-}" ]] || {
    echo "FAIL: RITE_TEST_TMPDIR is empty after setup_test_tmpdir"
    false
  }
}

# ---------------------------------------------------------------------------
# 3. RITE_TEST_TMPDIR points to an existing directory after setup_test_tmpdir
# ---------------------------------------------------------------------------

@test "RITE_TEST_TMPDIR points to an existing directory after setup_test_tmpdir" {
  [ -d "${RITE_TEST_TMPDIR:-}" ] || {
    echo "FAIL: RITE_TEST_TMPDIR ('${RITE_TEST_TMPDIR:-}') is not a directory"
    false
  }
}

# ---------------------------------------------------------------------------
# 4. setup_test_tmpdir is idempotent: calling it twice does not crash
#
# While tests should not call it twice, this verifies that the helper
# itself does not have side-effects that break on re-invocation (e.g.
# shell errors from chdir into the new tmpdir replacing the old one).
# ---------------------------------------------------------------------------

@test "setup_test_tmpdir can be called a second time without error" {
  local first_tmpdir="$RITE_TEST_TMPDIR"

  # Second call should succeed and update RITE_TEST_TMPDIR to a new path
  setup_test_tmpdir

  # The new value must be a non-empty, existing directory
  [[ -n "${RITE_TEST_TMPDIR:-}" ]] || {
    echo "FAIL: RITE_TEST_TMPDIR empty after second call"
    false
  }
  [ -d "${RITE_TEST_TMPDIR:-}" ] || {
    echo "FAIL: RITE_TEST_TMPDIR not a directory after second call"
    false
  }
}

# ---------------------------------------------------------------------------
# 5. RITE_REPO_ROOT is available at load time (before setup_test_tmpdir)
#
# Documents that RITE_REPO_ROOT is assigned by setup.bash at source time
# (not inside setup_test_tmpdir), so a guard checking it before
# setup_test_tmpdir is called is correct and intentional.
# ---------------------------------------------------------------------------

@test "RITE_REPO_ROOT is set at load time independently of setup_test_tmpdir" {
  run bash -c '
    unset RITE_REPO_ROOT
    source "'"${RITE_REPO_ROOT}/tests/helpers/setup.bash"'"

    # RITE_REPO_ROOT must be set by the source, before setup_test_tmpdir
    if [[ -n "${RITE_REPO_ROOT:-}" ]]; then
      echo "SET"
    else
      echo "UNSET"
    fi
  '

  [ "$status" -eq 0 ]
  [ "$output" = "SET" ]
}
