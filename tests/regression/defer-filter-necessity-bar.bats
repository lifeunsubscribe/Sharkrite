#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-review-issues.sh
# Regression test for: follow-up "defer filter" tightening (necessity bar)
#
# Problem: the assessment prompt's tie-break biased uncertain findings toward
# ACTIONABLE_LATER over DISMISSED, so cosmetic/nitpick findings were filed as
# follow-up ISSUES (a recent run produced ~6 follow-ups, several pure nitpicks).
#
# Fix: flip the tie-break for non-essential findings (DISMISSED over
# ACTIONABLE_LATER) and add a NECESSITY BAR to the ACTIONABLE_LATER definition —
# the assessor must state what concretely breaks/regresses, else DISMISSED.
#
# These tests are STRUCTURAL: the classification itself is the model's job, so we
# assert the prompt text in assess-review-issues.sh carries the necessity-bar
# language and the flipped tie-break.

load '../helpers/setup.bash'

setup() {
  export ASSESS_REVIEW_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"
  [ -f "$ASSESS_REVIEW_SCRIPT" ] || {
    echo "setup: ASSESS_REVIEW_SCRIPT not found at $ASSESS_REVIEW_SCRIPT" >&2
    false
  }
}

# ─── Test 1: NECESSITY BAR language is present in the prompt ───────────────────

@test "assess-review-issues.sh: ACTIONABLE_LATER prompt carries the necessity bar" {
  run grep -n "genuinely necessary future work" "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: necessity-bar language ('genuinely necessary future work') missing"
    false
  }

  # The bar must explicitly route nitpicks to DISMISSED rather than defer them.
  run grep -n "DISMISSED, not deferred" "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: 'DISMISSED, not deferred' language missing from necessity bar"
    false
  }
}

# ─── Test 2: tie-break now prefers DISMISSED for cosmetic findings ────────────

@test "assess-review-issues.sh: tie-break prefers DISMISSED over ACTIONABLE_LATER for nitpicks" {
  run grep -n "DISMISSED over ACTIONABLE_LATER" "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: tie-break does not flip to 'DISMISSED over ACTIONABLE_LATER'"
    false
  }

  # The old prefer-LATER-over-DISMISSED bias must be gone.
  run grep -n "ACTIONABLE_LATER over DISMISSED" "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: old 'ACTIONABLE_LATER over DISMISSED' bias still present:"
    echo "$output"
    false
  }
}

# ─── Test 3: ACTIONABLE_NOW tie-break preference is preserved ─────────────────

@test "assess-review-issues.sh: ACTIONABLE_NOW over ACTIONABLE_LATER tie-break preserved" {
  # The change is surgical: NOW-over-LATER (do not defer in-scope work) must stay.
  run grep -n "ACTIONABLE_NOW over ACTIONABLE_LATER" "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: 'ACTIONABLE_NOW over ACTIONABLE_LATER' tie-break was lost"
    false
  }
}
