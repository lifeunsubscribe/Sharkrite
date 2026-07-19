#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/integration-sync.sh, bin/rite
# tests/regression/sync-integration-branch.bats
#
# Regression tests for `rite --sync` (integration-sync.sh, #1041 + #1045).
#
# Test strategy: structural greps for the invariant contracts (no rebase in
# sync_integration_branch, force-with-lease in sync_issue_branch, no stash,
# no workflow entry, resolver guard, diag lines), plus behavioral bin/rite
# dispatch tests using the dry-run flag and bare-word alias, plus behavioral
# rail tests for the four issue-form safety rails using stubs.
#
# We do NOT test the live git merge/rebase path (requires a real git repo with
# remote state) — that is a network integration test. We test:
#   1. Arg validation (bare → all-repo plan, "main" refusal, mixed args)
#   2. Dry-run routing: issue form, all-repo form, branch form
#   3. Bare-word alias routing (rite sync <branch> == rite --sync <branch>)
#   4. Design-contract greps (no rebase in branch func, force-with-lease in
#      issue func, no stash, no workflow call, resolver guard, INTEGRATION_SYNC
#      and SYNC_ISSUE diag lines)
#   5. Issue-form safety rails: live-lock, dirty-tree, threshold, conflict
#   6. Ledger-absent safety for bare form

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  # Minimal fake project so bin/rite's config.sh can find RITE_PROJECT_ROOT.
  export _FAKE_PROJECT="$RITE_TEST_TMPDIR/fake-project"
  mkdir -p "$_FAKE_PROJECT/.rite"

  # Fake bin/ directory populated per-test with stubs.
  export _FAKE_BIN="$RITE_TEST_TMPDIR/fake-bin"
  mkdir -p "$_FAKE_BIN"

  # Symlink the real bin/rite into our fake bin/.
  ln -sf "$RITE_REPO_ROOT/bin/rite" "$_FAKE_BIN/rite"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# _run_rite ARGS...
#   Runs bin/rite under a minimal environment: RITE_LIB_DIR from the real lib,
#   RITE_PROJECT_ROOT from a fake project dir, logging off.
# ---------------------------------------------------------------------------
_run_rite() {
  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" "$@" < /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Test 1: --sync with no args prints the all-repo dry-run plan (NOT a usage error).
# Updated by #1045: bare --sync is the all-repo form, not an error.
# ---------------------------------------------------------------------------
@test "--sync with no args prints the all-repo plan (dry-run)" {
  _run_rite --dry-run --sync

  # Must exit zero: bare --sync is a valid all-repo form
  [ "$status" -eq 0 ]

  # Must mention the all-repo sync function
  echo "$output" | grep -qi "sync_all_repos\|all.*ledger\|integration.*branch\|in-flight"
}

# ---------------------------------------------------------------------------
# Test 2: --sync main is refused.
# ---------------------------------------------------------------------------
@test "--sync main is refused with explanatory error" {
  _run_rite --sync main || true

  [ "$status" -ne 0 ]
  # Error must mention that syncing main is not allowed / meaningless
  echo "$output" | grep -qi "main"
}

# ---------------------------------------------------------------------------
# Test 3: --dry-run --sync <branch> prints a branch-form sync plan (no side effects).
# ---------------------------------------------------------------------------
@test "--dry-run --sync demo-branch prints integration-sync plan" {
  _run_rite --dry-run --sync demo-branch

  [ "$status" -eq 0 ]
  # Dry-run plan must mention the integration-sync function and branch name
  echo "$output" | grep -qi "integration.sync\|sync_integration_branch"
  echo "$output" | grep -q "demo-branch"
}

# ---------------------------------------------------------------------------
# Test 4: Bare-word alias `rite sync <branch>` produces the same dry-run plan
#         as the flag form `rite --sync <branch>`.
# ---------------------------------------------------------------------------
@test "bare-word 'sync <branch>' produces same dry-run plan as '--sync <branch>'" {
  # Capture flag form
  _run_rite --dry-run --sync parity-branch
  local _flag_output="$output"
  local _flag_status="$status"

  # Capture bare-word form
  _run_rite --dry-run sync parity-branch
  local _bare_output="$output"
  local _bare_status="$status"

  # Both must succeed
  [ "$_flag_status" -eq 0 ]
  [ "$_bare_status" -eq 0 ]

  # Both must mention the same branch name and the same function
  echo "$_flag_output" | grep -q "parity-branch"
  echo "$_bare_output" | grep -q "parity-branch"
  echo "$_flag_output" | grep -qi "integration.sync\|sync_integration_branch"
  echo "$_bare_output" | grep -qi "integration.sync\|sync_integration_branch"
}

# ---------------------------------------------------------------------------
# Test 5: Bare-word `rite sync` (no branch) prints the all-repo plan.
# Updated by #1045: bare-word `sync` with no args = all-repo form, not an error.
# ---------------------------------------------------------------------------
@test "bare-word 'sync' with no args prints the all-repo plan (dry-run)" {
  _run_rite --dry-run sync

  # Must exit zero — all-repo form is valid
  [ "$status" -eq 0 ]

  # Must mention the all-repo sweep
  echo "$output" | grep -qi "sync_all_repos\|all.*ledger\|integration.*branch\|in-flight"
}

# ---------------------------------------------------------------------------
# Test 6: --dry-run --sync <N> prints the issue-form plan.
# ---------------------------------------------------------------------------
@test "--dry-run --sync 42 prints the issue-form plan naming issue 42" {
  _run_rite --dry-run --sync 42

  [ "$status" -eq 0 ]
  # Must mention the issue-form function and issue number
  echo "$output" | grep -qi "sync_issue_branch\|issue"
  echo "$output" | grep -q "42"
}

# ---------------------------------------------------------------------------
# Test 7: --dry-run --sync <N> <M> (multi-issue) prints a plan naming both issues.
# ---------------------------------------------------------------------------
@test "--dry-run --sync 42 57 prints the issue-form plan naming both issues" {
  _run_rite --dry-run --sync 42 57

  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "sync_issue_branch\|issue"
  echo "$output" | grep -q "42"
  echo "$output" | grep -q "57"
}

# ---------------------------------------------------------------------------
# Test 8: Mixed numeric + non-numeric args are rejected.
# ---------------------------------------------------------------------------
@test "--sync demo-branch 42 (mixed args) exits non-zero with usage message" {
  _run_rite --sync demo-branch 42 || true

  [ "$status" -ne 0 ]
  # Must mention the three valid forms
  echo "$output" | grep -qi "mixed\|branch\|issue\|usage\|three"
}

# ---------------------------------------------------------------------------
# Test 9: No rebase in sync_integration_branch (design contract).
# The sync_issue_branch function DOES use rebase — only the integration-branch
# function must not.
# ---------------------------------------------------------------------------
@test "sync_integration_branch function body contains no 'git rebase' call" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  # Extract only the sync_integration_branch function body and check for rebase.
  local _rebase_count
  _rebase_count=$(sed -n '/^sync_integration_branch()/,/^}/p' "$_lib" | grep -c 'git rebase' || true)
  [ "$_rebase_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 10: sync_issue_branch contains force-with-lease (design contract).
# ---------------------------------------------------------------------------
@test "sync_issue_branch function body contains 'force-with-lease'" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  local _fwl_count
  _fwl_count=$(sed -n '/^sync_issue_branch()/,/^}/p' "$_lib" | grep -c 'force-with-lease' || true)
  [ "$_fwl_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 11: sync_issue_branch never calls workflow / resolver / verify paths.
# ---------------------------------------------------------------------------
@test "sync_issue_branch does not call workflow, resolver, or verify_post_merge" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  local _wf_count
  _wf_count=$(sed -n '/^sync_issue_branch()/,/^}/p' "$_lib" | \
    grep -cE 'attempt_claude_merge_resolution|verify_post_merge|run_workflow' || true)
  [ "$_wf_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 12: No git stash anywhere in integration-sync.sh.
# ---------------------------------------------------------------------------
@test "integration-sync.sh contains no 'git stash' call" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  local _stash_count
  _stash_count=$(grep -c 'git stash' "$_lib" || true)
  [ "$_stash_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 13: Resolver is availability-guarded (declare -f pattern, stale-branch style).
# ---------------------------------------------------------------------------
@test "integration-sync.sh guards resolver with 'declare -f attempt_claude_merge_resolution'" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  grep -q 'declare -f attempt_claude_merge_resolution' "$_lib"
}

# ---------------------------------------------------------------------------
# Test 14: INTEGRATION_SYNC diag line is emitted (grep for _diag call).
# ---------------------------------------------------------------------------
@test "integration-sync.sh emits INTEGRATION_SYNC diag line via _diag" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  grep -q 'INTEGRATION_SYNC' "$_lib"
}

# ---------------------------------------------------------------------------
# Test 15: SYNC_ISSUE diag line is emitted (grep for _diag call).
# ---------------------------------------------------------------------------
@test "integration-sync.sh emits SYNC_ISSUE diag line via _diag" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  grep -q 'SYNC_ISSUE' "$_lib"
}

# ---------------------------------------------------------------------------
# Test 16: --help includes all three --sync forms.
# ---------------------------------------------------------------------------
@test "--help output documents all three --sync forms" {
  _run_rite --help || true

  # All three --sync lines must appear
  echo "$output" | grep -q -- '--sync'
  # Issue form documented
  echo "$output" | grep -q -- '--sync N'
  # Bare form documented (bare --sync at end of line or followed by whitespace)
  echo "$output" | grep -qE -- '--sync\s*$|--sync\s+#'
}

# ---------------------------------------------------------------------------
# Test 17: Conflict resolver is called inside a subshell that cd's into the
#          sync worktree (structural grep — cwd contract).
# ---------------------------------------------------------------------------
@test "integration-sync.sh calls resolver inside a subshell with cd into sync worktree" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  grep -q 'cd "\$_sync_wt".*attempt_claude_merge_resolution\|( cd "\$_sync_wt"' "$_lib"
}

# ---------------------------------------------------------------------------
# Test 18: push_failed outcome for integration branch push errors (not conflict).
# ---------------------------------------------------------------------------
@test "integration-sync.sh emits push_failed diag outcome (not conflict) for push errors" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  local _count
  _count=$(grep -c 'outcome=push_failed' "$_lib" || true)
  [ "$_count" -ge 2 ]
  ! grep -A1 'print_error "Push failed' "$_lib" | grep -q 'outcome=conflict'
}

# ---------------------------------------------------------------------------
# Test 19: Live-lock rail — proven by bats with a stub.
#
# Strategy: build a minimal fake integration-sync.sh that overrides
# get_locked_issue_numbers to return the target issue number (simulating a
# live lock), then run the real sync_issue_branch and verify the outcome.
# We test the function directly via library sourcing to avoid needing a
# full git repo — the rail fires before any git/gh call.
# ---------------------------------------------------------------------------
@test "sync_issue_branch: live-lock rail skips the issue (outcome=skipped-lock)" {
  # Build a test harness that sources the real lib but overrides
  # get_locked_issue_numbers to simulate a live lock for issue 99.
  local _harness="$RITE_TEST_TMPDIR/test-live-lock.sh"
  cat > "$_harness" << 'HARNESS'
#!/bin/bash
set -euo pipefail
RITE_LIB_DIR="$1"
# Source only colour/logging/config basics
source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
source "$RITE_LIB_DIR/utils/colors.sh" 2>/dev/null || true
# Stub get_locked_issue_numbers to return issue 99 (live lock simulation).
# These stubs are defined BEFORE sourcing integration-sync.sh so the
# declare-f guards in integration-sync.sh skip sourcing those real libs.
get_locked_issue_numbers() { echo "99"; }
# Stub all git/gh calls that would fire after the rail
detect_pr_for_issue() { return 1; }
detect_worktree_for_pr() { return 1; }
git_fetch_safe() { echo "STUB_FETCH"; }
git() { echo "STUB_GIT $*"; }
get_commits_behind_main() { COMMITS_BEHIND_MAIN=0; }
resolve_target_branch() { echo "main"; RESOLVED_TARGET_BRANCH=main; }
backfill_worktree_locks() { return 0; }
verify_post_merge() { return 0; }
_diag() { echo "DIAG: $*"; }
# Source integration-sync.sh — its re-source guard checks sync_integration_branch
# which is NOT yet defined here, so real functions load. Pre-defined stubs above
# survive because integration-sync.sh's conditional sources use ! declare -f guards.
source "$RITE_LIB_DIR/utils/integration-sync.sh" 2>/dev/null || true
sync_issue_branch "99"
exit $?
HARNESS
  chmod +x "$_harness"

  run bash "$_harness" "$RITE_REPO_ROOT/lib" 2>&1
  set +u; set +o pipefail

  # Rail fires → exit 0 (skip is informational)
  [ "$status" -eq 0 ]
  # Output must say skipped-lock
  echo "$output" | grep -qi "live\|lock\|skipped"
  # DIAG must say skipped-lock
  echo "$output" | grep -q "DIAG:.*SYNC_ISSUE.*skipped-lock"
}

# ---------------------------------------------------------------------------
# Test 20: Dirty worktree rail — proven by bats with a stub.
#
# Strategy: source integration-sync.sh, override get_locked_issue_numbers to
# return nothing, provide a fake worktree path where `git diff` exits non-zero.
# ---------------------------------------------------------------------------
@test "sync_issue_branch: dirty-tree rail skips and emits skipped-dirty diag" {
  local _harness="$RITE_TEST_TMPDIR/test-dirty-rail.sh"
  # Build a minimal fake worktree with a tracked change
  local _fake_wt="$RITE_TEST_TMPDIR/fake-worktree"
  mkdir -p "$_fake_wt"

  cat > "$_harness" << HARNESS
#!/bin/bash
set -euo pipefail
RITE_LIB_DIR="\$1"
FAKE_WT="\$2"
source "\$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
source "\$RITE_LIB_DIR/utils/colors.sh" 2>/dev/null || true
# Stubs
get_locked_issue_numbers() { echo ""; }
detect_pr_for_issue() { PR_NUMBER="55"; PR_BRANCH="feature-55"; return 0; }
detect_worktree_for_pr() { WORKTREE_PATH="\$FAKE_WT"; return 0; }
# Override git to make dirty-check return non-zero.
# Normalize: strip leading -C <path> so stub works for both forms.
git() {
  if [ "\${1:-}" = "-C" ]; then shift 2; fi
  # git diff --quiet → exit 1 (dirty)
  if [ "\${1:-}" = "diff" ] && [ "\${2:-}" = "--quiet" ]; then
    return 1
  fi
  # git rev-parse --abbrev-ref HEAD → return branch name
  if [ "\${1:-}" = "rev-parse" ]; then
    echo "feature-55"
    return 0
  fi
  echo "STUB_GIT \$1 \${2:-}"
  return 0
}
_diag() { echo "DIAG: \$*"; }
resolve_target_branch() { echo "main"; RESOLVED_TARGET_BRANCH=main; }
git_fetch_safe() { return 0; }
get_commits_behind_main() { COMMITS_BEHIND_MAIN=2; }
backfill_worktree_locks() { return 0; }
verify_post_merge() { return 0; }
source "\$RITE_LIB_DIR/utils/integration-sync.sh" 2>/dev/null || true
sync_issue_branch "55"
exit \$?
HARNESS
  chmod +x "$_harness"

  run bash "$_harness" "$RITE_REPO_ROOT/lib" "$_fake_wt" 2>&1
  set +u; set +o pipefail

  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "uncommitted\|dirty\|WIP\|skipped"
  echo "$output" | grep -q "DIAG:.*SYNC_ISSUE.*skipped-dirty"
  # No stash must have been called
  ! echo "$output" | grep -qi "stash"
}

# ---------------------------------------------------------------------------
# Test 21: Threshold rail — proven by bats with a stub.
# Branch is 12 commits behind, threshold is 10 → skipped-threshold.
# ---------------------------------------------------------------------------
@test "sync_issue_branch: threshold rail skips at/above RITE_STALE_BRANCH_THRESHOLD" {
  local _harness="$RITE_TEST_TMPDIR/test-threshold-rail.sh"
  local _fake_wt="$RITE_TEST_TMPDIR/fake-wt-thresh"
  mkdir -p "$_fake_wt"

  cat > "$_harness" << HARNESS
#!/bin/bash
set -euo pipefail
RITE_LIB_DIR="\$1"
FAKE_WT="\$2"
export RITE_STALE_BRANCH_THRESHOLD=10
source "\$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
source "\$RITE_LIB_DIR/utils/colors.sh" 2>/dev/null || true
get_locked_issue_numbers() { echo ""; }
detect_pr_for_issue() { PR_NUMBER="77"; PR_BRANCH="feature-77"; return 0; }
detect_worktree_for_pr() { WORKTREE_PATH="\$FAKE_WT"; return 0; }
git() {
  if [ "\${1:-}" = "-C" ]; then shift 2; fi
  if [ "\${1:-}" = "diff" ] && [ "\${2:-}" = "--quiet" ]; then return 0; fi
  if [ "\${1:-}" = "diff" ] && [ "\${2:-}" = "--cached" ]; then return 0; fi
  if [ "\${1:-}" = "rev-parse" ]; then echo "feature-77"; return 0; fi
  echo "STUB_GIT \$1 \${2:-}"; return 0
}
_diag() { echo "DIAG: \$*"; }
resolve_target_branch() { echo "main"; RESOLVED_TARGET_BRANCH=main; }
git_fetch_safe() { return 0; }
# Report 12 commits behind (above threshold of 10)
get_commits_behind_main() { COMMITS_BEHIND_MAIN=12; }
backfill_worktree_locks() { return 0; }
verify_post_merge() { return 0; }
source "\$RITE_LIB_DIR/utils/integration-sync.sh" 2>/dev/null || true
sync_issue_branch "77"
exit \$?
HARNESS
  chmod +x "$_harness"

  run bash "$_harness" "$RITE_REPO_ROOT/lib" "$_fake_wt" 2>&1
  set +u; set +o pipefail

  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "threshold\|close-and-restart\|behind\|skipped"
  echo "$output" | grep -q "DIAG:.*SYNC_ISSUE.*skipped-threshold"
  # No rebase must have been attempted
  ! echo "$output" | grep -qi "rebasing\|STUB_GIT.*rebase"
}

# ---------------------------------------------------------------------------
# Test 22: Conflict rail — proven by bats with a stub.
# Git rebase fails; git rebase --abort is recorded; outcome=conflict; exit 0.
# ---------------------------------------------------------------------------
@test "sync_issue_branch: conflict rail aborts rebase, reports conflict, exits 0" {
  local _harness="$RITE_TEST_TMPDIR/test-conflict-rail.sh"
  local _fake_wt="$RITE_TEST_TMPDIR/fake-wt-conflict"
  mkdir -p "$_fake_wt"
  local _git_log="$RITE_TEST_TMPDIR/git-calls.log"

  cat > "$_harness" << HARNESS
#!/bin/bash
set -euo pipefail
RITE_LIB_DIR="\$1"
FAKE_WT="\$2"
GIT_LOG="\$3"
source "\$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
source "\$RITE_LIB_DIR/utils/colors.sh" 2>/dev/null || true
get_locked_issue_numbers() { echo ""; }
detect_pr_for_issue() { PR_NUMBER="88"; PR_BRANCH="feature-88"; return 0; }
detect_worktree_for_pr() { WORKTREE_PATH="\$FAKE_WT"; return 0; }
git() {
  # Normalize: strip leading -C <path> so stub works for both
  # `git <cmd>` and `git -C <path> <cmd>` forms.
  local _args=("\$@")
  if [ "\${1:-}" = "-C" ]; then
    shift 2  # skip -C and path
  fi
  echo "GIT:\$1 \${2:-}" >> "\$GIT_LOG"
  if [ "\${1:-}" = "diff" ] && [ "\${2:-}" = "--quiet" ]; then return 0; fi
  if [ "\${1:-}" = "diff" ] && [ "\${2:-}" = "--cached" ]; then return 0; fi
  if [ "\${1:-}" = "rev-parse" ] && [ "\${2:-}" = "--abbrev-ref" ]; then echo "feature-88"; return 0; fi
  if [ "\${1:-}" = "rev-parse" ] && [ "\${2:-}" = "--verify" ]; then return 0; fi
  # git rebase → fail (simulate conflict)
  if [ "\${1:-}" = "rebase" ] && [ "\${2:-}" != "--abort" ]; then return 1; fi
  # git rebase --abort → succeed (record it)
  if [ "\${1:-}" = "rebase" ] && [ "\${2:-}" = "--abort" ]; then return 0; fi
  return 0
}
_diag() { echo "DIAG: \$*"; }
resolve_target_branch() { echo "main"; RESOLVED_TARGET_BRANCH=main; }
git_fetch_safe() { return 0; }
get_commits_behind_main() { COMMITS_BEHIND_MAIN=3; }
backfill_worktree_locks() { return 0; }
verify_post_merge() { return 0; }
source "\$RITE_LIB_DIR/utils/integration-sync.sh" 2>/dev/null || true
sync_issue_branch "88"
exit \$?
HARNESS
  chmod +x "$_harness"

  run bash "$_harness" "$RITE_REPO_ROOT/lib" "$_fake_wt" "$_git_log" 2>&1
  set +u; set +o pipefail

  # Conflict is a skip (exit 0 — composable)
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "conflict\|aborted\|abort"
  echo "$output" | grep -q "DIAG:.*SYNC_ISSUE.*conflict"
  # git rebase --abort must have been called
  grep -q "GIT:rebase --abort" "$_git_log" || grep -q "GIT:-C.*rebase.*--abort" "$_git_log"
}

# ---------------------------------------------------------------------------
# Test 23: Bare form is ledger-absent-safe (no ${RITE_STATE_DIR}/integration-branches/
#          dir → Phase A reports zero items, exit 0).
# ---------------------------------------------------------------------------
@test "sync_all_repos: ledger-absent is a zero-item phase (exit 0, no error)" {
  local _harness="$RITE_TEST_TMPDIR/test-ledger-absent.sh"
  local _fake_state="$RITE_TEST_TMPDIR/fake-state"
  mkdir -p "$_fake_state"
  # Deliberately do NOT create integration-branches/ subdirectory

  cat > "$_harness" << HARNESS
#!/bin/bash
set -euo pipefail
RITE_LIB_DIR="\$1"
RITE_STATE_DIR="\$2"
RITE_LOCK_DIR="\$2/locks"
export RITE_STATE_DIR RITE_LOCK_DIR
source "\$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
source "\$RITE_LIB_DIR/utils/colors.sh" 2>/dev/null || true
# Pre-stub functions that the lib sources conditionally, so the guards
# (! declare -f) prevent their real sources from loading.
backfill_worktree_locks() { return 0; }
_diag() { echo "DIAG: \$*"; }
get_locked_issue_numbers() { echo ""; }
detect_pr_for_issue() { return 1; }
detect_worktree_for_pr() { return 1; }
resolve_target_branch() { echo "main"; RESOLVED_TARGET_BRANCH=main; }
get_commits_behind_main() { COMMITS_BEHIND_MAIN=0; }
git_fetch_safe() { return 0; }
verify_post_merge() { return 0; }
# Source integration-sync.sh — its re-source guard checks sync_integration_branch,
# which is NOT yet defined here, so the real functions load (including sync_all_repos).
RITE_SOURCE_FUNCTIONS_ONLY=1 source "\$RITE_LIB_DIR/utils/integration-sync.sh" 2>/dev/null || true
# Re-stub sub-sync functions AFTER sourcing so the re-source guard (based on
# sync_integration_branch) does not interfere. We override the real implementations
# with stubs to prevent them from doing git/network calls.
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: integration-sync.sh uses declare -f sync_integration_branch sentinel guard (function-sentinel), so stubs defined before source are preserved. But sync_integration_branch IS defined by the source, so we override it after.
sync_integration_branch() { echo "STUB_SYNC_BRANCH \$*"; return 0; }
sync_issue_branch() { echo "STUB_SYNC_ISSUE \$*"; return 0; }
sync_all_repos
exit \$?
HARNESS
  chmod +x "$_harness"

  run bash "$_harness" "$RITE_REPO_ROOT/lib" "$_fake_state" 2>&1
  set +u; set +o pipefail

  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "ledger.*absent\|empty\|no integration\|zero\|Phase A"
  # Phase A must not have called sync_integration_branch
  ! echo "$output" | grep -q "STUB_SYNC_BRANCH"
}
