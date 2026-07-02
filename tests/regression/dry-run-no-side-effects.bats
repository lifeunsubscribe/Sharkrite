#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite, lib/utils/config.sh, lib/core/batch-process-issues.sh, lib/core/workflow-runner.sh
# tests/regression/dry-run-no-side-effects.bats
#
# Regression tests for --dry-run fail-closed plan-and-exit.
#
# Bug (born dead in the initial commit): --dry-run only exported
# RITE_DRY_RUN=true; the parser case was a bare `shift` and no dispatch path
# ever consulted the variable. The sole runtime consumer was config.sh's
# mkdir skip — so `rite --dry-run N` ran the FULL workflow for real while
# starving it of its own state directories.
#
# Fix (two layers):
#   1. bin/rite: dry-run choke point immediately after the arg-parse loop,
#      BEFORE the logging block (log creation + rotation that deletes old
#      logs) and before the six early-dispatch modes. Prints the dispatch
#      plan from the tuple (MODE, ARGS, BATCH_FILTER_ARGS, PR_INPUT) via the
#      pure resolve_dispatch_plan(), exits 0. Unrecognized tuple → refuse,
#      exit 1. No target → exit 1.
#   2. batch-process-issues.sh and workflow-runner.sh refuse at EXECUTION
#      entry (never at source time) when RITE_DRY_RUN=true.

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  # Minimal fake project so config.sh finds RITE_PROJECT_ROOT without git.
  export _FAKE_PROJECT="$RITE_TEST_TMPDIR/fake-project"
  mkdir -p "$_FAKE_PROJECT/.rite/logs"

  # Recording stubs for external commands. Any *.calls file after a dry-run
  # means the choke point leaked execution.
  export _FAKE_BIN="$RITE_TEST_TMPDIR/fake-bin"
  mkdir -p "$_FAKE_BIN"
  _stub_command "gh" 0 ""
  _stub_command "claude" 0 ""

  # Fake install tree: bin/rite is COPIED (not symlinked) so its own
  # BASH_SOURCE resolution binds RITE_LIB_DIR to the fake lib tree, where
  # every dispatch target is a recording stub.
  export _FAKE_INSTALL="$RITE_TEST_TMPDIR/fake-install"
  mkdir -p "$_FAKE_INSTALL/bin"
  cp "$RITE_REPO_ROOT/bin/rite" "$_FAKE_INSTALL/bin/rite"
  chmod +x "$_FAKE_INSTALL/bin/rite"
  cp -R "$RITE_REPO_ROOT/lib" "$_FAKE_INSTALL/lib"
  local _target
  for _target in batch-process-issues workflow-runner claude-workflow create-pr undo-workflow plan-issues; do
    cat > "$_FAKE_INSTALL/lib/core/${_target}.sh" << DISPATCHSTUB
#!/usr/bin/env bash
echo "DISPATCH_STUB_CALLED:${_target}" >> "$_FAKE_BIN/${_target}.calls"
exit 0
DISPATCHSTUB
    chmod +x "$_FAKE_INSTALL/lib/core/${_target}.sh"
  done
  for _target in rite-health-report rite-full-suite; do
    cat > "$_FAKE_INSTALL/bin/${_target}" << BINSTUB
#!/usr/bin/env bash
echo "DISPATCH_STUB_CALLED:${_target}" >> "$_FAKE_BIN/${_target}.calls"
exit 0
BINSTUB
    chmod +x "$_FAKE_INSTALL/bin/${_target}"
  done
}

teardown() {
  teardown_test_tmpdir
}

# _stub_command NAME EXIT_CODE [OUTPUT]
#   Writes a stub script to $_FAKE_BIN/<NAME> that prints OUTPUT (if given)
#   and exits EXIT_CODE. Records invocations to $_FAKE_BIN/<NAME>.calls.
_stub_command() {
  local _name="$1" _exit="${2:-0}" _output="${3:-}"
  local _script="$_FAKE_BIN/$_name"
  cat > "$_script" << STUBEOF
#!/bin/bash
echo "STUB_CALLED:$_name" >> "$_FAKE_BIN/${_name}.calls"
${_output:+echo "$_output"}
exit $_exit
STUBEOF
  chmod +x "$_script"
}

# _run_rite ARGS...
#   Runs the copied bin/rite against the stub-instrumented fake install.
_run_rite() {
  run env -u RITE_LOG_FILE -u RITE_DRY_RUN -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    "$_FAKE_INSTALL/bin/rite" "$@" < /dev/null
}

# Fails (with a listing) if any recording stub was invoked.
_assert_no_dispatch_calls() {
  local _calls
  _calls=$(ls "$_FAKE_BIN"/*.calls 2>/dev/null || true)
  if [ -n "$_calls" ]; then
    echo "Unexpected dispatch/stub calls:" >&2
    echo "$_calls" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Single-issue tuple: plan-and-exit 0, zero execution
# ---------------------------------------------------------------------------
@test "rite --dry-run 42 prints single-issue plan, exits 0, dispatches nothing" {
  _run_rite --dry-run 42

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Dry Run"
  echo "$output" | grep -q "workflow-runner.sh 42 --auto"
  echo "$output" | grep -q "nothing was executed"
  _assert_no_dispatch_calls
}

# ---------------------------------------------------------------------------
# Logging side effects: no log created, no rotation of pre-seeded logs
# (the choke point sits BEFORE the logging block that creates the log file
# and rotates — i.e. DELETES — logs beyond the 20 newest)
# ---------------------------------------------------------------------------
@test "dry-run creates no log file and pre-seeded old logs survive rotation" {
  local _i
  for _i in $(seq 1 25); do
    echo "old log $_i" > "$_FAKE_PROJECT/.rite/logs/rite-seed${_i}-20260101-000000.log"
  done

  _run_rite --dry-run 42

  [ "$status" -eq 0 ]
  # All 25 seeded logs must survive (rotation would have deleted 5+),
  # and no new log may appear (creation would make it 26).
  local _log_count
  _log_count=$(ls -1 "$_FAKE_PROJECT/.rite/logs"/rite-*.log 2>/dev/null | wc -l | tr -d ' ')
  [ "$_log_count" -eq 25 ]
  ! echo "$output" | grep -q "Logging to:"
}

# ---------------------------------------------------------------------------
# Label-batch tuple (MODE stays "full" here — proves tuple-based planning)
# ---------------------------------------------------------------------------
@test "rite --label tech-debt --dry-run plans the batch filter, dispatches nothing" {
  _run_rite --label tech-debt --dry-run

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "batch-process-issues.sh --label tech-debt --auto"
  [ ! -f "$_FAKE_BIN/batch-process-issues.calls" ]
  _assert_no_dispatch_calls
}

# ---------------------------------------------------------------------------
# Multi-issue batch tuple (the live-incident path: rite N1 N2 ... --dry-run)
# ---------------------------------------------------------------------------
@test "rite --dry-run with multiple issues plans batch-process-issues, dispatches nothing" {
  _run_rite --dry-run 490 489 467

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "batch-process-issues.sh 490 489 467 --auto"
  _assert_no_dispatch_calls
}

# ---------------------------------------------------------------------------
# Flag-order parity
# ---------------------------------------------------------------------------
@test "rite 42 --dry-run and rite --dry-run 42 produce identical plan and exit code" {
  _run_rite 42 --dry-run
  local _first_status="$status"
  local _first_output="$output"

  _run_rite --dry-run 42

  [ "$_first_status" -eq "$status" ]
  [ "$_first_output" = "$output" ]
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Env-injected RITE_DRY_RUN (no flag) — previously ran everything for real
# ---------------------------------------------------------------------------
@test "env-injected RITE_DRY_RUN=true (no --dry-run flag) also plans-and-exits" {
  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DRY_RUN=true \
    "$_FAKE_INSTALL/bin/rite" 42 < /dev/null

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "workflow-runner.sh 42 --auto"
  _assert_no_dispatch_calls
}

# ---------------------------------------------------------------------------
# The six early-dispatch modes (dispatch BEFORE the old proposed choke site)
# ---------------------------------------------------------------------------
@test "all six early-dispatch modes plan-and-exit under dry-run with zero execution" {
  local _mode_flag
  for _mode_flag in --health-report --full-suite --refresh-encountered-issues --tags --backfill-locks --reset-approval; do
    _run_rite "$_mode_flag" --dry-run
    if [ "$status" -ne 0 ]; then
      echo "mode $_mode_flag exited $status:" >&2
      echo "$output" >&2
      return 1
    fi
    echo "$output" | grep -q "Dry Run" || {
      echo "mode $_mode_flag printed no plan: $output" >&2
      return 1
    }
    _assert_no_dispatch_calls || {
      echo "mode $_mode_flag leaked execution" >&2
      return 1
    }
  done
}

@test "rite --health-report --dry-run names the health-report target without spawning it" {
  _run_rite --health-report --dry-run

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "rite-health-report"
  [ ! -f "$_FAKE_BIN/rite-health-report.calls" ]
}

@test "rite --init --dry-run plans without creating .rite/config" {
  _run_rite --init --dry-run

  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "initialize"
  [ ! -f "$_FAKE_PROJECT/.rite/config" ]
  _assert_no_dispatch_calls
}

# ---------------------------------------------------------------------------
# --pr tuple: intent only, zero network
# ---------------------------------------------------------------------------
@test "rite --dry-run --pr 72 prints resolution intent without calling gh" {
  _run_rite --dry-run --pr 72

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "resolve PR #72"
  [ ! -f "$_FAKE_BIN/gh.calls" ]
  _assert_no_dispatch_calls
}

# ---------------------------------------------------------------------------
# Fail-closed: no target / unrecognized tuple
# ---------------------------------------------------------------------------
@test "rite --dry-run with no target exits 1 with 'no target specified'" {
  _run_rite --dry-run

  [ "$status" -eq 1 ]
  echo "$output" | grep -q "no target specified"
  _assert_no_dispatch_calls
}

@test "resolve_dispatch_plan refuses an impossible tuple (fail-closed default branch)" {
  # Extract the pure function straight from bin/rite via its markers — driving
  # the default branch through the CLI would require fabricating a MODE the
  # parser cannot produce.
  eval "$(sed -n '/^# --- resolve_dispatch_plan (pure)/,/^# --- end resolve_dispatch_plan/p' "$RITE_REPO_ROOT/bin/rite")"
  declare -f resolve_dispatch_plan >/dev/null

  # Impossible mode → 1 (refuse)
  run resolve_dispatch_plan "no-such-mode" "" ""
  [ "$status" -eq 1 ]

  # No target → 2 (distinct sentinel, surfaced as exit 1 with its own message)
  run resolve_dispatch_plan "full" "" ""
  [ "$status" -eq 2 ]

  # Ambiguous tuple (undo with two issue args) → 1 (refuse)
  run resolve_dispatch_plan "undo" "" "" 1 2
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Layer 2: batch-process-issues.sh refuses at execution entry
# ---------------------------------------------------------------------------
@test "layer 2: batch-process-issues.sh refuses under RITE_DRY_RUN=true with zero gh calls" {
  run env -u RITE_LOG_FILE \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_DRY_RUN=true \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    "$RITE_REPO_ROOT/lib/core/batch-process-issues.sh" 42 < /dev/null

  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "dry-run"
  echo "$output" | grep -qi "refusing"
  [ ! -f "$_FAKE_BIN/gh.calls" ]
}

@test "layer 2: batch-process-issues.sh double-source with guard preset still exits 0 (re-source safety)" {
  # RITE_DRY_RUN deliberately unset: the refusal must be execution-entry only,
  # never source-time (tests/regression/lib-resource-safety.bats contract).
  run bash -c "
    set -euo pipefail
    unset RITE_DRY_RUN
    export _RITE_BATCH_PROCESS_LOADED=true
    source '${RITE_REPO_ROOT}/lib/core/batch-process-issues.sh' 2>/dev/null
    source '${RITE_REPO_ROOT}/lib/core/batch-process-issues.sh' 2>/dev/null
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "layer 2: sourcing batch-process-issues.sh with RITE_DRY_RUN=true does not exit at source time" {
  # The refusal is gated on direct execution (BASH_SOURCE = \$0); a sourcing
  # shell with the re-source guard preset must sail past it even in dry-run.
  run bash -c "
    set -euo pipefail
    export RITE_DRY_RUN=true
    export _RITE_BATCH_PROCESS_LOADED=true
    source '${RITE_REPO_ROOT}/lib/core/batch-process-issues.sh' 2>/dev/null
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

# ---------------------------------------------------------------------------
# Layer 2: workflow-runner.sh refuses at run_workflow() entry
# ---------------------------------------------------------------------------
@test "layer 2: run_workflow refuses under RITE_DRY_RUN=true before any gh call" {
  cat > "$RITE_TEST_TMPDIR/harness.sh" << 'HARNESS'
#!/usr/bin/env bash
set -uo pipefail
export RITE_DRY_RUN=true
export RITE_PROJECT_ROOT="$1"
export RITE_LIB_DIR="$2"
source "$RITE_LIB_DIR/core/workflow-runner.sh" 2>/dev/null || true
declare -f run_workflow >/dev/null || { echo "NO_RUN_WORKFLOW"; exit 97; }
_exit=0
( run_workflow 42 ) || _exit=$?
echo "RW_EXIT=$_exit"
HARNESS
  chmod +x "$RITE_TEST_TMPDIR/harness.sh"

  run env PATH="$_FAKE_BIN:$PATH" \
    bash "$RITE_TEST_TMPDIR/harness.sh" "$_FAKE_PROJECT" "$RITE_REPO_ROOT/lib"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "RW_EXIT=1"
  echo "$output" | grep -qi "refusing"
  [ ! -f "$_FAKE_BIN/gh.calls" ]
}
