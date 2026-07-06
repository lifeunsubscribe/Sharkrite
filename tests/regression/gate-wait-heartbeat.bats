#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh
# Regression for #946: the post-review gate wait heartbeats instead of sitting
# silent. Review typically beats the parallel gate by minutes; the old single
# bounded wait printed NOTHING after "Review posted" — every iteration read as
# a hang at the console (Sarah: "it always hangs way too long at this part").

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"; export RITE_REPO_ROOT
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  # shellcheck source=/dev/null
  source "${RITE_REPO_ROOT}/lib/utils/timeout.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
  # Extract just the wrapper from workflow-runner (a top-level orchestrator —
  # sourcing it whole runs the program body), snippet-extraction pattern per
  # undo-lock-and-branch-cleanup.bats. Line-number based: a literal
  # "name() {" pattern in THIS file's source gets mangled by bats'
  # preprocessor (same family as runbook rule 7's heredoc-@test trap).
  _wf="${RITE_REPO_ROOT}/lib/core/workflow-runner.sh"
  _start=$(grep -n "^_wait_gate_heartbeat" "$_wf" | head -1 | cut -d: -f1)
  eval "$(awk -v s="$_start" 'NR>=s { print; if (NR>s && /^}/) exit }' "$_wf")"
  print_info() { echo "INFO: $*"; }
}

@test "child exit code propagates through slices (fast child)" {
  sleep 0.2 &
  # File capture, NOT $( ): wait_pid_with_timeout reaps via `wait`, which only
  # works in the child's parent shell — a subshell capture (run/$()) turns the
  # reap into `wait` on a non-child (exit 127).
  local pid=$! rc=0
  _wait_gate_heartbeat "$pid" 10 > "$BATS_TEST_TMPDIR/hb.out" || rc=$?
  [ "$rc" -eq 0 ]
  grep -q "waiting for the parallel gate" "$BATS_TEST_TMPDIR/hb.out"
}

@test "nonzero child exit propagates" {
  ( sleep 0.2; exit 3 ) &
  local pid=$! rc=0
  _wait_gate_heartbeat "$pid" 10 >/dev/null || rc=$?
  [ "$rc" -eq 3 ]
}

@test "heartbeat line emitted per slice while child runs (2s slices)" {
  export RITE_GATE_HEARTBEAT_SLICE=2
  sleep 5 &
  local pid=$! rc=0
  _wait_gate_heartbeat "$pid" 30 > "$BATS_TEST_TMPDIR/hb.out" || rc=$?
  [ "$rc" -eq 0 ]
  grep -q "gate still running (2s elapsed" "$BATS_TEST_TMPDIR/hb.out"
  grep -q "gate still running (4s elapsed" "$BATS_TEST_TMPDIR/hb.out"
}

@test "genuine timeout returns 124 after the bound" {
  export RITE_GATE_HEARTBEAT_SLICE=1
  sleep 30 &
  local pid=$! rc=0
  _wait_gate_heartbeat "$pid" 3 >/dev/null || rc=$?
  [ "$rc" -eq 124 ]
  kill "$pid" 2>/dev/null || true
}

@test "source: both long gate waits use the heartbeat wrapper" {
  run grep -c '_wait_gate_heartbeat "\$_gate_pid\|_wait_gate_heartbeat "\$_init_gate_pid' "${RITE_REPO_ROOT}/lib/core/workflow-runner.sh"
  [ "$output" = "2" ]
  # And no remaining bare long wait on the gate pids.
  run grep -E 'wait_pid_with_timeout "\$_(init_)?gate_pid" "\$\{RITE_GATE_WAIT_TIMEOUT' "${RITE_REPO_ROOT}/lib/core/workflow-runner.sh"
  [ "$status" -ne 0 ]
}
