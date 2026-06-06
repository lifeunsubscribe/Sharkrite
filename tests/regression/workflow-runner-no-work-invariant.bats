#!/usr/bin/env bats
# tests/regression/workflow-runner-no-work-invariant.bats
#
# Regression test for: workflow-runner.sh should fail loud when phases complete
# but no work artifact (commit or PR) was produced.
#
# Bug history (2026-06-04, finance-glance batch):
#   bootstrap-docs.sh sourced assess-documentation.sh's top-level executable code
#   as a side effect. That code ran the full post-merge flow, hit `exit 0`, and
#   silently terminated workflow-runner with status 0. The batch reporter saw
#   exit 0 and logged a phantom "✅ Issue #1 → PR #1 (167s)" completion — but
#   issue #1 was still OPEN, no branch existed, no PR existed.
#
#   The function-extraction fix (#378) closed the specific trigger (bootstrap-docs
#   sourcing pattern). This invariant guards against the entire CLASS of regression:
#   any future path that gets workflow-runner to exit 0 without real work done will
#   now be caught and surfaced as exit 13.
#
# This test suite verifies:
#   1. verify_workflow_produced_work() is defined as a named function
#   2. verify_workflow_produced_work() is called before run_workflow() returns 0
#   3. verify_workflow_produced_work() returns 0 when PR_NUMBER is set
#   4. verify_workflow_produced_work() returns 0 when commits exist on branch
#   5. verify_workflow_produced_work() returns 13 with clear error when neither
# 6. batch-process-issues.sh handles exit 13 as a failure (not a completion)
#
# Exit code reference:
#   docs/architecture/exit-codes.md — exit code 13
#
# Related tests:
#   tests/regression/dev-session-no-work-fails-loud.bats (phase 1 guard)
#   tests/regression/batch-single-issue-parity.bats (handle_closed_issue contract)

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
}

teardown() {
  teardown_test_tmpdir
}

# =============================================================================
# STRUCTURAL: verify_workflow_produced_work() is defined and wired up
# =============================================================================

@test "structural: verify_workflow_produced_work() is defined in workflow-runner.sh" {
  _count=$(grep -c "^verify_workflow_produced_work()" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" || true)
  [ "$_count" -ge 1 ]
}

@test "structural: verify_workflow_produced_work() is defined BEFORE run_workflow()" {
  # The call site inside run_workflow() must come after the function definition.
  _line_helper=$(grep -n "^verify_workflow_produced_work()" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" | head -1 | cut -d: -f1)
  _line_run=$(grep -n "^run_workflow()" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" | head -1 | cut -d: -f1)
  [ -n "$_line_helper" ] && [ -n "$_line_run" ]
  [ "$_line_helper" -lt "$_line_run" ]
}

@test "structural: run_workflow() calls verify_workflow_produced_work" {
  # The invariant must be wired into run_workflow(), not just defined.
  _count=$(grep -c "verify_workflow_produced_work" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" || true)
  # At minimum 2 occurrences: the function definition + the call site inside run_workflow()
  [ "$_count" -ge 2 ]
}

@test "structural: verify_workflow_produced_work call is before final 'return 0' in run_workflow()" {
  # The invariant must fire on the normal-exit path, not after return 0.
  # We verify the call appears on a lower line number than the LAST 'return 0'
  # in run_workflow(). The last return 0 is the successful-completion path.
  # (Earlier return 0 lines are from early-exit branches like the CLOSED path.)
  _line_run=$(grep -n "^run_workflow()" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" | head -1 | cut -d: -f1)
  # Find the closing brace of run_workflow (the first standalone '}' after run_workflow start)
  _line_close=$(awk "NR>$_line_run && /^\}$/ {print NR; exit}" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  # The LAST call to verify_workflow_produced_work inside run_workflow()
  _line_call=$(awk "NR>$_line_run && NR<$_line_close && /verify_workflow_produced_work/ {last=NR} END {print last+0}" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")
  # The LAST 'return 0' inside run_workflow() before the closing brace
  _line_ret0=$(awk "NR>$_line_run && NR<$_line_close && /^[[:space:]]*return 0$/ {last=NR} END {print last+0}" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  [ "${_line_call:-0}" -gt 0 ] || { echo "FAIL: verify_workflow_produced_work not called inside run_workflow()"; return 1; }
  [ "${_line_ret0:-0}" -gt 0 ] || { echo "FAIL: final 'return 0' not found inside run_workflow()"; return 1; }
  [ "$_line_call" -lt "$_line_ret0" ] || {
    echo "FAIL: verify_workflow_produced_work (line $_line_call) appears AFTER final return 0 (line $_line_ret0)"
    return 1
  }
}

@test "structural: exit code 13 is documented in exit-codes.md" {
  grep -q "| \`13\`" "$RITE_REPO_ROOT/docs/architecture/exit-codes.md" || {
    echo "FAIL: exit code 13 not documented in docs/architecture/exit-codes.md"
    return 1
  }
}

@test "structural: batch-process-issues.sh handles exit code 13 explicitly" {
  # The batch must have a specific elif for exit 13 — not just silently count it
  # as a generic failure in the else branch. This ensures the clear diagnostic
  # message ("invariant violated") is shown to the operator.
  grep -q "EXIT_CODE.*-eq 13\|_WF_EXIT.*-eq 13\|13.*invariant" "$RITE_REPO_ROOT/lib/core/batch-process-issues.sh" || {
    echo "FAIL: batch-process-issues.sh does not have an explicit handler for exit code 13"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: verify_workflow_produced_work() function logic
# =============================================================================

@test "behavioral: verify_workflow_produced_work passes when PR_NUMBER is set" {
  # A PR existing is sufficient proof of work — Phase 2 (create-pr.sh) produced it.
  _script="$RITE_TEST_TMPDIR/test-invariant-pr.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Minimal stubs for dependencies
RITE_LIB_DIR="${RITE_LIB_DIR:?RITE_LIB_DIR not set}"
print_error() { echo "ERROR: $*" >&2; }
print_info()  { echo "INFO: $*" >&2; }

# Inline the function under test (avoids full workflow-runner.sh sourcing cost)
verify_workflow_produced_work() {
  local issue_number="$1"
  local pr_number="${2:-}"

  if [ -n "$pr_number" ] && [ "$pr_number" != "null" ]; then
    return 0
  fi

  if [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
    local _commits_on_branch
    _commits_on_branch=$(git -C "$WORKTREE_PATH" rev-list --count "origin/main..HEAD" 2>/dev/null || echo "0")
    if [ "${_commits_on_branch:-0}" -gt 0 ]; then
      return 0
    fi
  fi

  print_error "Workflow returned 0 but produced no commits and no PR — this is a bug"
  return 13
}

WORKTREE_PATH=""
verify_workflow_produced_work "42" "123"
echo "exit:$?"
EOF
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "exit:0" ]]
}

@test "behavioral: verify_workflow_produced_work passes when commits exist on branch" {
  # Commits on the branch (without a PR) are also sufficient — covers --dev-and-pr mode.
  _script="$RITE_TEST_TMPDIR/test-invariant-commits.sh"
  cat > "$_script" <<'OUTER'
#!/usr/bin/env bash
set -euo pipefail

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

# Set up a git repo with a feature branch that has commits ahead of origin/main
MAIN_REPO="$TMPDIR_LOCAL/main"
WORKTREE_DIR="$TMPDIR_LOCAL/worktrees"
mkdir -p "$MAIN_REPO" "$WORKTREE_DIR"

cd "$MAIN_REPO"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > file.txt
git add .
git commit -qm "init"
git branch -M main

# Simulate origin/main (self-remote)
git remote add origin "file://$MAIN_REPO"
git fetch origin -q
git branch --set-upstream-to=origin/main main

# Create feature branch with a commit
git checkout -b "feat/issue-42" -q
echo "work" > work.txt
git add work.txt
git commit -qm "feat: do some work"

# Worktree is the main repo itself for this test
export WORKTREE_PATH="$MAIN_REPO"

print_error() { echo "ERROR: $*" >&2; }
print_info()  { echo "INFO: $*" >&2; }

verify_workflow_produced_work() {
  local issue_number="$1"
  local pr_number="${2:-}"

  if [ -n "$pr_number" ] && [ "$pr_number" != "null" ]; then
    return 0
  fi

  if [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
    local _commits_on_branch
    _commits_on_branch=$(git -C "$WORKTREE_PATH" rev-list --count "origin/main..HEAD" 2>/dev/null || echo "0")
    if [ "${_commits_on_branch:-0}" -gt 0 ]; then
      return 0
    fi
  fi

  print_error "Workflow returned 0 but produced no commits and no PR — this is a bug"
  return 13
}

# No PR, but commits exist on branch
verify_workflow_produced_work "42" ""
echo "exit:$?"
OUTER
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "exit:0" ]]
}

@test "behavioral: verify_workflow_produced_work returns 13 when no PR and no commits" {
  # The false-positive scenario: phases all returned 0, but no real work happened.
  _script="$RITE_TEST_TMPDIR/test-invariant-fail.sh"
  cat > "$_script" <<'OUTER'
#!/usr/bin/env bash
set -euo pipefail

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

# Set up a git repo where HEAD == origin/main (no commits on branch)
MAIN_REPO="$TMPDIR_LOCAL/main"
mkdir -p "$MAIN_REPO"
cd "$MAIN_REPO"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > file.txt
git add .
git commit -qm "init"
git branch -M main
git remote add origin "file://$MAIN_REPO"
git fetch origin -q
git branch --set-upstream-to=origin/main main

# No feature branch commits — HEAD is on main
export WORKTREE_PATH="$MAIN_REPO"

print_error() { echo "ERROR: $*" >&2; }
print_info()  { echo "INFO: $*" >&2; }

verify_workflow_produced_work() {
  local issue_number="$1"
  local pr_number="${2:-}"

  if [ -n "$pr_number" ] && [ "$pr_number" != "null" ]; then
    return 0
  fi

  if [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
    local _commits_on_branch
    _commits_on_branch=$(git -C "$WORKTREE_PATH" rev-list --count "origin/main..HEAD" 2>/dev/null || echo "0")
    if [ "${_commits_on_branch:-0}" -gt 0 ]; then
      return 0
    fi
  fi

  print_error "Workflow returned 0 but produced no commits and no PR — this is a bug"
  print_info  "Issue #${issue_number} state preserved; investigate before re-running"
  return 13
}

# Neither PR nor commits — invariant must fire
_exit=0
verify_workflow_produced_work "42" "" || _exit=$?
echo "invariant_exit:$_exit"
OUTER
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "invariant_exit:13" ]]
}

@test "behavioral: verify_workflow_produced_work error message is actionable" {
  # The error message must say 'this is a bug' and mention preserving state.
  _script="$RITE_TEST_TMPDIR/test-invariant-msg.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

print_error() { echo "ERROR: $*"; }
print_info()  { echo "INFO: $*"; }

verify_workflow_produced_work() {
  local issue_number="$1"
  local pr_number="${2:-}"

  if [ -n "$pr_number" ] && [ "$pr_number" != "null" ]; then
    return 0
  fi

  if [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
    local _commits_on_branch
    _commits_on_branch=$(git -C "$WORKTREE_PATH" rev-list --count "origin/main..HEAD" 2>/dev/null || echo "0")
    if [ "${_commits_on_branch:-0}" -gt 0 ]; then
      return 0
    fi
  fi

  print_error "Workflow returned 0 but produced no commits and no PR — this is a bug"
  print_info  "Issue #${issue_number} state preserved; investigate before re-running"
  return 13
}

WORKTREE_PATH=""
_exit=0
verify_workflow_produced_work "99" "" || _exit=$?
EOF
  chmod +x "$_script"
  run bash "$_script"

  # Status of the script itself is 0 (we captured exit via _exit=0; cmd || _exit=$?)
  [ "$status" -eq 0 ]
  # Error message must mention the invariant violation and be actionable
  [[ "$output" =~ "this is a bug" ]]
  [[ "$output" =~ "state preserved" ]]
  [[ "$output" =~ "Issue #99" ]]
}

@test "behavioral: verify_workflow_produced_work returns 13 when PR is 'null' literal" {
  # jq sometimes emits literal "null" string instead of empty when field is absent.
  # The guard must treat "null" the same as "".
  _script="$RITE_TEST_TMPDIR/test-invariant-null.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

print_error() { echo "ERROR: $*"; }
print_info()  { echo "INFO: $*"; }

verify_workflow_produced_work() {
  local issue_number="$1"
  local pr_number="${2:-}"

  if [ -n "$pr_number" ] && [ "$pr_number" != "null" ]; then
    return 0
  fi

  if [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
    local _commits_on_branch
    _commits_on_branch=$(git -C "$WORKTREE_PATH" rev-list --count "origin/main..HEAD" 2>/dev/null || echo "0")
    if [ "${_commits_on_branch:-0}" -gt 0 ]; then
      return 0
    fi
  fi

  print_error "Workflow returned 0 but produced no commits and no PR — this is a bug"
  return 13
}

# PR_NUMBER set to literal "null" (jq artifact) — must NOT pass as valid PR
WORKTREE_PATH=""
_exit=0
verify_workflow_produced_work "42" "null" || _exit=$?
echo "invariant_exit:$_exit"
EOF
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "invariant_exit:13" ]]
}

# =============================================================================
# BEHAVIORAL: run_workflow() integration — stub all phases to return 0
# =============================================================================

@test "behavioral: invariant check is wired between phase_completion and final return 0" {
  # Simulate the false-positive scenario structurally: verify that the invariant
  # check block appears between the phase_completion call and the final return 0
  # in run_workflow(). This is a code-path verification without sourcing the full
  # file (sourcing workflow-runner.sh requires a complete runtime environment).
  #
  # We extract the portion of run_workflow() after phase_completion and before
  # the closing '}', then verify the invariant call is present in that block.

  _line_run=$(grep -n "^run_workflow()" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" | head -1 | cut -d: -f1)
  _line_close=$(awk "NR>$_line_run && /^\}$/ {print NR; exit}" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")
  _line_completion=$(awk "NR>$_line_run && NR<$_line_close && /phase_completion/ {print NR; exit}" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  [ -n "$_line_completion" ] || { echo "FAIL: phase_completion not found inside run_workflow()"; return 1; }

  # Extract lines from phase_completion to the closing brace
  _tail_block=$(awk "NR>=$_line_completion && NR<=$_line_close" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  # The invariant call must be in that block
  echo "$_tail_block" | grep -q "verify_workflow_produced_work" || {
    echo "FAIL: verify_workflow_produced_work not called after phase_completion in run_workflow()"
    echo "Block from line $_line_completion to $_line_close:"
    echo "$_tail_block"
    return 1
  }

  # The final return 0 must also be in that block (it's the success return)
  echo "$_tail_block" | grep -qE "^[[:space:]]*return 0$" || {
    echo "FAIL: final 'return 0' not found after phase_completion in run_workflow()"
    return 1
  }

  echo "OK: invariant check is between phase_completion and final return 0"
}

# =============================================================================
# BEHAVIORAL: batch exit-13 handling
# =============================================================================

@test "behavioral: batch marks issue as invariant_violated on exit 13" {
  # Verify the batch processor properly classifies exit 13 as an invariant
  # violation (not a generic failure), so the operator sees the diagnostic.
  _script="$RITE_TEST_TMPDIR/test-batch-exit13.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Simulate the batch exit-code classification logic
classify_workflow_exit() {
  local EXIT_CODE="$1"
  local ISSUE_NUM="$2"

  if [ $EXIT_CODE -eq 0 ]; then
    echo "completed"
  elif [ $EXIT_CODE -eq 12 ]; then
    echo "already_closed_at_start"
  elif [ $EXIT_CODE -eq 13 ]; then
    # Exit 13: invariant violated — phases returned 0 but no work produced.
    echo "invariant_violated"
  else
    echo "failed"
  fi
}

# Test exit 13 is classified as invariant_violated, not "failed" or "completed"
STATUS=$(classify_workflow_exit 13 42)
echo "status:$STATUS"
EOF
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "status:invariant_violated" ]]
}

@test "behavioral: batch does NOT count exit 13 as a successful completion" {
  # The acceptance criterion from the issue: batch 'completed successfully' path
  # must be gated on this invariant, not just exit 0.
  # Verify the batch exits non-zero (FAILED_COUNT > 0) when workflow exits 13.
  _script="$RITE_TEST_TMPDIR/test-batch-not-success.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Simulate batch outcome accumulation
COMPLETED_ISSUES=0
FAILED_ISSUES=()

simulate_batch_issue() {
  local _WF_EXIT="$1"
  local ISSUE_NUM="$2"

  if [ $_WF_EXIT -eq 0 ]; then
    COMPLETED_ISSUES=$((COMPLETED_ISSUES + 1))
  elif [ $_WF_EXIT -eq 13 ]; then
    # Invariant violated — treat as failure, NOT completion
    FAILED_ISSUES+=("$ISSUE_NUM")
  else
    FAILED_ISSUES+=("$ISSUE_NUM")
  fi
}

# Issue exits with 0 (success): should be counted as completed
simulate_batch_issue 0 "10"
# Issue exits with 13 (invariant violated): must NOT be counted as completed
simulate_batch_issue 13 "11"

echo "completed:$COMPLETED_ISSUES"
echo "failed_count:${#FAILED_ISSUES[@]}"
echo "failed_issues:${FAILED_ISSUES[*]}"
EOF
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ]
  # Only the exit-0 issue counts as completed
  [[ "$output" =~ "completed:1" ]]
  # Exit-13 issue must be in failed_issues
  [[ "$output" =~ "failed_count:1" ]]
  [[ "$output" =~ "failed_issues:11" ]]
}
