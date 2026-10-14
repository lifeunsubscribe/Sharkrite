#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, bin/rite
# Regression tests for #1135: run_workflow banner must not claim a lifecycle
# mode before detection has run; the accurate state line follows detection.
#
# Design contract:
#   1. Banner says "Processing issue #N…" — no lifecycle claim.
#   2. After the skip_to_phase detection block resolves:
#      a. No PR/worktree found → prints "Starting full lifecycle (phases 1-5)"
#      b. Resume (skip_to_phase set) → prints "Resuming: PR #N, <phase desc>"
#   3. dry-run strings in bin/rite carry "(full lifecycle; resumes from detected state)"
#      so the plan output is honest about the detection-dependent behaviour.
#
# All tests are STRUCTURAL (grep on source): the contract is a wording invariant
# that code cannot express.  The line-order test pins that the state line cannot
# appear before detection runs (the banner fires first, the state line is after).

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  _WFR="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  _RITE="$RITE_REPO_ROOT/bin/rite"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# 1. Banner in run_workflow has no lifecycle claim
# ---------------------------------------------------------------------------
@test "structural: run_workflow banner does not claim (full lifecycle)" {
  [ -f "$_WFR" ] || { echo "FAIL: workflow-runner.sh not found"; return 1; }

  _count=$(grep -c 'Processing issue.*full lifecycle' "$_WFR" || true)
  [ "$_count" -eq 0 ] || {
    echo "FAIL: banner still announces 'full lifecycle' before detection (found $_count occurrence(s))"
    return 1
  }
}

# ---------------------------------------------------------------------------
# 2a. Fresh-issue state line exists ("Starting full lifecycle" in else branch)
# ---------------------------------------------------------------------------
@test "structural: Starting full lifecycle (phases 1-5) state line exists" {
  [ -f "$_WFR" ] || { echo "FAIL: workflow-runner.sh not found"; return 1; }

  _count=$(grep -c 'Starting full lifecycle (phases 1-5)' "$_WFR" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: 'Starting full lifecycle (phases 1-5)' not found in workflow-runner.sh"
    return 1
  }
}

@test "structural: Starting full lifecycle state line appears after the banner (line order)" {
  [ -f "$_WFR" ] || { echo "FAIL: workflow-runner.sh not found"; return 1; }

  _banner_line=$(grep -n 'Processing issue #.*…' "$_WFR" | head -1 | cut -d: -f1)
  _state_line=$(grep -n 'Starting full lifecycle (phases 1-5)' "$_WFR" | head -1 | cut -d: -f1)

  [ -n "$_banner_line" ] || { echo "FAIL: banner line not found in workflow-runner.sh"; return 1; }
  [ -n "$_state_line" ]  || { echo "FAIL: state line not found in workflow-runner.sh"; return 1; }

  [ "$_state_line" -gt "$_banner_line" ] || {
    echo "FAIL: state line (line $_state_line) must come AFTER banner (line $_banner_line)"
    return 1
  }
}

# ---------------------------------------------------------------------------
# 2b. Resume state line exists ("Resuming: PR #" in the skip_to_phase branch)
# ---------------------------------------------------------------------------
@test "structural: Resuming state line exists for the resume path" {
  [ -f "$_WFR" ] || { echo "FAIL: workflow-runner.sh not found"; return 1; }

  _count=$(grep -c 'Resuming: PR #' "$_WFR" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: 'Resuming: PR #' state line not found in workflow-runner.sh"
    return 1
  }
}

@test "structural: Resuming state line appears after the banner (line order)" {
  [ -f "$_WFR" ] || { echo "FAIL: workflow-runner.sh not found"; return 1; }

  _banner_line=$(grep -n 'Processing issue #.*…' "$_WFR" | head -1 | cut -d: -f1)
  _resume_line=$(grep -n 'Resuming: PR #' "$_WFR" | head -1 | cut -d: -f1)

  [ -n "$_banner_line" ] || { echo "FAIL: banner line not found"; return 1; }
  [ -n "$_resume_line" ] || { echo "FAIL: Resuming state line not found"; return 1; }

  [ "$_resume_line" -gt "$_banner_line" ] || {
    echo "FAIL: Resuming line (line $_resume_line) must come AFTER banner (line $_banner_line)"
    return 1
  }
}

# ---------------------------------------------------------------------------
# 3. dry-run strings in bin/rite contain the qualified form
# ---------------------------------------------------------------------------
@test "structural: bin/rite single-issue dry-run includes 'resumes from detected state'" {
  [ -f "$_RITE" ] || { echo "FAIL: bin/rite not found"; return 1; }

  _count=$(grep -c 'resumes from detected state' "$_RITE" || true)
  [ "$_count" -ge 3 ] || {
    echo "FAIL: expected at least 3 occurrences of 'resumes from detected state' in bin/rite, got $_count"
    return 1
  }
}
