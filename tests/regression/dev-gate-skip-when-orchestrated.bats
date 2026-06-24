#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Regression: the dev/initial-commit test gate (_run_dev_test_gate) must NOT run
# during ORCHESTRATED runs.
#
# Bug (live 2026-06-24, issue 649 dev session): _run_dev_test_gate ran the FULL
# `bats -r tests/` suite during the dev phase even when workflow-runner drove the
# run (RITE_ORCHESTRATED=true). That is redundant with the post-commit structured
# gate (run_test_gate, Phase 2/3 — targeted + baseline-diff + bounded), and it is
# untargeted (parallel barrier-timeout load flake), unbounded (a tty-stdin
# deadlock in the lint suite wedged the run for 78 minutes), and spawned a second
# auto-fix session churning on phantom failures. Fix: skip when orchestrated.
#
# Probe: _run_dev_test_gate runs `eval "$_test_cmd"`; RITE_TEST_CMD="touch <s>"
# lets us observe whether the test command actually executed.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  WORKFLOW_FILE="${RITE_LIB_DIR}/core/claude-workflow.sh"
}

# Call _run_dev_test_gate in a clean subshell with functions-only sourcing.
# Args: $1 = RITE_ORCHESTRATED value, $2 = sentinel path the fake test cmd touches.
_call_dev_gate() {
  # AUTO_MODE is set AFTER sourcing (the file's arg-parse path would reset it),
  # and stdin is /dev/null so a stray interactive read can never hang the test.
  run env \
    RITE_LIB_DIR="$RITE_LIB_DIR" \
    RITE_SOURCE_FUNCTIONS_ONLY=1 \
    RITE_ORCHESTRATED="$1" \
    RITE_TEST_CMD="touch $2" \
    RITE_TEST_GATE_AUTOFIX=false \
    RITE_LOG_FILE=/dev/null \
    bash -c 'source "$RITE_LIB_DIR/core/claude-workflow.sh"; AUTO_MODE=true; _run_dev_test_gate' </dev/null
}

@test "_run_dev_test_gate is SKIPPED under RITE_ORCHESTRATED=true (no test run)" {
  local _sentinel="$BATS_TEST_TMPDIR/ran-orchestrated"
  _call_dev_gate true "$_sentinel"
  [ "$status" -eq 0 ]
  [ ! -f "$_sentinel" ]   # test command never executed — guard skipped it
}

@test "structural: the orchestrated skip precedes the test execution (eval)" {
  # The guard must sit at the top of the function, before `eval "$_test_cmd"`,
  # so it short-circuits the whole detection+run+auto-fix body.
  _fn=$(awk '/^_run_dev_test_gate\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$WORKFLOW_FILE")
  _guard_line=$(printf '%s\n' "$_fn" | grep -n 'RITE_ORCHESTRATED' | head -1 | cut -d: -f1)
  _eval_line=$(printf '%s\n' "$_fn" | grep -n 'eval "\$_test_cmd"' | head -1 | cut -d: -f1)
  [ -n "$_guard_line" ]
  [ -n "$_eval_line" ]
  [ "$_guard_line" -lt "$_eval_line" ]
}
