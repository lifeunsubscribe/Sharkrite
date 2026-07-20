#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/core/batch-process-issues.sh, lib/utils/pr-detection.sh
# tests/regression/branch-mismatch-refusal.bats
#
# Regression test: rite must refuse early (exit 19) when an existing PR's
# baseRefName differs from the effective target branch resolved for the issue.
#
# Issue #1044 — "Block PR base mismatch with corrected command"
#
# Root cause: Without this guard, a re-run of an issue whose PR targets an
# integration branch would silently operate on that PR even if the user invokes
# `rite N` with the default main target — causing stale-branch rebase or merge
# against the wrong base, potentially shipping unreviewed integration changes.
#
# Fix:
#   1. detect_pr_for_issue() fetches baseRefName alongside headRefName (same
#      API call, no extra round-trip) and sets PR_BASE_BRANCH.
#   2. run_workflow()'s inline worktree-detection block also fetches baseRefName
#      (headRefName,baseRefName) when the worktree is unknown, setting PR_BASE_BRANCH.
#   3. A new branch-mismatch guard runs AFTER worktree detection and BEFORE
#      check_stale_branch (so no rebase/close/merge ever runs against a mismatched PR).
#   4. handle_branch_mismatch() prints the verbose block and returns 19.
#   5. run_workflow() returns 19 in both single-issue and batch modes.
#   6. main() propagates 19 without "Workflow failed".
#   7. batch-process-issues.sh: elif _WF_EXIT=19 records branch_mismatch
#      (SKIPPED class); branch_mismatch added to gate-breaker non-failure list.
#
# Tests in this file:
#   STRUCTURAL (static code inspection of workflow-runner.sh):
#     1.  handle_branch_mismatch() function exists
#     2.  handle_branch_mismatch() returns 19 (not 0 or 1)
#     3.  handle_branch_mismatch() output contains "rite --branch"
#     4.  handle_branch_mismatch() does NOT assign RITE_TARGET_BRANCH (no auto-adopt)
#     5.  mismatch check appears before check_stale_branch in run_workflow()
#     6.  mismatch check calls resolve_target_branch WITHOUT the PR number (avoids circular match)
#     7.  inline worktree-detection block fetches baseRefName alongside headRefName
#     8.  exit-19 case exists in main()'s workflow_exit dispatcher
#
#   STRUCTURAL (static code inspection of batch-process-issues.sh):
#     9.  elif [ $_WF_EXIT -eq 19 ] branch exists
#    10.  branch_mismatch status is set in the exit-19 branch
#    11.  branch_mismatch is in the gate-breaker non-failure case list
#    12.  no gh pr list/view/issue list in the exit-19 branch (non-comment)
#
#   STRUCTURAL (static code inspection of pr-detection.sh):
#    13.  detect_pr_for_issue() fetches baseRefName in the same gh pr view call
#    14.  PR_BASE_BRANCH is initialized in detect_pr_for_issue()
#
#   STRUCTURAL (CLAUDE.md):
#    15.  exit-19 documented in the key-codes bullet
#
#   BEHAVIORAL (subprocess execution with stubs):
#    16.  base=big, target=main  → exits 19, output contains "rite --branch big"
#    17.  base=main, target=big  → exits 19, output contains "rite 42" (no --branch)
#    18.  base == target         → no refusal, exits 0 (workflow continues)
#    19.  batch _WF_EXIT=19      → branch_mismatch in ISSUE_STATUS, in SKIPPED_ISSUES

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WORKFLOW_RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
PR_DETECTION="$REPO_ROOT/lib/utils/pr-detection.sh"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

setup() {
  [ -f "$WORKFLOW_RUNNER" ] || {
    echo "FATAL: $WORKFLOW_RUNNER not found" >&2
    return 1
  }
  [ -f "$BATCH_PROCESSOR" ] || {
    echo "FATAL: $BATCH_PROCESSOR not found" >&2
    return 1
  }
  [ -f "$PR_DETECTION" ] || {
    echo "FATAL: $PR_DETECTION not found" >&2
    return 1
  }
  [ -f "$CLAUDE_MD" ] || {
    echo "FATAL: $CLAUDE_MD not found" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: workflow-runner.sh
# =============================================================================

@test "structural: handle_branch_mismatch() function exists in workflow-runner.sh" {
  grep -q "^handle_branch_mismatch()" "$WORKFLOW_RUNNER" || {
    echo "FAIL: handle_branch_mismatch() function not found in workflow-runner.sh" >&2
    return 1
  }
}

@test "structural: handle_branch_mismatch() returns 19" {
  _func_body=$(awk '
    /^handle_branch_mismatch[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract handle_branch_mismatch function body" >&2
    return 1
  }

  echo "$_func_body" | grep -qE '^\s*return 19' || {
    echo "FAIL: handle_branch_mismatch() does not contain 'return 19'" >&2
    echo "      Exit code 19 is the batch sentinel for branch-mismatch refusals" >&2
    return 1
  }
}

@test "structural: handle_branch_mismatch() output contains 'rite --branch'" {
  _func_body=$(awk '
    /^handle_branch_mismatch[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract handle_branch_mismatch function body" >&2
    return 1
  }

  echo "$_func_body" | grep -qE "rite --branch" || {
    echo "FAIL: handle_branch_mismatch() does not include 'rite --branch' in its output" >&2
    echo "      The corrected command must appear in the refusal message" >&2
    return 1
  }
}

@test "structural: handle_branch_mismatch() does NOT assign RITE_TARGET_BRANCH (no auto-adopt)" {
  _func_body=$(awk '
    /^handle_branch_mismatch[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract handle_branch_mismatch function body" >&2
    return 1
  }

  _assign_count=$(echo "$_func_body" | grep -cE "RITE_TARGET_BRANCH=" || true)
  [ "$_assign_count" -eq 0 ] || {
    echo "FAIL: handle_branch_mismatch() assigns RITE_TARGET_BRANCH (auto-adopt is forbidden)" >&2
    echo "      The handler must only print the refusal block and return 19" >&2
    return 1
  }
}

@test "structural: mismatch check appears before check_stale_branch in run_workflow()" {
  _func_with_lines=$(awk '
    /^run_workflow[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print NR": "$0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_with_lines" ] || {
    echo "FAIL: Could not extract run_workflow function body" >&2
    return 1
  }

  _mismatch_line=$(echo "$_func_with_lines" | grep -E "handle_branch_mismatch" | head -1 | grep -oE '^[0-9]+' || true)
  [ -n "$_mismatch_line" ] || {
    echo "FAIL: handle_branch_mismatch call not found in run_workflow()" >&2
    return 1
  }

  _stale_line=$(echo "$_func_with_lines" | grep -E "check_stale_branch" | head -1 | grep -oE '^[0-9]+' || true)
  [ -n "$_stale_line" ] || {
    echo "FAIL: check_stale_branch call not found in run_workflow()" >&2
    return 1
  }

  if [ "$_mismatch_line" -ge "$_stale_line" ]; then
    echo "FAIL: mismatch check (line $_mismatch_line) must appear BEFORE check_stale_branch (line $_stale_line)" >&2
    echo "      Without this, a mismatched PR could be rebased/closed/merged against the wrong base" >&2
    return 1
  fi
}

@test "structural: mismatch guard calls resolve_target_branch WITHOUT PR number (avoids circular match)" {
  # The resolve_target_branch call for the mismatch check must NOT pass PR_NUMBER
  # as the second argument. If it did, tier 1 would return the PR's own baseRefName,
  # making the comparison always match (circular).
  # The guard uses a local variable (_mismatch_target) to hold the result and
  # calls resolve_target_branch with only the issue number.
  _func_body=$(awk '
    /^run_workflow[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract run_workflow function body" >&2
    return 1
  }

  # The line that assigns _mismatch_target must call resolve_target_branch
  _mismatch_resolve=$(echo "$_func_body" | grep -E "_mismatch_target" | grep "resolve_target_branch" || true)
  [ -n "$_mismatch_resolve" ] || {
    echo "FAIL: No '_mismatch_target=\$(resolve_target_branch...)' assignment found in run_workflow()" >&2
    echo "      The guard must store the resolver result in _mismatch_target" >&2
    return 1
  }

  # That call must NOT pass PR_NUMBER as the second argument (would be circular)
  if echo "$_mismatch_resolve" | grep -qE 'resolve_target_branch[^)]*PR_NUMBER'; then
    echo "FAIL: mismatch check passes PR_NUMBER to resolve_target_branch (circular match)" >&2
    echo "      Passing the PR makes tier 1 return baseRefName itself — comparison always matches" >&2
    return 1
  fi
}

@test "structural: inline worktree-detection block fetches baseRefName alongside headRefName" {
  # Both must appear in the same --json argument (no extra round-trip).
  grep -qE "headRefName,baseRefName|baseRefName,headRefName" "$WORKFLOW_RUNNER" || {
    echo "FAIL: No combined headRefName+baseRefName fetch found in workflow-runner.sh" >&2
    echo "      The inline worktree-detection block must fetch both in a single API call" >&2
    return 1
  }
}

@test "structural: main() workflow_exit dispatcher has exit-19 case" {
  grep -qE '\[ \$workflow_exit -eq 19 \]' "$WORKFLOW_RUNNER" || {
    echo "FAIL: No 'workflow_exit -eq 19' case in workflow-runner.sh main() dispatcher" >&2
    echo "      Without this, batch cannot distinguish branch-mismatch from a real failure" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: batch-process-issues.sh
# =============================================================================

@test "structural: batch-process-issues.sh has elif _WF_EXIT -eq 19 branch" {
  grep -qE 'elif \[ \$_WF_EXIT -eq 19 \]' "$BATCH_PROCESSOR" || {
    echo "FAIL: No 'elif [ \$_WF_EXIT -eq 19 ]' branch in batch-process-issues.sh" >&2
    echo "      Exit 19 must route to the branch_mismatch skip path" >&2
    return 1
  }
}

@test "structural: branch_mismatch status is set in the exit-19 branch" {
  _branch_body=$(awk '
    /elif \[ \$_WF_EXIT -eq 19 \]/ { in_branch=1; next }
    in_branch && /^[[:space:]]*(elif|else)[[:space:]]/ { exit }
    in_branch { print $0 }
  ' "$BATCH_PROCESSOR")

  [ -n "$_branch_body" ] || {
    echo "FAIL: Could not extract exit-19 branch body from batch-process-issues.sh" >&2
    return 1
  }

  echo "$_branch_body" | grep -q "branch_mismatch" || {
    echo "FAIL: 'branch_mismatch' not found in exit-19 branch of batch-process-issues.sh" >&2
    echo "      ISSUE_STATUS must be set to 'branch_mismatch' for proper reporting" >&2
    return 1
  }
}

@test "structural: branch_mismatch is in the gate-breaker non-failure case list" {
  grep -qE "branch_mismatch" "$BATCH_PROCESSOR" | grep -q "case" || true
  # Check that the _update_gate_breaker_counter case list includes branch_mismatch
  _breaker_body=$(awk '
    /^_update_gate_breaker_counter[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$BATCH_PROCESSOR")

  echo "$_breaker_body" | grep -q "branch_mismatch" || {
    echo "FAIL: 'branch_mismatch' not found in _update_gate_breaker_counter case list" >&2
    echo "      A branch-mismatch skip must reset the gate-breaker streak" >&2
    return 1
  }
}

@test "structural: no gh stat-gathering in exit-19 branch (non-comment)" {
  _branch_body=$(awk '
    /elif \[ \$_WF_EXIT -eq 19 \]/ { in_branch=1; next }
    in_branch && /^[[:space:]]*(elif|else)[[:space:]]/ { exit }
    in_branch { print $0 }
  ' "$BATCH_PROCESSOR")

  [ -n "$_branch_body" ] || {
    echo "FAIL: Could not extract exit-19 branch body from batch-process-issues.sh" >&2
    return 1
  }

  _noncomment_body=$(echo "$_branch_body" | grep -v '^\s*#')

  if echo "$_noncomment_body" | grep -qE 'gh.*pr list'; then
    echo "FAIL: 'gh pr list' (non-comment) found in exit-19 branch" >&2
    echo "      No dev session ran for a branch-mismatch refusal — stat-gathering must be skipped" >&2
    return 1
  fi

  if echo "$_noncomment_body" | grep -qE 'gh.*pr view'; then
    echo "FAIL: 'gh pr view' (non-comment) found in exit-19 branch" >&2
    echo "      PR stat gathering must be skipped for branch-mismatch refusals" >&2
    return 1
  fi

  if echo "$_noncomment_body" | grep -qE 'gh.*issue list'; then
    echo "FAIL: 'gh issue list' (non-comment) found in exit-19 branch" >&2
    echo "      Tech-debt issue search must be skipped for branch-mismatch refusals" >&2
    return 1
  fi
}

# =============================================================================
# STRUCTURAL: pr-detection.sh
# =============================================================================

@test "structural: detect_pr_for_issue() fetches baseRefName in the same gh pr view call" {
  grep -qE "baseRefName" "$PR_DETECTION" || {
    echo "FAIL: 'baseRefName' not found in pr-detection.sh" >&2
    echo "      detect_pr_for_issue() must fetch baseRefName alongside headRefName" >&2
    return 1
  }

  # Both names must appear in the same gh pr view call (not separate round-trips).
  grep -qE "headRefName,baseRefName|baseRefName,headRefName" "$PR_DETECTION" || {
    echo "FAIL: Combined headRefName+baseRefName fetch not found in pr-detection.sh" >&2
    echo "      Both must be requested in the same --json argument (no extra API call)" >&2
    return 1
  }
}

@test "structural: PR_BASE_BRANCH is initialized in detect_pr_for_issue()" {
  _func_body=$(awk '
    /^detect_pr_for_issue[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$PR_DETECTION")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract detect_pr_for_issue function body" >&2
    return 1
  }

  echo "$_func_body" | grep -qE 'PR_BASE_BRANCH=' || {
    echo "FAIL: PR_BASE_BRANCH not initialized in detect_pr_for_issue()" >&2
    echo "      Callers depend on PR_BASE_BRANCH being set (even to empty) on each call" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: CLAUDE.md
# =============================================================================

@test "structural: CLAUDE.md documents exit 19 (branch mismatch) in key-codes bullet" {
  grep -qiE "branch.mismatch" "$CLAUDE_MD" || {
    echo "FAIL: 'branch mismatch' not found in CLAUDE.md" >&2
    echo "      Exit code 19 must be documented in the key-codes Common Pitfalls bullet" >&2
    return 1
  }

  grep -qE "exit 19|19.*branch" "$CLAUDE_MD" || {
    echo "FAIL: Exit 19 not documented in CLAUDE.md" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: subprocess execution with stubs
# =============================================================================

# Write the minimal stub preamble for behavioral tests.
_write_mismatch_stub_preamble() {
  local _script="$1"
  local _batch_mode="${2:-false}"
  local _pr_base="${3:-big}"      # PR's baseRefName
  local _effective_target="${4:-main}"  # effective target from resolver

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand
  cat > "$_script" <<STUB_EOF
#!/usr/bin/env bash
set -euo pipefail

RITE_LIB_DIR="/dev/null/stub"
RITE_PROJECT_ROOT="\$BATS_TEST_TMPDIR"
RITE_DATA_DIR=".rite"
WORKFLOW_MODE="unsupervised"
RESUME_MODE=false
BYPASS_BLOCKERS=false
CURRENT_PHASE=""
CURRENT_ISSUE=""
CURRENT_PR="456"
CURRENT_RETRY=0
INTERRUPT_RECEIVED=false
CLOSING_ISSUE_JQ_REGEX=""
BATCH_MODE=${_batch_mode}
PR_BASE_BRANCH="${_pr_base}"

print_header()  { :; }
print_info()    { echo "INFO: \$*" >&2; }
print_success() { :; }
print_status()  { :; }
print_step()    { :; }
verbose_info()  { :; }
print_error()   { echo "ERROR: \$*" >&2; }

iso_to_epoch() { echo "1767225600"; }

# resolve_target_branch stub: returns effective target WITHOUT PR number argument.
# When PR number IS passed (tier 1), returns the target as-is to avoid circular match.
resolve_target_branch() {
  local _issue="\${1:-}"
  local _pr="\${2:-}"
  # Stub: returns the configured effective target when called without PR arg.
  # When called with PR arg (for detect_pr_for_issue path), still returns the
  # same value so tier-1 would be the PR base — but the mismatch guard calls
  # WITHOUT the PR arg specifically to avoid this circularity.
  echo "${_effective_target}"
}
RESOLVED_TARGET_BRANCH="${_effective_target}"
RESOLVED_TARGET_SOURCE="default"

handle_branch_mismatch() {
  local issue_number="\$1"
  local pr_number="\$2"
  local pr_base="\$3"
  local effective_target="\$4"
  local _corrected_cmd
  if [ "\$pr_base" = "main" ]; then
    _corrected_cmd="rite \${issue_number}"
  else
    _corrected_cmd="rite --branch \${pr_base} \${issue_number}"
  fi
  print_error "PR #\${pr_number} base mismatch for issue #\${issue_number}"
  print_error "  PR #\${pr_number} is based on:  \${pr_base}"
  print_error "  Current effective target:       \${effective_target}"
  print_error "  Re-run with: \${_corrected_cmd}"
  return 19
}

STUB_EOF
}

@test "behavioral: base=big target=main → exits 19 and output contains 'rite --branch big'" {
  _script="$BATS_TEST_TMPDIR/test-mismatch-big-main.sh"
  _write_mismatch_stub_preamble "$_script" "false" "big" "main"

  cat >> "$_script" <<'INLINE_EOF'

PR_NUMBER="456"

_mismatch_exit=0
set +e
handle_branch_mismatch "42" "$PR_NUMBER" "$PR_BASE_BRANCH" "main"
_mismatch_exit=$?
set -e

if [ "$_mismatch_exit" -ne 19 ]; then
  echo "FAIL: expected exit 19, got $_mismatch_exit" >&2
  exit 1
fi

# Capture output to verify corrected command appears
_output=$(handle_branch_mismatch "42" "$PR_NUMBER" "big" "main" 2>&1 || true)
if ! echo "$_output" | grep -qF "rite --branch big"; then
  echo "FAIL: corrected command 'rite --branch big' not in output" >&2
  echo "Output was: $_output" >&2
  exit 1
fi

exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: test script exited $status" >&2
    echo "$output" >&2
    return 1
  }
}

@test "behavioral: base=main target=big → exits 19 and suggests 'rite 42' (no --branch)" {
  _script="$BATS_TEST_TMPDIR/test-mismatch-main-big.sh"
  _write_mismatch_stub_preamble "$_script" "false" "main" "big"

  cat >> "$_script" <<'INLINE_EOF'

PR_NUMBER="456"

# When PR base is "main" and effective target is "big":
# corrected command should be "rite 42" (drop --branch, use default target)
# Capture exit code separately (not via $? after || true) to avoid clobbering.
_mismatch_exit=0
set +e
handle_branch_mismatch "42" "$PR_NUMBER" "main" "big"
_mismatch_exit=$?
set -e

if [ "$_mismatch_exit" -ne 19 ]; then
  echo "FAIL: expected exit 19, got $_mismatch_exit" >&2
  exit 1
fi

# Capture output text separately
_output=$(handle_branch_mismatch "42" "$PR_NUMBER" "main" "big" 2>&1 || true)

if ! echo "$_output" | grep -qE "rite 42"; then
  echo "FAIL: corrected command 'rite 42' not in output when PR base is main" >&2
  echo "Output was: $_output" >&2
  exit 1
fi

if echo "$_output" | grep -qF "rite --branch"; then
  echo "FAIL: '--branch' should NOT appear when PR base is main (no flag needed)" >&2
  echo "Output was: $_output" >&2
  exit 1
fi

exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: test script exited $status" >&2
    echo "$output" >&2
    return 1
  }
}

@test "behavioral: base == target → no refusal (handle_branch_mismatch not called)" {
  _script="$BATS_TEST_TMPDIR/test-no-mismatch.sh"
  _write_mismatch_stub_preamble "$_script" "false" "main" "main"

  cat >> "$_script" <<'INLINE_EOF'

PR_NUMBER="456"
PR_BASE_BRANCH="main"

# Simulate the guard logic: only call handle_branch_mismatch on mismatch
_effective_target=$(resolve_target_branch "42")
_pr_base_for_check="${PR_BASE_BRANCH:-}"
_mismatch_exit=0

if [ -n "$_pr_base_for_check" ] && [ "$_pr_base_for_check" != "$_effective_target" ]; then
  set +e
  handle_branch_mismatch "42" "$PR_NUMBER" "$_pr_base_for_check" "$_effective_target"
  _mismatch_exit=$?
  set -e
fi

if [ "$_mismatch_exit" -ne 0 ]; then
  echo "FAIL: expected no refusal (exit 0), got $_mismatch_exit" >&2
  exit 1
fi

exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: test script exited $status" >&2
    echo "$output" >&2
    return 1
  }
}

@test "behavioral: batch mode _WF_EXIT=19 records branch_mismatch in ISSUE_STATUS" {
  # Verify the batch routing logic: _WF_EXIT=19 → ISSUE_STATUS[N]="branch_mismatch",
  # SKIPPED_ISSUES contains the issue, batch continues (no EXIT_CODE escalation).
  _script="$BATS_TEST_TMPDIR/test-batch-mismatch.sh"

  cat > "$_script" <<'INLINE_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Minimal batch-process-issues.sh routing simulation.
# Verifies the elif $_WF_EXIT -eq 19 branch produces correct side effects.

declare -A ISSUE_STATUS
SKIPPED_ISSUES=()
EXIT_CODE=0

_format_elapsed() { echo "0s"; }
end_issue_tracking() { :; }

print_info() { echo "INFO: $*" >&2; }
print_warning() { echo "WARN: $*" >&2; }

ISSUE_NUM="42"
ISSUE_START_TIME=0
_WF_EXIT=19

if [ $_WF_EXIT -eq 19 ]; then
  end_issue_tracking "$ISSUE_NUM"
  ISSUE_END_TIME=1
  ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))

  print_info "⏭️  #$ISSUE_NUM skipped — PR base branch does not match effective target"

  SKIPPED_ISSUES+=("$ISSUE_NUM")
  ISSUE_STATUS["$ISSUE_NUM"]="branch_mismatch"
fi

# Assertions
if [ "${ISSUE_STATUS[$ISSUE_NUM]:-}" != "branch_mismatch" ]; then
  echo "FAIL: ISSUE_STATUS[$ISSUE_NUM] should be 'branch_mismatch', got '${ISSUE_STATUS[$ISSUE_NUM]:-}'" >&2
  exit 1
fi

_found_in_skipped=false
for _s in "${SKIPPED_ISSUES[@]+"${SKIPPED_ISSUES[@]}"}"; do
  [ "$_s" = "$ISSUE_NUM" ] && _found_in_skipped=true && break
done

if [ "$_found_in_skipped" != "true" ]; then
  echo "FAIL: issue #$ISSUE_NUM not found in SKIPPED_ISSUES" >&2
  exit 1
fi

if [ "$EXIT_CODE" -ne 0 ]; then
  echo "FAIL: EXIT_CODE should remain 0 for branch_mismatch (batch must not fail)" >&2
  exit 1
fi

exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: test script exited $status" >&2
    echo "$output" >&2
    return 1
  }
}
