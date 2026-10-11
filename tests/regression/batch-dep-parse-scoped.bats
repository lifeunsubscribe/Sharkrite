#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh
# tests/regression/batch-dep-parse-scoped.bats
#
# Regression test: batch dep parser must scope extraction to the Dependencies:
# field, not the full issue body.
#
# Root bug (2026-06-12, issue #556, batch `rite 554 555 556`):
#   batch-process-issues.sh grepped the ENTIRE issue body for dep patterns.
#   Issue #556's body documented the ordinal-ref bug with the prose example
#   "After #1"; the parser harvested #1, found repo issue #1 open, and skipped
#   #556 with dep_failed — even though its actual Dependencies field said "None".
#   Third instance of the unanchored-marker class (issue #34's
#   sharkrite-parent-pr: placeholder; strict-lint parallel-with annotations
#   fixed in PR #557).
#
# Tests in this file:
#   UNIT (helper function isolation):
#     1. Prose-only body with dep syntax → no deps extracted
#     2. Body with Dependencies: None → no deps extracted
#     3. Body with Dependencies: After #N → N extracted
#     4. Dependencies: Blocked by: #N → N extracted
#     5. Dependencies: Depends on #N → N extracted
#     6. Multiple deps on one line → all extracted
#     7. Multi-line dep field (continuation lines) → all extracted
#     8. Parallel-with annotation stripped → sibling NOT harvested as dep
#     9. Header inline ref: "**Dependencies**: After #5" → 5 extracted
#    10. Section stop: refs after next ** header not collected
#    11. Section stop: refs after ## header not collected
#    12. Section stop: refs after --- divider not collected
#    13. No Dependencies: field at all → empty (no fallback to whole body)
#    14. Bare #N on header line: "**Dependencies**: #42" → 42 extracted
#    15. Bare #N on continuation line: "#42" alone → 42 extracted
#    16. Plain number without # not harvested (format anchor check)
#
#   STRUCTURAL (static code inspection):
#    17. _extract_dep_issues_from_body function defined in batch-process-issues.sh
#    18. Per-issue DEP_ISSUES= line uses _extract_dep_issues_from_body, not grep -oiE
#    19. Preflight _dep_refs= line uses _extract_dep_issues_from_body, not grep -oiE
#    20. Deliberate divergence comment still present (parity contract unchanged)
#    21. Dead _inline variable is not present (SC2034 fix)
#
#   BEHAVIORAL (per-issue guard integration):
#    22. Body with prose "After #1" but Dependencies: None → issue NOT skipped
#    23. Body with Dependencies: After #N where N is failed → issue skipped
#    24. Bare #N dep: "Dependencies: #N" where N is failed → issue skipped
#
#   LEGACY FORM (## Dependencies markdown header — pre-#964 issues):
#    25. "## Dependencies\nAfter: #N" → N extracted (mirrors #967 body shape)
#    26. "### Dependencies\nAfter: #N" → N extracted (any ## level)
#    27. "## Dependencies\nBlocked by: #N" → N extracted
#    28. "## Dependencies" + multiple following lines → all extracted
#    29. "## Dependencies" stops at next ## section header → refs after stop not collected
#    30. Canonical "**Dependencies**: After #N" still works (existing behavior pinned)
#
#   FENCE GUARD (## Dependencies or **Dependencies**: inside code fence → NOT collected):
#    31. "## Dependencies" inside ``` fence → NOT treated as dep section
#    32. "**Dependencies**: After #N" inside ``` fence → NOT treated as dep (canonical form)
#    33. Fence closes correctly — header AFTER close of fence IS detected

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"

# =============================================================================
# Helper: source only _extract_dep_issues_from_body from the batch file.
# We source via a wrapper that sets up the minimum stubs needed to prevent the
# script body from running. RITE_SOURCE_FUNCTIONS_ONLY isn't supported by
# batch-process-issues.sh (it's an orchestrator), so we use the _LOADED guard.
# =============================================================================

_load_extract_helper() {
  # The _RITE_BATCH_PROCESS_LOADED guard prevents the body from running when
  # re-sourced. We need to temporarily unset function definitions so we can
  # re-source just the function block up to the first `if [ -z "${RITE_LIB_DIR:-}" ]`.
  #
  # Simpler: define the function inline using the extracted text so the test
  # does not depend on sourcing the full orchestrator.
  #
  # We use a heredoc-eval approach to extract the function definition from the
  # batch file — this keeps the test coupled to the real implementation without
  # needing to run the full script context.
  #
  # Extract the function from the batch file and define it in this subshell.
  eval "$(awk '
    /_extract_dep_issues_from_body[(][)]/ { in_fn=1 }
    in_fn { print }
    in_fn && /^}$/ { exit }
  ' "$BATCH_PROCESSOR")"
}

# =============================================================================
# UNIT: _extract_dep_issues_from_body helper function
# =============================================================================

@test "unit: prose-only body with dep syntax → no deps extracted" {
  # Reproduces the live #556 bug: prose says "After #1" but no Dependencies: field
  _load_extract_helper

  _body="## Description
This fix addresses the ordinal-ref bug. For example, a body like
After #1 would previously be parsed as a live dependency. The fix
scopes extraction to the Dependencies field only.

**Acceptance Criteria**
- [ ] No false dep_failed skips

**Dependencies**: None"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  # "None" is text, not a number — should be empty
  [ -z "$_result" ] || {
    echo "FAIL: expected no deps for 'Dependencies: None', got: '$_result'" >&2
    return 1
  }
}

@test "unit: body with Dependencies: None → no deps extracted" {
  _load_extract_helper

  _body="**Dependencies**: None"
  _result=$(_extract_dep_issues_from_body "$_body" || true)
  [ -z "$_result" ] || {
    echo "FAIL: expected no deps, got: '$_result'" >&2
    return 1
  }
}

@test "unit: body with Dependencies: After #N → N extracted" {
  _load_extract_helper

  _body="**Scope Boundary**
- DO: fix the parser

**Dependencies**: After #42

**Done Definition**: Tests pass"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  [ "$_result" = "42" ] || {
    echo "FAIL: expected '42', got: '$_result'" >&2
    return 1
  }
}

@test "unit: body with Dependencies: Blocked by: #N → N extracted" {
  _load_extract_helper

  _body="**Dependencies**: Blocked by: #7"
  _result=$(_extract_dep_issues_from_body "$_body" || true)
  [ "$_result" = "7" ] || {
    echo "FAIL: expected '7', got: '$_result'" >&2
    return 1
  }
}

@test "unit: body with Dependencies: Depends on #N → N extracted" {
  _load_extract_helper

  _body="**Dependencies**: Depends on #99"
  _result=$(_extract_dep_issues_from_body "$_body" || true)
  [ "$_result" = "99" ] || {
    echo "FAIL: expected '99', got: '$_result'" >&2
    return 1
  }
}

@test "unit: multiple deps on one Dependencies: line → all extracted" {
  _load_extract_helper

  _body="**Dependencies**: After #10, Blocked by: #20"
  _result=$(_extract_dep_issues_from_body "$_body" || true)
  echo "$_result" | grep -qw "10" || {
    echo "FAIL: expected '10' in '$_result'" >&2
    return 1
  }
  echo "$_result" | grep -qw "20" || {
    echo "FAIL: expected '20' in '$_result'" >&2
    return 1
  }
}

@test "unit: multi-line dep field continuation lines → all extracted" {
  _load_extract_helper

  _body="**Dependencies**:
After #5
Blocked by: #6

**Done Definition**: All tests pass"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  echo "$_result" | grep -qw "5" || {
    echo "FAIL: expected '5' in '$_result'" >&2
    return 1
  }
  echo "$_result" | grep -qw "6" || {
    echo "FAIL: expected '6' in '$_result'" >&2
    return 1
  }
}

@test "unit: parallel-with annotation stripped → sibling NOT harvested as dep" {
  # "After #5 (can run in parallel with #6)" — #6 is a sibling hint, not a dep
  _load_extract_helper

  _body="**Dependencies**: After #5 (can run in parallel with #6)"
  _result=$(_extract_dep_issues_from_body "$_body" || true)
  echo "$_result" | grep -qw "5" || {
    echo "FAIL: expected '5' (real dep) in '$_result'" >&2
    return 1
  }
  ! echo "$_result" | grep -qw "6" || {
    echo "FAIL: '6' (parallel sibling) must NOT appear in '$_result'" >&2
    return 1
  }
}

@test "unit: header inline ref: **Dependencies**: After #5 → 5 extracted" {
  _load_extract_helper

  # Dep ref is on the same line as the header, not on a continuation line
  _body="**Dependencies**: After #5
**Done Definition**: Tests pass"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  [ "$_result" = "5" ] || {
    echo "FAIL: expected '5', got: '$_result'" >&2
    return 1
  }
}

@test "unit: section stop — refs after next ** header not collected" {
  _load_extract_helper

  _body="**Dependencies**: None

**Done Definition**: After #99 is referenced here as an example"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  ! echo "$_result" | grep -qw "99" || {
    echo "FAIL: '99' from Done Definition section must NOT appear in '$_result'" >&2
    return 1
  }
}

@test "unit: section stop — refs after ## header not collected" {
  _load_extract_helper

  _body="**Dependencies**: None

## Technical Notes

After #55 we should also fix the related issue"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  ! echo "$_result" | grep -qw "55" || {
    echo "FAIL: '55' from Technical Notes section must NOT appear in '$_result'" >&2
    return 1
  }
}

@test "unit: section stop — refs after --- divider not collected" {
  _load_extract_helper

  _body="**Dependencies**: None
---
After #77 in footer text"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  ! echo "$_result" | grep -qw "77" || {
    echo "FAIL: '77' after --- divider must NOT appear in '$_result'" >&2
    return 1
  }
}

@test "unit: no Dependencies: field at all → empty (no fallback to whole body)" {
  # Design decision: bodies without a Dependencies: header yield no deps.
  # Rationale: the issue template mandates the field; missing it means the body
  # is malformed. Falling back to whole-body parsing is precisely the bug we fix.
  _load_extract_helper

  _body="## Description
This issue implements the After #10 workflow fix.
Depends on #20 being ready first.

**Acceptance Criteria**
- [ ] Works correctly"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  [ -z "$_result" ] || {
    echo "FAIL: expected empty result (no Dependencies: field), got: '$_result'" >&2
    echo "      Whole-body fallback must not fire — that is the bug we are fixing" >&2
    return 1
  }
}

@test "unit: bare #N on header line — **Dependencies**: #42 → 42 extracted" {
  # Covers the silent-drop bug: bare "#N" shorthand (no keyword prefix) in the
  # Dependencies field was previously ignored because only keyword-anchored refs
  # (After #N, Blocked by: #N, Depends on #N) were collected from the header line.
  _load_extract_helper

  _body="**Dependencies**: #42"
  _result=$(_extract_dep_issues_from_body "$_body" || true)
  [ "$_result" = "42" ] || {
    echo "FAIL: expected '42' for bare '#42' on header line, got: '$_result'" >&2
    return 1
  }
}

@test "unit: bare #N on continuation line — standalone '#42' → 42 extracted" {
  # Covers the silent-drop bug: bare "#N" on a continuation line under the
  # Dependencies: header was not harvested — only keyword-anchored refs were.
  _load_extract_helper

  _body="**Dependencies**:
#42

**Done Definition**: Tests pass"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  [ "$_result" = "42" ] || {
    echo "FAIL: expected '42' for bare '#42' continuation line, got: '$_result'" >&2
    return 1
  }
}

@test "unit: plain number without # in Dependencies section NOT harvested (format anchor)" {
  # Regression guard: the # prefix is a format anchor that prevents plain numeric
  # words (version numbers, timeouts, counts) from being harvested as issue numbers.
  # E.g. "**Dependencies**: After #5 (timeout: 300s)" must yield only "5", not "300".
  _load_extract_helper

  _body="**Dependencies**: After #5 (timeout: 300s, retry: 3 times)"
  _result=$(_extract_dep_issues_from_body "$_body" || true)
  # "5" must be in the result (keyword-anchored ref)
  echo "$_result" | grep -qw "5" || {
    echo "FAIL: expected '5' in '$_result'" >&2
    return 1
  }
  # "300" and "3" must NOT be in the result (plain numeric words, no # prefix)
  ! echo "$_result" | grep -qw "300" || {
    echo "FAIL: '300' (plain number) must NOT appear in '$_result'" >&2
    return 1
  }
  ! echo "$_result" | grep -qw "3" || {
    echo "FAIL: '3' (plain number) must NOT appear in '$_result'" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: static code inspection
# =============================================================================

@test "structural: _extract_dep_issues_from_body is defined in batch-process-issues.sh" {
  grep -q '_extract_dep_issues_from_body()' "$BATCH_PROCESSOR" || {
    echo "FAIL: _extract_dep_issues_from_body() not found in $BATCH_PROCESSOR" >&2
    return 1
  }
}

@test "structural: per-issue DEP_ISSUES= uses _extract_dep_issues_from_body, not whole-body grep" {
  # The per-issue guard must call the helper, not the old grep -oiE pattern.
  # Anchor to ^[[:space:]]* so comments that reference "DEP_ISSUES=" are not
  # matched before the actual assignment line (e.g. line 279 in batch-process-issues.sh
  # is a comment: "# The per-issue dep-skip guard (search for "DEP_ISSUES=" below)").
  _dep_issues_line=$(grep -E '^[[:space:]]*DEP_ISSUES=' "$BATCH_PROCESSOR" | head -1 || true)
  [ -n "$_dep_issues_line" ] || {
    echo "FAIL: DEP_ISSUES= assignment not found in $BATCH_PROCESSOR" >&2
    return 1
  }
  # Must call the scoped helper
  echo "$_dep_issues_line" | grep -q '_extract_dep_issues_from_body' || {
    echo "FAIL: DEP_ISSUES= must use _extract_dep_issues_from_body, not whole-body grep" >&2
    echo "      Line: $_dep_issues_line" >&2
    return 1
  }
  # Must NOT use the old whole-body grep
  ! echo "$_dep_issues_line" | grep -q 'grep -oiE' || {
    echo "FAIL: DEP_ISSUES= still uses old grep -oiE whole-body pattern" >&2
    echo "      Line: $_dep_issues_line" >&2
    return 1
  }
}

@test "structural: preflight _dep_refs= uses _extract_dep_issues_from_body, not whole-body grep" {
  # The preflight dep extraction must also call the helper.
  # Anchor to ^[[:space:]]* to skip any comments that mention _dep_refs= before
  # reaching the actual assignment line.
  _dep_refs_line=$(grep -E '^[[:space:]]*_dep_refs=' "$BATCH_PROCESSOR" | head -1 || true)
  [ -n "$_dep_refs_line" ] || {
    echo "FAIL: _dep_refs= assignment not found in $BATCH_PROCESSOR" >&2
    return 1
  }
  echo "$_dep_refs_line" | grep -q '_extract_dep_issues_from_body' || {
    echo "FAIL: _dep_refs= must use _extract_dep_issues_from_body, not whole-body grep" >&2
    echo "      Line: $_dep_refs_line" >&2
    return 1
  }
  ! echo "$_dep_refs_line" | grep -q 'grep -oiE' || {
    echo "FAIL: _dep_refs= still uses old grep -oiE whole-body pattern" >&2
    echo "      Line: $_dep_refs_line" >&2
    return 1
  }
}

@test "structural: Deliberate divergence comment still present (parity contract)" {
  # The dep-failed divergence comment is required by batch-single-issue-parity.bats.
  # Our change must not remove it.
  grep -q "Deliberate divergence from single-issue mode" "$BATCH_PROCESSOR" || {
    echo "FAIL: 'Deliberate divergence' comment not found — per-issue guard may have been altered" >&2
    return 1
  }
}

@test "structural: dead _inline variable removed (SC2034 fix — no new unused variable)" {
  # The old _inline variable was assigned but never read, introducing a new SC2034
  # violation. CLAUDE.md states: "SC2034 is currently disabled with a 49-occurrence
  # ledger; new violations must be addressed." This test asserts the dead variable
  # is gone and the replacement (_inline_refs) is the one in use.
  #
  # We check that:
  #   a) "_inline=" (the dead assignment) is NOT in the function
  #   b) "_inline_refs=" (the replacement) IS in the function
  _fn_body=$(awk '
    /_extract_dep_issues_from_body[(][)]/ { in_fn=1 }
    in_fn { print }
    in_fn && /^}$/ { exit }
  ' "$BATCH_PROCESSOR" || true)

  [ -n "$_fn_body" ] || {
    echo "FAIL: could not extract _extract_dep_issues_from_body body from $BATCH_PROCESSOR" >&2
    return 1
  }

  # Dead variable must be gone (checking for bare assignment, not the name in comments)
  ! echo "$_fn_body" | grep -qE '^\s+_inline=\$\(' || {
    echo "FAIL: dead '_inline=\$(...)' assignment still present in _extract_dep_issues_from_body" >&2
    echo "      This is the SC2034 violation from the old implementation." >&2
    return 1
  }

  # Replacement variable must be present
  echo "$_fn_body" | grep -q '_inline_refs' || {
    echo "FAIL: '_inline_refs' not found in _extract_dep_issues_from_body" >&2
    echo "      Expected the replacement variable that fixes SC2034" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: per-issue guard integration
# =============================================================================

@test "behavioral: prose 'After #1' with Dependencies: None → issue NOT skipped" {
  # Reproduces the exact #556 failure: prose contains dep syntax but structured
  # field says None. The issue must NOT be marked dep_failed.

  _script="$BATS_TEST_TMPDIR/test-556-regression.sh"
  cat > "$_script" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

# ---- Source _extract_dep_issues_from_body from the real batch file ----
eval "$(awk '
  /_extract_dep_issues_from_body[(][)]/ { in_fn=1 }
  in_fn { print }
  in_fn && /^}$/ { exit }
' "BATCH_PROCESSOR_PATH")"

# ---- Simulate the per-issue dep-check block ----
declare -A ISSUE_STATUS
ISSUE_NUM=556
ISSUE_BODY="## Description
This issue fixes the ordinal-ref bug. In a body like:
After #1 would previously be parsed as a live dependency.
The parser harvested #1 from the description text.

**Dependencies**: None"

DEP_ISSUES=$(_extract_dep_issues_from_body "$ISSUE_BODY" || true)
if [ -n "$DEP_ISSUES" ]; then
  DEP_FAILED=false
  FAILED_DEP=""
  for dep_num in $DEP_ISSUES; do
    dep_status="${ISSUE_STATUS[$dep_num]:-}"
    if [ "$dep_status" = "failed" ] || [ "$dep_status" = "blocked" ] || \
       [ "$dep_status" = "not_found" ] || [ "$dep_status" = "dep_failed" ]; then
      DEP_FAILED=true
      FAILED_DEP="$dep_num"
      break
    fi
    # Simulate dep issue #1 is OPEN (worst case: this is what triggered the bug)
    if [ "$dep_num" = "1" ]; then
      DEP_FAILED=true
      FAILED_DEP="$dep_num"
      break
    fi
  done
  if [ "$DEP_FAILED" = true ]; then
    echo "SKIPPED: issue $ISSUE_NUM (dep $FAILED_DEP)"
    exit 0
  fi
fi
echo "PROCEEDED: issue $ISSUE_NUM"
SCRIPT_EOF

  # Substitute the real batch processor path
  sed -i.bak "s|BATCH_PROCESSOR_PATH|$BATCH_PROCESSOR|g" "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed with status $status: $output" >&2
    return 1
  }
  echo "$output" | grep -q "PROCEEDED: issue 556" || {
    echo "FAIL: issue #556 was skipped despite Dependencies: None" >&2
    echo "      The prose 'After #1' must NOT be harvested as a live dep" >&2
    echo "Output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "SKIPPED" || {
    echo "FAIL: issue was incorrectly skipped" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: Dependencies: After #N where N is failed → issue skipped (existing behavior preserved)" {
  # Genuine dep in the structured field must still gate correctly.

  _script="$BATS_TEST_TMPDIR/test-real-dep-gates.sh"
  cat > "$_script" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

eval "$(awk '
  /_extract_dep_issues_from_body[(][)]/ { in_fn=1 }
  in_fn { print }
  in_fn && /^}$/ { exit }
' "BATCH_PROCESSOR_PATH")"

declare -A ISSUE_STATUS
ISSUE_STATUS[30]="failed"
ISSUE_NUM=50
ISSUE_BODY="## Description
Implements the next phase.

**Dependencies**: After #30

**Done Definition**: Tests pass"

DEP_ISSUES=$(_extract_dep_issues_from_body "$ISSUE_BODY" || true)
if [ -n "$DEP_ISSUES" ]; then
  DEP_FAILED=false
  FAILED_DEP=""
  for dep_num in $DEP_ISSUES; do
    dep_status="${ISSUE_STATUS[$dep_num]:-}"
    if [ "$dep_status" = "failed" ] || [ "$dep_status" = "blocked" ] || \
       [ "$dep_status" = "not_found" ] || [ "$dep_status" = "dep_failed" ]; then
      DEP_FAILED=true
      FAILED_DEP="$dep_num"
      break
    fi
  done
  if [ "$DEP_FAILED" = true ]; then
    echo "SKIPPED: issue $ISSUE_NUM (dep $FAILED_DEP failed)"
    exit 0
  fi
fi
echo "PROCEEDED: issue $ISSUE_NUM"
SCRIPT_EOF

  sed -i.bak "s|BATCH_PROCESSOR_PATH|$BATCH_PROCESSOR|g" "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed with status $status: $output" >&2
    return 1
  }
  echo "$output" | grep -q "SKIPPED: issue 50" || {
    echo "FAIL: issue #50 should be skipped when its dep (#30) failed" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: bare #N dep — Dependencies: #N where N is failed → issue skipped" {
  # Validates that bare "#N" refs (no keyword prefix) in the Dependencies field
  # now gate correctly after the silent-drop fix.
  # Before the fix: "Dependencies: #30" yielded no deps → issue PROCEEDED even
  # when dep #30 had failed. After the fix: bare #N is harvested → issue SKIPPED.

  _script="$BATS_TEST_TMPDIR/test-bare-dep-gates.sh"
  cat > "$_script" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

eval "$(awk '
  /_extract_dep_issues_from_body[(][)]/ { in_fn=1 }
  in_fn { print }
  in_fn && /^}$/ { exit }
' "BATCH_PROCESSOR_PATH")"

declare -A ISSUE_STATUS
ISSUE_STATUS[30]="failed"
ISSUE_NUM=51
ISSUE_BODY="## Description
Implements the next phase.

**Dependencies**: #30

**Done Definition**: Tests pass"

DEP_ISSUES=$(_extract_dep_issues_from_body "$ISSUE_BODY" || true)
if [ -n "$DEP_ISSUES" ]; then
  DEP_FAILED=false
  FAILED_DEP=""
  for dep_num in $DEP_ISSUES; do
    dep_status="${ISSUE_STATUS[$dep_num]:-}"
    if [ "$dep_status" = "failed" ] || [ "$dep_status" = "blocked" ] || \
       [ "$dep_status" = "not_found" ] || [ "$dep_status" = "dep_failed" ]; then
      DEP_FAILED=true
      FAILED_DEP="$dep_num"
      break
    fi
  done
  if [ "$DEP_FAILED" = true ]; then
    echo "SKIPPED: issue $ISSUE_NUM (dep $FAILED_DEP failed)"
    exit 0
  fi
fi
echo "PROCEEDED: issue $ISSUE_NUM"
SCRIPT_EOF

  sed -i.bak "s|BATCH_PROCESSOR_PATH|$BATCH_PROCESSOR|g" "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed with status $status: $output" >&2
    return 1
  }
  echo "$output" | grep -q "SKIPPED: issue 51" || {
    echo "FAIL: issue #51 should be skipped when bare dep (#30) failed" >&2
    echo "      Before fix: 'Dependencies: #30' yielded no deps → issue PROCEEDED" >&2
    echo "Output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "PROCEEDED" || {
    echo "FAIL: issue incorrectly proceeded despite failed bare dep #30" >&2
    echo "Output: $output" >&2
    return 1
  }
}

# =============================================================================
# LEGACY FORM: ## Dependencies markdown header (pre-#964 issues, e.g. #967)
# =============================================================================

@test "legacy: '## Dependencies\\nAfter: #N' → N extracted (mirrors #967 body shape)" {
  # Root regression: issue #967 used '## Dependencies' / 'After: #921' and ran
  # concurrently with open #921 instead of deferring. Live batch: 2026-07-06.
  _load_extract_helper

  _body="## Description
Implements the widget redesign.

## Dependencies
After: #921

## Acceptance Criteria
- [ ] Widget renders correctly"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  [ "$_result" = "921" ] || {
    echo "FAIL: expected '921' from legacy '## Dependencies / After: #921' body, got: '$_result'" >&2
    echo "      This is the exact #967 body shape that caused the live batch failure" >&2
    return 1
  }
}

@test "legacy: '### Dependencies\\nAfter: #N' → N extracted (any ## level)" {
  # The guard must handle any markdown heading depth (##, ###, ####, etc.)
  # that documents dependencies — not just the two-hash form.
  _load_extract_helper

  _body="## Description
Implements the next phase.

### Dependencies
After: #55

## Acceptance Criteria
- [ ] Phase complete"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  [ "$_result" = "55" ] || {
    echo "FAIL: expected '55' from '### Dependencies / After: #55', got: '$_result'" >&2
    return 1
  }
}

@test "legacy: '## Dependencies\\nBlocked by: #N' → N extracted" {
  _load_extract_helper

  _body="## Dependencies
Blocked by: #12"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  [ "$_result" = "12" ] || {
    echo "FAIL: expected '12' from 'Blocked by: #12', got: '$_result'" >&2
    return 1
  }
}

@test "legacy: '## Dependencies' with multiple following lines → all deps extracted" {
  _load_extract_helper

  _body="## Description
Implements the next phase.

## Dependencies
After: #10
After: #20
Blocked by: #30

## Acceptance Criteria
- [ ] All prior phases complete"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  echo "$_result" | grep -qw "10" || {
    echo "FAIL: expected '10' in '$_result'" >&2
    return 1
  }
  echo "$_result" | grep -qw "20" || {
    echo "FAIL: expected '20' in '$_result'" >&2
    return 1
  }
  echo "$_result" | grep -qw "30" || {
    echo "FAIL: expected '30' in '$_result'" >&2
    return 1
  }
}

@test "legacy: '## Dependencies' stops at next ## section header — refs after stop not collected" {
  # The stop-at-next-header rule must still apply when the legacy form is active.
  _load_extract_helper

  _body="## Dependencies
After: #10

## Acceptance Criteria
After: #99 is mentioned here as a prerequisite explanation"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  echo "$_result" | grep -qw "10" || {
    echo "FAIL: expected '10' (in dep section) in '$_result'" >&2
    return 1
  }
  ! echo "$_result" | grep -qw "99" || {
    echo "FAIL: '99' (after section stop) must NOT appear in '$_result'" >&2
    return 1
  }
}

@test "legacy pin: canonical '**Dependencies**: After #N' still works (behavior preserved)" {
  # Regression guard: adding legacy-form support must not break the canonical form.
  _load_extract_helper

  _body="**Dependencies**: After #77

**Done Definition**: Tests pass"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  [ "$_result" = "77" ] || {
    echo "FAIL: canonical form broken — expected '77', got: '$_result'" >&2
    return 1
  }
}

# =============================================================================
# FENCE GUARD: headers inside ``` fences must NOT trigger dep collection
# =============================================================================

@test "fence guard: '## Dependencies' inside \`\`\` fence → NOT treated as dep section" {
  # A body documenting the dep header format in a code example must not
  # trigger dep collection. Mirrors the BARE_MARKER_GREP rule: format anchor
  # needed; fence content is documentation, not live dependency edges.
  _load_extract_helper

  _body="## Description
The issue format requires a dep section. Example:

\`\`\`
## Dependencies
After: #921
\`\`\`

**Dependencies**: None"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  # "921" is inside the fence — must NOT be collected
  ! echo "$_result" | grep -qw "921" || {
    echo "FAIL: '921' inside code fence must NOT be harvested as a dep" >&2
    echo "      The fence guard must prevent '## Dependencies' inside \`\`\` from triggering collection" >&2
    echo "      Got: '$_result'" >&2
    return 1
  }
}

@test "fence guard: '**Dependencies**: After #N' inside \`\`\` fence → NOT treated as dep" {
  # The canonical form is also fenced-guarded — a code example showing the
  # header format must not trigger collection.
  _load_extract_helper

  _body="## Description
Use the canonical form in your issues:

\`\`\`
**Dependencies**: After #42
\`\`\`

**Dependencies**: None"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  # "42" is inside the fence — must NOT be collected
  ! echo "$_result" | grep -qw "42" || {
    echo "FAIL: '42' inside code fence must NOT be harvested as a dep" >&2
    echo "      Got: '$_result'" >&2
    return 1
  }
}

@test "fence guard: header AFTER close of fence IS detected correctly" {
  # After a fence closes, dep header detection must resume normally.
  # The fence toggle must not leave collection permanently disabled.
  _load_extract_helper

  _body="## Description
Example:

\`\`\`
## Dependencies
After: #999
\`\`\`

## Dependencies
After: #88"

  _result=$(_extract_dep_issues_from_body "$_body" || true)
  # "88" is after the fence close — must be collected
  echo "$_result" | grep -qw "88" || {
    echo "FAIL: '88' after fence close must be collected — got: '$_result'" >&2
    return 1
  }
  # "999" is inside the fence — must NOT be collected
  ! echo "$_result" | grep -qw "999" || {
    echo "FAIL: '999' inside fence must NOT be collected — got: '$_result'" >&2
    return 1
  }
}

# =============================================================================
# DEP_IN_QUEUE: defer dependent when dep is queued later (issue #1022)
#
# These tests source the REAL _check_dep_queued_later function from the batch
# file via awk extraction, so they bind to the shipped implementation and
# cannot drift silently.
# =============================================================================

@test "dep-in-queue: N2 depends on open N1 queued later → N2 deferred, not dep_failed" {
  # Reproduces the core gap: `rite N2 N1` where N2→N1 and N1 is still OPEN.
  # Before the fix: N2 was skipped with dep_failed immediately.
  # After the fix:  N2 is appended to the queue and processed after N1.

  _script="$BATS_TEST_TMPDIR/test-dep-in-queue-defer.sh"
  cat > "$_script" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Load the real _check_dep_queued_later from the batch file
eval "$(awk '
  /_check_dep_queued_later[(][)]/ { in_fn=1 }
  in_fn { print }
  in_fn && /^}$/ { exit }
' "BATCH_PROCESSOR_PATH")"

declare -A ISSUE_STATUS
declare -A _DEFER_COUNT
ISSUE_LIST=(2 1)    # N2 listed first, N1 queued later
_batch_qi=1         # incremented past index 0 (N2 is current); N1 is at index 1

ISSUE_NUM=2
DEP_FAILED=false
DEP_IN_QUEUE=false
DEP_IN_QUEUE_NUM=""

# Simulate dep issue #1 is OPEN and not in failure list
dep_issue_state="OPEN"
if [ "$dep_issue_state" = "OPEN" ]; then
  _check_dep_queued_later 1 "$ISSUE_NUM" "$_batch_qi"
  if [ "$DEP_IN_QUEUE" = false ]; then
    DEP_FAILED=true
  fi
fi

if [ "$DEP_IN_QUEUE" = true ]; then
  _DEFER_COUNT[$ISSUE_NUM]=$(( ${_DEFER_COUNT[$ISSUE_NUM]:-0} + 1 ))
  ISSUE_LIST+=("$ISSUE_NUM")
  ISSUE_STATUS["$ISSUE_NUM"]="deferred_for_dep"
  echo "DEFERRED: issue $ISSUE_NUM (dep 1 queued later)"
elif [ "$DEP_FAILED" = true ]; then
  echo "SKIPPED: issue $ISSUE_NUM (dep_failed)"
else
  echo "PROCEEDED: issue $ISSUE_NUM"
fi
echo "QUEUE:${ISSUE_LIST[*]}"
SCRIPT_EOF

  sed -i.bak "s|BATCH_PROCESSOR_PATH|$BATCH_PROCESSOR|g" "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  echo "$output" | grep -q "DEFERRED: issue 2" || {
    echo "FAIL: N2 should be DEFERRED when dep N1 is in queue" >&2
    echo "      Before fix: N2 was SKIPPED with dep_failed immediately" >&2
    echo "Output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "SKIPPED" || {
    echo "FAIL: N2 was incorrectly skipped (old dep_failed behaviour still active)" >&2
    echo "Output: $output" >&2
    return 1
  }
  # N2 should have been appended to the queue for later processing
  echo "$output" | grep -qE "QUEUE:.*2 1 2|QUEUE:2 1 2" || {
    echo "FAIL: N2 should appear at end of queue after N1" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "dep-in-queue: N2 depends on open N1 NOT in queue → dep_failed (existing behavior pinned)" {
  # When the dep is OPEN but is NOT in the current batch, the old dep_failed
  # skip must still apply — the deferral only fires for queue-members.

  _script="$BATS_TEST_TMPDIR/test-dep-not-in-queue.sh"
  cat > "$_script" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

eval "$(awk '
  /_check_dep_queued_later[(][)]/ { in_fn=1 }
  in_fn { print }
  in_fn && /^}$/ { exit }
' "BATCH_PROCESSOR_PATH")"

declare -A ISSUE_STATUS
declare -A _DEFER_COUNT
ISSUE_LIST=(2 3 4)   # dep #1 is NOT in this list
_batch_qi=1          # past index 0 (N2 is current)

ISSUE_NUM=2
DEP_FAILED=false
DEP_IN_QUEUE=false
DEP_IN_QUEUE_NUM=""

dep_issue_state="OPEN"
if [ "$dep_issue_state" = "OPEN" ]; then
  _check_dep_queued_later 1 "$ISSUE_NUM" "$_batch_qi"
  if [ "$DEP_IN_QUEUE" = false ]; then
    DEP_FAILED=true
  fi
fi

if [ "$DEP_IN_QUEUE" = true ]; then
  echo "DEFERRED: issue $ISSUE_NUM"
elif [ "$DEP_FAILED" = true ]; then
  echo "SKIPPED: issue $ISSUE_NUM (dep 1 — issue still open)"
else
  echo "PROCEEDED: issue $ISSUE_NUM"
fi
SCRIPT_EOF

  sed -i.bak "s|BATCH_PROCESSOR_PATH|$BATCH_PROCESSOR|g" "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  echo "$output" | grep -q "SKIPPED: issue 2" || {
    echo "FAIL: N2 should be SKIPPED when dep N1 is OPEN but NOT in queue" >&2
    echo "Output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "DEFERRED" || {
    echo "FAIL: N2 must NOT be deferred when dep is not in queue" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "dep-in-queue: dep already CLOSED → runs immediately (existing behavior pinned)" {
  # When the dep issue is CLOSED (already merged), the OPEN check is never
  # entered — the dependent issue should proceed to the workflow normally.

  _script="$BATS_TEST_TMPDIR/test-dep-closed.sh"
  cat > "$_script" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

eval "$(awk '
  /_check_dep_queued_later[(][)]/ { in_fn=1 }
  in_fn { print }
  in_fn && /^}$/ { exit }
' "BATCH_PROCESSOR_PATH")"

declare -A ISSUE_STATUS
declare -A _DEFER_COUNT
ISSUE_LIST=(2 1)
_batch_qi=1

ISSUE_NUM=2
DEP_FAILED=false
DEP_IN_QUEUE=false

# dep issue #1 is CLOSED — OPEN block never entered
dep_issue_state="CLOSED"
if [ "$dep_issue_state" = "OPEN" ]; then
  _check_dep_queued_later 1 "$ISSUE_NUM" "$_batch_qi"
  [ "$DEP_IN_QUEUE" = false ] && DEP_FAILED=true
fi

if [ "$DEP_IN_QUEUE" = true ]; then
  echo "DEFERRED: issue $ISSUE_NUM"
elif [ "$DEP_FAILED" = true ]; then
  echo "SKIPPED: issue $ISSUE_NUM"
else
  echo "PROCEEDED: issue $ISSUE_NUM"
fi
SCRIPT_EOF

  sed -i.bak "s|BATCH_PROCESSOR_PATH|$BATCH_PROCESSOR|g" "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  echo "$output" | grep -q "PROCEEDED: issue 2" || {
    echo "FAIL: N2 should PROCEED when dep N1 is CLOSED" >&2
    echo "Output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "SKIPPED\|DEFERRED" || {
    echo "FAIL: N2 must not be skipped/deferred when dep is CLOSED" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "dep-in-queue: ≥3-issue chain (N3→N2→N1) — second deferral of N3 works (anti-cycle fix)" {
  # A reprocessed issue (deferred once, status=deferred_for_dep) must still be
  # deferred again when its dep is still queued later.
  # Old code: status=deferred_for_dep skipped the scan → N3 got dep_failed
  # even though N2 was still queued after N3 (correct: N3 should defer again).
  #
  # The chain that NEEDS the second deferral: queue [N3, N2, N1, N3, N2]
  # _batch_qi=3 (re-processing N3 at index 3), N2 is at index 4 (still queued)
  # → positional scan finds N2 at index 4 → DEP_IN_QUEUE=true → N3 deferred again.
  # Old code would skip the scan (deferred_for_dep) → N3 dep_failed incorrectly.

  _script="$BATS_TEST_TMPDIR/test-chain-second-defer.sh"
  cat > "$_script" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

eval "$(awk '
  /_check_dep_queued_later[(][)]/ { in_fn=1 }
  in_fn { print }
  in_fn && /^}$/ { exit }
' "BATCH_PROCESSOR_PATH")"

declare -A ISSUE_STATUS
declare -A _DEFER_COUNT
# Simulate queue after first deferral of N3 and first deferral of N2:
# [N3, N2, N1, N3, N2] — both N3 and N2 were deferred once
ISSUE_LIST=(3 2 1 3 2)
_DEFER_COUNT[3]=1   # N3 was deferred once already
_DEFER_COUNT[2]=1   # N2 was deferred once already
ISSUE_STATUS[3]="deferred_for_dep"
ISSUE_STATUS[2]="deferred_for_dep"

# N3 is being re-processed at index 3 (_batch_qi=4, already incremented past index 3)
_batch_qi=4
ISSUE_NUM=3
DEP_FAILED=false
DEP_IN_QUEUE=false
DEP_IN_QUEUE_NUM=""

# Simulate dep N2 is still OPEN
dep_issue_state="OPEN"
if [ "$dep_issue_state" = "OPEN" ]; then
  _check_dep_queued_later 2 "$ISSUE_NUM" "$_batch_qi"
  if [ "$DEP_IN_QUEUE" = false ]; then
    DEP_FAILED=true
  fi
fi

if [ "$DEP_IN_QUEUE" = true ]; then
  _DEFER_COUNT[$ISSUE_NUM]=$(( ${_DEFER_COUNT[$ISSUE_NUM]:-0} + 1 ))
  ISSUE_LIST+=("$ISSUE_NUM")
  ISSUE_STATUS["$ISSUE_NUM"]="deferred_for_dep"
  echo "DEFERRED: issue $ISSUE_NUM (defer #${_DEFER_COUNT[$ISSUE_NUM]})"
elif [ "$DEP_FAILED" = true ]; then
  echo "SKIPPED: issue $ISSUE_NUM (dep_failed)"
else
  echo "PROCEEDED: issue $ISSUE_NUM"
fi
echo "QUEUE:${ISSUE_LIST[*]}"
SCRIPT_EOF

  sed -i.bak "s|BATCH_PROCESSOR_PATH|$BATCH_PROCESSOR|g" "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  echo "$output" | grep -q "DEFERRED: issue 3" || {
    echo "FAIL: N3 should be DEFERRED again (dep N2 at index 4 is still queued)" >&2
    echo "      Old code: deferred_for_dep status skipped scan → dep_failed incorrectly" >&2
    echo "Output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "SKIPPED" || {
    echo "FAIL: N3 must NOT be dep_failed when N2 is still queued after current pos" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "dep-in-queue: already-processed dep (index < _batch_qi) does NOT trigger false deferral" {
  # Finding #2: the scan must be positional (from _batch_qi) not over the full list.
  # An issue that already ran but left its issue OPEN (e.g. waiting_for_parent,
  # branch_mismatch) is at an index BEFORE _batch_qi and must not cause a false
  # "queued later" deferral.
  #
  # Setup: ISSUE_LIST=(1 2), _batch_qi=2 (N2 is current, index 1; qi incremented to 2)
  # Dep #1 was at index 0 — already processed, left OPEN (e.g. waiting_for_parent).
  # Positional scan from index 2 sees no entry for dep #1 → DEP_IN_QUEUE=false → dep_failed.
  # Old code: full list scan finds #1 at index 0 → false DEP_IN_QUEUE=true.

  _script="$BATS_TEST_TMPDIR/test-already-processed-dep.sh"
  cat > "$_script" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

eval "$(awk '
  /_check_dep_queued_later[(][)]/ { in_fn=1 }
  in_fn { print }
  in_fn && /^}$/ { exit }
' "BATCH_PROCESSOR_PATH")"

declare -A ISSUE_STATUS
declare -A _DEFER_COUNT
ISSUE_LIST=(1 2)
# Dep #1 ran at index 0, left the issue OPEN (waiting_for_parent)
ISSUE_STATUS[1]="waiting_for_parent"
_batch_qi=2    # N2 is current (index 1); qi incremented to 2; scan starts at 2

ISSUE_NUM=2
DEP_FAILED=false
DEP_IN_QUEUE=false

dep_issue_state="OPEN"
if [ "$dep_issue_state" = "OPEN" ]; then
  _check_dep_queued_later 1 "$ISSUE_NUM" "$_batch_qi"
  if [ "$DEP_IN_QUEUE" = false ]; then
    DEP_FAILED=true
  fi
fi

if [ "$DEP_IN_QUEUE" = true ]; then
  echo "DEFERRED: issue $ISSUE_NUM"
elif [ "$DEP_FAILED" = true ]; then
  echo "SKIPPED: issue $ISSUE_NUM (dep_failed — dep already ran, issue still open)"
else
  echo "PROCEEDED: issue $ISSUE_NUM"
fi
SCRIPT_EOF

  sed -i.bak "s|BATCH_PROCESSOR_PATH|$BATCH_PROCESSOR|g" "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  echo "$output" | grep -q "SKIPPED: issue 2" || {
    echo "FAIL: N2 should be SKIPPED (dep #1 already ran, still OPEN, not re-queued)" >&2
    echo "      Old code: full-list scan found #1 at index 0 → false DEFERRED" >&2
    echo "Output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "DEFERRED" || {
    echo "FAIL: N2 must NOT be deferred (dep #1 is before current queue position)" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "dep-in-queue: anti-cycle cap — 2-cycle terminates after _UNIQUE_ISSUE_COUNT deferrals" {
  # The cap uses _UNIQUE_ISSUE_COUNT (frozen operator-supplied count), not
  # ${#ISSUE_LIST[@]} (live length, which grows with every deferral). With the
  # live length, a 2-cycle counter trails the bound every round and the cap
  # never fires. With _UNIQUE_ISSUE_COUNT=2, after N2 is deferred twice the
  # cap fires on the third encounter — a reachable, cycle-terminating state.
  #
  # Simulates state after two full rounds of a 2-cycle (N2↔N1):
  #   Original list [2, 1] → _UNIQUE_ISSUE_COUNT=2
  #   Both deferred twice → ISSUE_LIST=[2,1,2,1,2,1]; _DEFER_COUNT[2]=2
  #   Third encounter of N2 (index 4, qi=5): dep N1 still queued at index 5
  #   but _DEFER_COUNT[2]=2 >= _UNIQUE_ISSUE_COUNT=2 → cap fires → dep_failed.

  _script="$BATS_TEST_TMPDIR/test-anti-cycle-cap.sh"
  cat > "$_script" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

eval "$(awk '
  /_check_dep_queued_later[(][)]/ { in_fn=1 }
  in_fn { print }
  in_fn && /^}$/ { exit }
' "BATCH_PROCESSOR_PATH")"

declare -A ISSUE_STATUS
declare -A _DEFER_COUNT
_UNIQUE_ISSUE_COUNT=2          # original operator-supplied count (frozen)
ISSUE_LIST=(2 1 2 1 2 1)      # after 2 rounds of mutual deferral (6 entries)
_DEFER_COUNT[2]=2              # N2 deferred twice; 2 >= _UNIQUE_ISSUE_COUNT=2 → cap
ISSUE_STATUS[2]="deferred_for_dep"
_batch_qi=5    # N2 at index 4; dep N1 is at index 5 (still queued after current)

ISSUE_NUM=2
DEP_FAILED=false
DEP_IN_QUEUE=false

dep_issue_state="OPEN"
if [ "$dep_issue_state" = "OPEN" ]; then
  _check_dep_queued_later 1 "$ISSUE_NUM" "$_batch_qi"
  if [ "$DEP_IN_QUEUE" = false ]; then
    DEP_FAILED=true
  fi
fi

if [ "$DEP_IN_QUEUE" = true ]; then
  echo "DEFERRED: issue $ISSUE_NUM"
elif [ "$DEP_FAILED" = true ]; then
  echo "SKIPPED: issue $ISSUE_NUM (cap exceeded)"
else
  echo "PROCEEDED: issue $ISSUE_NUM"
fi
SCRIPT_EOF

  sed -i.bak "s|BATCH_PROCESSOR_PATH|$BATCH_PROCESSOR|g" "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  echo "$output" | grep -q "SKIPPED: issue 2" || {
    echo "FAIL: N2 should be SKIPPED when defer count >= _UNIQUE_ISSUE_COUNT" >&2
    echo "      The cap prevents infinite deferral loops in dependency cycles" >&2
    echo "Output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "DEFERRED" || {
    echo "FAIL: N2 must NOT be deferred when defer count >= _UNIQUE_ISSUE_COUNT" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "structural: _check_dep_queued_later defined in batch-process-issues.sh" {
  grep -q '_check_dep_queued_later()' "$BATCH_PROCESSOR" || {
    echo "FAIL: _check_dep_queued_later() not found in $BATCH_PROCESSOR" >&2
    return 1
  }
}

@test "structural: DEP_IN_QUEUE uses _check_dep_queued_later (not for-in scan)" {
  grep -q '_check_dep_queued_later' "$BATCH_PROCESSOR" || {
    echo "FAIL: _check_dep_queued_later not called in $BATCH_PROCESSOR" >&2
    return 1
  }
  grep -q 'DEP_IN_QUEUE=true' "$BATCH_PROCESSOR" || {
    echo "FAIL: DEP_IN_QUEUE=true not found — queue-membership deferral not implemented" >&2
    return 1
  }
  grep -q 'deferred_for_dep' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'deferred_for_dep' status not found — anti-cycle guard missing" >&2
    return 1
  }
  # The main loop must use a while-index pattern (not for-in) to support live appends
  grep -q '_batch_qi' "$BATCH_PROCESSOR" || {
    echo "FAIL: _batch_qi not found — main loop may still be a for-in snapshot" >&2
    return 1
  }
}

@test "structural: _DEFER_COUNT declared in batch-process-issues.sh" {
  grep -q '_DEFER_COUNT' "$BATCH_PROCESSOR" || {
    echo "FAIL: _DEFER_COUNT not found — positional anti-cycle counter missing" >&2
    return 1
  }
}

@test "structural: _UNIQUE_ISSUE_COUNT frozen before main loop" {
  grep -q '_UNIQUE_ISSUE_COUNT' "$BATCH_PROCESSOR" || {
    echo "FAIL: _UNIQUE_ISSUE_COUNT not found — TOTAL_ISSUES inflation fix missing" >&2
    return 1
  }
}

@test "structural: _active_skipped filter block re-freezes _UNIQUE_ISSUE_COUNT after filtering" {
  # The _active_skipped filter (run-collision guard) reassigns ISSUE_LIST to the
  # filtered subset. _UNIQUE_ISSUE_COUNT must be updated in the same block so the
  # anti-cycle cap in _check_dep_queued_later reflects the post-filter count, not
  # the inflated pre-filter count.
  #
  # A bare grep for '_UNIQUE_ISSUE_COUNT' would pass even if both freeze sites were
  # deleted (the identifier appears inside the function body too). This test anchors
  # to the _active_skipped branch specifically.
  #
  # We extract the _active_skipped if-block and assert _UNIQUE_ISSUE_COUNT= is
  # inside it — not just anywhere in the file.
  _block=$(awk '
    /if \[ \$\{#_active_skipped\[@\]\}/ { in_block=1; depth=1 }
    in_block {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") depth--
      }
      print
      if (depth==0) { in_block=0 }
    }
  ' "$BATCH_PROCESSOR" || true)

  [ -n "$_block" ] || {
    echo "FAIL: could not find _active_skipped if-block in $BATCH_PROCESSOR" >&2
    return 1
  }

  echo "$_block" | grep -q '_UNIQUE_ISSUE_COUNT=' || {
    echo "FAIL: _active_skipped filter block does not re-freeze _UNIQUE_ISSUE_COUNT" >&2
    echo "      Without this, the anti-cycle cap reads the inflated pre-filter count" >&2
    echo "      and a deferred issue from a filtered batch can loop past the cap" >&2
    return 1
  }
}
