#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/core/assess-review-issues.sh
# Regression test for: DISMISSED items leaking into rollup body (defect #3)
# Issues: #469-#478-#495
#
# Bug: assess-and-resolve.sh extracted severity buckets using:
#   grep -A 20 "^### .* - ACTIONABLE_LATER" | grep -B 2 "Severity:.*HIGH"
# When an ACTIONABLE_LATER item is immediately followed by a DISMISSED item, the
# 20-line look-ahead spans the item boundary and grep -B 2 pulls the DISMISSED
# header into the severity bucket.
#
# Live example: "### Static guard test - DISMISSED" appeared in rollup body of
# issue #430 (PR #387) because grep -A 20 on the preceding ACTIONABLE_LATER
# included the DISMISSED header within the 20-line window.
#
# Fix: replace grep -A 20 | grep -B 2 with awk-based per-item extraction that
# stops at each ### header (regardless of STATE), keeping items isolated.
#
# Tests in this file:
#   1. Static: grep -A 20 pattern (item boundary crossing) is absent
#   2. Unit:   awk extractor produces no DISMISSED headers in LATER bucket
#   3. Unit:   awk extractor correctly extracts HIGH item even when DISMISSED item follows
#   4. Unit:   awk extractor handles NOW items without spilling into DISMISSED
#   5. Static: assess-review-issues.sh adds priority label to per-item issues

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export ASSESS_RESOLVE_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
  export ASSESS_REVIEW_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"

  [ -f "$ASSESS_RESOLVE_SCRIPT" ] || {
    echo "setup: ASSESS_RESOLVE_SCRIPT not found at $ASSESS_RESOLVE_SCRIPT" >&2
    false
  }
  [ -f "$ASSESS_REVIEW_SCRIPT" ] || {
    echo "setup: ASSESS_REVIEW_SCRIPT not found at $ASSESS_REVIEW_SCRIPT" >&2
    false
  }
}

teardown() {
  teardown_test_tmpdir
}

# ─── Test 1: Static — grep -A 20 item-crossing pattern is gone ────────────────

@test "assess-and-resolve.sh: ACTIONABLE_LATER extraction no longer uses grep -A 20" {
  # The original bug pattern: grep -A 20 spans item boundaries when items are short.
  # The fix uses awk-based per-item extraction instead.
  run grep -n 'grep -A 20.*ACTIONABLE_LATER' "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -ne 0 ] || {
    echo "FAIL: 'grep -A 20.*ACTIONABLE_LATER' still present in $ASSESS_RESOLVE_SCRIPT"
    echo "Matches:"
    echo "$output"
    false
  }
}

# ─── Test 2: Unit — awk extractor: DISMISSED items do not appear in LATER bucket ─

@test "_extract_items_by_state: DISMISSED items do not appear in ACTIONABLE_LATER bucket" {
  # Construct assessment content where a DISMISSED item immediately follows a LATER item.
  # The DISMISSED header must not appear in the extraction output.
  FILTERED_CONTENT="### Fix unquoted conflict-file list - ACTIONABLE_LATER
**Severity:** HIGH
**Reasoning:** Unquoted expansion splits on whitespace.
**Category:** correctness

### Static guard test is fragile - DISMISSED
**Severity:** LOW
**Reasoning:** This is a style preference.
**Category:** style"

  # Inline the awk extractor function (matches the implementation in assess-and-resolve.sh).
  # Use length(block) > 0 to avoid BSD awk locale bug with != on macOS.
  _extract_items_by_state() {
    local _state_pattern="$1"
    local _severity_pattern="$2"
    echo "$FILTERED_CONTENT" | awk -v states="$_state_pattern" -v sev="$_severity_pattern" '
      /^### .* - ACTIONABLE_/ {
        if (length(block) > 0 && block ~ sev) { print block; print "" }
        in_block = ($0 ~ states)
        block = in_block ? $0 : ""
        next
      }
      /^### / {
        if (length(block) > 0 && block ~ sev) { print block; print "" }
        in_block = 0; block = ""; next
      }
      in_block { block = block "\n" $0 }
      END { if (length(block) > 0 && block ~ sev) { print block; print "" } }
    ' || true
  }

  HIGH_ISSUES=$(_extract_items_by_state "ACTIONABLE_LATER" "Severity:.*HIGH")

  # Must contain the LATER item
  [[ "$HIGH_ISSUES" == *"Fix unquoted conflict-file list"* ]] || {
    echo "FAIL: Expected ACTIONABLE_LATER HIGH item in output, got:"
    echo "$HIGH_ISSUES"
    false
  }

  # Must NOT contain the DISMISSED item header
  [[ "$HIGH_ISSUES" != *"DISMISSED"* ]] || {
    echo "FAIL: DISMISSED item leaked into HIGH_ISSUES bucket:"
    echo "$HIGH_ISSUES"
    false
  }

  # Must NOT contain the DISMISSED item title
  [[ "$HIGH_ISSUES" != *"Static guard test is fragile"* ]] || {
    echo "FAIL: DISMISSED item content leaked into HIGH_ISSUES bucket:"
    echo "$HIGH_ISSUES"
    false
  }
}

# ─── Test 3: Unit — awk extractor correctly handles adjacent items ─────────────

@test "_extract_items_by_state: extracts HIGH LATER item adjacent to DISMISSED without spill" {
  # Three-item assessment: LATER HIGH → DISMISSED LOW → LATER MEDIUM
  # The HIGH bucket should contain only the first item.
  FILTERED_CONTENT="### First finding is HIGH - ACTIONABLE_LATER
**Severity:** HIGH
**Reasoning:** Real correctness bug.

### Nit about variable names - DISMISSED
**Severity:** LOW
**Reasoning:** Style preference.

### Second MEDIUM finding - ACTIONABLE_LATER
**Severity:** MEDIUM
**Reasoning:** Worth tracking."

  _extract_items_by_state() {
    local _state_pattern="$1"
    local _severity_pattern="$2"
    echo "$FILTERED_CONTENT" | awk -v states="$_state_pattern" -v sev="$_severity_pattern" '
      /^### .* - ACTIONABLE_/ {
        if (length(block) > 0 && block ~ sev) { print block; print "" }
        in_block = ($0 ~ states)
        block = in_block ? $0 : ""
        next
      }
      /^### / {
        if (length(block) > 0 && block ~ sev) { print block; print "" }
        in_block = 0; block = ""; next
      }
      in_block { block = block "\n" $0 }
      END { if (length(block) > 0 && block ~ sev) { print block; print "" } }
    ' || true
  }

  HIGH_ISSUES=$(_extract_items_by_state "ACTIONABLE_LATER" "Severity:.*HIGH")
  MEDIUM_ISSUES=$(_extract_items_by_state "ACTIONABLE_LATER" "Severity:.*MEDIUM")

  # HIGH bucket: first item only
  [[ "$HIGH_ISSUES" == *"First finding is HIGH"* ]] || {
    echo "FAIL: Expected HIGH finding in HIGH_ISSUES, got: $HIGH_ISSUES"
    false
  }
  [[ "$HIGH_ISSUES" != *"Nit about variable names"* ]] || {
    echo "FAIL: DISMISSED item leaked into HIGH_ISSUES: $HIGH_ISSUES"
    false
  }
  [[ "$HIGH_ISSUES" != *"Second MEDIUM finding"* ]] || {
    echo "FAIL: MEDIUM item leaked into HIGH_ISSUES: $HIGH_ISSUES"
    false
  }

  # MEDIUM bucket: second LATER item only
  [[ "$MEDIUM_ISSUES" == *"Second MEDIUM finding"* ]] || {
    echo "FAIL: Expected MEDIUM finding in MEDIUM_ISSUES, got: $MEDIUM_ISSUES"
    false
  }
  [[ "$MEDIUM_ISSUES" != *"Nit about variable names"* ]] || {
    echo "FAIL: DISMISSED item leaked into MEDIUM_ISSUES: $MEDIUM_ISSUES"
    false
  }
}

# ─── Test 4: Unit — awk extractor handles NOW items without spilling ───────────

@test "_extract_items_by_state: NOW items isolated from DISMISSED in combined NOW|LATER mode" {
  FILTERED_CONTENT="### NOW bug to fix immediately - ACTIONABLE_NOW
**Severity:** CRITICAL
**Reasoning:** Must fix now.

### Cosmetic naming nit - DISMISSED
**Severity:** LOW
**Reasoning:** Style only."

  _extract_items_by_state() {
    local _state_pattern="$1"
    local _severity_pattern="$2"
    echo "$FILTERED_CONTENT" | awk -v states="$_state_pattern" -v sev="$_severity_pattern" '
      /^### .* - ACTIONABLE_/ {
        if (length(block) > 0 && block ~ sev) { print block; print "" }
        in_block = ($0 ~ states)
        block = in_block ? $0 : ""
        next
      }
      /^### / {
        if (length(block) > 0 && block ~ sev) { print block; print "" }
        in_block = 0; block = ""; next
      }
      in_block { block = block "\n" $0 }
      END { if (length(block) > 0 && block ~ sev) { print block; print "" } }
    ' || true
  }

  CRITICAL_ISSUES=$(_extract_items_by_state "ACTIONABLE_(NOW|LATER)" "Severity:.*CRITICAL")

  [[ "$CRITICAL_ISSUES" == *"NOW bug to fix immediately"* ]] || {
    echo "FAIL: Expected CRITICAL NOW item, got: $CRITICAL_ISSUES"
    false
  }
  [[ "$CRITICAL_ISSUES" != *"DISMISSED"* ]] || {
    echo "FAIL: DISMISSED header leaked into CRITICAL_ISSUES: $CRITICAL_ISSUES"
    false
  }
  [[ "$CRITICAL_ISSUES" != *"Cosmetic naming nit"* ]] || {
    echo "FAIL: DISMISSED item content leaked into CRITICAL_ISSUES: $CRITICAL_ISSUES"
    false
  }
}

# ─── Test 5: Static — assess-review-issues.sh adds priority label ─────────────

@test "assess-review-issues.sh: per-item issues include a priority label" {
  # Defect #4 fix: priority label derived from ITEM_SEVERITY must be added
  # when creating per-item tech-debt issues.
  run grep -n 'priority_label\|priority-high\|priority-medium\|priority-low' "$ASSESS_REVIEW_SCRIPT"

  [ "$status" -eq 0 ] || {
    echo "FAIL: No priority label handling found in $ASSESS_REVIEW_SCRIPT"
    echo "Expected: _priority_label assignment and --label usage near gh issue create"
    false
  }

  # Verify the gh issue create call includes --label "$_priority_label"
  run grep -n 'label.*_priority_label\|_priority_label.*label' "$ASSESS_REVIEW_SCRIPT"

  [ "$status" -eq 0 ] || {
    echo "FAIL: gh issue create does not pass priority label in $ASSESS_REVIEW_SCRIPT"
    echo "Output: $output"
    false
  }
}
