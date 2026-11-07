#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh
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
#    3. drift: waiting_for_parent assignment is inside the CLOSED-state gate
#    4. drift: dep_failed assignment is inside the CLOSED-state gate
#   STRUCTURAL (guard 3 — overlap):
#    5. Closed-issue guard exists before the _ftm_file_overlap call
#    6. Guard comment references the parity contract ("do NOT short-circuit")
#   BEHAVIORAL (guard 3 — overlap):
#    7. CLOSED issue with pre-populated _OVERLAP_FILES → proceeds (no defer)
#    8. OPEN issue with pre-populated _OVERLAP_FILES → deferred (guard fires)
#    9. CLOSED: ISSUE_LIST length is unchanged after the guard (no re-append)
#   BEHAVIORAL (guards 1+2 — parent-PR + dep, replica-based):
#   10. CLOSED issue with parent-PR marker → proceeds (waiting_for_parent never set)
#   11. OPEN issue with parent-PR marker → skipped (waiting_for_parent set)
#   12. CLOSED issue with failed dep → proceeds (dep_failed never set)
#   13. OPEN issue with failed dep → skipped (dep_failed set)
#   Note: tests 10-13 exercise a self-contained replica of the gate logic. Tests
#   3-4 (drift) are the production-side backstop: they verify the key status
#   assignments remain inside the CLOSED-state gate in the real source file.

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

@test "drift: waiting_for_parent assignment is inside the CLOSED-state gate in production" {
  # Prevents silent divergence between the replica in _build_parent_pr_guard_script
  # and the production gate. The behavioral tests (8-9) test the replica, not
  # production — a control-flow regression (e.g. re-adding a continue for CLOSED
  # inside the gate) would pass those tests unchanged. This drift check is the
  # production-side backstop: the waiting_for_parent status assignment must appear
  # BEFORE the annotated fi that closes the CLOSED-state gate.
  local _gate_close_line _waiting_line
  _gate_close_line=$(grep -n 'fi  # \[ "\$ISSUE_STATE" != "CLOSED" \].*parent-PR + dep guards' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)
  _waiting_line=$(grep -n 'ISSUE_STATUS\["$ISSUE_NUM"\]="waiting_for_parent"' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)

  [ -n "$_gate_close_line" ] || {
    echo "FAIL: annotated closing fi for CLOSED-state gate not found in $BATCH_PROCESSOR" >&2
    return 1
  }
  [ -n "$_waiting_line" ] || {
    echo "FAIL: waiting_for_parent status assignment not found in $BATCH_PROCESSOR" >&2
    return 1
  }
  [ "$_waiting_line" -lt "$_gate_close_line" ] || {
    echo "FAIL: waiting_for_parent assignment (line $_waiting_line) must be INSIDE the CLOSED gate (closes at line $_gate_close_line)" >&2
    return 1
  }
}

@test "drift: dep_failed assignment is inside the CLOSED-state gate in production" {
  # Same backstop for the dep guard. If the dep_failed status assignment is moved
  # outside the CLOSED-state gate (or the gate is removed), this test catches it
  # even though the behavioral tests (10-11) test only the replica.
  local _gate_close_line _dep_failed_line
  _gate_close_line=$(grep -n 'fi  # \[ "\$ISSUE_STATE" != "CLOSED" \].*parent-PR + dep guards' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)
  _dep_failed_line=$(grep -n 'ISSUE_STATUS\["$ISSUE_NUM"\]="dep_failed"' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)

  [ -n "$_gate_close_line" ] || {
    echo "FAIL: annotated closing fi for CLOSED-state gate not found in $BATCH_PROCESSOR" >&2
    return 1
  }
  [ -n "$_dep_failed_line" ] || {
    echo "FAIL: dep_failed status assignment not found in $BATCH_PROCESSOR" >&2
    return 1
  }
  [ "$_dep_failed_line" -lt "$_gate_close_line" ] || {
    echo "FAIL: dep_failed assignment (line $_dep_failed_line) must be INSIDE the CLOSED gate (closes at line $_gate_close_line)" >&2
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

# =============================================================================
# Helpers for parent-PR and dep guard behavioral tests (#1474)
# =============================================================================

# _build_parent_pr_guard_script ISSUE_STATE
#
# Builds a self-contained bash script that simulates the parent-PR guard
# decision point: ISSUE_BODY has a valid parent-PR marker, gh_safe is
# stubbed to return OPEN for the parent PR, and the parent issue is not in
# the queue — the worst-case path that would set waiting_for_parent for an
# OPEN issue without the CLOSED guard.
#
# Prints the path of the generated script.
_build_parent_pr_guard_script() {
  local _state="$1"
  local _script="$BATS_TEST_TMPDIR/parent-pr-guard-$$.sh"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '' \
    'print_info()    { printf "INFO: %s\n" "$*" >&2; }' \
    'print_success() { printf "OK: %s\n"   "$*" >&2; }' \
    '' \
    '# Stub: returns OPEN for any parent PR state check.' \
    'gh_safe() { printf "OPEN\n"; }' \
    '' \
    'declare -A ISSUE_STATUS' \
    'declare -A _DEFER_COUNT' \
    'SKIPPED_ISSUES=()' \
    'ISSUE_NUM=42' \
    "ISSUE_STATE=\"${_state}\"" \
    'RITE_MARKER_PARENT_PR="sharkrite-parent-pr"' \
    'RITE_LOCK_DIR="/tmp/no-such-lock-dir-$$"' \
    '' \
    '# ISSUE_BODY has a real parent-PR marker (triggers guard for OPEN issue).' \
    'ISSUE_BODY="sharkrite-parent-pr:99"' \
    '' \
    'if [ "$ISSUE_STATE" != "CLOSED" ]; then' \
    '  if echo "$ISSUE_BODY" | grep -qE "${RITE_MARKER_PARENT_PR}:[0-9]+"; then' \
    '    PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE "${RITE_MARKER_PARENT_PR}:[0-9]+" | cut -d: -f2 || true)' \
    '    if [ -n "$PARENT_PR" ]; then' \
    '      PARENT_PR_STATE=$(gh_safe pr view "$PARENT_PR")' \
    '      if [ "$PARENT_PR_STATE" = "OPEN" ]; then' \
    '        SKIPPED_ISSUES+=("$ISSUE_NUM")' \
    '        ISSUE_STATUS["$ISSUE_NUM"]="waiting_for_parent"' \
    '        printf "GUARD_FIRED: issue %s status=waiting_for_parent\n" "$ISSUE_NUM"' \
    '        printf "STATUS:%s\n" "${ISSUE_STATUS[$ISSUE_NUM]:-UNSET}"' \
    '        printf "SKIPPED_COUNT:%s\n" "${#SKIPPED_ISSUES[@]}"' \
    '        exit 0' \
    '      fi' \
    '    fi' \
    '  fi' \
    'fi' \
    '' \
    'printf "PROCEEDED: issue %s state=%s\n" "$ISSUE_NUM" "$ISSUE_STATE"' \
    'printf "STATUS:%s\n" "${ISSUE_STATUS[$ISSUE_NUM]:-UNSET}"' \
    'printf "SKIPPED_COUNT:%s\n" "${#SKIPPED_ISSUES[@]}"' \
    > "$_script"

  chmod +x "$_script"
  echo "$_script"
}

# _build_dep_guard_script ISSUE_STATE
#
# Builds a self-contained bash script that simulates the dep guard decision
# point: dep issue 99 is pre-set as "failed" in ISSUE_STATUS, DEP_ISSUES is
# pre-populated (skipping _extract_dep_issues_from_body) — the path that
# would set dep_failed for an OPEN issue without the CLOSED guard.
#
# Prints the path of the generated script.
_build_dep_guard_script() {
  local _state="$1"
  local _script="$BATS_TEST_TMPDIR/dep-guard-$$.sh"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '' \
    'print_warning() { printf "WARNING: %s\n" "$*" >&2; }' \
    '' \
    'declare -A ISSUE_STATUS' \
    'SKIPPED_ISSUES=()' \
    'ISSUE_NUM=42' \
    "ISSUE_STATE=\"${_state}\"" \
    '' \
    '# Pre-conditions: dep issue 99 already failed in this batch.' \
    'ISSUE_STATUS[99]="failed"' \
    'DEP_ISSUES="99"' \
    '' \
    'if [ "$ISSUE_STATE" != "CLOSED" ]; then' \
    '  DEP_FAILED=false' \
    '  FAILED_DEP=""' \
    '  DEP_REASON=""' \
    '  for dep_num in $DEP_ISSUES; do' \
    '    dep_status="${ISSUE_STATUS[$dep_num]:-}"' \
    '    if [ "$dep_status" = "failed" ]; then' \
    '      DEP_FAILED=true' \
    '      FAILED_DEP="$dep_num"' \
    '      DEP_REASON="$dep_status in this batch"' \
    '      break' \
    '    fi' \
    '  done' \
    '  if [ "$DEP_FAILED" = true ]; then' \
    '    SKIPPED_ISSUES+=("$ISSUE_NUM")' \
    '    ISSUE_STATUS["$ISSUE_NUM"]="dep_failed"' \
    '    printf "GUARD_FIRED: issue %s status=dep_failed\n" "$ISSUE_NUM"' \
    '    printf "STATUS:%s\n" "${ISSUE_STATUS[$ISSUE_NUM]:-UNSET}"' \
    '    printf "SKIPPED_COUNT:%s\n" "${#SKIPPED_ISSUES[@]}"' \
    '    exit 0' \
    '  fi' \
    'fi' \
    '' \
    'printf "PROCEEDED: issue %s state=%s\n" "$ISSUE_NUM" "$ISSUE_STATE"' \
    'printf "STATUS:%s\n" "${ISSUE_STATUS[$ISSUE_NUM]:-UNSET}"' \
    'printf "SKIPPED_COUNT:%s\n" "${#SKIPPED_ISSUES[@]}"' \
    > "$_script"

  chmod +x "$_script"
  echo "$_script"
}

# =============================================================================
# BEHAVIORAL — parent-PR guard (#1474)
# =============================================================================

@test "behavioral: CLOSED issue with parent-PR marker → proceeds (waiting_for_parent never set)" {
  _script=$(_build_parent_pr_guard_script "CLOSED")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status; output: $output" >&2; return 1
  }
  echo "$output" | grep -q "PROCEEDED: issue 42 state=CLOSED" || {
    echo "FAIL: expected PROCEEDED; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "GUARD_FIRED" || {
    echo "FAIL: CLOSED issue must NOT fire the parent-PR guard; got: $output" >&2; return 1
  }
  echo "$output" | grep -q "SKIPPED_COUNT:0" || {
    echo "FAIL: SKIPPED_COUNT must be 0 for CLOSED issue; got: $output" >&2; return 1
  }
}

@test "behavioral: OPEN issue with parent-PR marker → skipped (waiting_for_parent set)" {
  _script=$(_build_parent_pr_guard_script "OPEN")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status; output: $output" >&2; return 1
  }
  echo "$output" | grep -q "GUARD_FIRED: issue 42 status=waiting_for_parent" || {
    echo "FAIL: expected GUARD_FIRED for OPEN issue; got: $output" >&2; return 1
  }
  echo "$output" | grep -q "STATUS:waiting_for_parent" || {
    echo "FAIL: expected STATUS:waiting_for_parent for OPEN issue; got: $output" >&2; return 1
  }
  echo "$output" | grep -q "SKIPPED_COUNT:1" || {
    echo "FAIL: SKIPPED_COUNT must be 1 for OPEN issue; got: $output" >&2; return 1
  }
}

# =============================================================================
# BEHAVIORAL — dep guard (#1474)
# =============================================================================

@test "behavioral: CLOSED issue with failed dep → proceeds (dep_failed never set)" {
  _script=$(_build_dep_guard_script "CLOSED")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status; output: $output" >&2; return 1
  }
  echo "$output" | grep -q "PROCEEDED: issue 42 state=CLOSED" || {
    echo "FAIL: expected PROCEEDED; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "GUARD_FIRED" || {
    echo "FAIL: CLOSED issue must NOT fire the dep guard; got: $output" >&2; return 1
  }
  echo "$output" | grep -q "SKIPPED_COUNT:0" || {
    echo "FAIL: SKIPPED_COUNT must be 0 for CLOSED issue; got: $output" >&2; return 1
  }
}

@test "behavioral: OPEN issue with failed dep → skipped (dep_failed set)" {
  _script=$(_build_dep_guard_script "OPEN")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status; output: $output" >&2; return 1
  }
  echo "$output" | grep -q "GUARD_FIRED: issue 42 status=dep_failed" || {
    echo "FAIL: expected GUARD_FIRED for OPEN issue; got: $output" >&2; return 1
  }
  echo "$output" | grep -q "STATUS:dep_failed" || {
    echo "FAIL: expected STATUS:dep_failed for OPEN issue; got: $output" >&2; return 1
  }
  echo "$output" | grep -q "SKIPPED_COUNT:1" || {
    echo "FAIL: SKIPPED_COUNT must be 1 for OPEN issue; got: $output" >&2; return 1
  }
}
