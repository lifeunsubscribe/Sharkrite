#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/conflict-resolver.sh
# tests/regression/conflict-resolver.bats
#
# End-to-end tests for the real attempt_claude_merge_resolution function.
# Only provider_run_agentic_session is stubbed — all other resolver logic
# (Step 1-6) runs from the actual source code.
#
# This test exists because conflict-resolver-diag.bats stubs
# attempt_claude_merge_resolution wholesale, which means CI stays green
# even when the resolver is completely broken. These tests catch that class
# of regression by exercising the real resolver.
#
# Key scenario: caller invokes resolver from a CLEAN TREE (post-abort state),
# which is exactly how all four call sites in production use it.

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

# ---------------------------------------------------------------------------
# Setup helpers
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Suppress diag output — tests don't need the log file
  export RITE_LOG_FILE="/dev/null"
  unset RITE_VERBOSE

  cd "$FIXTURE_REPO"
}

teardown() {
  teardown_test_tmpdir
}

# Create a feature branch that conflicts with origin/main on README.md.
# Returns with FIXTURE_REPO as cwd on the feature branch.
# Sets BRANCH_NAME for use in tests.
_setup_conflict_scenario() {
  BRANCH_NAME="fix/conflict-test-e2e-$$"

  # Feature branch: append feature content to README.md
  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  printf '\nFeature line added by branch\n' >> README.md
  git add README.md
  git commit -m "Feature modifies README" >/dev/null 2>&1

  # Advance origin/main with conflicting content on the same line
  git checkout main >/dev/null 2>&1
  printf '\nConflicting line added by main\n' >> README.md
  git add README.md
  git commit -m "Main modifies README (conflicts with branch)" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Return to feature branch
  git checkout "$BRANCH_NAME" >/dev/null 2>&1
}

# ===========================================================================
# CORE END-TO-END: resolver runs from post-abort clean tree (the real call-site
# entry condition) and successfully resolves the conflict.
# ===========================================================================

@test "resolver: succeeds when called from clean tree (post-abort, real callers' entry state)" {
  _setup_conflict_scenario

  # Reproduce the EXACT call-site pattern from stale-branch.sh and divergence-handler.sh:
  #   1. Attempt the merge (fails with conflicts)
  #   2. Abort the merge — leaving a CLEAN TREE
  #   3. Call attempt_claude_merge_resolution

  # Step A: verify origin/main does conflict with our branch
  git merge origin/main --no-edit 2>/dev/null || true
  local unmerged_count
  unmerged_count=$(git diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')
  [ "$unmerged_count" -gt 0 ]  # sanity: conflicts exist

  # Step B: abort — this is the state ALL four callers produce before invoking resolver
  git merge --abort 2>/dev/null || true

  # Step C: confirm we are now in a clean tree (no unmerged files)
  local post_abort_count
  post_abort_count=$(git diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')
  [ "$post_abort_count" -eq 0 ]  # clean tree confirmed

  # Source the real resolver
  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"

  # Stub ONLY provider_run_agentic_session — all other resolver logic runs real code.
  # The stub simulates Claude: reads the conflict, writes resolved content, stages it.
  provider_run_agentic_session() {
    # Find conflicting files (Step 3 has re-run git merge by the time we're called)
    local _conflicted
    _conflicted=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ -z "$_conflicted" ]; then
      echo "STUB ERROR: no conflicting files visible to provider stub" >&2
      return 1
    fi
    # Resolve each conflicting file: write clean content, stage it
    while IFS= read -r _f; do
      [ -z "$_f" ] && continue
      echo "Resolved content (no conflict markers)" > "$_f"
      git add "$_f"
    done <<< "$_conflicted"
    return 0
  }

  # Also stub load_provider (called by resolver Step 5) so it doesn't
  # try to source the real claude.sh which requires PROVIDER_CMD etc.
  load_provider() { return 0; }

  # Run the resolver from the clean tree
  local result=0
  attempt_claude_merge_resolution \
    --branch-name "$BRANCH_NAME" \
    --merge-target "origin/main" 2>/dev/null || result=$?

  # Resolver must return 0 (success — conflicts resolved and staged)
  [ "$result" -eq 0 ]

  # Verify: no unmerged files remain
  local remaining
  remaining=$(git diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')
  [ "$remaining" -eq 0 ]

  # Verify: no conflict markers in resolved files.
  # Use the same precise regex as conflict-resolver.sh Check 2 to avoid
  # false-positives from markdown setext underlines or doc separators.
  # Includes the diff3/zdiff3 base-version marker (|||||||).
  if grep -rqE '^(<<<<<<<[[:space:]]|=======$|>>>>>>>[[:space:]]|\|\|\|\|\|\|\|[[:space:]])' . --include="*.md" 2>/dev/null; then
    echo "FAIL: Conflict markers still present after resolver returned 0" >&2
    return 1
  fi
}

# ===========================================================================
# REGRESSION: Step 3 must re-run git merge to produce conflict markers.
# If Step 3 is absent or broken, Claude sees no conflicts and cannot resolve.
# ===========================================================================

@test "resolver: Step 3 recreates conflict markers so provider stub sees unmerged files" {
  _setup_conflict_scenario

  # Abort any prior state — enter from clean tree (production pattern)
  git merge origin/main --no-edit 2>/dev/null || true
  git merge --abort 2>/dev/null || true

  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"

  # Capture what files the provider_run_agentic_session stub sees
  local provider_saw_conflicts="false"

  provider_run_agentic_session() {
    local _conflicts
    _conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ -n "$_conflicts" ]; then
      provider_saw_conflicts="true"
    fi
    # Resolve to let resolver complete cleanly
    while IFS= read -r _f; do
      [ -z "$_f" ] && continue
      echo "Resolved" > "$_f"
      git add "$_f"
    done <<< "$_conflicts"
    return 0
  }
  load_provider() { return 0; }

  attempt_claude_merge_resolution \
    --branch-name "$BRANCH_NAME" \
    --merge-target "origin/main" 2>/dev/null || true

  # The provider stub MUST have seen unmerged files — proving Step 3 re-ran git merge
  [ "$provider_saw_conflicts" = "true" ]
}

# ===========================================================================
# FAILURE PATH: provider stub returns 1 → resolver returns 1, tree is clean
# ===========================================================================

@test "resolver: returns 1 when provider session fails, leaves clean tree" {
  _setup_conflict_scenario

  git merge origin/main --no-edit 2>/dev/null || true
  git merge --abort 2>/dev/null || true

  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"

  # Provider stub: fails without resolving anything
  provider_run_agentic_session() { return 1; }
  load_provider() { return 0; }

  local result=0
  attempt_claude_merge_resolution \
    --branch-name "$BRANCH_NAME" \
    --merge-target "origin/main" 2>/dev/null || result=$?

  # Resolver must return 1 (failure)
  [ "$result" -eq 1 ]

  # Working tree must be clean after failure (merge aborted by resolver)
  local remaining
  remaining=$(git diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')
  [ "$remaining" -eq 0 ]
}

# ===========================================================================
# USAGE CAP PATH: provider stub returns 5 → resolver returns 5
# ===========================================================================

@test "resolver: returns 5 when provider hits usage cap (exit 5)" {
  _setup_conflict_scenario

  git merge origin/main --no-edit 2>/dev/null || true
  git merge --abort 2>/dev/null || true

  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"

  provider_run_agentic_session() { return 5; }
  load_provider() { return 0; }

  local result=0
  attempt_claude_merge_resolution \
    --branch-name "$BRANCH_NAME" \
    --merge-target "origin/main" 2>/dev/null || result=$?

  # Must propagate exit 5 intact (batch-abort sentinel)
  [ "$result" -eq 5 ]
}

# ===========================================================================
# REGRESSION: _cr_conflict_files array — paths with spaces do not word-split
#
# Before the fix, $_cr_conflict_files (newline-delimited) was passed unquoted
# to `git diff/log`, causing word-splitting on paths with spaces or glob chars.
# After the fix, the list is converted to an array via while-read and each
# element is passed as a properly-quoted argument.
# ===========================================================================

@test "resolver: context diff uses correct file when conflict path contains a space" {
  # Create a conflict on a file whose name contains a space.
  local SPACED_FILE="my feature.md"
  BRANCH_NAME="fix/spaced-path-test-$$"

  # Feature branch: create and modify a file with a space in the name
  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  printf '# Feature\n' > "$SPACED_FILE"
  git add "$SPACED_FILE"
  git commit -m "Add spaced file on branch" >/dev/null 2>&1

  # Advance origin/main with conflicting content on the same spaced file
  git checkout main >/dev/null 2>&1
  printf '# Main version\n' > "$SPACED_FILE"
  git add "$SPACED_FILE"
  git commit -m "Add spaced file on main (conflicts with branch)" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Return to feature branch
  git checkout "$BRANCH_NAME" >/dev/null 2>&1

  # Reproduce caller pattern: attempt merge, abort, call resolver from clean tree
  git merge origin/main --no-edit 2>/dev/null || true
  local unmerged_count
  unmerged_count=$(git diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')
  [ "$unmerged_count" -gt 0 ]  # sanity: conflict exists on spaced file

  git merge --abort 2>/dev/null || true

  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"

  # Capture the prompt so we can verify it references the spaced filename correctly
  local captured_prompt=""
  provider_run_agentic_session() {
    captured_prompt="$1"
    # Resolve the conflict so the resolver completes successfully
    local _conflicted
    _conflicted=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    while IFS= read -r _f; do
      [ -z "$_f" ] && continue
      echo "Resolved" > "$_f"
      git add "$_f"
    done <<< "$_conflicted"
    return 0
  }
  load_provider() { return 0; }

  local result=0
  attempt_claude_merge_resolution \
    --branch-name "$BRANCH_NAME" \
    --merge-target "origin/main" 2>/dev/null || result=$?

  # Resolver must succeed
  [ "$result" -eq 0 ]

  # The prompt's "Conflicting files" section must list the spaced filename intact —
  # if word-splitting had occurred, it would appear as two separate tokens ("my" and "feature.md")
  echo "$captured_prompt" | grep -qF "my feature.md"
}
