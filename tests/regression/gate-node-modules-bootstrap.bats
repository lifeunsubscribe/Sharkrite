#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# Issue #784: node test gate false-fails on missing node_modules.
#
# rite worktrees never get node_modules (untracked). The non-Sharkrite npm
# branch of run_test_gate must:
#   1. bootstrap node_modules (npm ci / npm install) BEFORE running npm test, and
#   2. treat a 127 "command not found" exit from the runner as a HARD BLOCK
#      (could-not-verify) — never a skip, never a pass. A skip-that-passes ships
#      breaks (Pilot's correction).
#
# Uses the full run_test_gate harness against a NON-Sharkrite fixture repo
# (package.json only — no Makefile shellcheck:/lint: targets, no tests/ dir, no
# pytest.ini) so the npm branch is selected. `npm` is stubbed on PATH so each
# test controls the bootstrap + test-run outcome deterministically.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"; export STUB_DIR
  # Marker the npm stub touches when its `ci`/`install` subcommand runs.
  BOOTSTRAP_MARKER="$TEST_REPO/bootstrap-was-invoked"; export BOOTSTRAP_MARKER

  # Non-Sharkrite node repo: package.json + lockfile (so the bootstrap chooses
  # `npm ci`), a source file, and a git history so the diff-base resolves.
  # Deliberately NO Makefile, NO tests/ dir, NO pytest.ini — keeps the manifest
  # ladder on the package.json (npm) branch.
  printf '{"name":"fix","version":"1.0.0","scripts":{"test":"jest"}}\n' > "$TEST_REPO/package.json"
  printf '{"lockfileVersion":3}\n' > "$TEST_REPO/package-lock.json"
  printf 'export const x = 1;\n' > "$TEST_REPO/index.js"
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && printf 'export const x = 2;\n' > index.js \
     && git add -A && git commit -qm change) >/dev/null 2>&1

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# Helper: write an `npm` stub whose `ci`/`install` touches BOOTSTRAP_MARKER and
# whose `test` subcommand emits $1 to stdout and exits $2.
_write_npm_stub() {
  local _test_stdout="$1" _test_exit="$2"
  cat > "$STUB_DIR/npm" <<STUB
#!/bin/bash
case "\$1" in
  ci|install)
    # Simulate node_modules bootstrap; record that it ran.
    touch "$BOOTSTRAP_MARKER"
    mkdir -p "$TEST_REPO/node_modules"
    exit 0
    ;;
  test)
    printf '%s\n' "$_test_stdout"
    exit $_test_exit
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/npm"
}

# Helper: run the gate against the fixture with STUB_DIR ahead on PATH.
# Captures _diag lines to $TEST_REPO/diag.log so the structured outcome/reason
# can be asserted (the gate writes diag, not the JSON, for the reason field on
# the runner-unavailable path).
_run_gate() {
  : > "$TEST_REPO/diag.log"
  # Set RITE_LOG_FILE so the real _diag (from logging.sh, sourced transitively)
  # writes its structured [diag] lines where we can assert them. _gate_raw_sink
  # defaults to RITE_LOG_FILE too, so bootstrap chatter also lands there.
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=784 RITE_LOG_FILE='$TEST_REPO/diag.log'
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
}

# ---------------------------------------------------------------------------
# Case (a): package.json + no node_modules + `npm ci` succeeds + `npm test`
# passes → gate runs, outcome=passed, AND bootstrap was invoked.
# ---------------------------------------------------------------------------
@test "(a) no node_modules → bootstrap invoked, npm test passes → outcome=passed" {
  _write_npm_stub "PASS all tests" 0
  [ ! -d "$TEST_REPO/node_modules" ]   # precondition: absent

  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # Bootstrap MUST have run (the whole point of #784).
  [ -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: node_modules bootstrap was not invoked before npm test"
    false
  }

  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Case (b): `npm test` exits 127 (jest missing) → outcome=failed
# reason=runner_unavailable, gate result BLOCKS (non-zero). NOT skipped, NOT
# passed. This is the core could-not-verify hard-block.
# ---------------------------------------------------------------------------
@test "(b) npm test exit 127 (runner missing) → BLOCKS (not skip, not pass)" {
  _write_npm_stub "sh: jest: command not found" 127
  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # Bootstrap still ran (it just couldn't make jest available in this scenario).
  [ -f "$BOOTSTRAP_MARKER" ]

  # MUST block: non-zero return + exit_code=1 in JSON.
  [ "$status" -eq 1 ] || {
    echo "FAIL: expected blocking (status 1), got status $status"
    echo "      127 must hard-block, never skip/pass."
    false
  }
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "1" ] || {
    echo "FAIL: expected exit_code=1, got '$output'"
    false
  }

  # Must NOT be recorded as a skip (skip would fake-green the merge).
  run jq -r '.skipped // "false"' "$TEST_REPO/gate.json"
  [ "$output" != "true" ] || {
    echo "FAIL: 127 runner-unavailable must NOT be a skip — that fake-greens the merge"
    false
  }

  # Distinct diagnostic: outcome=failed reason=runner_unavailable.
  run grep -q "TEST_GATE outcome=failed reason=runner_unavailable" "$TEST_REPO/diag.log"
  [ "$status" -eq 0 ] || {
    echo "FAIL: expected 'TEST_GATE outcome=failed reason=runner_unavailable' diag"
    echo "--- diag.log ---"; cat "$TEST_REPO/diag.log"
    false
  }
}

# ---------------------------------------------------------------------------
# Case (b2): runner emits "command not found" but exits 0 (some shell wrappers
# swallow the child's exit code). The guard's output-signature branch must
# still HARD BLOCK — this is the case the bare `_tests_exit != 0` check would
# miss, proving the guard adds coverage beyond block-on-any.
# ---------------------------------------------------------------------------
@test "(b2) 'command not found' in output but exit 0 → still BLOCKS via guard" {
  _write_npm_stub "sh: jest: command not found" 0
  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  [ "$status" -eq 1 ] || {
    echo "FAIL: command-not-found signature must block even when exit was 0"
    false
  }
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "1" ]
  run grep -q "TEST_GATE outcome=failed reason=runner_unavailable" "$TEST_REPO/diag.log"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Case (c): a REAL npm test assertion failure (exit 1, FAILED output, NOT 127)
# → outcome=failed (normal block, not masked as runner_unavailable).
# ---------------------------------------------------------------------------
@test "(c) npm test real failure (exit 1, FAILED) → outcome=failed (normal block)" {
  _write_npm_stub "FAILED tests/foo.test.js - expected 1 to equal 2" 1
  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  [ "$status" -eq 1 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "1" ]

  # Real failure must not be masked as a skip.
  run jq -r '.skipped // "false"' "$TEST_REPO/gate.json"
  [ "$output" != "true" ]
}
