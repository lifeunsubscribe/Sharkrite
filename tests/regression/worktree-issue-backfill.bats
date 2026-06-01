#!/usr/bin/env bats
# tests/regression/worktree-issue-backfill.bats
#
# Regression tests for: Backfill worktree lock files with issue IDs
# Issue #91
#
# Tests the backfill_worktree_locks() function in lib/utils/issue-lock.sh.
#
# Scenarios covered:
# 1. Worktree exists without lock file + branch has open PR with Closes #N
#    → backfill creates lock dir with worktree file
# 2. Worktree that already has a lock dir is skipped (idempotent)
# 3. Worktree with no open PR is silently skipped
# 4. Main project root worktree is always skipped
# 5. Detached HEAD worktree (no branch) is skipped
# 6. Lock dir with pid but no worktree file gets worktree file added
# 7. repo-status.sh lock-based lookup: worktree file correctly maps to issue number

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  # Copy library files to test environment
  export RITE_ROOT_DIR="${RITE_TEST_TMPDIR}/rite-install"
  export RITE_LIB_DIR="${RITE_ROOT_DIR}/lib"
  export RITE_UTILS_DIR="${RITE_LIB_DIR}/utils"
  export RITE_CORE_DIR="${RITE_LIB_DIR}/core"
  export RITE_DATA_DIR=".rite"
  export RITE_PROJECT_ROOT="${RITE_TEST_TMPDIR}/test-project"
  export RITE_PROJECT_NAME="test-project"

  mkdir -p "$RITE_UTILS_DIR"
  mkdir -p "$RITE_CORE_DIR"
  mkdir -p "$RITE_PROJECT_ROOT/$RITE_DATA_DIR"

  cp "${RITE_REPO_ROOT}/lib/utils/config.sh" "$RITE_UTILS_DIR/"
  cp "${RITE_REPO_ROOT}/lib/utils/issue-lock.sh" "$RITE_UTILS_DIR/"

  # Lock dir defaults to $RITE_PROJECT_ROOT/.rite/locks (set by config.sh)
  export RITE_LOCK_DIR="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/locks"
  mkdir -p "$RITE_LOCK_DIR"

  # Mock print functions
  print_status()  { echo "$@" >&2; }
  print_warning() { echo "WARNING: $@" >&2; }
  print_error()   { echo "ERROR: $@" >&2; }
  export -f print_status print_warning print_error
}

teardown() {
  teardown_test_tmpdir
}

# =============================================================================
# Test 1: worktree with no lock file, open PR with Closes #N → lock created
# =============================================================================

@test "backfill creates lock dir for worktree with open PR that closes an issue" {
  local wt_path="${RITE_TEST_TMPDIR}/feat-worktree"
  mkdir -p "$wt_path"

  # Mock git to return a single non-main worktree
  local mock_bin="${RITE_TEST_TMPDIR}/mock-bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git" <<'MOCKGIT'
#!/bin/bash
if [[ "$*" == *"worktree list --porcelain"* ]]; then
  printf 'worktree %s\n' "${RITE_PROJECT_ROOT}"
  printf 'branch refs/heads/main\n'
  printf '\n'
  printf 'worktree %s\n' "${FEAT_WORKTREE_PATH}"
  printf 'branch refs/heads/feat/add-fault-injection\n'
  printf '\n'
  exit 0
fi
exit 0
MOCKGIT
  chmod +x "$mock_bin/git"

  # Mock gh to return an open PR with Closes #42 in the body
  cat > "$mock_bin/gh" <<'MOCKGH'
#!/bin/bash
# gh pr list --head feat/add-fault-injection --state open --json number,body --limit 1 --jq .[0] // empty
if [[ "$*" == *"pr list"* ]] && [[ "$*" == *"--head"* ]]; then
  printf '{"number":88,"body":"Closes #42\n\nAdds fault injection support."}'
  exit 0
fi
exit 0
MOCKGH
  chmod +x "$mock_bin/gh"

  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    export FEAT_WORKTREE_PATH='${wt_path}'
    export PATH='${mock_bin}:\${PATH}'

    source '${RITE_UTILS_DIR}/config.sh'
    source '${RITE_UTILS_DIR}/issue-lock.sh'

    backfill_worktree_locks

    # Verify lock dir was created
    [ -d '${RITE_LOCK_DIR}/issue-42.lock' ] || { echo 'FAIL: lock dir not created'; exit 1; }
    [ -f '${RITE_LOCK_DIR}/issue-42.lock/worktree' ] || { echo 'FAIL: worktree file not created'; exit 1; }

    # Verify worktree path is correct
    content=\$(cat '${RITE_LOCK_DIR}/issue-42.lock/worktree')
    [ \"\$content\" = '${wt_path}' ] || { echo \"FAIL: worktree file has wrong content: \$content\"; exit 1; }

    echo 'PASS'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"
}

# =============================================================================
# Test 2: existing lock dir with worktree file is left unchanged (idempotent)
# =============================================================================

@test "backfill is idempotent: existing lock dir with worktree file is not overwritten" {
  local wt_path="${RITE_TEST_TMPDIR}/feat-worktree"
  mkdir -p "$wt_path"

  # Pre-create lock dir with a different (stale) worktree path
  local lock_dir="${RITE_LOCK_DIR}/issue-42.lock"
  mkdir -p "$lock_dir"
  echo "/some/other/path" > "$lock_dir/worktree"

  local mock_bin="${RITE_TEST_TMPDIR}/mock-bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git" <<'MOCKGIT'
#!/bin/bash
if [[ "$*" == *"worktree list --porcelain"* ]]; then
  printf 'worktree %s\n' "${RITE_PROJECT_ROOT}"
  printf 'branch refs/heads/main\n'
  printf '\n'
  printf 'worktree %s\n' "${FEAT_WORKTREE_PATH}"
  printf 'branch refs/heads/feat/add-fault-injection\n'
  printf '\n'
  exit 0
fi
exit 0
MOCKGIT
  chmod +x "$mock_bin/git"

  # gh should NOT be called because the lock dir already exists
  # If it is called (and returns something), the test would still pass,
  # but we confirm the file content is unchanged.
  cat > "$mock_bin/gh" <<'MOCKGH'
#!/bin/bash
# This should NOT be called — existing lock dir skips the gh lookup
printf '{"number":99,"body":"Closes #42"}'
exit 0
MOCKGH
  chmod +x "$mock_bin/gh"

  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    export FEAT_WORKTREE_PATH='${wt_path}'
    export PATH='${mock_bin}:\${PATH}'

    source '${RITE_UTILS_DIR}/config.sh'
    source '${RITE_UTILS_DIR}/issue-lock.sh'

    backfill_worktree_locks

    # Lock dir must still exist
    [ -d '${lock_dir}' ] || { echo 'FAIL: lock dir was removed'; exit 1; }

    # Worktree file content must not be overwritten
    content=\$(cat '${lock_dir}/worktree')
    [ \"\$content\" = '/some/other/path' ] || { echo \"FAIL: worktree file was overwritten: \$content\"; exit 1; }

    echo 'PASS'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"
}

# =============================================================================
# Test 3: worktree with no open PR is silently skipped
# =============================================================================

@test "backfill silently skips worktree with no open PR" {
  local wt_path="${RITE_TEST_TMPDIR}/orphan-worktree"
  mkdir -p "$wt_path"

  local mock_bin="${RITE_TEST_TMPDIR}/mock-bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git" <<'MOCKGIT'
#!/bin/bash
if [[ "$*" == *"worktree list --porcelain"* ]]; then
  printf 'worktree %s\n' "${RITE_PROJECT_ROOT}"
  printf 'branch refs/heads/main\n'
  printf '\n'
  printf 'worktree %s\n' "${ORPHAN_WT_PATH}"
  printf 'branch refs/heads/feat/orphan-branch\n'
  printf '\n'
  exit 0
fi
exit 0
MOCKGIT
  chmod +x "$mock_bin/git"

  # gh returns empty — no open PR for this branch
  cat > "$mock_bin/gh" <<'MOCKGH'
#!/bin/bash
# No PR found
printf ''
exit 0
MOCKGH
  chmod +x "$mock_bin/gh"

  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    export ORPHAN_WT_PATH='${wt_path}'
    export PATH='${mock_bin}:\${PATH}'

    source '${RITE_UTILS_DIR}/config.sh'
    source '${RITE_UTILS_DIR}/issue-lock.sh'

    backfill_worktree_locks

    # No lock dirs should exist (main project root lock would be wrong too)
    lock_count=\$(ls '${RITE_LOCK_DIR}' 2>/dev/null | grep -c 'issue-' || true)
    [ \"\$lock_count\" = '0' ] || { echo \"FAIL: unexpected lock dir count: \$lock_count\"; exit 1; }

    echo 'PASS'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"
}

# =============================================================================
# Test 4: main project root is always skipped
# =============================================================================

@test "backfill skips the main project root worktree" {
  local mock_bin="${RITE_TEST_TMPDIR}/mock-bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git" <<'MOCKGIT'
#!/bin/bash
if [[ "$*" == *"worktree list --porcelain"* ]]; then
  # Only the main worktree — no feature worktrees
  printf 'worktree %s\n' "${RITE_PROJECT_ROOT}"
  printf 'branch refs/heads/main\n'
  printf '\n'
  exit 0
fi
exit 0
MOCKGIT
  chmod +x "$mock_bin/git"

  # gh must NOT be called for the main worktree
  cat > "$mock_bin/gh" <<'MOCKGH'
#!/bin/bash
echo "ERROR: gh should not be called for main worktree" >&2
exit 1
MOCKGH
  chmod +x "$mock_bin/gh"

  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    export PATH='${mock_bin}:\${PATH}'

    source '${RITE_UTILS_DIR}/config.sh'
    source '${RITE_UTILS_DIR}/issue-lock.sh'

    # Should complete without calling gh (which would exit 1)
    backfill_worktree_locks

    echo 'PASS'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"
}

# =============================================================================
# Test 5: detached HEAD worktree (no branch) is skipped
# =============================================================================

@test "backfill skips detached HEAD worktree" {
  local wt_path="${RITE_TEST_TMPDIR}/detached-worktree"
  mkdir -p "$wt_path"

  local mock_bin="${RITE_TEST_TMPDIR}/mock-bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git" <<'MOCKGIT'
#!/bin/bash
if [[ "$*" == *"worktree list --porcelain"* ]]; then
  printf 'worktree %s\n' "${RITE_PROJECT_ROOT}"
  printf 'branch refs/heads/main\n'
  printf '\n'
  # Detached HEAD: no branch line
  printf 'worktree %s\n' "${DETACHED_WT_PATH}"
  printf 'HEAD abc1234def5678abc1234def5678abc1234def56\n'
  printf 'detached\n'
  printf '\n'
  exit 0
fi
exit 0
MOCKGIT
  chmod +x "$mock_bin/git"

  # gh must NOT be called for detached HEAD
  cat > "$mock_bin/gh" <<'MOCKGH'
#!/bin/bash
echo "ERROR: gh should not be called for detached HEAD" >&2
exit 1
MOCKGH
  chmod +x "$mock_bin/gh"

  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    export DETACHED_WT_PATH='${wt_path}'
    export PATH='${mock_bin}:\${PATH}'

    source '${RITE_UTILS_DIR}/config.sh'
    source '${RITE_UTILS_DIR}/issue-lock.sh'

    backfill_worktree_locks

    echo 'PASS'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"
}

# =============================================================================
# Test 6: lock dir with pid but no worktree file gets the worktree file added
# =============================================================================

@test "backfill adds worktree file to existing pid-only lock dir" {
  local wt_path="${RITE_TEST_TMPDIR}/feat-worktree"
  mkdir -p "$wt_path"

  # Pre-create lock dir with pid but no worktree file (old lock format)
  local lock_dir="${RITE_LOCK_DIR}/issue-55.lock"
  mkdir -p "$lock_dir"
  echo "99999" > "$lock_dir/pid"
  # No worktree file

  local mock_bin="${RITE_TEST_TMPDIR}/mock-bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git" <<'MOCKGIT'
#!/bin/bash
if [[ "$*" == *"worktree list --porcelain"* ]]; then
  printf 'worktree %s\n' "${RITE_PROJECT_ROOT}"
  printf 'branch refs/heads/main\n'
  printf '\n'
  printf 'worktree %s\n' "${FEAT_WORKTREE_PATH}"
  printf 'branch refs/heads/feat/add-thing\n'
  printf '\n'
  exit 0
fi
exit 0
MOCKGIT
  chmod +x "$mock_bin/git"

  cat > "$mock_bin/gh" <<'MOCKGH'
#!/bin/bash
if [[ "$*" == *"pr list"* ]]; then
  printf '{"number":101,"body":"Closes #55\n\nAdds a thing."}'
  exit 0
fi
exit 0
MOCKGH
  chmod +x "$mock_bin/gh"

  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    export FEAT_WORKTREE_PATH='${wt_path}'
    export PATH='${mock_bin}:\${PATH}'

    source '${RITE_UTILS_DIR}/config.sh'
    source '${RITE_UTILS_DIR}/issue-lock.sh'

    backfill_worktree_locks

    # Worktree file must now exist
    [ -f '${lock_dir}/worktree' ] || { echo 'FAIL: worktree file not added'; exit 1; }

    # pid file must still be intact
    [ -f '${lock_dir}/pid' ] || { echo 'FAIL: pid file was removed'; exit 1; }

    echo 'PASS'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"
}

# =============================================================================
# Test 7: acquire_issue_lock writes worktree file when path provided
# =============================================================================

@test "acquire_issue_lock writes worktree file when worktree_path is provided" {
  local wt_path="${RITE_TEST_TMPDIR}/active-worktree"
  mkdir -p "$wt_path"

  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'

    source '${RITE_UTILS_DIR}/config.sh'
    source '${RITE_UTILS_DIR}/issue-lock.sh'

    acquire_issue_lock 77 '${wt_path}'

    # Both pid and worktree files must exist
    [ -f '${RITE_LOCK_DIR}/issue-77.lock/pid' ] || { echo 'FAIL: pid not written'; exit 1; }
    [ -f '${RITE_LOCK_DIR}/issue-77.lock/worktree' ] || { echo 'FAIL: worktree not written'; exit 1; }

    content=\$(cat '${RITE_LOCK_DIR}/issue-77.lock/worktree')
    [ \"\$content\" = '${wt_path}' ] || { echo \"FAIL: worktree path mismatch: \$content\"; exit 1; }

    release_issue_lock 77
    echo 'PASS'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"
}

# =============================================================================
# Test 8: acquire_issue_lock without worktree_path does not write worktree file
# =============================================================================

@test "acquire_issue_lock without worktree_path does not create worktree file" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'

    source '${RITE_UTILS_DIR}/config.sh'
    source '${RITE_UTILS_DIR}/issue-lock.sh'

    acquire_issue_lock 88

    # pid must exist, worktree must not
    [ -f '${RITE_LOCK_DIR}/issue-88.lock/pid' ] || { echo 'FAIL: pid not written'; exit 1; }
    [ ! -f '${RITE_LOCK_DIR}/issue-88.lock/worktree' ] || { echo 'FAIL: unexpected worktree file'; exit 1; }

    release_issue_lock 88
    echo 'PASS'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"
}

# =============================================================================
# Test 9: lock-based lookup in worktree details — issue number resolved via
# lock dir's worktree file (simulates the repo-status.sh lookup logic)
# =============================================================================

@test "lock-based lookup: issue number is resolved from worktree file in lock dir" {
  local wt_path="${RITE_TEST_TMPDIR}/my-worktree"
  mkdir -p "$wt_path"

  # Create a backfill lock dir with a worktree file pointing to our test path
  local lock_dir="${RITE_LOCK_DIR}/issue-99.lock"
  mkdir -p "$lock_dir"
  echo "$wt_path" > "$lock_dir/worktree"

  # Simulate the lookup loop from repo-status.sh
  run bash -c "
    set -euo pipefail
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'

    resolved_issue=''

    while IFS= read -r _lf; do
      _lf_wt=\$(cat \"\$_lf\" 2>/dev/null || echo '')
      if [ \"\$_lf_wt\" = '${wt_path}' ]; then
        resolved_issue=\$(basename \"\$(dirname \"\$_lf\")\" | grep -oE '[0-9]+' || true)
        break
      fi
    done < <(ls '${RITE_LOCK_DIR}'/issue-*.lock/worktree 2>/dev/null || true)

    [ \"\$resolved_issue\" = '99' ] || { echo \"FAIL: expected 99, got \$resolved_issue\"; exit 1; }
    echo 'PASS'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"
}
