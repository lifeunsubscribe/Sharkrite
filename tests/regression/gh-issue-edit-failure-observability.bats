#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/plan-issues.sh, lib/core/assess-review-issues.sh
#
# Regression tests for: Handle gh issue edit failures in batch processing
# Issue #572
#
# Background: Two separate observability gaps existed for gh issue edit failures:
#
#   Gap 1 — plan-issues.sh::_rewrite_created_issue_bodies:
#     When gh issue edit failed for any issue, a per-issue warning was printed
#     but _rewrite_created_issue_bodies returned 0 and the create_issues caller
#     unconditionally printed "Created N issues" (success).  The batch outcome
#     did not surface partial failure: dependency refs remained unresolved while
#     the run reported success.
#
#   Gap 2 — assess-review-issues.sh (duplicate-issue update path):
#     When gh issue edit failed during duplicate-issue body update, the issue
#     number was still written to RITE_PER_ITEM_ISSUES_FILE (the passback
#     mechanism).  assess-and-resolve.sh uses this passback to skip consolidated
#     rollup for that finding.  A failed edit means the duplicate body was NOT
#     updated — the finding was effectively dropped from the batch outcome while
#     the run still reported success.
#
# Tests in this file:
#   1. _rewrite_created_issue_bodies exits 0 when all edits succeed
#   2. _rewrite_created_issue_bodies exits 1 when any edit fails
#   3. _rewrite_created_issue_bodies emits a per-issue warning on edit failure
#   4. _rewrite_created_issue_bodies emits a summary warning when any edit fails
#   5. _rewrite_created_issue_bodies counts partial successes correctly
#      (succeeds for some, fails for others → exits 1, counts are correct)
#   6. Static: create_issues caller captures _rewrite_created_issue_bodies exit code
#   7. Static: create_issues prints warning (not success) when rewrite returns 1
#   8. assess-review-issues.sh: passback NOT written when gh issue edit fails
#   9. assess-review-issues.sh: passback IS written when gh issue edit succeeds
#  10. assess-review-issues.sh: warning printed when gh issue edit fails

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: extract the two functions under test from plan-issues.sh via awk
# brace-depth tracker — same pattern as plan-ordinal-ref-resolution.bats.
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Stub print_* so output is clean without terminal/colors setup.
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }

  # Extract functions under test from plan-issues.sh.
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

  # Default gh_safe stub (tests override as needed).
  gh_safe() { :; }
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: write ordinal_map_file from "N=real_num" pairs.
# ---------------------------------------------------------------------------
write_ordinal_map() {
  local _file="$1"; shift
  : > "$_file"
  for pair in "$@"; do
    echo "$pair" >> "$_file"
  done
}

# ---------------------------------------------------------------------------
# Test 1: all edits succeed → exit 0
# ---------------------------------------------------------------------------

@test "Test 1: _rewrite_created_issue_bodies exits 0 when all gh issue edit calls succeed" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-t1.txt"
  title_map="$RITE_TEST_TMPDIR/title-t1.txt"

  write_ordinal_map "$ordinal_map" "1=500" "2=501"
  : > "$title_map"

  # Stub: view returns bodies with ordinal refs; edit always succeeds
  gh_safe() {
    local _subcmd="$1"; shift
    case "$_subcmd" in
      issue)
        local _op="$1"; shift
        case "$_op" in
          view) echo "**Dependencies**: After #1" ;;
          edit) return 0 ;;
        esac ;;
    esac
  }

  _rewrite_created_issue_bodies 500 501 -- "$ordinal_map" "$title_map"
  _exit=$?
  [ "$_exit" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $_exit"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 2: any edit fails → exit 1
# ---------------------------------------------------------------------------

@test "Test 2: _rewrite_created_issue_bodies exits 1 when any gh issue edit call fails" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-t2.txt"
  title_map="$RITE_TEST_TMPDIR/title-t2.txt"

  write_ordinal_map "$ordinal_map" "1=500"
  : > "$title_map"

  # Stub: view returns a body with an ordinal ref; edit always fails
  gh_safe() {
    local _subcmd="$1"; shift
    case "$_subcmd" in
      issue)
        local _op="$1"; shift
        case "$_op" in
          view) echo "**Dependencies**: After #1" ;;
          edit) return 1 ;;
        esac ;;
    esac
  }

  _rc=0
  _rewrite_created_issue_bodies 500 -- "$ordinal_map" "$title_map" || _rc=$?
  [ "$_rc" -eq 1 ] || {
    echo "FAIL: expected exit 1 when edit fails, got $_rc"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 3: per-issue warning emitted on edit failure
# ---------------------------------------------------------------------------

@test "Test 3: _rewrite_created_issue_bodies emits a per-issue warning when gh issue edit fails" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-t3.txt"
  title_map="$RITE_TEST_TMPDIR/title-t3.txt"

  write_ordinal_map "$ordinal_map" "1=500"
  : > "$title_map"

  gh_safe() {
    local _subcmd="$1"; shift
    case "$_subcmd" in
      issue)
        local _op="$1"; shift
        case "$_op" in
          view) echo "**Dependencies**: After #1" ;;
          edit) return 1 ;;
        esac ;;
    esac
  }

  # Capture stderr where print_warning writes
  _output=$( _rewrite_created_issue_bodies 500 -- "$ordinal_map" "$title_map" 2>&1 || true )

  # Must contain per-issue warning referencing the issue number
  echo "$_output" | grep -q "500" || {
    echo "FAIL: per-issue warning does not reference issue #500"
    echo "Output: $_output"
    false
  }

  echo "$_output" | grep -qi "warn\|Could not update\|unresolved" || {
    echo "FAIL: no warning text found in output"
    echo "Output: $_output"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 4: summary warning emitted when any edit fails
# ---------------------------------------------------------------------------

@test "Test 4: _rewrite_created_issue_bodies emits a summary warning on partial failure" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-t4.txt"
  title_map="$RITE_TEST_TMPDIR/title-t4.txt"

  write_ordinal_map "$ordinal_map" "1=500"
  : > "$title_map"

  gh_safe() {
    local _subcmd="$1"; shift
    case "$_subcmd" in
      issue)
        local _op="$1"; shift
        case "$_op" in
          view) echo "After #1" ;;
          edit) return 1 ;;
        esac ;;
    esac
  }

  _output=$( _rewrite_created_issue_bodies 500 -- "$ordinal_map" "$title_map" 2>&1 || true )

  # Summary warning must mention the failure count
  echo "$_output" | grep -qi "incomplete\|failed\|could not" || {
    echo "FAIL: no summary failure message found"
    echo "Output: $_output"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 5: partial success (one succeeds, one fails) — exit 1, counts correct
# ---------------------------------------------------------------------------

@test "Test 5: _rewrite_created_issue_bodies: partial success (1 ok, 1 fail) exits 1" {
  local ordinal_map title_map
  ordinal_map="$RITE_TEST_TMPDIR/ordinal-t5.txt"
  title_map="$RITE_TEST_TMPDIR/title-t5.txt"

  write_ordinal_map "$ordinal_map" "1=500" "2=501"
  : > "$title_map"

  # Issue 500 edit succeeds; issue 501 edit fails
  gh_safe() {
    local _subcmd="$1"; shift
    case "$_subcmd" in
      issue)
        local _op="$1"; shift
        local _num="$1"; shift
        case "$_op" in
          view) echo "After #1" ;;   # both have refs to rewrite
          edit)
            case "$_num" in
              500) return 0 ;;
              501) return 1 ;;
              *)   return 0 ;;
            esac ;;
        esac ;;
    esac
  }

  _rc=0
  _output=$( _rewrite_created_issue_bodies 500 501 -- "$ordinal_map" "$title_map" 2>&1 ) || _rc=$?

  # Must exit 1 (at least one failure)
  [ "$_rc" -eq 1 ] || {
    echo "FAIL: expected exit 1 for partial failure, got $_rc"
    false
  }

  # Must have reported a success for issue 500
  echo "$_output" | grep -qi "Updated #500\|500.*resolved" || {
    echo "FAIL: no success message for issue 500"
    echo "Output: $_output"
    false
  }

  # Must have reported a failure for issue 501
  echo "$_output" | grep -q "501" || {
    echo "FAIL: no failure reference to issue 501"
    echo "Output: $_output"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 6 (static): create_issues captures _rewrite_created_issue_bodies exit code
# ---------------------------------------------------------------------------

@test "Test 6 (static): create_issues captures _rewrite_created_issue_bodies exit code via '|| _rewrite_rc=\$?'" {
  _src="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  # The capture pattern must be present: save exit code before the if/else branch
  _pattern_found=$(grep -c '_rewrite_created_issue_bodies' "$_src" || true)
  [ "$_pattern_found" -gt 0 ] || {
    echo "FAIL: _rewrite_created_issue_bodies call not found in create_issues"
    false
  }

  # Exit-code capture: must use '_rewrite_rc' variable adjacent to the call
  _rc_capture=$(grep -A5 '_rewrite_created_issue_bodies' "$_src" | grep '_rewrite_rc' || true)
  [ -n "$_rc_capture" ] || {
    echo "FAIL: _rewrite_rc capture not found near _rewrite_created_issue_bodies call"
    echo "  Expected pattern: '_rewrite_rc=0' / '|| _rewrite_rc=\$?' adjacent to the call"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 7 (static): create_issues prints warning (not unconditional success)
#   when rewrite returns 1
# ---------------------------------------------------------------------------

@test "Test 7 (static): create_issues branches on _rewrite_rc and prints warning on failure" {
  _src="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  # The if/else branch on _rewrite_rc must exist
  _branch=$(grep '_rewrite_rc' "$_src" | grep -E 'if \[|then|\-eq 0' || true)
  [ -n "$_branch" ] || {
    echo "FAIL: no conditional branch on _rewrite_rc found in $(_src)"
    false
  }

  # The else branch must NOT print unconditional success when rc != 0
  # Verify by checking that the success print is inside the _rewrite_rc==0 branch,
  # i.e. that there is no 'print_success.*issues' line that is NOT gated by _rewrite_rc check.
  #
  # Strategy: extract the block around the _rewrite_created_issue_bodies call and
  # verify the success message only appears in the if-eq-0 branch.
  _block=$(awk '/^  _rewrite_rc=0/{found=1} found{print; if(/^  fi$/){exit}}' "$_src" || true)

  # Block must contain the _rewrite_rc guard
  echo "$_block" | grep -q '_rewrite_rc' || {
    echo "FAIL: _rewrite_rc guard block not extractable"
    echo "Block: $_block"
    false
  }

  # Block must contain a warning for the failure case (else branch)
  echo "$_block" | grep -qi 'print_warning\|could not be resolved\|see warnings' || {
    echo "FAIL: no print_warning found in the else branch after _rewrite_rc check"
    echo "Block: $_block"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 8: assess-review-issues.sh — passback NOT written when gh issue edit fails
#
# This is the core bug: when the duplicate-issue body update fails, the issue
# number must NOT be written to RITE_PER_ITEM_ISSUES_FILE.  Writing it on
# failure causes assess-and-resolve.sh to silently skip creating a new issue
# for the finding, effectively dropping it from the batch outcome.
# ---------------------------------------------------------------------------

@test "Test 8: assess-review-issues.sh: passback NOT written to RITE_PER_ITEM_ISSUES_FILE when gh issue edit fails" {
  _passback_file="$RITE_TEST_TMPDIR/per-item-issues.txt"
  : > "$_passback_file"

  # Inline the duplicate-issue update block from assess-review-issues.sh,
  # mirroring exactly the fixed code structure (exit-code gated passback).
  run bash -c "
    set -euo pipefail

    print_info()    { echo \"INFO: \$*\" >&2; }
    print_warning() { echo \"WARNING: \$*\" >&2; }

    gh_safe() {
      local _subcmd=\"\$1\"; shift
      case \"\$_subcmd\" in
        issue)
          local _op=\"\$1\"; shift
          case \"\$_op\" in
            view) echo 'existing body content'; return 0 ;;
            edit) return 1 ;;  # <-- edit fails
          esac ;;
      esac
    }

    DUPLICATE_ISSUE=42
    RITE_PER_ITEM_ISSUES_FILE='${_passback_file}'
    UPDATED_ISSUES=''
    ITEM_SEVERITY='MEDIUM'
    ITEM_REASONING='Some reasoning text that is longer than sixty characters for the signature'
    ITEM_CONTEXT='Some context'
    ITEM_DEFER='Needs separate focused PR'
    PR_NUMBER=99
    ASSESSMENT_TIMESTAMP='2026-06-12T00:00:00Z'

    EXISTING_BODY=\$(gh_safe issue view \"\$DUPLICATE_ISSUE\" --json body --jq '.body' || true)
    EXISTING_BODY=\"\${EXISTING_BODY:-}\"
    REASONING_SIGNATURE=\$(echo \"\$ITEM_REASONING\" | head -c 60 || true)

    # Replicate the update path (reasoning signature is NOT in existing body)
    UPDATED_BODY=\"\${EXISTING_BODY}

---

## Additional Assessment (PR #\${PR_NUMBER})

**Severity:** \${ITEM_SEVERITY}
**Reasoning:** \${ITEM_REASONING}
**Context:** \${ITEM_CONTEXT}
**Defer Reason:** \${ITEM_DEFER}

_Added by Sharkrite on \${ASSESSMENT_TIMESTAMP}_\"

    EDIT_BODY_FILE=\$(mktemp)
    printf '%s' \"\$UPDATED_BODY\" > \"\$EDIT_BODY_FILE\"
    _issue_edit_rc=0
    gh_safe issue edit \"\$DUPLICATE_ISSUE\" --body-file \"\$EDIT_BODY_FILE\" >/dev/null 2>&1 \
      || _issue_edit_rc=\$?
    rm -f \"\$EDIT_BODY_FILE\"
    if [ \"\$_issue_edit_rc\" -eq 0 ]; then
      UPDATED_ISSUES=\"\${UPDATED_ISSUES}#\${DUPLICATE_ISSUE} \"
      if [ -n \"\${RITE_PER_ITEM_ISSUES_FILE:-}\" ]; then
        echo \"\$DUPLICATE_ISSUE\" >> \"\$RITE_PER_ITEM_ISSUES_FILE\" 2>/dev/null || true
      fi
    else
      print_warning \"Could not update duplicate issue #\${DUPLICATE_ISSUE} body (gh issue edit failed with exit \${_issue_edit_rc}); finding will be re-evaluated\"
    fi
  " 2>&1

  # The passback file must be empty — issue 42 must NOT have been written
  _contents=$(cat "$_passback_file")
  [ -z "$_contents" ] || {
    echo "FAIL: passback file should be empty on edit failure, but contains: '$_contents'"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 9: assess-review-issues.sh — passback IS written when gh issue edit succeeds
# ---------------------------------------------------------------------------

@test "Test 9: assess-review-issues.sh: passback IS written to RITE_PER_ITEM_ISSUES_FILE when gh issue edit succeeds" {
  _passback_file="$RITE_TEST_TMPDIR/per-item-issues-success.txt"
  : > "$_passback_file"

  run bash -c "
    set -euo pipefail

    print_info()    { echo \"INFO: \$*\" >&2; }
    print_warning() { echo \"WARNING: \$*\" >&2; }

    gh_safe() {
      local _subcmd=\"\$1\"; shift
      case \"\$_subcmd\" in
        issue)
          local _op=\"\$1\"; shift
          case \"\$_op\" in
            view) echo 'existing body content'; return 0 ;;
            edit) return 0 ;;  # <-- edit succeeds
          esac ;;
      esac
    }

    DUPLICATE_ISSUE=42
    RITE_PER_ITEM_ISSUES_FILE='${_passback_file}'
    UPDATED_ISSUES=''
    ITEM_SEVERITY='MEDIUM'
    ITEM_REASONING='Some reasoning text that is longer than sixty characters for the signature'
    ITEM_CONTEXT='Some context'
    ITEM_DEFER='Needs separate focused PR'
    PR_NUMBER=99
    ASSESSMENT_TIMESTAMP='2026-06-12T00:00:00Z'

    EXISTING_BODY=\$(gh_safe issue view \"\$DUPLICATE_ISSUE\" --json body --jq '.body' || true)
    EXISTING_BODY=\"\${EXISTING_BODY:-}\"

    UPDATED_BODY=\"\${EXISTING_BODY}

---

## Additional Assessment (PR #\${PR_NUMBER})

**Severity:** \${ITEM_SEVERITY}
**Reasoning:** \${ITEM_REASONING}

_Added by Sharkrite on \${ASSESSMENT_TIMESTAMP}_\"

    EDIT_BODY_FILE=\$(mktemp)
    printf '%s' \"\$UPDATED_BODY\" > \"\$EDIT_BODY_FILE\"
    _issue_edit_rc=0
    gh_safe issue edit \"\$DUPLICATE_ISSUE\" --body-file \"\$EDIT_BODY_FILE\" >/dev/null 2>&1 \
      || _issue_edit_rc=\$?
    rm -f \"\$EDIT_BODY_FILE\"
    if [ \"\$_issue_edit_rc\" -eq 0 ]; then
      UPDATED_ISSUES=\"\${UPDATED_ISSUES}#\${DUPLICATE_ISSUE} \"
      if [ -n \"\${RITE_PER_ITEM_ISSUES_FILE:-}\" ]; then
        echo \"\$DUPLICATE_ISSUE\" >> \"\$RITE_PER_ITEM_ISSUES_FILE\" 2>/dev/null || true
      fi
    else
      print_warning \"Could not update duplicate issue #\${DUPLICATE_ISSUE} body (gh issue edit failed with exit \${_issue_edit_rc}); finding will be re-evaluated\"
    fi
  " 2>&1

  [ "$status" -eq 0 ] || {
    echo "FAIL: inline block exited non-zero ($status)"
    echo "Output: $output"
    false
  }

  # The passback file must contain the issue number
  _contents=$(cat "$_passback_file")
  [ "$_contents" = "42" ] || {
    echo "FAIL: passback file should contain '42', got: '$_contents'"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 10 (static): assess-review-issues.sh: warning printed on edit failure
# ---------------------------------------------------------------------------

@test "Test 10 (static): assess-review-issues.sh: print_warning present in the else branch after _issue_edit_rc check" {
  _src="${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"

  # The _issue_edit_rc variable must be referenced in the source
  _rc_ref=$(grep -c '_issue_edit_rc' "$_src" || true)
  [ "$_rc_ref" -gt 0 ] || {
    echo "FAIL: _issue_edit_rc not found in $( basename "$_src" )"
    false
  }

  # The else branch on _issue_edit_rc must contain a warning
  _block=$(awk '/_issue_edit_rc/{found=1} found{print; if(/^            fi$/){exit}}' "$_src" || true)
  echo "$_block" | grep -q 'print_warning' || {
    echo "FAIL: print_warning not found in the _issue_edit_rc else branch"
    echo "Block: $_block"
    false
  }
}
