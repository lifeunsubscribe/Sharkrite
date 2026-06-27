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
