#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh
# tests/regression/pr-number-null-from-jq.bats
#
# Regression test for: PR_NUMBER capturing literal 'null' from jq
#
# Bug (2026-06-04, finance-glance batch run):
#   When `gh pr list --search ... --json number --jq '.[0].number'` finds no
#   matching PRs, jq's `.[0].number` on an empty array returns JSON null.
#   With `-r` (raw output), jq outputs the literal 4-char string "null".
#   Bash captures this as `PR_NUMBER="null"`.
#
#   The fallback `${PR_NUMBER:-}` does NOT help because the string is not empty.
#   The check `[ -n "$PR_NUMBER" ]` then evaluates true, entering the "PR found"
#   branch, logging "PR: #null", and potentially making further gh API calls
#   with "null" as the PR number.
#
#   Live symptom: "✅ Issue #1 → PR #1 (167s)" printed for a fresh repo with
#   zero PRs. The workflow-runner exit-0 bug (#378) was the deeper cause but
#   even without it this PR_NUMBER lookup is unsafe.
#
# Fix (both layers, belt-and-suspenders):
#   Layer 1 (jq): use `// empty` operator — converts null to no output,
#     so bash captures "" instead of "null".
#   Layer 2 (bash): explicit `[ "$PR_NUMBER" = "null" ] && PR_NUMBER=""`
#     guard after each capture, as defense-in-depth for future call paths
#     that might not use `// empty`.
#
# Tests in this file:
#   STRUCTURAL (static code inspection of batch-process-issues.sh):
#     1. Primary call site (line ~658): jq filter ends with `// empty`
#     2. Primary call site: bash null-strip guard present after the capture
#     3. Secondary call site (NEW_DEBT_ISSUE, line ~689): jq filter has `// empty`
#     4. Secondary call site: bash null-strip guard present
#
#   STRUCTURAL (audit sweep — other call sites):
#     5. workflow-runner.sh phase_push_and_pr PR_NUMBER lookup uses `// empty`
#     6. workflow-runner.sh Method 2 detect path uses `// empty`
#     7. pr-detection.sh detect_pr_for_current_branch uses `// empty`
#     8. claude-workflow.sh draft PR capture uses `// empty`
#     9. claude-workflow.sh empty-branch cleanup uses `// empty`
#    10. scratchpad-manager.sh dedup lookup uses `// empty`
#
#   BEHAVIORAL (simulate gh pr list returning []):
#    11. jq returns empty string (not "null") when given `[]` as input
#    12. Batch summary does NOT print "PR: #..." for issue with no PR

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
WORKFLOW_RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"
PR_DETECTION="$REPO_ROOT/lib/utils/pr-detection.sh"
CLAUDE_WORKFLOW="$REPO_ROOT/lib/core/claude-workflow.sh"
SCRATCHPAD_MANAGER="$REPO_ROOT/lib/utils/scratchpad-manager.sh"

setup() {
  [ -f "$BATCH_PROCESSOR" ] || {
    echo "FATAL: $BATCH_PROCESSOR not found" >&2
    return 1
  }
  [ -f "$WORKFLOW_RUNNER" ] || {
    echo "FATAL: $WORKFLOW_RUNNER not found" >&2
    return 1
  }
  [ -f "$PR_DETECTION" ] || {
    echo "FATAL: $PR_DETECTION not found" >&2
    return 1
  }
  [ -f "$CLAUDE_WORKFLOW" ] || {
    echo "FATAL: $CLAUDE_WORKFLOW not found" >&2
    return 1
  }
  [ -f "$SCRATCHPAD_MANAGER" ] || {
    echo "FATAL: $SCRATCHPAD_MANAGER not found" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: batch-process-issues.sh primary call site
# =============================================================================

@test "structural: batch-process-issues.sh PR_NUMBER jq filter ends with '// empty'" {
  # The primary bug call site: `sort_by(.number) | last | .number`
  # must end with `// empty` to prevent literal "null" capture.
  grep -qE "sort_by\(.number\) \| last \| \.number // empty" "$BATCH_PROCESSOR" || {
    echo "FAIL: PR_NUMBER jq filter in batch-process-issues.sh does not end with '// empty'" >&2
    echo "      Expected pattern: sort_by(.number) | last | .number // empty" >&2
    echo "      Without // empty, jq returns literal string \"null\" when no PRs match." >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh has bash null-strip guard after PR_NUMBER capture" {
  # Belt-and-suspenders: the line `[ "$PR_NUMBER" = "null" ] && PR_NUMBER=""`
  # must appear after the PR_NUMBER capture assignment.
  # Extract the block around the PR_NUMBER capture to verify ordering.
  _pr_capture_line=$(grep -n "sort_by(.number) | last" "$BATCH_PROCESSOR" | head -1 | cut -d: -f1)
  [ -n "$_pr_capture_line" ] || {
    echo "FAIL: Could not find PR_NUMBER capture line in batch-process-issues.sh" >&2
    return 1
  }

  # The null-strip guard must appear within a few lines after the capture
  _null_strip_line=$(awk "NR > $_pr_capture_line && NR <= ($_pr_capture_line + 5) && /\\\$PR_NUMBER.*=.*null.*&&.*PR_NUMBER/ { print NR; exit }" "$BATCH_PROCESSOR")
  [ -n "$_null_strip_line" ] || {
    echo "FAIL: bash null-strip guard '[ \"\$PR_NUMBER\" = \"null\" ] && PR_NUMBER=\"\"' not found" >&2
    echo "      within 5 lines after the PR_NUMBER jq capture in batch-process-issues.sh" >&2
    echo "      This guard is required as defense-in-depth for any future call path" >&2
    echo "      that may not use '// empty' at the jq layer." >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh NEW_DEBT_ISSUE jq filter ends with '// empty'" {
  # Secondary call site: `.[0].number` for tech-debt issue lookup.
  grep -qE "\.\[0\]\.number // empty" "$BATCH_PROCESSOR" || {
    echo "FAIL: At least one .[0].number call site in batch-process-issues.sh missing '// empty'" >&2
    return 1
  }

  # Specifically, the NEW_DEBT_ISSUE assignment must use // empty
  grep -qE "NEW_DEBT_ISSUE=.*--jq '.*\.\[0\]\.number // empty'" "$BATCH_PROCESSOR" || {
    echo "FAIL: NEW_DEBT_ISSUE jq filter in batch-process-issues.sh does not end with '// empty'" >&2
    echo "      Expected pattern: --jq '.[0].number // empty'" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh has bash null-strip guard after NEW_DEBT_ISSUE capture" {
  _capture_line=$(grep -n "NEW_DEBT_ISSUE=.*--jq" "$BATCH_PROCESSOR" | head -1 | cut -d: -f1)
  [ -n "$_capture_line" ] || {
    echo "FAIL: Could not find NEW_DEBT_ISSUE capture line in batch-process-issues.sh" >&2
    return 1
  }

  _null_strip_line=$(awk "NR > $_capture_line && NR <= ($_capture_line + 5) && /NEW_DEBT_ISSUE.*=.*null.*&&.*NEW_DEBT_ISSUE/ { print NR; exit }" "$BATCH_PROCESSOR")
  [ -n "$_null_strip_line" ] || {
    echo "FAIL: bash null-strip guard for NEW_DEBT_ISSUE not found within 5 lines after capture" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: audit sweep — other .[0].number call sites
# =============================================================================

@test "structural: workflow-runner.sh phase_push_and_pr PR_NUMBER lookup uses '// empty'" {
  # The PR_NUMBER lookup inside phase_push_and_pr (used when checking for an
  # existing open PR during the push phase) must use // empty.
  _matches=$(grep -c "\.\[0\]\.number // empty" "$WORKFLOW_RUNNER" || true)
  [ "$_matches" -ge 1 ] || {
    echo "FAIL: No '.[0].number // empty' pattern found in workflow-runner.sh" >&2
    echo "      All .[0].number jq extractions must use // empty to prevent literal null capture." >&2
    return 1
  }
}

@test "structural: workflow-runner.sh Method 2 PR detection uses '// empty'" {
  # Method 2 detection: gh pr list --head \$_branch ... --jq '.[0].number // empty'
  # This path fires when the body-search method (Method 1) finds nothing.
  grep -qE "pr list.*--head.*--jq '.*\.\[0\]\.number // empty'" "$WORKFLOW_RUNNER" || {
    echo "FAIL: Method 2 PR detection in workflow-runner.sh does not use '// empty'" >&2
    echo "      Pattern expected: pr list --head \$_branch ... --jq '.[0].number // empty'" >&2
    return 1
  }
}

@test "structural: pr-detection.sh detect_pr_for_current_branch uses '// empty'" {
  grep -qE "\.\[0\]\.number // empty" "$PR_DETECTION" || {
    echo "FAIL: pr-detection.sh detect_pr_for_current_branch does not use '// empty'" >&2
    return 1
  }
}

@test "structural: claude-workflow.sh draft PR capture uses '// empty'" {
  # The PR_NUMBER capture after draft PR creation (used to report the draft
  # PR number back to the user) must use // empty.
  _matches=$(grep -c "\.\[0\]\.number // empty" "$CLAUDE_WORKFLOW" || true)
  [ "$_matches" -ge 2 ] || {
    echo "FAIL: Expected at least 2 '.[0].number // empty' patterns in claude-workflow.sh" >&2
    echo "      Found: $_matches" >&2
    echo "      Both the draft-PR capture and the empty-branch cleanup path must use // empty." >&2
    return 1
  }
}

@test "structural: scratchpad-manager.sh dedup lookup uses '// empty'" {
  grep -qE "\.\[0\]\.number // empty" "$SCRATCHPAD_MANAGER" || {
    echo "FAIL: scratchpad-manager.sh dedup issue lookup does not use '// empty'" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: jq // empty semantics
# =============================================================================

@test "behavioral: jq returns empty string (not 'null') for .[0].number // empty on empty array" {
  # Directly verify that the jq fix produces the right output at the tool level.
  # This test is the ground truth: if jq is not installed or behaves differently,
  # we want to know.
  _result=$(echo '[]' | jq -r '.[0].number // empty' 2>/dev/null || true)
  [ -z "$_result" ] || {
    echo "FAIL: jq '.[0].number // empty' on '[]' returned '$_result' instead of empty string" >&2
    echo "      This means the jq fix is not working as expected on this system." >&2
    return 1
  }
}

@test "behavioral: jq returns the number (not 'null') for .[0].number // empty on non-empty array" {
  # Positive case: verify // empty doesn't break the happy path.
  _result=$(echo '[{"number":42}]' | jq -r '.[0].number // empty' 2>/dev/null || true)
  [ "$_result" = "42" ] || {
    echo "FAIL: jq '.[0].number // empty' on '[{\"number\":42}]' returned '$_result' instead of '42'" >&2
    return 1
  }
}

@test "behavioral: batch summary does NOT print 'PR: #null' when gh pr list returns empty" {
  # Simulate the full capture-and-check sequence that batch-process-issues.sh uses.
  # The mock gh binary returns the raw JSON '[]' for any pr list call (no matching PRs).
  # gh_safe internally applies the --jq filter via jq(1), which is what produces null.
  # The mock here mimics gh_safe by piping the empty-array JSON through jq directly.
  _script="$BATS_TEST_TMPDIR/test-null-pr.sh"
  cat > "$_script" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail

# gh_safe mock: parse --jq argument and apply it via real jq to simulate
# what `gh pr list --json ... | jq -r FILTER` produces when no PRs exist.
# This is the closest behavioral approximation without requiring a PATH mock-bin.
gh_safe() {
  local _jq_filter=""
  local _json="[]"   # gh returns [] when no PRs match the search
  local _args=("$@")
  local _i=0
  while [ "$_i" -lt "${#_args[@]}" ]; do
    if [ "${_args[$_i]}" = "--jq" ]; then
      _i=$((_i + 1))
      _jq_filter="${_args[$_i]:-}"
    fi
    _i=$((_i + 1))
  done
  if [ -n "$_jq_filter" ]; then
    echo "$_json" | jq -r "$_jq_filter" 2>/dev/null || true
  else
    echo "$_json"
  fi
  return 0
}
print_info()    { echo "INFO: $*"; }
print_success() { echo "SUCCESS: $*"; }

ISSUE_NUM=5
ISSUE_DURATION=42

# The fixed capture sequence from batch-process-issues.sh
PR_NUMBER=$(gh_safe pr list --search "fixes #${ISSUE_NUM} OR closes #${ISSUE_NUM} in:body" --state all --json number --jq 'sort_by(.number) | reverse | .[0].number // empty')
PR_NUMBER="${PR_NUMBER:-}"
[ "$PR_NUMBER" = "null" ] && PR_NUMBER=""

print_success "Issue #$ISSUE_NUM completed successfully"
if [ -n "$PR_NUMBER" ]; then
  print_info "PR: #$PR_NUMBER"
  echo "FAIL_MARKER: entered PR branch with PR_NUMBER='$PR_NUMBER'"
else
  echo "PASS_MARKER: correctly skipped PR branch (PR_NUMBER is empty)"
fi
print_info "Duration: ${ISSUE_DURATION}s"
STUB_EOF
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script exited with status $status" >&2
    echo "Output: $output" >&2
    return 1
  }

  # Must NOT print "PR: #null" or "PR: #..." for a no-PR issue
  if echo "$output" | grep -q "PR: #"; then
    echo "FAIL: batch summary printed 'PR: #...' for issue with no real PR" >&2
    echo "Output: $output" >&2
    return 1
  fi

  # Must NOT enter the PR branch at all
  if echo "$output" | grep -q "FAIL_MARKER"; then
    echo "FAIL: entered the PR-found branch when gh pr list returned empty array" >&2
    echo "Output: $output" >&2
    return 1
  fi

  # Must see the pass marker
  echo "$output" | grep -q "PASS_MARKER" || {
    echo "FAIL: did not see expected PASS_MARKER in output" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: bash null-strip guard catches literal 'null' even without jq // empty" {
  # Belt-and-suspenders test: even if a future code path omits // empty at the jq
  # layer, the bash-level guard must still prevent "null" from propagating.
  _script="$BATS_TEST_TMPDIR/test-bash-null-strip.sh"
  cat > "$_script" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Simulate a jq call that returns literal "null" (no // empty guard)
gh_safe() {
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
    echo "null"   # What jq outputs for .[0].number without // empty on []
    return 0
  fi
}
print_info()    { echo "INFO: $*"; }
print_success() { echo "SUCCESS: $*"; }

ISSUE_NUM=7
ISSUE_DURATION=10

# Capture (intentionally without // empty to test the bash-layer guard)
PR_NUMBER=$(gh_safe pr list --search "fixes #${ISSUE_NUM} OR closes #${ISSUE_NUM} in:body" --state all --json number --jq 'sort_by(.number) | reverse | .[0].number')
# Bash-level null strip (belt-and-suspenders)
PR_NUMBER="${PR_NUMBER:-}"
[ "$PR_NUMBER" = "null" ] && PR_NUMBER=""

print_success "Issue #$ISSUE_NUM completed successfully"
if [ -n "$PR_NUMBER" ]; then
  echo "FAIL_MARKER: entered PR branch with PR_NUMBER='$PR_NUMBER'"
else
  echo "PASS_MARKER: bash null-strip guard correctly cleared PR_NUMBER"
fi
STUB_EOF
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script exited with status $status" >&2
    echo "Output: $output" >&2
    return 1
  }

  if echo "$output" | grep -q "FAIL_MARKER"; then
    echo "FAIL: bash null-strip guard did not clear literal 'null' string" >&2
    echo "Output: $output" >&2
    return 1
  fi

  echo "$output" | grep -q "PASS_MARKER" || {
    echo "FAIL: did not see PASS_MARKER — null-strip guard may be missing" >&2
    echo "Output: $output" >&2
    return 1
  }
}
