#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-review-issues.sh, lib/core/assess-and-resolve.sh
#
# Regression tests for issue #910 — fix-loop assessment had no cross-round memory:
# new ACTIONABLE_NOW items on retry could be disjoint pre-existing findings, causing
# NOW count to grow instead of converge (live: PR #905, 2026-07-05).
#
# Fix: on retry passes (RITE_RETRY_COUNT > 0), assess-review-issues.sh:
#   1. Fetches ACTIONABLE_NOW items from the most recent prior assessment
#      (build_prior_now_ledger).
#   2. Injects them into the prompt with CONVERGENCE RULES:
#      - Prior NOW items: verify FIXED (→ DISMISSED) or NOT FIXED (→ re-raise NOW).
#      - New NOW items: only valid if introduced-by-fix or CRITICAL severity.
# On first pass (RETRY_COUNT=0) this section is empty — no behavior change.
#
# These are structural tests asserting prompt contract invariants.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export ASSESS_REVIEW_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"
  export ASSESS_AND_RESOLVE_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
  [ -f "$ASSESS_REVIEW_SCRIPT" ] || {
    echo "setup: ASSESS_REVIEW_SCRIPT not found at $ASSESS_REVIEW_SCRIPT" >&2
    false
  }
  [ -f "$ASSESS_AND_RESOLVE_SCRIPT" ] || {
    echo "setup: ASSESS_AND_RESOLVE_SCRIPT not found at $ASSESS_AND_RESOLVE_SCRIPT" >&2
    false
  }
}

teardown() {
  teardown_test_tmpdir
}

# ─── Test 1: build_prior_now_ledger function is defined ───────────────────────

@test "assess-review-issues.sh: build_prior_now_ledger function is defined" {
  run grep -n 'build_prior_now_ledger' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: build_prior_now_ledger not found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 2: convergence section is guarded by retry count check ──────────────

@test "assess-review-issues.sh: FIXREVIEW_NOW_SECTION is guarded by RETRY_COUNT > 0" {
  # The convergence rules must only activate on retry passes.
  run grep -n 'RETRY_COUNT.*gt 0\|RETRY_COUNT.*-gt 0' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no RETRY_COUNT > 0 guard found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 3: RITE_RETRY_COUNT is read from environment ───────────────────────

@test "assess-review-issues.sh: reads RITE_RETRY_COUNT from environment" {
  run grep -n 'RITE_RETRY_COUNT' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: RITE_RETRY_COUNT env var not read in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 4: assess-and-resolve.sh exports RITE_RETRY_COUNT ──────────────────

@test "assess-and-resolve.sh: exports RITE_RETRY_COUNT before calling assess-review-issues.sh" {
  run grep -n 'export RITE_RETRY_COUNT' "$ASSESS_AND_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: 'export RITE_RETRY_COUNT' not found in $ASSESS_AND_RESOLVE_SCRIPT"
    false
  }
}

# ─── Test 5: convergence section contains prior ACTIONABLE_NOW rule ────────────

@test "assess-review-issues.sh: convergence prompt contains prior ACTIONABLE_NOW verification rule" {
  run grep -n 'ACTIONABLE_NOW VERIFICATION\|Prior ACTIONABLE_NOW\|prior.*ACTIONABLE_NOW' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no prior ACTIONABLE_NOW verification rule found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 6: convergence section has tighter new-NOW bar ─────────────────────

@test "assess-review-issues.sh: convergence prompt has tighter new ACTIONABLE_NOW bar on retry" {
  # New NOW items on retry must be introduced-by-fix or CRITICAL.
  run grep -n 'introduced by the fix\|introduced by fix' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no 'introduced by fix' new-NOW bar found in $ASSESS_REVIEW_SCRIPT"
    false
  }

  run grep -n 'CRITICAL severity\|CRITICAL.*regardless' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no CRITICAL severity exception for new NOW items found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 7: prior NOW items must state which condition justifies new NOW ──────

@test "assess-review-issues.sh: convergence prompt requires justification for new ACTIONABLE_NOW items" {
  # The prompt must require the assessor to name the condition satisfied.
  run grep -n 'introduced by fix commits\|CRITICAL severity' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no justification condition wording found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 8: fixed prior NOW items become DISMISSED ──────────────────────────

@test "assess-review-issues.sh: convergence rule routes fixed prior NOW items to DISMISSED" {
  # A fixed prior NOW finding must not be re-raised as NOW — route it to DISMISSED.
  run grep -n 'FIXED.*DISMISSED\|classify.*DISMISSED' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no FIXED → DISMISSED routing rule found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 9: FIXREVIEW_NOW_SECTION is included in ASSESSMENT_PROMPT ───────────

@test "assess-review-issues.sh: FIXREVIEW_NOW_SECTION is included in ASSESSMENT_PROMPT" {
  run grep -n 'FIXREVIEW_NOW_SECTION' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: FIXREVIEW_NOW_SECTION not referenced in $ASSESS_REVIEW_SCRIPT"
    false
  }

  # Must appear in the ASSESSMENT_PROMPT assembly
  local block
  block=$(awk '/ASSESSMENT_PROMPT=/{f=1} f{print; if (/FIXREVIEW_NOW_SECTION/) exit}' "$ASSESS_REVIEW_SCRIPT")
  [[ "$block" == *"FIXREVIEW_NOW_SECTION"* ]] || {
    echo "FAIL: FIXREVIEW_NOW_SECTION not found in ASSESSMENT_PROMPT assembly"
    false
  }
}

# ─── Test 10: first-pass prompt is unchanged (section is empty at RETRY_COUNT=0) ─

@test "assess-review-issues.sh: FIXREVIEW_NOW_SECTION is empty on first pass (no RETRY_COUNT)" {
  # The variable must be initialized to "" before the retry guard.
  # Structural: the empty-init assignment must appear before the RETRY_COUNT > 0 check.
  local init_line guard_line
  init_line=$(grep -n 'FIXREVIEW_NOW_SECTION=""' "$ASSESS_REVIEW_SCRIPT" | head -1 || true)
  guard_line=$(grep -n 'RETRY_COUNT.*gt 0\|RETRY_COUNT.*-gt 0' "$ASSESS_REVIEW_SCRIPT" | head -1 || true)

  [ -n "$init_line" ] || {
    echo "FAIL: FIXREVIEW_NOW_SECTION=\"\" init not found in $ASSESS_REVIEW_SCRIPT"
    false
  }
  [ -n "$guard_line" ] || {
    echo "FAIL: RETRY_COUNT > 0 guard not found in $ASSESS_REVIEW_SCRIPT"
    false
  }

  local init_num guard_num
  init_num="${init_line%%:*}"
  guard_num="${guard_line%%:*}"
  [ "$init_num" -lt "$guard_num" ] || {
    echo "FAIL: FIXREVIEW_NOW_SECTION init (line $init_num) must appear before RETRY_COUNT guard (line $guard_num)"
    false
  }
}
