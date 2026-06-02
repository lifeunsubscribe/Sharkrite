#!/usr/bin/env bats
# Regression test for #77: Detect 'local' outside function scope
#
# Bug history:
# - Milestone #11: Fixed lib/core/local-review.sh:295
# - Issue #77: Fixed lib/core/claude-workflow.sh:1364 (emergency patch commit 4eace34)
# - Issue #77: Fixed 3 more instances in claude-workflow.sh (commit e58e2e8)
#
# This test ensures no new instances are introduced.

setup() {
  # Find project root (tests/ is at project root level)
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  # Temp dir inside lib/ for lint fixture files (linter only scans lib/, bin/, tools/)
  export LINT_FIXTURE_DIR="$PROJECT_ROOT/lib/test-fixtures-temp"
  mkdir -p "$LINT_FIXTURE_DIR"
}

teardown() {
  rm -rf "$LINT_FIXTURE_DIR"
}

@test "no 'local' declarations outside function scope in codebase" {
  # Uses the shipped LOCAL_OUTSIDE_FUNCTION lint rule (Rule 7 in tools/sharkrite-lint.sh)
  # as the authoritative check. The lint rule is heredoc-aware and handles all bash
  # function declaration styles — exercising the production AWK directly rather than
  # a parallel implementation.

  cd "$PROJECT_ROOT"
  # No fixture files — ensure fixture dir is empty so only the real codebase is scanned
  rm -f "$LINT_FIXTURE_DIR"/*.sh 2>/dev/null || true

  run tools/sharkrite-lint.sh

  # If any LOCAL_OUTSIDE_FUNCTION violations exist, the lint will report and exit non-zero
  if [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]; then
    echo "Found 'local' outside function violations:"
    echo "$output" | grep "LOCAL_OUTSIDE_FUNCTION"
    false
  fi
  true
}

@test "lint rule catches local outside function (via make check)" {
  # Verify that the lint rule in tools/sharkrite-lint.sh is active
  # This doesn't fail the build but ensures the rule is configured

  cd "$PROJECT_ROOT"

  # Check that the lint script contains the LOCAL_OUTSIDE_FUNCTION rule
  run grep -q "LOCAL_OUTSIDE_FUNCTION" tools/sharkrite-lint.sh
  [ "$status" -eq 0 ]
}

@test "LOCAL_OUTSIDE_FUNCTION: lint rule fires on fixture with local outside function" {
  # Verifies the shipped Rule 7 AWK correctly detects local outside function —
  # exercises the production linter rather than a parallel inline AWK implementation.

  cat > "$LINT_FIXTURE_DIR/bad-local-outside.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# local used at script scope — should be flagged
local foo="bar"
echo "$foo"
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]
  [[ "$output" =~ "bad-local-outside.sh" ]]
}

@test "LOCAL_OUTSIDE_FUNCTION: lint rule passes on local inside function" {
  # Verifies no false positive when local is correctly inside a function.

  cat > "$LINT_FIXTURE_DIR/good-local-inside.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_function() {
  local foo="bar"
  echo "$foo"
}
my_function
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  # If it fires LOCAL_OUTSIDE_FUNCTION, ensure it's not on our safe file
  if [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]; then
    [[ ! "$output" =~ "good-local-inside.sh" ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged a local-inside-function
    }
  fi
}

@test "LOCAL_OUTSIDE_FUNCTION: heredoc with JSON braces does not corrupt depth counter" {
  # Regression: a heredoc containing JSON (with unbalanced { or }) must not
  # corrupt the brace depth counter and cause subsequent 'local' inside real
  # functions to appear as violations.
  # This exercises the production AWK in tools/sharkrite-lint.sh directly.

  cat > "$LINT_FIXTURE_DIR/heredoc-json-brace.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
  cat <<JSONEOF
{
  "key": "value"
}
JSONEOF
  local foo="bar"
  echo "$foo"
}
my_func
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  # The local inside my_func is correct — must not be flagged
  if [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]; then
    [[ ! "$output" =~ "heredoc-json-brace.sh" ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged local inside function after JSON heredoc
    }
  fi
}
