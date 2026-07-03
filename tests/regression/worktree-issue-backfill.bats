#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/issue-lock.sh, lib/utils/repo-status.sh
# tests/regression/worktree-issue-backfill.bats
#
# Regression test for: Backfill issue lock files for legacy worktrees (#91)
#
# Problem: Worktrees created before the lock infrastructure (PR #67, commit
# eb714e6) have no lock file, so `rite --status` cannot show issue associations
# for them.  The worktree → issue mapping relies on
# ${RITE_LOCK_DIR}/issue-N.lock/cwd, which only exists when acquire_issue_lock
# wrote it during a live workflow run.
#
# Fix: `backfill_worktree_locks` walks `git worktree list`, queries the open PR
# for each branch, extracts the "Closes #N" reference, and writes a minimal
# lock dir (cwd + backfill sentinel, no pid) for any worktree that is missing
# one.  `repo-status.sh` calls this before rendering the worktree-details
# panel, and also has a dedicated backfill-lock lookup path.
#
# Test scenarios:
# 1. Worktree without lock + branch has open PR with Closes #N
#    → backfill creates lock dir with cwd and backfill sentinel
# 2. Backfill is idempotent: calling it twice does not corrupt the lock
# 3. Live lock (with valid pid file) is NOT overwritten by backfill
# 4. Worktree whose branch has no PR → no lock file created (graceful skip)
# 5. backfill_worktree_locks exported function is present in issue-lock.sh
# 6. Static check: repo-status.sh calls backfill_worktree_locks
# 7. Static check: backfill-lock lookup is present in repo-status.sh

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

# ---------------------------------------------------------------------------
# Shared setup: minimal git repo with one worktree
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  # Create bare remote and fixture repo
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  # Set up environment
  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_LOCK_DIR="${RITE_PROJECT_ROOT}/.rite/locks"

  mkdir -p "$RITE_LOCK_DIR"
  mkdir -p "$RITE_PROJECT_ROOT/.rite"

  cd "$FIXTURE_REPO"

  # Create a feature branch and worktree (simulating pre-lock-infra worktree)
  BRANCH_NAME="feat/add-fault-injection"
  ISSUE_NUMBER=42

  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  echo "feature code" > feature.sh
  git add feature.sh
  git commit -m "Add fault injection" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  WORKTREE_PATH="${RITE_TEST_TMPDIR}/wt-feat"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1
  # Resolve to canonical path — git worktree list --porcelain reports the real path
  # (e.g. /private/var/... on macOS), while mktemp returns the symlink (/var/...).
  # Backfill writes the porcelain path to the cwd file, so tests must compare
  # against the same resolved form.
  _resolved="$(cd "$WORKTREE_PATH" && pwd -P 2>/dev/null || true)"
  [ -n "$_resolved" ] && WORKTREE_PATH="$_resolved"

  # Install a mock `gh` binary on PATH that returns a PR body with Closes #N.
  # The mock responds to: gh pr list --head <branch> ... with a JSON object
  # containing the branch's PR body.  All other gh calls return empty JSON.
  MOCK_BIN_DIR="${RITE_TEST_TMPDIR}/mock-bin"
  mkdir -p "$MOCK_BIN_DIR"

  # Write the mock gh script
  cat > "${MOCK_BIN_DIR}/gh" <<MOCK_SCRIPT
#!/usr/bin/env bash
# Mock gh binary for backfill tests
# Intercepts: gh pr list --head <branch> ...
# Returns a minimal PR JSON for the known branch; empty for everything else.

ARGS=("\$@")
CMD="\${ARGS[0]:-}"
SUBCMD="\${ARGS[1]:-}"

if [ "\$CMD" = "pr" ] && [ "\$SUBCMD" = "list" ]; then
  # Scan args for --head value
  _head_branch=""
  for (( i=0; i<\${#ARGS[@]}; i++ )); do
    if [ "\${ARGS[\$i]}" = "--head" ]; then
      _head_branch="\${ARGS[\$i+1]:-}"
    fi
  done

  if [ "\$_head_branch" = "${BRANCH_NAME}" ]; then
    # Return a fake PR that closes issue #${ISSUE_NUMBER}
    # Check if --jq flag is present (repo-status.sh uses --jq .[0] // empty)
    _has_jq_flag=false
    for _a in "\${ARGS[@]}"; do
      [ "\$_a" = "--jq" ] && _has_jq_flag=true
    done

    if [ "\$_has_jq_flag" = "true" ]; then
      # Return a single object (jq .[0] // empty pre-evaluated).
      # Note: body must not contain literal newlines — use valid JSON escaping.
      printf '{"number":101,"body":"Closes #${ISSUE_NUMBER} - feat implementation"}\n'
    else
      printf '[{"number":101,"body":"Closes #${ISSUE_NUMBER} - feat implementation"}]\n'
    fi
    exit 0
  fi

  # Unknown branch — return empty (jq path) or empty array
  _has_jq_flag=false
  for _a in "\${ARGS[@]}"; do
    [ "\$_a" = "--jq" ] && _has_jq_flag=true
  done
  [ "\$_has_jq_flag" = "true" ] && printf '' || printf '[]\n'
  exit 0
fi

# Default: return empty / success for all other gh subcommands
printf '[]'
exit 0
MOCK_SCRIPT
  chmod +x "${MOCK_BIN_DIR}/gh"

  # Prepend mock-bin to PATH so backfill_worktree_locks picks it up
  export PATH="${MOCK_BIN_DIR}:${PATH}"

  # Source the library under test
  source "${RITE_LIB_DIR}/utils/config.sh"
  source "${RITE_LIB_DIR}/utils/issue-lock.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  export BRANCH_NAME ISSUE_NUMBER WORKTREE_PATH MOCK_BIN_DIR
}

teardown() {
  # Return to a safe dir before removing test tmpdir
  cd / 2>/dev/null || true
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Test 1: backfill creates lock dir for legacy worktree
# ---------------------------------------------------------------------------

@test "backfill_worktree_locks: creates cwd lock for worktree without existing lock" {
  # Pre-condition: no lock file exists
  [ ! -d "${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock" ]

  # Run backfill
  run backfill_worktree_locks

  # Should succeed (best-effort, exit 0 always)
  [ "$status" -eq 0 ]

  # Lock dir must now exist
  [ -d "${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock" ]

  # cwd file must contain the worktree path
  [ -f "${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock/cwd" ]
  _cwd=$(cat "${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock/cwd")
  [ "$_cwd" = "$WORKTREE_PATH" ]

  # backfill sentinel must be present
  [ -f "${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock/backfill" ]

  # pid file must NOT be present (backfill does not write pid)
  [ ! -f "${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock/pid" ]
}

# ---------------------------------------------------------------------------
# Test 2: backfill is idempotent — calling it twice does not corrupt the lock
# ---------------------------------------------------------------------------

@test "backfill_worktree_locks: idempotent — second call does not corrupt cwd" {
  # First call
  backfill_worktree_locks

  _cwd_before=$(cat "${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock/cwd" 2>/dev/null || echo "")
  [ -n "$_cwd_before" ]

  # Second call
  run backfill_worktree_locks
  [ "$status" -eq 0 ]

  _cwd_after=$(cat "${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock/cwd" 2>/dev/null || echo "")

  # cwd must still point to the correct worktree path after second call
  [ "$_cwd_after" = "$WORKTREE_PATH" ]
}

# ---------------------------------------------------------------------------
# Test 3: live lock (with valid PID) is NOT overwritten by backfill
# ---------------------------------------------------------------------------

@test "backfill_worktree_locks: does NOT overwrite a live lock held by a running process" {
  local _lock_dir="${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock"
  mkdir -p "$_lock_dir"

  # Write a pid file pointing to a live PID (this shell)
  echo $$ > "${_lock_dir}/pid"
  # Write a cwd file with a DIFFERENT path to prove it's not overwritten
  echo "/some/other/path" > "${_lock_dir}/cwd"

  # Backfill should skip this lock since a live process holds it
  run backfill_worktree_locks
  [ "$status" -eq 0 ]

  # cwd must still be the original value, not overwritten
  _cwd=$(cat "${_lock_dir}/cwd")
  [ "$_cwd" = "/some/other/path" ]
}

# ---------------------------------------------------------------------------
# Test 4: worktree whose branch has no PR → no lock file created
# ---------------------------------------------------------------------------

@test "backfill_worktree_locks: gracefully skips worktree with no PR" {
  # Create a second worktree on a branch that the mock gh returns no PR for
  local _no_pr_branch="test/add-provider-swap"
  git checkout -b "$_no_pr_branch" main >/dev/null 2>&1
  git push -u origin "$_no_pr_branch" >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  local _no_pr_wt="${RITE_TEST_TMPDIR}/wt-no-pr"
  git worktree add "$_no_pr_wt" "$_no_pr_branch" >/dev/null 2>&1

  # Run backfill — the known branch gets a lock, the unknown branch does not
  run backfill_worktree_locks
  [ "$status" -eq 0 ]

  # No lock for any issue pointing to the no-PR worktree
  local _found_stray=false
  for _ld in "${RITE_LOCK_DIR}"/issue-*.lock; do
    [ -d "$_ld" ] || continue
    [ -f "$_ld/cwd" ] || continue
    _c=$(cat "$_ld/cwd" 2>/dev/null || true)
    if [ "$_c" = "$_no_pr_wt" ]; then
      _found_stray=true
      break
    fi
  done

  # No stray lock should have been created for the no-PR worktree
  [ "$_found_stray" = "false" ]

  # The known-branch lock was still created
  [ -d "${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock" ]
}

# ---------------------------------------------------------------------------
# Test 5: backfill_worktree_locks function is defined in issue-lock.sh
# ---------------------------------------------------------------------------

@test "issue-lock.sh: backfill_worktree_locks function is defined" {
  run bash -c "
    source '${RITE_REPO_ROOT}/lib/utils/issue-lock.sh'
    declare -f backfill_worktree_locks >/dev/null 2>&1
  "
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 6: static check — repo-status.sh calls backfill_worktree_locks
# ---------------------------------------------------------------------------

@test "repo-status.sh: calls backfill_worktree_locks in repo_wide_status" {
  run grep -c "backfill_worktree_locks" "${RITE_REPO_ROOT}/lib/utils/repo-status.sh"
  [ "$status" -eq 0 ]
  # Must appear at least once (the call site; may also appear in comment)
  [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 7: static check — backfill-lock lookup is present in repo-status.sh
# ---------------------------------------------------------------------------

@test "repo-status.sh: contains backfill-lock lookup path for worktree-details panel" {
  # The backfill-lock lookup checks for the 'backfill' sentinel file.
  # This grep confirms the lookup path was not accidentally removed.
  run grep -c 'backfill' "${RITE_REPO_ROOT}/lib/utils/repo-status.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]  # At least the call + the sentinel check
}
