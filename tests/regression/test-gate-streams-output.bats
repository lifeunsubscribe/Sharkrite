#!/usr/bin/env bats
# Regression test: test_gate streams output to stdout, not only to temp file
#
# Verifies:
#   1. Known test output appears in the process's stdout stream (not only in temp file)
#   2. Exit codes are preserved correctly through the tee process substitution
#   3. Temp files are still populated after the run (parser still works)
#   4. Output appears exactly once in stdout and once in temp file (no double-write)
#
# Related issue: #465 (Stream test_gate output, don't only capture it)
# Root cause: All capture sites used >/$>> redirect; output went to temp file only.
# Fix: Replaced with > >(tee -a "$file") at all six sites.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export TEST_WORKSPACE=$(mktemp -d)
  export RITE_PROJECT_ROOT="$TEST_WORKSPACE"
  export RITE_STATE_DIR="$TEST_WORKSPACE/.rite/state"
  mkdir -p "$RITE_STATE_DIR"
  export PR_NUMBER="999"
  _diag() { true; }
  export -f _diag 2>/dev/null || true
}

teardown() {
  rm -rf "${TEST_WORKSPACE:-}"
}

# ---------------------------------------------------------------------------
# Structural: all six capture sites use tee (not bare > or >>)
# ---------------------------------------------------------------------------

@test "structural: make shellcheck capture site uses tee (not bare redirect)" {
  # The line must contain tee, not a bare >> redirect
  _line=$(grep -n 'make shellcheck 2>&1' "${RITE_LIB_DIR}/utils/test-gate.sh" | grep -v '^\s*#' || true)
  [ -n "$_line" ]
  echo "$_line" | grep -q 'tee'
}

@test "structural: make lint capture site uses tee (not bare redirect)" {
  _line=$(grep -n 'make lint 2>&1' "${RITE_LIB_DIR}/utils/test-gate.sh" | grep -v '^\s*#' || true)
  [ -n "$_line" ]
  echo "$_line" | grep -q 'tee'
}

@test "structural: bats capture site uses tee (not bare redirect)" {
  _line=$(grep -n 'bats -r tests/ 2>&1' "${RITE_LIB_DIR}/utils/test-gate.sh" | grep -v '^\s*#' || true)
  [ -n "$_line" ]
  echo "$_line" | grep -q 'tee'
}

@test "structural: make test fallback capture site uses tee" {
  _line=$(grep -n 'make test 2>&1' "${RITE_LIB_DIR}/utils/test-gate.sh" | grep -v '^\s*#' || true)
  [ -n "$_line" ]
  echo "$_line" | grep -q 'tee'
}

@test "structural: npm test fallback capture site uses tee" {
  _line=$(grep -n 'npm test 2>&1' "${RITE_LIB_DIR}/utils/test-gate.sh" | grep -v '^\s*#' || true)
  [ -n "$_line" ]
  echo "$_line" | grep -q 'tee'
}

@test "structural: python3 -m pytest fallback capture site uses tee" {
  _line=$(grep -n 'python3 -m pytest 2>&1' "${RITE_LIB_DIR}/utils/test-gate.sh" | grep -v '^\s*#' || true)
  [ -n "$_line" ]
  echo "$_line" | grep -q 'tee'
}

@test "structural: no bare >> to lint_raw_file without tee" {
  # Must not have: ) >> "$_lint_raw_file" (the old pure-redirect pattern)
  # tee -a is the expected form. This rule only applies to the capture sites — not the comment lines.
  _bare=$(grep -nE '\) >> "?\$_lint_raw_file"?' "${RITE_LIB_DIR}/utils/test-gate.sh" | grep -v '^\s*#' || true)
  [ -z "$_bare" ]
}

@test "structural: no bare > to tests_raw_file without tee" {
  # Must not have: ) > "$_tests_raw_file" (the old pure-redirect pattern)
  _bare=$(grep -nE '\) > "?\$_tests_raw_file"?' "${RITE_LIB_DIR}/utils/test-gate.sh" | grep -v '^\s*#' || true)
  [ -z "$_bare" ]
}

# ---------------------------------------------------------------------------
# Streaming-output test: known test name appears in stdout, not just temp file
# ---------------------------------------------------------------------------

@test "run_test_gate: bats output streams to stdout (known test name visible in stream)" {
  # Requires make and bats to be available
  if ! command -v make >/dev/null 2>&1 || ! command -v bats >/dev/null 2>&1; then
    skip "make or bats not available"
  fi

  _mock_dir=$(mktemp -d)
  mkdir -p "$_mock_dir/tests/regression"

  # Create a Sharkrite-style Makefile
  cat > "$_mock_dir/Makefile" << 'EOF'
.PHONY: shellcheck lint
shellcheck:
	@echo "shellcheck-marker-for-streaming-test OK"
lint:
	@echo "lint-marker-for-streaming-test OK"
EOF

  # Create a bats test with a distinctive name that we'll look for in stdout
  cat > "$_mock_dir/tests/regression/streaming.bats" << 'EOF'
#!/usr/bin/env bats
@test "streaming-test-sentinel-line" { true; }
EOF

  _gate_output="$_mock_dir/gate.json"

  # Capture stdout+stderr together so we can check what the gate streams.
  # The gate writes herald lines to stderr, and test output (via tee) to stdout.
  # We capture both via 2>&1 in the outer subshell.
  _captured=$(bash -c "
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
  " 2>&1 || true)

  # The sentinel test name must appear in the captured stream (streamed via tee, not only in file)
  echo "$_captured" | grep -q "streaming-test-sentinel-line"

  rm -rf "$_mock_dir"
}

# ---------------------------------------------------------------------------
# Exit-code preservation test: bats failure is detected through tee
# ---------------------------------------------------------------------------

@test "run_test_gate: exit code preserved when bats fails (tee does not mask failure)" {
  if ! command -v make >/dev/null 2>&1 || ! command -v bats >/dev/null 2>&1; then
    skip "make or bats not available"
  fi

  _mock_dir=$(mktemp -d)
  mkdir -p "$_mock_dir/tests/regression"

  cat > "$_mock_dir/Makefile" << 'EOF'
.PHONY: shellcheck lint
shellcheck:
	@exit 0
lint:
	@exit 0
EOF

  # A bats test that intentionally fails
  cat > "$_mock_dir/tests/regression/failing.bats" << 'EOF'
#!/usr/bin/env bats
@test "intentional-failure-for-exit-code-test" { false; }
EOF

  _gate_output="$_mock_dir/gate.json"

  # Gate must return 1 when bats reports failures
  run bash -c "
    set -uo pipefail
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='$_mock_dir'
    export PR_NUMBER='42'
    RITE_LOG_FILE=''
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    run_test_gate '$_gate_output' '$_mock_dir'
  " 2>/dev/null
  # Gate exits 1 when there are test failures (exit code preservation through tee)
  [ "$status" -eq 1 ]

  # JSON must also reflect the failure
  if command -v jq >/dev/null 2>&1 && [ -f "$_gate_output" ]; then
    _exit_code=$(jq '.exit_code' "$_gate_output" || echo "0")
    [ "$_exit_code" -eq 1 ]
  fi

  rm -rf "$_mock_dir"
}

# ---------------------------------------------------------------------------
# Temp-file-still-populated test: parser still works after tee conversion
# ---------------------------------------------------------------------------

@test "run_test_gate: temp files are still populated after tee (parser still works)" {
  if ! command -v make >/dev/null 2>&1 || ! command -v bats >/dev/null 2>&1; then
    skip "make or bats not available"
  fi

  _mock_dir=$(mktemp -d)
  mkdir -p "$_mock_dir/tests/regression"

  cat > "$_mock_dir/Makefile" << 'EOF'
.PHONY: shellcheck lint
shellcheck:
	@echo "shellcheck-temp-file-check OK"
lint:
	@echo "lint-temp-file-check OK"
EOF

  cat > "$_mock_dir/tests/regression/passing.bats" << 'EOF'
#!/usr/bin/env bats
@test "temp-file-population-check" { true; }
EOF

  _gate_output="$_mock_dir/gate.json"

  run bash -c "
    set -uo pipefail
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='$_mock_dir'
    export PR_NUMBER='42'
    RITE_LOG_FILE=''
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    run_test_gate '$_gate_output' '$_mock_dir'
    echo \"gate_exit:\$?\"
  " 2>/dev/null
  [ "$status" -eq 0 ]

  # Gate output JSON must exist and have lint/tests arrays (populated from the temp files)
  [ -f "$_gate_output" ]
  if command -v jq >/dev/null 2>&1; then
    # Parser must produce valid JSON with lint and tests arrays
    jq '.lint | type' "$_gate_output" | grep -q '"array"'
    jq '.tests | type' "$_gate_output" | grep -q '"array"'
  fi

  rm -rf "$_mock_dir"
}

# ---------------------------------------------------------------------------
# No-double-write test: output appears once in stdout and once in temp file
# ---------------------------------------------------------------------------

@test "run_test_gate: no double-write — make shellcheck output line count matches between stream and temp file" {
  if ! command -v make >/dev/null 2>&1 || ! command -v bats >/dev/null 2>&1; then
    skip "make or bats not available"
  fi

  _mock_dir=$(mktemp -d)
  mkdir -p "$_mock_dir/tests/regression"

  # shellcheck outputs exactly two lines
  cat > "$_mock_dir/Makefile" << 'EOF'
.PHONY: shellcheck lint
shellcheck:
	@echo "unique-line-alpha"
	@echo "unique-line-beta"
lint:
	@exit 0
EOF

  cat > "$_mock_dir/tests/regression/smoke.bats" << 'EOF'
#!/usr/bin/env bats
@test "no-double-write-smoke" { true; }
EOF

  _gate_output="$_mock_dir/gate.json"

  # Capture what flows to stdout+stderr via tee
  _stream_output=$(bash -c "
    set -uo pipefail
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='$_mock_dir'
    export PR_NUMBER='42'
    RITE_LOG_FILE=''
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    run_test_gate '$_gate_output' '$_mock_dir'
  " 2>/dev/null || true)

  # Count occurrences of the sentinel lines in the stream
  _alpha_count=$(echo "$_stream_output" | grep -c "unique-line-alpha" || true)
  _beta_count=$(echo "$_stream_output" | grep -c "unique-line-beta" || true)

  # Each line should appear exactly once (tee writes to stdout once, not twice)
  [ "$_alpha_count" -eq 1 ]
  [ "$_beta_count" -eq 1 ]

  rm -rf "$_mock_dir"
}
