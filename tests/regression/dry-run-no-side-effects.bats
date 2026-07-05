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
  # Extract both pure routing functions from bin/rite via their markers.
  # resolve_dispatch_plan now delegates to resolve_dispatch_key, so both must
  # be loaded before resolve_dispatch_plan can be exercised in isolation.
  eval "$(sed -n '/^# --- resolve_dispatch_key (pure)/,/^# --- end resolve_dispatch_key/p' "$RITE_REPO_ROOT/bin/rite")"
  eval "$(sed -n '/^# --- resolve_dispatch_plan (pure)/,/^# --- end resolve_dispatch_plan/p' "$RITE_REPO_ROOT/bin/rite")"
  declare -f resolve_dispatch_key >/dev/null
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
# resolve_dispatch_key unit tests — covers all recognized tuple keys
# ---------------------------------------------------------------------------
@test "resolve_dispatch_key returns correct keys for all recognized tuples" {
  # Extract both pure routing functions from bin/rite via their markers.
  eval "$(sed -n '/^# --- resolve_dispatch_key (pure)/,/^# --- end resolve_dispatch_key/p' "$RITE_REPO_ROOT/bin/rite")"
  eval "$(sed -n '/^# --- resolve_dispatch_plan (pure)/,/^# --- end resolve_dispatch_plan/p' "$RITE_REPO_ROOT/bin/rite")"
  set +u; set +o pipefail

  run resolve_dispatch_key "health-report" "" ""
  [ "$status" -eq 0 ]; [ "$output" = "health-report" ]

  run resolve_dispatch_key "health-report" "" "" "--latest"
  [ "$status" -eq 0 ]; [ "$output" = "health-report-latest" ]

  run resolve_dispatch_key "full-suite" "" ""
  [ "$status" -eq 0 ]; [ "$output" = "full-suite" ]

  run resolve_dispatch_key "tags" "" ""
  [ "$status" -eq 0 ]; [ "$output" = "tags" ]

  run resolve_dispatch_key "backfill-locks" "" ""
  [ "$status" -eq 0 ]; [ "$output" = "backfill-locks" ]

  run resolve_dispatch_key "init" "" ""
  [ "$status" -eq 0 ]; [ "$output" = "init" ]

  run resolve_dispatch_key "plan" "" ""
  [ "$status" -eq 0 ]; [ "$output" = "plan" ]

  run resolve_dispatch_key "status" "" ""
  [ "$status" -eq 0 ]; [ "$output" = "status-repo-wide" ]

  run resolve_dispatch_key "full" "--label tech-debt" ""
  [ "$status" -eq 0 ]; [ "$output" = "batch-filter" ]

  run resolve_dispatch_key "full" "" "72"
  [ "$status" -eq 0 ]; [ "$output" = "pr-resolve" ]

  run resolve_dispatch_key "full" "" "" "42"
  [ "$status" -eq 0 ]; [ "$output" = "single-issue" ]

  run resolve_dispatch_key "full" "" "" "some description"
  [ "$status" -eq 0 ]; [ "$output" = "single-issue-text" ]

  run resolve_dispatch_key "full" "" "" "42" "43"
  [ "$status" -eq 0 ]; [ "$output" = "batch-multi" ]

  run resolve_dispatch_key "dev-and-pr" "" "" "42"
  [ "$status" -eq 0 ]; [ "$output" = "dev-and-pr" ]

  run resolve_dispatch_key "status" "" "" "42"
  [ "$status" -eq 0 ]; [ "$output" = "status-per-issue" ]

  run resolve_dispatch_key "review-latest" "" "" "42"
  [ "$status" -eq 0 ]; [ "$output" = "review-latest" ]

  run resolve_dispatch_key "assess-and-fix" "" "" "42"
  [ "$status" -eq 0 ]; [ "$output" = "assess-and-fix" ]

  run resolve_dispatch_key "undo" "" "" "42"
  [ "$status" -eq 0 ]; [ "$output" = "undo" ]

  # Unrecognized mode → empty string
  run resolve_dispatch_key "no-such-mode" "" ""
  [ "$status" -eq 0 ]; [ "$output" = "" ]

  # No target in full mode → no-target
  run resolve_dispatch_key "full" "" ""
  [ "$status" -eq 0 ]; [ "$output" = "no-target" ]
}

@test "resolve_dispatch_key refuses mixed --pr and positional issue numbers" {
  eval "$(sed -n '/^# --- resolve_dispatch_key (pure)/,/^# --- end resolve_dispatch_key/p' "$RITE_REPO_ROOT/bin/rite")"
  set +u; set +o pipefail

  run resolve_dispatch_key "full" "" "72" "42"
  [ "$status" -eq 0 ]
  [ "$output" = "mixed-pr-and-issues" ]
}

# ---------------------------------------------------------------------------
# Parity tests: for each tuple case, the dry-run plan names exactly the stub
# that executes without --dry-run. This structurally proves plan == execution.
# ---------------------------------------------------------------------------

@test "parity: single-issue — dry-run plan names workflow-runner, real execution calls it" {
  _run_rite --dry-run 42
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "workflow-runner.sh 42 --auto"

  # Without --dry-run: normalize_and_resolve calls "gh issue view 42" before
  # exec-ing workflow-runner.  Override the gh stub to emit minimal valid issue
  # JSON so the pre-flight does not abort with "Issue #42 not found".
  # Uses an unquoted heredoc so $_FAKE_BIN is expanded at write time.
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: $_FAKE_BIN must be expanded at write time
  cat > "$_FAKE_BIN/gh" << GHSTUB
#!/bin/bash
echo "STUB_CALLED:gh" >> "$_FAKE_BIN/gh.calls"
# Return minimal valid JSON for "issue view" calls; pass everything else.
if [ "\${1:-}" = "issue" ] && [ "\${2:-}" = "view" ]; then
  echo '{"title":"Test issue","body":"","state":"OPEN"}'
  exit 0
fi
exit 0
GHSTUB
  chmod +x "$_FAKE_BIN/gh"

  _run_rite 42
  [ "$status" -eq 0 ]
  [ -f "$_FAKE_BIN/workflow-runner.calls" ]
  [ ! -f "$_FAKE_BIN/batch-process-issues.calls" ]
}

@test "parity: multi-issue batch — dry-run plan names batch-process-issues, real execution calls it" {
  _run_rite --dry-run 490 489 467
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "batch-process-issues.sh 490 489 467 --auto"

  _run_rite 490 489 467
  [ "$status" -eq 0 ]
  [ -f "$_FAKE_BIN/batch-process-issues.calls" ]
  [ ! -f "$_FAKE_BIN/workflow-runner.calls" ]
}

@test "parity: label-batch — dry-run plan names batch-process-issues, real execution calls it" {
  _run_rite --label tech-debt --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "batch-process-issues.sh --label tech-debt --auto"

  _run_rite --label tech-debt
  [ "$status" -eq 0 ]
  [ -f "$_FAKE_BIN/batch-process-issues.calls" ]
}

@test "parity: --pr mixed tuple refused identically by dry-run and real execution" {
  # Dry-run: exits 1 (mixed-pr-and-issues)
  _run_rite --dry-run --pr 72 42
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "ambiguous\|cannot be combined"

  # Real: exits 1 with same semantic refusal
  _run_rite --pr 72 42
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "ambiguous\|cannot be combined"
}

@test "parity: dispatch section has no independent routing conditionals (structural)" {
  # After resolve_dispatch_key() is called in the dispatch section, there must
  # be zero old-style 'elif [...MODE...ARGS...]' routing guards in the
  # smart-routing block.  The entire routing decision lives in
  # resolve_dispatch_key(); the case statement only dispatches.
  local _dispatch_section
  _dispatch_section=$(sed -n '/^# Smart routing/,/^esac$/p' "$RITE_REPO_ROOT/bin/rite")

  # Must not contain: elif [...] && [ "$MODE" = ... ] (the pre-PR pattern)
  if echo "$_dispatch_section" | grep -qE 'elif \[ \$\{#ARGS\[@\]\}.*\] && \[ "\$MODE"'; then
    echo "FAIL: dispatch section still contains independent MODE+ARGS routing conditional" >&2
    return 1
  fi

  # Must not contain: if [ "$MODE" = "status" ] && [ -z "${ARGS[0]:-}" ] (the pre-PR pattern)
  if echo "$_dispatch_section" | grep -qE 'if \[ "\$MODE" = "status" \] && \[ -z'; then
    echo "FAIL: dispatch section still contains independent status+ARGS routing conditional" >&2
    return 1
  fi

  # Must contain exactly one routing entry point: the _DISPATCH_KEY assignment
  # (anchoring on the assignment prevents false matches from comments that
  # mention resolve_dispatch_key() by name).
  local _key_calls
  _key_calls=$(echo "$_dispatch_section" | grep -c '_DISPATCH_KEY=$(resolve_dispatch_key' || true)
  if [ "$_key_calls" -ne 1 ]; then
    echo "FAIL: expected exactly 1 _DISPATCH_KEY=\$(resolve_dispatch_key assignment in dispatch section, got $_key_calls" >&2
    return 1
  fi
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
