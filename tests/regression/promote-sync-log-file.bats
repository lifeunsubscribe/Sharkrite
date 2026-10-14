#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite
#
# Regression tests for issue #1211: --promote and --sync log file creation.
#
# Before the fix, both dispatch arms exited before the logging setup block ran,
# so no .rite/logs/rite-*.log file was ever created for those modes.
#
# After the fix, both arms are positioned after the FIFO tee setup and the slug
# block computes a meaningful name for each variant:
#   --promote <branch>       → rite-promote-<branch>-<ts>.log
#   --sync <branch>          → rite-sync-<branch>-<ts>.log
#   --sync <N> [<N>...]      → rite-sync-<N>-<M>-<ts>.log
#   --sync (bare)            → rite-sync-all-<ts>.log
#
# Tests also verify that read-only modes remain unaffected (no log created) and
# that --no-log still suppresses log creation for both new modes.

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  export _FAKE_PROJECT="$RITE_TEST_TMPDIR/fake-project"
  mkdir -p "$_FAKE_PROJECT/.rite/logs"

  export _FAKE_BIN="$RITE_TEST_TMPDIR/fake-bin"
  mkdir -p "$_FAKE_BIN"
  ln -sf "$RITE_REPO_ROOT/bin/rite" "$_FAKE_BIN/rite"
}

teardown() {
  teardown_test_tmpdir
}

# _run_rite ARGS...
# Runs bin/rite with logging enabled (the default) and the test project root.
# Uses bats' `run` so $status and $output are set; never aborts the test on
# non-zero exit (bin/rite exits non-zero in a test env because there is no real
# git repo or GitHub auth, but the log file is created before the dispatch).
_run_rite() {
  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    bash "$_FAKE_BIN/rite" "$@" < /dev/null
}

# _log_count GLOB
# Returns the number of log files whose basename matches GLOB inside the test
# project's .rite/logs/ directory.  Never exits non-zero.
_log_count() {
  ls "$_FAKE_PROJECT/.rite/logs/" 2>/dev/null | grep -c "$1" || true
}

# ---------------------------------------------------------------------------
# --promote
# ---------------------------------------------------------------------------

@test "--promote <branch> creates rite-promote-<branch>-<ts>.log" {
  _run_rite --promote supervised-ux

  local _count
  _count=$(_log_count "^rite-promote-supervised-ux-")
  [ "$_count" -ge 1 ]
}

@test "--promote with slash in branch sanitizes slug (/ becomes -)" {
  _run_rite --promote feat/my-integration

  local _count
  _count=$(_log_count "^rite-promote-feat-my-integration-")
  [ "$_count" -ge 1 ]
}

@test "promote log file contains the standard sharkrite log header" {
  _run_rite --promote supervised-ux

  local _log
  _log=$(ls -1 "$_FAKE_PROJECT/.rite/logs/" 2>/dev/null | grep "^rite-promote-supervised-ux-" | head -1 || true)
  [ -n "$_log" ]
  grep -q "=== Sharkrite Log ===" "$_FAKE_PROJECT/.rite/logs/$_log"
}

# ---------------------------------------------------------------------------
# --sync (branch form, issue form, bare sweep)
# ---------------------------------------------------------------------------

@test "--sync <branch> creates rite-sync-<branch>-<ts>.log" {
  _run_rite --sync staging

  local _count
  _count=$(_log_count "^rite-sync-staging-")
  [ "$_count" -ge 1 ]
}

@test "--sync <N> creates rite-sync-<N>-<ts>.log" {
  _run_rite --sync 42

  local _count
  _count=$(_log_count "^rite-sync-42-")
  [ "$_count" -ge 1 ]
}

@test "--sync <N> <M> creates rite-sync-<N>-<M>-<ts>.log" {
  _run_rite --sync 42 43

  local _count
  _count=$(_log_count "^rite-sync-42-43-")
  [ "$_count" -ge 1 ]
}

@test "bare --sync creates rite-sync-all-<ts>.log" {
  _run_rite --sync

  local _count
  _count=$(_log_count "^rite-sync-all-")
  [ "$_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Read-only modes: exemption list unchanged, no log created
# ---------------------------------------------------------------------------

@test "read-only --status creates no log file" {
  _run_rite --status

  local _count
  _count=$(_log_count "^rite-")
  [ "$_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# --no-log suppresses log creation for both new modes
# ---------------------------------------------------------------------------

@test "--promote --no-log suppresses log creation" {
  _run_rite --promote test-branch --no-log

  local _count
  _count=$(_log_count "^rite-promote-")
  [ "$_count" -eq 0 ]
}

@test "--sync --no-log suppresses log creation" {
  _run_rite --sync staging --no-log

  local _count
  _count=$(_log_count "^rite-sync-")
  [ "$_count" -eq 0 ]
}
