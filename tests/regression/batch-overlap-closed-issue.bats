#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh::_apply_overlap_defer_or_warn
# Regression tests: closed-issue bypass for three pre-run guards (#1461, #1474)
#
# Guard 1 — parent-PR guard (#1474):
#   Bug: The parent-PR guard's waiting_for_parent path fired for CLOSED issues,
#   bypassing handle_closed_issue() entirely — reproducing the #274 orphan-worktree
#   class. A CLOSED follow-up issue got ISSUE_STATUS="waiting_for_parent" and was
#   re-deferred forever instead of being cleaned up.
#   Fix: Wrap the ISSUE_BODY fetch + parent-PR guard in
#   `if [ "$ISSUE_STATE" != "CLOSED" ]; then`.
#
# Guard 2 — dependency guard (#1474):
#   Bug: The dep guard fired gh issue view per-dep per-pass for CLOSED issues,
#   burning network calls and potentially marking issues as dep_failed (bypassing
#   handle_closed_issue()).
#   Fix: Same gate as above covers the dep guard too (single if-block wraps both).
#
# Guard 3 — cross-batch overlap guard (#1461):
#   Bug: The overlap guard ran before closed-issue handling, so a CLOSED issue
#   was deferred (re-appended to ISSUE_LIST) instead of proceeding to cleanup.
#   Each pass burned one defer-cap slot and made one extra gh API call.
#   Fix: Wrap the overlap guard in `if [ "$ISSUE_STATE" != "CLOSED" ]`.
#
# Tests:
#   STRUCTURAL (guard 1 — parent-PR):
#    1. CLOSED-state gate exists before the parent-PR grep check
#    2. CLOSED-state gate exists before _extract_dep_issues_from_body
#   STRUCTURAL (guard 3 — overlap):
#    3. Closed-issue guard exists before the _ftm_file_overlap call
#    4. Guard comment references the parity contract ("do NOT short-circuit")
#   BEHAVIORAL (guard 3 — overlap):
#    5. CLOSED issue with pre-populated _OVERLAP_FILES → proceeds (no defer)
#    6. OPEN issue with pre-populated _OVERLAP_FILES → deferred (guard fires)
#    7. CLOSED: ISSUE_LIST length is unchanged after the guard (no re-append)

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"

setup() {
  [ -f "$BATCH_PROCESSOR" ] || {
    echo "FATAL: $BATCH_PROCESSOR not found" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL — parent-PR + dep guards (#1474)
# =============================================================================

@test "structural: CLOSED-state gate exists before parent-PR grep check" {
  # The 'if [ "$ISSUE_STATE" != "CLOSED" ]; then' gate that wraps the ISSUE_BODY
  # fetch must appear before the parent-PR grep (RITE_MARKER_PARENT_PR) in the
  # source, so CLOSED follow-up issues bypass the waiting_for_parent path and
  # reach run_workflow() → handle_closed_issue() instead.
  local _guard_line _parent_pr_line
  _guard_line=$(grep -n 'if \[ "\$ISSUE_STATE" != "CLOSED" \]' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)
  _parent_pr_line=$(grep -n 'RITE_MARKER_PARENT_PR.*\[0-9\]' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)

  [ -n "$_guard_line" ] || {
    echo "FAIL: no 'ISSUE_STATE != CLOSED' guard found in $BATCH_PROCESSOR" >&2
    return 1
  }
  [ -n "$_parent_pr_line" ] || {
    echo "FAIL: no RITE_MARKER_PARENT_PR grep line found in $BATCH_PROCESSOR" >&2
    return 1
  }
  [ "$_guard_line" -lt "$_parent_pr_line" ] || {
    echo "FAIL: guard (line $_guard_line) must come BEFORE parent-PR grep (line $_parent_pr_line)" >&2
    return 1
  }
}

@test "structural: CLOSED-state gate exists before dep guard call site" {
  # The same gate wraps the dep guard, so CLOSED issues bypass the dep_failed /
  # deferred_for_dep paths that would otherwise bypass handle_closed_issue().
  # We grep for the call site (DEP_ISSUES=..._extract_dep_issues_from_body), not
  # the function definition, so the line number comparison is meaningful.
  local _guard_line _dep_guard_line
  _guard_line=$(grep -n 'if \[ "\$ISSUE_STATE" != "CLOSED" \]' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)
  _dep_guard_line=$(grep -n 'DEP_ISSUES=.*_extract_dep_issues_from_body' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)

  [ -n "$_guard_line" ] || {
    echo "FAIL: no 'ISSUE_STATE != CLOSED' guard found in $BATCH_PROCESSOR" >&2
    return 1
  }
  [ -n "$_dep_guard_line" ] || {
    echo "FAIL: no DEP_ISSUES=_extract_dep_issues_from_body call found in $BATCH_PROCESSOR" >&2
    return 1
  }
  [ "$_guard_line" -lt "$_dep_guard_line" ] || {
    echo "FAIL: guard (line $_guard_line) must come BEFORE dep guard call site (line $_dep_guard_line)" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL — overlap guard (#1461)
# =============================================================================

@test "structural: CLOSED-state guard exists before _ftm_file_overlap call" {
  # The guard must appear BEFORE the _ftm_file_overlap call in the source file.
  local _guard_line _overlap_line
  _guard_line=$(grep -n 'ISSUE_STATE.*!=.*CLOSED' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)
  _overlap_line=$(grep -n '_ftm_file_overlap "\$ISSUE_BODY"' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)

  [ -n "$_guard_line" ] || {
    echo "FAIL: no 'ISSUE_STATE != CLOSED' guard found in $BATCH_PROCESSOR" >&2
    return 1
  }
  [ -n "$_overlap_line" ] || {
    echo "FAIL: no '_ftm_file_overlap \"\$ISSUE_BODY\"' call found in $BATCH_PROCESSOR" >&2
    return 1
  }
  [ "$_guard_line" -lt "$_overlap_line" ] || {
    echo "FAIL: guard (line $_guard_line) must come BEFORE _ftm_file_overlap (line $_overlap_line)" >&2
    return 1
  }
}

@test "structural: guard comment references the parity contract" {
  # The closing comment block must explain WHY closed issues are skipped and
  # tie back to the parity contract. Use unique text from the new guard block
  # (lines around the 'if [ "$ISSUE_STATE" != "CLOSED" ]' site) so this test
  # does not pass by matching the pre-existing comment at ~line 1239.
  grep -qE "Skipped for CLOSED issues|Deferring a closed issue only" "$BATCH_PROCESSOR" || {
    echo "FAIL: guard block must reference parity contract (unique text not found)" >&2
    return 1
  }
}

# =============================================================================
# Helpers for behavioral tests
# =============================================================================

# _build_guard_script ISSUE_STATE
#
# Builds a self-contained bash script that:
#  1. Extracts _apply_overlap_defer_or_warn from the production source
#     (not duplicated logic).
#  2. Pre-populates _OVERLAP_FILES to simulate an overlap being found.
#  3. Runs the ISSUE_STATE guard exactly as the batch loop does.
#  4. Prints OVERLAP_DEFERRED or PROCEEDED with metadata for assertions.
#
# Prints the path of the generated script.
_build_guard_script() {
  local _state="$1"
  local _script="$BATS_TEST_TMPDIR/guard-test-$$.sh"

  local _fn2_tmp="$BATS_TEST_TMPDIR/fn2-$$.sh"
  awk '
    /^_apply_overlap_defer_or_warn[(][)]/ { in_fn=1 }
    in_fn { print }
    in_fn && /^}$/ { exit }
  ' "$BATCH_PROCESSOR" > "$_fn2_tmp" 2>/dev/null

  grep -q "_apply_overlap_defer_or_warn" "$_fn2_tmp" 2>/dev/null || {
    echo "ERROR: could not extract _apply_overlap_defer_or_warn from $BATCH_PROCESSOR" >&2
    return 1
  }

  local _fn2_body
  _fn2_body=$(cat "$_fn2_tmp" || true)

  # Use printf to avoid heredoc @test-line bats rewriting
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '' \
    'print_warning() { printf "WARNING: %s\n" "$*" >&2; }' \
    '_diag() { true; }' \
    '' \
    "${_fn2_body}" \
    '' \
    'declare -A ISSUE_STATUS' \
    'declare -A _DEFER_COUNT' \
    '_UNIQUE_ISSUE_COUNT=3' \
    '_DEFER_COUNT[42]=0' \
    'ISSUE_LIST=(42)' \
    'ISSUE_NUM=42' \
    "ISSUE_STATE=\"${_state}\"" \
    '' \
    '# Pre-populate overlap — simulates what _ftm_file_overlap would find.' \
    '# We are testing the ISSUE_STATE guard, not overlap detection (that is' \
    '# tested in batch-cross-batch-overlap.bats).' \
    '_OVERLAP_FILES="lib/utils/docs-map.sh"' \
    '_OVERLAP_WT="/worktrees/other-issue_b1000-1001"' \
    '' \
    '_list_len_before="${#ISSUE_LIST[@]}"' \
    '' \
    'if [ "$ISSUE_STATE" != "CLOSED" ]; then' \
    '  _overlap_action_rc=0; _apply_overlap_defer_or_warn || _overlap_action_rc=$?' \
    '  if [ "$_overlap_action_rc" -ne 0 ]; then' \
    '    echo "OVERLAP_DEFERRED: issue $ISSUE_NUM defer=${_DEFER_COUNT[$ISSUE_NUM]} files=${_OVERLAP_FILES}"' \
    '    echo "STATUS:${ISSUE_STATUS[$ISSUE_NUM]:-UNSET}"' \
    '    echo "ISSUE_LIST_LEN_BEFORE:${_list_len_before}"' \
    '    echo "ISSUE_LIST_LEN_AFTER:${#ISSUE_LIST[@]}"' \
    '    exit 0' \
    '  fi' \
    'fi' \
    'echo "PROCEEDED: issue $ISSUE_NUM state=$ISSUE_STATE"' \
    'echo "STATUS:proceeded"' \
    'echo "ISSUE_LIST_LEN:${#ISSUE_LIST[@]}"' \
    > "$_script"

  chmod +x "$_script"
  echo "$_script"
}

# =============================================================================
# BEHAVIORAL — overlap guard (#1461)
# =============================================================================

@test "behavioral: CLOSED issue with overlap pre-populated → proceeds (never deferred)" {
  _script=$(_build_guard_script "CLOSED")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status; output: $output" >&2; return 1
  }
  echo "$output" | grep -q "PROCEEDED: issue 42 state=CLOSED" || {
    echo "FAIL: expected PROCEEDED; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "OVERLAP_DEFERRED" || {
    echo "FAIL: must NOT print OVERLAP_DEFERRED for CLOSED issue; got: $output" >&2; return 1
  }
}

@test "behavioral: CLOSED issue → ISSUE_LIST length unchanged (no re-append)" {
  _script=$(_build_guard_script "CLOSED")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status; output: $output" >&2; return 1
  }
  echo "$output" | grep -q "ISSUE_LIST_LEN:1" || {
    echo "FAIL: ISSUE_LIST must have length 1 (no re-append); got: $output" >&2; return 1
  }
}

@test "behavioral: OPEN issue with overlap pre-populated → deferred (guard fires)" {
  _script=$(_build_guard_script "OPEN")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status; output: $output" >&2; return 1
  }
  echo "$output" | grep -q "OVERLAP_DEFERRED: issue 42" || {
    echo "FAIL: expected OVERLAP_DEFERRED for OPEN issue; got: $output" >&2; return 1
  }
  echo "$output" | grep -q "STATUS:deferred_for_overlap" || {
    echo "FAIL: expected STATUS:deferred_for_overlap; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "PROCEEDED" || {
    echo "FAIL: must NOT print PROCEEDED when overlap defers an OPEN issue; got: $output" >&2; return 1
  }
}
