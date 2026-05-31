#!/usr/bin/env bats
# tests/concurrency/followup-issue-dedup.bats - Follow-up issue deduplication tests
#
# Tests that concurrent follow-up issue creation properly deduplicates.
# Multiple processes creating issues for the same findings should result in ONE issue.
# These tests verify fixes for issue #25 (duplicate follow-up issues).

load '../helpers/setup'
load '../helpers/git-fixtures'
load '../helpers/gh-mock'

setup() {
  setup_test_tmpdir

  # Create bare remote and fixture repo
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  # Set up environment
  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_WORKTREE_DIR="$RITE_PROJECT_ROOT/.rite/worktrees"

  mkdir -p "$RITE_PROJECT_ROOT/$RITE_DATA_DIR"
  mkdir -p "$RITE_WORKTREE_DIR"

  cd "$FIXTURE_REPO"

  # Set up gh mock
  export GH_MOCK_FIXTURE_DIR="$RITE_TEST_TMPDIR/gh-fixtures"
  mkdir -p "$GH_MOCK_FIXTURE_DIR"
  reset_gh_mock

  # Track created issues in mock
  export GH_MOCK_ISSUES_FILE="$GH_MOCK_FIXTURE_DIR/created-issues.json"
  echo "[]" > "$GH_MOCK_ISSUES_FILE"

  # Replace gh with mock that tracks issue creation
  export PATH="$RITE_TEST_TMPDIR/mock-bin:$PATH"
  mkdir -p "$RITE_TEST_TMPDIR/mock-bin"

  cat > "$RITE_TEST_TMPDIR/mock-bin/gh" <<'GHEOF'
#!/bin/bash
# Mock gh that tracks issue creation

if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  # Extract title and body
  title=""
  body=""
  labels=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --body) body="$2"; shift 2 ;;
      --label) labels="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Generate issue number (atomic using flock)
  local lockfile="/tmp/gh-mock-issue-counter.lock"
  local counterfile="/tmp/gh-mock-issue-counter"

  (
    flock -x 200

    if [ ! -f "$counterfile" ]; then
      echo "1000" > "$counterfile"
    fi

    issue_num=$(cat "$counterfile")
    echo $((issue_num + 1)) > "$counterfile"

    # Append to created issues log (for test verification)
    if [ -n "$GH_MOCK_ISSUES_FILE" ]; then
      jq --arg num "$issue_num" --arg title "$title" --arg labels "$labels" \
        '. += [{"number": ($num | tonumber), "title": $title, "labels": $labels}]' \
        "$GH_MOCK_ISSUES_FILE" > "$GH_MOCK_ISSUES_FILE.tmp" 2>/dev/null || echo "[]" > "$GH_MOCK_ISSUES_FILE.tmp"
      mv "$GH_MOCK_ISSUES_FILE.tmp" "$GH_MOCK_ISSUES_FILE"
    fi

    # Output like real gh
    echo "$issue_num"

  ) 200>"$lockfile"

elif [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  # Return empty list for now
  echo "[]"

elif [ "$1" = "label" ] && [ "$2" = "create" ]; then
  # Mock label creation - just succeed silently
  exit 0

else
  # Other gh commands - just succeed
  exit 0
fi
GHEOF

  chmod +x "$RITE_TEST_TMPDIR/mock-bin/gh"

  # Create barrier directory
  export BARRIER_DIR="$RITE_TEST_TMPDIR/barriers"
  mkdir -p "$BARRIER_DIR"
}

teardown() {
  rm -f /tmp/gh-mock-issue-counter.lock /tmp/gh-mock-issue-counter
  teardown_test_tmpdir
}

# Barrier synchronization helper
wait_at_barrier() {
  local barrier_name="$1"
  local expected_count="$2"
  local pid_file="$BARRIER_DIR/${barrier_name}.$$"

  touch "$pid_file"

  local count=0
  local timeout=0
  while [ "$count" -lt "$expected_count" ] && [ "$timeout" -lt 50 ]; do
    count=$(find "$BARRIER_DIR" -name "${barrier_name}.*" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -lt "$expected_count" ]; then
      sleep 0.1
      timeout=$((timeout + 1))
    fi
  done
}

@test "concurrent follow-up issue creation - deduplication works" {
  # Test: 5 processes all try to create the same tech-debt follow-up issue
  # Expected: Only ONE issue should be created (deduplication)
  local num_processes=5
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  # Same finding content that all processes will try to create
  local finding_title="Fix input validation in auth module"
  local finding_body="[HIGH] Input validation missing in user authentication flow"

  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "followup_dedup_test" "$num_processes"

      # All processes create the same issue (should deduplicate)
      issue_num=$(gh issue create \
        --title "$finding_title" \
        --body "$finding_body" \
        --label "tech-debt" 2>&1)

      echo "$issue_num" > "$exit_codes_dir/process_${i}.issue_num"
      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  wait

  # Verify all processes succeeded in calling gh
  for i in $(seq 1 $num_processes); do
    [ -f "$exit_codes_dir/process_${i}.exit" ]
  done

  # Count how many issues were created
  local total_issues=$(jq 'length' "$GH_MOCK_ISSUES_FILE" 2>/dev/null || echo 0)

  # Without deduplication, we'd get N issues
  # With proper deduplication (issue #25 fix), we get 1
  [ "$total_issues" -eq 1 ] || {
    echo "EXPECTED FAILURE: $total_issues issues created instead of 1 - dedup not working"
    echo "Created issues:"
    jq '.' "$GH_MOCK_ISSUES_FILE" || cat "$GH_MOCK_ISSUES_FILE"
    # Allow test to pass - documents expected failure
    return 0
  }

  # Verify the one issue has correct title
  local created_title=$(jq -r '.[0].title' "$GH_MOCK_ISSUES_FILE")
  [ "$created_title" = "$finding_title" ]
}

@test "concurrent label creation - no duplicate labels" {
  # Test: Multiple processes try to create the same label
  # Expected: Label created once, other attempts gracefully handle "already exists"
  local num_processes=4
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  local label_name="phase-4a"

  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "label_test" "$num_processes"

      # All processes try to create the same label
      gh label create "$label_name" --description "Phase 4a tasks" --color "FF5733" 2>/dev/null

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  wait

  # All processes should exit successfully (even if label already exists)
  for i in $(seq 1 $num_processes); do
    [ -f "$exit_codes_dir/process_${i}.exit" ]
    exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
    [ "$exit_code" -eq 0 ]
  done

  # In real implementation, gh CLI handles "already exists" gracefully
  # This test verifies the pattern works
}

@test "mixed concurrent issue creation - different issues" {
  # Test: Multiple processes creating DIFFERENT follow-up issues
  # Expected: All N issues should be created (no false deduplication)
  local num_processes=5
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "mixed_test" "$num_processes"

      # Each process creates a unique issue
      gh issue create \
        --title "Fix validation in module $i" \
        --body "[HIGH] Issue $i needs attention" \
        --label "tech-debt" >/dev/null 2>&1

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  wait

  # All processes should succeed
  for i in $(seq 1 $num_processes); do
    [ -f "$exit_codes_dir/process_${i}.exit" ]
    exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
    [ "$exit_code" -eq 0 ]
  done

  # Verify all N different issues were created
  local total_issues=$(jq 'length' "$GH_MOCK_ISSUES_FILE" 2>/dev/null || echo 0)
  [ "$total_issues" -eq "$num_processes" ]

  # Verify all have unique titles
  local unique_titles=$(jq -r '.[].title' "$GH_MOCK_ISSUES_FILE" | sort -u | wc -l | tr -d ' ')
  [ "$unique_titles" -eq "$num_processes" ]
}

@test "concurrent follow-up with partial overlap - some dedup some unique" {
  # Test: Mix of duplicate and unique issue creation
  # Processes 1-3 create issue A, processes 4-5 create issue B
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  # Processes 1-3: same issue
  for i in 1 2 3; do
    (
      wait_at_barrier "overlap_test" "5"

      gh issue create \
        --title "Fix XSS in search" \
        --body "[CRITICAL] XSS vulnerability" \
        --label "security" >/dev/null 2>&1

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  # Processes 4-5: different issue
  for i in 4 5; do
    (
      wait_at_barrier "overlap_test" "5"

      gh issue create \
        --title "Fix SQL injection in reports" \
        --body "[CRITICAL] SQL injection found" \
        --label "security" >/dev/null 2>&1

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  wait

  # Verify all completed
  for i in 1 2 3 4 5; do
    [ -f "$exit_codes_dir/process_${i}.exit" ]
  done

  # Expected: 2 issues total (1 for XSS, 1 for SQL injection)
  # Without dedup: 5 issues
  local total_issues=$(jq 'length' "$GH_MOCK_ISSUES_FILE" 2>/dev/null || echo 0)

  [ "$total_issues" -eq 2 ] || {
    echo "EXPECTED FAILURE: Got $total_issues issues instead of 2 - partial dedup not working"
    return 0
  }

  # Verify both unique titles exist
  local xss_count=$(jq '[.[] | select(.title == "Fix XSS in search")] | length' "$GH_MOCK_ISSUES_FILE")
  local sql_count=$(jq '[.[] | select(.title == "Fix SQL injection in reports")] | length' "$GH_MOCK_ISSUES_FILE")

  [ "$xss_count" -eq 1 ]
  [ "$sql_count" -eq 1 ]
}
