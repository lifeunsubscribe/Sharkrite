#!/usr/bin/env bats
# Tests for Sharkrite custom lint rules

setup() {
  # Create temp directory for test files
  TEST_DIR=$(mktemp -d)
  LINT_SCRIPT="$BATS_TEST_DIRNAME/../../tools/sharkrite-lint.sh"
}

teardown() {
  # Clean up temp files
  rm -rf "$TEST_DIR"
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

@test "detects unguarded gh output capture (no fallback)" {
  create_test_script "bad-gh.sh" 'PR_HEAD=$(gh pr view "$PR_NUMBER" --json headRefOid --jq ".headRefOid")'

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "GH_UNGUARDED_CALL" ]]
}

@test "detects unguarded gh capture with 2>/dev/null but no || fallback" {
  create_test_script "bad-gh-redirect.sh" 'ALL_REVIEWS=$(gh pr view "$PR_NUMBER" --json comments --jq "." 2>/dev/null)'

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "GH_UNGUARDED_CALL" ]]
}

@test "accepts gh capture with || echo fallback" {
  create_test_script "good-gh-echo.sh" 'PR_BRANCH=$(gh pr view "$PR_NUMBER" --json headRefName --jq ".headRefName" 2>/dev/null || echo "")'

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "GH_UNGUARDED_CALL" ]]
}

@test "accepts gh capture with || true fallback" {
  create_test_script "good-gh-true.sh" 'REVIEW_JSON=$(gh pr view "$PR_NUMBER" --json comments --jq "." 2>/dev/null || true)'

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "GH_UNGUARDED_CALL" ]]
}

@test "accepts gh capture used in if conditional (caller owns exit code)" {
  create_test_script "good-gh-if.sh" 'if PR_INFO=$(gh pr view "$PR_NUMBER" --json title 2>&1); then
  echo "$PR_INFO"
fi'

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "GH_UNGUARDED_CALL" ]]
}

@test "accepts gh capture with 2>&1 error handler pattern" {
  create_test_script "good-gh-handler.sh" 'REVIEW_JSON=$(gh pr view "$PR_NUMBER" --json comments --jq "." 2>"$GH_STDERR") || {
  cat "$GH_STDERR"
  exit 1
}'

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "GH_UNGUARDED_CALL" ]]
}

@test "detects unguarded gh label list capture" {
  # gh label is now in the network-verb list (coverage gap from PR #135 assessment)
  create_test_script "bad-gh-label.sh" 'existing=$(gh label list --limit 200 --json name --jq ".[].name" 2>/dev/null)'

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "GH_UNGUARDED_CALL" ]]
}

@test "accepts gh label list capture with || echo fallback" {
  create_test_script "good-gh-label.sh" 'existing=$(gh label list --limit 200 --json name --jq ".[].name" 2>/dev/null || echo "")'

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "GH_UNGUARDED_CALL" ]]
}
