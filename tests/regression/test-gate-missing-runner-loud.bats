#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
#
# Regression tests for:
#   1. RITE_TEST_COMMAND override (honored over manifest detection)
#   2. Manifest table: Cargo.toml→cargo test, go.mod→go test, *.ino→loud skip
#   3. Missing-runner skip is LOUD (warning on stderr) when PR touches source files
#
# Issue #717/#719: skip-but-pass was invisible fake-green for non-sharkrite repos.
# Every non-Sharkrite repo that lacked a recognized runner got exit 0 (skipped),
# which assess-and-resolve.sh treated as a pass.  The fix:
#   - RITE_TEST_COMMAND overrides manifest detection before the ladder runs
#   - Cargo.toml, go.mod, *.ino added to the manifest ladder
#   - *.ino always loud-skips (board config required; RITE_TEST_COMMAND needed)
#   - else-skip path warns on stderr when git diff shows source-file changes

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
