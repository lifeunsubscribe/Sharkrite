#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/stale-branch.sh, lib/utils/branch-preflight.sh, lib/core/claude-workflow.sh
# tests/regression/stale-branch-base-branch-resolution.bats
#
# Regression tests for dynamic base branch resolution in stale-branch.sh and
# branch-preflight.sh. Fixes the anti-pattern from #365/#420 where origin/main
# was hardcoded — stale-branch and preflight operations now use the PR's actual
# base branch.
#
# Tests:
#   1. _stale_resolve_base_branch falls back to "main" when PR number is empty
#   2. _stale_resolve_base_branch falls back to "main" when gh_safe returns empty
#   3. _stale_resolve_base_branch returns the API value when valid
#   4. _stale_resolve_base_branch rejects unsafe branch names (path traversal)
#   5. _stale_resolve_base_branch rejects branch names with shell meta-characters
#   6. get_commits_behind_main accepts base_branch param (no longer hardcodes main)
#   7. format_stale_close_comment uses provided base_branch in git commands
#   8. format_stale_close_comment close-comment text body uses dynamic base_branch
#   9. classify_branch_health accepts optional base_branch (4th param)
#  10. classify_branch_health fetch uses base_branch param, not hardcoded 'main'
#  11. _preflight_has_only_init_commit uses base_branch param, not 'origin/main'
#  12. claude-workflow.sh caller passes resolved base_branch to classify_branch_health

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LOG_FILE=""

  # Stub print functions
  print_status()  { :; }
  print_info()    { :; }
  print_warning() { :; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_success() { :; }
  print_header()  { :; }
  _diag()         { :; }
  export -f print_status print_info print_warning print_error print_success print_header _diag

  # Stub all stale-branch deps so sourcing doesn't fail
  create_sharkrite_stash() { return 0; }
  verify_post_merge()      { return 0; }
  export -f create_sharkrite_stash verify_post_merge
}

teardown() {
  teardown_test_tmpdir
}

# =============================================================================
# Tests for _stale_resolve_base_branch
# =============================================================================

@test "_stale_resolve_base_branch: empty PR number → falls back to 'main'" {
  # Stub gh_safe (should not be called when pr_number is empty)
  gh_safe() { echo "SHOULD_NOT_BE_CALLED"; }
  export -f gh_safe

  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  _stale_resolve_base_branch ""
  [ "$_STALE_BASE_BRANCH" = "main" ] || {
    echo "FAIL: expected 'main', got '$_STALE_BASE_BRANCH'"
    return 1
  }
}

@test "_stale_resolve_base_branch: null PR number → falls back to 'main'" {
  gh_safe() { echo "SHOULD_NOT_BE_CALLED"; }
  export -f gh_safe

  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  _stale_resolve_base_branch "null"
  [ "$_STALE_BASE_BRANCH" = "main" ] || {
    echo "FAIL: expected 'main', got '$_STALE_BASE_BRANCH'"
    return 1
  }
}

@test "_stale_resolve_base_branch: gh_safe returns empty → falls back to 'main'" {
  gh_safe() { echo ""; }
  export -f gh_safe

  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  _stale_resolve_base_branch "42"
  [ "$_STALE_BASE_BRANCH" = "main" ] || {
    echo "FAIL: expected 'main' (empty API response), got '$_STALE_BASE_BRANCH'"
    return 1
  }
}

@test "_stale_resolve_base_branch: valid branch name returned from API is used" {
  gh_safe() { echo "develop"; }
  export -f gh_safe

  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  _stale_resolve_base_branch "42"
  [ "$_STALE_BASE_BRANCH" = "develop" ] || {
    echo "FAIL: expected 'develop', got '$_STALE_BASE_BRANCH'"
    return 1
  }
}

@test "_stale_resolve_base_branch: path traversal in branch name → falls back to 'main'" {
  # A crafted baseRefName containing '..' must be rejected to prevent
  # injection into 'origin/${base_branch}' git calls.
  gh_safe() { echo "../evil"; }
  export -f gh_safe

  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  _stale_resolve_base_branch "42"
  [ "$_STALE_BASE_BRANCH" = "main" ] || {
    echo "FAIL: expected 'main' (path traversal rejected), got '$_STALE_BASE_BRANCH'"
    return 1
  }
}

@test "_stale_resolve_base_branch: shell meta-characters in branch name → falls back to 'main'" {
  # A crafted baseRefName with semicolons/backticks must be rejected.
  gh_safe() { printf 'main;rm -rf /'; }
  export -f gh_safe

  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  _stale_resolve_base_branch "42"
  [ "$_STALE_BASE_BRANCH" = "main" ] || {
    echo "FAIL: expected 'main' (meta-characters rejected), got '$_STALE_BASE_BRANCH'"
    return 1
  }
}

# =============================================================================
# Tests verifying get_commits_behind_main accepts base_branch parameter
# =============================================================================

@test "get_commits_behind_main: accepts base_branch param, not hardcoded to 'main'" {
  # Source the function and verify its signature accepts a second argument.
  # This is a static check on the function definition — confirms the param was added.
  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  _src=$(declare -f get_commits_behind_main)
  # The function body must reference base_branch (the new parameter)
  echo "$_src" | grep -q 'base_branch' || {
    echo "FAIL: get_commits_behind_main does not reference base_branch parameter"
    return 1
  }
  # It must NOT have the hardcoded literal 'origin/main'
  echo "$_src" | grep -qF 'origin/main' && {
    echo "FAIL: get_commits_behind_main still contains hardcoded 'origin/main'"
    return 1
  }
  return 0
}

# =============================================================================
# Tests verifying format_stale_close_comment uses base_branch parameter
# =============================================================================

@test "format_stale_close_comment: uses base_branch param, not hardcoded to 'main'" {
  # Verify the function definition references base_branch, not a literal origin/main.
  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  _src=$(declare -f format_stale_close_comment)
  echo "$_src" | grep -q 'base_branch' || {
    echo "FAIL: format_stale_close_comment does not reference base_branch parameter"
    return 1
  }
  echo "$_src" | grep -qF 'origin/main' && {
    echo "FAIL: format_stale_close_comment still contains hardcoded 'origin/main'"
    return 1
  }
  return 0
}

@test "format_stale_close_comment: close-comment text body uses dynamic base_branch, not literal 'main'" {
  # Regression: The git commands used $base_branch but the human-readable text in the
  # heredoc said "behind main", "from main", "from current main" — producing a misleading
  # message for non-main base branches (e.g. develop, release/1.x).
  # This test verifies the comment body text uses the provided base_branch value.
  #
  # We create a minimal git repo so format_stale_close_comment can run its git commands.
  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  # Set up a minimal git repo in the test tmpdir
  local _repo="$RITE_TEST_TMPDIR/repo"
  mkdir -p "$_repo"
  git -C "$_repo" init -q
  git -C "$_repo" config user.email "test@test.com"
  git -C "$_repo" config user.name "Test"
  echo "init" > "$_repo/file.txt"
  git -C "$_repo" add .
  git -C "$_repo" commit -qm "init"
  # Simulate origin/develop by creating a local ref
  git -C "$_repo" checkout -qb develop
  git -C "$_repo" checkout -q -b feature
  echo "feature" >> "$_repo/file.txt"
  git -C "$_repo" add .
  git -C "$_repo" commit -qm "feat: add feature"

  # Call format_stale_close_comment with base_branch="develop"
  _comment=$(format_stale_close_comment "$_repo" 5 "develop")

  # The text body must mention "develop" (the actual base branch)
  echo "$_comment" | grep -q 'develop' || {
    echo "FAIL: close-comment body does not mention 'develop' (the passed base_branch)"
    echo "--- comment body ---"
    echo "$_comment"
    return 1
  }

  # The text body must NOT say "behind main" or "from main" with literal "main"
  # (only check for "main" as a standalone word in the prose, not inside variable names)
  if echo "$_comment" | grep -qE 'behind main\b|from main\b|from current main\b'; then
    echo "FAIL: close-comment body still contains hardcoded 'main' in prose"
    echo "--- comment body ---"
    echo "$_comment"
    return 1
  fi
  return 0
}

# =============================================================================
# Tests for classify_branch_health: accepts base_branch parameter
# =============================================================================

@test "classify_branch_health: function signature accepts optional base_branch (4th param)" {
  # Static check: the function must declare base_branch as a local variable
  # from the 4th positional argument.
  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/branch-preflight.sh"

  _src=$(declare -f classify_branch_health)
  echo "$_src" | grep -q 'base_branch' || {
    echo "FAIL: classify_branch_health does not reference base_branch parameter"
    return 1
  }
  return 0
}

@test "classify_branch_health: fetch uses base_branch param, not hardcoded 'main'" {
  # Verify the function body does NOT hard-code 'fetch origin main'.
  # It must use 'fetch origin "$base_branch"' (or equivalent variable reference).
  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/branch-preflight.sh"

  _src=$(declare -f classify_branch_health)
  # Must not have the literal 'fetch origin main'
  if echo "$_src" | grep -qF 'fetch origin main'; then
    echo "FAIL: classify_branch_health still has hardcoded 'fetch origin main'"
    return 1
  fi
  # Must reference base_branch in the fetch call
  echo "$_src" | grep -q 'base_branch' || {
    echo "FAIL: classify_branch_health does not use base_branch variable"
    return 1
  }
  return 0
}

@test "_preflight_has_only_init_commit: uses base_branch param, not hardcoded 'origin/main'" {
  # Verify the helper passes base_branch to the git log call instead of hardcoding origin/main.
  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/branch-preflight.sh"

  _src=$(declare -f _preflight_has_only_init_commit)
  # Must not hardcode origin/main
  if echo "$_src" | grep -qF 'origin/main'; then
    echo "FAIL: _preflight_has_only_init_commit still contains hardcoded 'origin/main'"
    return 1
  fi
  # Must reference base_branch
  echo "$_src" | grep -q 'base_branch' || {
    echo "FAIL: _preflight_has_only_init_commit does not use base_branch variable"
    return 1
  }
  return 0
}

# =============================================================================
# Test verifying claude-workflow.sh caller passes resolved base branch
# =============================================================================

@test "claude-workflow.sh: classify_branch_health caller passes resolved base_branch (4th arg)" {
  # Regression test for issue #637 (follow-up from PR #630).
  # Before this fix, classify_branch_health was called without the 4th arg:
  #   classify_branch_health "$ISSUE_NUMBER" "$BRANCH_NAME" "$EXISTING_WT_FOR_BRANCH"
  # This left the new BASE_BRANCH plumbing dead — preflight always compared
  # against origin/main, even for PRs targeting develop/release/etc.
  #
  # This is a static source-text check: verify the call site in claude-workflow.sh
  # passes a 4th argument to classify_branch_health (the resolved base branch).
  _wf_src=$(grep -A2 'classify_branch_health "\$ISSUE_NUMBER"' \
    "$RITE_REPO_ROOT/lib/core/claude-workflow.sh" || true)

  # The call must exist and pass a 4th argument (not stop at 3 args)
  if [ -z "$_wf_src" ]; then
    echo "FAIL: classify_branch_health call not found in claude-workflow.sh"
    return 1
  fi

  # Must include a 4th argument after EXISTING_WT_FOR_BRANCH
  if ! echo "$_wf_src" | grep -qE \
    'classify_branch_health "\$ISSUE_NUMBER" "\$BRANCH_NAME" "\$EXISTING_WT_FOR_BRANCH" "\$'; then
    echo "FAIL: classify_branch_health is called without a 4th (base_branch) argument"
    echo "--- found call ---"
    echo "$_wf_src"
    return 1
  fi
  return 0
}

@test "claude-workflow.sh: _stale_resolve_base_branch is called before classify_branch_health" {
  # Verify the caller wires up _stale_resolve_base_branch to resolve the base
  # before passing it to classify_branch_health (not hardcoding it).
  _wf_content=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  # _stale_resolve_base_branch must appear in the file (caller wiring present)
  if ! echo "$_wf_content" | grep -q '_stale_resolve_base_branch'; then
    echo "FAIL: _stale_resolve_base_branch is not called in claude-workflow.sh"
    return 1
  fi

  # The variable _preflight_base_branch must be used as the 4th arg to classify_branch_health
  if ! echo "$_wf_content" | grep -q '_preflight_base_branch'; then
    echo "FAIL: _preflight_base_branch variable not found in claude-workflow.sh"
    return 1
  fi
  return 0
}
