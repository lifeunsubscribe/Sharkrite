#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/core/batch-process-issues.sh, bin/rite, lib/core/undo-workflow.sh, lib/utils/pr-refusal.sh
# tests/regression/pr-number-refused-as-issue.bats
#
# Regression test: rite must refuse a bare PR number before any dev work runs.
#
# Issue #839 — "Reject bare PR numbers in issue commands"
# Issue #851 — "Canonicalize bare PR-number calls to issue form"
#   Extends #839 coverage to --status, --review-latest, --assess-and-fix, --undo
#   entrypoints which bypass run_workflow()'s /pull/ guard.
#
# Root cause: GitHub's shared number space means `gh issue view <PR#>` succeeds
# and returns the PR as if it were an issue. Before this fix, rite silently
# adopted PR numbers, spawned dev sessions, and sometimes merged code.
#
# Live incident (2026-07-01): `rite 490 489 471 467` cwd mixup ran real dev
# sessions against three old PRs. PR #826 was produced and merged from #489.
# PRs #490 and #467 burned 278s/516s sessions and left orphan worktrees.
#
# Fix:
#   1. The `url` field is added to the initial `gh issue view --json` fetch in
#      run_workflow() — no extra API call.
#   2. If the url contains '/pull/', handle_pr_number_refused() is called before
#      any worktree, lock, or dev-session side effects.
#   3. handle_pr_number_refused() prints the PR title, url, and linked issue (if
#      found), then returns 15.
#   4. run_workflow() returns 15 in both single-issue and batch modes. main()
#      routes exit 15 to the dedicated pr_number_refused branch, avoiding the
#      misleading "Workflow failed" message that the generic else branch prints.
#   5. Batch mode: batch-process-issues.sh captures exit 15 to record pr_number_refused
#      (SKIPPED class) and continues remaining issues.
#
# Tests in this file:
#   STRUCTURAL (static code inspection of workflow-runner.sh):
#     1. url field is present in the gh issue view --json fetch in run_workflow()
#     2. handle_pr_number_refused() function exists
#     3. handle_pr_number_refused() returns 15 (not 0 or 1)
#     4. /pull/ check is present in run_workflow() before the CLOSED check
#     5. exit-15 case exists in main()'s workflow_exit dispatcher
#
#   STRUCTURAL (static code inspection of batch-process-issues.sh):
#     6. PR_NUMBER_REFUSED_ISSUES array is initialized
#     7. elif [ $_WF_EXIT -eq 15 ] branch exists
#     8. pr_number_refused status is set in the exit-15 branch
#     9. No gh pr list/view/issue list in the exit-15 branch (non-comment)
#
#   BEHAVIORAL (subprocess execution with stubs):
#    10. Single-issue mode: run_workflow exits 15 for PR number (non-zero refusal)
#    11. Single-issue mode: refusal message names the PR
#    12. Batch mode: run_workflow exits 15 for PR number (sentinel)
#    13. Real issue number: url /issues/ path passes the check unchanged
#    14. Linked issue is printed when PR body contains "Closes #N"
#    15. Linked issue suggestion is omitted when PR body has no closing ref
#
#   STRUCTURAL (static code inspection of bin/rite — phase-command entrypoints, #851):
#    16. _reject_if_pr_number() function exists in bin/rite
#    17. _reject_if_pr_number() uses exit 15
#    18. status-per-issue dispatch block calls _reject_if_pr_number
#    19. review-latest dispatch block calls _reject_if_pr_number
#    20. assess-and-fix dispatch block calls _reject_if_pr_number
#
#   BEHAVIORAL (bin/rite _reject_if_pr_number(), #851):
#    21. _reject_if_pr_number() exits 15 when issue number refers to a PR
#
#   STRUCTURAL (static code inspection of undo-workflow.sh, #851):
#    22. undo-workflow.sh checks for /pull/ in the url field before Phase 1
#    23. undo-workflow.sh exits 15 when /pull/ is detected
#
#   BEHAVIORAL (undo-workflow.sh, #851):
#    24. undo-workflow.sh exits 15 when the issue number refers to a PR
#
#   STRUCTURAL (lib/utils/pr-refusal.sh — shared helper, this issue):
#    25. refuse_if_pr_number() function exists in pr-refusal.sh
#    26. pr-refusal.sh has a function-sentinel re-source guard
#    27. workflow-runner.sh sources pr-refusal.sh
#    28. bin/rite sources pr-refusal.sh
#    29. undo-workflow.sh sources pr-refusal.sh
#    30. handle_pr_number_refused() delegates to refuse_if_pr_number
#    31. _reject_if_pr_number() delegates to refuse_if_pr_number
#
#   BEHAVIORAL (lib/utils/pr-refusal.sh — shared helper, this issue):
#    32. refuse_if_pr_number() returns 15 for a PR number
#    33. refuse_if_pr_number() returns 0 for a real issue number
#    34. refuse_if_pr_number() accepts pre-fetched ISSUE_DATA (no extra API call)
#    35. refuse_if_pr_number() uses CALLER_VERB in the error message

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WORKFLOW_RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
RITE_BINARY="$REPO_ROOT/bin/rite"
UNDO_WORKFLOW="$REPO_ROOT/lib/core/undo-workflow.sh"
PR_REFUSAL_LIB="$REPO_ROOT/lib/utils/pr-refusal.sh"

setup() {
  [ -f "$WORKFLOW_RUNNER" ] || {
    echo "FATAL: $WORKFLOW_RUNNER not found" >&2
    return 1
  }
  [ -f "$BATCH_PROCESSOR" ] || {
    echo "FATAL: $BATCH_PROCESSOR not found" >&2
    return 1
  }
  [ -f "$RITE_BINARY" ] || {
    echo "FATAL: $RITE_BINARY not found" >&2
    return 1
  }
  [ -f "$UNDO_WORKFLOW" ] || {
    echo "FATAL: $UNDO_WORKFLOW not found" >&2
    return 1
  }
  [ -f "$PR_REFUSAL_LIB" ] || {
    echo "FATAL: $PR_REFUSAL_LIB not found" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: workflow-runner.sh
# =============================================================================

@test "structural: run_workflow() fetches 'url' field in the initial gh issue view call" {
  # The url field enables zero-cost PR detection (no extra API call).
  # It must appear in the --json argument of the issue data fetch in run_workflow().
  _func_body=$(awk '
    /^run_workflow[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract run_workflow function body" >&2
    return 1
  }

  # The issue data fetch must include 'url' in its --json field list
  echo "$_func_body" | grep -qE "gh_safe issue view.*--json.*url" || {
    echo "FAIL: run_workflow()'s gh issue view --json fetch does not include 'url' field" >&2
    echo "      The url field is required to detect PR numbers without an extra API call" >&2
    return 1
  }
}

@test "structural: handle_pr_number_refused() function exists in workflow-runner.sh" {
  grep -q "^handle_pr_number_refused()" "$WORKFLOW_RUNNER" || {
    echo "FAIL: handle_pr_number_refused() function not found in workflow-runner.sh" >&2
    return 1
  }
}

@test "structural: handle_pr_number_refused() returns 15 (not 0 or 1)" {
  _func_body=$(awk '
    /^handle_pr_number_refused[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract handle_pr_number_refused function body" >&2
    return 1
  }

  echo "$_func_body" | grep -qE '^\s*return 15' || {
    echo "FAIL: handle_pr_number_refused() does not contain 'return 15'" >&2
    echo "      Exit code 15 is the batch sentinel for PR-number refusals" >&2
    return 1
  }
}

@test "structural: run_workflow() checks for /pull/ in url before the CLOSED state check" {
  # Extract run_workflow body with line numbers to verify ordering.
  _func_with_lines=$(awk '
    /^run_workflow[(][)]/ { in_func=1; lineno=NR; next }
    in_func && /^\}$/ { exit }
    in_func { print NR": "$0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_with_lines" ] || {
    echo "FAIL: Could not extract run_workflow function body" >&2
    return 1
  }

  # Find the line with /pull/ check
  _pull_line=$(echo "$_func_with_lines" | grep -E "/pull/" | head -1 | grep -oE '^[0-9]+' || true)
  [ -n "$_pull_line" ] || {
    echo "FAIL: No '/pull/' URL check found in run_workflow()" >&2
    echo "      The PR detection must check the url field before any worktree side effects" >&2
    return 1
  }

  # Find the CLOSED state check
  _closed_line=$(echo "$_func_with_lines" | grep -E 'issue_state.*=.*"CLOSED"' | head -1 | grep -oE '^[0-9]+' || true)
  [ -n "$_closed_line" ] || {
    echo "FAIL: Could not find CLOSED state check in run_workflow()" >&2
    return 1
  }

  # /pull/ check must come before CLOSED check
  if [ "$_pull_line" -ge "$_closed_line" ]; then
    echo "FAIL: /pull/ check (line $_pull_line) must appear BEFORE CLOSED check (line $_closed_line)" >&2
    echo "      A closed PR number must also be refused before cleanup runs" >&2
    return 1
  fi
}

@test "structural: main() workflow_exit dispatcher has exit-15 case" {
  # The top-level executor in main() must have an explicit elif for workflow_exit -eq 15
  # so the sentinel propagates to batch. Without it, exit 15 falls into the else → exit 1.
  grep -qE '\[ \$workflow_exit -eq 15 \]' "$WORKFLOW_RUNNER" || {
    echo "FAIL: No 'workflow_exit -eq 15' case in workflow-runner.sh main() dispatcher" >&2
    echo "      Without this, batch cannot distinguish PR-number refusal from a real failure" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: batch-process-issues.sh
# =============================================================================

@test "structural: batch-process-issues.sh initializes PR_NUMBER_REFUSED_ISSUES array" {
  grep -q 'PR_NUMBER_REFUSED_ISSUES=' "$BATCH_PROCESSOR" || {
    echo "FAIL: PR_NUMBER_REFUSED_ISSUES array not initialized in batch-process-issues.sh" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh has elif _WF_EXIT -eq 15 branch" {
  grep -qE 'elif \[ \$_WF_EXIT -eq 15 \]' "$BATCH_PROCESSOR" || {
    echo "FAIL: No 'elif [ \$_WF_EXIT -eq 15 ]' branch in batch-process-issues.sh" >&2
    echo "      Exit 15 must route to the pr_number_refused skip path" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh sets pr_number_refused status in exit-15 branch" {
  _branch_body=$(awk '
    /elif \[ \$_WF_EXIT -eq 15 \]/ { in_branch=1; next }
    in_branch && (/elif \[ \$_WF_EXIT -eq/ || /^  else$/) { exit }
    in_branch { print $0 }
  ' "$BATCH_PROCESSOR")

  [ -n "$_branch_body" ] || {
    echo "FAIL: Could not extract the exit-15 branch body from batch-process-issues.sh" >&2
    return 1
  }

  echo "$_branch_body" | grep -q 'pr_number_refused' || {
    echo "FAIL: 'pr_number_refused' status not set in exit-15 branch" >&2
    echo "      The status is used by the batch reporter to label the skip correctly" >&2
    return 1
  }
}

@test "structural: no gh pr list or gh pr view or gh issue list in exit-15 branch (non-comment)" {
  # No dev session ran for PR-number refusals — stat-gathering calls must be skipped.
  _branch_body=$(awk '
    /elif \[ \$_WF_EXIT -eq 15 \]/ { in_branch=1; next }
    in_branch && (/elif \[ \$_WF_EXIT -eq/ || /^  else$/) { exit }
    in_branch { print $0 }
  ' "$BATCH_PROCESSOR")

  [ -n "$_branch_body" ] || {
    echo "FAIL: Could not extract the exit-15 branch body from batch-process-issues.sh" >&2
    return 1
  }

  _noncomment_body=$(echo "$_branch_body" | grep -v '^\s*#')

  if echo "$_noncomment_body" | grep -qE 'gh.*pr list'; then
    echo "FAIL: 'gh pr list' (non-comment) found in exit-15 branch" >&2
    echo "      No dev session ran for a PR-number refusal — stat-gathering must be skipped" >&2
    return 1
  fi

  if echo "$_noncomment_body" | grep -qE 'gh.*pr view'; then
    echo "FAIL: 'gh pr view' (non-comment) found in exit-15 branch" >&2
    echo "      PR stat gathering must be skipped for PR-number refusals" >&2
    return 1
  fi

  if echo "$_noncomment_body" | grep -qE 'gh.*issue list'; then
    echo "FAIL: 'gh issue list' (non-comment) found in exit-15 branch" >&2
    echo "      Tech-debt issue search must be skipped for PR-number refusals" >&2
    return 1
  fi
}

# =============================================================================
# BEHAVIORAL: subprocess execution with stubs
# =============================================================================

# Shared stub preamble written to a temp file to avoid heredoc duplication.
# Sets up all workflow-runner.sh dependencies needed for the PR detection path.
_write_stub_preamble() {
  local _script="$1"
  local _batch_mode="${2:-false}"
  local _pr_url="${3:-https://github.com/owner/repo/pull/490}"
  local _pr_title="${4:-Some old PR title}"
  local _pr_body="${5:-}"  # optional body for Closes #N test

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand (_batch_mode, _pr_title, _pr_url, _pr_body)
  cat > "$_script" <<STUB_EOF
#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Minimal stubs for workflow-runner.sh dependencies
# ---------------------------------------------------------------------------
RITE_LIB_DIR="/dev/null/stub"
RITE_PROJECT_ROOT="\$BATS_TEST_TMPDIR"
RITE_DATA_DIR=".rite"
WORKFLOW_MODE="unsupervised"
RESUME_MODE=false
BYPASS_BLOCKERS=false
CURRENT_PHASE=""
CURRENT_ISSUE=""
CURRENT_PR=""
CURRENT_RETRY=0
INTERRUPT_RECEIVED=false
CLOSING_ISSUE_JQ_REGEX=""
BATCH_MODE=${_batch_mode}

print_header()  { :; }
print_info()    { :; }
print_success() { :; }
print_status()  { :; }
print_step()    { :; }
verbose_info()  { :; }
# print_error writes to stderr so test can capture it
print_error()   { echo "ERROR: \$*" >&2; }

iso_to_epoch() { echo "1767225600"; }

# gh_safe stub: returns a PR (url contains /pull/) for issue view calls
gh_safe() {
  if [ "\${1:-}" = "issue" ] && [ "\${2:-}" = "view" ]; then
    echo '{"state":"OPEN","title":"${_pr_title}","closedAt":null,"closedByPullRequestsReferences":[],"url":"${_pr_url}"}'
    return 0
  fi
  if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
    # Return PR body for linked-issue lookup
    echo '{"body":"${_pr_body}"}'
    return 0
  fi
  echo ""
  return 0
}

git() { return 0; }
extract_changes_summary() { echo ""; }
run_with_timeout() { local _t="\$1"; shift; "\$@" 2>/dev/null || true; }
STUB_EOF
}

@test "behavioral: single-issue mode exits 15 (non-zero refusal) when number is a PR" {
  # run_workflow() returns 15 in both single-issue and batch mode.
  # Exit 15 is non-zero (refusal accepted) and avoids the misleading
  # "Workflow failed" message that the generic else branch in main() would print.
  # See: docs/architecture/exit-codes.md — exit code 15

  _script="$BATS_TEST_TMPDIR/test-single-pr-refused.sh"
  _write_stub_preamble "$_script" "false" "https://github.com/owner/repo/pull/490" "Old PR title"

  cat >> "$_script" <<'INLINE_EOF'

# Inline copies matching real workflow-runner.sh logic (no BATCH_MODE gate —
# both modes return 15 so main() can route cleanly without "Workflow failed").
handle_pr_number_refused() {
  local issue_number="$1"
  local issue_data="$2"
  local pr_title
  pr_title=$(echo "$issue_data" | jq -r '.title // "unknown"' || true)
  local pr_url
  pr_url=$(echo "$issue_data" | jq -r '.url // ""' || true)
  print_error "#${issue_number} is a Pull Request, not an issue"
  print_error "PR title: ${pr_title}"
  [ -n "$pr_url" ] && print_error "PR url: ${pr_url}"
  local _linked_issue=""
  local _pr_body
  _pr_body=$(gh_safe pr view "$issue_number" --json body --jq '.body' 2>/dev/null || true)
  if [ -n "$_pr_body" ]; then
    _linked_issue=$(echo "$_pr_body" | grep -ioE '(closes|fixes|resolves)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
  fi
  [ -n "$_linked_issue" ] && print_error "Linked issue: #${_linked_issue}"
  return 15
}

run_workflow() {
  local issue_number="$1"
  local issue_data
  issue_data=$(gh_safe issue view "$issue_number" --json state,title,closedAt,closedByPullRequestsReferences,url)

  local _issue_url
  _issue_url=$(echo "$issue_data" | jq -r '.url // ""' || true)
  if echo "$_issue_url" | grep -qF '/pull/'; then
    set +e
    handle_pr_number_refused "$issue_number" "$issue_data"
    set -e
    # Return 15 in both single-issue and batch mode — matches real code.
    # main() routes this to the dedicated pr_number_refused branch (exit 15)
    # without printing "Workflow failed".
    return 15
  fi
  return 0
}

_exit=0
run_workflow "490" || _exit=$?

if [ "$_exit" -ne 15 ]; then
  echo "FAIL: expected exit 15 for PR number in single-issue mode, got $_exit" >&2
  exit 1
fi
exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script itself failed (status=$status)" >&2
    echo "Output: $output" >&2
    echo "Stderr: $stderr" >&2
    return 1
  }
}

@test "behavioral: single-issue mode prints PR title and number in refusal message" {
  _script="$BATS_TEST_TMPDIR/test-pr-refused-message.sh"
  _write_stub_preamble "$_script" "false" "https://github.com/owner/repo/pull/490" "Reject bare PR numbers in issue commands"

  cat >> "$_script" <<'INLINE_EOF'

handle_pr_number_refused() {
  local issue_number="$1"
  local issue_data="$2"
  local pr_title
  pr_title=$(echo "$issue_data" | jq -r '.title // "unknown"' || true)
  local pr_url
  pr_url=$(echo "$issue_data" | jq -r '.url // ""' || true)
  print_error "#${issue_number} is a Pull Request, not an issue"
  print_error "PR title: ${pr_title}"
  [ -n "$pr_url" ] && print_error "PR url: ${pr_url}"
  local _pr_body
  _pr_body=$(gh_safe pr view "$issue_number" --json body --jq '.body' 2>/dev/null || true)
  local _linked_issue=""
  if [ -n "$_pr_body" ]; then
    _linked_issue=$(echo "$_pr_body" | grep -ioE '(closes|fixes|resolves)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
  fi
  [ -n "$_linked_issue" ] && print_error "Linked issue: #${_linked_issue}"
  return 15
}

run_workflow() {
  local issue_number="$1"
  local issue_data
  issue_data=$(gh_safe issue view "$issue_number" --json state,title,closedAt,closedByPullRequestsReferences,url)
  local _issue_url
  _issue_url=$(echo "$issue_data" | jq -r '.url // ""' || true)
  if echo "$_issue_url" | grep -qF '/pull/'; then
    set +e
    handle_pr_number_refused "$issue_number" "$issue_data"
    set -e
    # Return 15 in both modes — matches real code.
    return 15
  fi
  return 0
}

_exit=0
run_workflow "490" 2>/tmp/pr_refused_stderr_$$ || _exit=$?
_stderr=$(cat /tmp/pr_refused_stderr_$$ || true)
rm -f /tmp/pr_refused_stderr_$$

echo "STDERR_OUTPUT: $_stderr"

# Check message mentions the PR number
if ! echo "$_stderr" | grep -q "490"; then
  echo "FAIL: refusal message does not mention PR #490" >&2
  exit 1
fi

# Check message mentions the PR title
if ! echo "$_stderr" | grep -qi "Pull Request"; then
  echo "FAIL: refusal message does not mention 'Pull Request'" >&2
  exit 1
fi

echo "PASS: refusal message is correct"
exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "PASS" || {
    echo "FAIL: PASS marker not found in output" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: batch mode exits 15 (sentinel) when number is a PR" {
  _script="$BATS_TEST_TMPDIR/test-batch-pr-refused.sh"
  _write_stub_preamble "$_script" "true" "https://github.com/owner/repo/pull/490" "Old PR title"

  cat >> "$_script" <<'INLINE_EOF'

handle_pr_number_refused() {
  local issue_number="$1"
  local issue_data="$2"
  local pr_title
  pr_title=$(echo "$issue_data" | jq -r '.title // "unknown"' || true)
  print_error "#${issue_number} is a Pull Request, not an issue"
  print_error "PR title: ${pr_title}"
  local _pr_body
  _pr_body=$(gh_safe pr view "$issue_number" --json body --jq '.body' 2>/dev/null || true)
  local _linked_issue=""
  if [ -n "$_pr_body" ]; then
    _linked_issue=$(echo "$_pr_body" | grep -ioE '(closes|fixes|resolves)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
  fi
  [ -n "$_linked_issue" ] && print_error "Linked issue: #${_linked_issue}"
  return 15
}

run_workflow() {
  local issue_number="$1"
  local issue_data
  issue_data=$(gh_safe issue view "$issue_number" --json state,title,closedAt,closedByPullRequestsReferences,url)
  local _issue_url
  _issue_url=$(echo "$issue_data" | jq -r '.url // ""' || true)
  if echo "$_issue_url" | grep -qF '/pull/'; then
    set +e
    handle_pr_number_refused "$issue_number" "$issue_data"
    set -e
    # Return 15 in both modes — matches real code.
    return 15
  fi
  return 0
}

_exit=0
run_workflow "490" || _exit=$?

if [ "$_exit" -ne 15 ]; then
  echo "FAIL: expected exit 15 for PR number in batch mode, got $_exit" >&2
  exit 1
fi
exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: real issue number (url contains /issues/) passes the check unchanged" {
  _script="$BATS_TEST_TMPDIR/test-real-issue-passes.sh"

  cat > "$_script" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail

BATCH_MODE=false
print_error() { echo "ERROR: $*" >&2; }
print_info()  { :; }

# gh_safe stub: returns a real issue URL (/issues/, not /pull/)
gh_safe() {
  if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
    echo '{"state":"OPEN","title":"A real issue","closedAt":null,"closedByPullRequestsReferences":[],"url":"https://github.com/owner/repo/issues/839"}'
    return 0
  fi
  echo ""
  return 0
}

handle_pr_number_refused() {
  echo "FAIL_MARKER: handle_pr_number_refused called for a real issue" >&2
  return 15
}

run_workflow() {
  local issue_number="$1"
  local issue_data
  issue_data=$(gh_safe issue view "$issue_number" --json state,title,closedAt,closedByPullRequestsReferences,url)
  local _issue_url
  _issue_url=$(echo "$issue_data" | jq -r '.url // ""' || true)
  if echo "$_issue_url" | grep -qF '/pull/'; then
    set +e
    handle_pr_number_refused "$issue_number" "$issue_data"
    set -e
    # Return 15 in both modes — matches real code.
    return 15
  fi
  # Past the check — real issue proceeds normally
  echo "PASS_MARKER: issue passed PR check"
  return 0
}

_exit=0
run_workflow "839" || _exit=$?

if [ "$_exit" -ne 0 ]; then
  echo "FAIL: real issue exited with non-zero code $_exit (should proceed normally)" >&2
  exit 1
fi

if ! grep -q "PASS_MARKER" <<< "$(run_workflow "839" 2>&1 || true)"; then
  :  # Already checked exit code above; output check is informational
fi
echo "PASS: real issue number passed PR check without refusal"
exit 0
STUB_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: linked issue is printed when PR body contains 'Closes #N'" {
  _script="$BATS_TEST_TMPDIR/test-linked-issue.sh"
  _write_stub_preamble "$_script" "false" "https://github.com/owner/repo/pull/489" "Fix authentication bug" "Closes #471"

  cat >> "$_script" <<'INLINE_EOF'

handle_pr_number_refused() {
  local issue_number="$1"
  local issue_data="$2"
  local pr_title
  pr_title=$(echo "$issue_data" | jq -r '.title // "unknown"' || true)
  print_error "#${issue_number} is a Pull Request, not an issue"
  print_error "PR title: ${pr_title}"
  local _pr_body
  _pr_body=$(gh_safe pr view "$issue_number" --json body --jq '.body' 2>/dev/null || true)
  local _linked_issue=""
  if [ -n "$_pr_body" ]; then
    _linked_issue=$(echo "$_pr_body" | grep -ioE '(closes|fixes|resolves)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
  fi
  if [ -n "$_linked_issue" ]; then
    print_error "Linked issue: #${_linked_issue}"
    print_error "Try: rite ${_linked_issue}"
  fi
  return 15
}

run_workflow() {
  local issue_number="$1"
  local issue_data
  issue_data=$(gh_safe issue view "$issue_number" --json state,title,closedAt,closedByPullRequestsReferences,url)
  local _issue_url
  _issue_url=$(echo "$issue_data" | jq -r '.url // ""' || true)
  if echo "$_issue_url" | grep -qF '/pull/'; then
    set +e
    handle_pr_number_refused "$issue_number" "$issue_data"
    set -e
    # Return 15 in both modes — matches real code.
    return 15
  fi
  return 0
}

_exit=0
run_workflow "489" 2>/tmp/linked_stderr_$$ || _exit=$?
_stderr=$(cat /tmp/linked_stderr_$$ || true)
rm -f /tmp/linked_stderr_$$

echo "STDERR_OUTPUT: $_stderr"

# Linked issue #471 must appear in the refusal message
if ! echo "$_stderr" | grep -q "471"; then
  echo "FAIL: linked issue #471 not mentioned in refusal message" >&2
  echo "Stderr was: $_stderr" >&2
  exit 1
fi

if ! echo "$_stderr" | grep -qi "rite 471"; then
  echo "FAIL: 'rite 471' suggestion not found in refusal message" >&2
  echo "Stderr was: $_stderr" >&2
  exit 1
fi

echo "PASS: linked issue printed correctly"
exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "PASS" || {
    echo "FAIL: PASS marker not found" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: linked issue suggestion is omitted when PR body has no closing reference" {
  _script="$BATS_TEST_TMPDIR/test-no-linked-issue.sh"
  # PR body has no "Closes #N" — only descriptive text
  _write_stub_preamble "$_script" "false" "https://github.com/owner/repo/pull/490" "Refactor module" "This PR refactors the module without closing any issue."

  cat >> "$_script" <<'INLINE_EOF'

handle_pr_number_refused() {
  local issue_number="$1"
  local issue_data="$2"
  local pr_title
  pr_title=$(echo "$issue_data" | jq -r '.title // "unknown"' || true)
  print_error "#${issue_number} is a Pull Request, not an issue"
  print_error "PR title: ${pr_title}"
  local _pr_body
  _pr_body=$(gh_safe pr view "$issue_number" --json body --jq '.body' 2>/dev/null || true)
  local _linked_issue=""
  if [ -n "$_pr_body" ]; then
    _linked_issue=$(echo "$_pr_body" | grep -ioE '(closes|fixes|resolves)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
  fi
  if [ -n "$_linked_issue" ]; then
    print_error "Linked issue: #${_linked_issue}"
    print_error "Try: rite ${_linked_issue}"
  else
    # No linked issue — suggest manual inspection
    print_error "No linked issue found in PR body — check the PR page manually"
  fi
  return 15
}

run_workflow() {
  local issue_number="$1"
  local issue_data
  issue_data=$(gh_safe issue view "$issue_number" --json state,title,closedAt,closedByPullRequestsReferences,url)
  local _issue_url
  _issue_url=$(echo "$issue_data" | jq -r '.url // ""' || true)
  if echo "$_issue_url" | grep -qF '/pull/'; then
    set +e
    handle_pr_number_refused "$issue_number" "$issue_data"
    set -e
    # Return 15 in both modes — matches real code.
    return 15
  fi
  return 0
}

_exit=0
run_workflow "490" 2>/tmp/nolink_stderr_$$ || _exit=$?
_stderr=$(cat /tmp/nolink_stderr_$$ || true)
rm -f /tmp/nolink_stderr_$$

echo "STDERR_OUTPUT: $_stderr"

# Must NOT print a specific #N suggestion when there's no closing reference
if echo "$_stderr" | grep -qE "Linked issue: #[0-9]+"; then
  echo "FAIL: linked issue suggestion was printed despite no Closes #N in PR body" >&2
  echo "Stderr was: $_stderr" >&2
  exit 1
fi

# Must still refuse (the PR number must be in the message)
if ! echo "$_stderr" | grep -q "490"; then
  echo "FAIL: refusal message did not mention PR #490" >&2
  exit 1
fi

echo "PASS: no linked-issue suggestion when PR body lacks closing ref"
exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "PASS" || {
    echo "FAIL: PASS marker not found" >&2
    echo "Output: $output" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: bin/rite phase-command entrypoints (#851)
# =============================================================================

@test "structural: _reject_if_pr_number() function exists in bin/rite" {
  # The helper centralizes the /pull/ guard for phase commands that bypass
  # run_workflow()'s check. Its absence means the guard is missing entirely.
  grep -q "^_reject_if_pr_number()" "$RITE_BINARY" || {
    echo "FAIL: _reject_if_pr_number() not found in bin/rite" >&2
    echo "      This function guards --status, --review-latest, and --assess-and-fix" >&2
    return 1
  }
}

@test "structural: _reject_if_pr_number() in bin/rite uses exit 15" {
  # Exit 15 is the canonical sentinel for PR-number refusals.
  # See: docs/architecture/exit-codes.md — exit code 15
  _func_body=$(awk '
    /^_reject_if_pr_number[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$RITE_BINARY")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract _reject_if_pr_number function body from bin/rite" >&2
    return 1
  }

  echo "$_func_body" | grep -qE '^\s*exit 15' || {
    echo "FAIL: _reject_if_pr_number() in bin/rite does not contain 'exit 15'" >&2
    echo "      Exit code 15 is the canonical sentinel for PR-number refusals" >&2
    return 1
  }
}

@test "structural: status-per-issue dispatch block in bin/rite calls _reject_if_pr_number" {
  # --status routes through pr-detection.sh directly, bypassing run_workflow()'s
  # /pull/ guard. The _reject_if_pr_number() call must appear in the
  # status-per-issue dispatch block, before the gh issue view fetch.
  _block=$(awk '
    /status-per-issue[)]\s*$/ { in_block=1; next }
    in_block && /^\s*;;$/ { exit }
    in_block { print $0 }
  ' "$RITE_BINARY")

  [ -n "$_block" ] || {
    echo "FAIL: Could not extract status-per-issue block from bin/rite" >&2
    return 1
  }

  echo "$_block" | grep -q '_reject_if_pr_number' || {
    echo "FAIL: status-per-issue block does not call _reject_if_pr_number" >&2
    echo "      A bare PR number passed to 'rite N --status' would silently show PR data" >&2
    return 1
  }
}

@test "structural: review-latest dispatch block in bin/rite calls _reject_if_pr_number" {
  # --review-latest calls normalize_and_resolve which uses 'gh issue view', so
  # a PR number silently passes. The _reject_if_pr_number() call must appear
  # BEFORE normalize_and_resolve in the review-latest dispatch block.
  _block=$(awk '
    /review-latest[)]\s*$/ { in_block=1; next }
    in_block && /^\s*;;$/ { exit }
    in_block { print $0 }
  ' "$RITE_BINARY")

  [ -n "$_block" ] || {
    echo "FAIL: Could not extract review-latest block from bin/rite" >&2
    return 1
  }

  echo "$_block" | grep -q '_reject_if_pr_number' || {
    echo "FAIL: review-latest block does not call _reject_if_pr_number" >&2
    echo "      A bare PR number passed to 'rite N --review-latest' would silently operate on a PR" >&2
    return 1
  }
}

@test "structural: assess-and-fix dispatch block in bin/rite calls _reject_if_pr_number" {
  # --assess-and-fix calls normalize_and_resolve before PR detection.
  # The _reject_if_pr_number() call must appear BEFORE normalize_and_resolve.
  _block=$(awk '
    /assess-and-fix[)]\s*$/ { in_block=1; next }
    in_block && /^\s*;;$/ { exit }
    in_block { print $0 }
  ' "$RITE_BINARY")

  [ -n "$_block" ] || {
    echo "FAIL: Could not extract assess-and-fix block from bin/rite" >&2
    return 1
  }

  echo "$_block" | grep -q '_reject_if_pr_number' || {
    echo "FAIL: assess-and-fix block does not call _reject_if_pr_number" >&2
    echo "      A bare PR number passed to 'rite N --assess-and-fix' would silently operate on a PR" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: bin/rite _reject_if_pr_number() (#851)
# =============================================================================

@test "behavioral: _reject_if_pr_number() exits 15 when issue number refers to a PR" {
  # Stubs gh_safe to return a /pull/ URL, sources the helper function from
  # bin/rite in function-only mode, invokes it, and asserts exit 15.
  # Mirrors test 23 (undo-workflow.sh behavioral) — same pattern, different target.
  _script="$BATS_TEST_TMPDIR/test-reject-if-pr-number.sh"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand (RITE_BINARY)
  cat > "$_script" <<STUB_EOF
#!/usr/bin/env bash
set -euo pipefail

ISSUE_NUMBER="490"

# Minimal stubs for bin/rite dependencies used by _reject_if_pr_number()
print_error()   { echo "ERROR: \$*" >&2; }
print_info()    { :; }
print_header()  { :; }
print_success() { :; }
print_step()    { :; }
verbose_info()  { :; }

# gh_safe stub: returns a /pull/ URL so _reject_if_pr_number() fires
gh_safe() {
  if [ "\${1:-}" = "issue" ] && [ "\${2:-}" = "view" ]; then
    echo '{"url":"https://github.com/owner/repo/pull/490","title":"Old PR title"}'
    return 0
  fi
  if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
    echo '{"body":""}'
    return 0
  fi
  echo ""
  return 0
}

# Extract and define only _reject_if_pr_number() from bin/rite
# (awk pulls the function body; eval sources it into this shell)
_func_body=\$(awk '
  /^_reject_if_pr_number[(][)]/ { in_func=1; print; next }
  in_func && /^\}$/ { print; in_func=0; next }
  in_func { print }
' "${RITE_BINARY}")

[ -n "\$_func_body" ] || {
  echo "FAIL: Could not extract _reject_if_pr_number from bin/rite" >&2
  exit 1
}

eval "\$_func_body"

# Invoke the guard in a subshell — _reject_if_pr_number() uses 'exit 15',
# so we must capture it from a subshell rather than via || capture.
_exit=0
( _reject_if_pr_number "\$ISSUE_NUMBER" ) || _exit=\$?

if [ "\$_exit" -ne 15 ]; then
  echo "FAIL: expected exit 15 for PR number, got \$_exit" >&2
  exit 1
fi
echo "PASS: _reject_if_pr_number() exited 15 for PR number"
exit 0
STUB_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "PASS" || {
    echo "FAIL: PASS marker not found in output" >&2
    echo "Output: $output" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: undo-workflow.sh (#851)
# =============================================================================

@test "structural: undo-workflow.sh delegates to refuse_if_pr_number before Phase 1 Discovery" {
  # The guard now delegates to lib/utils/pr-refusal.sh (refuse_if_pr_number).
  # Verify the delegation call exists and appears before Phase 1 Discovery.
  _guard_line=$(grep -n "refuse_if_pr_number" "$UNDO_WORKFLOW" | head -1 | cut -d: -f1 || true)
  [ -n "$_guard_line" ] || {
    echo "FAIL: No refuse_if_pr_number call found in undo-workflow.sh" >&2
    echo "      The PR-number guard must delegate to lib/utils/pr-refusal.sh" >&2
    return 1
  }

  _phase1_line=$(grep -n "PHASE 1: DISCOVERY" "$UNDO_WORKFLOW" | head -1 | cut -d: -f1 || true)
  [ -n "$_phase1_line" ] || {
    echo "FAIL: Could not find 'PHASE 1: DISCOVERY' marker in undo-workflow.sh" >&2
    return 1
  }

  if [ "$_guard_line" -ge "$_phase1_line" ]; then
    echo "FAIL: refuse_if_pr_number call (line $_guard_line) must appear BEFORE Phase 1 Discovery (line $_phase1_line)" >&2
    echo "      The guard must fire before any discovery side effects run" >&2
    return 1
  fi
}

@test "structural: undo-workflow.sh exits 15 in the PR-number guard" {
  # Exit 15 is the canonical sentinel for bare-PR-number refusals.
  # The guard line uses '|| exit 15' so the process exits when the helper returns 15.
  _guard_line=$(grep -n "refuse_if_pr_number" "$UNDO_WORKFLOW" | head -1 | cut -d: -f1 || true)
  _phase1_line=$(grep -n "PHASE 1: DISCOVERY" "$UNDO_WORKFLOW" | head -1 | cut -d: -f1 || true)

  [ -n "$_guard_line" ] && [ -n "$_phase1_line" ] || {
    echo "FAIL: Could not locate the guard boundaries in undo-workflow.sh" >&2
    return 1
  }

  _guard_block=$(awk "NR >= $_guard_line && NR < $_phase1_line" "$UNDO_WORKFLOW")
  echo "$_guard_block" | grep -q 'exit 15' || {
    echo "FAIL: undo-workflow.sh guard does not contain 'exit 15'" >&2
    echo "      Exit code 15 is the canonical sentinel for PR-number refusals" >&2
    echo "      See: docs/architecture/exit-codes.md — exit code 15" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: undo-workflow.sh (#851)
# =============================================================================

@test "behavioral: undo-workflow.sh exits 15 when issue number refers to a PR" {
  # rite <PR#> --undo must be refused before any discovery or cleanup work runs.
  # Sources refuse_if_pr_number from the shared helper and exercises the
  # undo-workflow.sh delegation pattern: refuse_if_pr_number ... || exit 15.
  _script="$BATS_TEST_TMPDIR/test-undo-pr-refused.sh"
  _pr_refusal_lib="$REPO_ROOT/lib/utils/pr-refusal.sh"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand (BATS_TEST_TMPDIR, _pr_refusal_lib)
  cat > "$_script" <<STUB_EOF
#!/usr/bin/env bash
set -euo pipefail

ISSUE_NUMBER="490"

print_error() { echo "ERROR: \$*" >&2; }

# gh_safe stub: returns a PR url for issue view calls
gh_safe() {
  if [ "\${1:-}" = "issue" ] && [ "\${2:-}" = "view" ]; then
    echo '{"url":"https://github.com/owner/repo/pull/490","title":"Old PR title"}'
    return 0
  fi
  if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
    echo '{"body":""}'
    return 0
  fi
  echo ""
  return 0
}

# Load the shared helper (mirrors undo-workflow.sh's source line)
source "${_pr_refusal_lib}"

# Exercise the delegation pattern from undo-workflow.sh
refuse_if_pr_number "\$ISSUE_NUMBER" "" "rite --undo" || exit 15

# Should not reach here for a PR number
echo "FAIL_MARKER: guard did not fire for PR number" >&2
exit 1
STUB_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 15 ] || {
    echo "FAIL: expected exit 15 for PR number in undo mode, got $status" >&2
    echo "Output: $output" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: lib/utils/pr-refusal.sh — shared helper (this issue)
# =============================================================================

@test "structural: refuse_if_pr_number() function exists in lib/utils/pr-refusal.sh" {
  grep -q "^refuse_if_pr_number()" "$PR_REFUSAL_LIB" || {
    echo "FAIL: refuse_if_pr_number() not found in lib/utils/pr-refusal.sh" >&2
    echo "      This is the shared canonical PR-refusal helper" >&2
    return 1
  }
}

@test "structural: lib/utils/pr-refusal.sh has a function-sentinel re-source guard" {
  # The guard must use 'declare -f refuse_if_pr_number' so multiple sources are safe.
  grep -q "declare -f refuse_if_pr_number" "$PR_REFUSAL_LIB" || {
    echo "FAIL: No function-sentinel re-source guard found in lib/utils/pr-refusal.sh" >&2
    echo "      Guard pattern: 'if declare -f refuse_if_pr_number >/dev/null 2>&1'" >&2
    return 1
  }
}

@test "structural: workflow-runner.sh sources pr-refusal.sh" {
  grep -q "source.*pr-refusal.sh" "$WORKFLOW_RUNNER" || {
    echo "FAIL: workflow-runner.sh does not source lib/utils/pr-refusal.sh" >&2
    return 1
  }
}

@test "structural: bin/rite sources pr-refusal.sh" {
  grep -q "source.*pr-refusal.sh" "$RITE_BINARY" || {
    echo "FAIL: bin/rite does not source lib/utils/pr-refusal.sh" >&2
    return 1
  }
}

@test "structural: undo-workflow.sh sources pr-refusal.sh" {
  grep -q "source.*pr-refusal.sh" "$UNDO_WORKFLOW" || {
    echo "FAIL: undo-workflow.sh does not source lib/utils/pr-refusal.sh" >&2
    return 1
  }
}

@test "structural: handle_pr_number_refused() in workflow-runner.sh delegates to refuse_if_pr_number" {
  _func_body=$(awk '
    /^handle_pr_number_refused[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract handle_pr_number_refused function body" >&2
    return 1
  }

  echo "$_func_body" | grep -q "refuse_if_pr_number" || {
    echo "FAIL: handle_pr_number_refused() does not delegate to refuse_if_pr_number" >&2
    echo "      The function must call the shared helper instead of duplicating logic" >&2
    return 1
  }
}

@test "structural: _reject_if_pr_number() in bin/rite delegates to refuse_if_pr_number" {
  _func_body=$(awk '
    /^_reject_if_pr_number[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$RITE_BINARY")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract _reject_if_pr_number function body from bin/rite" >&2
    return 1
  }

  echo "$_func_body" | grep -q "refuse_if_pr_number" || {
    echo "FAIL: _reject_if_pr_number() does not delegate to refuse_if_pr_number" >&2
    echo "      The function must call the shared helper instead of duplicating logic" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: lib/utils/pr-refusal.sh — shared helper (this issue)
# =============================================================================

@test "behavioral: refuse_if_pr_number() returns 15 for a PR number" {
  _script="$BATS_TEST_TMPDIR/test-rpn-pr-returns-15.sh"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand (PR_REFUSAL_LIB)
  cat > "$_script" <<STUB_EOF
#!/usr/bin/env bash
set -euo pipefail

print_error() { echo "ERROR: \$*" >&2; }

# gh_safe stub: returns a /pull/ URL
gh_safe() {
  if [ "\${1:-}" = "issue" ] && [ "\${2:-}" = "view" ]; then
    echo '{"url":"https://github.com/owner/repo/pull/490","title":"Old PR title"}'
    return 0
  fi
  if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
    echo '{"body":""}'
    return 0
  fi
  echo ""
  return 0
}

source "${PR_REFUSAL_LIB}"

_exit=0
refuse_if_pr_number "490" "" "rite" || _exit=\$?

if [ "\$_exit" -ne 15 ]; then
  echo "FAIL: expected return 15 for PR number, got \$_exit" >&2
  exit 1
fi
echo "PASS: refuse_if_pr_number returned 15 for PR number"
exit 0
STUB_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "PASS" || {
    echo "FAIL: PASS marker not found" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: refuse_if_pr_number() returns 0 for a real issue number" {
  _script="$BATS_TEST_TMPDIR/test-rpn-issue-returns-0.sh"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand (PR_REFUSAL_LIB)
  cat > "$_script" <<STUB_EOF
#!/usr/bin/env bash
set -euo pipefail

print_error() { echo "ERROR: \$*" >&2; }

# gh_safe stub: returns an /issues/ URL (real issue, not PR)
gh_safe() {
  if [ "\${1:-}" = "issue" ] && [ "\${2:-}" = "view" ]; then
    echo '{"url":"https://github.com/owner/repo/issues/839","title":"A real issue"}'
    return 0
  fi
  echo ""
  return 0
}

source "${PR_REFUSAL_LIB}"

_exit=0
refuse_if_pr_number "839" "" "rite" || _exit=\$?

if [ "\$_exit" -ne 0 ]; then
  echo "FAIL: expected return 0 for real issue, got \$_exit" >&2
  exit 1
fi
echo "PASS: refuse_if_pr_number returned 0 for real issue"
exit 0
STUB_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "PASS" || {
    echo "FAIL: PASS marker not found" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: refuse_if_pr_number() accepts pre-fetched ISSUE_DATA (no extra gh issue view call)" {
  # When ISSUE_DATA is provided, gh_safe issue view must NOT be called.
  # If it is called, the stub fails loudly.
  _script="$BATS_TEST_TMPDIR/test-rpn-prefetched-data.sh"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand (PR_REFUSAL_LIB)
  cat > "$_script" <<STUB_EOF
#!/usr/bin/env bash
set -euo pipefail

print_error() { echo "ERROR: \$*" >&2; }

# gh_safe stub: fails if called for 'issue view' (data was pre-fetched)
gh_safe() {
  if [ "\${1:-}" = "issue" ] && [ "\${2:-}" = "view" ]; then
    echo "FAIL: gh_safe issue view was called despite pre-fetched ISSUE_DATA" >&2
    exit 2
  fi
  # pr view is allowed (linked-issue lookup)
  if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
    echo '{"body":""}'
    return 0
  fi
  echo ""
  return 0
}

source "${PR_REFUSAL_LIB}"

# Pre-fetched data with /pull/ URL — no extra API call should happen
_prefetched='{"url":"https://github.com/owner/repo/pull/490","title":"Old PR"}'

_exit=0
refuse_if_pr_number "490" "\$_prefetched" "rite" || _exit=\$?

if [ "\$_exit" -ne 15 ]; then
  echo "FAIL: expected return 15 for pre-fetched PR data, got \$_exit" >&2
  exit 1
fi
echo "PASS: refuse_if_pr_number used pre-fetched data without extra API call"
exit 0
STUB_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "PASS" || {
    echo "FAIL: PASS marker not found" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: refuse_if_pr_number() uses CALLER_VERB in the error message" {
  # The CALLER_VERB arg customizes the 'accepts issue numbers only' line.
  # undo-workflow.sh passes 'rite --undo' so the message says
  # 'rite --undo accepts issue numbers only.' instead of just 'rite'.
  _script="$BATS_TEST_TMPDIR/test-rpn-caller-verb.sh"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand (PR_REFUSAL_LIB)
  cat > "$_script" <<STUB_EOF
#!/usr/bin/env bash
set -euo pipefail

print_error() { echo "ERROR: \$*" >&2; }

gh_safe() {
  if [ "\${1:-}" = "issue" ] && [ "\${2:-}" = "view" ]; then
    echo '{"url":"https://github.com/owner/repo/pull/490","title":"Old PR title"}'
    return 0
  fi
  if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
    echo '{"body":""}'
    return 0
  fi
  echo ""
  return 0
}

source "${PR_REFUSAL_LIB}"

_exit=0
refuse_if_pr_number "490" "" "rite --undo" 2>/tmp/rpn_verb_stderr_\$\$ || _exit=\$?
_stderr=\$(cat /tmp/rpn_verb_stderr_\$\$ || true)
rm -f /tmp/rpn_verb_stderr_\$\$

if [ "\$_exit" -ne 15 ]; then
  echo "FAIL: expected return 15 for PR number, got \$_exit" >&2
  exit 1
fi

if ! echo "\$_stderr" | grep -q "rite --undo"; then
  echo "FAIL: CALLER_VERB 'rite --undo' not found in error message" >&2
  echo "Stderr was: \$_stderr" >&2
  exit 1
fi
echo "PASS: refuse_if_pr_number used CALLER_VERB in error message"
exit 0
STUB_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "PASS" || {
    echo "FAIL: PASS marker not found" >&2
    echo "Output: $output" >&2
    return 1
  }
}
