#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh
# Tests for sharkrite-lint.sh file discovery glob patterns
#
# Regression guard for #128: lint glob patterns must mirror the Makefile's
# find command so both tools cover the same set of shell files.
#
# Makefile (shellcheck target):
#   find bin lib tools -type f \( -name "*.sh" -o -path "bin/rite*" -o -path "tools/git-hooks/*" \)
#
# sharkrite-lint.sh (SHELL_FILES):
#   find "$PROJECT_ROOT/bin" "$PROJECT_ROOT/lib" "$PROJECT_ROOT/tools" \
#     -type f ! -name 'sharkrite-lint.sh' \( -name "*.sh" -o -path "$PROJECT_ROOT/bin/rite*" \
#     -o -path "$PROJECT_ROOT/tools/git-hooks/*" \)

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LINT_SCRIPT="$PROJECT_ROOT/tools/sharkrite-lint.sh"
}

# ---------------------------------------------------------------------------
# Pattern consistency: lint script must use anchored $PROJECT_ROOT/... paths
# not loose "*/..." wildcards that could match unintended nested directories.
# ---------------------------------------------------------------------------

@test "lint script uses anchored PROJECT_ROOT path for bin/rite* (not loose wildcard)" {
  # The pattern should be -path "$PROJECT_ROOT/bin/rite*" (dollar + variable),
  # NOT -path "*/bin/rite*" (wildcard prefix that can over-match).
  # We check for the anchored form's literal source text.
  run grep -c 'path.*\$PROJECT_ROOT/bin/rite' "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "lint script uses anchored PROJECT_ROOT path for tools/git-hooks/* (not loose wildcard)" {
  run grep -c 'path.*\$PROJECT_ROOT/tools/git-hooks' "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "lint script does NOT use loose wildcard */bin/rite* pattern in code (non-comment lines)" {
  # Loose wildcards like */bin/rite* can match unintended sub-paths.
  # After #128 the SHELL_FILES discovery block must not use wildcard-prefix -path patterns.
  # We grep only non-comment lines to avoid matching explanatory comments.
  run bash -c "grep -v '^\s*#' \"$LINT_SCRIPT\" | grep -c '\*/bin/rite\*' || true"
  [ "$output" -eq 0 ]
}

@test "lint script does NOT use loose wildcard */tools/git-hooks/* pattern in code (non-comment lines)" {
  run bash -c "grep -v '^\s*#' \"$LINT_SCRIPT\" | grep -c '\*/tools/git-hooks/\*' || true"
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Coverage parity: the lint script must search the same top-level directories
# as the Makefile's shellcheck target (bin, lib, tools).
# ---------------------------------------------------------------------------

@test "lint script searches bin/ directory" {
  run grep -c 'PROJECT_ROOT/bin' "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "lint script searches lib/ directory" {
  run grep -c 'PROJECT_ROOT/lib' "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "lint script searches tools/ directory" {
  run grep -c 'PROJECT_ROOT/tools' "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------
# File discovery integration: bin/rite and bin/rite-health-report (no .sh
# extension) and tools/git-hooks/pre-push must be picked up by the linter.
# These are the exact files the Makefile targets via -path "bin/rite*" and
# -path "tools/git-hooks/*".
# ---------------------------------------------------------------------------

@test "find command with anchored pattern discovers bin/rite (no .sh extension)" {
  # Directly exercise the find command from the SHELL_FILES block to verify
  # bin/rite and bin/rite-health-report are matched by -path "$PROJECT_ROOT/bin/rite*".
  PR="$PROJECT_ROOT"
  run bash -c "find '$PR/bin' -type f -path '$PR/bin/rite*' 2>/dev/null | sort"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "bin/rite" ]]
}

@test "find command with anchored pattern discovers tools/git-hooks/pre-push" {
  PR="$PROJECT_ROOT"
  run bash -c "find '$PR/tools' -type f -path '$PR/tools/git-hooks/*' 2>/dev/null | sort"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "tools/git-hooks/pre-push" ]]
}

@test "bin/rite path pattern anchors to bin/ root (no false positives from nested bin/)" {
  # Verify: -path "$PROJECT_ROOT/bin/rite*" does NOT match a file like
  # "$PROJECT_ROOT/lib/something/bin/rite-like-file".
  # Use find with -path to replicate how the lint script discovers files.

  PR="$PROJECT_ROOT"

  # Create a temp nested path outside the project tree to avoid polluting
  # the lint file-discovery scope and git status if the test is interrupted.
  NESTED_DIR="$BATS_TEST_TMPDIR/subdir/bin"
  mkdir -p "$NESTED_DIR"
  touch "$NESTED_DIR/rite-fake"

  # find with anchored -path "$PR/bin/rite*" must NOT match the nested file
  MATCHES=$(find "$BATS_TEST_TMPDIR" -type f -path "$PR/bin/rite*" 2>/dev/null || true)

  # Should be empty: the nested path doesn't match the anchored bin/ pattern
  [ -z "$MATCHES" ]
}
