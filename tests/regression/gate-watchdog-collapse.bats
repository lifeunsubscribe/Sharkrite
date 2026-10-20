#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-verdict.sh::_gate_build_verdict, lib/utils/test-gate.sh
#
# Regression tests: watchdog-killed gate collapses N not-run tests into ONE
# [GATE] finding instead of emitting each as a separate ACTIONABLE_NOW item
# (issue #1130, live: batch 20261011-174713 slot #1021 — watchdog kill at 1800s →
# 690 not-run findings buried 5 real ones).
#
# Converted from run_test_gate (issue #1241): behavioral tests now call
# _gate_build_verdict directly with pre-built post-synthesis TAP fixtures —
# no stub runner, no git fixture, no subprocess spawning.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export RITE_REPO_ROOT
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: gate-verdict.sh uses a function-sentinel guard (declare -f _gate_write_json); pre-source _diag() stub is preserved on source.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/gate-verdict.sh"
  set +u; set +o pipefail
}

# =============================================================================
# BEHAVIORAL: watchdog-kill finding collapse
# =============================================================================

@test "watchdog kill — N not-run tests collapsed into exactly 1 finding" {
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  # Post-synthesis TAP: bats exited 124, run_test_gate collapsed 5 not-run tests
  # into one [tests_not_run] line before calling _gate_build_verdict.
  printf '1..5\nnot ok 1 [tests_not_run] watchdog killed bats group after 1800s — 5 tests not run; root cause is gate runtime, not the tests (reduce selection cost: add # sharkrite-gate-serial to load-heavy files, or scope lint rules with SHARKRITE_LINT_ONLY=N)\n' \
    > "$_tests_raw"

  _rc=0; _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 1 "$_out" "tests_not_run" "" || _rc=$?
  [ "$_rc" -eq 1 ]

  run jq -r '.exit_code' "$_out"
  [ "$output" = "1" ]

  # Exactly ONE test finding, not 5 individual ones
  run jq -r '.tests | length' "$_out"
  [ "$output" = "1" ]

  # The collapsed finding carries the watchdog and deficit markers
  run jq -r '.tests[0].test_name' "$_out"
  [[ "$output" == *"[tests_not_run]"* ]]
  [[ "$output" == *"watchdog"* ]]
  [[ "$output" == *"5 tests not run"* ]]

  # reason is tests_not_run (not assertion failed)
  run jq -r '.tests[0].reason' "$_out"
  [ "$output" = "tests_not_run" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

@test "watchdog kill with real failures — per-test failures kept, not-run collapsed to 1" {
  # Post-synthesis TAP: 5 planned, 1 real failure, then watchdog kills (exits 124).
  # TAP deficit = 5 - 1 = 4; real failure stays; 4 not-run collapsed to 1.
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  printf '1..5\nnot ok 1 real failing test\nnot ok 2 [tests_not_run] watchdog killed bats group after 1800s — 4 tests not run; root cause is gate runtime, not the tests (reduce selection cost: add # sharkrite-gate-serial to load-heavy files, or scope lint rules with SHARKRITE_LINT_ONLY=N)\n' \
    > "$_tests_raw"

  _rc=0; _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 1 "$_out" "tests_not_run" "" || _rc=$?
  [ "$_rc" -eq 1 ]

  run jq -r '.exit_code' "$_out"
  [ "$output" = "1" ]

  # 2 findings: 1 real failure + 1 collapsed not-run (not 5 total)
  run jq -r '.tests | length' "$_out"
  [ "$output" = "2" ]

  # First finding: the real per-test failure
  run jq -r '.tests[0].reason' "$_out"
  [ "$output" = "assertion failed" ]

  # Second finding: the collapsed watchdog not-run finding (4 = 5 planned - 1 reported)
  run jq -r '.tests[1].test_name' "$_out"
  [[ "$output" == *"[tests_not_run]"* ]]
  [[ "$output" == *"watchdog"* ]]
  [[ "$output" == *"4 tests not run"* ]]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

@test "watchdog kill with no TAP plan — gate produces exactly 1 not-run finding" {
  # Post-synthesis TAP: bats killed before emitting the plan line (SIGKILL = exit 137),
  # empty TAP. _fr_watchdog=true with deficit=0; run_test_gate emits a single
  # collapsed finding naming "0 tests not run".
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  printf 'not ok 1 [tests_not_run] watchdog killed bats group after 1800s — 0 tests not run; root cause is gate runtime, not the tests (reduce selection cost: add # sharkrite-gate-serial to load-heavy files, or scope lint rules with SHARKRITE_LINT_ONLY=N)\n' \
    > "$_tests_raw"

  _rc=0; _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 1 "$_out" "tests_not_run" "" || _rc=$?
  [ "$_rc" -eq 1 ]

  run jq -r '.exit_code' "$_out"
  [ "$output" = "1" ]

  # Exactly ONE collapsed finding (not zero) even with no plan deficit
  run jq -r '.tests | length' "$_out"
  [ "$output" = "1" ]

  run jq -r '.tests[0].reason' "$_out"
  [ "$output" = "tests_not_run" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

@test "no watchdog kill — normal exit 1 still uses per-test not-run synthesis" {
  # Post-synthesis TAP: plan/executed mismatch but no watchdog (exits 1, not 124).
  # _synthesize_notrun_findings emits per-test [tests_not_run] lines (deficit=2).
  # 2 planned, 0 reported = deficit 2 via exit 1 (swallowed test, not watchdog).
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  printf '1..2\nnot ok 1 [tests_not_run] planned test in selected bats file(s) never reported a result (bats plan/executed mismatch; killed before reporting)\nnot ok 2 [tests_not_run] planned test in selected bats file(s) never reported a result (bats plan/executed mismatch; killed before reporting)\n' \
    > "$_tests_raw"

  _rc=0; _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 1 "$_out" "" "" || _rc=$?
  [ "$_rc" -eq 1 ]

  run jq -r '.exit_code' "$_out"
  [ "$output" = "1" ]

  # With no watchdog, per-test synthesis runs: deficit=2 → 2 findings (not collapsed)
  run jq -r '.tests | length' "$_out"
  [ "$output" = "2" ]

  # No "watchdog killed" text in any finding (this is NOT a watchdog-collapse run)
  run jq -r '[.tests[].test_name] | join(" ")' "$_out"
  [[ "$output" != *"watchdog killed"* ]]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

# =============================================================================
# STRUCTURAL: source guards
# =============================================================================

@test "source: all three bats groups set _fr_watchdog on watchdog kill" {
  # Parallel, serial, and full-suite watchdog kill sites must all set _fr_watchdog=true
  run grep -c '_fr_watchdog=true' "$RITE_REPO_ROOT/lib/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

@test "source: watchdog collapse emits one finding with deficit and remediation hint" {
  local _sh="$RITE_REPO_ROOT/lib/utils/test-gate.sh"
  # The collapsed finding must carry the deficit count and a remediation hint
  grep -q 'watchdog killed.*tests not run.*reduce selection cost' "$_sh"
}

@test "source: _synthesize_notrun_findings preserved in else branch (normal non-watchdog path)" {
  local _sh="$RITE_REPO_ROOT/lib/utils/test-gate.sh"
  # _synthesize_notrun_findings must still exist for the non-watchdog path
  grep -q '_synthesize_notrun_findings' "$_sh"
  # The collapse and synthesis are in separate branches — both if and else present
  # in the not-run block — verify _fr_watchdog guards the split
  grep -q '_fr_watchdog.*false.*=.*true\|_fr_watchdog:-false' "$_sh"
}
