#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh
# Tests for Sharkrite custom lint rules

setup() {
  # Create temp directory for test files outside the project (linter won't scan it)
  TEST_DIR=$(mktemp -d)
  LINT_SCRIPT="$BATS_TEST_DIRNAME/../../tools/sharkrite-lint.sh"

  # Project root (tests/lint/ is two levels below project root)
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  # Fixture dir for production-linter tests (Rule 7 heredoc/string-stripping tests).
  # Use BATS_TEST_TMPDIR so fixtures are outside the project tree and don't hit the
  # test-fixtures-temp exclusion. Inject via RITE_LINT_EXTRA_DIRS so the linter scans them.
  LINT_FIXTURE_DIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}/custom-rule-fixtures"
  mkdir -p "$LINT_FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$LINT_FIXTURE_DIR"
}

teardown() {
  # Clean up temp files
  rm -rf "$TEST_DIR"
  rm -rf "$LINT_FIXTURE_DIR"
  unset RITE_LINT_EXTRA_DIRS
}

# Helper to create a test script
create_test_script() {
  local filename=$1
  local content=$2

  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/lib"
  echo "#!/usr/bin/env bash" > "$TEST_DIR/bin/$filename"
  echo "$content" >> "$TEST_DIR/bin/$filename"
}

@test "detects grep -c with || echo '0'" {
  create_test_script "bad-grep.sh" 'COUNT=$(grep -c "pattern" file.txt || echo "0")'

  # Should fail (lint script exits non-zero and output contains error)
  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "GREP_C_ECHO_ZERO" ]]
}

@test "accepts grep -c with || true" {
  create_test_script "good-grep.sh" 'COUNT=$(grep -c "pattern" file.txt || true)'

  # Should pass (no GREP_C_ECHO_ZERO error)
  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "GREP_C_ECHO_ZERO" ]]
}

@test "detects git push without refspec" {
  create_test_script "bad-push.sh" 'git push'

  # Should fail (lint script exits non-zero and output contains error)
  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "GIT_PUSH_NO_REFSPEC" ]]
}

@test "accepts git push with origin and branch" {
  create_test_script "good-push.sh" 'git push origin main'

  # Should pass
  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "GIT_PUSH_NO_REFSPEC" ]]
}

@test "warns on eval with GitHub data" {
  create_test_script "eval-github.sh" 'eval "$GH_API_RESPONSE"'

  # Should warn (not fail, just warn)
  cd "$TEST_DIR/.." && "$LINT_SCRIPT" 2>&1 | grep -q "EVAL_UNTRUSTED_DATA"
}

@test "detects unquoted heredoc in command substitution" {
  create_test_script "bad-heredoc.sh" 'OUTPUT=$(cat <<EOF
some content
EOF
)'

  # Should fail (lint script exits non-zero and output contains error)
  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "UNQUOTED_HEREDOC_CMDSUB" ]]
}

@test "accepts quoted heredoc in command substitution" {
  create_test_script "good-heredoc.sh" "OUTPUT=\$(cat <<'EOF'
some content
EOF
)"

  # Should pass
  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "UNQUOTED_HEREDOC_CMDSUB" ]]
}

@test "detects BSD sed without GNU fallback" {
  create_test_script "bad-sed.sh" "sed -i '' 's/foo/bar/' file.txt"

  # Should fail (lint script exits non-zero and output contains error)
  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "BSD_SED_NO_FALLBACK" ]]
}

@test "accepts BSD sed with GNU fallback check" {
  create_test_script "good-sed.sh" 'if sed --version >/dev/null 2>&1; then
  sed -i "s/foo/bar/" file.txt
else
  sed -i "" "s/foo/bar/" file.txt
fi'

  # Should pass
  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "BSD_SED_NO_FALLBACK" ]]
}

@test "detects PIPESTATUS after || true" {
  create_test_script "bad-pipestatus.sh" 'cmd1 | cmd2 || true
EXIT_CODE=${PIPESTATUS[0]}'

  # Should fail (lint script exits non-zero and output contains error)
  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "PIPESTATUS_AFTER_OR_TRUE" ]]
}

@test "accepts PIPESTATUS with fallback" {
  create_test_script "good-pipestatus.sh" 'cmd1 | cmd2 || _exit=${PIPESTATUS[0]:-$?}'

  # Should pass (the pattern checks for the fallback)
  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "PIPESTATUS_AFTER_OR_TRUE" ]]
}

@test "detects local outside function" {
  create_test_script "bad-local.sh" 'local foo="bar"
echo "$foo"'

  # Should fail (lint script exits non-zero and output contains error)
  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]
}

@test "accepts local inside function" {
  create_test_script "good-local.sh" 'my_function() {
  local foo="bar"
  echo "$foo"
}'

  # Should pass
  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]
}

@test "accepts local inside function keyword style (function name() {})" {
  # Edge case: 'function name() {' syntax was not matched by the original regex
  create_test_script "good-local-fnkw-parens.sh" 'function my_function() {
  local foo="bar"
  echo "$foo"
}'

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]
}

@test "accepts local inside function keyword style without parens (function name {})" {
  # Edge case: 'function name {' syntax (no parens)
  create_test_script "good-local-fnkw-noparens.sh" 'function my_function {
  local foo="bar"
  echo "$foo"
}'

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]
}

@test "accepts local inside function with hyphenated name" {
  # Edge case: function names with hyphens (bash allows these, \w+ misses them)
  create_test_script "good-local-hyphen.sh" 'my-function() {
  local foo="bar"
  echo "$foo"
}'

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]
}

@test "LOCAL_OUTSIDE_FUNCTION: brace-tracking handles JSON heredoc with unbalanced braces" {
  # Regression: a heredoc containing JSON (with unbalanced { or }) must not
  # corrupt the brace depth counter and cause subsequent 'local' inside real
  # functions to appear as violations.
  #
  # Exercises the production Rule 7 AWK in tools/sharkrite-lint.sh directly
  # (via a fixture file) rather than a parallel inline AWK re-implementation.

  cat > "$LINT_FIXTURE_DIR/heredoc-json-brace-custom.sh" <<'EOF'
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
    [[ ! "$output" =~ heredoc-json-brace-custom\.sh ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged local inside function after JSON heredoc
    }
  fi
}

@test "LOCAL_OUTSIDE_FUNCTION: brace in single-quoted string does not skew depth" {
  # Regression: a { inside a single-quoted string must not bump the depth counter.
  # Without string-stripping, echo 'opening {' inside a function raises depth to 2
  # so the function body's closing } only brings it to 1, and any subsequent
  # 'local' at script scope looks like depth 1 (inside a function) — a false negative.

  cat > "$LINT_FIXTURE_DIR/single-quote-brace.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
  echo 'Error: missing closing brace {'
  local foo="bar"
  echo "$foo"
}
# local at script scope — must be flagged
local bad="oops"
my_func
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  # Must detect the script-scope local
  [ "$status" -eq 1 ]
  [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]
  [[ "$output" =~ single-quote-brace\.sh ]]
}

@test "LOCAL_OUTSIDE_FUNCTION: brace in double-quoted string does not skew depth" {
  # Regression: a { inside a double-quoted string must not bump the depth counter.

  cat > "$LINT_FIXTURE_DIR/double-quote-brace.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
  echo "Error: missing closing brace {"
  local foo="bar"
  echo "$foo"
}
# local at script scope — must be flagged
local bad="oops"
my_func
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]
  [[ "$output" =~ double-quote-brace\.sh ]]
}

@test "LOCAL_OUTSIDE_FUNCTION: closing brace in single-quoted string does not produce false positive" {
  # Regression: a } inside a single-quoted string must not decrement depth.
  # Without string-stripping, echo '}' inside a function brings depth to 0
  # prematurely; a subsequent 'local' inside the same function looks like a violation.

  cat > "$LINT_FIXTURE_DIR/single-quote-close-brace.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
  echo 'closing brace: }'
  local foo="bar"
  echo "$foo"
}
my_func
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  # The local inside my_func is correct — must not be flagged
  if [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]; then
    [[ ! "$output" =~ single-quote-close-brace\.sh ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged local inside function after '}' in string
    }
  fi
}

@test "LOCAL_OUTSIDE_FUNCTION: dollar-brace param expansion does not skew depth" {
  # \${VAR} expansions always have balanced braces but should not add depth noise
  # for more complex forms like \${FOO:-{default}} where the default itself has braces.

  cat > "$LINT_FIXTURE_DIR/dollar-brace-param.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
  local val="${MY_VAR:-default}"
  echo "$val"
}
my_func
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  # No violations expected
  if [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]; then
    [[ ! "$output" =~ dollar-brace-param\.sh ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged local using \${...} expansion
    }
  fi
}

@test "LOCAL_OUTSIDE_FUNCTION: lowercase heredoc marker does not corrupt depth counter" {
  # Regression: a heredoc opened with a lowercase marker (<<eof, <<sql, <<json, etc.)
  # must be recognized by the state machine so braces inside its body are not counted.
  # Without lowercase support, the marker would not match /^[A-Za-z_][A-Za-z_0-9]*$/
  # and the state machine would stay open; every { and } in the heredoc body would
  # corrupt the depth counter, producing false positives on subsequent 'local' inside
  # real functions.

  cat > "$LINT_FIXTURE_DIR/lowercase-marker-heredoc.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
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
    [[ ! "$output" =~ lowercase-marker-heredoc\.sh ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged local inside function after lowercase heredoc
    }
  fi
}

@test "LOCAL_OUTSIDE_FUNCTION: mixed-case heredoc marker does not corrupt depth counter" {
  # Regression: a heredoc opened with a mixed-case marker (<<EndBlock, <<HereDoc, etc.)
  # must be recognized so braces inside its body do not corrupt the depth counter.

  cat > "$LINT_FIXTURE_DIR/mixedcase-marker-heredoc.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
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

  # The local inside my_func is correct — must not be flagged
  if [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]; then
    [[ ! "$output" =~ mixedcase-marker-heredoc\.sh ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged local inside function after mixed-case heredoc
    }
  fi
}

@test "LOCAL_OUTSIDE_FUNCTION: dash-form lowercase heredoc (<<-eof) does not corrupt depth" {
  # Regression: <<-eof (dash form with lowercase marker) strips the leading dash
  # before marker matching, so the state machine must still enter heredoc mode.
  # Braces inside tab-indented heredoc body must not be counted.

  cat > "$LINT_FIXTURE_DIR/dash-lowercase-heredoc.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
my_func() {
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

  # The local inside my_func is correct — must not be flagged
  if [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]]; then
    [[ ! "$output" =~ dash-lowercase-heredoc\.sh ]] || {
      false  # LOCAL_OUTSIDE_FUNCTION falsely flagged local inside function after <<-eof heredoc
    }
  fi
}

@test "GH_UNSAFE_CALL: lowercase heredoc body lines are not scanned for gh calls" {
  # Regression: if the state machine doesn't recognize a lowercase heredoc marker,
  # gh commands in the heredoc body (e.g., prompt text or documentation) get
  # falsely flagged as GH_UNSAFE_CALL violations.

  cat > "$LINT_FIXTURE_DIR/lowercase-marker-gh-call.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
generate_prompt() {
  cat <<prompt
Run this to check status:
  gh pr list
  gh issue view 42
prompt
}
generate_prompt
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  # gh calls inside lowercase heredoc body must not be flagged
  if [[ "$output" =~ "GH_UNSAFE_CALL" ]]; then
    [[ ! "$output" =~ lowercase-marker-gh-call\.sh ]] || {
      false  # GH_UNSAFE_CALL falsely flagged gh in lowercase heredoc body
    }
  fi
}

@test "UNSAFE_PIPE_IN_CMDSUB: lowercase heredoc body lines are not scanned for unsafe pipes" {
  # Regression: if the state machine doesn't recognize a lowercase heredoc marker,
  # pipe expressions in the heredoc body (e.g., example commands in prompt text)
  # get falsely flagged as UNSAFE_PIPE_IN_CMDSUB violations.

  cat > "$LINT_FIXTURE_DIR/lowercase-marker-pipe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
show_example() {
  cat <<example
Here is how to check:
  COUNT=$(git log | grep "pattern")
example
}
show_example
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  # pipe expressions inside lowercase heredoc body must not be flagged
  if [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]; then
    [[ ! "$output" =~ lowercase-marker-pipe\.sh ]] || {
      false  # UNSAFE_PIPE_IN_CMDSUB falsely flagged pipe expression in lowercase heredoc body
    }
  fi
}
