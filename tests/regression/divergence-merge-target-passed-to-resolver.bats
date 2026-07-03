#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/divergence-handler.sh
# tests/regression/divergence-merge-target-passed-to-resolver.bats
#
# Regression tests for the --merge-target invariant in _do_rebase_and_push.
#
# Bug context (PR #435, issue #432 → follow-up issue #450):
#   When _do_rebase_and_push encounters rebase conflicts and invokes
#   attempt_claude_merge_resolution, it must pass:
#
#     --merge-target "origin/$branch_name"
#
#   NOT the resolver's default of "origin/main".
#
#   Without this flag, the resolver re-runs git merge against origin/main
#   instead of origin/$branch_name. The resolver then stages + commits on
#   top of un-rebased HEAD and force-pushes — overwriting the foreign commits
#   that the divergence handler exists to preserve.
#
# Tests:
#   1. _do_rebase_and_push passes --merge-target "origin/$branch_name" to the resolver
#      (argument invariant — fails if the call site reverts to positional form or default target).
#
#   2. The full divergence flow preserves foreign commits on origin/$branch_name
#      when the resolver uses the correct merge target.
#      (semantic invariant — exercises the behavior the arg guards against breaking).
#
#   3. Wrong-target failure path: foreign commit is NOT an ancestor when the
#      resolver uses origin/main (the shared ancestor) instead of origin/$branch_name.
#      (counterpart to Test 2 — proves the ancestry assertion is non-vacuous).

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  setup_test_tmpdir

  # Create bare remote and fixture repo
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_WORKTREE_DIR="$RITE_PROJECT_ROOT/.rite/worktrees"

  # Suppress diag output in tests
  export RITE_LOG_FILE="/dev/null"
  unset RITE_VERBOSE

  mkdir -p "$RITE_WORKTREE_DIR"

  cd "$FIXTURE_REPO"

  # Source the divergence-handler (conflict-resolver.sh is optional — tests stub the function)
  source "$RITE_LIB_DIR/utils/divergence-handler.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  teardown_test_tmpdir
}

# ───────────────────────────────────────────────────────────────────
# Shared fixture: branch that conflicts with origin/$BRANCH_NAME.
#
# After this call:
#   - BRANCH_NAME is set
#   - WORKTREE_PATH is set and cwd is the worktree
#   - local branch and origin/$BRANCH_NAME have diverged such that
#     rebasing local onto origin/$BRANCH_NAME produces a conflict
#   - origin/$BRANCH_NAME has one "foreign" commit not in local
#
# The fixture deliberately does NOT advance origin/main — that keeps
# origin/main as the shared ancestor so we can verify that the resolver
# is called with origin/$BRANCH_NAME (not origin/main) as the merge target.
# ───────────────────────────────────────────────────────────────────
_setup_diverging_branch() {
  BRANCH_NAME="fix/merge-target-test-$$"

  # Create feature branch from main with a shared commit
  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  echo "# Shared base content" > feature.md
  git add feature.md
  git commit -m "Feature: shared base" >/dev/null 2>&1
  git push -u origin "$BRANCH_NAME" >/dev/null 2>&1

  # Simulate a collaborator (or CI) pushing a foreign commit to origin/$BRANCH_NAME.
  # This commit modifies feature.md to a value that will conflict with our local change.
  local tmp_clone="${RITE_TEST_TMPDIR}/tmp-clone-$$"
  git clone "$BARE_REMOTE" "$tmp_clone" >/dev/null 2>&1
  git -C "$tmp_clone" config user.name "Collaborator"
  git -C "$tmp_clone" config user.email "collab@example.com"
  git -C "$tmp_clone" checkout "$BRANCH_NAME" >/dev/null 2>&1
  echo "# Collaborator's version (foreign commit)" > "$tmp_clone/feature.md"
  git -C "$tmp_clone" add feature.md
  git -C "$tmp_clone" commit -m "Foreign: collaborator's change" >/dev/null 2>&1
  git -C "$tmp_clone" push origin "$BRANCH_NAME" >/dev/null 2>&1
  # Record the foreign commit SHA so tests can verify it survives the workflow
  FOREIGN_COMMIT_SHA=$(git -C "$tmp_clone" rev-parse HEAD)

  # Local: make a conflicting change to feature.md (same file, different content)
  echo "# Local developer's version (not pushed)" > feature.md
  git add feature.md
  git commit -m "Local: developer's change (unpushed)" >/dev/null 2>&1

  # Switch main repo back to 'main' so we can create a worktree on BRANCH_NAME
  git checkout main >/dev/null 2>&1

  # Create worktree on the local (non-updated) branch
  WORKTREE_PATH="$RITE_WORKTREE_DIR/issue-merge-target-$$"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1

  cd "$WORKTREE_PATH"

  # Fetch remote state so divergence-handler can detect divergence
  git fetch origin "$BRANCH_NAME" >/dev/null 2>&1

  # Sanity: confirm the fixture actually produces a conflict on rebase
  if git rebase "origin/$BRANCH_NAME" >/dev/null 2>&1; then
    git rebase --abort 2>/dev/null || true
    echo "ERROR: fixture did not produce a rebase conflict — check that both sides modify the same line" >&2
    return 1
  fi
  git rebase --abort >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────
# Test 1: Argument invariant — _do_rebase_and_push passes
# --merge-target "origin/$BRANCH_NAME" to attempt_claude_merge_resolution
#
# This test stubs attempt_claude_merge_resolution to capture the argument
# and verifies the correct target is passed. It does NOT test full resolver
# behavior — only the call-site contract.
# ───────────────────────────────────────────────────────────────────
@test "divergence merge-target: resolver called with --merge-target origin/\$branch_name, not origin/main" {
  _setup_diverging_branch

  # Capture the --merge-target value passed to the resolver.
  # Use a global (not local) so the stub function, which runs in the
  # same process but at a different call-stack depth, can write to it reliably.
  _captured_merge_target=""

  attempt_claude_merge_resolution() {
    # Parse named flags to find --merge-target
    while [ $# -gt 0 ]; do
      case "$1" in
        --merge-target) _captured_merge_target="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    # Resolve conflict so _do_rebase_and_push can proceed past the resolver step
    echo "# Resolved content" > feature.md
    git add feature.md
    git commit -m "chore: resolve conflict (test stub)" >/dev/null 2>&1
    return 0
  }

  # Run _do_rebase_and_push in auto mode — triggers resolver on rebase conflict
  local exit_code=0
  _do_rebase_and_push "$BRANCH_NAME" "true" "450" "435" 2>/dev/null || exit_code=$?

  # The resolver must have been called (exit 0 proves it was reached and returned success)
  [ "$exit_code" -eq 0 ]

  # The --merge-target must be origin/$BRANCH_NAME — not origin/main (the resolver default)
  [ "$_captured_merge_target" = "origin/$BRANCH_NAME" ]

  # Explicitly assert it is NOT origin/main — the exact wrong value the bug would have used
  [ "$_captured_merge_target" != "origin/main" ]

  # Clean up worktree
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────
# Test 2: Semantic invariant — foreign commits on origin/$BRANCH_NAME
# are reachable from the pushed branch when the REAL resolver runs
# with the correct merge target.
#
# This test sources the real conflict-resolver.sh but stubs only
# provider_run_agentic_session (the Claude network call) — all other
# resolver logic runs real code. The resolver's internal git merge runs
# against origin/$BRANCH_NAME (the correct target), producing a merge
# commit that has the foreign commit as a parent. After _do_rebase_and_push
# force-pushes the resolved branch, the foreign commit must be reachable
# from origin/$BRANCH_NAME via the merge parent.
#
# Contrast with wrong-target behavior: if the resolver merged against
# origin/main instead, the merge commit would have main as parent (not
# origin/$BRANCH_NAME), and the foreign commit would not be reachable.
# ───────────────────────────────────────────────────────────────────
@test "divergence merge-target: foreign commit is ancestor of pushed branch when resolver uses correct target" {
  _setup_diverging_branch

  # Source the REAL conflict-resolver.sh so its internal git merge runs.
  # The re-source guard means this is idempotent if already loaded.
  if [ -f "$RITE_LIB_DIR/utils/conflict-resolver.sh" ]; then
    source "$RITE_LIB_DIR/utils/conflict-resolver.sh"
  fi

  # Stub only the provider session — Claude resolves conflicts by writing
  # clean content and staging. All other resolver logic (Steps 1-6) runs real code.
  provider_run_agentic_session() {
    local _conflicted
    _conflicted=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ -z "$_conflicted" ]; then
      echo "STUB ERROR: no conflicting files visible to provider stub" >&2
      return 1
    fi
    # Resolve each conflicting file with merged content and stage it
    while IFS= read -r _f; do
      [ -z "$_f" ] && continue
      echo "# Merged content: collaborator + developer" > "$_f"
      git add "$_f"
    done <<< "$_conflicted"
    return 0
  }

  # Stub load_provider so the resolver doesn't try to source the real claude.sh
  load_provider() { return 0; }

  # Run _do_rebase_and_push in auto mode — invokes the real resolver
  local exit_code=0
  _do_rebase_and_push "$BRANCH_NAME" "true" "450" "435" 2>/dev/null || exit_code=$?

  # Must succeed (exit 0)
  [ "$exit_code" -eq 0 ]

  # Fetch updated remote state
  git fetch origin "$BRANCH_NAME" >/dev/null 2>&1

  # The foreign commit must be an ancestor of the pushed branch tip.
  # The real resolver runs: git merge "origin/$BRANCH_NAME" (correct target) → merge commit
  # has the foreign commit as a parent → git merge-base --is-ancestor returns 0.
  # If the wrong target (origin/main) had been used, origin/main is the shared ancestor,
  # NOT the foreign commit — the foreign commit would not be reachable from the merge result.
  local is_ancestor=0
  git -C "$WORKTREE_PATH" merge-base --is-ancestor "$FOREIGN_COMMIT_SHA" "origin/$BRANCH_NAME" || is_ancestor=$?
  [ "$is_ancestor" -eq 0 ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────
# Test 3: Wrong-target failure path — foreign commit is NOT an ancestor
# when the resolver uses the wrong merge target (origin/main).
#
# This is the counterpart to Test 2. It demonstrates that Test 2's
# ancestry assertion is non-vacuous: using origin/main (the shared
# ancestor, not the branch-specific remote) does NOT preserve the
# foreign commit. The two tests together form a proof-by-contrast:
#   - Correct target  → foreign commit IS ancestor (Test 2)
#   - Wrong target    → foreign commit is NOT ancestor (Test 3)
#
# Mechanism: stub attempt_claude_merge_resolution to resolve conflicts
# without incorporating the foreign commit (simulating the pre-fix buggy
# call site that merged against origin/main instead of origin/$BRANCH_NAME).
# The stub resolves the conflict file and commits directly on top of the
# un-rebased local HEAD — leaving the foreign commit unreachable.
# After _do_rebase_and_push force-pushes this result, origin/$BRANCH_NAME
# is overwritten with a tip that has no path to the foreign commit.
#
# Note: _do_rebase_and_push uses --force-with-lease push when the resolver
# commits (i.e. _resolver_rewrote_history=true). The foreign commit is absent
# from the pushed tip because the stub committed without incorporating it —
# the force-push is the mechanism that overwrites origin/$BRANCH_NAME with
# that resolver-produced (foreign-commit-free) result.
# ───────────────────────────────────────────────────────────────────
@test "divergence merge-target: foreign commit is NOT ancestor when resolver uses wrong target (origin/main)" {
  _setup_diverging_branch

  # Sentinel: tracks whether the stub was actually called.
  # Without this, the test could pass green if the resolver is never invoked
  # (e.g. because _do_rebase_and_push short-circuits via a force-push path
  # that bypasses the resolver entirely). Mirrors Test 1's _captured_merge_target pattern.
  _resolver_invoked="false"

  # Stub attempt_claude_merge_resolution to simulate the pre-fix bug:
  # ignore --merge-target and resolve conflicts without incorporating the
  # foreign commit. The stub writes local-only content and commits directly
  # on top of un-rebased HEAD, leaving no path to the foreign commit.
  # This produces the same outcome as a resolver that merged origin/main
  # (shared ancestor) instead of origin/$BRANCH_NAME: the push will
  # overwrite the remote with a history that never includes the foreign commit.
  attempt_claude_merge_resolution() {
    _resolver_invoked="true"
    # Intentionally ignore all arguments (including --merge-target).
    # Resolve conflict files by writing local-only content and staging them.
    # Do NOT attempt git merge — origin/main is the fixture's shared ancestor
    # and merging it would be a no-op (no new commits on main since branch creation),
    # producing no staged changes and therefore no resolver commit. Instead, directly
    # overwrite the conflicting file with local-only content, matching what a
    # wrong-target resolver would have produced (local content, no foreign commit).
    local _conflicted
    _conflicted=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    while IFS= read -r _f; do
      [ -z "$_f" ] && continue
      echo "# Wrong-target resolved content (local only, foreign commit not incorporated)" > "$_f"
      git add "$_f"
    done <<< "$_conflicted"
    # Commit the resolution — _do_rebase_and_push checks git diff --cached and only
    # commits if staged changes exist. Committing here is also valid: the resolver
    # contract allows it, and it ensures _resolver_rewrote_history=true triggers the
    # force-with-lease push path regardless of the cached-diff check.
    git commit -m "chore: wrong-target resolution (test stub, no foreign commit)" >/dev/null 2>&1
    return 0
  }

  # Run _do_rebase_and_push — the stub above resolves without the foreign commit
  local exit_code=0
  _do_rebase_and_push "$BRANCH_NAME" "true" "450" "435" 2>/dev/null || exit_code=$?

  # The push must succeed (exit 0) — we need origin/$BRANCH_NAME to be updated
  # so we can verify the foreign commit is absent from the pushed result.
  [ "$exit_code" -eq 0 ]

  # The resolver stub must have been called — guards against silent regression-value
  # loss where the test passes green without ever exercising the resolver path.
  [ "$_resolver_invoked" = "true" ]

  # Fetch updated remote state
  git fetch origin "$BRANCH_NAME" >/dev/null 2>&1

  # The foreign commit must NOT be an ancestor of origin/$BRANCH_NAME.
  # The stub committed on top of local (un-rebased) HEAD without incorporating
  # the foreign commit. _do_rebase_and_push then force-pushed this result,
  # overwriting origin/$BRANCH_NAME with a tip whose history never includes
  # the foreign commit.
  # git merge-base --is-ancestor exits 0 if ancestor, 1 if not.
  local is_ancestor=0
  git -C "$WORKTREE_PATH" merge-base --is-ancestor "$FOREIGN_COMMIT_SHA" "origin/$BRANCH_NAME" || is_ancestor=$?
  [ "$is_ancestor" -ne 0 ]

  # Clean up
  cd "$FIXTURE_REPO"
  git worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  git branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  git push origin --delete "$BRANCH_NAME" >/dev/null 2>&1 || true
}
