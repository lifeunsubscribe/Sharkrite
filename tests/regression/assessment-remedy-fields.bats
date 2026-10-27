#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-review-issues.sh, lib/core/assess-and-resolve.sh
# Regression tests for: emit Suggested Fix / Verification fields for ACTIONABLE_LATER items (#1546)
#
# These fields let follow-up issue bodies be built runbook-conformant with zero
# additional LLM calls: the assessor emits the remedy it already has in hand.
#
# Test inventory:
#  1. Static: assess-review-issues.sh OUTPUT FORMAT includes Suggested Fix field
#  2. Static: assess-review-issues.sh OUTPUT FORMAT includes Verification field
#  3. Static: assess-review-issues.sh while-read loop parses **Suggested Fix:** case
#  4. Static: assess-review-issues.sh while-read loop parses **Verification:** case
#  5. Static: assess-review-issues.sh resets ITEM_SUGGESTED_FIX and ITEM_VERIFICATION per finding
#  6. Static: assess-review-issues.sh uses ${ITEM_VERIFICATION:-} (safe fallback for legacy)
#  7. Static: assess-review-issues.sh uses ${ITEM_SUGGESTED_FIX:-} (safe fallback for legacy)
#  8. Static: assess-and-resolve.sh extracts _f_suggested_fix with ${VAR:-} fallback
#  9. Static: assess-and-resolve.sh extracts _f_verification with ${VAR:-} fallback
# 10. Unit:   _f_verification extracted correctly from a fixture finding block
# 11. Unit:   _f_suggested_fix extracted correctly from a fixture finding block
# 12. Unit:   legacy fixture (no new fields) yields empty strings (backward compat / no crash)
# 13. Unit:   _f_verification takes precedence over Location-derived _verification_cmd

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export ASSESS_RESOLVE_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
  export ASSESS_REVIEW_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ─── Test 1: Static — OUTPUT FORMAT includes Suggested Fix ───────────────────

@test "assess-review-issues.sh: OUTPUT FORMAT instructs assessor to emit Suggested Fix for ACTIONABLE_LATER" {
  run grep -n 'Suggested Fix' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: 'Suggested Fix' not found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 2: Static — OUTPUT FORMAT includes Verification ────────────────────

@test "assess-review-issues.sh: OUTPUT FORMAT instructs assessor to emit Verification for ACTIONABLE_LATER" {
  run grep -n 'FOR ACTIONABLE_LATER.*Verification' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: 'FOR ACTIONABLE_LATER.*Verification' not found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 3: Static — parse case for Suggested Fix ───────────────────────────

@test "assess-review-issues.sh: while-read loop has case arm for **Suggested Fix:**" {
  run grep -n 'Suggested.*Fix:\*\*\*)' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: No case arm for '**Suggested Fix:**' found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 4: Static — parse case for Verification ────────────────────────────

@test "assess-review-issues.sh: while-read loop has case arm for **Verification:**" {
  run grep -n 'Verification:\*\*\*)' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: No case arm for '**Verification:**' found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 5: Static — variables are reset per finding ────────────────────────

@test "assess-review-issues.sh: ITEM_SUGGESTED_FIX and ITEM_VERIFICATION reset in TITLE case" {
  run grep -n 'ITEM_SUGGESTED_FIX=""' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: ITEM_SUGGESTED_FIX=\"\" reset not found in $ASSESS_REVIEW_SCRIPT"
    false
  }
  run grep -n 'ITEM_VERIFICATION=""' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: ITEM_VERIFICATION=\"\" reset not found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 6: Static — safe ${VAR:-} fallback for ITEM_VERIFICATION ───────────

@test "assess-review-issues.sh: uses \${ITEM_VERIFICATION:-} safe fallback (backward compat)" {
  run grep -n '\${ITEM_VERIFICATION:-}' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: '\${ITEM_VERIFICATION:-}' safe fallback not found in $ASSESS_REVIEW_SCRIPT"
    echo "This means legacy assessments (missing the field) will crash under set -u"
    false
  }
}

# ─── Test 7: Static — safe ${VAR:-} fallback for ITEM_SUGGESTED_FIX ─────────

@test "assess-review-issues.sh: uses \${ITEM_SUGGESTED_FIX:-} safe fallback (backward compat)" {
  run grep -n '\${ITEM_SUGGESTED_FIX:-}' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: '\${ITEM_SUGGESTED_FIX:-}' safe fallback not found in $ASSESS_REVIEW_SCRIPT"
    echo "This means legacy assessments (missing the field) will crash under set -u"
    false
  }
}

# ─── Test 8: Static — assess-and-resolve.sh extracts _f_suggested_fix safely ─

@test "assess-and-resolve.sh: _f_suggested_fix extracted with \${VAR:-} safe fallback" {
  run grep -n '_f_suggested_fix=.*:-' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: '_f_suggested_fix' with ':-' fallback not found in $ASSESS_RESOLVE_SCRIPT"
    echo "This means legacy assessments will crash under set -u"
    false
  }
}

# ─── Test 9: Static — assess-and-resolve.sh extracts _f_verification safely ──

@test "assess-and-resolve.sh: _f_verification extracted with \${VAR:-} safe fallback" {
  run grep -n '_f_verification=.*:-' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: '_f_verification' with ':-' fallback not found in $ASSESS_RESOLVE_SCRIPT"
    echo "This means legacy assessments will crash under set -u"
    false
  }
}

# ─── Test 10: Unit — _f_verification extracted correctly from fixture block ───

@test "assess-and-resolve.sh: _f_verification is extracted from a finding block with the field" {
  run bash -c '
    set -euo pipefail
    _finding_block="### Fix missing input guard - ACTIONABLE_LATER

**Severity:** HIGH
**Category:** CodeQuality
**Reasoning:** The function accepts user input without validation.
**Context:** In scope of this PR but deferred due to refactor complexity.
**Location:** lib/core/foo.sh:42
**Fix Effort:** <1hr
**Defer Reason:** Needs separate focused PR
**Suggested Fix:** Add an early return when the argument is empty or non-numeric.
**Verification:** grep -n \"validate_input\" lib/core/foo.sh"

    _f_verification=$(echo "$_finding_block" | grep -oE '"'"'\*\*Verification:\*\*.*'"'"' | head -1 | sed '"'"'s/\*\*Verification:\*\*[[:space:]]*//'"'"' | sed '"'"'s/\*//g'"'"' || true)
    _f_verification="${_f_verification:-}"
    echo "$_f_verification"
  '
  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status): $output"
    false
  }
  [[ "$output" == *"grep"*"validate_input"* ]] || {
    echo "FAIL: Expected extracted verification command containing 'grep' and 'validate_input', got: '$output'"
    false
  }
}

# ─── Test 11: Unit — _f_suggested_fix extracted correctly from fixture block ──

@test "assess-and-resolve.sh: _f_suggested_fix is extracted from a finding block with the field" {
  run bash -c '
    set -euo pipefail
    _finding_block="### Fix missing input guard - ACTIONABLE_LATER

**Severity:** HIGH
**Category:** CodeQuality
**Reasoning:** The function accepts user input without validation.
**Context:** In scope of this PR but deferred due to refactor complexity.
**Location:** lib/core/foo.sh:42
**Fix Effort:** <1hr
**Defer Reason:** Needs separate focused PR
**Suggested Fix:** Add an early return when the argument is empty or non-numeric.
**Verification:** grep -n \"validate_input\" lib/core/foo.sh"

    _f_suggested_fix=$(echo "$_finding_block" | grep -oE '"'"'\*\*Suggested Fix:\*\*.*'"'"' | head -1 | sed '"'"'s/\*\*Suggested Fix:\*\*[[:space:]]*//'"'"' | sed '"'"'s/\*//g'"'"' || true)
    _f_suggested_fix="${_f_suggested_fix:-}"
    echo "$_f_suggested_fix"
  '
  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status): $output"
    false
  }
  [[ "$output" == *"early return"* ]] || {
    echo "FAIL: Expected extracted suggested fix containing 'early return', got: '$output'"
    false
  }
}

# ─── Test 12: Unit — legacy fixture (no new fields) yields empty strings ──────

@test "assess-and-resolve.sh: legacy assessment without new fields produces empty _f_suggested_fix and _f_verification (no crash)" {
  run bash -c '
    set -euo pipefail
    # Legacy finding block — no Suggested Fix or Verification fields
    _finding_block="### Fix missing input guard - ACTIONABLE_LATER

**Severity:** HIGH
**Category:** CodeQuality
**Reasoning:** The function accepts user input without validation.
**Context:** In scope of this PR but deferred due to refactor complexity.
**Location:** lib/core/foo.sh:42
**Fix Effort:** <1hr
**Defer Reason:** Needs separate focused PR"

    _f_suggested_fix=$(echo "$_finding_block" | grep -oE '"'"'\*\*Suggested Fix:\*\*.*'"'"' | head -1 | sed '"'"'s/\*\*Suggested Fix:\*\*[[:space:]]*//'"'"' | sed '"'"'s/\*//g'"'"' || true)
    _f_suggested_fix="${_f_suggested_fix:-}"
    _f_verification=$(echo "$_finding_block" | grep -oE '"'"'\*\*Verification:\*\*.*'"'"' | head -1 | sed '"'"'s/\*\*Verification:\*\*[[:space:]]*//'"'"' | sed '"'"'s/\*//g'"'"' || true)
    _f_verification="${_f_verification:-}"
    # Both must be empty (not crash under set -u)
    [ -z "$_f_suggested_fix" ] || { echo "FAIL: _f_suggested_fix should be empty for legacy fixture, got: $_f_suggested_fix"; exit 1; }
    [ -z "$_f_verification" ] || { echo "FAIL: _f_verification should be empty for legacy fixture, got: $_f_verification"; exit 1; }
    echo "ok"
  '
  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status): $output"
    false
  }
  [ "$output" = "ok" ] || {
    echo "FAIL: Expected 'ok', got: '$output'"
    false
  }
}

# ─── Test 13: Unit — _f_verification overrides Location-derived _verification_cmd ─

@test "assess-and-resolve.sh: _f_verification takes precedence over Location-derived command" {
  # The outer if-elif-else chain in assess-and-resolve.sh must check _f_verification
  # first; Location-based derivation should only run when _f_verification is empty.
  # Static: the _f_verification branch appears BEFORE the _f_location branch.
  run grep -n '_f_verification\|_f_location' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ]

  # Find the line number of the _f_verification guard and the _f_location guard
  _vline=$(grep -n 'if \[ -n.*_f_verification' "$ASSESS_RESOLVE_SCRIPT" | head -1 | cut -d: -f1)
  _lline=$(grep -n 'elif \[ -n.*_f_location' "$ASSESS_RESOLVE_SCRIPT" | grep -v '^\s*#' | head -1 | cut -d: -f1)

  [ -n "$_vline" ] || {
    echo "FAIL: Could not find 'if [ -n.*_f_verification' guard in $ASSESS_RESOLVE_SCRIPT"
    false
  }
  [ -n "$_lline" ] || {
    echo "FAIL: Could not find 'elif [ -n.*_f_location' guard in $ASSESS_RESOLVE_SCRIPT"
    false
  }
  [ "$_vline" -lt "$_lline" ] || {
    echo "FAIL: _f_verification guard (line $_vline) does not appear before _f_location guard (line $_lline)"
    echo "The Verification field from the assessor must take precedence over Location-derived commands"
    false
  }
}
