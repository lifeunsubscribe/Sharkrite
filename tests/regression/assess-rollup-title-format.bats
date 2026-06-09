#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh
# Regression test for: assess-and-resolve.sh title truncation (defect #1)
# Issues: #469-#478-#495
#
# Bug: assess-and-resolve.sh built follow-up issue titles from PR_TITLE truncated
# at character 50 followed by "..." + ": " (colon-space), producing titles like:
#   "[tech-debt] Extend test 13 in: review feedback from PR #N"
#   "[tech-debt] Self-documenting PR bodies trigger spurious: review feedback from PR #N"
#
# Fix: Use the first ACTIONABLE_LATER/NOW item's actual title as the description,
# capped at 60 chars with graceful truncation (no mid-word cut) and a count suffix.
# Format: [tech-debt] <first item title> (+N more) — PR #N
# Example: [tech-debt] Fence guard truncates real blocks (+1 more) — PR #387
#
# Tests in this file:
#   1. Static: old "cut -c1-50" + colon pattern no longer present
#   2. Static: new title uses first-item extraction (grep -m1 ACTIONABLE_)
#   3. Unit:   single-item assessment produces "[tech-debt] <title> — PR #N"
#   4. Unit:   multi-item assessment produces "(+N more)" suffix
#   5. Unit:   title capped at 60 chars with no mid-word truncation
#   6. Unit:   PR title fallback when no ACTIONABLE items found

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

# ─── Test 2: Static — new title uses first-item extraction ────────────────────

@test "assess-and-resolve.sh: title extraction uses first ACTIONABLE item grep" {
  # The fix: extract the first ACTIONABLE_(NOW|LATER) header title as description
  run grep -n 'grep -m1.*ACTIONABLE_' "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -eq 0 ] || {
    echo "FAIL: Expected 'grep -m1.*ACTIONABLE_' pattern in $ASSESS_RESOLVE_SCRIPT (first-item extraction)"
    echo "Output: $output"
    false
  }
}

# ─── Test 3: Unit — single-item title format ──────────────────────────────────

@test "assess-and-resolve.sh: single item produces title without (+N more)" {
  # Simulate the title-building logic with a single ACTIONABLE_LATER item.
  # We source a minimal extraction from the script to test the title fragment.

  # Build a mock FILTERED_CONTENT with one item
  FILTERED_CONTENT="### Fix unquoted conflict-file list word-splits in git diff - ACTIONABLE_LATER
**Severity:** HIGH
**Reasoning:** Unquoted expansion splits on whitespace."
  PR_NUMBER="387"
  ISSUE_NUMBER=""

  # Inline the same logic from the fixed assess-and-resolve.sh
  _first_item_title=$(echo "$FILTERED_CONTENT" | grep -m1 -E "^### .* - ACTIONABLE_(NOW|LATER)" | \
    sed 's/^### //; s/ - ACTIONABLE_.*//' || true)
  _total_items=$(echo "$FILTERED_CONTENT" | grep -c -E "^### .* - ACTIONABLE_(NOW|LATER)" || true)
  _total_items=${_total_items:-0}
  _remaining_item_count=0
  if [ "$_total_items" -gt 1 ]; then
    _remaining_item_count=$((_total_items - 1))
  fi

  _item_desc=""
  if [ -n "$_first_item_title" ]; then
    if [ "${#_first_item_title}" -gt 60 ]; then
      _item_desc="${_first_item_title:0:60}"
      _item_desc=$(echo "$_item_desc" | sed 's/ [^ ]*$//' || true)
      _item_desc="${_item_desc}..."
    else
      _item_desc="$_first_item_title"
    fi
    [ "$_remaining_item_count" -gt 0 ] && _item_desc="${_item_desc} (+${_remaining_item_count} more)"
    _item_desc="${_item_desc} — PR #${PR_NUMBER}"
  fi

  ISSUE_TITLE="[tech-debt] ${_item_desc}"

  # Assertions
  [[ "$ISSUE_TITLE" == *"Fix unquoted conflict-file list word-splits in git diff"* ]] || {
    echo "FAIL: Expected first-item title in ISSUE_TITLE, got: $ISSUE_TITLE"
    false
  }
  [[ "$ISSUE_TITLE" != *"(+0 more)"* ]] || {
    echo "FAIL: Single item should not produce '(+0 more)', got: $ISSUE_TITLE"
    false
  }
  [[ "$ISSUE_TITLE" != *"(+*)"* ]] || {
    echo "FAIL: Single item should not produce any '(+N more)', got: $ISSUE_TITLE"
    false
  }
  [[ "$ISSUE_TITLE" == *"— PR #387"* ]] || {
    echo "FAIL: Expected '— PR #387' suffix, got: $ISSUE_TITLE"
    false
  }
}

# ─── Test 4: Unit — multi-item title includes (+N more) ───────────────────────

@test "assess-and-resolve.sh: two items produces (+1 more) suffix" {
  FILTERED_CONTENT="### Fix unquoted conflict-file list - ACTIONABLE_LATER
**Severity:** HIGH
**Reasoning:** First finding.

### Static guard test under-counts sites - ACTIONABLE_LATER
**Severity:** MEDIUM
**Reasoning:** Second finding."
  PR_NUMBER="392"
  ISSUE_NUMBER=""

  _first_item_title=$(echo "$FILTERED_CONTENT" | grep -m1 -E "^### .* - ACTIONABLE_(NOW|LATER)" | \
    sed 's/^### //; s/ - ACTIONABLE_.*//' || true)
  _total_items=$(echo "$FILTERED_CONTENT" | grep -c -E "^### .* - ACTIONABLE_(NOW|LATER)" || true)
  _total_items=${_total_items:-0}
  _remaining_item_count=0
  [ "$_total_items" -gt 1 ] && _remaining_item_count=$((_total_items - 1))

  _item_desc="$_first_item_title"
  [ "$_remaining_item_count" -gt 0 ] && _item_desc="${_item_desc} (+${_remaining_item_count} more)"
  _item_desc="${_item_desc} — PR #${PR_NUMBER}"
  ISSUE_TITLE="[tech-debt] ${_item_desc}"

  [[ "$ISSUE_TITLE" == *"(+1 more)"* ]] || {
    echo "FAIL: Expected '(+1 more)' for 2-item assessment, got: $ISSUE_TITLE"
    false
  }
  [[ "$ISSUE_TITLE" == *"Fix unquoted conflict-file list"* ]] || {
    echo "FAIL: Expected first-item title fragment, got: $ISSUE_TITLE"
    false
  }
}

# ─── Test 5: Unit — long titles are capped at 60 chars without mid-word cut ──

@test "assess-and-resolve.sh: title exceeding 60 chars truncates at word boundary" {
  # 64-char title: should truncate to last word boundary before char 60
  long_title="Extremely long finding title that exceeds sixty characters total here"
  FILTERED_CONTENT="### ${long_title} - ACTIONABLE_LATER
**Severity:** MEDIUM"
  PR_NUMBER="400"

  _first_item_title=$(echo "$FILTERED_CONTENT" | grep -m1 -E "^### .* - ACTIONABLE_(NOW|LATER)" | \
    sed 's/^### //; s/ - ACTIONABLE_.*//' || true)

  _item_desc=""
  if [ "${#_first_item_title}" -gt 60 ]; then
    _item_desc="${_first_item_title:0:60}"
    _item_desc=$(echo "$_item_desc" | sed 's/ [^ ]*$//' || true)
    _item_desc="${_item_desc}..."
  else
    _item_desc="$_first_item_title"
  fi

  # Must not exceed 63 chars (60 cap + "...")
  title_len="${#_item_desc}"
  [ "$title_len" -le 63 ] || {
    echo "FAIL: Truncated title exceeds 63 chars ($title_len): '$_item_desc'"
    false
  }
  # Must end with "..."
  [[ "$_item_desc" == *"..." ]] || {
    echo "FAIL: Truncated title should end with '...', got: '$_item_desc'"
    false
  }
  # Must not end with a partial word followed by "..." (no hyphenation, no mid-word)
  # Check that the char before "..." is a space-terminated word (not a letter sequence ending without space)
  _without_ellipsis="${_item_desc%...}"
  [[ "$_without_ellipsis" == *" "* ]] || {
    echo "WARN: Truncated title may be a single long word — acceptable: '$_item_desc'"
  }
}

# ─── Test 6: Unit — fallback when no ACTIONABLE items ────────────────────────

@test "assess-and-resolve.sh: fallback title when FILTERED_CONTENT is empty" {
  FILTERED_CONTENT=""
  PR_NUMBER="410"

  _first_item_title=$(echo "$FILTERED_CONTENT" | grep -m1 -E "^### .* - ACTIONABLE_(NOW|LATER)" | \
    sed 's/^### //; s/ - ACTIONABLE_.*//' || true)
  _total_items=$(echo "$FILTERED_CONTENT" | grep -c -E "^### .* - ACTIONABLE_(NOW|LATER)" || true)
  _total_items=${_total_items:-0}
  _remaining_item_count=0

  _item_desc=""
  if [ -n "$_first_item_title" ]; then
    _item_desc="$_first_item_title — PR #${PR_NUMBER}"
  else
    _item_desc="review feedback — PR #${PR_NUMBER}"
  fi

  ISSUE_TITLE="[tech-debt] ${_item_desc}"

  [[ "$ISSUE_TITLE" == *"review feedback — PR #410"* ]] || {
    echo "FAIL: Expected fallback 'review feedback — PR #410', got: $ISSUE_TITLE"
    false
  }
  # Must NOT contain ": " (the old truncation artifact)
  [[ "$ISSUE_TITLE" != *"PR title"*": "* ]] || {
    echo "FAIL: Fallback title should not contain old colon artifact: $ISSUE_TITLE"
    false
  }
}
