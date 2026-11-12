#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/core/assess-review-issues.sh, lib/core/promote-branch.sh
#
# Regression tests for #1548: security findings routed to priority-high
# Extended by #1562: promote-path follow-up issues also route through _resolve_issue_labels
#
# Category=Security forces priority-high (floor) and adds the "security" label
# regardless of the raw severity. MEDIUM/LOW Security findings are elevated;
# CRITICAL/HIGH stay high. Non-Security categories are unchanged.
#
# Tests:
#   1. Unit: Security/MEDIUM → priority-high + security label (floor case)
#   2. Unit: Security/LOW    → priority-high + security label (floor case)
#   3. Unit: Security/HIGH   → priority-high + security label (already high)
#   4. Unit: Performance/MEDIUM → priority-medium (non-Security unchanged)
#   5. Unit: UX/LOW → priority-low (non-Security unchanged)
#   6. Unit: multi-part base label (tech-debt,from-review) + Security/MEDIUM → correct string
#   7. Unit: compound category "Security / Input Validation" fires security floor
#   8. Static: assess-review-issues.sh calls _resolve_issue_labels for the per-item path
#   9. Static: assess-and-resolve.sh calls _resolve_issue_labels for the rollup path
#  10. Static: promote-branch.sh NOW aggregate path routes through _resolve_issue_labels
#  11. Static: promote-branch.sh fallback unassessed path routes through _resolve_issue_labels
#  12. Static: promote-branch.sh fallback has JSON-block second-pass detection
#  13. Unit: fallback JSON-only Security item sets _promo_fb_sec_cat to "Security"

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export ASSESS_RESOLVE_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
  export ASSESS_REVIEW_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"
  export PROMOTE_SCRIPT="${RITE_REPO_ROOT}/lib/core/promote-branch.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: source assess-and-resolve.sh functions-only and call _resolve_issue_labels.
# Usage: _call_resolve_issue_labels "<base>" "<severity>" "<category>"
# Prints the result label string to stdout.
# ---------------------------------------------------------------------------
_run_resolve() {
  local _base="$1" _sev="$2" _cat="$3"
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${RITE_REPO_ROOT}/lib'
    export RITE_PROJECT_ROOT='${RITE_REPO_ROOT}'
    print_info()    { :; }
    print_warning() { :; }
    print_success() { :; }
    print_error()   { :; }
    verbose_info()  { :; }
    _diag()         { :; }
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh'
    _resolve_issue_labels '${_base}' '${_sev}' '${_cat}'
  "
}

# ─── Test 1: Security/MEDIUM → priority-high + security label ────────────────

@test "_resolve_issue_labels: Security/MEDIUM is elevated to priority-high with security label" {
  _run_resolve "tech-debt" "MEDIUM" "Security"
  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status): $output"
    false
  }
  [ "$output" = "tech-debt,priority-high,security" ] || {
    echo "FAIL: expected 'tech-debt,priority-high,security', got: '$output'"
    false
  }
}

# ─── Test 2: Security/LOW → priority-high + security label ───────────────────

@test "_resolve_issue_labels: Security/LOW is elevated to priority-high with security label" {
  _run_resolve "tech-debt" "LOW" "Security"
  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status): $output"
    false
  }
  [ "$output" = "tech-debt,priority-high,security" ] || {
    echo "FAIL: expected 'tech-debt,priority-high,security', got: '$output'"
    false
  }
}

# ─── Test 3: Security/HIGH → already-high, still adds security label ─────────

@test "_resolve_issue_labels: Security/HIGH stays priority-high and adds security label" {
  _run_resolve "tech-debt" "HIGH" "Security"
  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status): $output"
    false
  }
  [ "$output" = "tech-debt,priority-high,security" ] || {
    echo "FAIL: expected 'tech-debt,priority-high,security', got: '$output'"
    false
  }
}

# ─── Test 4: Non-Security/MEDIUM unchanged ────────────────────────────────────

@test "_resolve_issue_labels: Performance/MEDIUM produces priority-medium (non-Security unchanged)" {
  _run_resolve "tech-debt" "MEDIUM" "Performance"
  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status): $output"
    false
  }
  [ "$output" = "tech-debt,priority-medium" ] || {
    echo "FAIL: expected 'tech-debt,priority-medium', got: '$output'"
    false
  }
}

# ─── Test 5: Non-Security/LOW unchanged ──────────────────────────────────────

@test "_resolve_issue_labels: UX/LOW produces priority-low (non-Security unchanged)" {
  _run_resolve "tech-debt" "LOW" "UX"
  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status): $output"
    false
  }
  [ "$output" = "tech-debt,priority-low" ] || {
    echo "FAIL: expected 'tech-debt,priority-low', got: '$output'"
    false
  }
}

# ─── Test 6: Multi-part base label + Security/MEDIUM ─────────────────────────

@test "_resolve_issue_labels: multi-part base (tech-debt,from-review) + Security/MEDIUM → correct string" {
  # assess-review-issues.sh passes "tech-debt,from-review" as the base.
  _run_resolve "tech-debt,from-review" "MEDIUM" "Security"
  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status): $output"
    false
  }
  [ "$output" = "tech-debt,from-review,priority-high,security" ] || {
    echo "FAIL: expected 'tech-debt,from-review,priority-high,security', got: '$output'"
    false
  }
}

# ─── Test 7: Compound category "Security / Input Validation" still fires floor ─

@test "_resolve_issue_labels: compound category 'Security / Input Validation' fires security floor" {
  # Regression: word-boundary pattern must match "security" within a compound
  # category like "Security / Input Validation", not just bare "Security".
  _run_resolve "tech-debt" "MEDIUM" "Security / Input Validation"
  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status): $output"
    false
  }
  [ "$output" = "tech-debt,priority-high,security" ] || {
    echo "FAIL: expected 'tech-debt,priority-high,security', got: '$output'"
    false
  }
}

# ─── Test 9: Static — assess-review-issues.sh uses _resolve_issue_labels ─────

@test "assess-review-issues.sh: per-item creation calls _resolve_issue_labels" {
  # Structural pin: the per-item ACTIONABLE_LATER creation path must use
  # _resolve_issue_labels (not the old inline severity-only case statement).
  # Grep for the assignment expression to avoid matching the comment that names it.
  run grep -n -E '_item_labels=\$\(_resolve_issue_labels' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: _item_labels=\$(_resolve_issue_labels ...) not found in $ASSESS_REVIEW_SCRIPT"
    echo "Expected: _item_labels=\$(_resolve_issue_labels ...)"
    false
  }
}

# ─── Test 10: Static — assess-and-resolve.sh uses _resolve_issue_labels ────────

@test "assess-and-resolve.sh: per-finding creation calls _resolve_issue_labels" {
  # Structural pin: the rollup per-finding loop must use _resolve_issue_labels
  # (not the old two-line _resolve_priority_label + string concat).
  # Grep for the assignment expression to avoid matching the function definition comment.
  run grep -n -E '_finding_labels=\$\(_resolve_issue_labels' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: _finding_labels=\$(_resolve_issue_labels ...) not found in $ASSESS_RESOLVE_SCRIPT"
    echo "Expected: _finding_labels=\$(_resolve_issue_labels ...)"
    false
  }
}

# ─── Test 11: Static — promote-branch.sh NOW path uses _resolve_issue_labels ──

@test "promote-branch.sh: assessed NOW aggregate path routes through _resolve_issue_labels" {
  # Structural pin: the NOW aggregate issue creation must derive labels via
  # _resolve_issue_labels (not hardcoded "from-review" + "tech-debt" strings).
  # This guards against regression where security findings in a promotion review
  # would be filed without the security label and priority-high (#1562).
  run grep -n -E '_promo_now_labels=\$\(_resolve_issue_labels' "$PROMOTE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: _promo_now_labels=\$(_resolve_issue_labels ...) not found in $PROMOTE_SCRIPT"
    echo "Expected: _promo_now_labels=\$(_resolve_issue_labels ...)"
    false
  }
}

# ─── Test 12: Static — promote-branch.sh fallback path uses _resolve_issue_labels ─

@test "promote-branch.sh: fallback unassessed path routes through _resolve_issue_labels" {
  # Structural pin: the fallback (unassessed) issue creation must derive labels via
  # _resolve_issue_labels so security findings in the raw review body still reach
  # priority-high + security label even when the assessor was unavailable (#1562).
  run grep -n -E '_promo_fb_labels=\$\(_resolve_issue_labels' "$PROMOTE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: _promo_fb_labels=\$(_resolve_issue_labels ...) not found in $PROMOTE_SCRIPT"
    echo "Expected: _promo_fb_labels=\$(_resolve_issue_labels ...)"
    false
  }
}

# ─── Test 12: Static — fallback has JSON-block second-pass detection ──────────

@test "promote-branch.sh: fallback has JSON-block second-pass security detection" {
  # Structural pin: the fallback security-category detection must include a second
  # pass that checks items[].category in the sharkrite-review-data JSON block when
  # the markdown **Category:** scan returns nothing (#1745). Without this pass,
  # MEDIUM/LOW security findings that only appear in the JSON block miss the floor.
  run grep -n 'RITE_MARKER_REVIEW_DATA' "$PROMOTE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: JSON-block second-pass detection code not found in $PROMOTE_SCRIPT"
    echo "Expected: sed -n \"/<!-- \${RITE_MARKER_REVIEW_DATA}/\" block after the markdown scan"
    false
  }
  # Verify the jq select((.category // "") ...) call is present in the fallback block.
  run grep -n 'select((.category // "")' "$PROMOTE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: jq select((.category // \"\") ...) not found in $PROMOTE_SCRIPT"
    echo "Expected a null-safe jq filter that checks items[].category for Security"
    false
  }
}

# ─── Test 13: Unit — JSON-only Security item fires detection ──────────────────

@test "promote-branch.sh fallback: JSON-only Security item sets sec_cat to Security" {
  # Verifies the JSON-block second pass: a review with no markdown **Category:**
  # line but with an items[].category="Security" JSON entry must produce
  # _promo_fb_sec_cat="Security" (#1745).
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  # Inline the detection logic from promote-branch.sh in a subshell.
  run bash -c '
    set -euo pipefail
    export RITE_MARKER_REVIEW_DATA="sharkrite-review-data"

    # Review body: no markdown **Category:** Security line, but JSON items[].category=Security
    _promo_review="## Code Review

Findings: CRITICAL: 0 | HIGH: 0 | MEDIUM: 1 | LOW: 0

#### 1. Unvalidated input passed to exec

**Severity:** MEDIUM

**Location:** lib/utils/foo.sh:42

<!-- sharkrite-review-data
{\"summary\":{\"critical\":0,\"high\":0,\"medium\":1,\"low\":0,\"verdict\":\"APPROVE_WITH_COMMENTS\"},\"items\":[{\"id\":1,\"severity\":\"MEDIUM\",\"category\":\"Security\",\"title\":\"Unvalidated input passed to exec\",\"file\":\"lib/utils/foo.sh\",\"line\":42,\"problem\":\"desc\",\"impact\":\"impact\",\"recommendation\":\"fix\"}],\"positive\":[]}
-->"

    # --- reproduce the two-stage detection from promote-branch.sh ---
    _promo_fb_sec_cat=""
    _promo_fb_sec_cat=$(echo "${_promo_review:-}" \
      | grep -iE "^\*\*Category:\*\*.*[Ss]ecurity" | head -1 \
      | sed "s/\*\*Category:\*\* *//" || true)

    if [ -z "${_promo_fb_sec_cat:-}" ] && command -v jq >/dev/null 2>&1; then
      _promo_fb_json=""
      _promo_fb_json=$(printf "%s" "${_promo_review:-}" \
        | sed -n "/<!-- ${RITE_MARKER_REVIEW_DATA}/,/-->/p" | sed "1d;\$d" || true)
      if [ -n "${_promo_fb_json:-}" ] && printf "%s" "${_promo_fb_json}" | jq empty 2>/dev/null; then
        if printf "%s" "${_promo_fb_json}" \
            | jq -e "[.items[]? | select((.category // \"\") | test(\"(?i)security\"))] | length > 0" \
            >/dev/null 2>&1; then
          _promo_fb_sec_cat="Security"
        fi
      fi
    fi

    echo "${_promo_fb_sec_cat:-}"
  '
  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status): $output"
    false
  }
  [ "$output" = "Security" ] || {
    echo "FAIL: expected 'Security', got: '$output'"
    false
  }
}

# ─── Test 14: Unit — null category field does not abort jq or mask Security ───

@test "promote-branch.sh fallback: null-category item does not mask Security item in same array" {
  # Regression guard for the null-category abort: a jq filter without (.category // "")
  # program-aborts on a null/missing category field, silently skipping ALL items in the
  # array including real Security ones. Verify that the fixed filter returns "Security"
  # even when one item in the array has no category field (#1745).
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  run bash -c '
    set -euo pipefail

    # Mixed array: first item has no category field, second has category=Security.
    _json="{\"items\":[{\"id\":1,\"severity\":\"LOW\",\"title\":\"style nit\"},{\"id\":2,\"severity\":\"MEDIUM\",\"category\":\"Security\",\"title\":\"Unvalidated input\"}]}"

    if printf "%s" "${_json}" \
        | jq -e "[.items[]? | select((.category // \"\") | test(\"(?i)security\"))] | length > 0" \
        >/dev/null 2>&1; then
      echo "Security"
    else
      echo ""
    fi
  '
  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status): $output"
    false
  }
  [ "$output" = "Security" ] || {
    echo "FAIL: expected 'Security', got: '$output'"
    echo "A null/missing category field aborted jq and masked the Security item"
    false
  }
}
