#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/43-dash-leading-grep-pattern.sh, tools/sharkrite-lint.sh
#
# Tests for Rule 43: DASH_LEADING_GREP_PATTERN
#
# A grep whose pattern text starts with '-' is parsed as an option flag group
# unless '--' or '-e' appears first.  grep exits 2 and prints nothing — a count
# comes back empty, a match test reads as "no match".
#
# Live (batch 1836-1840, issue #1838, 2026-11-24):
#   grep -c '---NARRATIVE---'   exited 2; recorded count empty; two tests
#   failed with "[: : integer expected"; fix session spent 29 minutes on it.
#   Fixed by PR #1855.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LINT_SCRIPT="${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"
  FIXTURE_DIR=$(mktemp -d)
  export FIXTURE_DIR
  # Rule 43 also scans `find tests -name '*.bats'` relative to cwd.
  mkdir -p "$FIXTURE_DIR/tests/regression" "$FIXTURE_DIR/tests/fixtures"
}

teardown() { rm -rf "$FIXTURE_DIR"; }

# ---------------------------------------------------------------------------
# Should FIRE
# ---------------------------------------------------------------------------

@test "DASH_LEADING_GREP_PATTERN: flags flags single-quoted pattern starting with dash in a shell file" {
  mkdir -p "$FIXTURE_DIR/lib/utils"
  cat > "$FIXTURE_DIR/lib/utils/example.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# BAD: pattern '-32$' parsed as flags
if grep -qE '-32$' <<< "$result"; then echo found; fi
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "DASH_LEADING_GREP_PATTERN" ]]
  [[ "$output" =~ "example.sh" ]]
}

@test "DASH_LEADING_GREP_PATTERN: flags flags triple-dash literal (the live failure pattern)" {
  mkdir -p "$FIXTURE_DIR/lib/utils"
  cat > "$FIXTURE_DIR/lib/utils/example.sh" <<'EOF'
#!/bin/bash
COUNT=$(grep -c '---NARRATIVE---' "$file" || true)
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "DASH_LEADING_GREP_PATTERN" ]]
}

@test "DASH_LEADING_GREP_PATTERN: flags double-quoted dash-leading pattern" {
  mkdir -p "$FIXTURE_DIR/lib/utils"
  cat > "$FIXTURE_DIR/lib/utils/example.sh" <<'EOF'
#!/bin/bash
grep -qE "-option" <<< "$line"
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "DASH_LEADING_GREP_PATTERN" ]]
}

@test "DASH_LEADING_GREP_PATTERN: flags a dash-leading pattern in a .bats helper (not a title)" {
  cat > "$FIXTURE_DIR/tests/regression/bad.bats" <<'EOF'
#!/usr/bin/env bats
_check() {
  grep -qE '-32$' <<< "$result"
}
@test "x" { true; }
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "DASH_LEADING_GREP_PATTERN" ]]
  [[ "$output" =~ "bad.bats" ]]
}

# ---------------------------------------------------------------------------
# Should NOT fire
# ---------------------------------------------------------------------------

@test "DASH_LEADING_GREP_PATTERN: does NOT flag when -- precedes the pattern" {
  mkdir -p "$FIXTURE_DIR/lib/utils"
  cat > "$FIXTURE_DIR/lib/utils/good.sh" <<'EOF'
#!/bin/bash
grep -qE -- '-32$' <<< "$result"
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "DASH_LEADING_GREP_PATTERN: does NOT flag when -e precedes the pattern" {
  mkdir -p "$FIXTURE_DIR/lib/utils"
  cat > "$FIXTURE_DIR/lib/utils/good.sh" <<'EOF'
#!/bin/bash
grep -qF -e '-option' <<< "$line"
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "DASH_LEADING_GREP_PATTERN: does NOT flag a lone '-' pattern" {
  mkdir -p "$FIXTURE_DIR/lib/utils"
  cat > "$FIXTURE_DIR/lib/utils/lone.sh" <<'EOF'
#!/bin/bash
grep '-' "$file"
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "DASH_LEADING_GREP_PATTERN: does NOT flag a full-line comment" {
  mkdir -p "$FIXTURE_DIR/lib/utils"
  cat > "$FIXTURE_DIR/lib/utils/commented.sh" <<'EOF'
#!/bin/bash
# grep -qE '-32$' would be bad but this is a comment
true
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "DASH_LEADING_GREP_PATTERN: does NOT flag an @test title line in a .bats file" {
  cat > "$FIXTURE_DIR/tests/regression/title.bats" <<'EOF'
#!/usr/bin/env bats
@test "Rule 43 fires on grep '-pattern' without --" { true; }
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "DASH_LEADING_GREP_PATTERN: does NOT flag inside a single-quoted heredoc body" {
  mkdir -p "$FIXTURE_DIR/lib/utils"
  cat > "$FIXTURE_DIR/lib/utils/hd.sh" <<'EOF'
#!/bin/bash
# Content of the heredoc is literal data, not code.
cat > "$tmp" <<'INNER'
grep -qE '-32$' <<< "$x"
INNER
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "DASH_LEADING_GREP_PATTERN: does NOT flag a variable pattern (not a literal)" {
  mkdir -p "$FIXTURE_DIR/lib/utils"
  cat > "$FIXTURE_DIR/lib/utils/var.sh" <<'EOF'
#!/bin/bash
grep -lF "$_name" "${files[@]}" 2>/dev/null | head -1 || true
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "DASH_LEADING_GREP_PATTERN: does NOT flag files under tests/fixtures/" {
  cat > "$FIXTURE_DIR/tests/fixtures/sample.bats" <<'EOF'
#!/usr/bin/env bats
_check() { grep -qE '-32$' <<< "$result"; }
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Suppression
# ---------------------------------------------------------------------------

@test "DASH_LEADING_GREP_PATTERN: suppression comment on preceding line prevents the finding" {
  mkdir -p "$FIXTURE_DIR/lib/utils"
  cat > "$FIXTURE_DIR/lib/utils/suppressed.sh" <<'EOF'
#!/bin/bash
# sharkrite-lint disable DASH_LEADING_GREP_PATTERN - Reason: pattern is a negative lookahead that cannot start with a letter
grep -qP '-(?!foo)' <<< "$line"
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "DASH_LEADING_GREP_PATTERN: suppression in a .bats file on the preceding line" {
  cat > "$FIXTURE_DIR/tests/regression/suppressed.bats" <<'EOF'
#!/usr/bin/env bats
@test "fixture string test" {
  # sharkrite-lint disable DASH_LEADING_GREP_PATTERN - Reason: fixture string, never executed
  local bad="grep -qE '-32\$'"
  [ -n "$bad" ]
}
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Codebase state
# ---------------------------------------------------------------------------

@test "DASH_LEADING_GREP_PATTERN: the real codebase is clean" {
  cd "$RITE_REPO_ROOT"
  SHARKRITE_LINT_ONLY=43 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "A grep call uses a dash-leading literal pattern without -- or -e:"
    echo "$output"
    false
  }
}
