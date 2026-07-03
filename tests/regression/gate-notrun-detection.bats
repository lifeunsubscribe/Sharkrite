#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, tests/regression/batch-locked-issue-in-progress-status.bats
#
# Regression tests: gate observability for bats plan-vs-executed mismatch
# (issue #804, PR #828's four blind fix rounds).
#
# bats-core 1.13 exits non-zero when fewer tests execute than the 1..N plan
# even with 0 reported failures, and a test killed before emitting its result
# writes NOTHING to report.tap. Before the fix, the gate reported exit_code=1
# with test_count=0 — a blocking gate with zero nameable findings. The gate
# now detects the mismatch (TAP plan deficit + the "Executed X instead of
# expected Y" warning in the captured pretty stream), emits synthetic
# [tests_not_run] not-ok findings naming the not-run tests when identifiable,
# and records reason=tests_not_run in the gate JSON.
#
# The live swallow requires a CONJUNCTION (spec 2x2 matrix): a bats file whose
# setup() leaks `set -euo pipefail` into the bats-exec-test shell AND
# BATS_TEST_TIMEOUT set (the gate exports it). Then a failing test triggers
# bats_kill_processes_of's untolerated `kill` (bats-exec-test:263) under the
# leaked errexit, killing bats-exec-test before the `not ok` line is emitted.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${RITE_LIB_DIR}/utils/test-gate.sh"
  # test-gate.sh leaks `set -euo pipefail` into this test shell — combined
  # with BATS_TEST_TIMEOUT (set by the gate) that leak is the exact swallow
  # this file guards against. Neutralize immediately after sourcing.
  set +eu
  set +o pipefail
}

# =============================================================================
# UNIT: _tap_plan_deficit
# =============================================================================

@test "unit: _tap_plan_deficit counts planned-but-unreported tests across concatenated sections" {
  _tap="$BATS_TEST_TMPDIR/concat.tap"
  cat > "$_tap" <<'EOF'
1..3
ok 1 first passes
ok 3 third passes
1..2
ok 1 serial a
not ok 2 serial b
EOF
  run _tap_plan_deficit "$_tap"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "unit: _tap_plan_deficit is 0 for a fully-reported TAP file" {
  _tap="$BATS_TEST_TMPDIR/full.tap"
  cat > "$_tap" <<'EOF'
1..2
ok 1 a
not ok 2 b
EOF
  run _tap_plan_deficit "$_tap"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "unit: _tap_plan_deficit is 0 for a missing or empty file" {
  run _tap_plan_deficit "$BATS_TEST_TMPDIR/does-not-exist.tap"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# =============================================================================
# UNIT: _extract_notrun_test_names (pretty-stream begin-without-result)
# =============================================================================

@test "unit: _extract_notrun_test_names names the begin-without-result test" {
  _pf="$BATS_TEST_TMPDIR/pretty.out"
  # Reproduce the real bats -F pretty in-place-update stream: cursor-to-column
  # CSI moves (ESC[<n>G) separate begin/result fragments on one physical line.
  printf '\033[34;1mswallow.bats\n' > "$_pf"
  printf '\033[0m\033[1G   first passes\033[K\033[77G1/3\033[2G\033[1G \342\234\223 first passes\033[K\n' >> "$_pf"
  printf '\033[0m\033[1G   second swallowed\033[K\033[77G2/3\033[2G\033[1G   third passes\033[K\033[77G3/3\033[2G\033[1G \342\234\223 third passes\033[K\n' >> "$_pf"
  printf '\033[0m   bats warning: Executed 2 instead of expected 3 tests\n' >> "$_pf"
  run _extract_notrun_test_names "$_pf"
  [ "$status" -eq 0 ]
  [ "$output" = "second swallowed" ]
}

@test "unit: _extract_notrun_test_names does not false-positive on skipped tests" {
  _pf="$BATS_TEST_TMPDIR/pretty-skip.out"
  # Skipped tests render as " - name (skipped: reason)" — the suffix must be
  # stripped when matching results against begins.
  printf '\033[34;1mskipmix.bats\n' > "$_pf"
  printf '\033[0m\033[1G   b skipped\033[K\033[77G1/2\033[2G\033[1G - b skipped (skipped: why)\033[K\n' >> "$_pf"
  printf '\033[0m\033[1G   c swallowed\033[K\033[77G2/2\033[2G\n' >> "$_pf"
  printf '   bats warning: Executed 1 instead of expected 2 tests\n' >> "$_pf"
  run _extract_notrun_test_names "$_pf"
  [ "$status" -eq 0 ]
  [ "$output" = "c swallowed" ]
}

# =============================================================================
# UNIT: _parse_bats_failure_line synthetic-marker reason
# =============================================================================

@test "unit: _parse_bats_failure_line emits reason tests_not_run for synthetic marker lines" {
  run _parse_bats_failure_line 'not ok 1 [tests_not_run] some test — began but never emitted a result'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason":"tests_not_run"'* ]]
  [[ "$output" == *'[tests_not_run] some test'* ]]
}

@test "unit: _parse_bats_failure_line keeps assertion-failed reason for real failures" {
  run _parse_bats_failure_line 'not ok 3 a genuinely failing test'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason":"assertion failed"'* ]]
}

# =============================================================================
# BEHAVIORAL: end-to-end gate run against a live swallowed test
# =============================================================================

@test "behavioral: gate emits tests_not_run finding instead of zero findings for a swallowed test" {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  command -v make >/dev/null 2>&1 || skip "make not installed"
  command -v git >/dev/null 2>&1 || skip "git not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  # --- Fixture repo: sharkrite-shaped (Makefile with shellcheck:/lint:) ---
  _repo="$BATS_TEST_TMPDIR/swallow-repo"
  mkdir -p "$_repo/tests"
  (cd "$_repo" && git init -q && git config user.email t@t.test && git config user.name t) || return 1
  printf 'shellcheck:\n\t@true\nlint:\n\t@true\n' > "$_repo/Makefile"
  (cd "$_repo" && git add -A && git commit -qm base) || return 1
  _base=$(cd "$_repo" && git rev-parse HEAD)

  # Swallow fixture per the spec 2x2 matrix: setup() sources a file that sets
  # `set -euo pipefail` (leaks into bats-exec-test); the gate itself exports
  # BATS_TEST_TIMEOUT; the failing test then gets killed before `not ok`.
  printf 'set -euo pipefail\n' > "$_repo/tests/strict-env.sh"
  cat > "$_repo/tests/swallow-fixture.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: tests/strict-env.sh
setup() { source "$BATS_TEST_DIRNAME/strict-env.sh"; }
@test "passes before" { true; }
@test "fails and is swallowed by leaked errexit plus timeout" { false; }
@test "passes after" { true; }
EOF
  (cd "$_repo" && git add -A && git commit -qm fixture) || return 1

  # --- Probe: does this bats version actually swallow? ---
  # If a future bats-core tolerates the kill at bats-exec-test:263, the failing
  # test reports a normal `not ok` and no synthetic finding is needed.
  _probe_tap="$BATS_TEST_TMPDIR/probe-tap"
  mkdir -p "$_probe_tap"
  (cd "$_repo" && BATS_TEST_TIMEOUT=120 BATS_REPORT_FILENAME=report.tap TERM=dumb \
    bats -F pretty --report-formatter tap --output "$_probe_tap" \
    tests/swallow-fixture.bats < /dev/null > /dev/null 2>&1) || true
  _probe_notok=$(grep -c '^not ok ' "$_probe_tap/report.tap" 2>/dev/null || true)
  [ "${_probe_notok:-0}" -eq 0 ] || skip "this bats version reports the failure normally (no swallow to detect)"

  # --- Run the real gate (subshell via `run`: run_test_gate manipulates the
  # EXIT trap, which must never touch this bats shell's own result trap) ---
  _out="$BATS_TEST_TMPDIR/gate.json"
  export RITE_TEST_GATE_DIFF_BASE="$_base"
  unset RITE_GATE_BACKGROUND RITE_GATE_FORCE_FULL 2>/dev/null || true
  run run_test_gate "$_out" "$_repo"

  # Gate must block (exit 1), with a nameable finding — not test_count=0.
  [ "$status" -eq 1 ] || {
    echo "FAIL: gate exit was $status, expected 1 (blocking)" >&2
    echo "$output" >&2
    return 1
  }
  [ -s "$_out" ] || {
    echo "FAIL: gate JSON not written" >&2
    return 1
  }
  grep -q '"reason":"tests_not_run"' "$_out" || {
    echo "FAIL: gate JSON lacks reason=tests_not_run:" >&2
    cat "$_out" >&2
    return 1
  }
  _tests_len=$(jq '.tests | length' "$_out")
  [ "${_tests_len:-0}" -ge 1 ] || {
    echo "FAIL: tests[] is empty — the fix loop would get zero nameable findings:" >&2
    cat "$_out" >&2
    return 1
  }
  [ "$(jq -r '.exit_code' "$_out")" = "1" ]
  # The swallowed test is named (pretty-stream begin-without-result).
  jq -r '.tests[].test_name' "$_out" | grep -q "swallowed" || {
    echo "FAIL: synthetic finding does not name the swallowed test:" >&2
    cat "$_out" >&2
    return 1
  }
}

# =============================================================================
# LANDMINE GUARD: batch-locked-issue-in-progress-status.bats
# =============================================================================

@test "structural: batch-locked-issue test file uses teardown, not an EXIT trap inside a @test" {
  _f="${BATS_TEST_DIRNAME}/batch-locked-issue-in-progress-status.bats"
  # A `trap ... EXIT` inside a @test body clobbers bats' result-emitting EXIT
  # trap: the file reports "Executed 0 instead of expected 1" and writes
  # nothing to report.tap — unconditionally (timeout-independent).
  ! grep -qE '^[[:space:]]+trap .*EXIT' "$_f"
  grep -qE '^teardown\(\)' "$_f"
}

@test "behavioral: batch-locked exit-14 integration test now reports a result line" {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  # Before the fix this exact invocation printed "Executed 0 instead of
  # expected 1 tests" and emitted NO ok/not-ok line (deterministic, with and
  # without BATS_TEST_TIMEOUT).
  run env TERM=dumb bats -f "returns 14 when phase_claude_workflow" \
    "${BATS_TEST_DIRNAME}/batch-locked-issue-in-progress-status.bats" < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1"* ]]
  [[ "$output" != *"Executed 0 instead of expected"* ]]
}
