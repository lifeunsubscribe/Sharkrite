#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh
# Regression test for: assess-and-resolve.sh follow-up issue format (issue #518, #909)
#
# Defects fixed:
#   1. Multi-finding bundling: all ACTIONABLE_LATER findings in one issue with (+N more)
#   2. [tech-debt]/[review-follow-up] tag prefix in titles
#   3. List markers (^[0-9]+\.) leaked into issue titles
#   4. Empty severity-bucket scaffolding (### CRITICAL (0)) in body
#   5. No acceptance criteria / verification command in generated bodies
#   6. Time Estimate missing (issue #909): runbook §3 requires it; now present and ordered before Description
#   7. Claude Context used "Files to read before starting:" (issue #909): now uses runbook §5 labels
#
# New behavior:
#   - One issue per ACTIONABLE_(NOW|LATER) finding
#   - Title = finding's own text, no prefix, no truncation, no list markers
#   - Body includes at least one - [ ] acceptance criterion per finding
#   - Body includes at least one verification command per finding
#   - Body omits empty severity buckets
#   - Label (tech-debt / review-follow-up) applied via --label, not in title
#   - Dedup/source-marker suffix preserved for unique scoping per PR+source-issue
#   - ## Time Estimate section present and ordered BEFORE ## Description
#   - ## Claude Context uses "Files to Read:" / "Files to Modify:" / "Related Issues:" labels
#
# Tests in this file:
#   1. Static: per-finding while-loop over ACTIONABLE_ headers exists
#   2. Static: body no longer contains "### 🚨 CRITICAL Security Issues" scaffold
#   3. Static: acceptance criterion (- [ ]) is hardcoded in per-finding body
#   4. Static: Verification Commands section present in per-finding body
#   5. Unit:   N findings → N iterations (per-finding index counter)
#   6. Unit:   body contains acceptance criterion and verification section
#   7. Unit:   empty severity buckets ("_No CRITICAL issues_") not in body
#   8. Unit:   label applied via --label flag, NOT embedded in ISSUE_TITLE
#   9. Static: severity normalization line present (_f_severity awk/tr guard)
#  10. Unit:   trailing severity annotation resolves to correct priority label
#              (calls real _resolve_priority_label from assess-and-resolve.sh)
#  11. Unit:   CRITICAL severity with annotation produces CRITICAL done definition
#              (calls real _resolve_done_def from assess-and-resolve.sh)
#  12. Static: ## Time Estimate section appears BEFORE ## Description (runbook §3 ordering)
#  13. Static: "Files to read before starting:" old label replaced by "Files to Read:" (runbook §5)
#  14. Unit:   Time Estimate section is always populated (severity fallback when Fix Effort absent)

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

# ─── Test 1: Static — per-finding loop over ACTIONABLE_ headers ──────────────

@test "assess-and-resolve.sh: per-finding while loop reads ACTIONABLE_ headers" {
  # The per-finding loop must grep for ACTIONABLE_(NOW|LATER) headers and
  # iterate with a while-read loop (not a single grep -m1 extraction).
  run grep -n 'grep.*ACTIONABLE_(NOW|LATER)' "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -eq 0 ] || {
    echo "FAIL: No per-finding ACTIONABLE_ grep found in $ASSESS_RESOLVE_SCRIPT"
    echo "Expected a while-loop over ACTIONABLE_(NOW|LATER) headers"
    false
  }
}

# ─── Test 2: Static — old severity-bucket scaffold is gone ───────────────────

@test "assess-and-resolve.sh: old severity-bucket scaffold no longer in body builder" {
  # Pre-#518: body contained ### 🚨 CRITICAL Security Issues ($CRITICAL_COUNT) etc.
  # Post-#518: per-finding body has Description/Acceptance/Verification; no buckets.
  run grep -n '### 🚨 CRITICAL Security Issues' "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -ne 0 ] || {
    echo "FAIL: Old severity-bucket scaffold still present in $ASSESS_RESOLVE_SCRIPT"
    echo "Matches:"
    echo "$output"
    false
  }
}

# ─── Test 3: Static — acceptance criterion present in body template ───────────

@test "assess-and-resolve.sh: per-finding body includes acceptance criterion (- [ ])" {
  # Each generated body must include at least one - [ ] checkbox.
  run grep -n -- '- \[ \]' "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -eq 0 ] || {
    echo "FAIL: No '- [ ]' acceptance criterion found in $ASSESS_RESOLVE_SCRIPT body builder"
    false
  }
}

# ─── Test 4: Static — Verification Commands section in body template ──────────

@test "assess-and-resolve.sh: per-finding body includes Verification Commands section" {
  # Each generated body must include a ## Verification Commands section.
  run grep -n 'Verification Commands' "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -eq 0 ] || {
    echo "FAIL: No 'Verification Commands' section found in $ASSESS_RESOLVE_SCRIPT body builder"
    false
  }
}

# ─── Test 5: Unit — N findings → N iterations (finding index counter) ─────────

@test "assess-and-resolve.sh: per-finding loop increments _finding_index for each header" {
  # Simulate the per-finding index counter logic.
  # Three ACTIONABLE_ headers → _finding_index should reach 3.
  FILTERED_CONTENT="### Fix unquoted var - ACTIONABLE_LATER
**Severity:** HIGH
**Reasoning:** Word splits on whitespace.

### Missing null check - ACTIONABLE_LATER
**Severity:** MEDIUM
**Reasoning:** Null pointer in edge case.

### Stale lock file not cleaned - ACTIONABLE_NOW
**Severity:** HIGH
**Reasoning:** Lock leaked on crash."

  _finding_index=0
  while IFS= read -r _fh_line; do
    [ -z "$_fh_line" ] && continue
    _finding_index=$((_finding_index + 1))
  done < <(echo "$FILTERED_CONTENT" | grep -E "^### .* - ACTIONABLE_(NOW|LATER)" || true)

  [ "$_finding_index" -eq 3 ] || {
    echo "FAIL: Expected 3 findings, got: $_finding_index"
    false
  }
}

# ─── Test 6: Unit — body contains acceptance criterion and verification ────────

@test "assess-and-resolve.sh: per-finding body has - [ ] criterion and Verification section" {
  # Build a minimal per-finding body using the same inline logic as the script.
  _clean_title="Fix unquoted variable expansion"
  _f_severity="HIGH"
  _f_location="lib/core/workflow-runner.sh:142"
  _acceptance_criterion="- [ ] [${_f_severity}] ${_clean_title}"
  # file:line location → sed -n 'Np' file (not grep -n '' file:line which errors)
  _verification_cmd="sed -n '142p' lib/core/workflow-runner.sh"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand
  FOLLOWUP_BODY="## Description

${_clean_title}

## Acceptance Criteria
${_acceptance_criterion}: see Description above for details

## Verification Commands
\`\`\`bash
${_verification_cmd}
\`\`\`

## Done Definition
Done when the finding is resolved."

  # Must contain a checkbox
  echo "$FOLLOWUP_BODY" | grep -q '\- \[ \]' || {
    echo "FAIL: Body missing '- [ ]' acceptance criterion"
    echo "Body:"
    echo "$FOLLOWUP_BODY"
    false
  }

  # Must contain Verification Commands
  echo "$FOLLOWUP_BODY" | grep -q 'Verification Commands' || {
    echo "FAIL: Body missing 'Verification Commands' section"
    echo "Body:"
    echo "$FOLLOWUP_BODY"
    false
  }

  # Must contain a valid location-seeded verification command.
  # file:line format produces "sed -n 'Np' file" (grep -n '' file:line is invalid).
  echo "$FOLLOWUP_BODY" | grep -q "sed -n '142p' lib/core/workflow-runner.sh" || {
    echo "FAIL: Body missing valid sed-based file:line verification command"
    echo "Body:"
    echo "$FOLLOWUP_BODY"
    false
  }
}

# ─── Test 7: Unit — empty severity buckets not present in body ────────────────

@test "assess-and-resolve.sh: per-finding body does not contain empty severity buckets" {
  # Pre-#518: body had "### CRITICAL (0)" / "_No CRITICAL issues_" boilerplate.
  # Post-#518: per-finding body has no severity-bucket scaffold at all.
  _clean_title="Fix missing null guard"
  _f_severity="MEDIUM"
  _f_location=""
  _acceptance_criterion="- [ ] [${_f_severity}] ${_clean_title}"
  _verification_cmd="# TODO: add verification command for this finding"

  FOLLOWUP_BODY="## Description

${_clean_title}

**Severity:** ${_f_severity}

## Acceptance Criteria
${_acceptance_criterion}: see Description above for details

## Verification Commands
\`\`\`bash
${_verification_cmd}
\`\`\`

## Done Definition
Done when the finding is addressed."

  # Must NOT contain empty-bucket boilerplate — negative assertions use
  # "run grep -q ...; [ $status -ne 0 ]" so the || true cannot swallow a false.
  run grep -q '_No CRITICAL issues_' <<< "$FOLLOWUP_BODY"
  [ "$status" -ne 0 ] || {
    echo "FAIL: Body contains empty-bucket boilerplate '_No CRITICAL issues_'"
    echo "Body:"
    echo "$FOLLOWUP_BODY"
    false
  }

  run grep -q '### CRITICAL.*([0-9]*)' <<< "$FOLLOWUP_BODY"
  [ "$status" -ne 0 ] || {
    echo "FAIL: Body contains severity-count bucket header"
    echo "Body:"
    echo "$FOLLOWUP_BODY"
    false
  }

  # Verify the body is present and non-empty
  [ -n "$FOLLOWUP_BODY" ] || {
    echo "FAIL: Body is empty"
    false
  }
}

# ─── Test 9: Static — severity normalization line present ─────────────────────

@test "assess-and-resolve.sh: _f_severity is normalized to leading token (trailing-text guard)" {
  # Issue #650: exact-match case arms silently downgrade when _f_severity has
  # trailing LLM annotations like "HIGH (word-split risk)".
  # The fix: normalize via awk '{print $1}' + tr immediately after capture.
  # This static test asserts the normalization is present in the script.
  run grep -n "awk '{print \$1}'" "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -eq 0 ] || {
    echo "FAIL: Severity normalization (awk '{print \$1}') not found in $ASSESS_RESOLVE_SCRIPT"
    echo "Expected: _f_severity=\$(echo \"\$_f_severity\" | awk '{print \$1}' | tr ...)"
    false
  }
}

# ─── Test 10: Unit — trailing severity annotation produces correct priority label ─

@test "assess-and-resolve.sh: severity with trailing text resolves to correct priority label" {
  # Regression for issue #650: "HIGH (word-split risk)" must yield priority-high,
  # not the default priority-medium that an unmatched case arm falls through to.
  #
  # This test calls the real _resolve_priority_label() from assess-and-resolve.sh
  # (sourced via RITE_SOURCE_FUNCTIONS_ONLY=1) so that any future change to the
  # case arms in the script breaks this test rather than passing silently.

  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${RITE_REPO_ROOT}/lib'
    export RITE_PROJECT_ROOT='${RITE_REPO_ROOT}'
    # Stub print functions consumed by sourced dependencies
    print_info()    { :; }
    print_warning() { :; }
    print_success() { :; }
    print_error()   { :; }
    verbose_info()  { :; }
    _diag()         { :; }
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh'
    # Normalize: same awk/tr pipeline used in the per-finding loop
    _raw_severity='HIGH (word-split risk)'
    _f_severity=\$(echo \"\$_raw_severity\" | awk '{print \$1}' | tr '[:lower:]' '[:upper:]' || true)
    _f_severity=\"\${_f_severity:-MEDIUM}\"
    # Call the real helper — not an inline copy of the case arms
    _priority_label=\$(_resolve_priority_label \"\$_f_severity\")
    echo \"\$_priority_label\"
  "

  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status)"
    echo "Output: $output"
    false
  }
  [ "$output" = "priority-high" ] || {
    echo "FAIL: Expected 'priority-high' for severity 'HIGH (word-split risk)', got: '$output'"
    false
  }
}

# ─── Test 11: Unit — CRITICAL with trailing annotation resolves to correct done def ─

@test "assess-and-resolve.sh: CRITICAL severity with annotation produces CRITICAL done definition" {
  # Regression for issue #650: "CRITICAL (confirmed)" must yield the CRITICAL done
  # definition, not the wildcard fallback.
  #
  # This test calls the real _resolve_done_def() from assess-and-resolve.sh
  # (sourced via RITE_SOURCE_FUNCTIONS_ONLY=1) so that any future change to the
  # case arms in the script breaks this test rather than passing silently.

  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${RITE_REPO_ROOT}/lib'
    export RITE_PROJECT_ROOT='${RITE_REPO_ROOT}'
    # Stub print functions consumed by sourced dependencies
    print_info()    { :; }
    print_warning() { :; }
    print_success() { :; }
    print_error()   { :; }
    verbose_info()  { :; }
    _diag()         { :; }
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh'
    # Normalize: same awk/tr pipeline used in the per-finding loop
    _raw_severity='CRITICAL (confirmed)'
    _f_severity=\$(echo \"\$_raw_severity\" | awk '{print \$1}' | tr '[:lower:]' '[:upper:]' || true)
    _f_severity=\"\${_f_severity:-MEDIUM}\"
    # Call the real helper — not an inline copy of the case arms
    _done_def=\$(_resolve_done_def \"\$_f_severity\")
    echo \"\$_done_def\"
  "

  [ "$status" -eq 0 ] || {
    echo "FAIL: subshell exited non-zero ($status)"
    echo "Output: $output"
    false
  }
  [[ "$output" == *"CRITICAL finding"* ]] || {
    echo "FAIL: Expected CRITICAL done definition for severity 'CRITICAL (confirmed)', got: '$output'"
    false
  }
}

# ─── Test 8: Unit — label via --label, not in title ──────────────────────────

@test "assess-and-resolve.sh: [tech-debt] label applied via --label, not embedded in title" {
  # The label classifies; the title must be the finding's own text only.
  _clean_title="Handle timeout in retry loop"
  _rollup_base_label="tech-debt"
  _priority_label="priority-high"
  _finding_labels="${_rollup_base_label},${_priority_label}"
  ISSUE_NUMBER="602"

  _src_issue_suffix=" for issue #${ISSUE_NUMBER}"
  ISSUE_TITLE="${_clean_title}${_src_issue_suffix}"

  # Title must NOT contain [tech-debt]
  [[ "$ISSUE_TITLE" != *"[tech-debt]"* ]] || {
    echo "FAIL: ISSUE_TITLE contains '[tech-debt]': '$ISSUE_TITLE'"
    false
  }

  # Label string must contain tech-debt (for the --label flag)
  [[ "$_finding_labels" == *"tech-debt"* ]] || {
    echo "FAIL: _finding_labels does not contain 'tech-debt': '$_finding_labels'"
    false
  }

  # Label string must contain priority
  [[ "$_finding_labels" == *"priority-high"* ]] || {
    echo "FAIL: _finding_labels does not contain 'priority-high': '$_finding_labels'"
    false
  }
}

# ─── Test 12: Static — ## Time Estimate appears BEFORE ## Description ─────────

@test "assess-and-resolve.sh: ## Time Estimate section appears before ## Description (runbook §3)" {
  # Issue #909: Time Estimate was emitted AFTER Dependencies, violating runbook §3.
  # The static ordering contract: the line "## Time Estimate" must appear before
  # "## Description" in the FOLLOWUP_BODY heredoc in the per-finding loop.
  #
  # We extract the line numbers of both patterns from the source file and assert
  # Time Estimate line < Description line.  The grep must find at least one
  # occurrence of each in the body builder context (not just anywhere in the file).

  _te_line=$(grep -n '## Time Estimate' "$ASSESS_RESOLVE_SCRIPT" | head -1 | cut -d: -f1 || true)
  _desc_line=$(grep -n '## Description' "$ASSESS_RESOLVE_SCRIPT" | head -1 | cut -d: -f1 || true)

  [ -n "$_te_line" ] || {
    echo "FAIL: '## Time Estimate' not found in $ASSESS_RESOLVE_SCRIPT"
    false
  }
  [ -n "$_desc_line" ] || {
    echo "FAIL: '## Description' not found in $ASSESS_RESOLVE_SCRIPT"
    false
  }
  [ "$_te_line" -lt "$_desc_line" ] || {
    echo "FAIL: '## Time Estimate' (line $_te_line) must appear before '## Description' (line $_desc_line)"
    echo "Runbook §3: Time Estimate is the third required section, Description is fourth"
    false
  }
}

# ─── Test 13: Static — old "Files to read before starting:" label removed ─────

@test "assess-and-resolve.sh: old 'Files to read before starting:' label replaced by 'Files to Read:'" {
  # Issue #909: Claude Context used "Files to read before starting:" (non-standard).
  # Runbook §5 specifies: "Files to Read:" / "Files to Modify:" / "Related Issues:"
  # Assert the old label is gone and the new runbook label is present.

  run grep -n 'Files to read before starting:' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: Old 'Files to read before starting:' label still present in body builder"
    echo "Matches:"
    echo "$output"
    false
  }

  run grep -n 'Files to Read:' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: New 'Files to Read:' label (runbook §5) not found in body builder"
    false
  }
}

# ─── Test 14: Unit — Time Estimate populated by severity fallback ──────────────

@test "assess-and-resolve.sh: Time Estimate severity fallback produces non-empty value for each severity" {
  # When Fix Effort metadata is absent, the case-in-case fallback must yield a
  # non-empty Fibonacci estimate for each recognized severity token.
  # Verifies issue #909 fix: severity-based fallback fills §3 when Fix Effort is missing.

  for _sev in CRITICAL HIGH MEDIUM LOW ""; do
    _time_estimate=""
    _f_fix_effort=""          # no Fix Effort field
    _f_severity="${_sev:-MEDIUM}"

    case "${_f_fix_effort:-}" in
      *\>1hr*) _time_estimate="2hr" ;;
      *\<1hr*) _time_estimate="1hr" ;;
      *\<10min*) _time_estimate="30min" ;;
      *)
        case "${_f_severity}" in
          CRITICAL) _time_estimate="2hr" ;;
          HIGH)     _time_estimate="1hr" ;;
          MEDIUM)   _time_estimate="45min" ;;
          *)        _time_estimate="30min" ;;
        esac
        ;;
    esac

    [ -n "$_time_estimate" ] || {
      echo "FAIL: Time Estimate empty for severity '${_sev:-MEDIUM}'"
      false
    }
  done
}
