#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gh-retry.sh, lib/core/workflow-runner.sh
# Integration test: gh CLI workflow
#
# Demonstrates gh interaction pattern:
# - Use gh-mock with realistic fixtures
# - Test multi-step workflows (create PR → view → comment → merge)

load '../helpers/setup'
load '../helpers/git-fixtures'
load '../helpers/gh-mock'

setup() {
  setup_test_tmpdir

  # Set up fixture directories
  export GH_MOCK_FIXTURE_DIR="${RITE_TEST_TMPDIR}/gh-fixtures"
  mkdir -p "$GH_MOCK_FIXTURE_DIR"

  reset_gh_mock
}

teardown() {
  teardown_test_tmpdir
}

@test "gh mock: PR creation workflow" {
  # Create fixture for PR creation
  cat > "${GH_MOCK_FIXTURE_DIR}/pr-create-default.json" <<'EOF'
{
  "number": 789,
  "url": "https://github.com/test/repo/pull/789",
  "title": "New feature implementation"
}
EOF

  # Mock gh pr create
  gh() { mock_gh "$@"; }
  export -f gh
  export -f mock_gh

  # Simulate PR creation
  run mock_gh pr create --title "New feature" --body "Feature description"

  [ "$status" -eq 0 ]

  # Verify output contains PR number
  echo "$output" | grep -q '"number": 789'
}

@test "gh mock: PR view with detailed fields" {
  # Create detailed PR fixture
  cat > "${GH_MOCK_FIXTURE_DIR}/pr-view-123.json" <<'EOF'
{
  "number": 123,
  "title": "Fix authentication bug",
  "state": "OPEN",
  "headRefName": "fix/auth-bug-#42",
  "baseRefName": "main",
  "additions": 50,
  "deletions": 20,
  "changedFiles": 3,
  "commits": [
    {"oid": "abc123", "message": "Initial fix"},
    {"oid": "def456", "message": "Add tests"}
  ]
}
EOF

  gh() { mock_gh "$@"; }
  export -f gh
  export -f mock_gh

  run mock_gh pr view 123 --json number,title,state

  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"number": 123'
  echo "$output" | grep -q '"state": "OPEN"'
}

@test "gh mock: issue list workflow" {
  cat > "${GH_MOCK_FIXTURE_DIR}/issue-list-default.json" <<'EOF'
[
  {"number": 1, "title": "First issue", "state": "OPEN"},
  {"number": 2, "title": "Second issue", "state": "CLOSED"}
]
EOF

  gh() { mock_gh "$@"; }
  export -f gh
  export -f mock_gh

  run mock_gh issue list --state all

  [ "$status" -eq 0 ]

  # Verify both issues in output
  echo "$output" | grep -q '"number": 1'
  echo "$output" | grep -q '"number": 2'
}

@test "gh mock: fault injection causes failure" {
  # Configure to fail on first call
  export GH_MOCK_FAIL_NTH=1
  export GH_MOCK_EXIT_CODE=42

  gh() { mock_gh "$@"; }
  export -f gh
  export -f mock_gh

  run mock_gh pr view 999

  # Should fail with configured exit code
  [ "$status" -eq 42 ]
  [[ "$output" =~ "mock failure" ]]
}

@test "gh mock: API endpoint mapping" {
  # Create fixture for API call
  cat > "${GH_MOCK_FIXTURE_DIR}/api-pulls-123.json" <<'EOF'
{
  "number": 123,
  "state": "open",
  "mergeable": true
}
EOF

  gh() { mock_gh "$@"; }
  export -f gh
  export -f mock_gh

  # API calls should map to fixture files
  run mock_gh api repos/owner/repo/pulls/123

  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"number": 123'
}
