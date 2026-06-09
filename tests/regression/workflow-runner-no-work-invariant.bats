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

@test "structural: check_workflow_invariant() is defined in workflow-runner.sh" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ -f "$_wfr" ]

  # The invariant predicate must be extracted into a named function so tests
  # can call it directly without re-implementing it. Refactored in issue #429.
  _count=$(grep -c "^check_workflow_invariant()" "$_wfr" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: check_workflow_invariant() not found as a top-level function in workflow-runner.sh"
    return 1
  }
}

@test "structural: check_workflow_invariant() contains INVARIANT_VIOLATED diagnostic" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ -f "$_wfr" ]

  # The INVARIANT_VIOLATED _diag line must exist inside check_workflow_invariant()
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

@test "structural: check_workflow_invariant() does not hardcode origin/main (uses dynamic base branch)" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

  # Extract check_workflow_invariant() body and verify it does NOT contain the
  # hardcoded "origin/main" string — a regression guard for issues #365/#420/#429.
  # The function must use a dynamically resolved base branch (from PR baseRefName
  # or RITE_MAIN_BRANCH fallback) rather than assuming the target is always main.
  _fn_body=$(awk '
    /^check_workflow_invariant\(\)/ { in_fn=1; depth=0 }
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

  _hardcoded_count=$(echo "$_fn_body" | grep -cF '"origin/main"' || true)
  [ "$_hardcoded_count" -eq 0 ] || {
    echo "FAIL: check_workflow_invariant() contains hardcoded \"origin/main\" — re-introduced anti-pattern"
    echo "Use dynamic base branch resolution (PR baseRefName or RITE_MAIN_BRANCH fallback)"
    return 1
  }
}

@test "structural: check_workflow_invariant() is defined BEFORE run_workflow()" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

  # check_workflow_invariant() must be defined before run_workflow() calls it
  _line_helper=$(grep -n "^check_workflow_invariant()" "$_wfr" | head -1 | cut -d: -f1)
  _line_run=$(grep -n "^run_workflow()" "$_wfr" | head -1 | cut -d: -f1)

  [ -n "$_line_helper" ] || {
    echo "FAIL: check_workflow_invariant() not found in workflow-runner.sh"
    return 1
  }
  [ -n "$_line_run" ] || {
    echo "FAIL: run_workflow() not found in workflow-runner.sh"
    return 1
  }
  [ "$_line_helper" -lt "$_line_run" ] || {
    echo "FAIL: check_workflow_invariant() (line $_line_helper) must be defined before run_workflow() (line $_line_run)"
    return 1
  }
}

@test "structural: run_workflow() calls check_workflow_invariant after phase_completion" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

  # Extract run_workflow() body and verify ordering:
  # phase_completion call must appear BEFORE the check_workflow_invariant call
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
  _line_invariant=$(echo "$_fn_body" | grep -n "check_workflow_invariant" | head -1 | cut -d: -f1)

  [ -n "$_line_completion" ] || {
    echo "FAIL: phase_completion call not found in run_workflow() body"
    return 1
  }
  [ -n "$_line_invariant" ] || {
    echo "FAIL: check_workflow_invariant call not found in run_workflow() body"
    return 1
  }
  [ "$_line_completion" -lt "$_line_invariant" ] || {
    echo "FAIL: phase_completion (line $_line_completion) must appear before check_workflow_invariant (line $_line_invariant)"
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
# BEHAVIORAL: call the real check_workflow_invariant() from workflow-runner.sh
#
# These tests source workflow-runner.sh with all external calls stubbed and
# call check_workflow_invariant() directly. This ensures the predicate logic
# lives in exactly one place — the source file — and tests cannot drift from
# the implementation. Previously these tests re-implemented the predicate
# inline (anti-pattern fixed by this issue; see issue #429).
# =============================================================================

# Shared scaffold: source workflow-runner.sh with all dependency libs
# short-circuited so check_workflow_invariant() is callable without
# network or git access.
#
# Strategy: each lib in lib/utils/ and lib/providers/ has a re-source guard
# (either a _RITE_*_LOADED var or a declare -f sentinel).  We set those vars
# and pre-define those sentinel functions BEFORE sourcing workflow-runner.sh,
# so every "source RITE_LIB_DIR/..." call returns immediately.
# workflow-runner.sh checks "if [ -z RITE_LIB_DIR ]" before sourcing config.sh,
# so pre-setting RITE_LIB_DIR also prevents the config.sh source chain.
# workflow-runner.sh's own _RITE_WORKFLOW_RUNNER_LOADED guard is NOT set here
# so its function bodies (including check_workflow_invariant) ARE loaded.
#
# Written to a temp file and sourced by each behavioral test script.
_write_invariant_stubs() {
  local stub_file="$1"
  local rite_lib_dir="$2"
  cat > "$stub_file" <<STUBS
#!/usr/bin/env bash
set -euo pipefail

# ── Skip config.sh: pre-set RITE_LIB_DIR so workflow-runner.sh skips it ──
export RITE_LIB_DIR="$rite_lib_dir"
export RITE_PROJECT_ROOT="\${RITE_PROJECT_ROOT:-\$(mktemp -d)}"
export RITE_DATA_DIR=".rite"
export RITE_LOG_FILE=""
export WORKFLOW_MODE="unsupervised"
export CURRENT_RETRY=0
export RITE_MAX_RETRIES=3
export RITE_ASSESSMENT_TIMEOUT=300
export RITE_STALE_BRANCH_THRESHOLD=10
export RITE_WORKTREE_BASE="/tmp/rite-test-wt"
export RITE_WORKTREE_DIR="/tmp/rite-test-wt/stub-wt"
export RITE_LOCK_DIR="\$RITE_PROJECT_ROOT/.rite/locks"
export CLOSING_ISSUE_JQ_REGEX="(closes?|fixes?|resolves?) #"
export RITE_MARKER_REVIEW="sharkrite-local-review"
export RITE_MARKER_ASSESSMENT="sharkrite-assessment"
export RITE_MARKER_FOLLOWUP="sharkrite-followup"

# ── Skip dependency libs via their _RITE_*_LOADED re-source guards ──
export _RITE_NOTIFICATIONS_LOADED=true
export _RITE_BLOCKER_RULES_LOADED=true
export _RITE_SESSION_TRACKER_LOADED=true
export _RITE_REVIEW_HELPER_LOADED=true
export _RITE_COLORS_LOADED=true
export _RITE_LOGGING_LOADED=true
# timeout.sh guard: checks _RITE_TIMEOUT_CHECKED=true AND declare -f run_with_timeout
export _RITE_TIMEOUT_CHECKED=true

# ── Skip libs that use declare -f sentinel guards ──
# Pre-define the sentinel so each lib returns at its guard check.
build_changes_summary()          { :; }
normalize_existing_issue()       { :; }
rite_markers_loaded()            { :; }
detect_pr_for_issue()            { :; }
iso_to_epoch()                   { echo "0"; }
create_sharkrite_stash()         { :; }
check_and_rebase_against_main()  { :; }
run_test_gate()                  { return 0; }
ensure_timeout_cmd()             { :; }
# provider-interface.sh: stub its primary entry points
load_provider()                  { :; }
provider_name()                  { echo "stub"; }

# ── Stubs for functions called by workflow-runner.sh function bodies ──
print_status()   { :; }
print_info()     { echo "INFO: \$*" >&2; }
print_warning()  { :; }
print_error()    { echo "ERROR: \$*" >&2; }
print_success()  { :; }
print_header()   { :; }
print_step()     { :; }
_diag()          { :; }
_timer_start()   { :; }
_timer_end()     { :; }
_rtk_snapshot()  { :; }
_rtk_summary()   { echo ""; }
_rtk_phase_delta() { echo "0"; }
get_session_summary()            { :; }
send_completion_notification()   { :; }
get_latest_work_commit_time()    { LATEST_COMMIT_TIME=""; }
acquire_issue_lock()             { return 0; }
release_issue_lock()             { return 0; }
backfill_worktree_locks()        { :; }
setup_interrupt_handlers()       { :; }
run_with_timeout()               { shift; "\$@"; }
GREEN=""
NC=""
# gh_safe: default stub returns empty (no network calls in invariant check)
gh_safe() { echo ""; }
# git: pass-through — behavioral tests that need a real repo set up their own
STUBS
}

@test "behavioral: workflow returning 0 with no commits and no PR triggers exit 13" {
  # Scenario: all phase functions return 0 (no error), but the issue ends with
  # no commits on branch and no PR.  check_workflow_invariant() must return 13.
  # Uses the real function from workflow-runner.sh — no predicate re-implementation.
  _stubs="$RITE_TEST_TMPDIR/stubs.sh"
  _script="$RITE_TEST_TMPDIR/test-no-work-invariant.sh"
  _write_invariant_stubs "$_stubs" "$RITE_LIB_DIR"

  cat > "$_script" <<OUTER
#!/usr/bin/env bash
set -euo pipefail
source "$_stubs"

# Source workflow-runner.sh — stubs file above has pre-set all dependency lib
# guards so the transitive source chain returns immediately for each dep.
# workflow-runner.sh's own guard (_RITE_WORKFLOW_RUNNER_LOADED) is NOT set,
# so its function bodies including check_workflow_invariant() ARE defined.
# shellcheck disable=SC1091
source "$RITE_LIB_DIR/core/workflow-runner.sh"

# No worktree, no PR → invariant must fire
_result=0
check_workflow_invariant 42 "" "" || _result=\$?
exit \$_result
OUTER
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
  # Uses the real check_workflow_invariant() — no predicate re-implementation.
  _stubs="$RITE_TEST_TMPDIR/stubs.sh"
  _script="$RITE_TEST_TMPDIR/test-with-pr-invariant.sh"
  _write_invariant_stubs "$_stubs" "$RITE_LIB_DIR"

  cat > "$_script" <<OUTER
#!/usr/bin/env bash
set -euo pipefail
source "$_stubs"

# shellcheck disable=SC1091
source "$RITE_LIB_DIR/core/workflow-runner.sh"

# PR_NUMBER="99" → invariant must pass (PR exists is sufficient)
_result=0
check_workflow_invariant 42 "" "99" || _result=\$?
if [ \$_result -eq 0 ]; then
  echo "invariant_passed"
fi
exit \$_result
OUTER
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
  # Scenario: worktree has commits ahead of the base branch — invariant must pass.
  # Uses the real check_workflow_invariant() with a real git repo.
  # The base branch is resolved via RITE_MAIN_BRANCH fallback (no PR → no API call).
  _stubs="$RITE_TEST_TMPDIR/stubs.sh"
  _script="$RITE_TEST_TMPDIR/test-with-commits-invariant.sh"
  _write_invariant_stubs "$_stubs" "$RITE_LIB_DIR"

  cat > "$_script" <<OUTER
#!/usr/bin/env bash
set -euo pipefail
source "$_stubs"

# shellcheck disable=SC1091
source "$RITE_LIB_DIR/core/workflow-runner.sh"

# Set up a real git repo: "origin/main" as remote-tracking ref, feature branch
# with one commit ahead of it.  check_workflow_invariant() will detect the
# commit via rev-list --count "origin/main..HEAD" (RITE_MAIN_BRANCH falls back
# to "main" when no PR_NUMBER is supplied).
TMPDIR_LOCAL="\$(mktemp -d)"
trap 'rm -rf "\$TMPDIR_LOCAL"' EXIT

ORIGIN_REPO="\$TMPDIR_LOCAL/origin"
FEATURE_REPO="\$TMPDIR_LOCAL/feature"

# Create origin repo with a main branch
git init -q "\$ORIGIN_REPO"
git -C "\$ORIGIN_REPO" config user.email "test@test.com"
git -C "\$ORIGIN_REPO" config user.name "Test"
echo "init" > "\$ORIGIN_REPO/file.txt"
git -C "\$ORIGIN_REPO" add .
git -C "\$ORIGIN_REPO" commit -qm "init"
git -C "\$ORIGIN_REPO" branch -M main

# Clone into feature repo so origin/main tracking ref exists
git clone -q "\$ORIGIN_REPO" "\$FEATURE_REPO"
git -C "\$FEATURE_REPO" config user.email "test@test.com"
git -C "\$FEATURE_REPO" config user.name "Test"

# Add a feature commit ahead of origin/main
echo "feature work" > "\$FEATURE_REPO/feature.txt"
git -C "\$FEATURE_REPO" add .
git -C "\$FEATURE_REPO" commit -qm "feat: add feature"

# check_workflow_invariant with the feature worktree, no PR
# RITE_MAIN_BRANCH falls back to "main"; rev-list sees 1 commit ahead of origin/main
export RITE_MAIN_BRANCH=main
_result=0
check_workflow_invariant 42 "\$FEATURE_REPO" "" || _result=\$?
if [ \$_result -eq 0 ]; then
  echo "invariant_passed"
fi
exit \$_result
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
  # Uses the real check_workflow_invariant() — no predicate re-implementation.
  _stubs="$RITE_TEST_TMPDIR/stubs.sh"
  _script="$RITE_TEST_TMPDIR/test-explicit-complete-bypass.sh"
  _write_invariant_stubs "$_stubs" "$RITE_LIB_DIR"

  cat > "$_script" <<OUTER
#!/usr/bin/env bash
set -euo pipefail
source "$_stubs"

# shellcheck disable=SC1091
source "$RITE_LIB_DIR/core/workflow-runner.sh"

# RITE_WORKFLOW_EXPLICIT_COMPLETE=1: invariant must be bypassed even with no artifacts
export RITE_WORKFLOW_EXPLICIT_COMPLETE=1
_result=0
check_workflow_invariant 42 "" "" || _result=\$?
if [ \$_result -eq 0 ]; then
  echo "bypass_worked"
fi
exit \$_result
OUTER
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
