#!/usr/bin/env bats
# tests/regression/gh-mock-backward-compat-aliases.bats
#
# Regression test: backward-compatibility aliases in gh-mock.bash
#
# Background:
#   PR #258 extracted stateful mock logic from gh-mock.bash into the shared
#   library gh-mock-state.bash.  In doing so, several internal functions were
#   renamed:
#
#     Old name (gh-mock.bash)        New name (gh-mock-state.bash)
#     ─────────────────────────────  ─────────────────────────────
#     _gh_mock_init_state            _gh_mock_state_init
#     _gh_mock_issues_file           _gh_mock_state_issues_file
#     _gh_mock_comments_file         _gh_mock_state_comments_file
#     _gh_mock_lag_file              _gh_mock_state_lag_file
#     _gh_mock_next_num_file         _gh_mock_state_next_num_file
#
#   Backward-compat wrappers (aliases) are defined in gh-mock.bash so that
#   any test or code that still calls the old names does not get
#   "command not found".  This regression test pins those aliases in place:
#   if anyone removes or renames them, these tests will fail loudly.
#
# Issue: #271
# Parent PR: #258
#
# Verification command: bats tests/regression/gh-mock-backward-compat-aliases.bats

load '../helpers/setup'
load '../helpers/gh-mock.bash'

setup() {
  setup_test_tmpdir

  export RITE_REPO_ROOT
  export GH_MOCK_STATE_DIR="$RITE_TEST_TMPDIR/gh-mock-state"
  setup_gh_mock_state
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# 1. _gh_mock_init_state alias
# ---------------------------------------------------------------------------

@test "backward-compat: _gh_mock_init_state is defined after sourcing gh-mock.bash" {
  # The alias must be a declared bash function.
  # If PR #258's backward-compat block is ever removed, this test fails.
  declare -f _gh_mock_init_state >/dev/null 2>&1
}

@test "backward-compat: _gh_mock_init_state initializes issues.json to empty array" {
  # Call the old name; it must delegate to _gh_mock_state_init and work.
  _gh_mock_init_state

  local issues_file
  issues_file=$(_gh_mock_state_issues_file)
  [ -f "$issues_file" ]
  [ "$(cat "$issues_file")" = "[]" ]
}

@test "backward-compat: _gh_mock_init_state initializes pr-comments.json to empty object" {
  _gh_mock_init_state

  local comments_file
  comments_file=$(_gh_mock_state_comments_file)
  [ -f "$comments_file" ]
  [ "$(cat "$comments_file")" = "{}" ]
}

@test "backward-compat: _gh_mock_init_state resets state (clears previously created issues)" {
  # Create an issue, then call the old init name — state must be wiped.
  local body_file="$RITE_TEST_TMPDIR/body.md"
  echo "Test body" > "$body_file"
  mock_gh issue create --title "Pre-init issue" --body-file "$body_file" > /dev/null

  local count_before
  count_before=$(gh_mock_issue_count)
  [ "$count_before" -eq 1 ]

  # Re-initialize via the old backward-compat alias
  _gh_mock_init_state

  local count_after
  count_after=$(gh_mock_issue_count)
  [ "$count_after" -eq 0 ]
}

@test "backward-compat: _gh_mock_init_state accepts and ignores extra arguments (passthrough)" {
  # The alias is defined as: _gh_mock_init_state() { _gh_mock_state_init "\$@"; }
  # _gh_mock_state_init takes no positional args, but must not crash when given them.
  _gh_mock_init_state some_extra_arg
  local issues_file
  issues_file=$(_gh_mock_state_issues_file)
  [ -f "$issues_file" ]
  [ "$(cat "$issues_file")" = "[]" ]
}

# ---------------------------------------------------------------------------
# 2. Path-helper aliases
#    Verify each old name exists and returns the same path as its new name.
# ---------------------------------------------------------------------------

@test "backward-compat: _gh_mock_issues_file returns same path as _gh_mock_state_issues_file" {
  declare -f _gh_mock_issues_file >/dev/null 2>&1

  local old_path new_path
  old_path=$(_gh_mock_issues_file)
  new_path=$(_gh_mock_state_issues_file)
  [ "$old_path" = "$new_path" ]
}

@test "backward-compat: _gh_mock_comments_file returns same path as _gh_mock_state_comments_file" {
  declare -f _gh_mock_comments_file >/dev/null 2>&1

  local old_path new_path
  old_path=$(_gh_mock_comments_file)
  new_path=$(_gh_mock_state_comments_file)
  [ "$old_path" = "$new_path" ]
}

@test "backward-compat: _gh_mock_lag_file returns same path as _gh_mock_state_lag_file" {
  declare -f _gh_mock_lag_file >/dev/null 2>&1

  local old_path new_path
  old_path=$(_gh_mock_lag_file)
  new_path=$(_gh_mock_state_lag_file)
  [ "$old_path" = "$new_path" ]
}

@test "backward-compat: _gh_mock_next_num_file returns same path as _gh_mock_state_next_num_file" {
  declare -f _gh_mock_next_num_file >/dev/null 2>&1

  local old_path new_path
  old_path=$(_gh_mock_next_num_file)
  new_path=$(_gh_mock_state_next_num_file)
  [ "$old_path" = "$new_path" ]
}

# ---------------------------------------------------------------------------
# 3. End-to-end: old init name + new API
#    Verify that initializing via the old name and then using the new API
#    works correctly (alias delegates properly, no state corruption).
# ---------------------------------------------------------------------------

@test "backward-compat: init via _gh_mock_init_state then create issue via mock_gh" {
  # Re-initialize using the old name
  _gh_mock_init_state

  local body_file="$RITE_TEST_TMPDIR/body.md"
  echo "Post-compat-init body" > "$body_file"

  run mock_gh issue create --title "After compat init" --body-file "$body_file" --label "tech-debt"
  [ "$status" -eq 0 ]
  [[ "$output" =~ /issues/[0-9]+$ ]]

  local count
  count=$(gh_mock_issue_count)
  [ "$count" -eq 1 ]
}
