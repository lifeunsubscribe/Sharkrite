#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh
# Regression test for: Remove shippable-defer branch from assess-and-resolve.sh
# Issue #717
#
# Background:
#   assess-and-resolve.sh previously had a "shippable-PR defer" branch
#   (lines ~1203-1233) that intercepted ACTIONABLE_NOW items whose severity was
#   all MEDIUM/LOW and routed them to a follow-up issue instead of the fix loop.
#   This caused the bucket label to lie: "NOW" items were deferred+merged with
#   fix_iterations=0. Observed regressions: finance-glance #60 (1px overlap),
#   #63 (NaN passthrough to int cast), and sharkrite #649 (3-cycle churn on
#   doc-consistency items).
#
#   Fix: deleted the shippable-defer branch entirely. NOW items always enter the
#   fix loop (exit 2) regardless of severity. Anything deferrable must be
#   classified ACTIONABLE_LATER or DISMISSED by the assessor.
#
# Tests in this file:
#   1. Static: no SHIPPABLE_DEFER variable reference remains in lib/
#   2. Static: no "Deferring.*NOW item" string in assess-and-resolve.sh
#   3. Static: no "PR is shippable" message in assess-and-resolve.sh
#      (was the print_success message in the removed defer branch)
#   4. Static: ACTIONABLE_NOW branch reaches fix loop (exit 2) as the
#      non-retry-cap else arm — confirmed by "Normal loop" comment presence
#   5. Static: CRITICAL_NOW_COUNT and HIGH_NOW_COUNT vars still computed
#      (still used by retry-cap branch for CRITICAL follow-up logic)
#
# Verification command:
#   bats tests/regression/assess-and-resolve-now-always-loops.bats

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

# ─── Test 1: No SHIPPABLE_DEFER references remain anywhere in lib/ ────────────

@test "assess-and-resolve: no SHIPPABLE_DEFER variable reference remains in lib/" {
  # The shippable-defer branch (issue #717) introduced SHIPPABLE_DEFER and its
  # downstream consumers. All must be deleted.
  local _lib_dir="${RITE_REPO_ROOT}/lib"
  run grep -rn "SHIPPABLE_DEFER" "$_lib_dir"

  # grep exits 1 when no matches — that is the success condition here.
  [ "$status" -ne 0 ] || {
    echo "FAIL: SHIPPABLE_DEFER reference(s) still present in lib/"
    echo "$output"
    false
  }
}

# ─── Test 2: No "Deferring.*NOW item" message ──────────────────────────────────

@test "assess-and-resolve: no 'Deferring.*NOW item' string in assess-and-resolve.sh" {
  run grep -n "Deferring.*NOW item" "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -ne 0 ] || {
    echo "FAIL: 'Deferring.*NOW item' message still present — shippable-defer branch not fully removed"
    echo "$output"
    false
  }
}

# ─── Test 3: No "PR is shippable" message ─────────────────────────────────────

@test "assess-and-resolve: no 'PR is shippable' message in assess-and-resolve.sh" {
  # The removed shippable-defer branch emitted "No CRITICAL/HIGH findings — PR is shippable".
  # That message must be gone; if it resurfaces a future contributor reintroduced the defer path.
  run grep -n "PR is shippable" "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -ne 0 ] || {
    echo "FAIL: 'PR is shippable' message still present — shippable-defer branch may still exist"
    echo "$output"
    false
  }
}

# ─── Test 4: Normal loop (exit 2) is the non-retry-cap else arm ───────────────

@test "assess-and-resolve: 'Normal loop' comment present (fix loop is surviving else branch)" {
  # After removing the shippable-defer if-branch, the structure under
  # ACTIONABLE_NOW_COUNT > 0 is:
  #   if [ "$RETRY_COUNT" -ge 3 ]; then  ← retry-cap handling
  #   else                               ← Normal loop: exit 2
  #
  # The "Normal loop" comment in the else branch confirms the fix loop survives
  # as the default path when retry count < 3.
  run grep -n "Normal loop" "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -eq 0 ] || {
    echo "FAIL: 'Normal loop' comment not found — may have accidentally deleted the fix-loop else branch"
    false
  }
}

# ─── Test 5: ACTIONABLE_NOW count feeds retry-cap CRITICAL check ─────────────

@test "assess-and-resolve: CRITICAL_NOW_COUNT and HIGH_NOW_COUNT still computed" {
  # These vars are computed in the ACTIONABLE_NOW branch and still used by the
  # retry-cap arm to decide whether to file a CRITICAL follow-up issue.
  # Deleting them would silently break the retry-cap CRITICAL logic.
  run grep -n "CRITICAL_NOW_COUNT" "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: CRITICAL_NOW_COUNT no longer computed in assess-and-resolve.sh"
    false
  }

  run grep -n "HIGH_NOW_COUNT" "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: HIGH_NOW_COUNT no longer computed in assess-and-resolve.sh"
    false
  }
}
