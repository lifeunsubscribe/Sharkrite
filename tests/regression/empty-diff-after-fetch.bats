#!/usr/bin/env bats
# tests/regression/empty-diff-after-fetch.bats
#
# Regression tests for issue #101: Add validation for empty diff after fetch
#
# Edge case: GitHub returns 200 OK with empty body (or git diff returns empty),
# but the PR has real changed files per the GitHub API metadata. This indicates
# a silent fetch failure rather than a legitimate empty PR.
#
# Verifies:
# 1. When diff is empty AND gh pr view reports changedFiles > 0:
#    - Emits "Empty diff after fetch" warning (not the generic "No code changes")
#    - Names the changedFiles count in the message
#    - Includes remediation hint (retry / git fetch origin)
#    - Exits non-zero
# 2. When diff is empty AND gh pr view reports changedFiles == 0:
#    - Emits the original "No code changes to review" message
#    - Does NOT emit the fetch-failure warning
#    - Exits non-zero
# 3. Static check: the cross-check logic is present in local-review.sh
#
# These tests source validate_diff_not_empty() directly from local-review.sh
# (via RITE_SOURCE_FUNCTIONS_ONLY=1) so they exercise the real production code
# rather than a copy of it.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"

  mkdir -p "$RITE_TEST_TMPDIR/.rite"

  # Inject a PATH-level shim dir so tests can drop mock binaries
  export SHIM_DIR="$RITE_TEST_TMPDIR/shims"
  mkdir -p "$SHIM_DIR"
  export PATH="$SHIM_DIR:$PATH"

  # Provide logging shims used by validate_diff_not_empty().
  # print_warning and print_info go to stdout so bats $output captures them.
  # print_status/print_error go to stderr (not checked in these tests).
  print_status()  { echo "[STATUS] $*" >&2; }
  print_error()   { echo "[ERROR] $*" >&2; }
  print_warning() { echo "[WARNING] $*"; }
  print_success() { echo "[SUCCESS] $*" >&2; }
  print_info()    { echo "[INFO] $*"; }
  export -f print_status print_error print_warning print_success print_info

  # Source local-review.sh in functions-only mode to load validate_diff_not_empty()
  # and fetch_pr_diff() without executing the script body (which needs config,
  # providers, a real PR number, etc.).
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "${RITE_REPO_ROOT}/lib/core/local-review.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Test 1: empty diff + GitHub reports >0 changed files → fetch-failure message
# ---------------------------------------------------------------------------

@test "empty diff with changedFiles>0: emits fetch-failure warning with file count" {
  # Mock gh to report 3 changed files when queried for metadata
  cat > "$SHIM_DIR/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"changedFiles"* ]]; then
  echo "3"
  exit 0
fi
command gh "$@"
EOF
  chmod +x "$SHIM_DIR/gh"

  # Run the real validate_diff_not_empty function in a subshell (it calls exit 1
  # on empty diff, so we must capture via run to avoid killing the test).
  run validate_diff_not_empty "123" "" "0"

  # Must exit non-zero
  [ "$status" -ne 0 ]

  # Must contain the fetch-failure warning with file count
  [[ "$output" == *"Empty diff after fetch"* ]]
  [[ "$output" == *"3 changed file"* ]]

  # Must include remediation hint
  [[ "$output" == *"git fetch origin"* ]]

  # Must NOT emit the generic "No code changes to review" message
  [[ "$output" != *"No code changes to review"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: empty diff + GitHub reports 0 changed files → legitimate empty PR
# ---------------------------------------------------------------------------

@test "empty diff with changedFiles==0: emits 'no code changes' message" {
  # Mock gh to report 0 changed files
  cat > "$SHIM_DIR/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"changedFiles"* ]]; then
  echo "0"
  exit 0
fi
command gh "$@"
EOF
  chmod +x "$SHIM_DIR/gh"

  run validate_diff_not_empty "123" "" "0"

  # Must exit non-zero
  [ "$status" -ne 0 ]

  # Must contain the original "no code changes" message
  [[ "$output" == *"No code changes to review"* ]]

  # Must NOT emit the fetch-failure warning
  [[ "$output" != *"Empty diff after fetch"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: gh pr view fails entirely → falls back to 0, no crash
# ---------------------------------------------------------------------------

@test "empty diff with gh pr view failure: falls back gracefully, no crash" {
  # Mock gh to always fail (e.g., network unavailable during changedFiles check)
  cat > "$SHIM_DIR/gh" <<'EOF'
#!/bin/bash
echo "Error: connection refused" >&2
exit 1
EOF
  chmod +x "$SHIM_DIR/gh"

  run validate_diff_not_empty "123" "" "0"

  # Must exit non-zero (empty diff → exit 1 regardless)
  [ "$status" -ne 0 ]

  # Must NOT crash with unbound variable or arithmetic errors
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" != *"integer expression expected"* ]]

  # Falls back to "no code changes" (gh failure → GH_CHANGED_FILES=0)
  [[ "$output" == *"No code changes to review"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: non-numeric changedFiles response → sanitized to 0, no crash
# ---------------------------------------------------------------------------

@test "empty diff with non-numeric changedFiles: sanitizes gracefully" {
  # Mock gh to return "null" (e.g., unexpected jq output)
  cat > "$SHIM_DIR/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"changedFiles"* ]]; then
  echo "null"
  exit 0
fi
command gh "$@"
EOF
  chmod +x "$SHIM_DIR/gh"

  run validate_diff_not_empty "123" "" "0"

  # Must exit non-zero
  [ "$status" -ne 0 ]

  # Must not crash on non-numeric input
  [[ "$output" != *"integer expression expected"* ]]
  [[ "$output" != *"[: null: integer expression expected"* ]]

  # Falls back to "no code changes" (null → sanitized to 0)
  [[ "$output" == *"No code changes to review"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: valid diff content → validation block is not triggered
# ---------------------------------------------------------------------------

@test "non-empty diff: validation block is skipped, function returns 0" {
  # gh mock not needed — the validation block exits before querying changedFiles
  VALID_DIFF="diff --git a/foo.sh b/foo.sh
index abc..def 100644
--- a/foo.sh
+++ b/foo.sh
@@ -1 +1 @@
-old line
+new line"

  # Compute DIFF_FILES as the script body does
  local DIFF_FILES
  DIFF_FILES=$(echo "$VALID_DIFF" | grep -c "^diff --git" || true)

  run validate_diff_not_empty "123" "$VALID_DIFF" "$DIFF_FILES"

  # Must succeed (diff is non-empty)
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 6: static check — cross-check logic is present in local-review.sh
# ---------------------------------------------------------------------------

@test "local-review.sh contains changedFiles cross-check for empty diff validation" {
  SCRIPT_PATH="${RITE_REPO_ROOT}/lib/core/local-review.sh"

  # The cross-check must query changedFiles from the GitHub API
  COUNT=$(grep -c "changedFiles" "$SCRIPT_PATH" || true)
  [ "$COUNT" -ge 1 ]

  # Must include the mismatch warning message
  WARN_COUNT=$(grep -c "Empty diff after fetch" "$SCRIPT_PATH" || true)
  [ "$WARN_COUNT" -ge 1 ]

  # Must include a remediation hint pointing to git fetch origin
  REMED_COUNT=$(grep -c "git fetch origin" "$SCRIPT_PATH" || true)
  [ "$REMED_COUNT" -ge 1 ]
}
