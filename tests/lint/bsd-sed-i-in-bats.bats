#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/41-bsd-sed-i-in-bats.sh, tools/sharkrite-lint.sh
#
# Tests for Rule 41: BARE_BSD_SED_I_IN_BATS
#
# Rule 10 already forbids bare `sed -i ''` in bin/, lib/ and tools/, but its
# file list only covers *.sh there, so .bats files were never scanned. A test
# using the BSD form passes every local check on the macOS dev box and fails
# the Linux half of the CI matrix, because GNU sed reads the empty string as
# the script and the expression as a filename.
#
# Live: gate-function-scoped-selection.bats used the BSD form in its fixture
# helper — 14/14 passing on macOS, 14/14 failing on ubuntu-latest, with main's
# CI red for days and the cause buried in a ~40-failure log (2026-10-14).

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LINT_SCRIPT="${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"
  FIXTURE_DIR=$(mktemp -d)
  export FIXTURE_DIR
  # The rule enumerates via `find tests -name '*.bats'`, relative to cwd.
  mkdir -p "$FIXTURE_DIR/tests/regression" "$FIXTURE_DIR/tests/fixtures"
}

teardown() { rm -rf "$FIXTURE_DIR"; }

# ---------------------------------------------------------------------------
# Should FIRE
# ---------------------------------------------------------------------------

@test "BARE_BSD_SED_I_IN_BATS: fires on an executed bare sed -i '' in a .bats helper" {
  cat > "$FIXTURE_DIR/tests/regression/bad.bats" <<'EOF'
#!/usr/bin/env bats
_mutate() {
  sed -i '' 's/alpha v1/alpha v2/' "$TARGET"
}
@test "x" { true; }
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=41 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "BARE_BSD_SED_I_IN_BATS" ]]
  [[ "$output" =~ "bad.bats" ]]
}

@test "BARE_BSD_SED_I_IN_BATS: fires regardless of surrounding indentation or case label" {
  # The live instance sat after a `case` label, not at the start of a line.
  cat > "$FIXTURE_DIR/tests/regression/case.bats" <<'EOF'
#!/usr/bin/env bats
_mutate() {
  case "$1" in
    alpha)   sed -i '' 's/a/b/' "$F" ;;
  esac
}
@test "x" { true; }
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=41 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "case.bats" ]]
}

# ---------------------------------------------------------------------------
# Should NOT fire
# ---------------------------------------------------------------------------

@test "BARE_BSD_SED_I_IN_BATS: does NOT fire on portable_sed_i usage" {
  cat > "$FIXTURE_DIR/tests/regression/good.bats" <<'EOF'
#!/usr/bin/env bats
_mutate() {
  portable_sed_i 's/alpha v1/alpha v2/' "$TARGET"
}
@test "x" { true; }
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=41 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "BARE_BSD_SED_I_IN_BATS: does NOT fire on a commented-out line" {
  cat > "$FIXTURE_DIR/tests/regression/commented.bats" <<'EOF'
#!/usr/bin/env bats
# was: sed -i '' 's/a/b/' "$F"
@test "x" { true; }
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=41 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "BARE_BSD_SED_I_IN_BATS: does NOT fire on an @test title quoting the bad form" {
  # Rule meta-tests name the pattern in their titles; a title cannot execute.
  cat > "$FIXTURE_DIR/tests/regression/title.bats" <<'EOF'
#!/usr/bin/env bats
@test "Rule 10 pattern matches bare sed -i '' lines" { true; }
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=41 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "BARE_BSD_SED_I_IN_BATS: respects an inline suppression on the preceding line" {
  cat > "$FIXTURE_DIR/tests/regression/suppressed.bats" <<'EOF'
#!/usr/bin/env bats
@test "fixture string" {
  # sharkrite-lint disable BARE_BSD_SED_I_IN_BATS - Reason: fixture string, never executed.
  local bad_line="  sed -i '' 's/a/b/' f"
  [ -n "$bad_line" ]
}
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=41 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "BARE_BSD_SED_I_IN_BATS: skips tests/fixtures/" {
  cat > "$FIXTURE_DIR/tests/fixtures/sample.bats" <<'EOF'
#!/usr/bin/env bats
_mutate() { sed -i '' 's/a/b/' "$F"; }
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=41 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Codebase state
# ---------------------------------------------------------------------------

@test "BARE_BSD_SED_I_IN_BATS: the real tests/ tree is clean" {
  cd "$RITE_REPO_ROOT"
  SHARKRITE_LINT_ONLY=41 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "A .bats file uses the BSD-only in-place sed form — it will fail Linux CI:"
    echo "$output"
    false
  }
}
