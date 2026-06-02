#!/usr/bin/env bats
# tests/regression/gh-mock-binary-concurrent.bats
#
# Regression tests verifying that gh-mock-binary.sh's stateful issue-create
# is safe for concurrent (parallel subprocess) invocation.
#
# Background:
#   The shared _gh_mock_state_issue_create function (in gh-mock-state.bash) is
#   SEQUENTIAL-ONLY: it performs a non-atomic read-compute-write on both the
#   issue-number counter (next-issue-num.txt) and the issues JSON array
#   (issues.json).  Two concurrent invocations from parallel subshells would
#   race and produce duplicate issue numbers or silently lose appends.
#
#   gh-mock-binary.sh is the standalone subprocess version of the mock.
#   It wraps the read-compute-write in flock(1) around calls to the shared
#   library, making it safe for parallel subprocess use.  These tests verify
#   that the locking is effective:
#
#   1. N parallel invocations of "gh issue create" all produce distinct issue
#      numbers (counter increments do not collide).
#   2. All N issues are recorded in issues.json (no appends lost).
#   3. N parallel "gh pr comment" invocations all record their comments (no
#      comments silently clobbered).
#
# The tests are skipped on systems where flock(1) is unavailable, because the
# binary falls back to sequential-only behaviour there.
#
# Verification command:
#   bats tests/regression/gh-mock-binary-concurrent.bats

load '../helpers/setup.bash'

# Path to the binary mock under test
GH_MOCK_BIN="${RITE_REPO_ROOT}/tests/helpers/gh-mock-binary.sh"

setup() {
  # Guard: verify required environment variables are set before proceeding.
  # Without these, tests would silently operate on wrong paths and produce
  # false passes — which is especially harmful for concurrency correctness tests.
  [[ -n "${RITE_TEST_TMPDIR:-}" ]] || {
    echo "setup: RITE_TEST_TMPDIR is not set — check tests/helpers/setup.bash" >&2
    return 1
  }
  [[ -n "${RITE_REPO_ROOT:-}" ]] || {
    echo "setup: RITE_REPO_ROOT is not set — check tests/helpers/setup.bash" >&2
    return 1
  }

  setup_test_tmpdir

  export GH_MOCK_STATE_DIR="${RITE_TEST_TMPDIR}/gh-mock-state"
  mkdir -p "$GH_MOCK_STATE_DIR"

  # Initialise state files (mirrors what setup_gh_mock_state does)
  echo "[]" > "${GH_MOCK_STATE_DIR}/issues.json"
  echo "{}" > "${GH_MOCK_STATE_DIR}/pr-comments.json"
  echo "0"  > "${GH_MOCK_STATE_DIR}/search-lag.txt"
  echo "0"  > "${GH_MOCK_STATE_DIR}/next-issue-num.txt"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Skip helper: skip on systems without flock
# ---------------------------------------------------------------------------
_require_flock() {
  if ! command -v flock >/dev/null 2>&1; then
    skip "flock(1) not available — concurrent locking cannot be tested on this platform"
  fi
}

# ---------------------------------------------------------------------------
# 1. Parallel issue creates produce distinct issue numbers
# ---------------------------------------------------------------------------

@test "concurrent gh issue create: 5 parallel invocations produce 5 distinct issue numbers" {
  _require_flock

  local body_file="${RITE_TEST_TMPDIR}/body.md"
  echo "test body" > "$body_file"

  local num_procs=5
  local pids=()

  # Launch N parallel invocations
  for i in $(seq 1 $num_procs); do
    (
      export GH_MOCK_STATE_DIR
      "$GH_MOCK_BIN" issue create \
        --title "Issue $i" \
        --body-file "$body_file" \
        --label "test"
    ) &
    pids+=($!)
  done

  # Wait for all to complete
  local failures=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failures=$(( failures + 1 ))
  done

  [ "$failures" -eq 0 ] || {
    echo "FAIL: $failures parallel invocations failed (non-zero exit)"
    false
  }

  # Count how many issues were recorded in the JSON state file
  local recorded_count
  recorded_count=$(jq 'length' "${GH_MOCK_STATE_DIR}/issues.json")

  [ "$recorded_count" -eq "$num_procs" ] || {
    echo "FAIL: Expected $num_procs issues in issues.json, got $recorded_count"
    echo "issues.json contents:"
    cat "${GH_MOCK_STATE_DIR}/issues.json"
    false
  }

  # Verify all issue numbers are distinct (no duplicates from racing counter reads)
  local distinct_count
  distinct_count=$(jq '[.[].number] | unique | length' "${GH_MOCK_STATE_DIR}/issues.json")

  [ "$distinct_count" -eq "$num_procs" ] || {
    echo "FAIL: Expected $num_procs distinct issue numbers, got $distinct_count (duplicates present)"
    echo "Issue numbers:"
    jq '[.[].number]' "${GH_MOCK_STATE_DIR}/issues.json"
    false
  }
}

@test "concurrent gh issue create: 10 parallel invocations produce 10 distinct issue numbers" {
  _require_flock

  local body_file="${RITE_TEST_TMPDIR}/body.md"
  echo "test body" > "$body_file"

  local num_procs=10
  local pids=()

  for i in $(seq 1 $num_procs); do
    (
      export GH_MOCK_STATE_DIR
      "$GH_MOCK_BIN" issue create \
        --title "Issue $i" \
        --body-file "$body_file"
    ) &
    pids+=($!)
  done

  local failures=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failures=$(( failures + 1 ))
  done

  [ "$failures" -eq 0 ] || {
    echo "FAIL: $failures parallel invocations failed (non-zero exit)"
    false
  }

  local recorded_count
  recorded_count=$(jq 'length' "${GH_MOCK_STATE_DIR}/issues.json")

  [ "$recorded_count" -eq "$num_procs" ] || {
    echo "FAIL: Expected $num_procs issues, got $recorded_count"
    cat "${GH_MOCK_STATE_DIR}/issues.json"
    false
  }

  local distinct_count
  distinct_count=$(jq '[.[].number] | unique | length' "${GH_MOCK_STATE_DIR}/issues.json")

  [ "$distinct_count" -eq "$num_procs" ] || {
    echo "FAIL: Expected $num_procs distinct numbers, got $distinct_count"
    jq '[.[].number]' "${GH_MOCK_STATE_DIR}/issues.json"
    false
  }
}

# ---------------------------------------------------------------------------
# 2. Parallel pr comment writes all survive (no silent clobbers)
# ---------------------------------------------------------------------------

@test "concurrent gh pr comment: 5 parallel invocations on same PR all recorded" {
  _require_flock

  local num_procs=5
  local pr_num=42
  local pids=()

  for i in $(seq 1 $num_procs); do
    local comment_file="${RITE_TEST_TMPDIR}/comment-${i}.md"
    echo "<!-- sharkrite-followup-issue:100${i} --> comment $i" > "$comment_file"
    (
      export GH_MOCK_STATE_DIR
      "$GH_MOCK_BIN" pr comment "$pr_num" --body-file "$comment_file"
    ) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  # Count comments recorded for this PR
  local comment_count
  comment_count=$(jq --arg pr "$pr_num" \
    'if has($pr) then .[$pr] | length else 0 end' \
    "${GH_MOCK_STATE_DIR}/pr-comments.json")

  [ "$comment_count" -eq "$num_procs" ] || {
    echo "FAIL: Expected $num_procs comments for PR $pr_num, got $comment_count"
    echo "pr-comments.json:"
    cat "${GH_MOCK_STATE_DIR}/pr-comments.json"
    false
  }
}

# ---------------------------------------------------------------------------
# 3. Mixed parallel creates + comments: all operations complete correctly
# ---------------------------------------------------------------------------

@test "concurrent mixed creates and comments: all operations recorded without loss" {
  _require_flock

  local body_file="${RITE_TEST_TMPDIR}/body.md"
  echo "test body" > "$body_file"

  local num_creates=5
  local num_comments=5
  local pr_num=99
  local pids=()

  # Launch parallel issue creates
  for i in $(seq 1 $num_creates); do
    (
      export GH_MOCK_STATE_DIR
      "$GH_MOCK_BIN" issue create \
        --title "Mixed issue $i" \
        --body-file "$body_file"
    ) &
    pids+=($!)
  done

  # Launch parallel pr comments simultaneously
  for i in $(seq 1 $num_comments); do
    local comment_file="${RITE_TEST_TMPDIR}/mixed-comment-${i}.md"
    echo "comment body $i" > "$comment_file"
    (
      export GH_MOCK_STATE_DIR
      "$GH_MOCK_BIN" pr comment "$pr_num" --body-file "$comment_file"
    ) &
    pids+=($!)
  done

  local failures=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failures=$(( failures + 1 ))
  done

  [ "$failures" -eq 0 ] || {
    echo "FAIL: $failures parallel invocations failed (non-zero exit)"
    false
  }

  # All issue creates must have been recorded
  local issue_count
  issue_count=$(jq 'length' "${GH_MOCK_STATE_DIR}/issues.json")
  [ "$issue_count" -eq "$num_creates" ] || {
    echo "FAIL: Expected $num_creates issues, got $issue_count"
    cat "${GH_MOCK_STATE_DIR}/issues.json"
    false
  }

  # All issue numbers must be distinct
  local distinct_count
  distinct_count=$(jq '[.[].number] | unique | length' "${GH_MOCK_STATE_DIR}/issues.json")
  [ "$distinct_count" -eq "$num_creates" ] || {
    echo "FAIL: Expected $num_creates distinct issue numbers, got $distinct_count"
    false
  }

  # All comments must have been recorded
  local comment_count
  comment_count=$(jq --arg pr "$pr_num" \
    'if has($pr) then .[$pr] | length else 0 end' \
    "${GH_MOCK_STATE_DIR}/pr-comments.json")
  [ "$comment_count" -eq "$num_comments" ] || {
    echo "FAIL: Expected $num_comments comments, got $comment_count"
    cat "${GH_MOCK_STATE_DIR}/pr-comments.json"
    false
  }
}

# ---------------------------------------------------------------------------
# 4. issue view not-found: binary returns exit 0 + empty (not exit 1)
#
# Regression guard for the divergence fixed in this issue:
#   gh-mock.bash previously returned exit 1 for a missing issue.
#   gh-mock-binary.sh previously returned exit 0 + empty.
#   Both now return exit 0 + empty (unified contract matching gh_safe behavior).
# ---------------------------------------------------------------------------

@test "binary: gh issue view for unknown issue returns exit 0 and empty output" {
  run "$GH_MOCK_BIN" issue view 9999 --json url --jq '.url'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "binary: gh issue view for tracked issue returns data and exit 0" {
  local body_file="${RITE_TEST_TMPDIR}/body.md"
  echo "body content" > "$body_file"

  # Create an issue and capture its number
  local url
  url=$("$GH_MOCK_BIN" issue create --title "Test issue for view" --body-file "$body_file")
  local issue_num="${url##*/}"

  run "$GH_MOCK_BIN" issue view "$issue_num" --json url --jq '.url'
  [ "$status" -eq 0 ]
  [ "$output" = "$url" ]
}

# ---------------------------------------------------------------------------
# 5. mock parity: binary and helper agree on issue view not-found behavior
#
# Verifies that after the deduplication refactor, both mocks implement the
# same contract: empty output + exit 0 for a missing issue.  This prevents
# the divergence from re-emerging if either file is edited independently.
# ---------------------------------------------------------------------------

@test "mock parity: binary and helper agree on issue view not-found (exit 0, empty output)" {
  load '../helpers/gh-mock.bash'

  # Helper mock (mock_gh) — uses gh-mock.bash in-process
  export GH_MOCK_STATE_DIR
  run mock_gh issue view 8888 --json url --jq '.url'
  local helper_status="$status"
  local helper_output="$output"

  # Binary mock — subprocess invocation
  run "$GH_MOCK_BIN" issue view 8888 --json url --jq '.url'
  local binary_status="$status"
  local binary_output="$output"

  # Both must return exit 0
  [ "$helper_status" -eq 0 ] || {
    echo "FAIL: helper mock returned exit $helper_status for not-found issue (expected 0)"
    false
  }
  [ "$binary_status" -eq 0 ] || {
    echo "FAIL: binary mock returned exit $binary_status for not-found issue (expected 0)"
    false
  }

  # Both must return empty output
  [ -z "$helper_output" ] || {
    echo "FAIL: helper mock returned non-empty output for not-found issue: '$helper_output'"
    false
  }
  [ -z "$binary_output" ] || {
    echo "FAIL: binary mock returned non-empty output for not-found issue: '$binary_output'"
    false
  }
}
