#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# sharkrite-gate-serial — spawns real sub-processes via run_test_gate (inner bats invocations)
#
# Regression tests: watchdog-killed gate collapses N not-run tests into ONE
# [GATE] finding instead of emitting each as a separate ACTIONABLE_NOW item
# (issue #1130, live: batch 20261011-174713 slot #1021 — watchdog kill at 1800s →
# 690 not-run findings buried 5 real ones).
#
# Integration pattern mirrors gate-block-on-any.bats: fake sharkrite repo +
# bats stub that exits 124 (the watchdog kill exit code from gtimeout/timeout).

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export RITE_REPO_ROOT
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"

  # Minimal fake sharkrite repo: no-op shellcheck:/lint: Makefile, one lib
  # file, and one covering bats test. Two commits so targeted selection fires.
  {
    printf '.PHONY: shellcheck lint\n'
    printf 'shellcheck:\n\t@echo ok\n'
    printf 'lint:\n\t@echo ok\n'
  } > "$TEST_REPO/Makefile"
  mkdir -p "$TEST_REPO/lib/utils" "$TEST_REPO/tests/regression"
  printf '#!/bin/bash\nfoo() { echo hi; }\n' > "$TEST_REPO/lib/utils/foo.sh"
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/utils/foo.sh\n@test "foo" { true; }\n' \
    > "$TEST_REPO/tests/regression/foo.bats"
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && printf '#!/bin/bash\nfoo() { echo changed; }\n' > lib/utils/foo.sh \
     && git add -A && git commit -qm change) >/dev/null 2>&1

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: test-gate.sh uses a function-sentinel guard (declare -f run_test_gate); pre-source _diag() stub is preserved on source.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
  set +u; set +o pipefail
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# _make_bats_stub — write a bats stub to $STUB_DIR/bats
# Args: $1 = TAP body to printf (e.g. '1..5\n'), $2 = exit code
_make_bats_stub() {
  local _tap_body="$1" _exit="$2"
  # Stub must NOT contain '--report-formatter' — that string in the binary
  # causes _bats_has_report_formatter to return true and the gate takes the
  # pretty path (report.tap in a dir). Without the string the gate uses plain
  # TAP (stdout → _tests_raw_file), which lets the plan line reach the deficit
  # detector. Argument parsing is avoided; any flags passed by the gate are
  # ignored and the stub always writes $_tap_body and exits $_exit.
  printf '#!/bin/bash\nprintf '"'"'%s'"'"'\nexit %s\n' "$_tap_body" "$_exit" \
    > "$STUB_DIR/bats"
  chmod +x "$STUB_DIR/bats"
}

# _run_gate — invoke run_test_gate in an isolated subshell with stub bats on PATH
# Args: $1 = output JSON path
_run_gate() {
  local _out="$1"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=1130
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH=\"$STUB_DIR:\$PATH\" run_test_gate \"$_out\" \"$TEST_REPO\"
  " </dev/null
}

# =============================================================================
# BEHAVIORAL: watchdog-kill finding collapse
# =============================================================================

@test "watchdog kill — N not-run tests collapsed into exactly 1 finding" {
  # Stub: 5 tests planned, none reported (all killed by watchdog), exits 124.
  _make_bats_stub '1..5\n' 124
  _out="$TEST_REPO/gate.json"
  _run_gate "$_out"

  [ "$status" -ne 127 ] || fail "run bash exited 127 (command not found) — PATH quoting bug or missing tool: $output"
  [ -f "$_out" ] || skip "gate fixture did not run in this environment (see #709)"

  # Gate still fails — block-on-any outcome=failed unchanged
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
}

@test "watchdog kill with real failures — per-test failures kept, not-run collapsed to 1" {
  # Stub: 5 tests planned, 1 real failure reported, then watchdog kills (exits 124).
  # TAP deficit = 5 - 1 = 4.
  _make_bats_stub '1..5\nnot ok 1 real failing test\n' 124
  _out="$TEST_REPO/gate.json"
  _run_gate "$_out"

  [ "$status" -ne 127 ] || fail "run bash exited 127 (command not found) — PATH quoting bug or missing tool: $output"
  [ -f "$_out" ] || skip "gate fixture did not run in this environment (see #709)"

  # Gate still fails
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
}

@test "watchdog kill with no TAP plan — gate produces exactly 1 not-run finding" {
  # Stub: bats killed before emitting the plan line (SIGKILL = exit 137), empty TAP.
  # _notrun_deficit is 0 and _notrun_warning is empty — the only trigger is _fr_watchdog.
  _make_bats_stub '' 137
  _out="$TEST_REPO/gate.json"
  _run_gate "$_out"

  [ "$status" -ne 127 ] || fail "run bash exited 127 (command not found) — PATH quoting bug or missing tool: $output"
  [ -f "$_out" ] || skip "gate fixture did not run in this environment (see #709)"

  # Gate fails
  run jq -r '.exit_code' "$_out"
  [ "$output" = "1" ]

  # Exactly ONE collapsed finding (not zero) even with no plan deficit
  run jq -r '.tests | length' "$_out"
  [ "$output" = "1" ]

  run jq -r '.tests[0].reason' "$_out"
  [ "$output" = "tests_not_run" ]
}

@test "no watchdog kill — normal exit 1 still uses per-test not-run synthesis" {
  # Stub: plan/executed mismatch but no watchdog (exits 1, not 124). The
  # existing _synthesize_notrun_findings path must still emit per-test findings.
  # 2 planned, 0 reported = deficit 2 via exit 1 (swallowed test, not watchdog).
  _make_bats_stub '1..2\n' 1
  _out="$TEST_REPO/gate.json"
  _run_gate "$_out"

  [ "$status" -ne 127 ] || fail "run bash exited 127 (command not found) — PATH quoting bug or missing tool: $output"
  [ -f "$_out" ] || skip "gate fixture did not run in this environment (see #709)"

  # Gate still fails
  run jq -r '.exit_code' "$_out"
  [ "$output" = "1" ]

  # With no watchdog, per-test synthesis runs: deficit=2 → 2 findings (not collapsed)
  run jq -r '.tests | length' "$_out"
  [ "$output" = "2" ]

  # No "watchdog killed" text in any finding (this is NOT a watchdog-collapse run)
  run jq -r '[.tests[].test_name] | join(" ")' "$_out"
  [[ "$output" != *"watchdog killed"* ]]
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
