#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-verdict.sh::_gate_command_flake_candidates, lib/utils/test-gate.sh::run_test_gate, lib/utils/gate-runners.sh::_node_flavored_test_context
# sharkrite-gate-serial
# Regression: the RITE_TEST_COMMAND gate path had no flake handling and wrote a
# thinner verdict than the detected-runner path.
#
# Live (freshup 2026-11-12b): a vitest pagination test in an untouched frontend
# file took 10.4 s under gate load and failed; the fix session for a BACKEND
# issue rewrote two frontend tests to make the gate pass. freshup runs the gate
# through RITE_TEST_COMMAND="bash scripts/rite-test.sh" (pytest + tsc + vitest,
# package.json one level down in frontend/), so:
#   - no flake re-run existed on that path (the sharkrite bats path has one)
#   - vitest failures were not normalized into named findings (the command
#     string and the repo root both hide the node runner)
#   - the verdict JSON carried neither head_sha (#986) nor the runner excerpt
#     (#1785), so a tsc-only failure reached the fix session as
#     "non-zero exit with no parseable findings"
#
# Contract pinned here: when every failing test file the runner names is
# outside the change, the whole command re-runs once and that result is the
# verdict. A failing file the change touched never re-runs.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TARGET_REPO=$(mktemp -d); export TARGET_REPO
  CMD_DIR=$(mktemp -d); export CMD_DIR
  DIAG_LOG="$CMD_DIR/diag.log"; export DIAG_LOG

  # Target repo: a base commit (tagged) plus one commit touching backend only.
  (cd "$TARGET_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && mkdir -p backend frontend/src/pages \
     && echo 'x = 1' > backend/app.py \
     && echo '// test' > frontend/src/pages/Schedule.test.tsx \
     && git add -A && git commit -qm init && git tag base \
     && echo 'x = 2' > backend/app.py \
     && git add -A && git commit -qm change) >/dev/null 2>&1

  # Runner outputs. vitest prints paths relative to ITS cwd (frontend/).
  cat > "$CMD_DIR/vitest-fail.txt" <<'OUT'
 RUN  v1.6.0 /repo/frontend

 ❯ src/pages/Schedule.test.tsx (12 tests | 1 failed) 10432ms
⎯⎯⎯⎯⎯⎯⎯ Failed Tests 1 ⎯⎯⎯⎯⎯⎯⎯

 FAIL  src/pages/Schedule.test.tsx > Schedule > paginates
Error: Test timed out in 5000ms.

 Test Files  1 failed | 40 passed (41)
      Tests  1 failed | 300 passed (301)
OUT
  cat > "$CMD_DIR/tsc-fail.txt" <<'OUT'
src/pages/Schedule.tsx(12,7): error TS6133: 'unused' is declared but its value is never read.
OUT

  # Fake test command: counts its runs; fails the first FAIL_RUNS times with
  # the output in FAIL_OUTPUT, then passes.
  cat > "$CMD_DIR/cmd.sh" <<'CMD'
#!/bin/bash
n=$(cat "$CMD_DIR/runs" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$CMD_DIR/runs"
if [ "$n" -le "${FAIL_RUNS:-1}" ]; then
  cat "$CMD_DIR/${FAIL_OUTPUT:-vitest-fail.txt}"
  exit 1
fi
echo " Test Files  41 passed (41)"
exit 0
CMD
  chmod +x "$CMD_DIR/cmd.sh"

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: test-gate.sh uses a function-sentinel guard (declare -f run_test_gate); pre-source _diag() stub is preserved on source.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
  set +u; set +o pipefail
}

teardown() { rm -rf "${TARGET_REPO:-}" "${CMD_DIR:-}"; }

# Run the gate in a clean subprocess so _diag writes to DIAG_LOG.
# $1 = extra env assignments (may be empty)
_run_cmd_gate() {
  local _extra="$1"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=77
    export RITE_LOG_FILE='$DIAG_LOG' RITE_STATE_DIR='$CMD_DIR/state'
    export CMD_DIR='$CMD_DIR'
    export RITE_TEST_COMMAND='bash $CMD_DIR/cmd.sh'
    export RITE_TEST_GATE_DIFF_BASE=base
    ${_extra:+export $_extra}
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    run_test_gate '$CMD_DIR/gate.json' '$TARGET_REPO'
  " </dev/null
}

# ---------------------------------------------------------------------------
# _gate_command_flake_candidates — the decision
# ---------------------------------------------------------------------------

@test "candidates: vitest failure in a file outside the change is a candidate" {
  run _gate_command_flake_candidates "$CMD_DIR/vitest-fail.txt" "backend/app.py"
  [ "$status" -eq 0 ]
  [ "$output" = "src/pages/Schedule.test.tsx" ]
}

@test "candidates: failing file in the change (runner-relative path) is not a candidate" {
  run _gate_command_flake_candidates "$CMD_DIR/vitest-fail.txt" \
    "backend/app.py
frontend/src/pages/Schedule.test.tsx"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "candidates: pytest FAILED line outside the change is a candidate, inside is not" {
  printf 'FAILED tests/test_api.py::test_list - AssertionError: 1 != 2\n1 failed, 40 passed in 3.2s\n' > "$CMD_DIR/py.txt"
  run _gate_command_flake_candidates "$CMD_DIR/py.txt" "frontend/src/App.tsx"
  [ "$status" -eq 0 ]
  [ "$output" = "tests/test_api.py" ]

  run _gate_command_flake_candidates "$CMD_DIR/py.txt" "tests/test_api.py"
  [ "$status" -eq 1 ]
}

@test "candidates: ANSI-colored FAIL line is still read" {
  printf ' \033[41m FAIL \033[0m src/a.test.ts > a > b\n Test Files  1 failed (1)\n' > "$CMD_DIR/ansi.txt"
  run _gate_command_flake_candidates "$CMD_DIR/ansi.txt" "backend/app.py"
  [ "$status" -eq 0 ]
  [ "$output" = "src/a.test.ts" ]
}

@test "candidates: a tsc error anywhere in the output is never a candidate" {
  cat "$CMD_DIR/vitest-fail.txt" "$CMD_DIR/tsc-fail.txt" > "$CMD_DIR/both.txt"
  run _gate_command_flake_candidates "$CMD_DIR/both.txt" "backend/app.py"
  [ "$status" -eq 1 ]
}

@test "candidates: no named failing file, or no computable change, is not a candidate" {
  printf 'boom: wrapper crashed\n' > "$CMD_DIR/crash.txt"
  run _gate_command_flake_candidates "$CMD_DIR/crash.txt" "backend/app.py"
  [ "$status" -eq 1 ]

  run _gate_command_flake_candidates "$CMD_DIR/vitest-fail.txt" ""
  [ "$status" -eq 1 ]
}

@test "candidates: more failing files than RITE_GATE_FLAKE_RETRY_MAX_FILES is not a candidate" {
  printf ' FAIL  src/a.test.ts > a\n FAIL  src/b.test.ts > b\n FAIL  src/c.test.ts > c\n' > "$CMD_DIR/many.txt"
  RITE_GATE_FLAKE_RETRY_MAX_FILES=2 run _gate_command_flake_candidates "$CMD_DIR/many.txt" "backend/app.py"
  [ "$status" -eq 1 ]
  RITE_GATE_FLAKE_RETRY_MAX_FILES=3 run _gate_command_flake_candidates "$CMD_DIR/many.txt" "backend/app.py"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# _node_flavored_test_context — output signature (wrapper script, nested package.json)
# ---------------------------------------------------------------------------

@test "node context: vitest summary in the output is enough without a root package.json" {
  [ ! -f "$TARGET_REPO/package.json" ]
  run _node_flavored_test_context "$TARGET_REPO" "bash scripts/rite-test.sh" "$CMD_DIR/vitest-fail.txt"
  [ "$status" -eq 0 ]

  printf 'Test Suites: 1 failed, 3 passed, 4 total\n' > "$CMD_DIR/jest.txt"
  run _node_flavored_test_context "$TARGET_REPO" "bash scripts/rite-test.sh" "$CMD_DIR/jest.txt"
  [ "$status" -eq 0 ]
}

@test "node context: non-node output with a wrapper command stays false" {
  printf 'FAILED tests/test_api.py::test_list - AssertionError\n1 failed in 3.2s\n' > "$CMD_DIR/py.txt"
  run _node_flavored_test_context "$TARGET_REPO" "bash scripts/rite-test.sh" "$CMD_DIR/py.txt"
  [ "$status" -ne 0 ]
  run _node_flavored_test_context "$TARGET_REPO" "bash scripts/rite-test.sh"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# run_test_gate — RITE_TEST_COMMAND path end to end
# ---------------------------------------------------------------------------

@test "gate: untouched failing test that passes on re-run clears the gate" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _run_cmd_gate "FAIL_RUNS=1"
  [ "$status" -eq 0 ]
  [ "$(cat "$CMD_DIR/runs")" = "2" ]
  [[ "$output" == *"none touched by this change"* ]]
  [[ "$output" == *"src/pages/Schedule.test.tsx"* ]]
  [ "$(jq -r '.exit_code' "$CMD_DIR/gate.json")" = "0" ]
  [ "$(jq -r '.tests | length' "$CMD_DIR/gate.json")" = "0" ]
  grep -qE 'TEST_GATE_FLAKE_RETRY cleared=1 persisted=0 files=1 retry_exit=0 mode=command pr=77' "$DIAG_LOG"
  grep -qE 'TEST_GATE outcome=passed ' "$DIAG_LOG"
}

@test "gate: failure that persists on re-run fails with named findings" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _run_cmd_gate "FAIL_RUNS=2"
  [ "$status" -eq 1 ]
  [ "$(cat "$CMD_DIR/runs")" = "2" ]
  [ "$(jq -r '.exit_code' "$CMD_DIR/gate.json")" = "1" ]
  # Named finding without a root package.json: normalized by output signature.
  run jq -r '.tests[].test_name' "$CMD_DIR/gate.json"
  [[ "$output" == *"Schedule.test.tsx"* ]]
  grep -qE 'TEST_GATE_FLAKE_RETRY cleared=0 persisted=1 files=1 retry_exit=1 mode=command pr=77' "$DIAG_LOG"
}

@test "gate: failing test file the change touched is not re-run" {
  (cd "$TARGET_REPO" \
     && echo '// edited' > frontend/src/pages/Schedule.test.tsx \
     && git add -A && git commit -qm 'touch test') >/dev/null 2>&1
  _run_cmd_gate "FAIL_RUNS=1"
  [ "$status" -eq 1 ]
  [ "$(cat "$CMD_DIR/runs")" = "1" ]
  ! grep -q 'TEST_GATE_FLAKE_RETRY' "$DIAG_LOG"
}

@test "gate: RITE_GATE_FLAKE_RETRY=false disables the re-run" {
  _run_cmd_gate "FAIL_RUNS=1 RITE_GATE_FLAKE_RETRY=false"
  [ "$status" -eq 1 ]
  [ "$(cat "$CMD_DIR/runs")" = "1" ]
}

@test "gate: tsc-only failure is not re-run and the verdict carries excerpt + head_sha" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _run_cmd_gate "FAIL_RUNS=1 FAIL_OUTPUT=tsc-fail.txt"
  [ "$status" -eq 1 ]
  [ "$(cat "$CMD_DIR/runs")" = "1" ]
  [ "$(jq -r '.tests | length' "$CMD_DIR/gate.json")" = "0" ]
  run jq -r '.excerpt' "$CMD_DIR/gate.json"
  [[ "$output" == *"error TS6133"* ]]
  _head=$(git -C "$TARGET_REPO" rev-parse HEAD)
  [ "$(jq -r '.head_sha' "$CMD_DIR/gate.json")" = "$_head" ]
}

@test "gate: passing command writes head_sha and no excerpt" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _run_cmd_gate "FAIL_RUNS=0"
  [ "$status" -eq 0 ]
  [ "$(cat "$CMD_DIR/runs")" = "1" ]
  _head=$(git -C "$TARGET_REPO" rev-parse HEAD)
  [ "$(jq -r '.head_sha' "$CMD_DIR/gate.json")" = "$_head" ]
  [ "$(jq -r '.excerpt // "none"' "$CMD_DIR/gate.json")" = "none" ]
}
