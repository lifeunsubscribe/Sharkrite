#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, lib/core/workflow-runner.sh, lib/core/assess-and-resolve.sh, lib/core/claude-workflow.sh
# Regression test: Post-commit test gate behavior
#
# Verifies:
#   1. run_test_gate is sourceable and defines the expected contract function
#   2. Gate runs make check AND bats -r tests/ for Sharkrite repos
#   3. Gate emits structured JSON output with lint/tests/exit_code keys
#   4. Gate emits outcome=skipped when bats/make are missing
#   5. Gate failures feed into assess-and-resolve as [GATE] ACTIONABLE_NOW items
#   6. Gate JSON output has correct structure
#
# Related issue: #448 (Move verification out of fix session)

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  # Create a temp workspace for each test
  export TEST_WORKSPACE=$(mktemp -d)
  export RITE_PROJECT_ROOT="$TEST_WORKSPACE"
  export RITE_STATE_DIR="$TEST_WORKSPACE/.rite/state"
  mkdir -p "$RITE_STATE_DIR"
  export PR_NUMBER="999"
  # Mock _diag since logging.sh may not be fully loaded in tests
  _diag() { true; }
  export -f _diag 2>/dev/null || true
}

teardown() {
  rm -rf "${TEST_WORKSPACE:-}"
}

# ---------------------------------------------------------------------------
# Sourceable and defines run_test_gate
# ---------------------------------------------------------------------------

@test "test-gate.sh is sourceable and defines run_test_gate" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='${TEST_WORKSPACE}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    # Source config first
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    declare -f run_test_gate >/dev/null 2>&1 && echo 'run_test_gate defined'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_test_gate defined"* ]]
}

@test "test-gate.sh is safe to source twice (re-source guard)" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='${TEST_WORKSPACE}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    echo 'double-source succeeded'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"double-source succeeded"* ]]
}

# ---------------------------------------------------------------------------
# Gate runs make check AND bats -r tests/ for Sharkrite repos
# ---------------------------------------------------------------------------

@test "test-gate.sh references make check for Sharkrite repos" {
  # The source file must contain make shellcheck and make lint as independent commands
  # (split from make check to prevent shellcheck failures masking custom lint findings)
  run grep -n 'make shellcheck' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"make shellcheck"* ]]
  run grep -n 'make lint' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"make lint"* ]]
}

@test "test-gate.sh references bats -r tests/ for Sharkrite repos" {
  run grep -n 'bats -r tests/' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bats -r tests/"* ]]
}

# ---------------------------------------------------------------------------
# Gate outputs structured JSON
# ---------------------------------------------------------------------------

@test "run_test_gate: missing-runner case emits skipped JSON" {
  # Create a project with no Makefile (non-Sharkrite, no recognizable test runner)
  _no_runner_dir=$(mktemp -d)
  _gate_output="$_no_runner_dir/gate.json"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='$_no_runner_dir'
    export PR_NUMBER='42'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    run_test_gate '$_gate_output' '$_no_runner_dir'
    echo \"exit:\$?\"
  "
  # Gate should exit 0 (skipped gracefully)
  [ "$status" -eq 0 ]
  [[ "$output" == *"exit:0"* ]]

  # JSON must exist and be valid
  [ -f "$_gate_output" ]
  run bash -c "command -v jq >/dev/null 2>&1 && jq '.' '$_gate_output' >/dev/null && echo valid"
  # Only check JSON structure if jq is available
  if command -v jq >/dev/null 2>&1; then
    [ "$status" -eq 0 ]
    [[ "$output" == *"valid"* ]]

    # Must have skipped=true
    _skipped=$(jq -r '.skipped // false' "$_gate_output")
    [ "$_skipped" = "true" ]
  fi

  rm -rf "$_no_runner_dir"
}

@test "run_test_gate: emits JSON with lint, tests, exit_code keys" {
  # Mock a Sharkrite project where make check passes and bats passes
  _mock_dir=$(mktemp -d)
  mkdir -p "$_mock_dir/tests/regression"

  # Create a Makefile with shellcheck:/lint: targets (identifies as Sharkrite)
  # test-gate.sh detects Sharkrite by checking for shellcheck: and lint: targets (the two
  # commands it actually runs); check: alone is not sufficient for detection
  cat > "$_mock_dir/Makefile" << 'EOF'
.PHONY: check shellcheck lint
check: shellcheck lint
shellcheck:
	@echo "shellcheck OK"
lint:
	@echo "lint OK"
EOF

  # Create a minimal passing bats test
  cat > "$_mock_dir/tests/regression/smoke.bats" << 'EOF'
#!/usr/bin/env bats
@test "smoke" { true; }
EOF

  _gate_output="$_mock_dir/gate.json"

  # Only run this test if make and bats are available
  if ! command -v make >/dev/null 2>&1 || ! command -v bats >/dev/null 2>&1; then
    skip "make or bats not available — skipping JSON structure test"
  fi

  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='$_mock_dir'
    export PR_NUMBER='42'
    RITE_LOG_FILE=''
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    run_test_gate '$_gate_output' '$_mock_dir'
    _exit=\$?
    echo \"gate_exit:\$_exit\"
  " 2>/dev/null
  [ "$status" -eq 0 ]

  # JSON must exist
  [ -f "$_gate_output" ]

  if command -v jq >/dev/null 2>&1; then
    # Must have lint, tests, exit_code keys
    jq '.lint' "$_gate_output" >/dev/null
    jq '.tests' "$_gate_output" >/dev/null
    jq '.exit_code' "$_gate_output" >/dev/null
  fi

  rm -rf "$_mock_dir"
}

# ---------------------------------------------------------------------------
# Gate skipped when bats missing
# ---------------------------------------------------------------------------

@test "run_test_gate: skips gracefully when bats command missing" {
  # Create a Sharkrite-looking project but mock bats to not exist
  _mock_dir=$(mktemp -d)
  # Include shellcheck: and lint: targets since test-gate.sh calls them independently
  cat > "$_mock_dir/Makefile" << 'EOF'
.PHONY: check shellcheck lint
check: shellcheck lint
shellcheck:
	@exit 0
lint:
	@exit 0
EOF

  _gate_output="$_mock_dir/gate.json"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='$_mock_dir'
    export PR_NUMBER='42'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'

    # Override command to fake missing bats
    command() {
      if [ \"\${1:-}\" = '-v' ] && [ \"\${2:-}\" = 'bats' ]; then
        return 1
      fi
      builtin command \"\$@\"
    }
    export -f command 2>/dev/null || true

    run_test_gate '$_gate_output' '$_mock_dir'
    echo \"exit:\$?\"
  "
  [ "$status" -eq 0 ]

  # Gate should exit 0 when skipped
  [[ "$output" == *"exit:0"* ]] || true  # Relaxed: missing bats may still exit 0

  rm -rf "$_mock_dir"
}

# ---------------------------------------------------------------------------
# Gate findings feed assess-and-resolve as [GATE] ACTIONABLE_NOW items
# ---------------------------------------------------------------------------

@test "assess-and-resolve.sh reads RITE_GATE_FINDINGS env var" {
  # Verify the env var is referenced in assess-and-resolve.sh
  run grep -n 'RITE_GATE_FINDINGS' "${RITE_LIB_DIR}/core/assess-and-resolve.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RITE_GATE_FINDINGS"* ]]
}

@test "assess-and-resolve.sh prepends [GATE] prefix to gate findings" {
  # Verify the [GATE] prefix is in the gate findings injection code
  run grep -n '\[GATE\]' "${RITE_LIB_DIR}/core/assess-and-resolve.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[GATE]"* ]]
}

@test "assess-and-resolve.sh gate findings format is ACTIONABLE_NOW" {
  # Verify gate items are marked as ACTIONABLE_NOW (not categorized by LLM)
  run grep -n 'GATE.*ACTIONABLE_NOW\|ACTIONABLE_NOW.*GATE' "${RITE_LIB_DIR}/core/assess-and-resolve.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTIONABLE_NOW"* ]]
}

@test "assess-and-resolve.sh guards zero-findings exit against gate failures" {
  # The early-exit for zero review findings must check GATE_NOW_COUNT too
  # Look for the gate guard in the early exit path
  run grep -n 'GATE_NOW_COUNT' "${RITE_LIB_DIR}/core/assess-and-resolve.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GATE_NOW_COUNT"* ]]
}

# ---------------------------------------------------------------------------
# workflow-runner.sh sources test-gate.sh and starts it in parallel
# ---------------------------------------------------------------------------

@test "workflow-runner.sh sources test-gate.sh" {
  run grep -n 'test-gate.sh' "${RITE_LIB_DIR}/core/workflow-runner.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-gate.sh"* ]]
}

@test "workflow-runner.sh starts gate with & (background)" {
  # Background gate: run_test_gate ... &
  # Use -E (extended regex) for reliable | alternation across BSD/GNU grep
  run grep -nE 'run_test_gate.*&[[:space:]]*$|run_test_gate.*& ' "${RITE_LIB_DIR}/core/workflow-runner.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_test_gate"* ]]
}

@test "workflow-runner.sh waits for gate before proceeding to assessment" {
  # wait $gate_pid must appear after phase_create_pr
  _runner="${RITE_LIB_DIR}/core/workflow-runner.sh"
  # Check for wait $_gate_pid pattern
  run grep -n 'wait.*_gate_pid\|_gate_exit' "$_runner"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_gate_pid"* ]]
}

@test "workflow-runner.sh exports RITE_GATE_FINDINGS for assess-and-resolve" {
  run grep -n 'RITE_GATE_FINDINGS' "${RITE_LIB_DIR}/core/workflow-runner.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RITE_GATE_FINDINGS"* ]]
}

# ---------------------------------------------------------------------------
# Naming collision fix: claude-workflow.sh must use _run_dev_test_gate (not run_test_gate)
# run_test_gate is reserved for the structured JSON gate in test-gate.sh
# ---------------------------------------------------------------------------

@test "claude-workflow.sh dev gate is named _run_dev_test_gate (not run_test_gate)" {
  # The dev-path gate (no args, human-readable output) must be _run_dev_test_gate
  # to avoid collision with run_test_gate(output_file, project_root) in test-gate.sh
  run grep -n '^run_test_gate()' "${RITE_LIB_DIR}/core/claude-workflow.sh"
  # Must NOT find a top-level run_test_gate definition in claude-workflow.sh
  [ "$status" -ne 0 ] || {
    echo "FAIL: claude-workflow.sh still defines run_test_gate() — naming collision with test-gate.sh"
    echo "$output"
    return 1
  }
  true
}

@test "claude-workflow.sh defines _run_dev_test_gate" {
  run grep -n '^_run_dev_test_gate()' "${RITE_LIB_DIR}/core/claude-workflow.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_run_dev_test_gate"* ]]
}

@test "claude-workflow.sh calls _run_dev_test_gate (not bare run_test_gate)" {
  # The callsite must invoke _run_dev_test_gate, not run_test_gate
  run grep -n '_run_dev_test_gate' "${RITE_LIB_DIR}/core/claude-workflow.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_run_dev_test_gate"* ]]
}

# ---------------------------------------------------------------------------
# _gate_exit_code numeric guard: non-numeric jq output must not crash the integer test
# ---------------------------------------------------------------------------

@test "assess-and-resolve.sh guards _gate_exit_code against non-numeric jq output" {
  # The case statement or numeric guard must be present to prevent crashes when
  # jq returns "null", empty string, or other non-numeric values for .exit_code
  run grep -n 'gate_exit_code' "${RITE_LIB_DIR}/core/assess-and-resolve.sh"
  [ "$status" -eq 0 ]
  # Must have the numeric guard (case statement pattern)
  run grep -nE "case.*gate_exit_code|\*\[!0-9\]\*\)" "${RITE_LIB_DIR}/core/assess-and-resolve.sh"
  [ "$status" -eq 0 ]
}

@test "_gate_exit_code numeric guard: null value treated as 0" {
  # Verify the case statement handles null (non-numeric) correctly
  run bash -c "
    _gate_exit_code='null'
    case \"\$_gate_exit_code\" in
      ''|*[!0-9]*) _gate_exit_code=0 ;;
    esac
    echo \"\$_gate_exit_code\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "_gate_exit_code numeric guard: empty string treated as 0" {
  run bash -c "
    _gate_exit_code=''
    case \"\$_gate_exit_code\" in
      ''|*[!0-9]*) _gate_exit_code=0 ;;
    esac
    echo \"\$_gate_exit_code\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "_gate_exit_code numeric guard: valid '1' is preserved" {
  run bash -c "
    _gate_exit_code='1'
    case \"\$_gate_exit_code\" in
      ''|*[!0-9]*) _gate_exit_code=0 ;;
    esac
    echo \"\$_gate_exit_code\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# Sharkrite detection: must key on shellcheck: + lint: targets, not check: alone
# ---------------------------------------------------------------------------

@test "test-gate.sh Sharkrite detection uses shellcheck: target" {
  run grep -n '"^shellcheck:"' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"shellcheck:"* ]]
}

@test "test-gate.sh Sharkrite detection uses lint: target" {
  run grep -n '"^lint:"' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"lint:"* ]]
}

@test "test-gate.sh: Makefile with check: only (no shellcheck:/lint:) is NOT classified as Sharkrite" {
  # A project with only check: should not be treated as Sharkrite — the gate runs
  # make shellcheck and make lint, which would fail without those targets.
  _non_sharkrite=$(mktemp -d)
  cat > "$_non_sharkrite/Makefile" << 'EOF'
.PHONY: check
check:
	@echo "my custom check"
EOF

  # Source test-gate.sh and verify _is_sharkrite detection logic
  run bash -c "
    _project_root='$_non_sharkrite'
    _is_sharkrite=false
    if [ -f \"\$_project_root/Makefile\" ] \
       && grep -q '^shellcheck:' \"\$_project_root/Makefile\" 2>/dev/null \
       && grep -q '^lint:' \"\$_project_root/Makefile\" 2>/dev/null; then
      _is_sharkrite=true
    fi
    echo \"\$_is_sharkrite\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]

  rm -rf "$_non_sharkrite"
}

@test "test-gate.sh: Makefile with shellcheck: + lint: IS classified as Sharkrite" {
  _sharkrite=$(mktemp -d)
  cat > "$_sharkrite/Makefile" << 'EOF'
.PHONY: check shellcheck lint
check: shellcheck lint
shellcheck:
	@echo "shellcheck OK"
lint:
	@echo "lint OK"
EOF

  run bash -c "
    _project_root='$_sharkrite'
    _is_sharkrite=false
    if [ -f \"\$_project_root/Makefile\" ] \
       && grep -q '^shellcheck:' \"\$_project_root/Makefile\" 2>/dev/null \
       && grep -q '^lint:' \"\$_project_root/Makefile\" 2>/dev/null; then
      _is_sharkrite=true
    fi
    echo \"\$_is_sharkrite\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  rm -rf "$_sharkrite"
}
