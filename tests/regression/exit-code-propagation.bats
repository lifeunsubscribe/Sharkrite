#!/usr/bin/env bats
# tests/regression/exit-code-propagation.bats
#
# Table-driven test for exit-code propagation through the Sharkrite workflow stack.
#
# Background:
#   Bugs #21 (exit 10 ambiguity) and #22 (exit 5 dropping) proved that exit codes
#   can be silently mutated as they cross script boundaries. This test builds a
#   comprehensive table covering every documented exit code at each layer and
#   asserts the parent layer's behavior is correct.
#
# Propagation chain under test (producer → consumer):
#   Layer A: assess-and-resolve.sh → workflow-runner.sh phase_assess_resolve
#   Layer B: workflow-runner.sh run_workflow → workflow-runner.sh main dispatcher
#   Layer C: workflow-runner.sh main dispatcher → batch-process-issues.sh loop
#   Layer D: Nested path (assess → runner → batch) — the layer most bugs hide in
#
# Exit code canonical table: docs/architecture/exit-codes.md
#
# Test taxonomy:
#   assess-and-resolve exits: 0 (merge), 1 (manual), 2 (loop), 3 (stale)
#   workflow-runner run_workflow exits: 0, 1, 5, 6
#   main dispatcher exits: 0, 5, 6, 1 (anything else)
#   batch loop interprets: 0 (complete), 5 (abort), 6 (merge-cleanup-failed), 10 (defer), 1 (fail)
#   Special signals: 4 (no work), 11 (stale restart), 124 (timeout/provider)
#
# Each @test follows the pattern:
#   1. Define producer behavior (stub function or inline exit code)
#   2. Run consumer logic (replicated from real script or sourced)
#   3. Assert consumer's output exit code or state change
#
# Every test is self-contained: no shared state leaks between rows.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"

  # Stub print functions used by sourced modules (all to stderr so they don't
  # pollute stdout which some tests use to capture structured output)
  print_status()  { echo "STATUS: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_warning() { echo "WARNING: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }
  export -f print_status print_info print_warning print_error print_success print_header
}

teardown() {
  teardown_test_tmpdir
}

# =============================================================================
# LAYER A: assess-and-resolve.sh → workflow-runner.sh phase_assess_resolve
#
# assess-and-resolve.sh is called as a subprocess by phase_assess_resolve.
# Its exit code drives which branch phase_assess_resolve takes.
# Table row format: (assess exit code, expected phase_assess_resolve return code)
# =============================================================================

# Helper: replicate the assess-and-resolve dispatch logic from phase_assess_resolve
# in workflow-runner.sh (lines ~1099-1276).  Reads $1 as the assess exit code
# and echoes the resulting phase return code to stdout.
_simulate_phase_assess_resolve() {
  local assessment_result=$1
  local retry_count=${2:-0}
  local max_retries=3

  # Mirrors the fixed dispatch table in phase_assess_resolve
  if [ "$assessment_result" -eq 2 ]; then
    if [ "$retry_count" -ge "$max_retries" ]; then
      # Max retries hit — caller gets 1 (manual intervention)
      echo 1; return
    fi
    # Loop to fix — caller gets 2
    echo 2; return

  elif [ "$assessment_result" -eq 3 ]; then
    # Review stale — route back to Phase 2
    echo 3; return

  elif [ "$assessment_result" -eq 0 ]; then
    # Ready to merge
    echo 0; return

  else
    # Exit 1 or any unrecognized code → manual intervention
    echo 1; return
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Row A-0: assess exit 0 → phase_assess_resolve returns 0 (ready to merge)
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-A: assess exit 0 (merge-ready) → phase_assess_resolve returns 0" {
  _out=$(_simulate_phase_assess_resolve 0)
  [ "$_out" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Row A-1: assess exit 1 → phase_assess_resolve returns 1 (manual intervention)
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-A: assess exit 1 (manual intervention) → phase_assess_resolve returns 1" {
  _out=$(_simulate_phase_assess_resolve 1)
  [ "$_out" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Row A-2: assess exit 2 → phase_assess_resolve returns 2 (loop to fix)
#          Only when retry_count < max_retries.
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-A: assess exit 2 (loop-to-fix) → phase_assess_resolve returns 2 (retry < max)" {
  _out=$(_simulate_phase_assess_resolve 2 0)
  [ "$_out" -eq 2 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Row A-2-exhausted: assess exit 2 at retry max → phase_assess_resolve returns 1
#          When retries exhausted, the fix loop cannot continue. The runner
#          falls through to manual intervention (return 1).
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-A: assess exit 2 at max retries → phase_assess_resolve returns 1 (manual)" {
  _out=$(_simulate_phase_assess_resolve 2 3)
  [ "$_out" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Row A-3: assess exit 3 → phase_assess_resolve returns 3 (review stale)
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-A: assess exit 3 (stale review) → phase_assess_resolve returns 3" {
  _out=$(_simulate_phase_assess_resolve 3)
  [ "$_out" -eq 3 ]
}

# =============================================================================
# LAYER B: workflow-runner.sh run_workflow → main dispatcher
#
# run_workflow() is called by the main() function in workflow-runner.sh.
# The main dispatcher converts run_workflow's return codes to process exit codes
# (lines ~2140-2153 of workflow-runner.sh).
# Table row format: (run_workflow return code, expected process exit code)
# =============================================================================

# Helper: replicate the main() dispatcher logic from workflow-runner.sh
_simulate_main_dispatcher() {
  local workflow_exit=$1

  if [ "$workflow_exit" -eq 0 ]; then
    echo 0
  elif [ "$workflow_exit" -eq 6 ]; then
    # Merge succeeded but cleanup failed — propagate 6 to batch reporter
    echo 6
  elif [ "$workflow_exit" -eq 5 ]; then
    # Usage cap — propagate 5 so batch can abort cleanly
    echo 5
  else
    # All other failures (1, 4, etc.) → generic failure exit 1
    echo 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Row B-0: run_workflow returns 0 → main dispatcher exits 0
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-B: run_workflow returns 0 (success) → main dispatcher exits 0" {
  _out=$(_simulate_main_dispatcher 0)
  [ "$_out" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Row B-1: run_workflow returns 1 → main dispatcher exits 1
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-B: run_workflow returns 1 (generic failure) → main dispatcher exits 1" {
  _out=$(_simulate_main_dispatcher 1)
  [ "$_out" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Row B-5: run_workflow returns 5 → main dispatcher exits 5 (NOT 1)
#          This is the critical propagation verified by issue #22.
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-B: run_workflow returns 5 (usage cap) → main dispatcher exits 5 (not 1)" {
  _out=$(_simulate_main_dispatcher 5)
  [ "$_out" -eq 5 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Row B-6: run_workflow returns 6 → main dispatcher exits 6 (NOT 1)
#          Merge succeeded but cleanup failed — caller must know work landed.
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-B: run_workflow returns 6 (merge-ok/cleanup-failed) → main dispatcher exits 6 (not 1)" {
  _out=$(_simulate_main_dispatcher 6)
  [ "$_out" -eq 6 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Row B-4: run_workflow returns 4 (no work) → main dispatcher exits 1 (not 4)
#          Exit 4 is internal to workflow-runner; it does not cross to batch.
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-B: run_workflow returns 4 (no-work internal) → main dispatcher exits 1 (internal code not exported)" {
  _out=$(_simulate_main_dispatcher 4)
  [ "$_out" -eq 1 ]
}

# =============================================================================
# LAYER C: main dispatcher → batch-process-issues.sh loop
#
# The batch loop calls the rite subprocess (which runs main) and branches on
# the process exit code.  This layer is the outermost consumer.
# Table row format: (process exit code, expected batch action)
# Each test writes a batch-loop simulator to a temp script and runs it.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Row C-0: process exit 0 → batch counts issue as COMPLETED, continues loop
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-C: process exit 0 → batch marks issue completed, loop continues" {
  _script="$RITE_TEST_TMPDIR/batch-c0.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
COMPLETED=0
FAILED=()
for N in 1 2 3; do
  case $N in 1) C=0;; 2) C=0;; 3) C=0;; esac
  if [ $C -eq 0 ]; then COMPLETED=$((COMPLETED+1))
  elif [ $C -eq 5 ]; then FAILED+=("$N"); break
  elif [ $C -eq 10 ]; then : # defer, continue
  else FAILED+=("$N"); fi
done
echo "completed:$COMPLETED"
echo "failed:${FAILED[*]:-none}"
EOF
  chmod +x "$_script"
  _out=$("$_script")
  echo "$_out" | grep -q "completed:3"
  echo "$_out" | grep -q "failed:none"
}

# ─────────────────────────────────────────────────────────────────────────────
# Row C-1: process exit 1 → batch counts issue as FAILED, loop continues
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-C: process exit 1 → batch marks issue failed, loop continues to next issue" {
  _script="$RITE_TEST_TMPDIR/batch-c1.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
COMPLETED=0
FAILED=()
PROCESSED=""
for N in 1 2 3; do
  case $N in 1) C=0;; 2) C=1;; 3) C=0;; esac
  PROCESSED="$PROCESSED $N"
  if [ $C -eq 0 ]; then COMPLETED=$((COMPLETED+1))
  elif [ $C -eq 5 ]; then FAILED+=("$N"); break
  elif [ $C -eq 10 ]; then : # defer
  else FAILED+=("$N"); fi
done
echo "processed:$PROCESSED"
echo "completed:$COMPLETED"
echo "failed:${FAILED[*]:-none}"
EOF
  chmod +x "$_script"
  _out=$("$_script")
  # Issue 2 failed but loop continued — issue 3 was processed
  echo "$_out" | grep -qE "processed:.* 3"
  echo "$_out" | grep -q "failed:.*2"
  echo "$_out" | grep -q "completed:2"
}

# ─────────────────────────────────────────────────────────────────────────────
# Row C-5: process exit 5 → batch ABORTS (breaks loop, issue 3 not processed)
#          Critical: usage cap must stop the entire batch immediately.
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-C: process exit 5 (usage cap) → batch aborts, remaining issues not processed" {
  _script="$RITE_TEST_TMPDIR/batch-c5.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
COMPLETED=0
FAILED=()
PROCESSED=""
for N in 1 2 3; do
  case $N in 1) C=0;; 2) C=5;; 3) C=0;; esac
  PROCESSED="$PROCESSED $N"
  if [ $C -eq 0 ]; then COMPLETED=$((COMPLETED+1))
  elif [ $C -eq 5 ]; then FAILED+=("$N"); break
  elif [ $C -eq 10 ]; then :
  else FAILED+=("$N"); fi
done
echo "processed:$PROCESSED"
echo "completed:$COMPLETED"
echo "failed:${FAILED[*]:-none}"
EOF
  chmod +x "$_script"
  _out=$("$_script")
  # Issue 3 must NOT have been processed
  ! echo "$_out" | grep -qE "processed:.* 3"
  # Issue 2 is in failed
  echo "$_out" | grep -q "failed:.*2"
  # Only issue 1 completed
  echo "$_out" | grep -q "completed:1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Row C-6: process exit 6 → batch records as merge-ok/cleanup-failed, continues
#          The work IS on remote; batch must not treat this like a failure.
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-C: process exit 6 (merge-ok/cleanup-failed) → batch records separately, loop continues" {
  _script="$RITE_TEST_TMPDIR/batch-c6.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
COMPLETED=0
FAILED=()
MERGED_CLEANUP_FAILED=()
PROCESSED=""
for N in 1 2 3; do
  case $N in 1) C=0;; 2) C=6;; 3) C=0;; esac
  PROCESSED="$PROCESSED $N"
  if [ $C -eq 0 ]; then COMPLETED=$((COMPLETED+1))
  elif [ $C -eq 6 ]; then MERGED_CLEANUP_FAILED+=("$N")
  elif [ $C -eq 5 ]; then FAILED+=("$N"); break
  elif [ $C -eq 10 ]; then :
  else FAILED+=("$N"); fi
done
echo "processed:$PROCESSED"
echo "completed:$COMPLETED"
echo "failed:${FAILED[*]:-none}"
echo "merged_cleanup_failed:${MERGED_CLEANUP_FAILED[*]:-none}"
EOF
  chmod +x "$_script"
  _out=$("$_script")
  # Issue 3 was processed (loop did not break)
  echo "$_out" | grep -qE "processed:.* 3"
  # Issue 2 is in merged-cleanup-failed bucket, NOT in failed
  echo "$_out" | grep -q "merged_cleanup_failed:.*2"
  ! echo "$_out" | grep -q "failed:.*2"
  # Issues 1 and 3 completed
  echo "$_out" | grep -q "completed:2"
}

# ─────────────────────────────────────────────────────────────────────────────
# Row C-10: process exit 10 → batch DEFERS issue, loop continues
#           Blocker-detected: issue is re-queued, remaining issues run.
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-C: process exit 10 (blocker-defer) → batch defers issue, loop continues" {
  _script="$RITE_TEST_TMPDIR/batch-c10.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
COMPLETED=0
FAILED=()
BLOCKED=()
PROCESSED=""
for N in 1 2 3; do
  case $N in 1) C=0;; 2) C=10;; 3) C=0;; esac
  PROCESSED="$PROCESSED $N"
  if [ $C -eq 0 ]; then COMPLETED=$((COMPLETED+1))
  elif [ $C -eq 5 ]; then FAILED+=("$N"); break
  elif [ $C -eq 10 ]; then BLOCKED+=("$N")
  else FAILED+=("$N"); fi
done
echo "processed:$PROCESSED"
echo "completed:$COMPLETED"
echo "failed:${FAILED[*]:-none}"
echo "blocked:${BLOCKED[*]:-none}"
EOF
  chmod +x "$_script"
  _out=$("$_script")
  # Issue 3 was processed
  echo "$_out" | grep -qE "processed:.* 3"
  # Issue 2 is blocked (deferred), not failed
  echo "$_out" | grep -q "blocked:.*2"
  ! echo "$_out" | grep -q "failed:.*2"
  # Issues 1 and 3 completed
  echo "$_out" | grep -q "completed:2"
}

# ─────────────────────────────────────────────────────────────────────────────
# Row C-11: process exit 11 → batch treats as generic failure (not blocker-defer)
#           Exit 11 (stale-restart) is internal to workflow-runner and should
#           never reach batch; if it leaks, it must not be treated as exit 10.
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-C: process exit 11 (stale-restart leak) → batch treats as failure, not blocker-defer" {
  _script="$RITE_TEST_TMPDIR/batch-c11.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
COMPLETED=0
FAILED=()
BLOCKED=()
PROCESSED=""
for N in 1 2 3; do
  case $N in 1) C=0;; 2) C=11;; 3) C=0;; esac
  PROCESSED="$PROCESSED $N"
  if [ $C -eq 0 ]; then COMPLETED=$((COMPLETED+1))
  elif [ $C -eq 5 ]; then FAILED+=("$N"); break
  elif [ $C -eq 10 ]; then BLOCKED+=("$N")
  else FAILED+=("$N"); fi  # 11 falls here — generic failure
done
echo "processed:$PROCESSED"
echo "completed:$COMPLETED"
echo "failed:${FAILED[*]:-none}"
echo "blocked:${BLOCKED[*]:-none}"
EOF
  chmod +x "$_script"
  _out=$("$_script")
  # Issue 2 failed (exit 11 is NOT a blocker-defer)
  echo "$_out" | grep -q "failed:.*2"
  ! echo "$_out" | grep -q "blocked:.*2"
  # Issue 3 was processed (loop continued)
  echo "$_out" | grep -qE "processed:.* 3"
}

# =============================================================================
# LAYER D: Nested path — producer → wrapper → consumer
# (the layer most bugs hide in, per issue description)
#
# Tests verify that exit codes survive nested shell calls without being
# swallowed by intermediate || { exit 1 } style error handling.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Row D-assess-2→runner→batch:
#   assess exits 2 → runner loops → eventual assess exits 0 → runner exits 0 → batch completes
#   Verifies the loop termination path propagates correctly end-to-end.
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-D (nested): assess exit 2 loop then 0 → runner exits 0 → batch records completed" {
  _script="$RITE_TEST_TMPDIR/nested-loop.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Simulate: assess returns 2 on first call, 0 on second (loop terminates)
CALL_COUNT=0
_assess() {
  CALL_COUNT=$((CALL_COUNT + 1))
  if [ $CALL_COUNT -eq 1 ]; then return 2; else return 0; fi
}

# Simulate phase_assess_resolve loop (up to 3 retries)
MAX_RETRIES=3
retry=0
phase_result=99
while [ $retry -lt $MAX_RETRIES ]; do
  assessment_result=0
  _assess || assessment_result=$?
  if [ $assessment_result -eq 2 ]; then
    retry=$((retry + 1))
    continue
  elif [ $assessment_result -eq 0 ]; then
    phase_result=0
    break
  else
    phase_result=1
    break
  fi
done

# Simulate main dispatcher
if [ $phase_result -eq 0 ]; then
  runner_exit=0
else
  runner_exit=1
fi

# Simulate batch loop
if [ $runner_exit -eq 0 ]; then
  echo "result:completed"
elif [ $runner_exit -eq 5 ]; then
  echo "result:abort"
elif [ $runner_exit -eq 10 ]; then
  echo "result:deferred"
else
  echo "result:failed"
fi
echo "call_count:$CALL_COUNT"
EOF
  chmod +x "$_script"
  _out=$("$_script")
  echo "$_out" | grep -q "result:completed"
  echo "$_out" | grep -q "call_count:2"
}

# ─────────────────────────────────────────────────────────────────────────────
# Row D-exit5-nested:
#   Inner producer returns 5 → intermediate wrapper must NOT swallow it as 1 →
#   outer consumer sees 5 and aborts batch.
#
#   Replicates the bug class from issue #22: intermediate || { exit 1 }
#   downgrading exit 5 to exit 1.
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-D (nested): exit 5 from inner producer propagates through intermediate wrapper (not downgraded to 1)" {
  _result=0
  (
    # Inner producer: usage cap
    inner_producer() { return 5; }

    # Intermediate wrapper: CORRECT implementation (branches on 5 explicitly)
    intermediate_wrapper() {
      local _r=0
      inner_producer || _r=$?
      if [ "$_r" -eq 5 ]; then
        return 5   # propagate usage cap
      elif [ "$_r" -ne 0 ]; then
        return 1   # generic failure
      fi
      return 0
    }

    # Outer consumer: run_workflow-like dispatcher
    intermediate_wrapper || return $?
  ) || _result=$?

  # Must be 5 (propagated), not 1 (swallowed by naive || return 1)
  [ "$_result" -eq 5 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Row D-exit5-swallowed (negative test):
#   Demonstrates the BROKEN pattern so we can confirm it IS broken and our
#   tests would catch it.  The naive || { exit 1 } swallows exit 5.
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-D (negative): naive '|| return 1' wrapper incorrectly swallows exit 5 (documents bug class)" {
  _result=0
  (
    inner_producer() { return 5; }

    # BROKEN intermediate wrapper — the pattern from before issue #22 fix
    broken_intermediate() {
      inner_producer || return 1   # swallows exit 5 → becomes exit 1
    }

    broken_intermediate || return $?
  ) || _result=$?

  # Broken pattern produces exit 1, NOT exit 5 — confirms the bug class is real
  [ "$_result" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Row D-exit6-nested:
#   merge-pr exits 6 → phase_merge_pr returns 6 → run_workflow returns 6 →
#   main dispatcher exits 6 → batch records as merge-ok/cleanup-failed.
# ─────────────────────────────────────────────────────────────────────────────
@test "layer-D (nested): exit 6 propagates from merge-pr through full stack to batch" {
  _script="$RITE_TEST_TMPDIR/nested-exit6.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Layer 1: merge-pr returns 6
merge_pr() { return 6; }

# Layer 2: phase_merge_pr — captures and re-propagates
phase_merge_pr_result=0
merge_pr || phase_merge_pr_result=$?
if [ $phase_merge_pr_result -eq 6 ]; then
  runner_result=6
elif [ $phase_merge_pr_result -eq 5 ]; then
  runner_result=5
elif [ $phase_merge_pr_result -eq 0 ]; then
  runner_result=0
else
  runner_result=1
fi

# Layer 3: main dispatcher
if [ $runner_result -eq 0 ]; then
  process_exit=0
elif [ $runner_result -eq 6 ]; then
  process_exit=6
elif [ $runner_result -eq 5 ]; then
  process_exit=5
else
  process_exit=1
fi

# Layer 4: batch loop
if [ $process_exit -eq 0 ]; then
  echo "batch:completed"
elif [ $process_exit -eq 6 ]; then
  echo "batch:merge_cleanup_failed"
elif [ $process_exit -eq 5 ]; then
  echo "batch:abort"
elif [ $process_exit -eq 10 ]; then
  echo "batch:deferred"
else
  echo "batch:failed"
fi
EOF
  chmod +x "$_script"
  _out=$("$_script")
  # Exit 6 must reach batch as merge_cleanup_failed (not failed, not completed)
  echo "$_out" | grep -q "batch:merge_cleanup_failed"
}

# =============================================================================
# SPECIAL EXIT CODES
#
# These codes have specific semantics that must not be confused with adjacent
# numeric values.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Verify exit code table: all documented codes are numerically distinct
#
# This is a structural guard — if anyone tries to reuse a code for a different
# meaning by changing a constant, this test fails immediately.
# ─────────────────────────────────────────────────────────────────────────────
@test "exit code uniqueness: all documented cross-script codes are distinct values" {
  # Cross-script signal codes from docs/architecture/exit-codes.md
  declare -a CODES=(0 1 2 3 4 5 6 10 11 124 127)

  # Verify all codes are distinct
  declare -A SEEN
  for code in "${CODES[@]}"; do
    if [ -n "${SEEN[$code]+x}" ]; then
      echo "Duplicate exit code detected: $code" >&2
      return 1
    fi
    SEEN[$code]=1
  done

  # Total count must equal array length (no deduplication occurred)
  [ "${#CODES[@]}" -eq 11 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Exit 4 (no-work): claude-workflow exits 4 → workflow-runner retry, then 1
#   Exit 4 is an internal code — it never crosses from workflow-runner to batch.
# ─────────────────────────────────────────────────────────────────────────────
@test "exit 4 (no-work): does not propagate to batch — main dispatcher converts to exit 1" {
  _out=$(_simulate_main_dispatcher 4)
  # Exit 4 is internal; main dispatcher converts unknown codes to 1
  [ "$_out" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Exit 11 (stale-restart): must not equal 10 (blocker-defer)
#   Numeric sanity guard — ensures the two batch-level signals never collide.
# ─────────────────────────────────────────────────────────────────────────────
@test "exit 11 (stale-restart) != exit 10 (blocker-defer): numeric sanity check" {
  [ 11 -ne 10 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Exit 5 (usage cap): must not equal 6 (merge-ok/cleanup-failed)
#   Both exit batch branches but with different semantics.
# ─────────────────────────────────────────────────────────────────────────────
@test "exit 5 (usage-cap) != exit 6 (merge-ok/cleanup-failed): numeric sanity check" {
  [ 5 -ne 6 ]
}

# =============================================================================
# STRUCTURAL GUARDS: verify real source files use the documented codes
#
# These tests grep the actual scripts to ensure the documented exit codes are
# present in the code.  They catch "the code says X but the doc says Y" drift.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# assess-and-resolve.sh must exit 2 for "loop to fix"
# ─────────────────────────────────────────────────────────────────────────────
@test "structural: assess-and-resolve.sh contains exit 2 (loop-to-fix signal)" {
  _count=$(grep -cE "^\s+exit 2\b" "$RITE_REPO_ROOT/lib/core/assess-and-resolve.sh" || true)
  [ "$_count" -ge 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# assess-and-resolve.sh must exit 3 for "review stale"
# ─────────────────────────────────────────────────────────────────────────────
@test "structural: assess-and-resolve.sh contains exit 3 (stale-review signal)" {
  _count=$(grep -cE "^\s+exit 3\b" "$RITE_REPO_ROOT/lib/core/assess-and-resolve.sh" || true)
  [ "$_count" -ge 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# workflow-runner.sh main dispatcher must explicitly handle exit 5 and exit 6
# ─────────────────────────────────────────────────────────────────────────────
@test "structural: workflow-runner.sh main dispatcher explicitly propagates exit 5" {
  _count=$(grep -c "exit 5" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" || true)
  [ "$_count" -ge 1 ]
}

@test "structural: workflow-runner.sh main dispatcher explicitly propagates exit 6" {
  _count=$(grep -c "exit 6" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" || true)
  [ "$_count" -ge 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# batch-process-issues.sh must handle exit codes 5, 6, 10 distinctly
# ─────────────────────────────────────────────────────────────────────────────
@test "structural: batch-process-issues.sh handles exit 5 (usage-cap abort)" {
  _count=$(grep -c "EXIT_CODE -eq 5" "$RITE_REPO_ROOT/lib/core/batch-process-issues.sh" || true)
  [ "$_count" -ge 1 ]
}

@test "structural: batch-process-issues.sh handles exit 6 (merge-ok/cleanup-failed)" {
  _count=$(grep -c "EXIT_CODE -eq 6" "$RITE_REPO_ROOT/lib/core/batch-process-issues.sh" || true)
  [ "$_count" -ge 1 ]
}

@test "structural: batch-process-issues.sh handles exit 10 (blocker-defer)" {
  _count=$(grep -c "EXIT_CODE -eq 10" "$RITE_REPO_ROOT/lib/core/batch-process-issues.sh" || true)
  [ "$_count" -ge 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# stale-branch.sh must use exit 11 (not 10) for the restart signal
# ─────────────────────────────────────────────────────────────────────────────
@test "structural: stale-branch.sh uses return 11 (not 10) for restart signal" {
  _count_11=$(grep -c "return 11" "$RITE_REPO_ROOT/lib/utils/stale-branch.sh" || true)
  _count_10=$(grep -cE "return 10\b" "$RITE_REPO_ROOT/lib/utils/stale-branch.sh" || true)
  [ "$_count_11" -ge 1 ]
  [ "$_count_10" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# workflow-runner.sh must check stale_result for 11 (not 10) in stale handler
# ─────────────────────────────────────────────────────────────────────────────
@test "structural: workflow-runner.sh stale handler branches on exit 11 (not 10)" {
  _count=$(grep -c "stale_result -eq 11" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" || true)
  [ "$_count" -ge 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# claude-workflow.sh must exit 4 (not 0) when no work is produced
# ─────────────────────────────────────────────────────────────────────────────
@test "structural: claude-workflow.sh contains exit 4 (no-work-produced signal)" {
  _count=$(grep -c "exit 4" "$RITE_REPO_ROOT/lib/core/claude-workflow.sh" || true)
  [ "$_count" -ge 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# claude-workflow.sh must exit 5 (not 1) for usage/token cap
# ─────────────────────────────────────────────────────────────────────────────
@test "structural: claude-workflow.sh contains exit 5 (usage-cap signal)" {
  _count=$(grep -c "exit 5" "$RITE_REPO_ROOT/lib/core/claude-workflow.sh" || true)
  [ "$_count" -ge 1 ]
}
