#!/usr/bin/env bats
# Test suite for issue #65: Add 5xx fallback to local-review GitHub diff fetch
#
# Verifies that local-review.sh retries gh pr diff on transient errors (5xx, 429)
# and falls back to local git diff when GitHub API is unavailable.

load '../helpers/setup'
load '../helpers/gh-mock'
load '../helpers/fault-injection'

setup() {
  # Create isolated test environment
  TEST_DIR=$(mktemp -d)
  export TEST_DIR
  export RITE_PROJECT_ROOT="$TEST_DIR"

  # Create minimal .rite structure
  mkdir -p "$TEST_DIR/.rite"

  # Create git environment with remote
  cd "$TEST_DIR"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"

  # Create initial commit on main
  echo "initial" > README.md
  git add README.md
  git commit -q -m "Initial commit"
  git branch -M main

  # Set up fake remote
  REMOTE_DIR="$TEST_DIR/remote"
  git init -q --bare "$REMOTE_DIR"
  git remote add origin "$REMOTE_DIR"
  git push -q origin main

  # Create feature branch with changes
  git checkout -q -b fix/test-feature
  echo "fix applied" > fix.txt
  git add fix.txt
  git commit -q -m "fix: test change"
  git push -q origin fix/test-feature

  # Reset to main for test isolation
  git checkout -q main

  # Fetch to ensure origin refs are available
  git fetch -q origin

  # Mock environment
  reset_fault_injection
  reset_gh_mock

  # Export required functions/variables for the script under test
  export -f print_status print_error print_warning print_success print_header
  export -f _timer_start _timer_end _diag

  # Stub logging functions to avoid missing dependencies
  print_status() { echo "[STATUS] $*" >&2; }
  print_error() { echo "[ERROR] $*" >&2; }
  print_warning() { echo "[WARNING] $*" >&2; }
  print_success() { echo "[SUCCESS] $*" >&2; }
  print_header() { echo "[HEADER] $*" >&2; }
  _timer_start() { :; }
  _timer_end() { :; }
  _diag() { :; }
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

# Helper: Extract diff fetch logic into a testable function
# This simulates the exact logic from local-review.sh lines 94-146
run_diff_fetch() {
  local PR_NUMBER="${1:-123}"
  local PR_BASE="${2:-main}"
  local PR_HEAD="${3:-fix/test-feature}"

  # Retry gh pr diff up to 3 times (handles transient 5xx/429 errors)
  MAX_DIFF_ATTEMPTS=3
  DIFF_ATTEMPT=0
  PR_DIFF=""
  GH_DIFF_ERROR=""
  GH_DIFF_SUCCESS=false

  while [ $DIFF_ATTEMPT -lt $MAX_DIFF_ATTEMPTS ] && [ "$GH_DIFF_SUCCESS" != true ]; do
    DIFF_ATTEMPT=$((DIFF_ATTEMPT + 1))

    GH_DIFF_ERROR=$(gh pr diff "$PR_NUMBER" 2>&1) && {
      PR_DIFF="$GH_DIFF_ERROR"
      GH_DIFF_SUCCESS=true
      break
    }

    # Check if error is transient (5xx, 429, network issues)
    if echo "$GH_DIFF_ERROR" | grep -qiE "500|502|503|504|429|timeout|temporarily unavailable|heavy server load"; then
      if [ $DIFF_ATTEMPT -lt $MAX_DIFF_ATTEMPTS ]; then
        # Exponential backoff: 2s, 4s (use 0s in tests for speed)
        BACKOFF=0
        print_warning "GitHub diff API error (attempt $DIFF_ATTEMPT/$MAX_DIFF_ATTEMPTS) - retrying in ${BACKOFF}s..."
        sleep "$BACKOFF"
        continue
      fi
    else
      # Non-transient error - don't retry
      break
    fi
  done

  # If gh pr diff failed after all retries, fall back to local git diff
  if [ "$GH_DIFF_SUCCESS" != true ]; then
    print_warning "GitHub diff API unavailable — falling back to local git diff"

    # Use git diff with the three-dot syntax (merge-base..HEAD)
    PR_DIFF=$(git diff "origin/$PR_BASE...origin/$PR_HEAD" 2>&1) || {
      print_error "Failed to fetch diff via both GitHub API and local git"
      echo ""
      echo "GitHub API error:"
      echo "$GH_DIFF_ERROR"
      echo ""
      echo "Git diff error:"
      echo "$PR_DIFF"
      return 1
    }

    print_status "Using local git diff as fallback"
  fi

  # Output the diff
  echo "$PR_DIFF"
  return 0
}

@test "gh pr diff 500 error falls back to local git diff" {
  # Simulate GitHub API returning 500 error
  export GH_MOCK_EXIT_CODE=1
  export GH_MOCK_STDERR="could not find pull request diff: HTTP 500: Server Error: Sorry, this diff is temporarily unavailable due to heavy server load."

  # Override gh command to return the mock error
  gh() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      echo "$GH_MOCK_STDERR" >&2
      return "$GH_MOCK_EXIT_CODE"
    fi
    command gh "$@"
  }
  export -f gh

  # Run the diff fetch logic
  run run_diff_fetch 123 main fix/test-feature

  # Should succeed (exit 0) using local git diff
  [ "$status" -eq 0 ]

  # Should contain the actual diff content
  [[ "$output" == *"diff --git"* ]]
  [[ "$output" == *"fix.txt"* ]]

  # Should have logged the fallback
  [[ "$output" == *"falling back to local git diff"* ]]
}

@test "both gh and git diff fail - exits with clear error" {
  # Simulate GitHub API failure
  export GH_MOCK_EXIT_CODE=1
  export GH_MOCK_STDERR="HTTP 500: Server Error"

  # Override gh to fail
  gh() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      echo "$GH_MOCK_STDERR" >&2
      return "$GH_MOCK_EXIT_CODE"
    fi
    command gh "$@"
  }
  export -f gh

  # Override git diff to also fail (simulate corrupt repo)
  git() {
    if [ "$1" = "diff" ]; then
      echo "fatal: bad object origin/main" >&2
      return 128
    fi
    command git "$@"
  }
  export -f git

  # Run the diff fetch logic
  run run_diff_fetch 123 main fix/test-feature

  # Should fail (exit 1)
  [ "$status" -eq 1 ]

  # Should display both errors
  [[ "$output" == *"Failed to fetch diff via both GitHub API and local git"* ]]
  [[ "$output" == *"GitHub API error:"* ]]
  [[ "$output" == *"Git diff error:"* ]]
}

@test "gh pr diff succeeds on retry after transient failure" {
  # Track call count using a temp file (survives subshell)
  _gh_count_file=$(mktemp)
  echo "0" > "$_gh_count_file"

  # Override gh to fail on first call, succeed on second
  gh() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      _gh_call_count=$(cat "$_gh_count_file")
      _gh_call_count=$((_gh_call_count + 1))
      echo "$_gh_call_count" > "$_gh_count_file"

      if [ $_gh_call_count -eq 1 ]; then
        echo "HTTP 503: Service Temporarily Unavailable" >&2
        return 1
      else
        # Return a valid diff
        echo "diff --git a/fix.txt b/fix.txt"
        echo "new file mode 100644"
        echo "--- /dev/null"
        echo "+++ b/fix.txt"
        echo "@@ -0,0 +1 @@"
        echo "+fix applied"
        return 0
      fi
    fi
    command gh "$@"
  }
  export -f gh
  export _gh_count_file

  # Run the diff fetch logic
  run run_diff_fetch 123 main fix/test-feature

  # Should succeed (exit 0)
  [ "$status" -eq 0 ]

  # Should use GitHub diff (not fall back to git)
  [[ "$output" == *"diff --git a/fix.txt b/fix.txt"* ]]

  # Should have logged the retry
  [[ "$output" == *"GitHub diff API error (attempt 1/3)"* ]]

  # Should NOT have fallen back to local git
  [[ "$output" != *"falling back to local git diff"* ]]

  # Cleanup
  rm -f "$_gh_count_file"
}

@test "non-transient gh error (404) does not retry" {
  # Track call count using a temp file (survives subshell)
  _gh_count_file=$(mktemp)
  echo "0" > "$_gh_count_file"

  # Override gh to return 404 (non-transient)
  gh() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      _gh_call_count=$(cat "$_gh_count_file")
      _gh_call_count=$((_gh_call_count + 1))
      echo "$_gh_call_count" > "$_gh_count_file"
      echo "HTTP 404: Not Found - PR does not exist" >&2
      return 1
    fi
    command gh "$@"
  }
  export -f gh
  export _gh_count_file

  # Run the diff fetch logic
  run run_diff_fetch 999 main fix/test-feature

  # Should use fallback immediately (exit 0 with local git diff)
  [ "$status" -eq 0 ]

  # Should only call gh once (no retry for 404)
  _final_count=$(cat "$_gh_count_file")
  [ "$_final_count" -eq 1 ]

  # Should fall back to local git diff
  [[ "$output" == *"falling back to local git diff"* ]]

  # Cleanup
  rm -f "$_gh_count_file"
}

@test "actual local-review.sh contains retry and fallback logic" {
  SCRIPT_PATH="$BATS_TEST_DIRNAME/../../lib/core/local-review.sh"

  # Verify retry loop exists
  RETRY_LOOP=$(grep -c "while \[ \$DIFF_ATTEMPT -lt \$MAX_DIFF_ATTEMPTS \]" "$SCRIPT_PATH" || true)
  [ "$RETRY_LOOP" -ge 1 ]

  # Verify git diff fallback exists
  GIT_FALLBACK=$(grep -c "git diff.*origin/\$PR_BASE.*origin/\$PR_HEAD" "$SCRIPT_PATH" || true)
  [ "$GIT_FALLBACK" -ge 1 ]

  # Verify transient error detection (5xx, 429)
  TRANSIENT_CHECK=$(grep -c "500|502|503|504|429" "$SCRIPT_PATH" || true)
  [ "$TRANSIENT_CHECK" -ge 1 ]

  # Verify fallback warning message
  FALLBACK_MSG=$(grep -c "falling back to local git diff" "$SCRIPT_PATH" || true)
  [ "$FALLBACK_MSG" -ge 1 ]
}
