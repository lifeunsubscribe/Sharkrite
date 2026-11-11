#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite-full-suite
# tests/regression/full-suite-scheduled-guards.bats
#
# Regression tests for the --scheduled flag guards (#1609, #1658).
#
# Tests verify:
#  1. Window guard: --scheduled outside 02:00-05:00 exits 0 without running.
#  2. Window guard: --scheduled inside 02:00-05:00 proceeds to run.
#  3. Busy guard: --scheduled with a live lock exits 0 without running.
#  4. Busy guard: backfill locks (no pid) and dead-pid locks do NOT block.
#  5. Manual invocations (no --scheduled) always run, regardless of hour/locks.
#  6. Skip is RECORDED: diag line and log entry are written on window skip.
#  7. Skip is RECORDED: diag line and log entry are written on busy skip.
#  8. FULL_SUITE_RUN diag is NOT emitted on a skip.
#  9. Deadline guard: --scheduled aborts when bats hangs past window deadline.
# 10. Deadline guard: aborted run leaves failure flag unchanged, no investigate.

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  export _FAKE_PROJECT="$RITE_TEST_TMPDIR/fake-project"
  mkdir -p "$_FAKE_PROJECT/.rite/logs" "$_FAKE_PROJECT/.rite/state" "$_FAKE_PROJECT/.rite/reports"

  export _FULL_SUITE_SCRIPT="$RITE_REPO_ROOT/bin/rite-full-suite"
  export _FAKE_LOCK_DIR="$RITE_TEST_TMPDIR/locks"
  mkdir -p "$_FAKE_LOCK_DIR"

  # Minimal Makefile so the repo-check passes
  cat > "$_FAKE_PROJECT/Makefile" << 'EOF'
.PHONY: check shellcheck lint
check:
	@exit 0
shellcheck:
	@exit 0
lint:
	@exit 0
EOF
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Shared helper: write lib stubs + stub make/bats that record invocations
# ---------------------------------------------------------------------------
_write_lib_stubs() {
  mkdir -p "$_FAKE_PROJECT/lib/utils"

  cat > "$_FAKE_PROJECT/lib/utils/config.sh" << 'STUB'
#!/bin/bash
# stub: config.sh
RITE_DATA_DIR="${RITE_DATA_DIR:-.rite}"
RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT:-$(pwd)}"
RITE_LIB_DIR="${RITE_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/.."}"
RITE_PROJECT_NAME="${RITE_PROJECT_NAME:-fake-project}"
# RITE_LOCK_DIR is passed in via env from the test; honour it if already set.
RITE_LOCK_DIR="${RITE_LOCK_DIR:-$RITE_PROJECT_ROOT/$RITE_DATA_DIR/locks}"
export RITE_DATA_DIR RITE_PROJECT_ROOT RITE_LIB_DIR RITE_PROJECT_NAME RITE_LOCK_DIR
STUB

  cat > "$_FAKE_PROJECT/lib/utils/colors.sh" << 'STUB'
#!/bin/bash
# stub: colors.sh
print_header()  { echo "=== $* ==="; }
print_info()    { echo "[INFO] $*"; }
print_step()    { echo "[STEP] $*"; }
print_success() { echo "[OK] $*"; }
print_warning() { echo "[WARN] $*"; }
print_error()   { echo "[ERROR] $*" >&2; }
strip_ansi()    { cat; }
STUB

  cat > "$_FAKE_PROJECT/lib/utils/logging.sh" << 'STUB'
#!/bin/bash
# stub: logging.sh
_RITE_LOGGING_LOADED=true
is_verbose() { [ "${RITE_VERBOSE:-false}" = "true" ]; }
_diag() {
  local msg="$1"
  local ts; ts=$(date '+%H:%M:%S')
  local line="[diag] $ts | $msg"
  if [ -n "${RITE_LOG_FILE:-}" ]; then
    echo "$line" >> "$RITE_LOG_FILE"
  else
    echo "$line" >&2
  fi
}
verbose_header()  { true; }
verbose_info()    { true; }
verbose_step()    { true; }
verbose_success() { true; }
verbose_warning() { true; }
STUB
}

_write_recording_tools() {
  mkdir -p "$_FAKE_PROJECT/bin" "$_FAKE_PROJECT/tests"
  local call_log="${1:-$RITE_TEST_TMPDIR/calls.log}"

  cat > "$_FAKE_PROJECT/bin/make" << EOF
#!/bin/bash
echo "make-called: \$*" >> "$call_log"
exit 0
EOF
  cat > "$_FAKE_PROJECT/bin/bats" << EOF
#!/bin/bash
echo "bats-called: \$*" >> "$call_log"
exit 0
EOF
  chmod +x "$_FAKE_PROJECT/bin/make" "$_FAKE_PROJECT/bin/bats"
}

# ---------------------------------------------------------------------------
# Shared runner: invoke rite-full-suite with fake env
# Extra env vars can be passed as "KEY=VALUE" arguments.
# ---------------------------------------------------------------------------
_run_full_suite() {
  local extra_env=()
  for _e in "$@"; do extra_env+=("$_e"); done

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    "${extra_env[@]}" \
    bash "$_FULL_SUITE_SCRIPT" "${_SUITE_FLAGS[@]+"${_SUITE_FLAGS[@]}"}"
}

# ---------------------------------------------------------------------------
# 1. Window guard: outside window → exits 0, nothing runs
# ---------------------------------------------------------------------------
@test "--scheduled outside window exits 0 without running make/bats" {
  _write_lib_stubs
  local call_log="$RITE_TEST_TMPDIR/calls.log"
  _write_recording_tools "$call_log"

  # Hour 9 is outside 02:00-05:00
  local fake_date_dir="$RITE_TEST_TMPDIR/fake-date-bin"
  mkdir -p "$fake_date_dir"
  printf '#!/bin/bash\nif [ "${1:-}" = "+%%H" ]; then echo "09"; else /bin/date "$@"; fi\n' \
    > "$fake_date_dir/date"
  chmod +x "$fake_date_dir/date"

  _SUITE_FLAGS=(--scheduled)
  run env \
    PATH="$fake_date_dir:$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    bash "$_FULL_SUITE_SCRIPT" --scheduled

  [ "$status" -eq 0 ]
  # make and bats must NOT have been called
  [ ! -f "$call_log" ] || ! grep -q "make-called\|bats-called" "$call_log"
}

# ---------------------------------------------------------------------------
# 2. Window guard: inside window → proceeds and runs make/bats
# ---------------------------------------------------------------------------
@test "--scheduled inside window (hour 03) proceeds to run" {
  _write_lib_stubs
  local call_log="$RITE_TEST_TMPDIR/calls.log"
  _write_recording_tools "$call_log"

  local fake_date_dir="$RITE_TEST_TMPDIR/fake-date-bin"
  mkdir -p "$fake_date_dir"
  # Hour 3 is inside 02:00-05:00
  printf '#!/bin/bash\nif [ "${1:-}" = "+%%H" ]; then echo "03"; else /bin/date "$@"; fi\n' \
    > "$fake_date_dir/date"
  chmod +x "$fake_date_dir/date"

  run env \
    PATH="$fake_date_dir:$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    bash "$_FULL_SUITE_SCRIPT" --scheduled

  [ "$status" -eq 0 ]
  # make and bats MUST have been called
  [ -f "$call_log" ]
  grep -q "make-called" "$call_log"
  grep -q "bats-called" "$call_log"
}

# ---------------------------------------------------------------------------
# 3. Skip is recorded (window guard): diag + log entry written, no FULL_SUITE_RUN
# ---------------------------------------------------------------------------
@test "--scheduled outside window records skip diag and log entry" {
  _write_lib_stubs
  _write_recording_tools

  local fake_date_dir="$RITE_TEST_TMPDIR/fake-date-bin"
  mkdir -p "$fake_date_dir"
  printf '#!/bin/bash\nif [ "${1:-}" = "+%%H" ]; then echo "10"; else /bin/date "$@"; fi\n' \
    > "$fake_date_dir/date"
  chmod +x "$fake_date_dir/date"

  run env \
    PATH="$fake_date_dir:$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    bash "$_FULL_SUITE_SCRIPT" --scheduled

  [ "$status" -eq 0 ]

  # Find the written log file
  local _log
  _log=$(find "$_FAKE_PROJECT/.rite/logs" -name "full-suite-*.log" | head -1 || true)
  [ -n "$_log" ]

  # Must contain the SKIPPED diag
  grep -q 'FULL_SUITE_SKIPPED' "$_log"
  grep -q 'reason=outside_window' "$_log"
  grep -q 'hour=10' "$_log"

  # Must contain the human-readable skip line
  grep -q 'SKIPPED' "$_log"

  # Must NOT contain a FULL_SUITE_RUN diag (no run happened)
  ! grep -q 'FULL_SUITE_RUN' "$_log"
}

# ---------------------------------------------------------------------------
# 4. Busy guard: live lock → exits 0 without running
# ---------------------------------------------------------------------------
@test "--scheduled with a live lock exits 0 without running make/bats" {
  _write_lib_stubs
  local call_log="$RITE_TEST_TMPDIR/calls.log"
  _write_recording_tools "$call_log"

  # Create a live issue lock using a background sleep as the "live process"
  local live_pid
  sleep 300 &
  live_pid=$!
  local lock_dir="$_FAKE_LOCK_DIR/issue-42.lock"
  mkdir -p "$lock_dir"
  echo "$live_pid" > "$lock_dir/pid"

  local fake_date_dir="$RITE_TEST_TMPDIR/fake-date-bin"
  mkdir -p "$fake_date_dir"
  # Inside window so only the busy guard fires
  printf '#!/bin/bash\nif [ "${1:-}" = "+%%H" ]; then echo "03"; else /bin/date "$@"; fi\n' \
    > "$fake_date_dir/date"
  chmod +x "$fake_date_dir/date"

  run env \
    PATH="$fake_date_dir:$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    bash "$_FULL_SUITE_SCRIPT" --scheduled

  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true

  [ "$status" -eq 0 ]
  [ ! -f "$call_log" ] || ! grep -q "make-called\|bats-called" "$call_log"
}

# ---------------------------------------------------------------------------
# 5. Busy guard: skip is recorded (batch_active)
# ---------------------------------------------------------------------------
@test "--scheduled with live lock records skip diag with reason=batch_active" {
  _write_lib_stubs
  _write_recording_tools

  local live_pid
  sleep 300 &
  live_pid=$!
  local lock_dir="$_FAKE_LOCK_DIR/batch.lock"
  mkdir -p "$lock_dir"
  echo "$live_pid" > "$lock_dir/pid"

  local fake_date_dir="$RITE_TEST_TMPDIR/fake-date-bin"
  mkdir -p "$fake_date_dir"
  printf '#!/bin/bash\nif [ "${1:-}" = "+%%H" ]; then echo "03"; else /bin/date "$@"; fi\n' \
    > "$fake_date_dir/date"
  chmod +x "$fake_date_dir/date"

  run env \
    PATH="$fake_date_dir:$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    bash "$_FULL_SUITE_SCRIPT" --scheduled

  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true

  [ "$status" -eq 0 ]

  local _log
  _log=$(find "$_FAKE_PROJECT/.rite/logs" -name "full-suite-*.log" | head -1 || true)
  [ -n "$_log" ]
  grep -q 'FULL_SUITE_SKIPPED' "$_log"
  grep -q 'reason=batch_active' "$_log"
  ! grep -q 'FULL_SUITE_RUN' "$_log"
}

# ---------------------------------------------------------------------------
# 6. Backfill locks (no pid file) do NOT trigger the busy guard
# ---------------------------------------------------------------------------
@test "--scheduled with backfill lock (no pid) proceeds to run" {
  _write_lib_stubs
  local call_log="$RITE_TEST_TMPDIR/calls.log"
  _write_recording_tools "$call_log"

  # Backfill lock: directory exists but has only a 'backfill' sentinel, no pid
  local lock_dir="$_FAKE_LOCK_DIR/issue-99.lock"
  mkdir -p "$lock_dir"
  echo "backfill" > "$lock_dir/backfill"
  # deliberately no pid file

  local fake_date_dir="$RITE_TEST_TMPDIR/fake-date-bin"
  mkdir -p "$fake_date_dir"
  printf '#!/bin/bash\nif [ "${1:-}" = "+%%H" ]; then echo "03"; else /bin/date "$@"; fi\n' \
    > "$fake_date_dir/date"
  chmod +x "$fake_date_dir/date"

  run env \
    PATH="$fake_date_dir:$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    bash "$_FULL_SUITE_SCRIPT" --scheduled

  [ "$status" -eq 0 ]
  [ -f "$call_log" ]
  grep -q "make-called" "$call_log"
}

# ---------------------------------------------------------------------------
# 7. Dead-pid locks do NOT trigger the busy guard
# ---------------------------------------------------------------------------
@test "--scheduled with dead-pid lock proceeds to run" {
  _write_lib_stubs
  local call_log="$RITE_TEST_TMPDIR/calls.log"
  _write_recording_tools "$call_log"

  # Use PID 1 as "our" dead pid — write a pid that cannot answer kill -0 for us
  # (we don't own PID 1). Actually on macOS kill -0 1 may succeed (launchd).
  # Instead use a PID we know is dead: start a process, let it exit, capture PID.
  local dead_pid
  (exit 0) &
  dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  # dead_pid is now reaped and cannot answer kill -0

  local lock_dir="$_FAKE_LOCK_DIR/issue-7.lock"
  mkdir -p "$lock_dir"
  echo "$dead_pid" > "$lock_dir/pid"

  local fake_date_dir="$RITE_TEST_TMPDIR/fake-date-bin"
  mkdir -p "$fake_date_dir"
  printf '#!/bin/bash\nif [ "${1:-}" = "+%%H" ]; then echo "03"; else /bin/date "$@"; fi\n' \
    > "$fake_date_dir/date"
  chmod +x "$fake_date_dir/date"

  run env \
    PATH="$fake_date_dir:$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    bash "$_FULL_SUITE_SCRIPT" --scheduled

  [ "$status" -eq 0 ]
  [ -f "$call_log" ]
  grep -q "make-called" "$call_log"
}

# ---------------------------------------------------------------------------
# 8. Manual run (no --scheduled): always runs regardless of hour
# ---------------------------------------------------------------------------
@test "manual run without --scheduled is unaffected by outside-window hour" {
  _write_lib_stubs
  local call_log="$RITE_TEST_TMPDIR/calls.log"
  _write_recording_tools "$call_log"

  local fake_date_dir="$RITE_TEST_TMPDIR/fake-date-bin"
  mkdir -p "$fake_date_dir"
  # Hour 14: deep working hours, would be blocked if --scheduled
  printf '#!/bin/bash\nif [ "${1:-}" = "+%%H" ]; then echo "14"; else /bin/date "$@"; fi\n' \
    > "$fake_date_dir/date"
  chmod +x "$fake_date_dir/date"

  run env \
    PATH="$fake_date_dir:$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    bash "$_FULL_SUITE_SCRIPT"
  # No --scheduled flag

  [ "$status" -eq 0 ]
  [ -f "$call_log" ]
  grep -q "make-called" "$call_log"
  grep -q "bats-called" "$call_log"
}

# ---------------------------------------------------------------------------
# 9. Manual run with a live lock: unaffected (always runs)
# ---------------------------------------------------------------------------
@test "manual run without --scheduled is unaffected by live lock" {
  _write_lib_stubs
  local call_log="$RITE_TEST_TMPDIR/calls.log"
  _write_recording_tools "$call_log"

  local live_pid
  sleep 300 &
  live_pid=$!
  local lock_dir="$_FAKE_LOCK_DIR/issue-1.lock"
  mkdir -p "$lock_dir"
  echo "$live_pid" > "$lock_dir/pid"

  local fake_date_dir="$RITE_TEST_TMPDIR/fake-date-bin"
  mkdir -p "$fake_date_dir"
  printf '#!/bin/bash\nif [ "${1:-}" = "+%%H" ]; then echo "03"; else /bin/date "$@"; fi\n' \
    > "$fake_date_dir/date"
  chmod +x "$fake_date_dir/date"

  run env \
    PATH="$fake_date_dir:$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    bash "$_FULL_SUITE_SCRIPT"

  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true

  [ "$status" -eq 0 ]
  [ -f "$call_log" ]
  grep -q "make-called" "$call_log"
}

# ---------------------------------------------------------------------------
# 10. Window guard: boundary — hour 02 (inclusive) is inside window
# ---------------------------------------------------------------------------
@test "--scheduled at hour 02 (window start, inclusive) proceeds to run" {
  _write_lib_stubs
  local call_log="$RITE_TEST_TMPDIR/calls.log"
  _write_recording_tools "$call_log"

  local fake_date_dir="$RITE_TEST_TMPDIR/fake-date-bin"
  mkdir -p "$fake_date_dir"
  printf '#!/bin/bash\nif [ "${1:-}" = "+%%H" ]; then echo "02"; else /bin/date "$@"; fi\n' \
    > "$fake_date_dir/date"
  chmod +x "$fake_date_dir/date"

  run env \
    PATH="$fake_date_dir:$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    bash "$_FULL_SUITE_SCRIPT" --scheduled

  [ "$status" -eq 0 ]
  [ -f "$call_log" ]
  grep -q "make-called" "$call_log"
}

# ---------------------------------------------------------------------------
# 11. Window guard: boundary — hour 05 (exclusive) is outside window
# ---------------------------------------------------------------------------
@test "--scheduled at hour 05 (window end, exclusive) is skipped" {
  _write_lib_stubs
  local call_log="$RITE_TEST_TMPDIR/calls.log"
  _write_recording_tools "$call_log"

  local fake_date_dir="$RITE_TEST_TMPDIR/fake-date-bin"
  mkdir -p "$fake_date_dir"
  printf '#!/bin/bash\nif [ "${1:-}" = "+%%H" ]; then echo "05"; else /bin/date "$@"; fi\n' \
    > "$fake_date_dir/date"
  chmod +x "$fake_date_dir/date"

  run env \
    PATH="$fake_date_dir:$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    bash "$_FULL_SUITE_SCRIPT" --scheduled

  [ "$status" -eq 0 ]
  [ ! -f "$call_log" ] || ! grep -q "make-called\|bats-called" "$call_log"
}

# ---------------------------------------------------------------------------
# 12. Deadline guard: --scheduled aborts when bats hangs past window deadline
# ---------------------------------------------------------------------------
@test "--scheduled deadline guard: aborts when bats hangs, emits outcome=aborted diag" {
  # Requires a real timeout command to exercise the watchdog.
  local _real_timeout_cmd=""
  if command -v gtimeout >/dev/null 2>&1; then
    _real_timeout_cmd="$(command -v gtimeout)"
  elif command -v timeout >/dev/null 2>&1; then
    _real_timeout_cmd="$(command -v timeout)"
  else
    skip "gtimeout or timeout not available — deadline guard requires a timeout command"
  fi

  _write_lib_stubs

  local fake_bin="$RITE_TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"

  # make stub: succeeds immediately
  cat > "$fake_bin/make" << 'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$fake_bin/make"

  # bats stub: sleeps long enough to be killed by the 2 s deadline
  cat > "$fake_bin/bats" << 'STUB'
#!/bin/bash
sleep 60
exit 0
STUB
  chmod +x "$fake_bin/bats"

  # Provide gtimeout in the fake PATH (the script checks for gtimeout first).
  cp "$_real_timeout_cmd" "$fake_bin/gtimeout"
  chmod +x "$fake_bin/gtimeout"

  # git stub: returns a fake branch name (needed for log header)
  cat > "$fake_bin/git" << 'STUB'
#!/bin/bash
if [ "${1:-}" = "-C" ] && [ "${3:-}" = "rev-parse" ]; then
  echo "test-branch"
  exit 0
fi
exec /usr/bin/git "$@"
STUB
  chmod +x "$fake_bin/git"

  # Date stub: returns hour=04, min=59, sec=59 so natural deadline = 1 s.
  # With RITE_FULL_SUITE_MIN_DEADLINE=2, floor=2 s kicks in and bats is killed
  # after 2 s (gtimeout exits 124).
  cat > "$fake_bin/date" << 'STUB'
#!/bin/bash
case "${1:-}" in
  '+%H') echo "04" ;;
  '+%M') echo "59" ;;
  '+%S') echo "59" ;;
  '+%Y-%m-%d') echo "2026-01-01" ;;
  '+%Y%m%d')   echo "20260101" ;;
  '+%H:%M:%S') echo "04:59:59" ;;
  *) exec /bin/date "$@" ;;
esac
STUB
  chmod +x "$fake_bin/date"

  mkdir -p "$_FAKE_PROJECT/tests"

  run env \
    PATH="$fake_bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    RITE_FULL_SUITE_MIN_DEADLINE=2 \
    bash "$_FULL_SUITE_SCRIPT" --scheduled

  [ "$status" -eq 0 ]

  # Must have written the diag and abort header to the log
  local _log
  _log=$(find "$_FAKE_PROJECT/.rite/logs" -name "full-suite-*.log" | head -1 || true)
  [ -n "$_log" ]
  grep -q 'FULL_SUITE_RUN' "$_log"
  grep -q 'outcome=aborted' "$_log"
  grep -q 'reason=window_end' "$_log"
  grep -q 'Scheduled run ABORTED at window end' "$_log"

  # Must NOT contain outcome=passed or outcome=failed (not a verdict)
  ! grep -q 'outcome=passed\|outcome=failed' "$_log"
}

# ---------------------------------------------------------------------------
# 13. Deadline guard: aborted run does not create or delete failure flag
# ---------------------------------------------------------------------------
@test "--scheduled deadline guard: aborted run leaves failure flag unchanged" {
  local _real_timeout_cmd=""
  if command -v gtimeout >/dev/null 2>&1; then
    _real_timeout_cmd="$(command -v gtimeout)"
  elif command -v timeout >/dev/null 2>&1; then
    _real_timeout_cmd="$(command -v timeout)"
  else
    skip "gtimeout or timeout not available — deadline guard requires a timeout command"
  fi

  _write_lib_stubs

  local fake_bin="$RITE_TEST_TMPDIR/fake-bin2"
  mkdir -p "$fake_bin"

  cat > "$fake_bin/make" << 'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$fake_bin/make"

  cat > "$fake_bin/bats" << 'STUB'
#!/bin/bash
sleep 60
exit 0
STUB
  chmod +x "$fake_bin/bats"

  cp "$_real_timeout_cmd" "$fake_bin/gtimeout"
  chmod +x "$fake_bin/gtimeout"

  cat > "$fake_bin/git" << 'STUB'
#!/bin/bash
if [ "${1:-}" = "-C" ] && [ "${3:-}" = "rev-parse" ]; then
  echo "test-branch"
  exit 0
fi
exec /usr/bin/git "$@"
STUB
  chmod +x "$fake_bin/git"

  cat > "$fake_bin/date" << 'STUB'
#!/bin/bash
case "${1:-}" in
  '+%H') echo "04" ;;
  '+%M') echo "59" ;;
  '+%S') echo "59" ;;
  '+%Y-%m-%d') echo "2026-01-01" ;;
  '+%Y%m%d')   echo "20260101" ;;
  '+%H:%M:%S') echo "04:59:59" ;;
  *) exec /bin/date "$@" ;;
esac
STUB
  chmod +x "$fake_bin/date"

  mkdir -p "$_FAKE_PROJECT/tests"

  local _flag="$_FAKE_PROJECT/.rite/state/full-suite-failure.flag"

  # Case A: flag does not exist before run — must still not exist after abort
  [ ! -f "$_flag" ]
  run env \
    PATH="$fake_bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    RITE_FULL_SUITE_MIN_DEADLINE=2 \
    bash "$_FULL_SUITE_SCRIPT" --scheduled
  [ "$status" -eq 0 ]
  [ ! -f "$_flag" ]

  # Case B: flag exists before run (prior failure) — must still exist after abort
  echo "outcome=failed" > "$_flag"
  run env \
    PATH="$fake_bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    RITE_FULL_SUITE_MIN_DEADLINE=2 \
    bash "$_FULL_SUITE_SCRIPT" --scheduled
  [ "$status" -eq 0 ]
  [ -f "$_flag" ]
  grep -q 'outcome=failed' "$_flag"

  # Must not have called investigate (no "Investigating failures" in output)
  ! echo "$output" | grep -q "Investigating failures"
}

# ---------------------------------------------------------------------------
# 14. Investigate deadline guard: serial reruns aborted near window end
# ---------------------------------------------------------------------------
@test "--investigate --scheduled: serial rerun loop aborts near window end, emits FULL_SUITE_INVESTIGATE_ABORTED diag" {
  _write_lib_stubs

  local fake_bin="$RITE_TEST_TMPDIR/fake-bin-investdeadline"
  mkdir -p "$fake_bin"
  local call_count_file="$RITE_TEST_TMPDIR/bats-inv-call-count"

  # make: passes
  cat > "$fake_bin/make" << 'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$fake_bin/make"

  # bats: first call (main run) fails with one test; subsequent calls (serial rerun)
  # should never be reached because the deadline guard fires first.
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: call_count_file path must expand
  cat > "$fake_bin/bats" << STUB
#!/bin/bash
_c=0; [ -f "${call_count_file}" ] && _c=\$(cat "${call_count_file}")
_c=\$(( _c + 1 ))
printf '%s' "\$_c" > "${call_count_file}"
if [ "\$_c" -eq 1 ]; then
  printf '1..1\nnot ok 1 fake test\n'
  exit 1
fi
# Should not reach here — serial rerun blocked by deadline guard
printf '1..1\nok 1 fake test\n'
exit 0
STUB
  chmod +x "$fake_bin/bats"

  cat > "$fake_bin/git" << 'STUB'
#!/bin/bash
if [ "${1:-}" = "-C" ] && [ "${3:-}" = "rev-parse" ]; then echo "test-branch"; exit 0; fi
exec /usr/bin/git "$@"
STUB
  chmod +x "$fake_bin/git"

  # H=04, M=59, S=00 → 60s remaining until 05:00; 60 ≤ BATS_TEST_TIMEOUT(300) → abort
  cat > "$fake_bin/date" << 'STUB'
#!/bin/bash
case "${1:-}" in
  '+%H') echo "04" ;;
  '+%M') echo "59" ;;
  '+%S') echo "00" ;;
  '+%Y-%m-%d') echo "2026-01-01" ;;
  '+%Y%m%d')   echo "20260101" ;;
  '+%H:%M:%S') echo "04:59:00" ;;
  *) exec /bin/date "$@" ;;
esac
STUB
  chmod +x "$fake_bin/date"

  # Fake .bats file so grep finds "fake test" for the serial rerun mapping
  mkdir -p "$_FAKE_PROJECT/tests"
  printf '#!/usr/bin/env bats\n@test "fake test" { true; }\n' > "$_FAKE_PROJECT/tests/fake.bats"

  run env \
    PATH="$fake_bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    RITE_FULL_SUITE_MIN_DEADLINE=2 \
    BATS_TEST_TIMEOUT=300 \
    bash "$_FULL_SUITE_SCRIPT" --investigate --scheduled

  # Overall outcome is 1 (bats failed — investigate does not change exit code)
  [ "$status" -eq 1 ]

  # Bats should have been called exactly once (main run); serial rerun never started
  [ -f "$call_count_file" ]
  [ "$(cat "$call_count_file")" -eq 1 ]

  # FULL_SUITE_INVESTIGATE_ABORTED diag must be in the log
  local _log
  _log=$(find "$_FAKE_PROJECT/.rite/logs" -name "full-suite-*.log" | head -1 || true)
  [ -n "$_log" ]
  grep -q 'FULL_SUITE_INVESTIGATE_ABORTED' "$_log"
  grep -q 'reason=window_end' "$_log"
  grep -q 'Investigate serial re-run ABORTED' "$_log"
}

# ---------------------------------------------------------------------------
# 15. Investigate deadline guard: manual runs are unaffected
# ---------------------------------------------------------------------------
@test "--investigate without --scheduled: serial reruns run regardless of hour" {
  _write_lib_stubs

  local fake_bin="$RITE_TEST_TMPDIR/fake-bin-investmanual"
  mkdir -p "$fake_bin"
  local call_count_file="$RITE_TEST_TMPDIR/bats-man-call-count"

  cat > "$fake_bin/make" << 'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$fake_bin/make"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: call_count_file path must expand
  cat > "$fake_bin/bats" << STUB
#!/bin/bash
_c=0; [ -f "${call_count_file}" ] && _c=\$(cat "${call_count_file}")
_c=\$(( _c + 1 ))
printf '%s' "\$_c" > "${call_count_file}"
if [ "\$_c" -eq 1 ]; then
  printf '1..1\nnot ok 1 fake test\n'
  exit 1
fi
# Serial rerun: should be called (manual run ignores deadline)
printf '1..1\nok 1 fake test\n'
exit 0
STUB
  chmod +x "$fake_bin/bats"

  cat > "$fake_bin/git" << 'STUB'
#!/bin/bash
if [ "${1:-}" = "-C" ] && [ "${3:-}" = "rev-parse" ]; then echo "test-branch"; exit 0; fi
exec /usr/bin/git "$@"
STUB
  chmod +x "$fake_bin/git"

  # Date returns H=04 M=59 — would abort in --scheduled mode
  cat > "$fake_bin/date" << 'STUB'
#!/bin/bash
case "${1:-}" in
  '+%H') echo "04" ;;
  '+%M') echo "59" ;;
  '+%S') echo "00" ;;
  '+%Y-%m-%d') echo "2026-01-01" ;;
  '+%Y%m%d')   echo "20260101" ;;
  '+%H:%M:%S') echo "04:59:00" ;;
  *) exec /bin/date "$@" ;;
esac
STUB
  chmod +x "$fake_bin/date"

  mkdir -p "$_FAKE_PROJECT/tests"
  printf '#!/usr/bin/env bats\n@test "fake test" { true; }\n' > "$_FAKE_PROJECT/tests/fake.bats"

  run env \
    PATH="$fake_bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOCK_DIR="$_FAKE_LOCK_DIR" \
    BATS_TEST_TIMEOUT=300 \
    bash "$_FULL_SUITE_SCRIPT" --investigate
  # Note: no --scheduled flag

  # Overall outcome is 1 (bats failed)
  [ "$status" -eq 1 ]

  # Bats must have been called more than once (serial rerun proceeded)
  [ -f "$call_count_file" ]
  [ "$(cat "$call_count_file")" -gt 1 ]

  # FULL_SUITE_INVESTIGATE_ABORTED must NOT appear (manual run, no deadline check)
  local _log
  _log=$(find "$_FAKE_PROJECT/.rite/logs" -name "full-suite-*.log" | head -1 || true)
  [ -n "$_log" ]
  ! grep -q 'FULL_SUITE_INVESTIGATE_ABORTED' "$_log"
}
