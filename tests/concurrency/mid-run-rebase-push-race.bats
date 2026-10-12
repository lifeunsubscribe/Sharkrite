#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/mid-run-rebase.sh
# sharkrite-gate-serial
#
# tests/concurrency/mid-run-rebase-push-race.bats
# Push-race tests for _mid_run_rebase_onto_main (issue #1045):
#   1. Content-empty foreign commit is discarded, push retried (exit 0)
#   2. Foreign commit with real code changes halts without pushing (exit 1)
#   3. Triple-race: retry push also rejected → accurate error, not "foreign code" (exit 1)
#
# Pins the anchor fix: pre_rebase_head (not merge-base) must be the diff base after
# a push rejection. The old merge-base regressed to the old fork point and pulled the
# branch's own feature diff into the check, making the content-empty discard path
# unreachable. Mirrors stale-branch.sh:506 / commit 0fd9298.

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    skip "Concurrency tests require bash 4+ (detected bash ${BASH_VERSION}). Install via: brew install bash"
  fi

  setup_test_tmpdir

  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_WORKTREE_DIR="$RITE_PROJECT_ROOT/.rite/worktrees"

  mkdir -p "$RITE_WORKTREE_DIR"

  cd "$FIXTURE_REPO"

  source "$RITE_LIB_DIR/utils/mid-run-rebase.sh"
  set +u; set +o pipefail
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: build the fixture shared by all three tests.
#   - Creates a feature branch with one commit, pushes it.
#   - Advances origin/main by one commit to create drift (triggers rebase).
#   - Creates a worktree pointing to the feature branch.
#   - Has a "concurrent" clone push one commit to the branch, advancing
#     the remote so the subsequent force-with-lease push will be rejected.
#
# When $concurrent_content is empty (default), the concurrent commit is
# --allow-empty (no diff vs branch tip).  When non-empty, the concurrent
# commit adds a new file with that content (real code change).
#
# Outputs (exported to caller's scope):
#   _branch_name   — the feature branch name
#   _worktree_path — path to the local worktree
#   _pre_push_tip  — the feature commit SHA before the rebase
# ---------------------------------------------------------------------------
_setup_mid_run_push_race_fixture() {
  local branch_suffix="$1"
  local concurrent_content="${2:-}"

  local branch_name="fix/mid-run-push-race-${branch_suffix}"
  local worktree_path="$RITE_WORKTREE_DIR/issue-mid-${branch_suffix}"

  cd "$FIXTURE_REPO"

  git checkout -b "$branch_name" main >/dev/null 2>&1
  echo "feature work" > "feature-${branch_suffix}.txt"
  git add "feature-${branch_suffix}.txt"
  git commit -m "Feature work for ${branch_suffix}" >/dev/null 2>&1
  git push -u origin "$branch_name" >/dev/null 2>&1

  local pre_push_tip
  pre_push_tip=$(git rev-parse HEAD 2>/dev/null)

  # Advance origin/main so drift triggers a rebase inside _mid_run_rebase_onto_main
  git checkout main >/dev/null 2>&1
  echo "main advance" > "main-advance-${branch_suffix}.txt"
  git add "main-advance-${branch_suffix}.txt"
  git commit -m "Advance main for ${branch_suffix}" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1

  # Concurrent clone: push one more commit to the remote branch so the
  # worktree's force-with-lease push after rebase is rejected.
  local concurrent_dir="$RITE_TEST_TMPDIR/concurrent-${branch_suffix}"
  git clone "$BARE_REMOTE" "$concurrent_dir" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.email "concurrent@example.com" >/dev/null 2>&1
  git -C "$concurrent_dir" config user.name "Concurrent" >/dev/null 2>&1
  git -C "$concurrent_dir" checkout "$branch_name" >/dev/null 2>&1

  if [ -z "$concurrent_content" ]; then
    # Empty commit: tree identical to pre_push_tip → diff pre_push_tip..remote is empty
    git -C "$concurrent_dir" commit --allow-empty -m "Sync merge (empty, no diff)" >/dev/null 2>&1
  else
    echo "$concurrent_content" > "$concurrent_dir/foreign-file-${branch_suffix}.txt"
    git -C "$concurrent_dir" add "foreign-file-${branch_suffix}.txt"
    git -C "$concurrent_dir" commit -m "Foreign code commit for ${branch_suffix}" >/dev/null 2>&1
  fi
  git -C "$concurrent_dir" push origin "$branch_name" >/dev/null 2>&1

  _branch_name="$branch_name"
  _worktree_path="$worktree_path"
  _pre_push_tip="$pre_push_tip"
}

# ---------------------------------------------------------------------------

@test "mid-run-rebase push-race: content-empty foreign commit is discarded and push retried (exit 0)" {
  # Scenario: After a successful mid-run rebase the force-push is rejected because
  # a concurrent empty commit landed on the remote (a pure mainline-sync placeholder
  # with no file changes). git diff pre_rebase_head..remote_head must be empty so the
  # function discards the foreign commit, retries the push with a refreshed lease,
  # and returns 0.
  #
  # The old merge-base anchor made this path unreachable: merge-base(post-rebase,remote)
  # regressed to the original fork point, causing the branch's own feature diff to
  # appear in the check and falsely classify the empty commit as non-empty.

  _setup_mid_run_push_race_fixture "ce-1045"

  run _mid_run_rebase_onto_main "$_worktree_path" "$_branch_name" "1045" "" "unsupervised" "main"

  [ "$status" -eq 0 ]
  # Feature file must still exist after the successful push
  [ -f "$_worktree_path/feature-ce-1045.txt" ]

  cd "$FIXTURE_REPO"
  git worktree remove "$_worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$_branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$_branch_name" >/dev/null 2>&1 || true
}

@test "mid-run-rebase push-race: foreign commit with real code changes halts without pushing (exit 1)" {
  # Scenario: After a successful mid-run rebase the force-push is rejected because
  # a concurrent commit added a new file (real code change). The function must halt
  # loudly, NOT push (preserve foreign code), restore local HEAD to pre_rebase_head,
  # and return 1.
  #
  # Pins AC 3 (halt without push, pre_rebase_head restored) and AC 4 (evidence log
  # only lists commits beyond pre_rebase_head — the branch's own rewritten feature
  # commit must NOT appear as "foreign evidence").

  _setup_mid_run_push_race_fixture "fc-1045" "foreign code content"

  local output_file="$RITE_TEST_TMPDIR/output-fc.txt"
  _mid_run_rebase_onto_main "$_worktree_path" "$_branch_name" "1045" "" "unsupervised" "main" > "$output_file" 2>&1 && _fc_exit=0 || _fc_exit=$?

  # Must halt (exit 1)
  [ "$_fc_exit" -eq 1 ]

  # Local HEAD must be restored to pre_rebase_head
  local local_head
  local_head=$(git -C "$_worktree_path" rev-parse HEAD 2>/dev/null || true)
  [ "$local_head" = "$_pre_push_tip" ]

  # Remote must NOT have been overwritten (force-push must not have been attempted)
  local remote_head
  remote_head=$(git -C "$FIXTURE_REPO" ls-remote origin "$_branch_name" 2>/dev/null | awk '{print $1}' || true)
  [ "$remote_head" != "$local_head" ]

  # Evidence log must mention the foreign commit subject
  grep -q "Foreign code commit" "$output_file"

  # Evidence log must NOT contain the branch's own feature commit subject —
  # that commit is at/below pre_rebase_head and must not appear in the range
  # pre_rebase_head..remote_head
  ! grep -q "Feature work for fc-1045" "$output_file"

  cd "$FIXTURE_REPO"
  git worktree remove "$_worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$_branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$_branch_name" >/dev/null 2>&1 || true
}

@test "mid-run-rebase push-race: triple-race emits accurate still-rejected error, not foreign-code message (exit 1)" {
  # Scenario: The retry push (after a content-empty lease refresh) is ALSO rejected
  # by a third concurrent push. The old code fell through past the content-empty `fi`
  # into "remote has foreign code commits" — mislabeling a harmless race as foreign code.
  # The fix adds an explicit "push still rejected after lease refresh" error and returns 1
  # without printing the foreign-code message. Mirrors stale-branch.sh:530.
  #
  # A PATH-based git stub fails the first two --force-with-lease push calls.
  # All other git operations (rebase, fetch, log, diff, reset) pass through to real git.

  _setup_mid_run_push_race_fixture "tr-1045"

  local real_git
  real_git="$(command -v git)"
  local stub_dir="$RITE_TEST_TMPDIR/stubs-tr"
  mkdir -p "$stub_dir"
  export RITE_STUB_REAL_GIT="$real_git"
  export RITE_STUB_PUSH_COUNT_FILE="$RITE_TEST_TMPDIR/push-count-tr.txt"
  export RITE_STUB_PUSH_FAIL_COUNT=2
  echo "0" > "$RITE_STUB_PUSH_COUNT_FILE"

  cat > "$stub_dir/git" <<'STUB_EOF'
#!/bin/bash
for _stub_arg in "$@"; do
  if [ "$_stub_arg" = "--force-with-lease" ]; then
    _stub_count=$(cat "$RITE_STUB_PUSH_COUNT_FILE" 2>/dev/null || echo 0)
    _stub_new=$((_stub_count + 1))
    echo "$_stub_new" > "$RITE_STUB_PUSH_COUNT_FILE"
    if [ "$_stub_new" -le "${RITE_STUB_PUSH_FAIL_COUNT:-2}" ]; then
      echo "error: failed to push some refs (stub: triple-race)" >&2
      exit 1
    fi
    break
  fi
done
exec "$RITE_STUB_REAL_GIT" "$@"
STUB_EOF
  chmod +x "$stub_dir/git"

  local original_path="$PATH"
  export PATH="$stub_dir:$PATH"

  local output_file="$RITE_TEST_TMPDIR/output-tr.txt"
  _mid_run_rebase_onto_main "$_worktree_path" "$_branch_name" "1045" "" "unsupervised" "main" > "$output_file" 2>&1 && _tr_exit=0 || _tr_exit=$?

  export PATH="$original_path"

  # Must halt (exit 1)
  [ "$_tr_exit" -eq 1 ]

  # Local HEAD must be restored to pre_rebase_head
  local local_head
  local_head=$(git -C "$_worktree_path" rev-parse HEAD 2>/dev/null || true)
  [ "$local_head" = "$_pre_push_tip" ]

  # Must emit the accurate still-rejected error, NOT the foreign-code message
  grep -q "push still rejected after lease refresh" "$output_file"
  ! grep -q "foreign code commits" "$output_file"

  # Stub must have intercepted exactly 2 --force-with-lease push calls
  local push_count
  push_count=$(cat "$RITE_STUB_PUSH_COUNT_FILE" 2>/dev/null || echo 0)
  [ "$push_count" -eq 2 ]

  cd "$FIXTURE_REPO"
  git worktree remove "$_worktree_path" --force >/dev/null 2>&1 || true
  git branch -D "$_branch_name" >/dev/null 2>&1 || true
  git push origin --delete "$_branch_name" >/dev/null 2>&1 || true
}
