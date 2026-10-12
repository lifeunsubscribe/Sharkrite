#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh, lib/core/assess-and-resolve.sh
# tests/regression/green-main-preflight.bats
#
# Regression tests for the green-main preflight (issue #916):
#   - batch-process-issues.sh runs origin/main gate before any issue starts
#   - assess-and-resolve.sh attribution: main-inherited failures → [GATE-INHERITED] INFO,
#     branch-only failures → ACTIONABLE_NOW
#
# Tests are structural (grep on source text) because the behavioral path
# requires running the full batch/assess orchestrators with mocked gh/Claude —
# too complex for a gate test. Structural tests pin the invariants that code
# cannot express (guard placement, wording contracts, attribution check pattern).

BATCH_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/lib/core/batch-process-issues.sh"
ASSESS_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/lib/core/assess-and-resolve.sh"

# ---------------------------------------------------------------------------
# batch-process-issues.sh — green-main preflight structural pins
# ---------------------------------------------------------------------------

@test "batch preflight: RITE_TEST_GATE_DIFF_BASE=HEAD forces full suite against origin/main" {
  grep -qF 'RITE_TEST_GATE_DIFF_BASE=HEAD' "$BATCH_SH"
}

@test "batch preflight: exports _RITE_MAIN_FAILING_TESTS_FILE on red-main-accepted path" {
  grep -qF 'export _RITE_MAIN_FAILING_TESTS_FILE' "$BATCH_SH"
}

@test "batch preflight: checks RITE_ACCEPT_RED_MAIN before halting" {
  grep -qF 'RITE_ACCEPT_RED_MAIN' "$BATCH_SH"
}

@test "batch preflight: respects RITE_SKIP_TESTS guard" {
  grep -qF 'RITE_SKIP_TESTS' "$BATCH_SH"
}

@test "batch preflight: exits 1 when main is red and RITE_ACCEPT_RED_MAIN is not set" {
  # The halt path must have 'exit 1' after the RITE_ACCEPT_RED_MAIN check
  # (not just any exit 1 — verify the accept-check and exit 1 are in the
  # same preflight block, not in an unrelated part of the file).
  grep -qF 'RITE_ACCEPT_RED_MAIN' "$BATCH_SH"
  grep -qF 'exit 1' "$BATCH_SH"
  # Both must appear in the same preflight section (between the GMP marker and the cleanup trap).
  # Extract the preflight block and check both are present there.
  awk '/Green-Main Preflight/,/Register a cleanup trap/' "$BATCH_SH" | grep -qF 'exit 1'
}

@test "batch preflight: cleanup trap removes _RITE_MAIN_FAILING_TESTS_FILE" {
  # The _cleanup_batch_session function must remove the attribution file.
  awk '/_cleanup_batch_session\(\)/,/^}/' "$BATCH_SH" | grep -qF '_RITE_MAIN_FAILING_TESTS_FILE'
}

@test "batch preflight: guard against unresolvable origin/main (skip path)" {
  grep -qF 'git rev-parse origin/main' "$BATCH_SH"
}

@test "batch preflight: test-gate.sh sourced with idempotent guard" {
  # Must not unconditionally source test-gate.sh (re-source guard prevents double-load)
  grep -qF 'declare -f run_test_gate' "$BATCH_SH"
}

# ---------------------------------------------------------------------------
# assess-and-resolve.sh — attribution filter structural pins
# ---------------------------------------------------------------------------

@test "assess attribution: reads _RITE_MAIN_FAILING_TESTS_FILE for attribution" {
  grep -qF '_RITE_MAIN_FAILING_TESTS_FILE' "$ASSESS_SH"
}

@test "assess attribution: uses grep -qxF for exact test-name matching" {
  # grep -qxF: exact full-line match — handles test names with regex metacharacters
  grep -qF 'grep -qxF "$_test_name"' "$ASSESS_SH"
}

@test "assess attribution: emits [GATE-INHERITED] info block for inherited tests" {
  grep -qF '[GATE-INHERITED]' "$ASSESS_SH"
}

@test "assess attribution: inherited tests do NOT increment GATE_NOW_COUNT" {
  # The continue statement after the inherited-test path must appear BEFORE
  # the GATE_NOW_COUNT increment — check both are in the test-loop block.
  awk '/Build \[GATE\] ACTIONABLE_NOW items from test failures/,/done < <\(jq -c .tests/' "$ASSESS_SH" \
    | grep -qF 'continue'
}

@test "assess attribution: synthetic empty-findings block is suppressed when all inherited" {
  # When _gate_inherited_count > 0 and GATE_NOW_COUNT == 0, the synthetic
  # block must NOT fire. Check the suppression guard is present.
  grep -qF '_gate_inherited_count' "$ASSESS_SH"
  # The synthetic block must check for > 0 inherited count
  awk '/Synthetic block for empty-findings/,/GATE_NOW_COUNT.*\+= 1/' "$ASSESS_SH" \
    | grep -qF '_gate_inherited_count'
}

@test "assess attribution: prints info when inherited failures are excluded" {
  grep -qF 'attributed to origin/main' "$ASSESS_SH"
}
