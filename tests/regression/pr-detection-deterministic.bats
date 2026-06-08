#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/pr-detection.sh
# tests/regression/pr-detection-deterministic.bats
#
# Regression test for: PR detection non-determinism across duplicate PRs
#
# Bug: detect_pr_for_issue used `head -1` on unordered `gh pr list` output.
# When both a CLOSED and an OPEN PR reference the same issue (common after
# `rite undo` + new attempt), GitHub's API returns them in arbitrary order.
# head -1 could return either one — often the CLOSED PR — causing subsequent
# operations (review posting, merge) to target the wrong PR.
#
# Fix: Replace `head -1` with a deterministic jq ordering:
#   - For `--state open` queries: sort_by(.number) | last  (highest number wins)
#   - For `--state all` queries: sort_by([OPEN_flag, .number]) | last
#
# Tests in this file:
#   1. OPEN PR is always picked when both OPEN and CLOSED reference same issue
#   2. Detection is stable across 10 repeated calls (no ordering flakiness)
#   3. Higher-numbered OPEN PR wins when multiple open PRs reference same issue
#   4. Returns empty when no PR references the issue
#   5. Returns the single result when exactly one PR matches

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: minimal env + mock gh binary
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  # Create a minimal git repo so config.sh's detect_project_root() succeeds
  git init --quiet "$RITE_TEST_TMPDIR/repo"
  cd "$RITE_TEST_TMPDIR/repo"
  git commit --quiet --allow-empty -m "init"

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/repo"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Create mock gh binary
  export MOCK_BIN_DIR="$RITE_TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_BIN_DIR"

  # GH_MOCK_RESPONSE_FILE controls what `gh pr list` returns.
  # Tests set this to a JSON file path before invoking detect_pr_for_issue.
  export GH_MOCK_RESPONSE_FILE="$RITE_TEST_TMPDIR/gh-response.json"

  cat > "$MOCK_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
# Minimal gh mock for pr-detection-deterministic tests.
#
# Intercepts:
#   gh pr list --state open   -> returns only OPEN records from GH_MOCK_RESPONSE_FILE
#   gh pr list --state all    -> returns all records
#   gh pr list (no state)     -> returns all records
#   gh pr view N --json ...   -> returns matching record
#   anything else             -> exits 0 silently
#
# GH_MOCK_RESPONSE_FILE must be a JSON array of PR objects with fields:
#   number, state, headRefName, body, title

_resp="${GH_MOCK_RESPONSE_FILE:-/dev/null}"

if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  _state="all"
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) _state="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [ "$_state" = "open" ]; then
    jq '[.[] | select(.state == "OPEN")]' "$_resp" 2>/dev/null || echo "[]"
  else
    jq '.' "$_resp" 2>/dev/null || echo "[]"
  fi

elif [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  _pr_num="$3"
  # Parse optional --jq filter (gh pr view N --json fields --jq '.field')
  _jq_filter=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --jq) _jq_filter="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  _pr_json=$(jq --argjson num "$_pr_num" '.[] | select(.number == $num)' \
    "$_resp" 2>/dev/null || echo "{}")

  if [ -n "$_jq_filter" ]; then
    echo "$_pr_json" | jq -r "$_jq_filter" 2>/dev/null || echo ""
  else
    echo "$_pr_json"
  fi

else
  exit 0
fi
GHEOF
  chmod +x "$MOCK_BIN_DIR/gh"

  # Prepend mock bin to PATH
  export PATH="$MOCK_BIN_DIR:$PATH"

  # Source pr-detection.sh (which sources date-helpers.sh via RITE_LIB_DIR)
  # RITE_LIB_DIR is already set above, so pr-detection.sh skips config.sh sourcing
  # shellcheck disable=SC1090
  source "${RITE_REPO_ROOT}/lib/utils/pr-detection.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: write the mock gh response file
# ---------------------------------------------------------------------------
write_gh_response() {
  # Usage: write_gh_response '[{...}, {...}]'
  # Use printf (not echo) to avoid macOS echo expanding \n into real newlines,
  # which would produce invalid JSON (bare newline inside a string literal).
  printf '%s\n' "$1" > "$GH_MOCK_RESPONSE_FILE"
}

# ---------------------------------------------------------------------------
# Test 1: OPEN PR wins over CLOSED when both reference same issue
# ---------------------------------------------------------------------------

@test "detect_pr_for_issue returns OPEN PR when OPEN and CLOSED both match" {
  # Simulates the real-world case after: rite undo (closes PR #10) + retry (opens PR #11)
  write_gh_response '[
    {"number": 10, "state": "CLOSED", "headRefName": "fix/old-attempt",
     "body": "Closes #999 - Some description", "title": "Fix issue #999 attempt 1"},
    {"number": 11, "state": "OPEN",   "headRefName": "fix/new-attempt",
     "body": "Closes #999 - Fresh attempt", "title": "Fix issue #999 attempt 2"}
  ]'

  # Direct call (not `run`) so PR_NUMBER/PR_BRANCH are set in caller's scope
  detect_pr_for_issue 999
  local rc=$?

  [ "$rc" -eq 0 ]
  # Must have returned the OPEN PR (number 11)
  [ "$PR_NUMBER" = "11" ]
  [ "$PR_BRANCH" = "fix/new-attempt" ]
}

# ---------------------------------------------------------------------------
# Test 2: Stable result across 10 repeated calls (ordering is deterministic)
# ---------------------------------------------------------------------------

@test "detect_pr_for_issue is stable across 10 repeated calls" {
  # Both PR 10 (CLOSED) and PR 11 (OPEN) reference issue #999.
  # Old code used head -1 which could return either depending on API order.
  # New code always returns the OPEN PR deterministically.
  write_gh_response '[
    {"number": 10, "state": "CLOSED", "headRefName": "fix/old-attempt",
     "body": "Closes #999 - Old PR", "title": "Fix #999 v1"},
    {"number": 11, "state": "OPEN",   "headRefName": "fix/new-attempt",
     "body": "Closes #999 - New PR", "title": "Fix #999 v2"}
  ]'

  local i result_numbers=""
  for i in $(seq 1 10); do
    detect_pr_for_issue 999 >/dev/null 2>&1 || true
    result_numbers="${result_numbers} ${PR_NUMBER}"
  done

  # All 10 calls must have returned PR #11 (the OPEN one)
  local unique_results
  unique_results=$(echo "$result_numbers" | tr ' ' '\n' | sort -u | grep -v '^$' || true)
  [ "$unique_results" = "11" ]
}

# ---------------------------------------------------------------------------
# Test 3: Highest-numbered OPEN PR wins when multiple open PRs match
# ---------------------------------------------------------------------------

@test "detect_pr_for_issue returns highest-numbered OPEN PR when multiple open PRs match" {
  # Edge case: two open PRs for the same issue (e.g., the earlier one wasn't closed)
  write_gh_response '[
    {"number": 5,  "state": "OPEN", "headRefName": "fix/early",
     "body": "Closes #999 - Early open", "title": "Fix #999 early"},
    {"number": 20, "state": "OPEN", "headRefName": "fix/later",
     "body": "Closes #999 - Later open", "title": "Fix #999 later"}
  ]'

  # Direct call (not `run`) so PR_NUMBER/PR_BRANCH are set in caller's scope
  detect_pr_for_issue 999
  local rc=$?

  [ "$rc" -eq 0 ]
  # Must return the most recently created open PR (highest number)
  [ "$PR_NUMBER" = "20" ]
  [ "$PR_BRANCH" = "fix/later" ]
}

# ---------------------------------------------------------------------------
# Test 4: Returns failure when no PR references the issue
# ---------------------------------------------------------------------------

@test "detect_pr_for_issue returns 1 when no PR references the issue" {
  write_gh_response '[
    {"number": 42, "state": "OPEN", "headRefName": "fix/other",
     "body": "Closes #888 - Unrelated PR", "title": "Fix #888"}
  ]'

  # Direct call (not `run`) — capture exit code separately for the failure case
  detect_pr_for_issue 999 || rc=$?

  [ "${rc:-0}" -eq 1 ]
  [ -z "$PR_NUMBER" ]
}

# ---------------------------------------------------------------------------
# Test 5: Correct result when exactly one PR matches (no ordering ambiguity)
# ---------------------------------------------------------------------------

@test "detect_pr_for_issue returns the single matching OPEN PR unambiguously" {
  write_gh_response '[
    {"number": 7, "state": "OPEN", "headRefName": "fix/solo",
     "body": "Closes #999 - Only PR for this issue", "title": "Fix #999"}
  ]'

  # Direct call (not `run`) so PR_NUMBER/PR_BRANCH are set in caller's scope
  detect_pr_for_issue 999
  local rc=$?

  [ "$rc" -eq 0 ]
  [ "$PR_NUMBER" = "7" ]
  [ "$PR_BRANCH" = "fix/solo" ]
}

# ---------------------------------------------------------------------------
# Test 6: OPEN PR wins even when it has a lower number than the CLOSED PR
# ---------------------------------------------------------------------------

@test "detect_pr_for_issue returns OPEN PR even when it has lower number than CLOSED" {
  # Less common case: somehow an older PR is still open while a newer one was closed
  write_gh_response '[
    {"number": 50, "state": "CLOSED", "headRefName": "fix/newer-closed",
     "body": "Closes #999 - Newer but closed", "title": "Fix #999 v2"},
    {"number": 30, "state": "OPEN",   "headRefName": "fix/older-open",
     "body": "Closes #999 - Older but still open", "title": "Fix #999 v1"}
  ]'

  # Note: when OPEN and CLOSED both exist, OPEN is always preferred regardless
  # of PR number — state takes precedence over recency.
  # Direct call (not `run`) so PR_NUMBER/PR_BRANCH are set in caller's scope
  detect_pr_for_issue 999
  local rc=$?

  [ "$rc" -eq 0 ]
  [ "$PR_NUMBER" = "30" ]
  [ "$PR_BRANCH" = "fix/older-open" ]
}
