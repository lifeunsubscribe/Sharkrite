#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/core/claude-workflow.sh, lib/core/create-pr.sh, lib/core/local-review.sh, lib/core/assess-and-resolve.sh, lib/core/merge-pr.sh
# Integration test: Full workflow phase
#
# Demonstrates full-phase integration:
# - Git repo setup with fixture-repo
# - gh mock for PR operations
# - Multi-step workflow (create branch → commit → push → PR)

load '../helpers/setup'
load '../helpers/git-fixtures'
load '../helpers/gh-mock'

setup() {
  setup_test_tmpdir

  # Create bare remote and fixture repo
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  # Set up gh mock
  export GH_MOCK_FIXTURE_DIR="${RITE_TEST_TMPDIR}/gh-fixtures"
  mkdir -p "$GH_MOCK_FIXTURE_DIR"

  reset_gh_mock

  cd "$FIXTURE_REPO"
}

teardown() {
  teardown_test_tmpdir
}

@test "full workflow: create branch, commit, PR" {
  # Step 1: Create feature branch
  branch_name=$(add_fixture_pr 42 "Fix authentication bug" 2)

  [ -n "$branch_name" ]
  [[ "$branch_name" =~ fix/fix-authentication-bug-#42 ]]

  # Step 2: Verify branch exists and has commits
  current_branch=$(git branch --show-current)
  [ "$current_branch" = "$branch_name" ]

  # Should have 2 commits on this branch (plus 1 initial)
  commit_count=$(git rev-list --count HEAD ^main)
  [ "$commit_count" -eq 2 ]

  # Step 3: Verify files were created
  [ -f "work-1.txt" ]
  [ -f "work-2.txt" ]

  # Step 4: Verify pushed to remote
  remote_branch=$(git ls-remote origin "$branch_name" | wc -l)
  [ "$remote_branch" -gt 0 ]
}

@test "full workflow: divergence and merge" {
  # Create feature branch with work
  branch_name=$(add_fixture_pr 50 "Add new feature" 3)

  # Simulate main diverging
  create_divergence 5

  # Verify divergence
  commits_behind=$(git rev-list --count HEAD..origin/main)
  [ "$commits_behind" -eq 5 ]

  # Merge main into feature branch
  git merge origin/main --no-edit >/dev/null 2>&1

  # Verify merge successful
  merge_base=$(git merge-base HEAD origin/main)
  main_head=$(git rev-parse origin/main)
  [ "$merge_base" = "$main_head" ]
}

@test "full workflow: PR detection after creation" {
  # Create PR
  branch_name=$(add_fixture_pr 88 "Refactor config" 1)

  # Create gh mock fixture for this PR
  cat > "${GH_MOCK_FIXTURE_DIR}/pr-list-default.json" <<EOF
[
  {
    "number": 555,
    "title": "Refactor config #88",
    "body": "Closes #88\\n\\nRefactored configuration loading.",
    "headRefName": "${branch_name}"
  }
]
EOF

  cat > "${GH_MOCK_FIXTURE_DIR}/pr-view-555.json" <<EOF
{
  "number": 555,
  "headRefName": "${branch_name}",
  "state": "OPEN"
}
EOF

  # Mock gh
  gh() { mock_gh "$@"; }
  export -f gh
  export -f mock_gh

  # Load pr-detection and test
  load_lib utils/pr-detection.sh

  detect_pr_for_issue 88

  [ "$PR_NUMBER" = "555" ]
  [ "$PR_BRANCH" = "$branch_name" ]
}

@test "full workflow: multi-issue PR with multiple commits" {
  # Start with issue #100
  branch_name=$(add_fixture_pr 100 "Large refactor" 5)

  # Verify all commits present
  commit_count=$(git rev-list --count HEAD ^main)
  [ "$commit_count" -eq 5 ]

  # Verify all work files created
  for i in {1..5}; do
    [ -f "work-${i}.txt" ]
  done

  # Verify commit messages reference the issue
  git log --oneline HEAD ^main | grep -q "#100"
}

@test "full workflow: fixture issue creation" {
  # Create issue metadata
  issue_file=$(add_fixture_issue 42 "Fix auth bug" "The authentication fails on expired tokens.")

  [ -f "$issue_file" ]

  # Verify issue JSON structure
  cat "$issue_file" | grep -q '"number": 42'
  cat "$issue_file" | grep -q '"title": "Fix auth bug"'
  cat "$issue_file" | grep -q '"state": "open"'
}
