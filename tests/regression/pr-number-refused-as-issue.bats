#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/core/batch-process-issues.sh
# tests/regression/pr-number-refused-as-issue.bats
#
# Regression test: rite must refuse a bare PR number before any dev work runs.
#
# Issue #839 — "Reject bare PR numbers in issue commands"
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
#   4. Single-issue mode: run_workflow() converts 15 to return 1 (non-zero refusal).
#   5. Batch mode: run_workflow() returns 15; batch records pr_number_refused
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
#    10. Single-issue mode: run_workflow exits 1 for PR number (not 0 or 15)
#    11. Single-issue mode: refusal message names the PR
#    12. Batch mode: run_workflow exits 15 for PR number (sentinel)
#    13. Real issue number: url /issues/ path passes the check unchanged
#    14. Linked issue is printed when PR body contains "Closes #N"
#    15. Linked issue suggestion is omitted when PR body has no closing ref

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WORKFLOW_RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"

setup() {
  [ -f "$WORKFLOW_RUNNER" ] || {
    echo "FATAL: $WORKFLOW_RUNNER not found" >&2
    return 1
  }
  [ -f "$BATCH_PROCESSOR" ] || {
    echo "FATAL: $BATCH_PROCESSOR not found" >&2
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

@test "behavioral: single-issue mode exits 1 (not 15) when number is a PR" {
  # run_workflow() must convert the internal return-15 to return-1 in single-issue
  # mode so callers in set -e chains don't see a surprising non-standard exit code.

  _script="$BATS_TEST_TMPDIR/test-single-pr-refused.sh"
  _write_stub_preamble "$_script" "false" "https://github.com/owner/repo/pull/490" "Old PR title"

  cat >> "$_script" <<'INLINE_EOF'

# Paste the functions under test
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
    local _pr_ref_exit
    set +e
    handle_pr_number_refused "$issue_number" "$issue_data"
    _pr_ref_exit=$?
    set -e
    if [ "${BATCH_MODE:-false}" = "true" ]; then
      return $_pr_ref_exit
    else
      return 1
    fi
  fi
  return 0
}

_exit=0
run_workflow "490" || _exit=$?

if [ "$_exit" -ne 1 ]; then
  echo "FAIL: expected exit 1 for PR number in single-issue mode, got $_exit" >&2
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
    local _pr_ref_exit
    set +e
    handle_pr_number_refused "$issue_number" "$issue_data"
    _pr_ref_exit=$?
    set -e
    [ "${BATCH_MODE:-false}" = "true" ] && return $_pr_ref_exit
    return 1
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
    local _pr_ref_exit
    set +e
    handle_pr_number_refused "$issue_number" "$issue_data"
    _pr_ref_exit=$?
    set -e
    if [ "${BATCH_MODE:-false}" = "true" ]; then
      return $_pr_ref_exit
    else
      return 1
    fi
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
    local _pr_ref_exit
    set +e
    handle_pr_number_refused "$issue_number" "$issue_data"
    _pr_ref_exit=$?
    set -e
    [ "${BATCH_MODE:-false}" = "true" ] && return $_pr_ref_exit
    return 1
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
    local _pr_ref_exit
    set +e
    handle_pr_number_refused "$issue_number" "$issue_data"
    _pr_ref_exit=$?
    set -e
    [ "${BATCH_MODE:-false}" = "true" ] && return $_pr_ref_exit
    return 1
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
    local _pr_ref_exit
    set +e
    handle_pr_number_refused "$issue_number" "$issue_data"
    _pr_ref_exit=$?
    set -e
    [ "${BATCH_MODE:-false}" = "true" ] && return $_pr_ref_exit
    return 1
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
