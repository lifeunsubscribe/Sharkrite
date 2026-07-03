#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/timeout.sh
#
# Regression for issue #654: the post-commit gate was awaited with a bare
# `wait "$_gate_pid"` (no timeout). A selected bats test that leaks a subprocess
# inheriting the gate's stdout pipe makes `tee` never see EOF, so the gate PID
# never exits and the whole workflow hangs for hours (live: `rite 482` ~2.5h).
#
# wait_pid_with_timeout bounds that wait; kill_process_tree reaps the gate's
# children. These tests lock in both, including a faithful reproduction of the
# leaked-pipe hang.
#
# NOTE: tests call the helpers directly (not via bats `run`) with `|| rc=$?`,
# because `wait` only works on children of the *current* shell — a `run`
# subshell can't reap a PID backgrounded in the test body.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "${RITE_LIB_DIR}/utils/timeout.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

@test "wait_pid_with_timeout: fast process returns its real exit code (0)" {
  sleep 0.2 & local p=$!
  local rc=0; wait_pid_with_timeout "$p" 5 || rc=$?
  [ "$rc" -eq 0 ]
}

@test "wait_pid_with_timeout: surfaces a non-zero exit code" {
  bash -c 'exit 7' & local p=$!
  local rc=0; wait_pid_with_timeout "$p" 5 || rc=$?
  [ "$rc" -eq 7 ]
}

@test "wait_pid_with_timeout: returns 124 on timeout, near the bound (not hanging)" {
  sleep 30 & local p=$!
  local t0=$SECONDS rc=0
  wait_pid_with_timeout "$p" 2 || rc=$?
  local elapsed=$((SECONDS - t0))
  kill_process_tree "$p"
  [ "$rc" -eq 124 ]
  [ "$elapsed" -lt 6 ]   # bounded, not the full 30s
}

@test "issue #654: a leaked child holding the gate pipe does NOT hang the wait" {
  # Faithful repro: a pipeline whose left side backgrounds a long sleep that
  # inherits the pipe's write end, so `cat` (stand-in for tee) never sees EOF
  # and the subshell PID never exits — exactly the gate-hang mechanism.
  local out="$BATS_TEST_TMPDIR/out"
  ( { sleep 30 & echo done; } | cat > "$out" ) & local p=$!
  local t0=$SECONDS rc=0
  wait_pid_with_timeout "$p" 2 || rc=$?
  local elapsed=$((SECONDS - t0))
  kill_process_tree "$p"
  pkill -f 'sleep 30' 2>/dev/null || true   # the reparented stray
  [ "$rc" -eq 124 ]      # rescued
  [ "$elapsed" -lt 6 ]   # did not hang on the 30s sleep
}

@test "kill_process_tree: kills the parent and its children" {
  bash -c 'sleep 30 & sleep 30 & wait' & local gp=$!
  sleep 0.3   # let children spawn
  kill_process_tree "$gp"
  sleep 0.3
  ! kill -0 "$gp" 2>/dev/null   # parent gone
  pkill -f 'sleep 30' 2>/dev/null || true
}

@test "kill_process_tree: no-op on empty/missing pid (no crash under set -e)" {
  run kill_process_tree ""
  [ "$status" -eq 0 ]
}
