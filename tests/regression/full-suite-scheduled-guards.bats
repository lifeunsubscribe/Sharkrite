#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite-full-suite
# tests/regression/full-suite-scheduled-guards.bats
#
# Regression tests for the --scheduled flag guards (#1609).
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
