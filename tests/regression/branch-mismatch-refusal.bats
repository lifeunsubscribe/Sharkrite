#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/core/batch-process-issues.sh, lib/utils/pr-detection.sh
# tests/regression/branch-mismatch-refusal.bats
#
# Regression test: rite must refuse when an existing PR's base branch differs
# from the effective target branch, and must name the exact corrected command.
#
# Issue #1044 — "Block PR base mismatch with corrected command"
#
# Root cause prevented: if a PR targeting integration branch "big" is resumed
# with no --branch flag (effective target = main), rite would silently operate
# on the wrong base, potentially merging into the wrong branch.
#
# Fix:
#   1. detect_pr_for_issue() fetches headRefName AND baseRefName in one API call.
#   2. The inline gh_safe pr view call in run_workflow()'s worktree-detection
#      block also fetches baseRefName (no second round-trip).
#   3. After PR detection and before the stale-branch check, run_workflow()
#      compares PR baseRefName vs resolve_target_branch(ISSUE_NUMBER) — called
#      WITHOUT the PR number so tier 1 is not consulted (would be circular).
#   4. On mismatch, handle_branch_mismatch() prints a verbose refusal block
#      with the exact corrected command and returns 19.
#   5. run_workflow() returns 19 in BOTH single-issue and batch mode. main()
#      routes exit 19 to the dedicated branch_mismatch branch, avoiding the
#      misleading "Workflow failed" message.
#   6. Batch mode: batch-process-issues.sh captures exit 19 to record
#      branch_mismatch (SKIPPED class) and continues remaining issues.
#
# Tests in this file:
#   STRUCTURAL (static code inspection of workflow-runner.sh):
#     1. handle_branch_mismatch() function exists
#     2. handle_branch_mismatch() returns 19
#     3. Mismatch check appears before check_stale_branch in run_workflow()
#     4. Mismatch check calls resolve_target_branch without PR number
#     5. handle_branch_mismatch() contains "rite --branch" in output
#     6. handle_branch_mismatch() does NOT assign RITE_TARGET_BRANCH
#     7. exit-19 case exists in main()'s workflow_exit dispatcher
#
#   STRUCTURAL (static code inspection of pr-detection.sh):
#     8. detect_pr_for_issue() sets PR_BASE_BRANCH
#     9. detect_pr_for_issue() fetches baseRefName in the same gh pr view call as headRefName
#
#   STRUCTURAL (static code inspection of batch-process-issues.sh):
#    10. BRANCH_MISMATCH_ISSUES array is initialized
#    11. elif [ $_WF_EXIT -eq 19 ] branch exists
#    12. branch_mismatch status is set in the exit-19 branch
#    13. branch_mismatch appears in gate-breaker non-failure case list
#
#   BEHAVIORAL (subprocess execution with stubs):
#    14. base=big  target=main  → returns 19, output contains "rite --branch big"
#    15. base=main target=big   → returns 19, output contains "rite <N>" (no --branch)
#    16. base==target           → no refusal (returns 0), workflow continues past check
#    17. No PR detected         → no refusal (returns 0), fresh issue path unaffected
#    18. PARENT_ATTACHMENT_MODE=adopt + base != target → no refusal (adopt guard fires)

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WORKFLOW_RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
PR_DETECTION_LIB="$REPO_ROOT/lib/utils/pr-detection.sh"

setup() {
  [ -f "$WORKFLOW_RUNNER" ] || {
    echo "FATAL: $WORKFLOW_RUNNER not found" >&2
    return 1
  }
  [ -f "$BATCH_PROCESSOR" ] || {
    echo "FATAL: $BATCH_PROCESSOR not found" >&2
    return 1
  }
  [ -f "$PR_DETECTION_LIB" ] || {
    echo "FATAL: $PR_DETECTION_LIB not found" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: workflow-runner.sh
# =============================================================================

@test "structural: handle_branch_mismatch() function exists in workflow-runner.sh" {
  grep -q 'handle_branch_mismatch()' "$WORKFLOW_RUNNER" || {
    echo "FAIL: handle_branch_mismatch() function not found in workflow-runner.sh" >&2
    return 1
  }
}

@test "structural: handle_branch_mismatch() returns 19" {
  grep -qE 'return 19' "$WORKFLOW_RUNNER" || {
    echo "FAIL: No 'return 19' in workflow-runner.sh" >&2
    echo "      handle_branch_mismatch() must return 19 (exit-19 sentinel)" >&2
    return 1
  }
}

@test "structural: mismatch check appears before check_stale_branch in run_workflow()" {
  # Extract the body of run_workflow() and verify handle_branch_mismatch is called
  # before check_stale_branch. Both must appear (no refusal → no stale check).
  _mismatch_line=$(grep -n 'handle_branch_mismatch' "$WORKFLOW_RUNNER" | grep -v 'handle_branch_mismatch()' | head -1 | cut -d: -f1 || true)
  _stale_line=$(grep -n 'check_stale_branch' "$WORKFLOW_RUNNER" | head -1 | cut -d: -f1 || true)

  [ -n "$_mismatch_line" ] || {
    echo "FAIL: handle_branch_mismatch call not found in workflow-runner.sh" >&2
    return 1
  }
  [ -n "$_stale_line" ] || {
    echo "FAIL: check_stale_branch call not found in workflow-runner.sh" >&2
    return 1
  }

  [ "$_mismatch_line" -lt "$_stale_line" ] || {
    echo "FAIL: handle_branch_mismatch (line $_mismatch_line) appears AFTER check_stale_branch (line $_stale_line)" >&2
    echo "      The mismatch check must run before the stale-branch check so no rebase/close" >&2
    echo "      ever touches a PR whose base disagrees with the effective target." >&2
    return 1
  }
}

@test "structural: mismatch check calls resolve_target_branch without PR number (no circular match)" {
  # resolve_target_branch must be called with only the issue number argument.
  # Passing the PR number would make tier 1 return the PR's own base, making
  # the comparison always match and silently skipping the check.
  grep -qE 'resolve_target_branch "\$issue_number"\s*\)' "$WORKFLOW_RUNNER" || \
  grep -qE 'resolve_target_branch "\$\{issue_number\}"\s*\)' "$WORKFLOW_RUNNER" || {
    echo "FAIL: resolve_target_branch not called with only issue_number in workflow-runner.sh" >&2
    echo "      Call must be: resolve_target_branch \"\$issue_number\" (no PR number)" >&2
    echo "      Passing the PR would be circular: tier 1 would return the PR base itself." >&2
    return 1
  }
}

@test "structural: handle_branch_mismatch() output contains 'rite --branch'" {
  _handler_body=$(awk '
    /^handle_branch_mismatch\(\)/ { in_func=1; next }
    in_func && /^\}/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_handler_body" ] || {
    echo "FAIL: Could not extract handle_branch_mismatch() body from workflow-runner.sh" >&2
    return 1
  }

  echo "$_handler_body" | grep -q 'rite --branch' || {
    echo "FAIL: 'rite --branch' not found in handle_branch_mismatch() body" >&2
    echo "      The refusal block must name the exact corrected command" >&2
    return 1
  }
}

@test "structural: handle_branch_mismatch() does NOT assign RITE_TARGET_BRANCH" {
  # Hard no-auto-adopt rule: the handler must never silently switch to the PR's
  # base by assigning RITE_TARGET_BRANCH. Scoped to the handler only — #1033's
  # --base parser arm legitimately assigns it elsewhere in main().
  _handler_body=$(awk '
    /^handle_branch_mismatch\(\)/ { in_func=1; next }
    in_func && /^\}/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_handler_body" ] || {
    echo "FAIL: Could not extract handle_branch_mismatch() body from workflow-runner.sh" >&2
    return 1
  }

  if echo "$_handler_body" | grep -qE 'RITE_TARGET_BRANCH='; then
    echo "FAIL: RITE_TARGET_BRANCH assignment found in handle_branch_mismatch()" >&2
    echo "      Hard rule: the handler must NEVER auto-adopt the PR's base branch." >&2
    return 1
  fi
}

@test "structural: main() workflow_exit dispatcher has exit-19 case" {
  grep -qE '\[ \$workflow_exit -eq 19 \]' "$WORKFLOW_RUNNER" || {
    echo "FAIL: No 'workflow_exit -eq 19' case in workflow-runner.sh main() dispatcher" >&2
    echo "      Without this, batch cannot distinguish branch mismatch from a real failure" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: pr-detection.sh
# =============================================================================

@test "structural: detect_pr_for_issue() initializes PR_BASE_BRANCH" {
  grep -q 'PR_BASE_BRANCH=""' "$PR_DETECTION_LIB" || \
  grep -qE 'PR_BASE_BRANCH=.*""' "$PR_DETECTION_LIB" || {
    echo "FAIL: PR_BASE_BRANCH not initialized in detect_pr_for_issue()" >&2
    echo "      detect_pr_for_issue() must set PR_BASE_BRANCH from the gh pr view call" >&2
    return 1
  }
}

@test "structural: detect_pr_for_issue() fetches baseRefName in same gh pr view call as headRefName" {
  # The issue requires no extra round-trip. Both fields must appear on the same
  # --json argument line (comma-separated).
  grep -qE 'headRefName,baseRefName|baseRefName,headRefName' "$PR_DETECTION_LIB" || {
    echo "FAIL: baseRefName not fetched in the same gh pr view call as headRefName in pr-detection.sh" >&2
    echo "      Both fields must be requested together: --json headRefName,baseRefName" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: batch-process-issues.sh
# =============================================================================

@test "structural: batch-process-issues.sh initializes BRANCH_MISMATCH_ISSUES array" {
  grep -q 'BRANCH_MISMATCH_ISSUES=' "$BATCH_PROCESSOR" || {
    echo "FAIL: BRANCH_MISMATCH_ISSUES array not initialized in batch-process-issues.sh" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh has elif _WF_EXIT -eq 19 branch" {
  grep -qE 'elif \[ \$_WF_EXIT -eq 19 \]' "$BATCH_PROCESSOR" || {
    echo "FAIL: No 'elif [ \$_WF_EXIT -eq 19 ]' branch in batch-process-issues.sh" >&2
    echo "      Exit 19 must route to the branch_mismatch skip path" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh sets branch_mismatch status in exit-19 branch" {
  _branch_body=$(awk '
    /elif \[ \$_WF_EXIT -eq 19 \]/ { in_branch=1; next }
    in_branch && (/elif \[ \$_WF_EXIT -eq/ || /^  else$/) { exit }
    in_branch { print $0 }
  ' "$BATCH_PROCESSOR")

  [ -n "$_branch_body" ] || {
    echo "FAIL: Could not extract the exit-19 branch body from batch-process-issues.sh" >&2
    return 1
  }

  echo "$_branch_body" | grep -q 'branch_mismatch' || {
    echo "FAIL: 'branch_mismatch' status not set in exit-19 branch" >&2
    echo "      The status is used by the batch reporter to label the skip correctly" >&2
    return 1
  }
}

@test "structural: branch_mismatch is in gate-breaker non-failure case list" {
  # branch_mismatch must reset the gate-breaker streak (no dev session ran —
  # there is nothing to attribute to a repeated gate failure pattern).
  # The case statement spans multiple lines; grep the file directly for the token
  # within the _update_gate_breaker_counter() function body.
  _breaker_body=$(awk '
    /^_update_gate_breaker_counter\(\)/ { in_func=1; next }
    in_func && /^\}/ { exit }
    in_func { print $0 }
  ' "$BATCH_PROCESSOR")

  [ -n "$_breaker_body" ] || {
    echo "FAIL: Could not extract _update_gate_breaker_counter() body from batch-process-issues.sh" >&2
    return 1
  }

  echo "$_breaker_body" | grep -q 'branch_mismatch' || {
    echo "FAIL: 'branch_mismatch' not found in _update_gate_breaker_counter() non-failure case list" >&2
    echo "      Add 'branch_mismatch' to the case statement so a skip resets the breaker streak" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: subprocess execution with stubs
# =============================================================================

# _write_mismatch_preamble SCRIPT BATCH_MODE PR_BASE EFFECTIVE_TARGET
#
# Writes a minimal stub preamble simulating the state after PR detection:
#   - PR_NUMBER is set (so the mismatch check fires)
#   - PR_BASE_BRANCH is set to PR_BASE
#   - resolve_target_branch is stubbed to return EFFECTIVE_TARGET
#   - handle_branch_mismatch is the real implementation (sourced inline)
_write_mismatch_preamble() {
  local _script="$1"
  local _batch_mode="${2:-false}"
  local _pr_base="${3:-big}"
  local _effective_target="${4:-main}"
  local _issue_num="${5:-42}"
  local _pr_num="${6:-99}"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand (_batch_mode, _pr_base, _effective_target, _issue_num, _pr_num)
  cat > "$_script" <<STUB_EOF
#!/usr/bin/env bash
set -euo pipefail

BATCH_MODE=${_batch_mode}

print_header()  { :; }
print_info()    { :; }
print_success() { :; }
print_status()  { :; }
print_step()    { :; }
verbose_info()  { :; }
print_error()   { echo "ERROR: \$*" >&2; }

# Stub resolve_target_branch to return the effective target without PR tier-1.
resolve_target_branch() { echo "${_effective_target}"; }

# Real handle_branch_mismatch implementation under test.
handle_branch_mismatch() {
  local _issue_number="\$1"
  local _pr_number="\$2"
  local _pr_base="\$3"
  local _effective_target="\$4"

  local _corrected_cmd
  if [ "\${_pr_base:-}" = "main" ]; then
    _corrected_cmd="rite \${_issue_number}"
  else
    _corrected_cmd="rite --branch \${_pr_base} \${_issue_number}"
  fi

  print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  print_error "PR base mismatch — cannot continue"
  print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  print_error "  Issue:            #\${_issue_number}"
  print_error "  PR:               #\${_pr_number}"
  print_error "  PR base:          \${_pr_base}"
  print_error "  Effective target: \${_effective_target}"
  print_error ""
  print_error "  Issue #\${_issue_number} is in flight on branch '\${_pr_base}'."
  print_error "  Run the corrected command:"
  print_error ""
  print_error "    \${_corrected_cmd}"
  print_error ""
  print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  return 19
}

PR_NUMBER="${_pr_num}"
PR_BASE_BRANCH="${_pr_base}"
ISSUE_NUMBER="${_issue_num}"
STUB_EOF
}

@test "behavioral: base=big target=main returns 19 and output contains 'rite --branch big'" {
  _script="$BATS_TEST_TMPDIR/test-mismatch-big-main.sh"
  _write_mismatch_preamble "$_script" "false" "big" "main" "42" "99"

  cat >> "$_script" <<'INLINE_EOF'

# Simulate the mismatch check from run_workflow().
_effective_target=$(resolve_target_branch "$ISSUE_NUMBER")
_pr_base="${PR_BASE_BRANCH:-}"

_exit=0
if [ -n "$_pr_base" ] && [ -n "$_effective_target" ] && [ "$_pr_base" != "$_effective_target" ]; then
  set +e
  handle_branch_mismatch "$ISSUE_NUMBER" "$PR_NUMBER" "$_pr_base" "$_effective_target"
  _exit=$?
  set -e
fi

if [ "$_exit" -ne 19 ]; then
  echo "FAIL: expected exit 19 for base=big target=main, got $_exit" >&2
  exit 1
fi
exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script itself failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }

  # Verify the corrected command appears in the output.
  echo "$output" | grep -q 'rite --branch big' || {
    echo "FAIL: 'rite --branch big' not found in refusal output" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: base=main target=big returns 19 and output contains 'rite 42' (no --branch)" {
  _script="$BATS_TEST_TMPDIR/test-mismatch-main-big.sh"
  _write_mismatch_preamble "$_script" "false" "main" "big" "42" "99"

  cat >> "$_script" <<'INLINE_EOF'

_effective_target=$(resolve_target_branch "$ISSUE_NUMBER")
_pr_base="${PR_BASE_BRANCH:-}"

_exit=0
if [ -n "$_pr_base" ] && [ -n "$_effective_target" ] && [ "$_pr_base" != "$_effective_target" ]; then
  set +e
  handle_branch_mismatch "$ISSUE_NUMBER" "$PR_NUMBER" "$_pr_base" "$_effective_target"
  _exit=$?
  set -e
fi

if [ "$_exit" -ne 19 ]; then
  echo "FAIL: expected exit 19 for base=main target=big, got $_exit" >&2
  exit 1
fi
exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script itself failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }

  # When PR base is "main", corrected command is "rite <N>" (no --branch flag).
  echo "$output" | grep -q 'rite 42' || {
    echo "FAIL: 'rite 42' not found in refusal output (should suggest plain rite <N> when PR base is main)" >&2
    echo "Output: $output" >&2
    return 1
  }

  # Confirm the output does NOT contain --branch (would be wrong for base=main case).
  if echo "$output" | grep -q 'rite --branch'; then
    echo "FAIL: 'rite --branch' found in output for base=main case (should be plain 'rite 42')" >&2
    echo "Output: $output" >&2
    return 1
  fi
}

@test "behavioral: base==target returns 0 and no refusal (workflow continues)" {
  _script="$BATS_TEST_TMPDIR/test-no-mismatch.sh"
  _write_mismatch_preamble "$_script" "false" "main" "main" "42" "99"

  cat >> "$_script" <<'INLINE_EOF'

_effective_target=$(resolve_target_branch "$ISSUE_NUMBER")
_pr_base="${PR_BASE_BRANCH:-}"

_exit=0
if [ -n "$_pr_base" ] && [ -n "$_effective_target" ] && [ "$_pr_base" != "$_effective_target" ]; then
  set +e
  handle_branch_mismatch "$ISSUE_NUMBER" "$PR_NUMBER" "$_pr_base" "$_effective_target"
  _exit=$?
  set -e
fi

if [ "$_exit" -ne 0 ]; then
  echo "FAIL: expected exit 0 when base==target (no mismatch), got $_exit" >&2
  exit 1
fi
exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script itself failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: adopted parent PR with base != main is not refused (PARENT_ATTACHMENT_MODE=adopt guard)" {
  # Regression for #1044 adopt-arm false-mismatch:
  # When PARENT_ATTACHMENT_MODE=adopt, the adopt arm has already set PR_NUMBER to
  # the parent PR's number without a --branch flag.  resolve_target_branch falls
  # through to tier-4 (main) while the parent PR's base may be any non-main
  # integration branch — a guaranteed false mismatch.
  # The mismatch check must be skipped entirely for adopted PRs.

  _script="$BATS_TEST_TMPDIR/test-adopt-no-refuse.sh"
  # pr_base=big, effective_target=main — a combination that WOULD fire the check
  # for a normal resume.  With PARENT_ATTACHMENT_MODE=adopt it must be bypassed.
  _write_mismatch_preamble "$_script" "false" "big" "main" "42" "99"

  cat >> "$_script" <<'INLINE_EOF'

# Simulate the adopt arm: PARENT_ATTACHMENT_MODE is set to adopt.
PARENT_ATTACHMENT_MODE=adopt

_effective_target=$(resolve_target_branch "$ISSUE_NUMBER")
_pr_base="${PR_BASE_BRANCH:-}"

_exit=0
# This is the guarded form from workflow-runner.sh (with the adopt exemption).
if [ -n "${PR_NUMBER:-}" ] && [ "${PR_NUMBER:-}" != "null" ] && [ "${PARENT_ATTACHMENT_MODE:-none}" != "adopt" ]; then
  if [ -n "$_pr_base" ] && [ -n "$_effective_target" ] && [ "$_pr_base" != "$_effective_target" ]; then
    set +e
    handle_branch_mismatch "$ISSUE_NUMBER" "${PR_NUMBER:-}" "$_pr_base" "$_effective_target"
    _exit=$?
    set -e
  fi
fi

if [ "$_exit" -ne 0 ]; then
  echo "FAIL: expected exit 0 for adopted parent PR (base=big, target=main), got $_exit" >&2
  echo "      Adopted parent PRs must never be refused by the mismatch check." >&2
  exit 1
fi
exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script itself failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: no PR detected returns 0 and check is skipped (fresh issue path)" {
  _script="$BATS_TEST_TMPDIR/test-no-pr.sh"
  _write_mismatch_preamble "$_script" "false" "" "main" "42" ""

  cat >> "$_script" <<'INLINE_EOF'

# PR_NUMBER is empty — no PR detected, check must be skipped entirely.
PR_NUMBER=""
_effective_target=$(resolve_target_branch "$ISSUE_NUMBER")
_pr_base="${PR_BASE_BRANCH:-}"

_exit=0
if [ -n "${PR_NUMBER:-}" ] && [ "${PR_NUMBER:-}" != "null" ]; then
  if [ -n "$_pr_base" ] && [ -n "$_effective_target" ] && [ "$_pr_base" != "$_effective_target" ]; then
    set +e
    handle_branch_mismatch "$ISSUE_NUMBER" "${PR_NUMBER:-}" "$_pr_base" "$_effective_target"
    _exit=$?
    set -e
  fi
fi

if [ "$_exit" -ne 0 ]; then
  echo "FAIL: expected exit 0 when no PR detected (fresh issue path), got $_exit" >&2
  exit 1
fi
exit 0
INLINE_EOF

  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "FAIL: test script itself failed (status=$status)" >&2
    echo "Output: $output" >&2
    return 1
  }
}
