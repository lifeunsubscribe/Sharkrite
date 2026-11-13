#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh::_gate_describe, lib/core/merge-pr.sh, lib/core/claude-workflow.sh
#
# freshup report 2026-11-12b: §3.6 the gate start message said "make check +
# bats -r tests/" while running the project's RITE_TEST_COMMAND; §3.5 a pending
# CI check followed by a merge read as "merged without a verdict"; §3.3 a fix
# session rewrote an assertion (== 4 → == 5) to match the output.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "$RITE_LIB_DIR/utils/test-gate.sh"
  set +u; set +o pipefail
  R="$BATS_TEST_TMPDIR/r"; mkdir -p "$R"
}

@test "_gate_describe: sharkrite repo, RITE_TEST_COMMAND, runner homes, nothing" {
  printf 'shellcheck:\n\ttrue\nlint:\n\ttrue\n' > "$R/Makefile"
  [ "$(_gate_describe "$R")" = "make check + targeted bats" ]
  rm "$R/Makefile"
  [ "$(RITE_TEST_COMMAND="bash scripts/rite-test.sh" _gate_describe "$R")" = "RITE_TEST_COMMAND: bash scripts/rite-test.sh" ]
  mkdir -p "$R/frontend"; printf '{"scripts":{"test":"vitest run"}}\n' > "$R/frontend/package.json"
  [[ "$(_gate_describe "$R")" == *"frontend:node"* ]]
  rm -rf "$R/frontend"
  [ "$(_gate_describe "$R")" = "project test runner" ]
}

@test "source: no gate-start message hard-codes make check + bats any more" {
  ! grep -n 'print_info "Starting post-commit gate in background (make check' "$RITE_LIB_DIR/core/workflow-runner.sh"
  [ "$(grep -c 'Starting post-commit gate in background.*_gate_describe' "$RITE_LIB_DIR/core/workflow-runner.sh")" = "2" ]
}

@test "source: pending CI is reported as waived with a reason, in the message and the diag" {
  grep -q 'still pending — waived' "$RITE_LIB_DIR/core/merge-pr.sh"
  grep -q 'MERGE_GATE_CI outcome=pending .*waived=true reason=pending_is_advisory' "$RITE_LIB_DIR/core/merge-pr.sh"
}

@test "source: the fix prompt forbids changing an expected value without naming the reason" {
  _ins=$(sed -n '/FIX_PROMPT+="## Instructions/,/\$EXIT_INSTRUCTION"/p' "$RITE_LIB_DIR/core/claude-workflow.sh")
  [[ "$_ins" == *"Never change an expected value to match the observed output"* ]]
}
