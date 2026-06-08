#!/usr/bin/env bats
# sharkrite-test-covers: tools/*-lint.sh
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

  # Use BATS_TEST_TMPDIR so fixtures are outside the project tree.
  # Inject via RITE_LINT_EXTRA_DIRS so the linter scans them without
  # the test-fixtures-temp exclusion interfering.
  export LINT_FIXTURE_DIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}/rule7-fixtures"
  mkdir -p "$LINT_FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$LINT_FIXTURE_DIR"
}

teardown() {
  rm -rf "$LINT_FIXTURE_DIR"
  unset RITE_LINT_EXTRA_DIRS
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
  [[ "$output" =~ bad-local-outside\.sh ]]
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
    [[ ! "$output" =~ good-local-inside\.sh ]] || {
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
    [[ ! "$output" =~ heredoc-json-brace\.sh ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged local inside function after JSON heredoc
    }
  fi
}

@test "LOCAL_OUTSIDE_FUNCTION: unbalanced { in single-quoted string is not counted" {
  # Regression (string-stripping): echo 'text {' inside a function must not raise
  # the depth counter, which would prevent the subsequent closing } from reaching 0
  # and cause a script-scope 'local' to be missed (false negative).

  cat > "$LINT_FIXTURE_DIR/str-open-brace-single.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
  echo 'Error: unmatched { in string'
  local foo="bar"
  echo "$foo"
}
# Script-scope local must be detected despite the { in the string above
local bad="oops"
my_func
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]
  [[ "$output" =~ str-open-brace-single\.sh ]]
}

@test "LOCAL_OUTSIDE_FUNCTION: unbalanced } in single-quoted string does not produce false positive" {
  # Regression (string-stripping): echo 'text }' inside a function must not decrement
  # depth prematurely, which would cause a 'local' inside the function to look like
  # depth 0 and get flagged as a violation.

  cat > "$LINT_FIXTURE_DIR/str-close-brace-single.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
  echo 'closing brace follows: }'
  local foo="bar"
  echo "$foo"
}
my_func
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  # The local inside my_func is valid — must not be flagged
  if [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]; then
    [[ ! "$output" =~ str-close-brace-single\.sh ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged local inside function after '}' in string
    }
  fi
}

@test "LOCAL_OUTSIDE_FUNCTION: unbalanced { in double-quoted string is not counted" {
  # Regression (string-stripping): echo "text {" inside a function must not raise depth.

  cat > "$LINT_FIXTURE_DIR/str-open-brace-double.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
  echo "Error: unmatched { in string"
  local foo="bar"
  echo "$foo"
}
local bad="oops"
my_func
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]
  [[ "$output" =~ str-open-brace-double\.sh ]]
}

@test "LOCAL_OUTSIDE_FUNCTION: unbalanced } in double-quoted string does not produce false positive" {
  # Regression (string-stripping): echo "text }" inside a function must not decrement depth.

  cat > "$LINT_FIXTURE_DIR/str-close-brace-double.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
  echo "closing brace follows: }"
  local foo="bar"
  echo "$foo"
}
my_func
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  if [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]; then
    [[ ! "$output" =~ str-close-brace-double\.sh ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged local inside function after '}' in string
    }
  fi
}

@test "LOCAL_OUTSIDE_FUNCTION: lowercase heredoc marker braces do not corrupt depth counter" {
  # Regression (#236): the heredoc state machine must recognize lowercase markers
  # (<<eof, <<sql, <<json, etc.) so braces inside such bodies are skipped — not counted.
  #
  # Root cause: the original marker regex /^[A-Z_][A-Z_0-9]*$/ was uppercase-only;
  # <<eof was not recognized as a heredoc open, so { and } in the body corrupted
  # the Rule 7 depth counter, causing subsequent 'local' inside real functions to
  # appear as violations (false positives).
  #
  # Fix: regex broadened to /^[A-Za-z_][A-Za-z_0-9]*$/ — this test ensures the
  # fix is verified and prevents regression.

  cat > "$LINT_FIXTURE_DIR/lowercase-hd-marker.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
  # Lowercase <<eof — body braces must not be counted toward depth
  cat <<eof
{
  "key": "value"
}
eof
  local foo="bar"
  echo "$foo"
}
my_func
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  # The local inside my_func is correct — must not be flagged
  if [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]; then
    [[ ! "$output" =~ lowercase-hd-marker\.sh ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged local inside function after <<eof heredoc (lowercase marker regression)
    }
  fi
}

@test "LOCAL_OUTSIDE_FUNCTION: mixed-case heredoc marker braces do not corrupt depth counter" {
  # Regression (#236): mixed-case markers (<<EndBlock, <<HereDoc) must also be
  # recognized by the state machine — not just all-uppercase.

  cat > "$LINT_FIXTURE_DIR/mixedcase-hd-marker.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
  # Mixed-case marker — body braces must not be counted
  cat <<EndBlock
{
  "nested": {
    "key": "value"
  }
}
EndBlock
  local result="done"
  echo "$result"
}
my_func
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  if [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]; then
    [[ ! "$output" =~ mixedcase-hd-marker\.sh ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged local inside function after <<EndBlock heredoc (mixed-case marker regression)
    }
  fi
}

@test "LOCAL_OUTSIDE_FUNCTION: dash-form lowercase heredoc (<<-eof) does not corrupt depth" {
  # Regression (#236): the dash form <<-eof (which strips leading tabs from the body
  # and allows an indented terminator) must also be recognized. The sub pattern
  # /.*<<-?[[:space:]]*/ handles both <<MARKER and <<-MARKER.

  cat > "$LINT_FIXTURE_DIR/dash-lowercase-hd.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
	# dash form <<-eof — tab-indented terminator, body braces must not be counted
	cat <<-eof
	{
	  "key": "value"
	}
	eof
  local foo="bar"
  echo "$foo"
}
my_func
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  if [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]; then
    [[ ! "$output" =~ dash-lowercase-hd\.sh ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged local inside function after <<-eof heredoc
    }
  fi
}
