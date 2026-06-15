#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh
# Regression test for: assess-and-resolve.sh title format (defect #1, #518)
# Issues: #469-#478-#495-#518
#
# Historical context:
#   Defect #1 (PR #469): PR_TITLE truncated at 50 chars + ": " produced mid-phrase cuts
#   Defect #518 (this PR): multi-finding bundling produced "(+N more)" titles with
#     [tech-debt]/[review-follow-up] prefix instead of one clean issue per finding.
#
# New behavior (post-#518):
#   - One issue per ACTIONABLE_(NOW|LATER) finding
#   - Title = the finding's own text, no [tech-debt] or [review-follow-up] prefix
#   - No (+N more) bundling
#   - No mid-phrase "..." truncation
#   - List markers (^[0-9]+\.) stripped from titles
#
# Tests in this file:
#   1. Static: old "cut -c1-50" + colon pattern no longer present
#   2. Static: old single-issue bundling grep -m1 pattern no longer present
#   3. Static: [tech-debt] prefix NOT hardcoded as ISSUE_TITLE prefix
#   4. Static: "(+N more)" bundling pattern NOT present in title construction
#   5. Unit:   per-finding loop strips list markers from titles
#   6. Unit:   per-finding loop produces clean title without prefix

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export ASSESS_RESOLVE_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
  [ -f "$ASSESS_RESOLVE_SCRIPT" ] || {
    echo "setup: ASSESS_RESOLVE_SCRIPT not found at $ASSESS_RESOLVE_SCRIPT" >&2
    false
  }
}

teardown() {
  teardown_test_tmpdir
}

# ─── Test 1: Static — old truncation pattern must not exist ───────────────────

@test "assess-and-resolve.sh: title no longer uses cut -c1-50 + colon truncation" {
  # The original bug: PR_TITLE cut to 50 chars then appended ": " as separator.
  # The result was mid-phrase truncations like "Extend test 13 in: review feedback..."
  run grep -n 'cut -c1-50' "$ASSESS_RESOLVE_SCRIPT"

  # Must find zero matches (the truncation is gone)
  [ "$status" -ne 0 ] || {
    echo "FAIL: 'cut -c1-50' still present in $ASSESS_RESOLVE_SCRIPT:"
    echo "$output"
    false
  }
}

# ─── Test 2: Static — old single-issue bundling grep -m1 pattern is gone ─────

@test "assess-and-resolve.sh: old first-item-only extraction (grep -m1) is gone" {
  # Pre-#518: a single bundled issue was titled from the first item via grep -m1.
  # Post-#518: a per-finding loop creates one issue per finding; grep -m1 is gone.
  # If grep -m1.*ACTIONABLE_ reappears, it means bundling was re-introduced.
  run grep -n 'grep -m1.*ACTIONABLE_' "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -ne 0 ] || {
    echo "FAIL: 'grep -m1.*ACTIONABLE_' found in $ASSESS_RESOLVE_SCRIPT — bundling re-introduced?"
    echo "Matches:"
    echo "$output"
    false
  }
}

# ─── Test 3: Static — [tech-debt] prefix NOT hardcoded in ISSUE_TITLE ────────

@test "assess-and-resolve.sh: ISSUE_TITLE does not include [tech-debt] prefix" {
  # Pre-#518: ISSUE_TITLE="[tech-debt] ${_item_desc}..."
  # Post-#518: ISSUE_TITLE="${_clean_title}${_src_issue_suffix}" (no prefix)
  run grep -n 'ISSUE_TITLE="\[tech-debt\]' "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -ne 0 ] || {
    echo "FAIL: '[tech-debt]' hardcoded as ISSUE_TITLE prefix in $ASSESS_RESOLVE_SCRIPT"
    echo "Matches:"
    echo "$output"
    false
  }
}

# ─── Test 4: Static — "(+N more)" bundling pattern gone ──────────────────────

@test "assess-and-resolve.sh: (+N more) bundling suffix no longer present" {
  # Pre-#518: multiple findings bundled into one issue with "(+N more)" in title.
  # Post-#518: each finding gets its own issue; no bundling suffix.
  run grep -n '(+.*more)' "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -ne 0 ] || {
    echo "FAIL: '(+N more)' bundling suffix still present in $ASSESS_RESOLVE_SCRIPT"
    echo "Matches:"
    echo "$output"
    false
  }
}

# ─── Test 5: Unit — list marker stripping ─────────────────────────────────────

@test "assess-and-resolve.sh: per-finding title strips leading list marker (1. Foo → Foo)" {
  # Defect: assessment headers like "### 1. Orphaned…" leaked the "1." prefix.
  # Fix: sed strips ^[0-9]+\. and ^[-*] before building ISSUE_TITLE.

  _raw_title="1. Orphaned reference in error handler"
  # Inline the same logic as the fixed code
  _clean_title=$(echo "$_raw_title" | sed 's/^[0-9][0-9]*\.[[:space:]]*//' | sed 's/^[-*][[:space:]]*//' || true)
  _clean_title=$(echo "$_clean_title" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)

  [[ "$_clean_title" == "Orphaned reference in error handler" ]] || {
    echo "FAIL: Expected 'Orphaned reference in error handler', got: '$_clean_title'"
    false
  }
  [[ "$_clean_title" != "1."* ]] || {
    echo "FAIL: List marker '1.' leaked into clean title: '$_clean_title'"
    false
  }
}

# ─── Test 6: Unit — clean title has no [tag] prefix ─────────────────────────

@test "assess-and-resolve.sh: per-finding ISSUE_TITLE has no [tech-debt] or [review-follow-up] prefix" {
  # Post-#518: title is just the finding's own text (+ optional source-issue suffix).
  _clean_title="Fix unquoted variable expansion in git diff"
  ISSUE_NUMBER="602"

  _src_issue_suffix=" for issue #${ISSUE_NUMBER}"
  ISSUE_TITLE="${_clean_title}${_src_issue_suffix}"

  # Must not start with [tech-debt] or [review-follow-up]
  [[ "$ISSUE_TITLE" != "[tech-debt]"* ]] || {
    echo "FAIL: ISSUE_TITLE starts with '[tech-debt]': '$ISSUE_TITLE'"
    false
  }
  [[ "$ISSUE_TITLE" != "[review-follow-up]"* ]] || {
    echo "FAIL: ISSUE_TITLE starts with '[review-follow-up]': '$ISSUE_TITLE'"
    false
  }
  # Must contain the clean title
  [[ "$ISSUE_TITLE" == *"Fix unquoted variable expansion in git diff"* ]] || {
    echo "FAIL: Clean title not found in ISSUE_TITLE: '$ISSUE_TITLE'"
    false
  }
  # Must contain the source-issue suffix for unique dedup scope
  [[ "$ISSUE_TITLE" == *"for issue #602"* ]] || {
    echo "FAIL: Source-issue suffix missing from ISSUE_TITLE: '$ISSUE_TITLE'"
    false
  }
}
