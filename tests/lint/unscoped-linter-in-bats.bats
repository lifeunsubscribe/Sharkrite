#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/40-unscoped-linter-in-bats.sh, tools/sharkrite-lint.sh
# sharkrite-gate-serial — this file contains a codebase-wide sweep (@test "codebase sweep")
# that runs SHARKRITE_LINT_ONLY=40 against the full project tests/ tree.  Keep it
# serial so it never contends toward the 120s BATS_TEST_TIMEOUT under --jobs 8.
#
# Tests for Rule 40: UNSCOPED_LINTER_IN_BATS
#
# Prevents the watchdog-kill class documented in CLAUDE.md → Single-rule mode:
# an unscoped full-scan per @test under --jobs 8 starves the CPU and drags
# gates to the 1800s watchdog (live: batch 155134 2026-07-18; slot #1021 2026-10-11).

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LINT_SCRIPT="${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"
  FIXTURE_DIR=$(mktemp -d)
  export FIXTURE_DIR
  # Mirror tests/ structure the rule expects
  mkdir -p "$FIXTURE_DIR/tests/regression"
}

teardown() { rm -rf "$FIXTURE_DIR"; }

# ---------------------------------------------------------------------------
# Should FIRE (violations)
# ---------------------------------------------------------------------------

@test "UNSCOPED_LINTER_IN_BATS: fires on 'run bash \$LINT_SCRIPT' without SHARKRITE_LINT_ONLY" {
  cat > "$FIXTURE_DIR/tests/regression/bad.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh
setup() {
  LINT_SCRIPT="/some/path/tools/sharkrite-lint.sh"
}
@test "check rule fires" {
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=40 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSCOPED_LINTER_IN_BATS" ]]
  [[ "$output" =~ "bad.bats" ]]
}

@test "UNSCOPED_LINTER_IN_BATS: fires on direct path 'bash tools/sharkrite-lint.sh'" {
  cat > "$FIXTURE_DIR/tests/regression/direct.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh
@test "direct path" {
  run bash "${BATS_TEST_DIRNAME}/../../tools/sharkrite-lint.sh"
  [ "$status" -eq 0 ]
}
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=40 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSCOPED_LINTER_IN_BATS" ]]
}

@test "UNSCOPED_LINTER_IN_BATS: fires on TEST_LINT_SCRIPT variable name (contains LINT_SCRIPT)" {
  cat > "$FIXTURE_DIR/tests/regression/testvar.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh
setup() {
  TEST_LINT_SCRIPT="/copy/of/tools/sharkrite-lint.sh"
}
@test "copy invocation" {
  run bash "$TEST_LINT_SCRIPT" 2>&1
  [ "$status" -eq 0 ]
}
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=40 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSCOPED_LINTER_IN_BATS" ]]
}

# ---------------------------------------------------------------------------
# Should PASS (no violation)
# ---------------------------------------------------------------------------

@test "UNSCOPED_LINTER_IN_BATS: silent on 'SHARKRITE_LINT_ONLY=16 run bash \$LINT_SCRIPT'" {
  cat > "$FIXTURE_DIR/tests/regression/scoped.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/16-missing-re-source-guard-in-lib-utils-lib-pro.sh
setup() {
  LINT_SCRIPT="/some/path/tools/sharkrite-lint.sh"
}
@test "scoped run" {
  SHARKRITE_LINT_ONLY=16 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=40 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "UNSCOPED_LINTER_IN_BATS" ]]
}

@test "UNSCOPED_LINTER_IN_BATS: silent when SHARKRITE_LINT_ONLY is on preceding line" {
  cat > "$FIXTURE_DIR/tests/regression/preceding.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh
setup() {
  LINT_SCRIPT="/some/path/tools/sharkrite-lint.sh"
}
@test "preceding assignment" {
  SHARKRITE_LINT_ONLY=21
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=40 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "UNSCOPED_LINTER_IN_BATS: silent when suppression comment is on preceding line" {
  cat > "$FIXTURE_DIR/tests/regression/suppressed.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh
setup() {
  LINT_SCRIPT="/some/path/tools/sharkrite-lint.sh"
}
@test "suppressed full sweep" {
  # sharkrite-lint disable UNSCOPED_LINTER_IN_BATS - Reason: stdin-safety test; scoping defeats the test purpose; serial-marked
  run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=40 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "UNSCOPED_LINTER_IN_BATS" ]]
}

@test "UNSCOPED_LINTER_IN_BATS: silent on 'bash -c \"grep ... \$LINT_SCRIPT\"' (file-read, not execution)" {
  cat > "$FIXTURE_DIR/tests/regression/grep-of-file.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh
setup() {
  LINT_SCRIPT="/some/path/tools/sharkrite-lint.sh"
}
@test "grep the lint script source, not run it" {
  run bash -c "grep -c 'RAW_ORIGIN_MAIN_REF' \"$LINT_SCRIPT\" || true"
  [ "$status" -eq 0 ]
}
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=40 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "UNSCOPED_LINTER_IN_BATS" ]]
}

@test "UNSCOPED_LINTER_IN_BATS: skips tests/fixtures/ directory" {
  mkdir -p "$FIXTURE_DIR/tests/fixtures"
  cat > "$FIXTURE_DIR/tests/fixtures/bad.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh
setup() { LINT_SCRIPT="/path/tools/sharkrite-lint.sh"; }
@test "x" { run bash "$LINT_SCRIPT"; }
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=40 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Codebase sweep: the real project tests/ must have zero unsuppressed violations
# ---------------------------------------------------------------------------

@test "codebase sweep: no unsuppressed UNSCOPED_LINTER_IN_BATS violations" {
  # Runs Rule 40 against the full project test tree.  Every existing
  # invocation must either be inline-scoped (SHARKRITE_LINT_ONLY=NN) or carry
  # a '# sharkrite-lint disable UNSCOPED_LINTER_IN_BATS - Reason: ...' comment
  # on the preceding line.
  cd "$RITE_REPO_ROOT"
  unset RITE_LINT_EXTRA_DIRS
  SHARKRITE_LINT_ONLY=40 run bash "$LINT_SCRIPT"

  local violations
  violations=$(echo "$output" | grep "UNSCOPED_LINTER_IN_BATS" || true)

  if [ -n "$violations" ]; then
    echo "UNSCOPED_LINTER_IN_BATS violations found:" >&3
    echo "$violations" >&3
    false
  fi
}
