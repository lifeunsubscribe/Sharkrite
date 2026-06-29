#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-review-issues.sh
# Regression test for: #791 — assessment marks a feature "done" while deferring
# its OWN acceptance criteria to follow-ups, shipping it non-functional.
#
# Live case: LeadFlow's #46 CloudWatch-alarm feature merged while deferring its
# producer token (the event it must emit), its SNS subscription, and the alarm
# itself into follow-ups. The gate only blocks on TEST failures; those deferred
# ACs had no tests, so the unmet-AC feature merged clean.
#
# Fix (prompt-level): a SCOPE BAR rule in the ASSESSMENT_PROMPT classification
# criteria — a finding that identifies an UNMET acceptance criterion / core
# deliverable of the issue UNDER ASSESSMENT is ACTIONABLE_NOW and MUST NOT be
# deferred to ACTIONABLE_LATER. The classification itself is the model's call;
# these tests assert the prompt rule is present (structural).

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export ASSESS_REVIEW_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"
  [ -f "$ASSESS_REVIEW_SCRIPT" ] || {
    echo "setup: ASSESS_REVIEW_SCRIPT not found at $ASSESS_REVIEW_SCRIPT" >&2
    false
  }
}

teardown() {
  teardown_test_tmpdir
}

# ─── Test 1: the SCOPE BAR rule exists with its distinctive phrasing ──────────

@test "assess-review-issues.sh: ASSESSMENT_PROMPT forbids deferring the issue's own acceptance criteria" {
  # The rule must name an unmet acceptance criterion of the issue under work and
  # forbid deferring it to ACTIONABLE_LATER.
  run grep -n 'acceptance criterion' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no 'acceptance criterion' scope rule found in $ASSESS_REVIEW_SCRIPT"
    false
  }

  run grep -n 'MUST NOT be' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no 'MUST NOT be deferred' wording found in $ASSESS_REVIEW_SCRIPT"
    false
  }

  run grep -n 'ships it non-functional\|non-functional' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no 'non-functional' consequence wording found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 2: the rule directs NOW over LATER for in-scope deliverables ────────

@test "assess-review-issues.sh: unmet own deliverable is ACTIONABLE_NOW, not ACTIONABLE_LATER" {
  # Pull the SCOPE BAR block and assert the NOW-over-LATER intent is expressed
  # within it (not just somewhere unrelated in the file).
  run grep -n 'SCOPE BAR' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: SCOPE BAR rule heading not found in $ASSESS_REVIEW_SCRIPT"
    false
  }

  # The block must direct such findings to ACTIONABLE_NOW and bar ACTIONABLE_LATER.
  block=$(awk '/SCOPE BAR/{f=1} f{print} /^DISMISSED - Not worth tracking:/{f=0}' "$ASSESS_REVIEW_SCRIPT")

  [[ "$block" == *"ACTIONABLE_NOW"* ]] || {
    echo "FAIL: SCOPE BAR block does not direct findings to ACTIONABLE_NOW"
    echo "$block"
    false
  }
  [[ "$block" == *"ACTIONABLE_LATER"* ]] || {
    echo "FAIL: SCOPE BAR block does not reference ACTIONABLE_LATER (the deferral it bars)"
    echo "$block"
    false
  }
  [[ "$block" == *"OUTSIDE the issue's stated scope"* ]] || {
    echo "FAIL: SCOPE BAR block does not gate LATER on findings outside issue scope"
    echo "$block"
    false
  }
}

# ─── Test 3: the rule leans on the injected ORIGINAL ISSUE SCOPE context ──────

@test "assess-review-issues.sh: SCOPE BAR compares findings against injected issue scope" {
  # The assessment prompt injects the issue's own scope ($ISSUE_DETAILS) under an
  # "ORIGINAL ISSUE SCOPE" heading. The rule must lean on that so the assessor can
  # compare findings to the issue's own ACs.
  run grep -n 'ORIGINAL ISSUE SCOPE' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: ORIGINAL ISSUE SCOPE section (injected issue context) not found"
    false
  }

  run grep -n 'ISSUE_DETAILS' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: ISSUE_DETAILS (the injected issue body) not referenced in the prompt"
    false
  }

  # The SCOPE BAR rule explicitly tells the assessor to compare against that scope.
  block=$(awk '/SCOPE BAR/{f=1} f{print} /^DISMISSED - Not worth tracking:/{f=0}' "$ASSESS_REVIEW_SCRIPT")
  [[ "$block" == *"ORIGINAL ISSUE SCOPE"* ]] || {
    echo "FAIL: SCOPE BAR rule does not reference the ORIGINAL ISSUE SCOPE section"
    echo "$block"
    false
  }
}
