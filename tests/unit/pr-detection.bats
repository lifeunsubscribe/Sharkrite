#!/usr/bin/env bats
# Unit test for PR detection utilities
#
# This demonstrates the git interaction test pattern:
# - Create ephemeral git repo with fixture-repo helpers
# - Mock gh CLI with fixture responses
# - Test the function's logic in isolation

load '../helpers/setup'
load '../helpers/git-fixtures'
load '../helpers/gh-mock'

setup() {
  setup_test_tmpdir

  # Create a bare remote and fixture repo
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  # Set up gh mock
  export GH_MOCK_FIXTURE_DIR="${RITE_TEST_TMPDIR}/gh-fixtures"
  mkdir -p "$GH_MOCK_FIXTURE_DIR"

  reset_gh_mock
}

teardown() {
  teardown_test_tmpdir
}

# Helper to create PR fixture for gh mock
create_test_pr_fixture() {
  local pr_number="$1"
  local issue_number="$2"
  local pr_title="$3"
  local branch_name="$4"

  cat > "${GH_MOCK_FIXTURE_DIR}/pr-list-default.json" <<EOF
[
  {
    "number": ${pr_number},
    "title": "${pr_title}",
    "body": "Closes #${issue_number}\\n\\nThis PR fixes the issue.",
    "headRefName": "${branch_name}"
  }
]
EOF

  cat > "${GH_MOCK_FIXTURE_DIR}/pr-view-${pr_number}.json" <<EOF
{
  "number": ${pr_number},
  "headRefName": "${branch_name}",
  "state": "OPEN"
}
EOF
}

@test "detect_pr_for_issue finds PR by 'Closes #N' in body" {
  cd "$FIXTURE_REPO"

  # Create PR fixture
  create_test_pr_fixture 123 42 "Fix auth bug" "fix/auth-bug-#42"

  # Source the pr-detection utilities (with gh mocked)
  # We need to override 'gh' command to use our mock
  gh() { mock_gh "$@"; }
  export -f gh
  export -f mock_gh

  # Load the function
  load_lib utils/pr-detection.sh

  # Test the function
  detect_pr_for_issue 42
  local exit_code=$?

  # Should succeed
  [ "$exit_code" -eq 0 ]

  # Should set PR_NUMBER and PR_BRANCH
  [ "$PR_NUMBER" = "123" ]
  [ "$PR_BRANCH" = "fix/auth-bug-#42" ]
}

@test "detect_pr_for_issue returns 1 when no PR found" {
  cd "$FIXTURE_REPO"

  # Create empty PR list fixture
  echo "[]" > "${GH_MOCK_FIXTURE_DIR}/pr-list-default.json"

  # Mock gh
  gh() { mock_gh "$@"; }
  export -f gh
  export -f mock_gh

  load_lib utils/pr-detection.sh

  run detect_pr_for_issue 999

  # Should fail (no PR found)
  [ "$status" -eq 1 ]
}

@test "detect_pr_for_issue falls back to title search" {
  cd "$FIXTURE_REPO"

  # Create PR with issue only in title, not body
  cat > "${GH_MOCK_FIXTURE_DIR}/pr-list-default.json" <<'EOF'
[
  {
    "number": 456,
    "title": "Work on issue #88",
    "body": "This PR addresses the problem.",
    "headRefName": "fix/issue-88"
  }
]
EOF

  cat > "${GH_MOCK_FIXTURE_DIR}/pr-view-456.json" <<'EOF'
{
  "number": 456,
  "headRefName": "fix/issue-88",
  "state": "OPEN"
}
EOF

  gh() { mock_gh "$@"; }
  export -f gh
  export -f mock_gh

  load_lib utils/pr-detection.sh

  detect_pr_for_issue 88
  local exit_code=$?

  [ "$exit_code" -eq 0 ]
  [ "$PR_NUMBER" = "456" ]
}

@test "gh mock supports fault injection" {
  cd "$FIXTURE_REPO"

  # Configure mock to fail on 2nd call
  export GH_MOCK_FAIL_NTH=2
  export GH_MOCK_EXIT_CODE=1

  gh() { mock_gh "$@"; }
  export -f gh
  export -f mock_gh

  # First call returns exit code 1 (no fixture, but no fault injection yet)
  run mock_gh pr list
  [ "$status" -eq 1 ]  # No fixture, but doesn't hit fault injection

  # Second call fails (fault injection)
  run mock_gh pr list
  [ "$status" -eq 1 ]
  [[ "$output" =~ "mock failure" ]]
}
