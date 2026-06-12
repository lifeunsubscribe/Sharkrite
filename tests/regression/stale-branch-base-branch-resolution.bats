#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/stale-branch.sh
# tests/regression/stale-branch-base-branch-resolution.bats
#
# Regression tests for dynamic base branch resolution in stale-branch.sh.
# Fixes the anti-pattern from #365/#420 where origin/main was hardcoded —
# stale-branch operations now use the PR's actual base branch.
#
# Tests:
#   1. _stale_resolve_base_branch falls back to "main" when PR number is empty
#   2. _stale_resolve_base_branch falls back to "main" when gh_safe returns empty
#   3. _stale_resolve_base_branch returns the API value when valid
#   4. _stale_resolve_base_branch rejects unsafe branch names (path traversal)
#   5. _stale_resolve_base_branch rejects branch names with shell meta-characters
#   6. get_commits_behind_main accepts base_branch param (no longer hardcodes main)
#   7. format_stale_close_comment uses provided base_branch in git commands

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
