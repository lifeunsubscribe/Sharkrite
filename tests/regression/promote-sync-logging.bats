#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite
# tests/regression/promote-sync-logging.bats
#
# Regression: --promote and --sync create named log files via the standard
# FIFO tee (issue #1211). The fix moved their dispatch below the logging
# setup block; prior to the fix both modes dispatched early and exited
# before logging was initialised, leaving no transcript.
#
# Tests:
#   1. Structural: promote/sync absent from the RITE_LOG_AUTO=false exemption
#   2. Structural: dispatch order — both modes appear after the logging block
#   3. Structural: log-slug derivation has arms for promote and sync
#   4. Behavioral: rite --promote <branch> writes rite-promote-<branch>-*.log
#   5. Behavioral: rite --sync <branch>  writes rite-sync-<branch>-*.log
#   6. Behavioral: rite --sync (bare)    writes rite-sync-all-*.log
#   7. Behavioral: --no-log suppresses log creation for --promote

load '../helpers/setup'

setup() {
  setup_test_tmpdir
  # Pre-create the logs directory so the log file can be written there.
  mkdir -p "$RITE_TEST_TMPDIR/.rite/logs"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Shared helper: run bin/rite with logging enabled, RITE_PROJECT_ROOT set to
# the test tmpdir so the log file lands there.  Exit code is not asserted —
# the dispatch will fail naturally (no ledger / no git remote) but the log
# file must already exist because it is written before the dispatch fires.
# ---------------------------------------------------------------------------
_run_rite_logged() {
  run env \
    -u RITE_LOG_FILE \
    -u RITE_LOG_AUTO \
    -u PR_NUMBER \
    -u ISSUE_NUMBER \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    RITE_LOCK_DIR="$RITE_TEST_TMPDIR/locks" \
    bash "$RITE_REPO_ROOT/bin/rite" "$@" < /dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Shared helper: grep bin/rite for a pattern and return the first line number.
# ---------------------------------------------------------------------------
_line_of() {
  grep -n "$1" "$RITE_REPO_ROOT/bin/rite" | head -1 | cut -d: -f1
}

# ---------------------------------------------------------------------------
# Group 1: Structural — exemption list
# The exemption is a single if-statement that matches both "status" and
# "health-report".  Promote and sync must not appear on that line.
# ---------------------------------------------------------------------------

@test "bin/rite: promote is NOT in the RITE_LOG_AUTO=false exemption line" {
  local _line
  _line=$(grep '"status".*"health-report"' "$RITE_REPO_ROOT/bin/rite" | head -1 || true)
  [ -n "$_line" ]
  ! echo "$_line" | grep -q '"promote"'
}

@test "bin/rite: sync is NOT in the RITE_LOG_AUTO=false exemption line" {
  local _line
  _line=$(grep '"status".*"health-report"' "$RITE_REPO_ROOT/bin/rite" | head -1 || true)
  [ -n "$_line" ]
  ! echo "$_line" | grep -q '"sync"'
}

@test "bin/rite: status IS in the RITE_LOG_AUTO=false exemption line" {
  local _line
  _line=$(grep '"status".*"health-report"' "$RITE_REPO_ROOT/bin/rite" | head -1 || true)
  echo "$_line" | grep -q '"status"'
}

# ---------------------------------------------------------------------------
# Group 2: Structural — dispatch order
# The logging-setup block (FIFO tee) must appear before both dispatches.
# Use a unique text fragment from each landmark to get its line number.
# ---------------------------------------------------------------------------

@test "bin/rite: promote dispatch line appears after logging-setup line" {
  # Landmark: the FIFO tee that captures output to the log file.
  local _log_line _dispatch_line
  _log_line=$(_line_of 'exec > >(tee >(strip_ansi')
  # Promote dispatch: the source line that loads promote-branch.sh.
  _dispatch_line=$(_line_of 'source.*promote-branch.sh')
  [ -n "$_log_line" ]
  [ -n "$_dispatch_line" ]
  [ "$_dispatch_line" -gt "$_log_line" ]
}

@test "bin/rite: sync dispatch line appears after logging-setup line" {
  local _log_line _dispatch_line
  _log_line=$(_line_of 'exec > >(tee >(strip_ansi')
  # Sync dispatch: the source line that loads integration-sync.sh.
  _dispatch_line=$(_line_of 'source.*integration-sync.sh')
  [ -n "$_log_line" ]
  [ -n "$_dispatch_line" ]
  [ "$_dispatch_line" -gt "$_log_line" ]
}

# ---------------------------------------------------------------------------
# Group 3: Structural — slug derivation
# ---------------------------------------------------------------------------

@test "bin/rite: promote log slug uses PROMOTE_BRANCH variable" {
  grep -q 'LOG_SLUG=.*PROMOTE_BRANCH' "$RITE_REPO_ROOT/bin/rite"
}

@test "bin/rite: sync log slug defaults to 'all' for bare invocation" {
  # The slug arm uses ${SYNC_ARGS[*]:-all} so bare --sync → rite-sync-all-*.log
  grep -q 'LOG_SLUG=.*:-all' "$RITE_REPO_ROOT/bin/rite"
}

# ---------------------------------------------------------------------------
# Group 4: Behavioral — log file created for promote
# ---------------------------------------------------------------------------

@test "rite --promote <branch> creates rite-promote-<branch>-*.log" {
  local _log_dir="$RITE_TEST_TMPDIR/.rite/logs"

  # Command exits non-zero (nothing to promote — no ledger) but the log file
  # must already exist because it is written before the dispatch fires.
  _run_rite_logged --promote "test-branch"

  local _count
  _count=$(ls "$_log_dir"/rite-promote-test-branch-*.log 2>/dev/null | wc -l | tr -d ' ')
  [ "$_count" -ge 1 ]
}

@test "rite --promote <branch> log contains the standard header" {
  _run_rite_logged --promote "header-check"

  local _log_dir="$RITE_TEST_TMPDIR/.rite/logs"
  local _f
  _f=$(ls "$_log_dir"/rite-promote-header-check-*.log 2>/dev/null | head -1)
  [ -n "$_f" ]
  grep -q "=== Sharkrite Log ===" "$_f"
  # Post-tee assertions: these lines only reach the log file when the exec tee
  # is active. Removing the exec tee at bin/rite:969 leaves the header (written
  # via plain >) intact but drops all subsequent output — so these two greps
  # catch a disabled or broken tee.
  grep -q "Logging to:" "$_f"
  grep -q "Promoting 'header-check' to main" "$_f"
}

# ---------------------------------------------------------------------------
# Group 5: Behavioral — log file created for sync
# ---------------------------------------------------------------------------

@test "rite --sync <branch> creates rite-sync-<branch>-*.log" {
  local _log_dir="$RITE_TEST_TMPDIR/.rite/logs"

  _run_rite_logged --sync "test-branch"

  local _count
  _count=$(ls "$_log_dir"/rite-sync-test-branch-*.log 2>/dev/null | wc -l | tr -d ' ')
  [ "$_count" -ge 1 ]
}

@test "rite --sync (bare) creates rite-sync-all-*.log" {
  local _log_dir="$RITE_TEST_TMPDIR/.rite/logs"

  # Bare sweep over an empty project: no ledger dir, no lock files → exits 0.
  _run_rite_logged --sync

  local _count
  _count=$(ls "$_log_dir"/rite-sync-all-*.log 2>/dev/null | wc -l | tr -d ' ')
  [ "$_count" -ge 1 ]
}

@test "rite --sync <branch> log contains tee'd content" {
  _run_rite_logged --sync "tee-check"

  local _log_dir="$RITE_TEST_TMPDIR/.rite/logs"
  local _f
  _f=$(ls "$_log_dir"/rite-sync-tee-check-*.log 2>/dev/null | head -1)
  [ -n "$_f" ]
  # Post-tee assertions: these lines only reach the log file when the exec tee
  # is active. Removing the exec tee at bin/rite:969 leaves the header (written
  # via plain >) intact but drops all subsequent output — so these two greps
  # catch a disabled or broken tee.
  grep -q "Logging to:" "$_f"
  grep -q "Sync Integration Branch: tee-check" "$_f"
}

# ---------------------------------------------------------------------------
# Group 6: Behavioral — --no-log suppresses log creation
# ---------------------------------------------------------------------------

@test "rite --no-log --promote <branch> creates NO log file" {
  local _log_dir="$RITE_TEST_TMPDIR/.rite/logs"

  run env \
    -u RITE_LOG_FILE \
    -u RITE_LOG_AUTO \
    -u PR_NUMBER \
    -u ISSUE_NUMBER \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    RITE_LOCK_DIR="$RITE_TEST_TMPDIR/locks" \
    bash "$RITE_REPO_ROOT/bin/rite" --no-log --promote "no-log-branch" < /dev/null \
    2>&1 || true

  local _count
  _count=$(ls "$_log_dir"/rite-promote-*.log 2>/dev/null | wc -l | tr -d ' ')
  [ "$_count" -eq 0 ]
}
