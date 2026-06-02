#!/usr/bin/env bats
# Tests for Sharkrite custom lint rules

setup() {
  # Create temp directory for test files outside the project (linter won't scan it)
  TEST_DIR=$(mktemp -d)
  LINT_SCRIPT="$BATS_TEST_DIRNAME/../../tools/sharkrite-lint.sh"

  # Project root (tests/lint/ is two levels below project root)
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  # Temp dir inside lib/ for lint fixture files (linter only scans lib/, bin/, tools/)
  LINT_FIXTURE_DIR="$PROJECT_ROOT/lib/test-fixtures-temp"
  mkdir -p "$LINT_FIXTURE_DIR"
}

teardown() {
  # Clean up temp files
  rm -rf "$TEST_DIR"
  rm -rf "$LINT_FIXTURE_DIR"
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
