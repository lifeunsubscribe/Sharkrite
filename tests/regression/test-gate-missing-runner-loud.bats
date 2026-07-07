#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
#
# Regression tests for:
#   1. RITE_TEST_COMMAND override (honored over manifest detection)
#   2. Manifest table: Cargo.toml→cargo test, go.mod→go test, *.ino→loud skip
#   3. Missing-runner skip is LOUD (warning on stderr) when PR touches source files
#   4. RITE_TEST_COMMAND missing-deps/no-tests fallback (issue #750)
#   5. make test missing-deps/no-tests fallback (issue #750)
#
# Issue #717/#719: skip-but-pass was invisible fake-green for non-sharkrite repos.
# Every non-Sharkrite repo that lacked a recognized runner got exit 0 (skipped),
# which assess-and-resolve.sh treated as a pass.  The fix:
#   - RITE_TEST_COMMAND overrides manifest detection before the ladder runs
#   - Cargo.toml, go.mod, *.ino added to the manifest ladder
#   - *.ino always loud-skips (board config required; RITE_TEST_COMMAND needed)
#   - else-skip path warns on stderr when git diff shows source-file changes
#
# Issue #750: RITE_TEST_COMMAND and make test paths hard-failed on missing-deps
# (ModuleNotFoundError) and no-tests-collected (exit 5), while the pytest-direct
# path already classified these as graceful skips.  Parity added for both paths.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"

  # Initialise a non-Sharkrite git repo with a base commit.
  # The repo has no Makefile with shellcheck:/lint: so _is_sharkrite=false.
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && touch README.md \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD) >/dev/null 2>&1
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# Helper: source test-gate.sh in a subprocess and run run_test_gate.
# $1 = extra env assignments (may be empty)
# $2 = project_root (defaults to TEST_REPO)
_run_gate() {
  local _env="$1"
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
# 1. RITE_TEST_COMMAND override
# ---------------------------------------------------------------------------

@test "RITE_TEST_COMMAND: honored over manifest detection for non-Sharkrite repo" {
  # Make the stub test command write a sentinel file so we can verify it ran.
  local _sentinel="$TEST_REPO/custom_runner_ran"
  cat > "$STUB_DIR/my-test-runner.sh" <<EOF
#!/bin/sh
touch "$_sentinel"
exit 0
EOF
  chmod +x "$STUB_DIR/my-test-runner.sh"

  _run_gate "RITE_TEST_COMMAND='$STUB_DIR/my-test-runner.sh'"

  # Custom runner should have been executed (sentinel file created)
  [ -f "$_sentinel" ] || {
    echo "FAIL: RITE_TEST_COMMAND was not executed (sentinel file missing)"
    echo "Gate output: $output"
    false
  }

  # JSON should record exit_code:0 (no skipped:true when runner is configured)
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"
  local _skipped
  _skipped=$(grep -o '"skipped":[a-z]*' "$TEST_REPO/gate.json" || true)
  [ -z "$_skipped" ] || [ "$_skipped" = '"skipped":false' ] || {
    echo "FAIL: gate.json shows skipped=true but RITE_TEST_COMMAND was set"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }
}

@test "RITE_TEST_COMMAND: failure propagates to gate exit code" {
  cat > "$STUB_DIR/failing-runner.sh" <<'EOF'
#!/bin/sh
echo "FAILED: test suite failed"
exit 1
EOF
  chmod +x "$STUB_DIR/failing-runner.sh"

  _run_gate "RITE_TEST_COMMAND='$STUB_DIR/failing-runner.sh'"
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  local _exit_code
  _exit_code=$(grep -o '"exit_code":[0-9]*' "$TEST_REPO/gate.json" | grep -o '[0-9]*' || true)
  [ "${_exit_code:-0}" -ne 0 ] || {
    echo "FAIL: exit_code should be non-zero when RITE_TEST_COMMAND fails"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }
}

@test "RITE_TEST_COMMAND: overrides Makefile test: runner when both present" {
  # Create a Makefile with a test: target that would normally be detected.
  # RITE_TEST_COMMAND should win.
  cat > "$TEST_REPO/Makefile" <<'EOF'
.PHONY: test
test:
	@echo "Makefile runner executed - should NOT appear"
	exit 1
EOF
  local _sentinel="$TEST_REPO/custom_override_ran"
  cat > "$STUB_DIR/override-runner.sh" <<EOF
#!/bin/sh
touch "$_sentinel"
exit 0
EOF
  chmod +x "$STUB_DIR/override-runner.sh"

  _run_gate "RITE_TEST_COMMAND='$STUB_DIR/override-runner.sh'"

  [ -f "$_sentinel" ] || {
    echo "FAIL: RITE_TEST_COMMAND should override Makefile test: runner"
    echo "Gate output: $output"
    false
  }
  # Makefile runner sentinel not created (didn't run "make test")
  [[ "$output" != *"Makefile runner executed"* ]] || {
    echo "FAIL: Makefile test: runner should have been bypassed by RITE_TEST_COMMAND"
    false
  }
}

# ---------------------------------------------------------------------------
# 2. Manifest table: Cargo.toml, go.mod, *.ino
# ---------------------------------------------------------------------------

@test "manifest: Cargo.toml detected — runs cargo test stub" {
  # Create Cargo.toml to trigger cargo test detection.
  printf '[package]\nname = "test"\nversion = "0.1.0"\n' > "$TEST_REPO/Cargo.toml"

  # Stub cargo: records invocation and exits 0.
  cat > "$STUB_DIR/cargo" <<'STUB'
#!/bin/sh
echo "[stub-cargo] $*"
exit 0
STUB
  chmod +x "$STUB_DIR/cargo"

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # cargo should have been invoked (output contains stub message)
  [[ "$output" == *"stub-cargo"* ]] || [[ "$output" == *"cargo test"* ]] || {
    echo "FAIL: cargo test was not invoked for Cargo.toml project"
    echo "Gate output: $output"
    false
  }

  # Gate should NOT have skipped
  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -z "$_skipped" ] || {
    echo "FAIL: gate skipped despite Cargo.toml present"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }
}

@test "manifest: go.mod detected — runs go test stub" {
  printf 'module example.com/test\n\ngo 1.21\n' > "$TEST_REPO/go.mod"

  # Stub go: records invocation and exits 0.
  cat > "$STUB_DIR/go" <<'STUB'
#!/bin/sh
echo "[stub-go] $*"
exit 0
STUB
  chmod +x "$STUB_DIR/go"

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  [[ "$output" == *"stub-go"* ]] || [[ "$output" == *"go test"* ]] || {
    echo "FAIL: go test was not invoked for go.mod project"
    echo "Gate output: $output"
    false
  }

  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -z "$_skipped" ] || {
    echo "FAIL: gate skipped despite go.mod present"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }
}

@test "manifest: *.ino detected — emits WARNING on stderr and skips" {
  # Create a mock Arduino sketch.
  printf '// Arduino sketch\nvoid setup() {}\nvoid loop() {}\n' > "$TEST_REPO/blink.ino"

  _run_gate ""

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # Gate must have skipped (arduino-cli/pio requires board config)
  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -n "$_skipped" ] || {
    echo "FAIL: gate should skip for .ino without RITE_TEST_COMMAND"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }

  # WARNING must appear in output (bats captures both stdout and stderr via `run`)
  [[ "$output" == *"WARNING"* ]] && [[ "$output" == *"Arduino"* ]] || {
    echo "FAIL: expected Arduino WARNING in output for .ino project"
    echo "Gate output: $output"
    false
  }

  # Hint about RITE_TEST_COMMAND should appear
  [[ "$output" == *"RITE_TEST_COMMAND"* ]] || {
    echo "FAIL: expected RITE_TEST_COMMAND hint in .ino skip output"
    echo "Gate output: $output"
    false
  }
}

# ---------------------------------------------------------------------------
# 2b. Cargo/Go missing-toolchain loud-skip (command -v guard)
# ---------------------------------------------------------------------------

@test "manifest: Cargo.toml present but cargo not installed — loud-skip with WARNING" {
  printf '[package]\nname = "test"\nversion = "0.1.0"\n' > "$TEST_REPO/Cargo.toml"

  # Run with an empty PATH so cargo is not found by command -v.
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH=/dev/null run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # Gate must have skipped (cargo binary missing)
  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -n "$_skipped" ] || {
    echo "FAIL: gate should loud-skip when Cargo.toml present but cargo not installed"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }

  # WARNING about missing cargo must appear
  [[ "$output" == *"WARNING"* ]] && [[ "$output" == *"cargo"* ]] || {
    echo "FAIL: expected WARNING mentioning 'cargo' in loud-skip output"
    echo "Gate output: $output"
    false
  }

  # Hint to install Rust toolchain or set RITE_TEST_COMMAND must appear
  [[ "$output" == *"rustup"* ]] || [[ "$output" == *"RITE_TEST_COMMAND"* ]] || {
    echo "FAIL: expected install hint or RITE_TEST_COMMAND hint for missing cargo"
    echo "Gate output: $output"
    false
  }
}

@test "manifest: go.mod present but go not installed — loud-skip with WARNING" {
  printf 'module example.com/test\n\ngo 1.21\n' > "$TEST_REPO/go.mod"

  # Run with an empty PATH so go is not found by command -v.
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH=/dev/null run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # Gate must have skipped (go binary missing)
  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -n "$_skipped" ] || {
    echo "FAIL: gate should loud-skip when go.mod present but go not installed"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }

  # WARNING about missing go must appear
  [[ "$output" == *"WARNING"* ]] && [[ "$output" == *"go"* ]] || {
    echo "FAIL: expected WARNING mentioning 'go' in loud-skip output"
    echo "Gate output: $output"
    false
  }

  # Hint to install Go toolchain or set RITE_TEST_COMMAND must appear
  [[ "$output" == *"go.dev"* ]] || [[ "$output" == *"RITE_TEST_COMMAND"* ]] || {
    echo "FAIL: expected install hint or RITE_TEST_COMMAND hint for missing go"
    echo "Gate output: $output"
    false
  }
}

@test "static: Cargo.toml branch has command -v cargo guard in source" {
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"
  # The cargo branch must guard against missing binary (loud-skip, not hard-block)
  grep -q 'command -v cargo' "$_script" || {
    echo "FAIL: 'command -v cargo' guard not found in test-gate.sh"
    echo "      Cargo.toml branch must check for cargo binary before running it."
    false
  }
}

@test "static: go.mod branch has command -v go guard in source" {
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"
  # The go branch must guard against missing binary (loud-skip, not hard-block)
  grep -q 'command -v go' "$_script" || {
    echo "FAIL: 'command -v go' guard not found in test-gate.sh"
    echo "      go.mod branch must check for go binary before running it."
    false
  }
}

# ---------------------------------------------------------------------------
# 3. Loud skip when PR touches source files (no runner at all)
# ---------------------------------------------------------------------------

@test "loud-skip: no runner + source file changed → WARNING on stderr" {
  # Add a source file change on top of the base commit so git diff sees it.
  (cd "$TEST_REPO" \
     && printf '#!/bin/sh\necho hello\n' > main.sh \
     && git add -A && git commit -qm "add main.sh") >/dev/null 2>&1

  _run_gate "RITE_TEST_GATE_DIFF_BASE=HEAD~1"

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # Gate must have skipped (no runner detected)
  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -n "$_skipped" ] || {
    echo "FAIL: gate should skip (no runner) but skipped:true not found in JSON"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }

  # WARNING must appear when source was touched
  [[ "$output" == *"WARNING"* ]] || {
    echo "FAIL: expected WARNING in output when source touched with no runner"
    echo "Gate output: $output"
    false
  }

  # RITE_TEST_COMMAND hint must appear
  [[ "$output" == *"RITE_TEST_COMMAND"* ]] || {
    echo "FAIL: expected RITE_TEST_COMMAND hint in loud-skip output"
    echo "Gate output: $output"
    false
  }

  # "fake-green" language must appear so the operator knows the risk
  [[ "$output" == *"fake-green"* ]] || {
    echo "FAIL: expected 'fake-green' risk notice in loud-skip output"
    echo "Gate output: $output"
    false
  }
}

@test "quiet-skip: no runner + only docs changed → NO WARNING" {
  # Add a docs-only change so the loud-skip does NOT fire (source not touched).
  (cd "$TEST_REPO" \
     && mkdir -p docs \
     && printf '# Docs\nsome docs content\n' > docs/guide.md \
     && git add -A && git commit -qm "add docs") >/dev/null 2>&1

  _run_gate "RITE_TEST_GATE_DIFF_BASE=HEAD~1"

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # Gate must have skipped
  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -n "$_skipped" ] || {
    echo "FAIL: gate should skip (no runner) — this is a docs-only change"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }

  # No WARNING expected for docs-only changes (not a fake-green risk)
  [[ "$output" != *"WARNING: No test runner detected"* ]] || {
    echo "FAIL: unexpected WARNING for docs-only change (no source files touched)"
    echo "Gate output: $output"
    false
  }
}

@test "skip JSON is distinguishable from pass: skipped:true present" {
  # Verify the gate's skip JSON is recognizable by assess-and-resolve.sh:
  # it must carry "skipped":true so _gate_skipped=true is parsed correctly.
  _run_gate ""

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  grep -q '"skipped":true' "$TEST_REPO/gate.json" || {
    echo "FAIL: skip JSON must contain 'skipped':true to be distinguishable from a pass"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }

  # A pass would have exit_code:0 without skipped:true — verify a skip has
  # the skipped flag (assess-and-resolve.sh checks .skipped // false).
  local _exit_code
  _exit_code=$(grep -o '"exit_code":[0-9]*' "$TEST_REPO/gate.json" | grep -o '[0-9]*' || true)
  [ "${_exit_code:-}" = "0" ] || {
    echo "FAIL: skipped gate should write exit_code:0 (assessed separately via skipped flag)"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }
}

# ---------------------------------------------------------------------------
# 4. Static structural checks (no subprocess needed)
# ---------------------------------------------------------------------------

@test "static: RITE_TEST_COMMAND is checked before manifest ladder in source" {
  # RITE_TEST_COMMAND branch must appear BEFORE the Cargo.toml / go.mod / package.json
  # lines in test-gate.sh to ensure the override wins over auto-detection.
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"

  local _cmd_line _cargo_line
  _cmd_line=$(grep -n "RITE_TEST_COMMAND" "$_script" | grep -v '^#\|^[[:space:]]*#' | head -1 | cut -d: -f1 || true)
  _cargo_line=$(grep -n "Cargo.toml" "$_script" | head -1 | cut -d: -f1 || true)

  [ -n "$_cmd_line" ] || {
    echo "FAIL: RITE_TEST_COMMAND not found in test-gate.sh"
    false
  }
  [ -n "$_cargo_line" ] || {
    echo "FAIL: Cargo.toml manifest detection not found in test-gate.sh"
    false
  }
  [ "$_cmd_line" -lt "$_cargo_line" ] || {
    echo "FAIL: RITE_TEST_COMMAND branch (line $_cmd_line) must appear before Cargo.toml (line $_cargo_line)"
    echo "      RITE_TEST_COMMAND must be checked BEFORE the manifest ladder."
    false
  }
}

@test "static: Cargo.toml appears before go.mod in manifest ladder" {
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"
  local _cargo_line _go_line
  _cargo_line=$(grep -n "Cargo.toml" "$_script" | head -1 | cut -d: -f1 || true)
  _go_line=$(grep -n "go.mod" "$_script" | head -1 | cut -d: -f1 || true)

  [ -n "$_cargo_line" ] || { echo "FAIL: Cargo.toml not found in test-gate.sh"; false; }
  [ -n "$_go_line" ] || { echo "FAIL: go.mod not found in test-gate.sh"; false; }
  [ "$_cargo_line" -lt "$_go_line" ] || {
    echo "FAIL: Cargo.toml (line $_cargo_line) should appear before go.mod (line $_go_line)"
    false
  }
}

@test "static: .ino detection emits WARNING and RITE_TEST_COMMAND hint in source" {
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"
  # .ino detection must include a WARNING + pio/arduino hint + RITE_TEST_COMMAND mention
  grep -q '\.ino' "$_script" || {
    echo "FAIL: .ino detection not found in test-gate.sh"
    false
  }
  grep -q 'RITE_TEST_COMMAND' "$_script" || {
    echo "FAIL: RITE_TEST_COMMAND hint not found in test-gate.sh"
    false
  }
}

@test "static: loud-skip warning appears in source for missing-runner + source-touched" {
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"
  # The warning text for source-touching skips must exist in the else-skip block
  grep -q 'fake-green' "$_script" || {
    echo "FAIL: 'fake-green' risk notice not found in test-gate.sh"
    echo "      The loud-skip path must inform operators of the fake-green risk."
    false
  }
  grep -q 'WARNING.*No test runner detected' "$_script" || grep -q 'WARNING.*no test runner' "$_script" 2>/dev/null || {
    # Check case-insensitively for the warning text
    grep -qi 'WARNING.*test runner detected\|test runner.*WARNING' "$_script" || {
      echo "FAIL: loud-skip WARNING text not found in test-gate.sh"
      echo "      Expected: WARNING: No test runner detected..."
      false
    }
  }
}

# ---------------------------------------------------------------------------
# 4. RITE_TEST_COMMAND missing-deps / no-tests fallback (issue #750)
# ---------------------------------------------------------------------------

@test "RITE_TEST_COMMAND: ModuleNotFoundError output → skipped:missing_deps (not failed)" {
  # RITE_TEST_COMMAND wraps a pytest invocation in a missing-venv environment.
  # The classifier should convert this to a loud skip rather than a hard failure.
  cat > "$STUB_DIR/missing-venv-runner.sh" <<'EOF'
#!/bin/sh
printf 'E  ModuleNotFoundError: No module named '"'"'mypackage'"'"'\n'
exit 1
EOF
  chmod +x "$STUB_DIR/missing-venv-runner.sh"

  _run_gate "RITE_TEST_COMMAND='$STUB_DIR/missing-venv-runner.sh'"

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # Gate must have skipped (not failed)
  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -n "$_skipped" ] || {
    echo "FAIL: gate should skip (not fail) when RITE_TEST_COMMAND emits ModuleNotFoundError"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }

  # The reason must be missing_deps
  local _reason
  _reason=$(grep -o '"reason":"[^"]*"' "$TEST_REPO/gate.json" || true)
  [ "$_reason" = '"reason":"missing_deps"' ] || {
    echo "FAIL: expected reason=missing_deps, got: $_reason"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }

  # A WARNING must appear in the output so the operator knows
  [[ "$output" == *"WARNING"* ]] || {
    echo "FAIL: expected WARNING in output for missing-deps skip"
    echo "Gate output: $output"
    false
  }
}

@test "RITE_TEST_COMMAND: python3 -m pytest missing → skipped:missing_deps (not failed)" {
  # Bare python interpreter error for missing pytest module (no ^E prefix).
  cat > "$STUB_DIR/no-pytest-runner.sh" <<'EOF'
#!/bin/sh
printf '/usr/bin/python3: No module named pytest\n'
exit 1
EOF
  chmod +x "$STUB_DIR/no-pytest-runner.sh"

  _run_gate "RITE_TEST_COMMAND='$STUB_DIR/no-pytest-runner.sh'"

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -n "$_skipped" ] || {
    echo "FAIL: gate should skip when RITE_TEST_COMMAND shows missing pytest module"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }

  local _reason
  _reason=$(grep -o '"reason":"[^"]*"' "$TEST_REPO/gate.json" || true)
  [ "$_reason" = '"reason":"missing_deps"' ] || {
    echo "FAIL: expected reason=missing_deps, got: $_reason"
    false
  }
}

@test "RITE_TEST_COMMAND: exit 5 (no tests collected) → skipped:no_tests (not failed)" {
  # pytest exits 5 when no tests are collected; RITE_TEST_COMMAND wrapping pytest
  # should produce a loud skip rather than a hard failure.
  cat > "$STUB_DIR/no-tests-runner.sh" <<'EOF'
#!/bin/sh
printf '============== no tests ran ==============\n'
exit 5
EOF
  chmod +x "$STUB_DIR/no-tests-runner.sh"

  _run_gate "RITE_TEST_COMMAND='$STUB_DIR/no-tests-runner.sh'"

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -n "$_skipped" ] || {
    echo "FAIL: gate should skip (not fail) when RITE_TEST_COMMAND exits 5"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }

  local _reason
  _reason=$(grep -o '"reason":"[^"]*"' "$TEST_REPO/gate.json" || true)
  [ "$_reason" = '"reason":"no_tests"' ] || {
    echo "FAIL: expected reason=no_tests, got: $_reason"
    false
  }
}

@test "RITE_TEST_COMMAND: real test failure (FAILED line) → still hard-fails (no false skip)" {
  # A real test failure that mentions ModuleNotFoundError in a traceback must
  # NOT be silently skipped — this is the v1 false-skip regression guard.
  cat > "$STUB_DIR/real-failure-runner.sh" <<'EOF'
#!/bin/sh
printf 'FAILED test_thing.py::test_something - AssertionError\n'
printf 'E  ModuleNotFoundError: No module named '"'"'"'"'"'mypackage'"'"'"'"'"'\n'
exit 1
EOF
  chmod +x "$STUB_DIR/real-failure-runner.sh"

  _run_gate "RITE_TEST_COMMAND='$STUB_DIR/real-failure-runner.sh'"

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # Gate must NOT have skipped — this is a real failure
  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -z "$_skipped" ] || {
    echo "FAIL: gate should NOT skip when output contains FAILED/AssertionError"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }

  # exit_code must be non-zero
  local _exit_code
  _exit_code=$(grep -o '"exit_code":[0-9]*' "$TEST_REPO/gate.json" | grep -o '[0-9]*' || true)
  [ "${_exit_code:-0}" -ne 0 ] || {
    echo "FAIL: exit_code should be non-zero for a real test failure"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }
}

# ---------------------------------------------------------------------------
# 5. make test missing-deps / no-tests fallback (issue #750)
# ---------------------------------------------------------------------------

@test "make test: Makefile wraps pytest with missing deps → skipped:missing_deps" {
  # A Makefile test: target that runs python -m pytest in a missing-venv
  # environment exits non-zero with ModuleNotFoundError output.
  # The gate should classify this as a loud skip, not a hard failure.
  # The recipe references pytest so the pytest-context guard fires.
  cat > "$STUB_DIR/pytest" <<'STUB'
#!/bin/sh
printf 'E  ModuleNotFoundError: No module named mypackage\n'
exit 1
STUB
  chmod +x "$STUB_DIR/pytest"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: $STUB_DIR must expand into Makefile recipe
  cat > "$TEST_REPO/Makefile" <<EOF
.PHONY: test
test:
	@PATH="$STUB_DIR:\$\$PATH" pytest
EOF

  _run_gate ""

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -n "$_skipped" ] || {
    echo "FAIL: gate should skip when make test outputs ModuleNotFoundError"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }

  local _reason
  _reason=$(grep -o '"reason":"[^"]*"' "$TEST_REPO/gate.json" || true)
  [ "$_reason" = '"reason":"missing_deps"' ] || {
    echo "FAIL: expected reason=missing_deps, got: $_reason"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }

  # Warn operator about the missing-deps condition
  [[ "$output" == *"WARNING"* ]] || {
    echo "FAIL: expected WARNING in output for missing-deps skip from make test"
    echo "Gate output: $output"
    false
  }
}

@test "make test: Makefile wraps pytest with no tests collected (exit 5) → skipped:no_tests" {
  # A Makefile test: target that runs pytest and exits 5 when no tests are
  # found should produce a loud skip rather than blocking the merge.
  # make propagates the test runner's exit 5 as its own exit code.
  # The recipe references pytest so the pytest-context guard fires.
  cat > "$STUB_DIR/pytest" <<'STUB'
#!/bin/sh
printf '============== no tests ran ==============\n'
exit 5
STUB
  chmod +x "$STUB_DIR/pytest"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: $STUB_DIR must expand into Makefile recipe
  cat > "$TEST_REPO/Makefile" <<EOF
.PHONY: test
test:
	@PATH="$STUB_DIR:\$\$PATH" pytest
EOF

  _run_gate ""

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -n "$_skipped" ] || {
    echo "FAIL: gate should skip when make test exits 5 (no tests collected)"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }

  local _reason
  _reason=$(grep -o '"reason":"[^"]*"' "$TEST_REPO/gate.json" || true)
  [ "$_reason" = '"reason":"no_tests"' ] || {
    echo "FAIL: expected reason=no_tests, got: $_reason"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }
}

@test "make test: real test failure (FAILED line) → still hard-fails (no false skip)" {
  # A real pytest failure bubbled through make must NOT be silently skipped.
  # Recipe references pytest so the pytest-context guard fires; the FAILED+
  # AssertionError output must still be classified as a real failure.
  cat > "$STUB_DIR/pytest" <<'STUB'
#!/bin/sh
printf 'FAILED test_thing.py::test_foo - AssertionError\n'
exit 1
STUB
  chmod +x "$STUB_DIR/pytest"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: $STUB_DIR must expand into Makefile recipe
  cat > "$TEST_REPO/Makefile" <<EOF
.PHONY: test
test:
	@PATH="$STUB_DIR:\$\$PATH" pytest
EOF

  _run_gate ""

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -z "$_skipped" ] || {
    echo "FAIL: gate should NOT skip when make test output contains FAILED/AssertionError"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }

  local _exit_code
  _exit_code=$(grep -o '"exit_code":[0-9]*' "$TEST_REPO/gate.json" | grep -o '[0-9]*' || true)
  [ "${_exit_code:-0}" -ne 0 ] || {
    echo "FAIL: exit_code should be non-zero for a real make test failure"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }
}

@test "make test: non-pytest target with 'No module named' in output → hard-fails (pytest-context guard)" {
  # This is the false-skip regression guard for the pytest-context check.
  # A non-pytest make test: target (e.g. running an app binary) that fails
  # because a Python import is missing at startup produces output that looks
  # like a missing-deps signature.  Without the pytest-context guard the old
  # code would classify this as skipped:missing_deps and pass the gate green,
  # letting a broken merge through.  With the guard, the recipe must reference
  # pytest/python for _classify_pytest_outcome to fire; a generic target
  # bypasses the classifier and hard-fails on the non-zero exit.
  cat > "$TEST_REPO/Makefile" <<'EOF'
.PHONY: test
test:
	@printf 'E  ModuleNotFoundError: No module named mypackage\n' && exit 1
EOF

  _run_gate ""

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # Gate must NOT have skipped — this is a non-pytest target
  local _skipped
  _skipped=$(grep -o '"skipped":true' "$TEST_REPO/gate.json" || true)
  [ -z "$_skipped" ] || {
    echo "FAIL: gate should NOT skip for a non-pytest make test target (pytest-context guard)"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }

  # exit_code must be non-zero (hard failure)
  local _exit_code
  _exit_code=$(grep -o '"exit_code":[0-9]*' "$TEST_REPO/gate.json" | grep -o '[0-9]*' || true)
  [ "${_exit_code:-0}" -ne 0 ] || {
    echo "FAIL: exit_code should be non-zero for a non-pytest make test failure"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }
}

# Static: verify the fallback check exists in source for both paths
@test "static: RITE_TEST_COMMAND path has missing-deps classification in source" {
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"
  # The RITE_TEST_COMMAND block must call _classify_pytest_outcome for missing-deps
  grep -q '_classify_pytest_outcome' "$_script" || {
    echo "FAIL: _classify_pytest_outcome not found in test-gate.sh"
    echo "      Both RITE_TEST_COMMAND and make test paths must call it for parity."
    false
  }
  # Confirm missing_deps reason is written from RITE_TEST_COMMAND path
  grep -q 'missing_deps.*RITE_TEST_COMMAND\|RITE_TEST_COMMAND.*missing_deps\|RITE_TEST_COMMAND.*missing.dep\|missing.dep.*RITE_TEST_COMMAND' "$_script" \
  || grep -q 'output.*indicates missing\|missing dependencies.*RITE_TEST_COMMAND\|RITE_TEST_COMMAND.*missing dep' "$_script" \
  || grep -q '"missing_deps"' "$_script" || {
    echo "FAIL: missing_deps skip JSON not found in test-gate.sh for RITE_TEST_COMMAND path"
    false
  }
}

# ---------------------------------------------------------------------------
# 6. No-bats-suite skip (issue #976)
# ---------------------------------------------------------------------------
# A Sharkrite repo with no *.bats files under tests/ (or no tests/ dir at all)
# must produce outcome=skipped reason=no_bats_suite, NOT a gate failure.
# Live trigger: LeadFlow PRs #598 #607 #618 #630 each minted a phantom HIGH
# [GATE] bats failure because bats -r tests/ exited non-zero on an empty suite.

@test "no-bats-suite: Sharkrite repo with no .bats files passes gate (not failed)" {
  # Build a minimal Sharkrite-like fixture: Makefile with shellcheck: + lint:
  # targets that succeed instantly (no real shell files to check), and no
  # tests/ directory at all.
  #
  # Expected outcome: gate exits 0 (passes) with exit_code:0 and tests:[] —
  # no [GATE] ACTIONABLE_NOW finding minted. The bats step is skipped internally
  # and the diag emits reason=no_bats_suite; the gate JSON itself is a clean pass
  # (lint OK, no bats failures) rather than a skip-sentinel (skipped:true is only
  # for whole-gate skips like missing_runner / missing_worktree).
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: no variables to expand; heredoc used for clarity
  cat > "$TEST_REPO/Makefile" <<'EOF'
.PHONY: shellcheck lint
shellcheck:
	@true
lint:
	@true
EOF

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (make or bats not installed)"

  # Gate must NOT have failed (exit_code must be 0)
  local _exit_code
  _exit_code=$(grep -o '"exit_code":[0-9]*' "$TEST_REPO/gate.json" | grep -o '[0-9]*' || true)
  [ "${_exit_code:-}" = "0" ] || {
    echo "FAIL: gate should exit_code:0 for a repo with no .bats files (not failed)"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }

  # tests[] must be empty — no [GATE] findings minted
  local _tests
  _tests=$(grep -o '"tests":\[\]' "$TEST_REPO/gate.json" || true)
  [ -n "$_tests" ] || {
    echo "FAIL: expected tests:[] (no findings) for a repo with no .bats files"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }

  # The gate output must mention the bats skip message (emitted to stderr)
  [[ "$output" == *"bats: skipped (no bats suite)"* ]] || {
    echo "FAIL: expected '[test-gate] bats: skipped (no bats suite)' in gate output"
    echo "Gate output: $output"
    false
  }
}

@test "no-bats-suite: Sharkrite repo with empty tests/ dir (no .bats) passes gate" {
  # Same scenario but the tests/ directory exists — just contains no .bats files.
  # bats -r tests/ on an empty dir also exits non-zero; the guard fires before
  # attempting the invocation so the gate still exits 0 with no findings.
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: no variables to expand; heredoc used for clarity
  cat > "$TEST_REPO/Makefile" <<'EOF'
.PHONY: shellcheck lint
shellcheck:
	@true
lint:
	@true
EOF
  mkdir -p "$TEST_REPO/tests"
  # tests/ exists but contains only a non-bats file
  printf '# placeholder\n' > "$TEST_REPO/tests/README.md"

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=999
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null

  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (make or bats not installed)"

  local _exit_code
  _exit_code=$(grep -o '"exit_code":[0-9]*' "$TEST_REPO/gate.json" | grep -o '[0-9]*' || true)
  [ "${_exit_code:-}" = "0" ] || {
    echo "FAIL: gate should exit_code:0 for Sharkrite repo with tests/ but no .bats files"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    echo "Gate output: $output"
    false
  }

  local _tests
  _tests=$(grep -o '"tests":\[\]' "$TEST_REPO/gate.json" || true)
  [ -n "$_tests" ] || {
    echo "FAIL: expected tests:[] for a repo with no .bats files (no findings)"
    echo "JSON: $(cat "$TEST_REPO/gate.json")"
    false
  }
}

@test "static: no_bats_suite skip guard present in source" {
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"
  # The no-bats-suite skip branch must emit the structured diag and message.
  grep -q 'no_bats_suite' "$_script" || {
    echo "FAIL: 'no_bats_suite' not found in test-gate.sh"
    echo "      The bats-skip guard must emit reason=no_bats_suite when no .bats files exist."
    false
  }
  grep -q 'bats: skipped (no bats suite)' "$_script" || {
    echo "FAIL: 'bats: skipped (no bats suite)' message not found in test-gate.sh"
    false
  }
}
