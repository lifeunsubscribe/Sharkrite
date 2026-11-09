#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/core/assess-review-issues.sh
#
# Conformance tests for follow-up issue body builders (issue #1551).
#
# Verifies that both body builders produce runbook-compliant content derived
# from #1546's structured assessment fields (Suggested Fix, Verification,
# Location) rather than placeholder strings, and that backward-compatibility
# is maintained for assessments that lack those fields.
#
# Tests:
#   1. _resolve_done_def: MEDIUM → bounded sentence (no "deferred with justification")
#   2. _resolve_done_def: CRITICAL → targeted sentence (unchanged)
#   3. Source grep: no '_Determine from the finding above_' placeholder in either builder
#   4. Source grep: no 'TODO: add verification command' string in either builder
#   5. assess-review-issues.sh: finding WITH Location → Files to Modify seeded from path
#   6. assess-review-issues.sh: finding WITHOUT Location → Files to Modify names absence
#   7. assess-review-issues.sh: finding WITH Suggested Fix → acceptance criterion embeds fix text
#   8. assess-review-issues.sh: finding WITH Verification field → verification command uses it
#   9. assess-review-issues.sh: backward-compat (no #1546 fields) → valid body, no placeholders

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

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Isolate RITE_LOCK_DIR before sourcing config so write_followup_evidence
  # stays inside the test tmpdir (mirrors assess-review-issues-richbody-followup.bats).
  export RITE_TEST_TMPDIR="${RITE_TEST_TMPDIR:-$(mktemp -d)}"
  export RITE_LOCK_DIR="${RITE_TEST_TMPDIR}/locks"
}

teardown() {
  teardown_test_tmpdir
  rm -rf "${MOCK_PROVIDER_DIR:-}"
  rm -f "${MOCK_REVIEW_FILE:-}"
}

# ─── Setup helpers for E2E tests ─────────────────────────────────────────────

_setup_e2e() {
  export PR_NUMBER=42
  export RITE_ISSUE_NUMBER=15
  export AUTO_MODE=true

  export MOCK_REVIEW_FILE
  MOCK_REVIEW_FILE=$(mktemp)
  cat > "$MOCK_REVIEW_FILE" <<'EOF'
## Code Review Summary

**Findings: CRITICAL: 0 | HIGH: 1 | MEDIUM: 0 | LOW: 0**
EOF

  export MOCK_PROVIDER_DIR
  MOCK_PROVIDER_DIR=$(mktemp -d)
  export PATH="${MOCK_PROVIDER_DIR}:${PATH}"

  export CREATE_CAPTURE="${MOCK_PROVIDER_DIR}/issue-create-bodies.txt"
  : > "$CREATE_CAPTURE"
  export TITLE_CAPTURE="${MOCK_PROVIDER_DIR}/issue-create-titles.txt"
  : > "$TITLE_CAPTURE"

  # Default mock gh: captures issue create bodies; benign for everything else.
  cat > "${MOCK_PROVIDER_DIR}/gh" <<MOCK_EOF
#!/bin/bash
CREATE_CAPTURE="${CREATE_CAPTURE}"
TITLE_CAPTURE="${TITLE_CAPTURE}"
MOCK_EOF
  cat >> "${MOCK_PROVIDER_DIR}/gh" <<'MOCK_EOF'
case "$1" in
  pr)
    case "$2" in
      view)
        echo '{"body":"Closes #15","comments":[],"files":[{"path":"lib/core/foo.sh"}],"headRefName":"fix-15-conf"}'
        ;;
      comment) exit 0 ;;
      *)       exit 0 ;;
    esac
    ;;
  issue)
    case "$2" in
      list)   echo '[]' ;;
      view)   echo '{"body":""}' ;;
      create)
        _title=""
        _bodyfile=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --title)     _title="$2";     shift 2 ;;
            --body-file) _bodyfile="$2";  shift 2 ;;
            *)           shift ;;
          esac
        done
        printf '%s\n' "$_title" >> "$TITLE_CAPTURE"
        { echo "===ISSUE_BODY_START==="; cat "$_bodyfile"; echo ""; echo "===ISSUE_BODY_END==="; } >> "$CREATE_CAPTURE"
        _n=$(( $(grep -c '===ISSUE_BODY_START===' "$CREATE_CAPTURE") + 100 ))
        echo "https://github.com/test/repo/issues/${_n}"
        ;;
      edit) exit 0 ;;
      *)    exit 0 ;;
    esac
    ;;
  label) exit 0 ;;
  *)     exit 0 ;;
esac
MOCK_EOF
  chmod +x "${MOCK_PROVIDER_DIR}/gh"
}

# Extract the Nth captured issue body (1-based).
_nth_body() {
  local _n="$1"
  awk -v want="$_n" '
    /===ISSUE_BODY_START===/ { idx++; if (idx==want) { capturing=1; next } }
    /===ISSUE_BODY_END===/   { if (capturing) { capturing=0 } }
    capturing { print }
  ' "$CREATE_CAPTURE"
}

_run_assess() {
  run bash "${RITE_LIB_DIR}/core/assess-review-issues.sh" "$PR_NUMBER" "$MOCK_REVIEW_FILE" --auto
  [ "$status" -eq 0 ] || {
    echo "assess-review-issues.sh exited $status"
    echo "--- output ---"
    echo "$output"
    false
  }
}

# ─── Tests 1-2: _resolve_done_def unit tests ─────────────────────────────────

@test "_resolve_done_def: MEDIUM severity produces bounded sentence (no 'explicitly deferred')" {
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail

  run _resolve_done_def "MEDIUM"
  [ "$status" -eq 0 ] || { echo "FAIL: _resolve_done_def exited $status"; false; }

  # Must NOT contain the runbook anti-example phrase.
  echo "$output" | grep -qF "explicitly deferred with justification" && {
    echo "FAIL: MEDIUM done-def still contains runbook anti-example phrase"
    echo "output: $output"
    false
  }
  # Must be a non-empty bounded sentence.
  [ -n "$output" ] || { echo "FAIL: empty done-def for MEDIUM"; false; }
}

@test "_resolve_done_def: CRITICAL severity produces targeted sentence (unchanged)" {
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail

  run _resolve_done_def "CRITICAL"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "CRITICAL finding is resolved" || {
    echo "FAIL: CRITICAL done-def changed unexpectedly"
    echo "output: $output"
    false
  }
}

# ─── Tests 3-4: placeholder removal structural greps ─────────────────────────

@test "assess-and-resolve.sh: '_Determine from the finding above_' placeholder is gone" {
  run grep -F '_Determine from the finding above_' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: '_Determine from the finding above_' placeholder still present in $ASSESS_RESOLVE_SCRIPT"
    echo "$output"
    false
  }
}

@test "assess-review-issues.sh: '_Determine from the finding above_' placeholder is gone" {
  run grep -F '_Determine from the finding above_' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: '_Determine from the finding above_' placeholder still present in $ASSESS_REVIEW_SCRIPT"
    echo "$output"
    false
  }
}

@test "assess-and-resolve.sh: 'TODO: add verification command' string is gone" {
  run grep -F 'TODO: add verification command' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: 'TODO: add verification command' still present in $ASSESS_RESOLVE_SCRIPT"
    echo "$output"
    false
  }
}

@test "assess-review-issues.sh: 'TODO: add verification command' string is gone" {
  run grep -F 'TODO: add verification command' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: 'TODO: add verification command' still present in $ASSESS_REVIEW_SCRIPT"
    echo "$output"
    false
  }
}

@test "assess-and-resolve.sh: 'explicitly deferred with justification' string is gone" {
  run grep -F 'explicitly deferred with justification' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: 'explicitly deferred with justification' anti-pattern still present in $ASSESS_RESOLVE_SCRIPT"
    echo "$output"
    false
  }
}

# ─── Tests 5-6: Files to Modify seeded from Location ─────────────────────────

@test "conformance: finding WITH Location → Files to Modify seeded from path" {
  _setup_e2e

  # Claude emits one HIGH finding with a Location field.
  cat > "${MOCK_PROVIDER_DIR}/claude" <<'MOCK_EOF'
#!/bin/bash
cat <<'ASSESSMENT_EOF'
### Missing bounds check - ACTIONABLE_LATER

**Severity:** HIGH
**Category:** Security
**Reasoning:** Buffer is not bounds-checked before use.
**Context:** Tracked for follow-up.
**Location:** lib/core/validate.sh:88
**Defer Reason:** Needs broader refactor.
ASSESSMENT_EOF
exit 0
MOCK_EOF
  chmod +x "${MOCK_PROVIDER_DIR}/claude"

  _run_assess

  local _body
  _body=$(_nth_body 1)
  [ -n "$_body" ] || { echo "FAIL: no issue body captured"; cat "$CREATE_CAPTURE"; false; }

  # Files to Modify must reference the path from the Location field.
  echo "$_body" | grep -qF "- lib/core/validate.sh" || {
    echo "FAIL: Files to Modify does not contain the Location path 'lib/core/validate.sh'"
    echo "--- body ---"
    echo "$_body"
    false
  }

  # Must NOT contain the old placeholder.
  echo "$_body" | grep -qF "_Determine from the finding above_" && {
    echo "FAIL: old '_Determine from the finding above_' placeholder still present"
    echo "$_body"
    false
  }
  return 0
}

@test "conformance: finding WITHOUT Location → Files to Modify names the absence explicitly" {
  _setup_e2e

  # Claude emits one MEDIUM finding with no Location field.
  cat > "${MOCK_PROVIDER_DIR}/claude" <<'MOCK_EOF'
#!/bin/bash
cat <<'ASSESSMENT_EOF'
### Vague error message - ACTIONABLE_LATER

**Severity:** MEDIUM
**Category:** UX
**Reasoning:** Error text is too vague for users to act on.
**Context:** Low priority follow-up.
**Defer Reason:** Cosmetic issue.
ASSESSMENT_EOF
exit 0
MOCK_EOF
  chmod +x "${MOCK_PROVIDER_DIR}/claude"

  _run_assess

  local _body
  _body=$(_nth_body 1)
  [ -n "$_body" ] || { echo "FAIL: no issue body captured"; cat "$CREATE_CAPTURE"; false; }

  # Files to Modify must state that no location is available, not a TODO placeholder.
  echo "$_body" | grep -qF "No location field in assessment" || {
    echo "FAIL: Files to Modify does not state absence of location field"
    echo "--- body ---"
    echo "$_body"
    false
  }

  echo "$_body" | grep -qF "_Determine from the finding above_" && {
    echo "FAIL: old '_Determine from the finding above_' placeholder still present"
    echo "$_body"
    false
  }
  return 0
}

# ─── Test 7: Suggested Fix embedded in acceptance criterion ───────────────────

@test "conformance: finding WITH Suggested Fix → acceptance criterion embeds the fix text" {
  _setup_e2e

  cat > "${MOCK_PROVIDER_DIR}/claude" <<'MOCK_EOF'
#!/bin/bash
cat <<'ASSESSMENT_EOF'
### Unvalidated user input - ACTIONABLE_LATER

**Severity:** HIGH
**Category:** Security
**Reasoning:** Input is used without sanitization.
**Context:** Needs dedicated fix.
**Location:** lib/core/handler.sh:55
**Suggested Fix:** Add sanitize_input() call before processing the value at handler.sh:55
**Defer Reason:** Needs broader auth refactor.
ASSESSMENT_EOF
exit 0
MOCK_EOF
  chmod +x "${MOCK_PROVIDER_DIR}/claude"

  _run_assess

  local _body
  _body=$(_nth_body 1)
  [ -n "$_body" ] || { echo "FAIL: no issue body captured"; cat "$CREATE_CAPTURE"; false; }

  # Acceptance criterion must include the suggested fix text, not just the title.
  echo "$_body" | grep -qF "Add sanitize_input() call" || {
    echo "FAIL: acceptance criterion does not embed the Suggested Fix text"
    echo "--- Acceptance Criteria section ---"
    echo "$_body" | sed -n '/## Acceptance Criteria/,/## /p' | head -5
    echo "--- full body ---"
    echo "$_body"
    false
  }
  return 0
}

# ─── Test 8: Verification field used in Verification Commands ─────────────────

@test "conformance: finding WITH Verification field → verification command uses it" {
  _setup_e2e

  cat > "${MOCK_PROVIDER_DIR}/claude" <<'MOCK_EOF'
#!/bin/bash
cat <<'ASSESSMENT_EOF'
### Missing error handler - ACTIONABLE_LATER

**Severity:** HIGH
**Category:** Reliability
**Reasoning:** Error path is unhandled; function returns without cleanup.
**Context:** Needs dedicated fix.
**Location:** lib/core/runner.sh:120
**Suggested Fix:** Add error trap and cleanup call in runner.sh:120
**Verification:** grep -n error_handler lib/core/runner.sh
**Defer Reason:** Part of larger reliability work.
ASSESSMENT_EOF
exit 0
MOCK_EOF
  chmod +x "${MOCK_PROVIDER_DIR}/claude"

  _run_assess

  local _body
  _body=$(_nth_body 1)
  [ -n "$_body" ] || { echo "FAIL: no issue body captured"; cat "$CREATE_CAPTURE"; false; }

  # Verification Commands section must contain the value from the Verification field.
  echo "$_body" | grep -qF "grep -n error_handler lib/core/runner.sh" || {
    echo "FAIL: Verification Commands section does not contain the Verification field value"
    echo "--- Verification Commands section ---"
    echo "$_body" | sed -n '/## Verification Commands/,/## /p' | head -5
    echo "--- full body ---"
    echo "$_body"
    false
  }
  return 0
}

# ─── Test 9: backward-compat — assessment WITHOUT #1546 fields ───────────────

@test "conformance: backward-compat — assessment without #1546 fields produces valid body" {
  _setup_e2e

  # Minimal assessment: no Suggested Fix, no Verification, no Location.
  cat > "${MOCK_PROVIDER_DIR}/claude" <<'MOCK_EOF'
#!/bin/bash
cat <<'ASSESSMENT_EOF'
### Legacy-format finding - ACTIONABLE_LATER

**Severity:** MEDIUM
**Category:** Code Quality
**Reasoning:** This is an old-style assessment without structured fields.
**Context:** Needs updating.
**Defer Reason:** Low priority.
ASSESSMENT_EOF
exit 0
MOCK_EOF
  chmod +x "${MOCK_PROVIDER_DIR}/claude"

  _run_assess

  local _body
  _body=$(_nth_body 1)
  [ -n "$_body" ] || { echo "FAIL: no issue body captured"; cat "$CREATE_CAPTURE"; false; }

  # Body must be valid: all required sections present.
  for _section in '## Description' '## Acceptance Criteria' '## Verification Commands' '## Done Definition' '## Scope Boundary'; do
    echo "$_body" | grep -qF "$_section" || {
      echo "FAIL: backward-compat body missing section: $_section"
      echo "--- body ---"
      echo "$_body"
      false
    }
  done

  # No placeholder strings from the old builders.
  echo "$_body" | grep -qF "_Determine from the finding above_" && {
    echo "FAIL: backward-compat body still contains '_Determine from the finding above_'"
    echo "$_body"; false
  }
  echo "$_body" | grep -qF "TODO: add verification command" && {
    echo "FAIL: backward-compat body still contains 'TODO: add verification command'"
    echo "$_body"; false
  }
  echo "$_body" | grep -qF "explicitly deferred with justification" && {
    echo "FAIL: backward-compat body still contains runbook anti-example done-def"
    echo "$_body"; false
  }

  # Degraded sections must state what is missing rather than blank.
  echo "$_body" | grep -qF "No location field in assessment" || {
    echo "FAIL: backward-compat body does not state absence of location field"
    echo "--- body ---"
    echo "$_body"
    false
  }
  echo "$_body" | grep -qF "no verification field in assessment" || {
    echo "FAIL: backward-compat body does not state absence of verification field"
    echo "--- body ---"
    echo "$_body"
    false
  }
  return 0
}
