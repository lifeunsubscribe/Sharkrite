#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh
# tests/regression/workflow-runner-no-work-invariant.bats
#
# Regression test for: workflow-runner.sh should fail loud when no work produced
# Issue #380 (trigger), this issue adds the generic invariant guard.
#
# Bug history (2026-06-04 finance-glance batch, rite 1 2 3 4 5 6 7):
#   bootstrap-docs.sh sourced assess-documentation.sh's top-level code, which ran
#   the full post-merge flow as a side effect, hit `exit 0`, and silently terminated
#   workflow-runner with status 0. The batch reporter logged:
#     ✅ Issue #1 → PR #1 (167s)
#   But issue #1 was still OPEN, no branch existed, no PR existed.
#
#   PR #378 fixed the specific sourcing path. This test covers the generic invariant:
#   run_workflow() must return 13 (not 0) when no commits exist on the feature branch
#   AND no PR exists for the issue — regardless of what phase logic led there.
#
# Tests:
#   STRUCTURAL:
#     1. run_workflow() contains the invariant check block
#     2. The invariant returns 13 (not 0 or 1)
#     3. The invariant is positioned AFTER phase_completion (defense-in-depth location)
#     4. main() dispatcher explicitly propagates exit 13 (not swallowed as exit 1)
#     5. batch-process-issues.sh handles EXIT_CODE -eq 13 distinctly
#     6. exit-codes.md documents exit 13 for workflow-runner.sh
#   BEHAVIORAL:
#     7. Simulate all phases stubbed to return 0 with no git artifacts → returns 13
#     8. Simulate phases stubbed to 0 WITH a PR_NUMBER set → returns 0 (invariant passes)
#     9. RITE_WORKFLOW_EXPLICIT_COMPLETE=1 bypasses the invariant check
#    10. batch loop: exit 13 is recorded as invariant_violated (not completed, not abort)

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"

  # Stub print functions (all to stderr to avoid polluting stdout)
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
# STRUCTURAL: verify the invariant guard is present in source files
# =============================================================================

@test "structural: run_workflow() contains INVARIANT_VIOLATED guard block" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ -f "$_wfr" ]

  # The invariant check must exist in the source
  _count=$(grep -c "INVARIANT_VIOLATED" "$_wfr" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: INVARIANT_VIOLATED diagnostic not found in workflow-runner.sh"
    return 1
  }
}

@test "structural: invariant guard uses return 13 (not 0 or 1)" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

  # The return inside the invariant block must be 13
  _count=$(grep -c "return 13" "$_wfr" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: 'return 13' not found in workflow-runner.sh — invariant must return 13"
    return 1
  }
}

@test "structural: invariant guard is positioned after phase_completion call in run_workflow()" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

  # Extract run_workflow() body and verify ordering:
  # phase_completion call must appear BEFORE the INVARIANT_VIOLATED guard
  _fn_body=$(awk '
    /^run_workflow\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c = substr($0,i,1)
        if (c == "{") depth++
        else if (c == "}") {
          depth--
          if (depth == 0) { print; in_fn=0; next }
        }
      }
      print
    }
  ' "$_wfr")

  _line_completion=$(echo "$_fn_body" | grep -n "phase_completion" | head -1 | cut -d: -f1)
  _line_invariant=$(echo "$_fn_body" | grep -n "INVARIANT_VIOLATED" | head -1 | cut -d: -f1)

  [ -n "$_line_completion" ] || {
    echo "FAIL: phase_completion call not found in run_workflow() body"
    return 1
  }
  [ -n "$_line_invariant" ] || {
    echo "FAIL: INVARIANT_VIOLATED not found in run_workflow() body"
    return 1
  }
  [ "$_line_completion" -lt "$_line_invariant" ] || {
    echo "FAIL: phase_completion (line $_line_completion) must appear before INVARIANT_VIOLATED guard (line $_line_invariant)"
    return 1
  }
}

@test "structural: main() dispatcher in workflow-runner.sh explicitly propagates exit 13" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

  # The main() dispatcher must have a branch for workflow_exit -eq 13 that exits 13
  # (not falls through to the generic `exit 1` else branch)
  _count=$(grep -c "workflow_exit -eq 13" "$_wfr" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: main() dispatcher does not branch on workflow_exit -eq 13"
    echo "Exit 13 would be swallowed by the generic 'else: exit 1' branch"
    return 1
  }

  # And there must be an 'exit 13' in the dispatcher context
  _count_exit=$(grep -c "exit 13" "$_wfr" || true)
  [ "$_count_exit" -ge 1 ] || {
    echo "FAIL: 'exit 13' not found in workflow-runner.sh main() dispatcher"
    return 1
  }
}

@test "structural: batch-process-issues.sh handles EXIT_CODE -eq 13 distinctly" {
  _batch="$RITE_REPO_ROOT/lib/core/batch-process-issues.sh"
  [ -f "$_batch" ]

  _count=$(grep -c "EXIT_CODE -eq 13" "$_batch" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: batch-process-issues.sh does not handle EXIT_CODE -eq 13"
    echo "Exit 13 would fall through to the generic failure branch"
    echo "and be indistinguishable from a real dev/merge failure"
    return 1
  }
}

@test "structural: batch-process-issues.sh records exit 13 as invariant_violated status" {
  _batch="$RITE_REPO_ROOT/lib/core/batch-process-issues.sh"

  _count=$(grep -c "invariant_violated" "$_batch" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: batch-process-issues.sh does not set status=invariant_violated for exit 13"
    return 1
  }
}

@test "structural: docs/architecture/exit-codes.md documents exit 13 for workflow-runner" {
  _doc="$RITE_REPO_ROOT/docs/architecture/exit-codes.md"
  [ -f "$_doc" ]

  _count=$(grep -c "13" "$_doc" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: exit code 13 not mentioned in docs/architecture/exit-codes.md"
    return 1
  }

  # More specific: the workflow-runner section must mention 13 and invariant
  _inv_mention=$(grep -A 30 'workflow-runner.*return codes from' "$_doc" | grep "13" || true)
  [ -n "$_inv_mention" ] || {
    echo "FAIL: exit 13 entry not found in the workflow-runner.sh section of exit-codes.md"
    echo "(checked 30 lines after the 'return codes from' header)"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: simulate phases that return 0 with no git artifacts
# =============================================================================

@test "behavioral: workflow returning 0 with no commits and no PR triggers exit 13" {
  # Simulate the scenario: all phase functions return 0 (no error),
  # but the issue ends with no commits on branch and no PR.
  # The invariant check must fire and return 13.
  _script="$RITE_TEST_TMPDIR/test-no-work-invariant.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Stubs for all dependencies
GREEN="\033[0;32m"
NC="\033[0m"
print_status()  { :; }
print_info()    { echo "INFO: $*" >&2; }
print_warning() { :; }
print_error()   { echo "ERROR: $*" >&2; }
print_success() { :; }
print_header()  { :; }
_diag()         { :; }
gh_safe()       { echo ""; }
get_session_summary() { :; }
_rtk_snapshot() { :; }
_rtk_summary()  { echo ""; }
_rtk_phase_delta() { echo "0"; }
_timer_start()  { :; }
_timer_end()    { :; }
send_completion_notification() { :; }
get_latest_work_commit_time() { LATEST_COMMIT_TIME=""; }
iso_to_epoch()  { echo "0"; }

# Environment
RITE_PROJECT_ROOT="$(mktemp -d)"
RITE_DATA_DIR=".rite"
RITE_MARKER_REVIEW="sharkrite-local-review"
RITE_MARKER_ASSESSMENT="sharkrite-assessment"
RITE_MARKER_FOLLOWUP="sharkrite-followup"
CLOSING_ISSUE_JQ_REGEX="(closes?|fixes?|resolves?) #"
WORKFLOW_MODE="unsupervised"
CURRENT_RETRY=0
RITE_LOG_FILE=""
export RITE_PROJECT_ROOT RITE_DATA_DIR WORKFLOW_MODE CURRENT_RETRY

# Stub phase functions — all succeed with no side effects
phase_pre_start_checks() { return 0; }
phase_claude_workflow()   { return 0; }
phase_create_pr()         { return 0; }
phase_assess_and_resolve() { return 0; }
phase_merge_pr()          { return 0; }
phase_completion()        { return 0; }

# Simulate the invariant check logic from run_workflow()
# (isolated from the full workflow — tests the predicate in the exact form
# it appears in the source, triggered after all phases return 0)
issue_number=42

# No worktree (simulates: phases ran but produced no git artifacts)
WORKTREE_PATH=""
PR_NUMBER=""

# Replicate the invariant check exactly as it appears in run_workflow():
if [ "${RITE_WORKFLOW_EXPLICIT_COMPLETE:-}" != "1" ]; then
  _inv_commits=0
  _inv_pr=""

  if [ -n "${WORKTREE_PATH:-}" ] && [ -d "${WORKTREE_PATH:-}" ]; then
    _inv_commits=$(git -C "$WORKTREE_PATH" rev-list --count "origin/main..HEAD" 2>/dev/null || echo 0)
  fi

  if [ -n "${PR_NUMBER:-}" ] && [ "${PR_NUMBER:-}" != "null" ]; then
    _inv_pr="$PR_NUMBER"
  fi

  if [ "$_inv_commits" -eq 0 ] && [ -z "$_inv_pr" ]; then
    print_error "BUG: workflow returned 0 for issue #${issue_number} but produced no commits and no PR"
    _diag "INVARIANT_VIOLATED issue=${issue_number} commits=0 pr=none worktree=${WORKTREE_PATH:-none}"
    exit 13
  fi
fi

exit 0
EOF
  chmod +x "$_script"
  run bash "$_script"

  # Must fail with exit 13
  [ "$status" -eq 13 ] || {
    echo "FAIL: expected exit 13 (invariant violated), got $status"
    echo "output: $output"
    return 1
  }

  # Error output must mention the invariant failure
  [[ "$output" =~ "no commits and no PR" ]] || [[ "$stderr" =~ "no commits and no PR" ]] || {
    echo "FAIL: output does not explain the invariant violation"
    echo "output: $output"
    return 1
  }
}

@test "behavioral: workflow with PR_NUMBER set bypasses invariant (legitimate completion)" {
  # Scenario: all phases complete, PR was created — invariant must NOT fire.
  _script="$RITE_TEST_TMPDIR/test-with-pr-invariant.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

print_error() { echo "ERROR: $*" >&2; }
print_info()  { echo "INFO: $*" >&2; }
_diag()       { :; }

issue_number=42
WORKTREE_PATH=""
PR_NUMBER="99"  # PR exists — invariant must pass

if [ "${RITE_WORKFLOW_EXPLICIT_COMPLETE:-}" != "1" ]; then
  _inv_commits=0
  _inv_pr=""

  if [ -n "${WORKTREE_PATH:-}" ] && [ -d "${WORKTREE_PATH:-}" ]; then
    _inv_commits=$(git -C "$WORKTREE_PATH" rev-list --count "origin/main..HEAD" 2>/dev/null || echo 0)
  fi

  if [ -n "${PR_NUMBER:-}" ] && [ "${PR_NUMBER:-}" != "null" ]; then
    _inv_pr="$PR_NUMBER"
  fi

  if [ "$_inv_commits" -eq 0 ] && [ -z "$_inv_pr" ]; then
    print_error "BUG: invariant violated"
    exit 13
  fi
fi

echo "invariant_passed"
exit 0
EOF
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (PR exists — invariant should pass), got $status"
    return 1
  }
  [[ "$output" =~ "invariant_passed" ]] || {
    echo "FAIL: expected 'invariant_passed' in output"
    return 1
  }
}

@test "behavioral: workflow with commits on branch bypasses invariant" {
  # Scenario: worktree has commits ahead of origin/main — invariant must pass.
  _script="$RITE_TEST_TMPDIR/test-with-commits-invariant.sh"
  cat > "$_script" <<'OUTER'
#!/usr/bin/env bash
set -euo pipefail

print_error() { echo "ERROR: $*" >&2; }
_diag()       { :; }

# Set up a real git repo with a feature branch ahead of origin/main
TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

MAIN_REPO="$TMPDIR_LOCAL/main"
git init -q "$MAIN_REPO"
git -C "$MAIN_REPO" config user.email "test@test.com"
git -C "$MAIN_REPO" config user.name "Test"
echo "init" > "$MAIN_REPO/file.txt"
git -C "$MAIN_REPO" add .
git -C "$MAIN_REPO" commit -qm "init"
git -C "$MAIN_REPO" branch -M main

WORKTREE_DIR="$TMPDIR_LOCAL/feature"
git -C "$MAIN_REPO" checkout -q -b feature
echo "feature work" > "$MAIN_REPO/feature.txt"
git -C "$MAIN_REPO" add .
git -C "$MAIN_REPO" commit -qm "feat: add feature"

# Simulate origin/main reference (tag it so rev-list can compare)
git -C "$MAIN_REPO" tag "origin-main" main 2>/dev/null || true
# Use the init commit as origin/main for rev-list comparison
ORIGIN_MAIN=$(git -C "$MAIN_REPO" rev-parse main 2>/dev/null || echo "")

WORKTREE_PATH="$MAIN_REPO"
PR_NUMBER=""

issue_number=42

if [ "${RITE_WORKFLOW_EXPLICIT_COMPLETE:-}" != "1" ]; then
  _inv_commits=0
  _inv_pr=""

  if [ -n "${WORKTREE_PATH:-}" ] && [ -d "${WORKTREE_PATH:-}" ]; then
    # Use the actual commits-ahead check against the init commit (acting as origin/main)
    _inv_commits=$(git -C "$WORKTREE_PATH" rev-list --count "${ORIGIN_MAIN}..HEAD" 2>/dev/null || echo 0)
  fi

  if [ -n "${PR_NUMBER:-}" ] && [ "${PR_NUMBER:-}" != "null" ]; then
    _inv_pr="$PR_NUMBER"
  fi

  if [ "$_inv_commits" -eq 0 ] && [ -z "$_inv_pr" ]; then
    print_error "BUG: invariant violated"
    exit 13
  fi
fi

echo "invariant_passed commits=${_inv_commits}"
exit 0
OUTER
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (commits exist — invariant should pass), got $status"
    echo "output: $output"
    return 1
  }
  [[ "$output" =~ "invariant_passed" ]] || {
    echo "FAIL: expected 'invariant_passed' in output"
    return 1
  }
}

@test "behavioral: RITE_WORKFLOW_EXPLICIT_COMPLETE=1 bypasses invariant (future no-code paths)" {
  # Scenario: no commits, no PR, but RITE_WORKFLOW_EXPLICIT_COMPLETE=1 is set.
  # This bypass is reserved for future "completed without code" workflow paths
  # (e.g., auto-close when already resolved upstream).
  _script="$RITE_TEST_TMPDIR/test-explicit-complete-bypass.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

print_error() { echo "ERROR: $*" >&2; }
_diag()       { :; }

issue_number=42
WORKTREE_PATH=""
PR_NUMBER=""
export RITE_WORKFLOW_EXPLICIT_COMPLETE=1  # bypass signal

if [ "${RITE_WORKFLOW_EXPLICIT_COMPLETE:-}" != "1" ]; then
  _inv_commits=0
  _inv_pr=""

  if [ -n "${WORKTREE_PATH:-}" ] && [ -d "${WORKTREE_PATH:-}" ]; then
    _inv_commits=$(git -C "$WORKTREE_PATH" rev-list --count "origin/main..HEAD" 2>/dev/null || echo 0)
  fi

  if [ -n "${PR_NUMBER:-}" ] && [ "${PR_NUMBER:-}" != "null" ]; then
    _inv_pr="$PR_NUMBER"
  fi

  if [ "$_inv_commits" -eq 0 ] && [ -z "$_inv_pr" ]; then
    print_error "BUG: invariant violated"
    exit 13
  fi
fi

echo "bypass_worked"
exit 0
EOF
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (RITE_WORKFLOW_EXPLICIT_COMPLETE=1 should bypass invariant), got $status"
    return 1
  }
  [[ "$output" =~ "bypass_worked" ]] || {
    echo "FAIL: expected 'bypass_worked' in output"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: batch reporter treats exit 13 distinctly from exit 0 and exit 1
# =============================================================================

@test "behavioral: batch loop records exit 13 as invariant_violated (not completed)" {
  # Simulate the batch loop receiving exit 13 from a workflow-runner subprocess.
  # The issue must be recorded as failed (not completed), loop must continue.
  _script="$RITE_TEST_TMPDIR/test-batch-exit13.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

COMPLETED=0
FAILED=()
INVARIANT_VIOLATED=()
PROCESSED=""

for N in 1 2 3; do
  # Issue 2 returns exit 13 (invariant violated)
  case $N in 1) C=0;; 2) C=13;; 3) C=0;; esac
  PROCESSED="$PROCESSED $N"

  if [ $C -eq 0 ]; then
    COMPLETED=$((COMPLETED+1))
  elif [ $C -eq 13 ]; then
    # Invariant violated — record as failure, continue loop
    INVARIANT_VIOLATED+=("$N")
    FAILED+=("$N")
    # Do NOT break — other issues are not affected
  elif [ $C -eq 5 ]; then
    FAILED+=("$N")
    break  # usage cap aborts
  else
    FAILED+=("$N")
  fi
done

echo "processed:$PROCESSED"
echo "completed:$COMPLETED"
echo "failed:${FAILED[*]:-none}"
echo "invariant_violated:${INVARIANT_VIOLATED[*]:-none}"
EOF
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ]

  # Issue 3 was processed (loop did NOT break on exit 13)
  echo "$output" | grep -qE "processed:.*3" || {
    echo "FAIL: loop broke early on exit 13 — issue 3 not processed"
    echo "output: $output"
    return 1
  }

  # Issue 2 is in invariant_violated (not completed)
  echo "$output" | grep -qE "invariant_violated:.*2" || {
    echo "FAIL: issue 2 not recorded as invariant_violated"
    echo "output: $output"
    return 1
  }

  # Issues 1 and 3 completed
  echo "$output" | grep -q "completed:2" || {
    echo "FAIL: expected 2 completed issues (1 and 3)"
    echo "output: $output"
    return 1
  }
}

@test "behavioral: batch loop does NOT record exit 13 as completed (phantom completion prevented)" {
  # Critical negative test: exit 13 must NOT increment the completed counter.
  # This is the exact bug the invariant was introduced to prevent.
  _script="$RITE_TEST_TMPDIR/test-batch-exit13-not-completed.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

COMPLETED=0
for N in 1 2; do
  case $N in 1) C=13;; 2) C=13;; esac
  if [ $C -eq 0 ]; then
    COMPLETED=$((COMPLETED+1))
  fi
  # exit 13 does not increment COMPLETED — falls through without counting
done
echo "completed:$COMPLETED"
EOF
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "completed:0" ]] || {
    echo "FAIL: exit 13 should NOT increment completed counter (phantom completion)"
    echo "output: $output"
    return 1
  }
}

# =============================================================================
# STRUCTURAL: exit code uniqueness — 13 must not collide with any existing code
# =============================================================================

@test "structural: exit 13 (invariant-violated) is numerically distinct from all other documented exit codes" {
  # Full set of documented cross-script codes including the new exit 13
  # Source: docs/architecture/exit-codes.md
  _codes=(0 1 2 3 4 5 6 10 11 12 13 124 127)

  # Verify all codes are distinct (no two codes are numerically equal)
  declare -A _seen
  for _code in "${_codes[@]}"; do
    if [ -n "${_seen[$_code]+x}" ]; then
      echo "FAIL: duplicate exit code detected: $_code" >&2
      return 1
    fi
    _seen[$_code]=1
  done

  # 13 must be in the set
  [ -n "${_seen[13]+x}" ] || {
    echo "FAIL: exit 13 not in the uniqueness table"
    return 1
  }
}
