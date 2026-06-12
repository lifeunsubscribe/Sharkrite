#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/plan-issues.sh
# tests/regression/plan-ordinal-ref-resolution.bats
#
# Regression tests for the post-creation ordinal/title ref rewriting pass
# added by issue #556 to plan-issues.sh.
#
# Background: `rite plan` generates issue bodies with batch-ordinal refs like
# "After #1" (meaning "after the 1st non-spike issue in this batch") and title
# refs like "After #[Build Schema]".  Before this fix these refs survived verbatim
# into the created GitHub issues.  On any repo whose issue numbers do NOT start at
# 1 (pre-existing issues), "After #1" then points at literal repo issue #1 — the
# wrong dependency — causing the batch gate to wrongly skip or wrongly proceed.
#
# This file tests:
#   A — _resolve_ordinal_refs_in_body: basic ordinal rewrite (After #2 → After #501)
#   B — _resolve_ordinal_refs_in_body: "can run in parallel" annotation rewrite
#   C — _resolve_ordinal_refs_in_body: title ref rewrite (#[Database Schema Setup])
#   D — _resolve_ordinal_refs_in_body: unresolvable refs left untouched
#   E — _resolve_ordinal_refs_in_body: no partial match (#12 not rewritten by ordinal 1)
#   F — _resolve_ordinal_refs_in_body: multi-ordinal body; all refs resolved correctly
#   G — _rewrite_created_issue_bodies + stubbed gh_safe: slate on a repo starting at
#       issue #500 ends with bodies referencing the actual created numbers
#   H — _rewrite_created_issue_bodies: bodies without resolvable refs are NOT edited
#   I — _rewrite_created_issue_bodies: spike issues' ordinals are NOT mapped
#       (spike title "spike: capture X sample for grounding" must not appear in ordinal map)
#   J — acceptance: _resolve_ordinal_refs_in_body and _rewrite_created_issue_bodies
#       are present in plan-issues.sh (structural check)

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: extract the two functions under test via awk brace-depth tracker
# so no top-level plan-issues.sh network calls run.
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Stub print_* so output is clean without terminal / colors setup.
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }

  # Extract the functions under test.
  for fn in _resolve_ordinal_refs_in_body _rewrite_created_issue_bodies; do
    eval "$(awk -v target="^${fn}\\(\\)" '
      $0 ~ target { in_fn=1; depth=0 }
      in_fn {
        for (i=1; i<=length($0); i++) {
          c=substr($0,i,1)
          if (c=="{") depth++
          if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
        }
        print; next
      }
    ' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"
  done

  # Minimal gh_safe stub used by _rewrite_created_issue_bodies.
  # Tests that exercise _rewrite_created_issue_bodies override this.
  gh_safe() { :; }
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: write ordinal_map_file from "N=real_num" pairs
# Usage: write_ordinal_map FILE N=real_num [N=real_num ...]
# ---------------------------------------------------------------------------
write_ordinal_map() {
  local _file="$1"; shift
  : > "$_file"
  for pair in "$@"; do
    echo "$pair" >> "$_file"
  done
}

# ---------------------------------------------------------------------------
# Helper: write title_map_file from "real_num=Title" pairs
# Usage: write_title_map FILE real_num=Title [real_num=Title ...]
# ---------------------------------------------------------------------------
write_title_map() {
  local _file="$1"; shift
  : > "$_file"
  for pair in "$@"; do
    echo "$pair" >> "$_file"
  done
}

# ---------------------------------------------------------------------------
# Fixture A — basic ordinal rewrite
#
# Ordinal map: 1=500, 2=501, 3=502
# Body:  "**Dependencies**: After #2"
# Expect: "**Dependencies**: After #501"
# ---------------------------------------------------------------------------

@test "Fixture A: After #2 is rewritten to After #501 when ordinal 2 maps to real issue 501" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-a.txt"
  title_map="$RITE_TEST_TMPDIR/title-a.txt"

  write_ordinal_map "$ordinal_map" "1=500" "2=501" "3=502"
  : > "$title_map"  # empty title map

  local input="**Dependencies**: After #2"
  local result
  result=$(_resolve_ordinal_refs_in_body "$input" "$ordinal_map" "$title_map")

  [ "$result" = "**Dependencies**: After #501" ] || {
    echo "FAIL: expected 'After #501', got: '$result'" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture B — "can run in parallel" annotation rewrite
#
# The generation prompt explicitly endorses ordinal refs in parenthetical
# annotations.  These must be rewritten even though the batch gate ignores them.
#
# Body: "After #1 (can run in parallel with #2, #3)"
# Ordinal map: 1=500, 2=501, 3=502
# Expect: "After #500 (can run in parallel with #501, #502)"
# ---------------------------------------------------------------------------

@test "Fixture B: ordinal refs inside 'can run in parallel' annotations are rewritten" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-b.txt"
  title_map="$RITE_TEST_TMPDIR/title-b.txt"

  write_ordinal_map "$ordinal_map" "1=500" "2=501" "3=502"
  : > "$title_map"

  local input="After #1 (can run in parallel with #2, #3)"
  local result
  result=$(_resolve_ordinal_refs_in_body "$input" "$ordinal_map" "$title_map")

  [ "$result" = "After #500 (can run in parallel with #501, #502)" ] || {
    echo "FAIL: expected 'After #500 (can run in parallel with #501, #502)', got: '$result'" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture C — title ref rewrite
#
# Body:   "Blocked by: #[Database Schema Setup]"
# Title map: 500=Database Schema Setup
# Expect: "Blocked by: #500"
# ---------------------------------------------------------------------------

@test "Fixture C: Blocked by #[Title] is rewritten to the real issue number" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-c.txt"
  title_map="$RITE_TEST_TMPDIR/title-c.txt"

  : > "$ordinal_map"
  write_title_map "$title_map" "500=Database Schema Setup"

  local input="**Dependencies**: Blocked by: #[Database Schema Setup]"
  local result
  result=$(_resolve_ordinal_refs_in_body "$input" "$ordinal_map" "$title_map")

  [ "$result" = "**Dependencies**: Blocked by: #500" ] || {
    echo "FAIL: expected 'Blocked by: #500', got: '$result'" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture D — unresolvable refs left untouched
#
# Ordinal map only has ordinals 1-3.  Body contains "#99" (out of range).
# Expect: "#99" is NOT rewritten.
# ---------------------------------------------------------------------------

@test "Fixture D: refs that do not match any ordinal or title are left untouched" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-d.txt"
  title_map="$RITE_TEST_TMPDIR/title-d.txt"

  write_ordinal_map "$ordinal_map" "1=500" "2=501"
  : > "$title_map"

  local input="**Dependencies**: After #99"
  local result
  result=$(_resolve_ordinal_refs_in_body "$input" "$ordinal_map" "$title_map")

  [ "$result" = "**Dependencies**: After #99" ] || {
    echo "FAIL: expected unchanged 'After #99', got: '$result'" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture E — no partial match: #12 is not rewritten by ordinal 1
#
# Ordinal 1 maps to 500, ordinal 2 maps to 501.
# Body: "After #12"
# Expect: "#12" is left untouched (12 ≠ ordinal 1, 12 ≠ ordinal 2).
# ---------------------------------------------------------------------------

@test "Fixture E: #12 is not rewritten when ordinals are only 1 and 2 (no partial digit match)" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-e.txt"
  title_map="$RITE_TEST_TMPDIR/title-e.txt"

  write_ordinal_map "$ordinal_map" "1=500" "2=501"
  : > "$title_map"

  local input="After #12 (unrelated existing issue)"
  local result
  result=$(_resolve_ordinal_refs_in_body "$input" "$ordinal_map" "$title_map")

  [ "$result" = "After #12 (unrelated existing issue)" ] || {
    echo "FAIL: expected '#12' unchanged, got: '$result'" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture F — multi-ordinal body: all ordinal refs resolved correctly
#
# Body has both "After #1" and "Blocked by: #2", plus a "(can run in parallel with #3)".
# Ordinal map: 1=500, 2=501, 3=502
# Expect: all three are rewritten.
# ---------------------------------------------------------------------------

@test "Fixture F: body with multiple ordinal refs — all resolved independently" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-f.txt"
  title_map="$RITE_TEST_TMPDIR/title-f.txt"

  write_ordinal_map "$ordinal_map" "1=500" "2=501" "3=502"
  : > "$title_map"

  local input
  input=$(printf 'After #1\nBlocked by: #2 (can run in parallel with #3)')
  local result
  result=$(_resolve_ordinal_refs_in_body "$input" "$ordinal_map" "$title_map")

  local expected
  expected=$(printf 'After #500\nBlocked by: #501 (can run in parallel with #502)')

  [ "$result" = "$expected" ] || {
    echo "FAIL: unexpected rewrite result" >&2
    echo "  expected: $expected" >&2
    echo "  got:      $result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture G — end-to-end: slate on a repo starting at issue #500
#
# Simulates a repo with pre-existing issues up to #499.  Three non-spike issues
# are "created" (mocked) at #500, #501, #502.  The bodies reference batch ordinals
# #1, #2, #3.  After _rewrite_created_issue_bodies runs, the stored bodies must
# reference #500, #501, #502.
#
# Uses a stateful gh_safe stub that:
#   - view: returns the pre-creation body (with ordinal refs)
#   - edit: stores the updated body in a local dict for assertion
# ---------------------------------------------------------------------------

@test "Fixture G: repo starting at #500 — created bodies rewritten to real issue numbers" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-g.txt"
  title_map="$RITE_TEST_TMPDIR/title-g.txt"

  # Ordinals 1→500, 2→501, 3→502  (as if rite plan created them at #500+)
  write_ordinal_map "$ordinal_map" "1=500" "2=501" "3=502"
  write_title_map "$title_map" \
    "500=Build Schema" \
    "501=Add CRUD endpoints" \
    "502=Add Filters"

  # Pre-creation bodies (what gh issue create stored verbatim)
  local _body_500 _body_501 _body_502
  _body_500="**Dependencies**: None"
  _body_501="**Dependencies**: After #1"
  _body_502="**Dependencies**: After #2 (can run in parallel with #501)"

  # Use temp files to record edited bodies (avoids associative array bash 4 requirement
  # in the stub function scope, which is called from a nested function).
  local _edited_dir
  _edited_dir="$RITE_TEST_TMPDIR/edited-g"
  mkdir -p "$_edited_dir"

  # Stub gh_safe: view returns pre-creation bodies; edit saves the new body to a file
  gh_safe() {
    local _subcmd="$1"
    shift
    case "$_subcmd" in
      issue)
        local _op="$1"; shift
        case "$_op" in
          view)
            local _num="$1"; shift
            # Return just the body text (the real gh_safe returns the .body field)
            local _jq=""
            while [ $# -gt 0 ]; do
              case "$1" in --jq) _jq="$2"; shift 2 ;; --json) shift 2 ;; *) shift ;; esac
            done
            case "$_num" in
              500) echo "$_body_500" ;;
              501) echo "$_body_501" ;;
              502) echo "$_body_502" ;;
              *) echo "" ;;
            esac
            ;;
          edit)
            local _num="$1"; shift
            local _bf=""
            while [ $# -gt 0 ]; do
              case "$1" in --body-file) _bf="$2"; shift 2 ;; *) shift ;; esac
            done
            # Save the new body to a per-issue file for later assertion
            if [ -n "$_bf" ] && [ -f "$_bf" ]; then
              cp "$_bf" "${_edited_dir}/${_num}.txt"
            fi
            ;;
        esac
        ;;
    esac
  }

  # Run the rewrite pass
  _rewrite_created_issue_bodies 500 501 502 -- "$ordinal_map" "$title_map"

  # Issue 500 has no ordinal refs — must NOT have been edited
  [ ! -f "${_edited_dir}/500.txt" ] || {
    echo "FAIL: issue 500 should not have been edited (no ordinal refs)" >&2
    echo "  got body: $(cat "${_edited_dir}/500.txt")" >&2
    false
  }

  # Issue 501: "After #1" → "After #500"
  [ -f "${_edited_dir}/501.txt" ] || {
    echo "FAIL: issue 501 was not edited (expected 'After #1' → 'After #500')" >&2
    false
  }
  local body501
  body501=$(cat "${_edited_dir}/501.txt")
  echo "$body501" | grep -q "After #500" || {
    echo "FAIL: issue 501 body does not contain 'After #500'" >&2
    echo "  got: $body501" >&2
    false
  }
  # Must NOT still contain the ordinal ref
  echo "$body501" | grep -qE "After #1([^0-9]|$)" && {
    echo "FAIL: issue 501 body still contains unresolved 'After #1'" >&2
    echo "  got: $body501" >&2
    false
  }

  # Issue 502: "After #2" → "After #501", "(can run in parallel with #501)" must survive
  [ -f "${_edited_dir}/502.txt" ] || {
    echo "FAIL: issue 502 was not edited (expected 'After #2' → 'After #501')" >&2
    false
  }
  local body502
  body502=$(cat "${_edited_dir}/502.txt")
  echo "$body502" | grep -q "After #501" || {
    echo "FAIL: issue 502 body does not contain 'After #501'" >&2
    echo "  got: $body502" >&2
    false
  }
  echo "$body502" | grep -qE "After #2([^0-9]|$)" && {
    echo "FAIL: issue 502 body still contains unresolved 'After #2'" >&2
    echo "  got: $body502" >&2
    false
  }
  # The #501 ref in the parallel annotation — it was already a real number and
  # ordinal 2 also maps to 501, so it stays #501 after rewriting.
  echo "$body502" | grep -q "#501" || {
    echo "FAIL: issue 502 lost its #501 ref" >&2
    echo "  got: $body502" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture H — bodies without resolvable refs are NOT edited
#
# All three issue bodies contain no batch-ordinal refs.  gh_safe issue edit
# must not be called for any of them.
# ---------------------------------------------------------------------------

@test "Fixture H: bodies without resolvable refs are not passed to gh issue edit" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-h.txt"
  title_map="$RITE_TEST_TMPDIR/title-h.txt"

  write_ordinal_map "$ordinal_map" "1=500" "2=501"
  : > "$title_map"

  local _edit_called=false

  gh_safe() {
    local _subcmd="$1"; shift
    case "$_subcmd" in
      issue)
        local _op="$1"; shift
        case "$_op" in
          view)
            local _num="$1"; shift
            # All bodies reference pre-existing issues (not batch ordinals)
            case "$_num" in
              500) echo "**Dependencies**: None" ;;
              501) echo "**Dependencies**: None" ;;
            esac
            ;;
          edit)
            _edit_called=true
            ;;
        esac
        ;;
    esac
  }

  _rewrite_created_issue_bodies 500 501 -- "$ordinal_map" "$title_map"

  [ "$_edit_called" = false ] || {
    echo "FAIL: gh issue edit was called but no body had ordinal refs to rewrite" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture I — spike issues do NOT contribute to the ordinal map
#
# Verifies (structurally) that the ordinal map file only contains entries for
# non-spike issues.  Spike issues ("spike: capture X sample for grounding")
# have their own separate spike_map_file and are prepended prerequisites;
# they must NOT be counted in the 1-based ordinal sequence.
#
# This is a structural check on the source: look for the `ordinal_counter`
# increment being inside the `else` branch (non-spike path) of the spike
# title check.
# ---------------------------------------------------------------------------

@test "Fixture I: ordinal_counter is only incremented for non-spike issues (structural check)" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  # Extract the create_issues function body
  local fn_body
  fn_body=$(awk '
    /^create_issues\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "$plan_issues_sh")

  # The ordinal_counter increment must appear after the spike-check else
  # (i.e., inside the non-spike branch).  A loose check: ordinal_counter
  # increment must follow the "^spike:" regex check in the function.
  echo "$fn_body" | grep -q "ordinal_counter" || {
    echo "FAIL: create_issues does not reference ordinal_counter" >&2
    false
  }

  # The ordinal_counter increment line must NOT appear before the spike check.
  # Simplest assertion: "ordinal_counter" and "spike:" both appear, and the
  # spike check line number comes before the ordinal_counter line in the fn body.
  local spike_line ordinal_line
  spike_line=$(echo "$fn_body" | grep -n "^spike:" | head -1 | cut -d: -f1 || true)
  ordinal_line=$(echo "$fn_body" | grep -n "ordinal_counter" | head -1 | cut -d: -f1 || true)

  [ -n "$spike_line" ] || {
    echo "FAIL: spike title check not found in create_issues" >&2
    false
  }
  [ -n "$ordinal_line" ] || {
    echo "FAIL: ordinal_counter not found in create_issues" >&2
    false
  }
  [ "$spike_line" -lt "$ordinal_line" ] || {
    echo "FAIL: ordinal_counter appears before spike check (should be inside the else/non-spike branch)" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture J — structural: both functions are present in plan-issues.sh
# ---------------------------------------------------------------------------

@test "Fixture J: _resolve_ordinal_refs_in_body and _rewrite_created_issue_bodies exist in plan-issues.sh" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  grep -q "^_resolve_ordinal_refs_in_body()" "$plan_issues_sh" || {
    echo "FAIL: _resolve_ordinal_refs_in_body not found in plan-issues.sh" >&2
    false
  }
  grep -q "^_rewrite_created_issue_bodies()" "$plan_issues_sh" || {
    echo "FAIL: _rewrite_created_issue_bodies not found in plan-issues.sh" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture K — title with '=' character in it does not corrupt the title map
#
# The title map format is "real_num=Title".  IFS='=' read -r a b reads
# everything after the first '=' into b.  A title like "A=B feature" must be
# preserved correctly.
# ---------------------------------------------------------------------------

@test "Fixture K: title containing '=' is handled without corruption" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-k.txt"
  title_map="$RITE_TEST_TMPDIR/title-k.txt"

  : > "$ordinal_map"
  # Title contains '=' — stored as "500=Config A=B feature"
  printf '500=Config A=B feature\n' > "$title_map"

  local input="Blocked by: #[Config A=B feature]"
  local result
  result=$(_resolve_ordinal_refs_in_body "$input" "$ordinal_map" "$title_map")

  [ "$result" = "Blocked by: #500" ] || {
    echo "FAIL: expected 'Blocked by: #500', got: '$result'" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture L — #PREV/#SPIKE refs are untouched (should have been resolved earlier)
#
# The rewrite function only handles ordinal and title refs.  #PREV and #SPIKE-*
# are resolved DURING creation (before gh issue create), not in the rewrite pass.
# This fixture verifies that residual #PREV / #SPIKE refs in any body are left
# alone (they should not appear in a correctly-functioning run, but if they do
# the rewrite must not corrupt them).
# ---------------------------------------------------------------------------

@test "Fixture L: #PREV and #SPIKE-* refs in body are not modified by the ordinal rewrite" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-l.txt"
  title_map="$RITE_TEST_TMPDIR/title-l.txt"

  write_ordinal_map "$ordinal_map" "1=500"
  : > "$title_map"

  local input="After #PREV (can run in parallel with #SPIKE-somelib)"
  local result
  result=$(_resolve_ordinal_refs_in_body "$input" "$ordinal_map" "$title_map")

  # #PREV and #SPIKE-somelib are not numeric → ordinal pass skips them
  [ "$result" = "After #PREV (can run in parallel with #SPIKE-somelib)" ] || {
    echo "FAIL: expected #PREV/#SPIKE refs to be untouched, got: '$result'" >&2
    false
  }
}
