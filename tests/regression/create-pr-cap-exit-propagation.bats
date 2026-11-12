#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/create-pr.sh, lib/core/workflow-runner.sh::phase_create_pr|phase_assess_and_resolve|run_workflow, bin/rite
#
# Regression tests for the review-failure exit-code chain.
#
# Live failure (batch 20261111-010111): the review model hit a usage cap at
# 02:20. local-review.sh reported exit 5, create-pr.sh ran
# `trigger_local_review || exit 1`, workflow-runner saw 1 (not 5), the batch
# marked the issue failed and MOVED ON. Twenty consecutive issues each ran a
# full dev session, pushed a PR, and failed at review — ~4 hours of dev-model
# credit spent producing unreviewed PRs — when exit 5 should have aborted the
# batch at the first one.
#
# Contract: create-pr.sh preserves exit 5 (usage cap) and exit 18 (auth
# failure) from the review runner; every workflow-runner site that consumes
# create-pr's exit code handles 18 alongside 5.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CREATE_PR_SH="$PROJECT_ROOT/lib/core/create-pr.sh"
  RUNNER_SH="$PROJECT_ROOT/lib/core/workflow-runner.sh"
  BINRITE="$PROJECT_ROOT/bin/rite"
}

# Run the REAL review-trigger block from create-pr.sh (extracted via
# sharkrite-extract markers) with a stubbed trigger_local_review that exits $1.
_run_trigger_block() {
  local stub_rc="$1"
  local block
  block=$(sed -n '/# sharkrite-extract: local-review-trigger-start/,/# sharkrite-extract: local-review-trigger-end/p' "$CREATE_PR_SH")
  [ -n "$block" ] || { echo "FAIL: empty block extraction" >&2; return 1; }
  [[ "$block" == *"trigger_local_review"* ]] || { echo "FAIL: block missing trigger call" >&2; return 1; }

  run bash -c "
    set -euo pipefail
    print_error() { echo \"[ERROR] \$*\" >&2; }
    trigger_local_review() { return ${stub_rc}; }
    AUTO_MODE=true
    PR_NUMBER=42
    ${block}
    echo 'REVIEW_OK'
  "
}

@test "create-pr review block: exit 5 from the review runner is preserved" {
  _run_trigger_block 5
  [ "$status" -eq 5 ]
  [[ "$output" == *"Local review failed"* ]]
  [[ "$output" != *"REVIEW_OK"* ]]
}

@test "create-pr review block: exit 18 from the review runner is preserved" {
  _run_trigger_block 18
  [ "$status" -eq 18 ]
  [[ "$output" == *"Local review failed"* ]]
}

@test "create-pr review block: generic review failure still exits 1" {
  _run_trigger_block 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Local review failed"* ]]
}

@test "create-pr review block: unknown non-zero codes collapse to 1 (not leaked)" {
  _run_trigger_block 7
  [ "$status" -eq 1 ]
}

@test "create-pr review block: success falls through" {
  _run_trigger_block 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"REVIEW_OK"* ]]
}

@test "create-pr.sh no longer uses '|| exit 1' on trigger_local_review" {
  run grep -nE 'trigger_local_review .*\|\| *\{' "$CREATE_PR_SH"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# workflow-runner: every create-pr exit consumer handles 18 next to 5
# ---------------------------------------------------------------------------

@test "phase_create_pr maps create-pr exit 18 to return 18" {
  run grep -nE 'create_pr_exit -eq 18' "$RUNNER_SH"
  [ "$status" -eq 0 ]
  run awk '/create_pr_exit -eq 18/{f=1} f&&/return 18/{print; exit}' "$RUNNER_SH"
  [ -n "$output" ]
}

@test "fix-loop and stale-reroute create-pr callers propagate 18" {
  for var in _loop_create_pr_rc _reroute_create_pr_rc _create_pr_rc; do
    run grep -nE "\\\$${var} -eq 18" "$RUNNER_SH"
    [ "$status" -eq 0 ] || { echo "missing -eq 18 check for $var" >&2; return 1; }
  done
}

@test "every create-pr exit-5 consumer in workflow-runner has a matching exit-18 consumer" {
  local five eighteen
  five=$(grep -cE '_create_pr_rc -eq 5|create_pr_exit -eq 5' "$RUNNER_SH" || true)
  eighteen=$(grep -cE '_create_pr_rc -eq 18|create_pr_exit -eq 18' "$RUNNER_SH" || true)
  [ "$five" -gt 0 ]
  [ "$five" -eq "$eighteen" ]
}

# ---------------------------------------------------------------------------
# bin/rite --assess-and-fix: PUSH_EXIT and stale-review consumers handle 5/18
# ---------------------------------------------------------------------------

@test "bin/rite fix-loop PUSH_EXIT 5 propagates to FINAL_EXIT=5" {
  run grep -nE 'PUSH_EXIT -eq 5' "$BINRITE"
  [ "$status" -eq 0 ]
  run awk '/PUSH_EXIT -eq 5/{f=1} f&&/FINAL_EXIT=5/{print; exit}' "$BINRITE"
  [ -n "$output" ]
}

@test "bin/rite fix-loop PUSH_EXIT 18 propagates to FINAL_EXIT=18" {
  run grep -nE 'PUSH_EXIT -eq 18' "$BINRITE"
  [ "$status" -eq 0 ]
  run awk '/PUSH_EXIT -eq 18/{f=1} f&&/FINAL_EXIT=18/{print; exit}' "$BINRITE"
  [ -n "$output" ]
}

@test "bin/rite stale-review branch captures CREATE_PR exit code" {
  # Must assign the exit code (not discard it) after the stale-review CREATE_PR call
  run grep -nE 'STALE_PUSH_EXIT=\$\?' "$BINRITE"
  [ "$status" -eq 0 ]
}

@test "bin/rite stale-review STALE_PUSH_EXIT 5 propagates to FINAL_EXIT=5" {
  run grep -nE 'STALE_PUSH_EXIT -eq 5' "$BINRITE"
  [ "$status" -eq 0 ]
  run awk '/STALE_PUSH_EXIT -eq 5/{f=1} f&&/FINAL_EXIT=5/{print; exit}' "$BINRITE"
  [ -n "$output" ]
}

@test "bin/rite stale-review STALE_PUSH_EXIT 18 propagates to FINAL_EXIT=18" {
  run grep -nE 'STALE_PUSH_EXIT -eq 18' "$BINRITE"
  [ "$status" -eq 0 ]
  run awk '/STALE_PUSH_EXIT -eq 18/{f=1} f&&/FINAL_EXIT=18/{print; exit}' "$BINRITE"
  [ -n "$output" ]
}
