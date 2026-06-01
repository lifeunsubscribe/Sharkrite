#!/usr/bin/env bats
# tests/regression/worktree-issue-backfill.bats
#
# Regression tests for issue #91: Backfill worktree → issue lock files so rite --status
# shows issue associations for worktrees created before the lock infrastructure (PR #67).
#
# Tests cover:
# 1. backfill_worktree_locks() creates lock+metadata for a worktree with no lock file
#    when branch name encodes the issue number
# 2. backfill_worktree_locks() falls back to gh PR API lookup when branch name
#    doesn't contain an issue number
# 3. Already-locked issues (live PID) are skipped
# 4. Already-backfilled entries with correct path are skipped (idempotent)
# 5. lookup_issue_for_worktree() finds the issue from the backfill metadata
# 6. acquire_issue_lock() reclaims a backfill lock dir (no pid file) gracefully

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  # Create a minimal git repo so config.sh's detect_project_root() succeeds
  git init --quiet "$RITE_TEST_TMPDIR/repo"
  cd "$RITE_TEST_TMPDIR/repo"
  git config user.email "test@example.com"
  git config user.name "Test User"
  echo "# repo" > README.md
  git add README.md
  git commit -m "init" --quiet

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/repo"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_INSTALL_DIR="${RITE_REPO_ROOT}"
  export RITE_WORKTREE_BASE="$RITE_TEST_TMPDIR/wt-base"
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/locks"

  mkdir -p "$RITE_LOCK_DIR"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: create a fake worktree directory with a branch symref
# ---------------------------------------------------------------------------
_make_fake_worktree() {
  local wt_path="$1"
  local branch="$2"
  mkdir -p "$wt_path"
  # Create a minimal .git file that points back to the main repo
  # (real worktrees have this; git worktree list reads it)
  echo "gitdir: $RITE_TEST_TMPDIR/repo/.git/worktrees/$(basename "$wt_path")" > "$wt_path/.git"
}

# ---------------------------------------------------------------------------
# Helper: mock git worktree list --porcelain output
# Creates a bash function override for git inside the test subprocess
# ---------------------------------------------------------------------------
_git_mock_porcelain() {
  local main_path="$1"
  shift
  # Each subsequent pair: wt_path branch
  local output="worktree $main_path
HEAD abc123
branch refs/heads/main

"
  while [ $# -ge 2 ]; do
    local wt_path="$1"
    local wt_branch="$2"
    shift 2
    output+="worktree $wt_path
HEAD def456
branch refs/heads/$wt_branch

"
  done
  echo "$output"
}

# ---------------------------------------------------------------------------
# 1. Branch name encodes issue number → backfill creates lock+metadata
# ---------------------------------------------------------------------------

@test "backfill: branch name issue-42 creates lock dir and metadata files" {
  local wt_path="$RITE_TEST_TMPDIR/wt/fix-something-issue-42"
  mkdir -p "$wt_path"

  # Inject a mock git that returns porcelain with our fake worktree.
  # Paths are expanded at write time (unquoted MOCKEOF) so the mock script
  # contains literal path strings rather than variable references.
  local mock_git="$RITE_TEST_TMPDIR/mock-bin/git"
  mkdir -p "$(dirname "$mock_git")"
  local _main_path="$RITE_TEST_TMPDIR/repo"
  local _wt_path_42="$wt_path"
  cat > "$mock_git" <<MOCKEOF
#!/usr/bin/env bash
if [[ "\$*" == *"worktree list --porcelain"* ]]; then
  printf 'worktree %s\nHEAD abc123\nbranch refs/heads/main\n\n' '${_main_path}'
  printf 'worktree %s\nHEAD def456\nbranch refs/heads/fix-something-issue-42\n\n' '${_wt_path_42}'
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKEOF
  chmod +x "$mock_git"

  run bash -c "
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='$RITE_DATA_DIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_LOCK_DIR='$RITE_LOCK_DIR'
    export PATH='$(dirname "$mock_git"):\$PATH'
    source '$RITE_LIB_DIR/utils/config.sh'
    source '$RITE_LIB_DIR/utils/issue-lock.sh'
    backfill_worktree_locks
    echo 'EXIT:'\$?
  "

  [ "$status" -eq 0 ]

  # Lock dir must exist
  [ -d "$RITE_LOCK_DIR/issue-42.lock" ]

  # Metadata files must be written
  [ -f "$RITE_LOCK_DIR/issue-42.lock/worktree" ]
  [ -f "$RITE_LOCK_DIR/issue-42.lock/branch" ]
  [ -f "$RITE_LOCK_DIR/issue-42.lock/backfilled" ]

  # Worktree file must contain the correct path
  local stored_path
  stored_path=$(cat "$RITE_LOCK_DIR/issue-42.lock/worktree")
  [ "$stored_path" = "$wt_path" ]

  # No pid file (backfill lock must NOT block acquire_issue_lock)
  [ ! -f "$RITE_LOCK_DIR/issue-42.lock/pid" ]
}

# ---------------------------------------------------------------------------
# 2. Branch name without issue number → gh API fallback → creates lock
# ---------------------------------------------------------------------------

@test "backfill: gh API fallback for branch without issue number in name" {
  local wt_path="$RITE_TEST_TMPDIR/wt/feat-add-fault-injection"
  mkdir -p "$wt_path"

  # Mock git returning a worktree with no issue number in branch
  local mock_git="$RITE_TEST_TMPDIR/mock-bin/git"
  mkdir -p "$(dirname "$mock_git")"
  cat > "$mock_git" <<MOCKEOF
#!/usr/bin/env bash
if [[ "\$*" == *"worktree list --porcelain"* ]]; then
  printf 'worktree %s\nHEAD abc123\nbranch refs/heads/main\n\n' '$RITE_TEST_TMPDIR/repo'
  printf 'worktree %s\nHEAD def456\nbranch refs/heads/feat-add-fault-injection\n\n' '$wt_path'
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKEOF
  chmod +x "$mock_git"

  # Mock gh returning a PR with closingIssuesReferences
  local mock_gh="$RITE_TEST_TMPDIR/mock-bin/gh"
  cat > "$mock_gh" <<'MOCKEOF'
#!/usr/bin/env bash
# Return a PR with closingIssuesReferences when asked for the feat branch
if [[ "$*" == *"pr list"* ]] && [[ "$*" == *"feat-add-fault-injection"* ]] && [[ "$*" == *"closingIssuesReferences"* ]]; then
  printf '{"number":55,"closingIssuesReferences":[{"number":77}]}'
  exit 0
fi
exit 0
MOCKEOF
  chmod +x "$mock_gh"

  run bash -c "
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='$RITE_DATA_DIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_LOCK_DIR='$RITE_LOCK_DIR'
    export PATH='$(dirname "$mock_git"):\$PATH'
    source '$RITE_LIB_DIR/utils/config.sh'
    source '$RITE_LIB_DIR/utils/issue-lock.sh'
    backfill_worktree_locks
  "

  [ "$status" -eq 0 ]
  [ -d "$RITE_LOCK_DIR/issue-77.lock" ]
  [ -f "$RITE_LOCK_DIR/issue-77.lock/worktree" ]

  local stored_path
  stored_path=$(cat "$RITE_LOCK_DIR/issue-77.lock/worktree")
  [ "$stored_path" = "$wt_path" ]
}

# ---------------------------------------------------------------------------
# 3. Live lock exists (real PID) → skip, don't overwrite
# ---------------------------------------------------------------------------

@test "backfill: live lock (numeric PID, live process) is not overwritten" {
  local wt_path="$RITE_TEST_TMPDIR/wt/fix-something-issue-55"
  mkdir -p "$wt_path"

  # Pre-create a live lock dir with the current shell's PID
  local live_lock_dir="$RITE_LOCK_DIR/issue-55.lock"
  mkdir -p "$live_lock_dir"
  echo $$ > "$live_lock_dir/pid"  # Current shell PID — definitely live

  local mock_git="$RITE_TEST_TMPDIR/mock-bin/git"
  mkdir -p "$(dirname "$mock_git")"
  cat > "$mock_git" <<MOCKEOF
#!/usr/bin/env bash
if [[ "\$*" == *"worktree list --porcelain"* ]]; then
  printf 'worktree %s\nHEAD abc123\nbranch refs/heads/main\n\n' '$RITE_TEST_TMPDIR/repo'
  printf 'worktree %s\nHEAD def456\nbranch refs/heads/fix-something-issue-55\n\n' '$wt_path'
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKEOF
  chmod +x "$mock_git"

  run bash -c "
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='$RITE_DATA_DIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_LOCK_DIR='$RITE_LOCK_DIR'
    export PATH='$(dirname "$mock_git"):\$PATH'
    source '$RITE_LIB_DIR/utils/config.sh'
    source '$RITE_LIB_DIR/utils/issue-lock.sh'
    backfill_worktree_locks
  "

  [ "$status" -eq 0 ]

  # The backfilled marker must NOT have been written (live lock preserved)
  [ ! -f "$live_lock_dir/backfilled" ]

  # PID file must still contain the original live PID
  local stored_pid
  stored_pid=$(cat "$live_lock_dir/pid")
  [ "$stored_pid" = "$$" ]
}

# ---------------------------------------------------------------------------
# 4. Already-backfilled with correct path → idempotent (no re-write)
# ---------------------------------------------------------------------------

@test "backfill: idempotent — already-backfilled entry with correct path is not re-written" {
  local wt_path="$RITE_TEST_TMPDIR/wt/fix-issue-60"
  mkdir -p "$wt_path"

  # Pre-create correct backfill
  local lock_dir="$RITE_LOCK_DIR/issue-60.lock"
  mkdir -p "$lock_dir"
  echo "$wt_path" > "$lock_dir/worktree"
  echo "fix-issue-60" > "$lock_dir/branch"
  echo "backfill" > "$lock_dir/backfilled"
  local orig_mtime
  orig_mtime=$(stat -f '%m' "$lock_dir/worktree" 2>/dev/null || stat -c '%Y' "$lock_dir/worktree" 2>/dev/null)

  local mock_git="$RITE_TEST_TMPDIR/mock-bin/git"
  mkdir -p "$(dirname "$mock_git")"
  cat > "$mock_git" <<MOCKEOF
#!/usr/bin/env bash
if [[ "\$*" == *"worktree list --porcelain"* ]]; then
  printf 'worktree %s\nHEAD abc123\nbranch refs/heads/main\n\n' '$RITE_TEST_TMPDIR/repo'
  printf 'worktree %s\nHEAD def456\nbranch refs/heads/fix-issue-60\n\n' '$wt_path'
  exit 0
fi
exec /usr/bin/git "\$@"
MOCKEOF
  chmod +x "$mock_git"

  # Small sleep to ensure mtime would differ if re-written
  sleep 1

  run bash -c "
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='$RITE_DATA_DIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_LOCK_DIR='$RITE_LOCK_DIR'
    export PATH='$(dirname "$mock_git"):\$PATH'
    source '$RITE_LIB_DIR/utils/config.sh'
    source '$RITE_LIB_DIR/utils/issue-lock.sh'
    backfill_worktree_locks
  "

  [ "$status" -eq 0 ]

  # mtime must not have changed
  local new_mtime
  new_mtime=$(stat -f '%m' "$lock_dir/worktree" 2>/dev/null || stat -c '%Y' "$lock_dir/worktree" 2>/dev/null)
  [ "$orig_mtime" = "$new_mtime" ]
}

# ---------------------------------------------------------------------------
# 5. lookup_issue_for_worktree finds issue from backfill metadata
# ---------------------------------------------------------------------------

@test "lookup_issue_for_worktree: returns correct issue number from lock dir" {
  local wt_path="$RITE_TEST_TMPDIR/wt/feat-xyz"
  mkdir -p "$wt_path"

  # Pre-create backfill lock entry
  local lock_dir="$RITE_LOCK_DIR/issue-88.lock"
  mkdir -p "$lock_dir"
  echo "$wt_path" > "$lock_dir/worktree"
  echo "feat-xyz" > "$lock_dir/branch"
  echo "backfill" > "$lock_dir/backfilled"

  run bash -c "
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='$RITE_DATA_DIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_LOCK_DIR='$RITE_LOCK_DIR'
    source '$RITE_LIB_DIR/utils/config.sh'
    source '$RITE_LIB_DIR/utils/issue-lock.sh'
    if lookup_issue_for_worktree '$wt_path'; then
      echo \"FOUND:\$BACKFILL_ISSUE_NUMBER\"
    else
      echo 'NOT_FOUND'
    fi
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"FOUND:88"* ]]
}

@test "lookup_issue_for_worktree: returns 1 when no lock dir matches" {
  run bash -c "
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='$RITE_DATA_DIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_LOCK_DIR='$RITE_LOCK_DIR'
    source '$RITE_LIB_DIR/utils/config.sh'
    source '$RITE_LIB_DIR/utils/issue-lock.sh'
    if lookup_issue_for_worktree '/nonexistent/path'; then
      echo 'FOUND'
    else
      echo 'NOT_FOUND'
    fi
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT_FOUND"* ]]
}

# ---------------------------------------------------------------------------
# 6. acquire_issue_lock reclaims backfill lock (no pid file) gracefully
# ---------------------------------------------------------------------------

@test "acquire_issue_lock: reclaims backfill lock dir that has no pid file" {
  # Pre-create a backfill lock (no pid file — as backfill_worktree_locks writes it)
  local lock_dir="$RITE_LOCK_DIR/issue-99.lock"
  mkdir -p "$lock_dir"
  echo "/some/worktree" > "$lock_dir/worktree"
  echo "some-branch"   > "$lock_dir/branch"
  echo "backfill"      > "$lock_dir/backfilled"
  # Deliberately NO pid file

  run bash -c "
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='$RITE_DATA_DIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_LOCK_DIR='$RITE_LOCK_DIR'
    source '$RITE_LIB_DIR/utils/config.sh'
    source '$RITE_LIB_DIR/utils/issue-lock.sh'

    # acquire_issue_lock must succeed (reclaim the backfill lock)
    acquire_issue_lock 99
    echo 'ACQUIRED'
    release_issue_lock 99
    echo 'RELEASED'
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"ACQUIRED"* ]]
  [[ "$output" == *"RELEASED"* ]]

  # Lock dir must be cleaned up after release
  [ ! -d "$lock_dir" ]
}
