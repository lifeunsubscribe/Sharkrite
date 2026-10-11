#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/integration-sync.sh, bin/rite
# tests/regression/sync-integration-branch.bats
#
# Regression tests for `rite --sync <branch>` (integration-sync.sh, #1035).
#
# Test strategy: structural greps for the invariant contracts (no rebase,
# no force-push, resolver availability-guard), plus behavioral bin/rite
# dispatch tests using the dry-run flag and the bare-word alias.
#
# We do NOT test the live git merge path (requires a real git repo with
# remote state) — that is a network integration test. We test:
#   1. Arg validation (missing branch, "main" refusal)
#   2. Dry-run routing via --dry-run flag
#   3. Bare-word alias routing (rite sync <branch> == rite --sync <branch>)
#   4. Design-contract greps (no rebase, no force-push, resolver guard,
#      diag INTEGRATION_SYNC present)

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
# Test 1 (updated #1048): --sync with no args = bare all-repo sweep plan.
# Supersedes #1041's "missing arg → error" criterion: bare --sync is now the
# all-repo form and must succeed (exit 0) and print the sweep plan.
# ---------------------------------------------------------------------------
@test "--dry-run --sync with no args exits zero and prints all-repo sweep plan" {
  _run_rite --dry-run --sync

  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "sync_all_repos"
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
# Test 3: --dry-run --sync <branch> prints a sync execution plan (no side effects).
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
# Test 5 (updated #1048): bare-word `rite sync` (no args) = all-repo form.
# Supersedes the old "no arg → error" assertion.
# ---------------------------------------------------------------------------
@test "bare-word '--dry-run sync' with no args exits zero and prints all-repo plan" {
  _run_rite --dry-run sync

  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "sync_all_repos"
}

# ---------------------------------------------------------------------------
# Test 6: No rebase inside sync_integration_branch (design contract).
# Note: sync_issue_branch uses rebase intentionally — scope to integration fn.
# ---------------------------------------------------------------------------
@test "sync_integration_branch contains no 'git rebase' call (integration branches never rebased)" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  # Only the integration-branch function — sync_issue_branch rebases by design.
  ! sed -n '/^sync_integration_branch()/,/^}/p' "$_lib" | grep -n 'git rebase'
}

# ---------------------------------------------------------------------------
# Test 7: No force push inside sync_integration_branch (design contract).
# Note: sync_issue_branch uses --force-with-lease intentionally.
# ---------------------------------------------------------------------------
@test "sync_integration_branch contains no force-push option (plain push only)" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  ! sed -n '/^sync_integration_branch()/,/^}/p' "$_lib" | grep -nE 'force-with-lease|push (-f|--force)'
}

# ---------------------------------------------------------------------------
# Test 8: Resolver is availability-guarded (declare -f pattern, stale-branch style).
# ---------------------------------------------------------------------------
@test "integration-sync.sh guards resolver with 'declare -f attempt_claude_merge_resolution'" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  grep -q 'declare -f attempt_claude_merge_resolution' "$_lib"
}

# ---------------------------------------------------------------------------
# Test 9: INTEGRATION_SYNC diag line is emitted (grep for _diag call).
# ---------------------------------------------------------------------------
@test "integration-sync.sh emits INTEGRATION_SYNC diag line via _diag" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  grep -q 'INTEGRATION_SYNC' "$_lib"
}

# ---------------------------------------------------------------------------
# Test 10: --help includes --sync verb.
# ---------------------------------------------------------------------------
@test "--help output includes --sync verb" {
  _run_rite --help || true

  echo "$output" | grep -q -- '--sync'
}

# ---------------------------------------------------------------------------
# Test 11: Conflict resolver is called inside a subshell that cd's into the
#          sync worktree (structural grep — the cwd contract cannot be asserted
#          via output alone without a live git repo).
#
# stale-branch.sh:717 does `cd "$worktree_path"` before calling the resolver;
# integration-sync.sh must match that pattern exactly.  The canonical fix wraps
# the call in `( cd "$_sync_wt" && attempt_claude_merge_resolution ... )`.
# ---------------------------------------------------------------------------
@test "integration-sync.sh calls resolver inside a subshell with cd into sync worktree" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  # The resolver call must be preceded by a cd into $_sync_wt in the same subshell.
  # Pattern: ( cd "$_sync_wt" && attempt_claude_merge_resolution
  grep -q 'cd "\$_sync_wt".*attempt_claude_merge_resolution\|( cd "\$_sync_wt"' "$_lib"
}

# ---------------------------------------------------------------------------
# Test 12: push_failed outcome is emitted in diag for push failures (not
#          outcome=conflict, which would misattribute push/network errors).
# ---------------------------------------------------------------------------
@test "integration-sync.sh emits push_failed diag outcome (not conflict) for push errors" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  # At least two outcome=push_failed lines must be present (one per push site:
  # post-clean-merge push and post-resolution push).
  local _count
  _count=$(grep -c 'outcome=push_failed' "$_lib" || true)
  [ "$_count" -ge 2 ]
  # Lines that print "Push failed" must pair with push_failed, not conflict.
  # Extract the _diag call immediately following each "Push failed" print and
  # confirm none of them say outcome=conflict.
  ! grep -A1 'print_error "Push failed' "$_lib" | grep -q 'outcome=conflict'
}

# ===========================================================================
# Tests 13–24: #1048 — issue form, bare form, and sync_issue_branch rails
# ===========================================================================

# ---------------------------------------------------------------------------
# Test 13: --dry-run --sync with issue numbers prints issue-sync plan.
# ---------------------------------------------------------------------------
@test "--dry-run --sync with issue numbers prints issue-sync plan naming both issues" {
  _run_rite --dry-run --sync 42 57

  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "sync_issue_branch"
  echo "$output" | grep -q "42"
  echo "$output" | grep -q "57"
}

# ---------------------------------------------------------------------------
# Test 14: branch form dry-run unchanged by #1048.
# ---------------------------------------------------------------------------
@test "--dry-run --sync demo-branch still prints integration-sync plan (unchanged)" {
  _run_rite --dry-run --sync demo-branch

  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "sync_integration_branch"
  echo "$output" | grep -q "demo-branch"
}

# ---------------------------------------------------------------------------
# Test 15: Mixed args (branch + issue number) rejected.
# ---------------------------------------------------------------------------
@test "--dry-run --sync with mixed args exits non-zero" {
  _run_rite --dry-run --sync demo-branch 42 || true

  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Test 16: Structural — no 'git stash' in integration-sync.sh (dirty rail
#          never stashes; this is a permanent design invariant).
# ---------------------------------------------------------------------------
@test "integration-sync.sh contains no 'git stash' call (dirty rail never stashes)" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  local _count
  _count=$(grep -c 'git stash' "$_lib" || true)
  [ "$_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 17: Structural — sync_issue_branch uses --force-with-lease.
# ---------------------------------------------------------------------------
@test "sync_issue_branch uses --force-with-lease (rebase form only, not integration form)" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  local _count
  _count=$(sed -n '/^sync_issue_branch()/,/^}/p' "$_lib" | grep -c 'force-with-lease' || true)
  [ "$_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 18: Structural — sync_issue_branch does not invoke workflow machinery.
# ---------------------------------------------------------------------------
@test "sync_issue_branch contains no workflow invocations (run_workflow, claude resolver, verify_post_merge)" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  local _count
  _count=$(sed -n '/^sync_issue_branch()/,/^}/p' "$_lib" | grep -cE 'attempt_claude_merge_resolution|verify_post_merge|run_workflow' || true)
  [ "$_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 19: Structural — SYNC_ISSUE diag lines emitted by integration-sync.sh.
# ---------------------------------------------------------------------------
@test "integration-sync.sh emits SYNC_ISSUE diag lines via _diag" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  grep -q 'SYNC_ISSUE' "$_lib"
}

# ---------------------------------------------------------------------------
# Test 20: Live-lock rail — skips when issue has a live lock (PID is $$).
# ---------------------------------------------------------------------------
@test "sync_issue_branch reports skipped-lock when issue holds a live lock" {
  # Pre-stub all dep functions so integration-sync.sh skips sourcing them.
  get_locked_issue_numbers() { echo "99"; }
  detect_pr_for_issue() { return 1; }
  detect_worktree_for_pr() { return 1; }
  resolve_target_branch() { echo "main"; }
  get_commits_behind_main() { COMMITS_BEHIND_MAIN=0; }
  git_fetch_safe() { return 0; }
  backfill_worktree_locks() { return 0; }
  verify_post_merge() { return 0; }
  _diag() { true; }
  print_warning() { true; }
  print_info() { true; }
  print_success() { true; }
  print_status() { true; }
  print_error() { true; }
  print_header() { true; }

  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/locks"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/state"
  mkdir -p "$RITE_LOCK_DIR" "$RITE_STATE_DIR"

  source "$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  set +u; set +o pipefail

  sync_issue_branch "99"

  [ "${_SYNC_ISSUE_OUTCOME:-}" = "skipped-lock" ]
}

# ---------------------------------------------------------------------------
# Test 21: Dirty worktree rail — skips when worktree has uncommitted changes.
# ---------------------------------------------------------------------------
@test "sync_issue_branch reports skipped-dirty for a dirty worktree" {
  # Set up a real git repo as the fake worktree
  local _wt="$RITE_TEST_TMPDIR/dirty-wt"
  mkdir -p "$_wt"
  git -C "$_wt" init -b main >/dev/null 2>&1 || git -C "$_wt" init >/dev/null 2>&1
  git -C "$_wt" commit --allow-empty -m "init" >/dev/null 2>&1
  # Create an uncommitted tracked change
  echo "dirty" > "$_wt/dirty.txt"
  git -C "$_wt" add "$_wt/dirty.txt" >/dev/null 2>&1

  # Stub deps — return the fake worktree
  get_locked_issue_numbers() { true; }
  detect_pr_for_issue() { PR_NUMBER="101"; PR_BRANCH="feat/101"; return 0; }
  detect_worktree_for_pr() { WORKTREE_PATH="$_wt"; return 0; }
  resolve_target_branch() { echo "main"; }
  get_commits_behind_main() { COMMITS_BEHIND_MAIN=3; }
  git_fetch_safe() { return 0; }
  backfill_worktree_locks() { return 0; }
  verify_post_merge() { return 0; }
  _diag() { true; }
  print_warning() { true; }
  print_info() { true; }
  print_success() { true; }
  print_status() { true; }
  print_error() { true; }
  print_header() { true; }

  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/locks2"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/state2"
  mkdir -p "$RITE_LOCK_DIR" "$RITE_STATE_DIR"

  source "$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  set +u; set +o pipefail

  sync_issue_branch "101"

  [ "${_SYNC_ISSUE_OUTCOME:-}" = "skipped-dirty" ]
}

# ---------------------------------------------------------------------------
# Test 22: Staleness threshold rail — skips when behind ≥ threshold.
# ---------------------------------------------------------------------------
@test "sync_issue_branch reports skipped-threshold when behind >= RITE_STALE_BRANCH_THRESHOLD" {
  local _wt="$RITE_TEST_TMPDIR/stale-wt"
  mkdir -p "$_wt"
  git -C "$_wt" init -b main >/dev/null 2>&1 || git -C "$_wt" init >/dev/null 2>&1
  git -C "$_wt" commit --allow-empty -m "init" >/dev/null 2>&1

  get_locked_issue_numbers() { true; }
  detect_pr_for_issue() { PR_NUMBER="202"; PR_BRANCH="feat/202"; return 0; }
  detect_worktree_for_pr() { WORKTREE_PATH="$_wt"; return 0; }
  resolve_target_branch() { echo "main"; }
  # Behind count at/above default threshold of 10
  get_commits_behind_main() { COMMITS_BEHIND_MAIN=10; }
  git_fetch_safe() { return 0; }
  backfill_worktree_locks() { return 0; }
  verify_post_merge() { return 0; }
  _diag() { true; }
  print_warning() { true; }
  print_info() { true; }
  print_success() { true; }
  print_status() { true; }
  print_error() { true; }
  print_header() { true; }

  export RITE_STALE_BRANCH_THRESHOLD=10
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/locks3"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/state3"
  mkdir -p "$RITE_LOCK_DIR" "$RITE_STATE_DIR"

  source "$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  set +u; set +o pipefail

  sync_issue_branch "202"

  [ "${_SYNC_ISSUE_OUTCOME:-}" = "skipped-threshold" ]
}

# ---------------------------------------------------------------------------
# Test 23: Conflict rail — aborts rebase and reports "conflict" (exit 0).
# ---------------------------------------------------------------------------
@test "sync_issue_branch reports conflict and exits 0 when rebase fails" {
  local _wt="$RITE_TEST_TMPDIR/conflict-wt"
  mkdir -p "$_wt"
  git -C "$_wt" init -b main >/dev/null 2>&1 || git -C "$_wt" init >/dev/null 2>&1
  git -C "$_wt" config user.email "test@test.com" >/dev/null 2>&1
  git -C "$_wt" config user.name "Test" >/dev/null 2>&1
  git -C "$_wt" commit --allow-empty -m "init" >/dev/null 2>&1

  # Stub a fake origin/main that forces conflict
  git -C "$_wt" config advice.detachedHead false >/dev/null 2>&1 || true

  get_locked_issue_numbers() { true; }
  detect_pr_for_issue() { PR_NUMBER="303"; PR_BRANCH="feat/303"; return 0; }
  detect_worktree_for_pr() { WORKTREE_PATH="$_wt"; return 0; }
  resolve_target_branch() { echo "main"; }
  get_commits_behind_main() { COMMITS_BEHIND_MAIN=2; }
  # Stub git_fetch_safe to succeed; rebase fails via the PATH-stub git below
  git_fetch_safe() { return 0; }
  backfill_worktree_locks() { return 0; }
  verify_post_merge() { return 0; }
  _diag() { true; }
  print_warning() { true; }
  print_info() { true; }
  print_success() { true; }
  print_status() { true; }
  print_error() { true; }
  print_header() { true; }

  # Use a PATH-stub git that makes `git rebase` always fail (non-zero exit).
  # Locate real git first; write the stub with printf so $1/$@ are literal.
  local _stub_bin="$RITE_TEST_TMPDIR/stub-git-bin"
  local _real_git
  _real_git=$(command -v git)
  mkdir -p "$_stub_bin"
  printf '#!/bin/bash\nif [ "${1:-}" = "rebase" ] && [ "${2:-}" != "--abort" ]; then\n  exit 1\nfi\nexec "%s" "$@"\n' "$_real_git" > "$_stub_bin/git"
  chmod +x "$_stub_bin/git"

  export PATH="$_stub_bin:$PATH"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/locks4"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/state4"
  mkdir -p "$RITE_LOCK_DIR" "$RITE_STATE_DIR"

  source "$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  set +u; set +o pipefail

  # Overall exit must be 0 (conflict is a skip — composable)
  sync_issue_branch "303"
  local _rc=$?

  [ "$_rc" -eq 0 ]
  [ "${_SYNC_ISSUE_OUTCOME:-}" = "conflict" ]
}

# ---------------------------------------------------------------------------
# Test 24: Bare form is ledger-absent-safe (no ledger dir → phase A = zero items).
# Structural: verify the [ -d ] guard exists in sync_all_repos.
# ---------------------------------------------------------------------------
@test "sync_all_repos in integration-sync.sh is guarded with [ -d ] for the ledger dir" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  # Expect '[ -d "$_ledger_dir" ]' or equivalent pattern
  grep -q 'integration-branches' "$_lib"
  grep -q '\[ -d ' "$_lib"
}
