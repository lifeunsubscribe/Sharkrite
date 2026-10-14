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

  # Create an isolated fixture git repo with a file-protocol bare remote.
  # This ensures all git operations (fetch, push, ls-remote) target only the
  # fixture and never touch the real sharkrite repo or any live branches.
  export _FAKE_REMOTE="$RITE_TEST_TMPDIR/fake-remote.git"
  export _FAKE_PROJECT="$RITE_TEST_TMPDIR/fake-project"
  git init --bare "$_FAKE_REMOTE" 2>/dev/null || true
  git init "$_FAKE_PROJECT" 2>/dev/null || true
  git -C "$_FAKE_PROJECT" remote add origin "file://$_FAKE_REMOTE"
  git -C "$_FAKE_PROJECT" config user.email "test@test"
  git -C "$_FAKE_PROJECT" config user.name "test"
  git -C "$_FAKE_PROJECT" commit --allow-empty -m "init" 2>/dev/null || true
  git -C "$_FAKE_PROJECT" push origin HEAD:main 2>/dev/null || true
  mkdir -p "$_FAKE_PROJECT/.rite/logs"

  export _FAKE_BIN="$RITE_TEST_TMPDIR/fake-bin"
  mkdir -p "$_FAKE_BIN"
  ln -sf "$RITE_REPO_ROOT/bin/rite" "$_FAKE_BIN/rite"

  # Stub gh so no live GitHub API calls are made.  Returning an empty JSON
  # array satisfies every gh pr list / gh pr view caller in the dispatch path.
  printf '#!/bin/sh\nprintf "[]\n"\n' > "$_FAKE_BIN/gh"
  chmod +x "$_FAKE_BIN/gh"
}

teardown() {
  teardown_test_tmpdir
}

# _run_rite ARGS...
# Runs bin/rite with logging enabled (the default) and the test project root.
# Uses bats' `run` so $status and $output are set; non-zero exit is expected
# because the fixture has no real GitHub remote or issue state.
#
# Isolation: cds into the fixture repo before invoking bin/rite so that any
# git commands (worktree list, fetch, push) operate on the fixture, not the
# real sharkrite worktree.  The gh stub in _FAKE_BIN prevents GitHub API calls.
_run_rite() {
  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    HOME="$RITE_TEST_TMPDIR" \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    bash -c 'cd "$RITE_PROJECT_ROOT" && exec bash "$@"' \
    bash "$_FAKE_BIN/rite" "$@" < /dev/null
}

# _log_count GREP_PATTERN
# Returns the number of log files whose basename matches GREP_PATTERN inside
# the test project's .rite/logs/ directory.  Never exits non-zero.
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
  # Dispatch must have attempted to run (exits non-zero in fixture env; the
  # log is created before dispatch so this distinguishes a dropped arm from a
  # dispatch that ran and failed expectedly).
  [ "$status" -ne 0 ]
}

@test "--promote with slash in branch sanitizes slug (/ becomes -)" {
  _run_rite --promote feat/my-integration

  local _count
  _count=$(_log_count "^rite-promote-feat-my-integration-")
  [ "$_count" -ge 1 ]
}

@test "--promote with space in branch sanitizes slug (space becomes -)" {
  _run_rite --promote "my branch"

  local _count
  _count=$(_log_count "^rite-promote-my-branch-")
  [ "$_count" -ge 1 ]
}

@test "promote log file contains the standard sharkrite log header" {
  _run_rite --promote supervised-ux

  local _log
  _log=$(ls -1 "$_FAKE_PROJECT/.rite/logs/" 2>/dev/null | grep "^rite-promote-supervised-ux-" | head -1 || true)
  [ -n "$_log" ]
  grep -q "=== Sharkrite Log ===" "$_FAKE_PROJECT/.rite/logs/$_log"
}

@test "--promote (no branch) prints error and exits non-zero" {
  _run_rite --promote
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a branch name"* ]]
}

# ---------------------------------------------------------------------------
# --sync (branch form, issue form, bare sweep)
# ---------------------------------------------------------------------------

@test "--sync <branch> creates rite-sync-<branch>-<ts>.log" {
  _run_rite --sync staging

  local _count
  _count=$(_log_count "^rite-sync-staging-")
  [ "$_count" -ge 1 ]
  [ "$status" -ne 0 ]
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

@test "--sync with mixed numeric and non-numeric args prints error and exits 1" {
  _run_rite --sync 42 not-a-branch
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid arguments"* ]]
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
