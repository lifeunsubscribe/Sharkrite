#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/local-review.sh
# Test suite for issue #65: Add 5xx fallback to local-review GitHub diff fetch
#
# Verifies that local-review.sh retries gh pr diff on transient errors (5xx, 429)
# and falls back to local git diff when GitHub API is unavailable.
#
# These tests source fetch_pr_diff() directly from local-review.sh
# (via RITE_SOURCE_FUNCTIONS_ONLY=1) so they exercise the real production code
# rather than a copy of it.

load '../helpers/setup.bash'
load '../helpers/gh-mock.bash'
load '../helpers/fault-injection.bash'

setup() {
  # Create isolated test environment
  TEST_DIR=$(mktemp -d)
  export TEST_DIR
  export RITE_PROJECT_ROOT="$TEST_DIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

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

  # Provide logging shims required by fetch_pr_diff().
  # These all write to stderr; the diff itself goes to stdout.
  # Set RITE_DIFF_RETRY_BACKOFF=0 to skip exponential sleep in tests.
  print_status() { echo "[STATUS] $*" >&2; }
  print_error() { echo "[ERROR] $*" >&2; }
  print_warning() { echo "[WARNING] $*" >&2; }
  print_success() { echo "[SUCCESS] $*" >&2; }
  print_header() { echo "[HEADER] $*" >&2; }
  _timer_start() { :; }
  _timer_end() { :; }
  _diag() { :; }
  export -f print_status print_error print_warning print_success print_header
  export -f _timer_start _timer_end _diag
  export RITE_DIFF_RETRY_BACKOFF=0

  # Source local-review.sh in functions-only mode to load fetch_pr_diff()
  # without executing the script body (which needs config, providers, etc.).
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "${RITE_REPO_ROOT}/lib/core/local-review.sh"

  # fetch_pr_diff delegates transient 5xx/429 retries to gh_safe (lib/utils/gh-retry.sh).
  # The functions-only guard in local-review.sh returns before that file is sourced, so
  # load it here explicitly — otherwise gh_safe is undefined and the gh() mocks below
  # are never exercised (the call would be 'command not found' and fall straight through).
  # RITE_GH_RETRY_MAX_SLEEP=0 keeps the retry path instant in tests.
  export RITE_GH_RETRY_MAX_SLEEP=0
  source "${RITE_REPO_ROOT}/lib/utils/gh-retry.sh"
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
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

  # Run the real fetch_pr_diff function
  run fetch_pr_diff 123 main fix/test-feature

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

  # Run the real fetch_pr_diff function
  run fetch_pr_diff 123 main fix/test-feature

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
        # No colon after the status code: gh_safe's retry regex deliberately
        # excludes "NNN:" forms (avoids false positives like "config line 503:"),
        # so the message must read "HTTP 503 ..." for the transient-retry path to fire.
        echo "HTTP 503 Service Temporarily Unavailable" >&2
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

  # Run the real fetch_pr_diff function
  run fetch_pr_diff 123 main fix/test-feature

  # Should succeed (exit 0)
  [ "$status" -eq 0 ]

  # Should use GitHub diff (not fall back to git)
  [[ "$output" == *"diff --git a/fix.txt b/fix.txt"* ]]

  # Retry is delegated to gh_safe: it retried the transient 503 and gh was
  # called twice (fail-then-succeed), so the GitHub diff is returned without
  # the local fallback ever running.
  _n=$(cat "$_gh_count_file")
  [ "$_n" -eq 2 ]

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

  # Run the real fetch_pr_diff function
  run fetch_pr_diff 999 main fix/test-feature

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

@test "local-review.sh delegates retry to gh_safe and keeps local git fallback" {
  SCRIPT_PATH="$BATS_TEST_DIRNAME/../../lib/core/local-review.sh"

  # Retry of transient 5xx/429 is now delegated to gh_safe (lib/utils/gh-retry.sh);
  # fetch_pr_diff no longer owns an in-function retry loop. Verify the delegation.
  GH_SAFE_CALL=$(grep -c "gh_safe pr diff" "$SCRIPT_PATH" || true)
  [ "$GH_SAFE_CALL" -ge 1 ]

  # Verify git diff fallback exists
  GIT_FALLBACK=$(grep -c "git diff.*origin/\$PR_BASE.*origin/\$PR_HEAD" "$SCRIPT_PATH" || true)
  [ "$GIT_FALLBACK" -ge 1 ]

  # Verify transient error detection (5xx, 429) lives in the gh_safe wrapper,
  # which is where retry classification moved when fetch_pr_diff was refactored.
  GH_RETRY_PATH="$BATS_TEST_DIRNAME/../../lib/utils/gh-retry.sh"
  TRANSIENT_CHECK=$(grep -c "429\|5\[0-9\]\[0-9\]" "$GH_RETRY_PATH" || true)
  [ "$TRANSIENT_CHECK" -ge 1 ]

  # Verify fallback warning message
  FALLBACK_MSG=$(grep -c "falling back to local git diff" "$SCRIPT_PATH" || true)
  [ "$FALLBACK_MSG" -ge 1 ]
}
