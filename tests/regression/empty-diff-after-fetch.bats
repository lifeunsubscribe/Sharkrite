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
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: write a temp script that reproduces the empty-diff validation block
# from local-review.sh (currently lines 153-191). Writing to a temp file
# avoids complex nested-quote problems with bash -c '...' heredocs.
# ---------------------------------------------------------------------------
_write_empty_diff_check_script() {
  local script_file="$1"
  local pr_number="$2"
  local pr_diff="$3"      # may be empty

  # Write the diff to a temp file so multi-line content survives variable export
  local diff_file="$RITE_TEST_TMPDIR/pr_diff.txt"
  printf '%s' "$pr_diff" > "$diff_file"

  cat > "$script_file" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

PR_NUMBER="$pr_number"
PR_DIFF=\$(cat "$diff_file")

print_status()  { echo "[STATUS] \$*" >&2; }
print_error()   { echo "[ERROR] \$*" >&2; }
print_warning() { echo "[WARNING] \$*"; }
print_success() { echo "[SUCCESS] \$*" >&2; }
print_info()    { echo "[INFO] \$*"; }

DIFF_LINES=\$(echo "\$PR_DIFF" | wc -l | tr -d ' ')
DIFF_FILES=\$(echo "\$PR_DIFF" | grep -c "^diff --git" || true)

if [ "\$DIFF_FILES" -eq 0 ] || [ -z "\$PR_DIFF" ] || [ "\$PR_DIFF" = "" ]; then
  GH_CHANGED_FILES=\$(gh pr view "\$PR_NUMBER" --json changedFiles --jq '.changedFiles' 2>/dev/null || echo "0")
  GH_CHANGED_FILES=\$(echo "\$GH_CHANGED_FILES" | tr -d '[:space:]')
  if ! echo "\$GH_CHANGED_FILES" | grep -qE '^[0-9]+\$'; then
    GH_CHANGED_FILES=0
  fi

  if [ "\$GH_CHANGED_FILES" -gt 0 ]; then
    print_warning "Empty diff after fetch — but GitHub reports \$GH_CHANGED_FILES changed file(s)"
    print_info "This indicates the diff fetch returned empty content despite real changes existing."
    print_info "Possible causes:"
    echo "  • GitHub API returned 200 OK with empty body (transient)"
    echo "  • Local git refs are stale (run: git fetch origin)"
    echo "  • Rate limit silently truncated the response"
    echo ""
    print_info "Remediation: retry this command, or run 'git fetch origin' and retry."
  else
    print_warning "No code changes to review"
    print_info "This PR has no diff against the base branch."
    print_info "Possible reasons:"
    echo "  • PR only has placeholder commit (no implementation yet)"
    echo "  • All changes were reverted"
    echo "  • Branch is identical to base"
  fi
  echo ""
  exit 1
fi

echo "DIFF_VALID"
exit 0
SCRIPT
  chmod +x "$script_file"
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

  local check_script="$RITE_TEST_TMPDIR/check.sh"
  _write_empty_diff_check_script "$check_script" "123" ""

  run "$check_script"

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

  local check_script="$RITE_TEST_TMPDIR/check.sh"
  _write_empty_diff_check_script "$check_script" "123" ""

  run "$check_script"

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

  local check_script="$RITE_TEST_TMPDIR/check.sh"
  _write_empty_diff_check_script "$check_script" "123" ""

  run "$check_script"

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

  local check_script="$RITE_TEST_TMPDIR/check.sh"
  _write_empty_diff_check_script "$check_script" "123" ""

  run "$check_script"

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

@test "non-empty diff: validation block is skipped, DIFF_VALID emitted" {
  # gh mock not needed — the validation block exits before querying changedFiles
  VALID_DIFF="diff --git a/foo.sh b/foo.sh
index abc..def 100644
--- a/foo.sh
+++ b/foo.sh
@@ -1 +1 @@
-old line
+new line"

  local check_script="$RITE_TEST_TMPDIR/check.sh"
  _write_empty_diff_check_script "$check_script" "123" "$VALID_DIFF"

  run "$check_script"

  # Must succeed (diff is non-empty)
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIFF_VALID"* ]]
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
