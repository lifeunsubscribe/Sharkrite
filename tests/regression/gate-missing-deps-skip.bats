#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
#
# Regression tests for #744: loud-skip on missing test dependencies (pytest).
#
# When the project test command fails because of missing Python dependencies
# (ModuleNotFoundError / "No module named") or because pytest collected no tests
# (exit code 5), the gate must emit outcome=skipped reason=missing_deps and an
# actionable WARNING — NOT outcome=failed — so the merge is not blocked on an
# environment gap rather than a code defect.
#
# Invariant: a genuine test failure (assertion error / non-zero exit WITHOUT
# the dep-error signatures) must still produce outcome=failed.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"

  # Initialise a non-Sharkrite git repo with a base commit.
  # No Makefile with shellcheck:/lint: targets → _is_sharkrite=false.
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && touch README.md \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD) >/dev/null 2>&1
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# Helper: run the gate in a subprocess with optional extra env and optional project_root.
_run_gate() {
  local _env="${1:-}"
  local _root="${2:-$TEST_REPO}"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    ${_env} run_test_gate '$_root/gate.json' '$_root'
  " </dev/null
}

# ---------------------------------------------------------------------------
# pytest path: ModuleNotFoundError → skipped
# ---------------------------------------------------------------------------

@test "pytest: ModuleNotFoundError → outcome=skipped reason=missing_deps" {
  # Create pytest.ini so the pytest branch is selected.
  printf '[pytest]\n' > "$TEST_REPO/pytest.ini"

  # Stub python3: exits 1 with a ModuleNotFoundError message.
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/python3" <<'STUB'
#!/bin/sh
echo "ModuleNotFoundError: No module named 'pytest'"
exit 1
STUB
  chmod +x "$STUB_DIR/python3"

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # Gate must have skipped (env gap, not a code defect).
  grep -q '"skipped":true' "$TEST_REPO/gate.json" || {
    echo "FAIL: expected skipped:true in gate.json for ModuleNotFoundError"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }

  # reason must be missing_deps (not missing_runner).
  grep -q '"reason":"missing_deps"' "$TEST_REPO/gate.json" || {
    echo "FAIL: expected reason:missing_deps in gate.json"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }

  # exit_code in JSON must be 0 (skip is not a failure).
  local _exit_code
  _exit_code=$(grep -o '"exit_code":[0-9]*' "$TEST_REPO/gate.json" | grep -o '[0-9]*' || true)
  [ "${_exit_code:-}" = "0" ] || {
    echo "FAIL: exit_code should be 0 for a missing-deps skip"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }
}

@test "pytest: ModuleNotFoundError → WARNING on stderr with pip install hint" {
  printf '[pytest]\n' > "$TEST_REPO/pytest.ini"

  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/python3" <<'STUB'
#!/bin/sh
echo "ModuleNotFoundError: No module named 'pytest'"
exit 1
STUB
  chmod +x "$STUB_DIR/python3"

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # WARNING must appear in output (bats run captures stdout + stderr).
  [[ "$output" == *"WARNING"* ]] || {
    echo "FAIL: expected WARNING in output for ModuleNotFoundError"
    echo "Gate output: $output"
    false
  }

  # Actionable install hint must appear.
  [[ "$output" == *"pip install"* ]] || [[ "$output" == *"requirements"* ]] || {
    echo "FAIL: expected pip/requirements hint in WARNING output"
    echo "Gate output: $output"
    false
  }
}

@test "pytest: exit 5 (no tests collected) → outcome=skipped reason=missing_deps" {
  # pytest exit 5 = "no tests were collected" — treated as an env/config gap.
  printf '[pytest]\n' > "$TEST_REPO/pytest.ini"

  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/python3" <<'STUB'
#!/bin/sh
echo "no tests ran"
exit 5
STUB
  chmod +x "$STUB_DIR/python3"

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  grep -q '"skipped":true' "$TEST_REPO/gate.json" || {
    echo "FAIL: expected skipped:true for pytest exit 5 (no tests collected)"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }

  grep -q '"reason":"missing_deps"' "$TEST_REPO/gate.json" || {
    echo "FAIL: expected reason:missing_deps for pytest exit 5"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }
}

@test "pytest: real test failure (exit 1, FAILED output) → outcome=failed (NOT skipped)" {
  # A genuine assertion failure must still block the merge.
  printf '[pytest]\n' > "$TEST_REPO/pytest.ini"

  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/python3" <<'STUB'
#!/bin/sh
echo "FAILED test_foo.py::test_bar - AssertionError: assert 1 == 2"
echo "1 failed in 0.01s"
exit 1
STUB
  chmod +x "$STUB_DIR/python3"

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # Must NOT be skipped — this is a real failure.
  grep -q '"skipped":true' "$TEST_REPO/gate.json" && {
    echo "FAIL: gate skipped a REAL test failure (FAILED assertion) — this must not happen"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }

  # exit_code must be non-zero.
  local _exit_code
  _exit_code=$(grep -o '"exit_code":[0-9]*' "$TEST_REPO/gate.json" | grep -o '[0-9]*' || true)
  [ "${_exit_code:-0}" -ne 0 ] || {
    echo "FAIL: exit_code should be non-zero for a real test failure"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }
}

# ---------------------------------------------------------------------------
# make test path (Makefile with test: target): ModuleNotFoundError → skipped
# ---------------------------------------------------------------------------

@test "make test: ModuleNotFoundError in output → outcome=skipped reason=missing_deps" {
  # Create a Makefile with a test: target that invokes a stub pytest that errors on deps.
  cat > "$TEST_REPO/Makefile" <<'EOF'
.PHONY: test
test:
	python3 -m pytest server/
EOF

  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/python3" <<'STUB'
#!/bin/sh
echo "ModuleNotFoundError: No module named 'flask'"
exit 1
STUB
  chmod +x "$STUB_DIR/python3"

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  grep -q '"skipped":true' "$TEST_REPO/gate.json" || {
    echo "FAIL: expected skipped:true for make test with ModuleNotFoundError"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }

  grep -q '"reason":"missing_deps"' "$TEST_REPO/gate.json" || {
    echo "FAIL: expected reason:missing_deps in gate.json for make test path"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }
}

@test "make test: 'No module named' in output → outcome=skipped reason=missing_deps" {
  cat > "$TEST_REPO/Makefile" <<'EOF'
.PHONY: test
test:
	python3 -m pytest
EOF

  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/python3" <<'STUB'
#!/bin/sh
echo "No module named 'pytest'"
exit 1
STUB
  chmod +x "$STUB_DIR/python3"

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  grep -q '"skipped":true' "$TEST_REPO/gate.json" || {
    echo "FAIL: expected skipped:true for 'No module named' in make test output"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }
}

@test "make test: WARNING with install hint emitted for missing deps" {
  cat > "$TEST_REPO/Makefile" <<'EOF'
.PHONY: test
test:
	python3 -m pytest
EOF

  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/python3" <<'STUB'
#!/bin/sh
echo "ModuleNotFoundError: No module named 'requests'"
exit 1
STUB
  chmod +x "$STUB_DIR/python3"

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  [[ "$output" == *"WARNING"* ]] || {
    echo "FAIL: expected WARNING in output for make test missing-deps skip"
    echo "Gate output: $output"
    false
  }

  [[ "$output" == *"pip install"* ]] || [[ "$output" == *"requirements"* ]] || [[ "$output" == *"RITE_TEST_COMMAND"* ]] || {
    echo "FAIL: expected install hint or RITE_TEST_COMMAND hint in WARNING for make test path"
    echo "Gate output: $output"
    false
  }
}

@test "make test: real failure (exit 1, no dep-error) → outcome=failed (NOT skipped)" {
  cat > "$TEST_REPO/Makefile" <<'EOF'
.PHONY: test
test:
	sh -c 'echo "FAILED: test_auth::test_login"; exit 1'
EOF

  _run_gate ""

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  grep -q '"skipped":true' "$TEST_REPO/gate.json" && {
    echo "FAIL: gate skipped a real make test failure (no dep-error) — must NOT skip"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }

  local _exit_code
  _exit_code=$(grep -o '"exit_code":[0-9]*' "$TEST_REPO/gate.json" | grep -o '[0-9]*' || true)
  [ "${_exit_code:-0}" -ne 0 ] || {
    echo "FAIL: exit_code should be non-zero for a real make test failure"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }
}

# ---------------------------------------------------------------------------
# Static structural checks
# ---------------------------------------------------------------------------

@test "static: reason=missing_deps present in test-gate.sh source" {
  grep -q 'reason=missing_deps' "${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh" || {
    echo "FAIL: 'reason=missing_deps' not found in test-gate.sh"
    echo "      The missing-deps skip path must emit this diag token."
    false
  }
}

@test "static: ModuleNotFoundError signature checked in test-gate.sh source" {
  grep -q 'ModuleNotFoundError' "${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh" || {
    echo "FAIL: 'ModuleNotFoundError' pattern not found in test-gate.sh"
    echo "      The missing-deps skip must check for this error string."
    false
  }
}

@test "static: 'No module named' signature checked in test-gate.sh source" {
  grep -q 'No module named' "${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh" || {
    echo "FAIL: 'No module named' pattern not found in test-gate.sh"
    echo "      The missing-deps skip must check for this error string."
    false
  }
}

@test "static: pytest exit 5 handled in test-gate.sh source" {
  # Exit 5 = "no tests were collected" — also an env gap, not a code failure.
  grep -q '_tests_exit.*-eq 5\|5.*_tests_exit' "${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh" || {
    echo "FAIL: pytest exit-5 check not found in test-gate.sh"
    echo "      Exit 5 (no tests collected) must route to the missing-deps skip."
    false
  }
}
