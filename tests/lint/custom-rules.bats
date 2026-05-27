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

  # Should fail
  cd "$TEST_DIR/.." && ! "$LINT_SCRIPT" 2>&1 | grep -q "GREP_C_ECHO_ZERO"
}

@test "accepts grep -c with || true" {
  create_test_script "good-grep.sh" 'COUNT=$(grep -c "pattern" file.txt || true)'

  # Should pass (no GREP_C_ECHO_ZERO error)
  cd "$TEST_DIR/.." && "$LINT_SCRIPT" 2>&1 | grep -qv "GREP_C_ECHO_ZERO" || true
}

@test "detects git push without refspec" {
  create_test_script "bad-push.sh" 'git push'

  # Should fail
  cd "$TEST_DIR/.." && ! "$LINT_SCRIPT" 2>&1 | grep -q "GIT_PUSH_NO_REFSPEC"
}

@test "accepts git push with origin and branch" {
  create_test_script "good-push.sh" 'git push origin main'

  # Should pass
  cd "$TEST_DIR/.." && "$LINT_SCRIPT" 2>&1 | grep -qv "GIT_PUSH_NO_REFSPEC" || true
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

  # Should fail
  cd "$TEST_DIR/.." && ! "$LINT_SCRIPT" 2>&1 | grep -q "UNQUOTED_HEREDOC_CMDSUB"
}

@test "accepts quoted heredoc in command substitution" {
  create_test_script "good-heredoc.sh" "OUTPUT=\$(cat <<'EOF'
some content
EOF
)"

  # Should pass
  cd "$TEST_DIR/.." && "$LINT_SCRIPT" 2>&1 | grep -qv "UNQUOTED_HEREDOC_CMDSUB" || true
}

@test "detects BSD sed without GNU fallback" {
  create_test_script "bad-sed.sh" "sed -i '' 's/foo/bar/' file.txt"

  # Should fail
  cd "$TEST_DIR/.." && ! "$LINT_SCRIPT" 2>&1 | grep -q "BSD_SED_NO_FALLBACK"
}

@test "accepts BSD sed with GNU fallback check" {
  create_test_script "good-sed.sh" 'if sed --version >/dev/null 2>&1; then
  sed -i "s/foo/bar/" file.txt
else
  sed -i "" "s/foo/bar/" file.txt
fi'

  # Should pass
  cd "$TEST_DIR/.." && "$LINT_SCRIPT" 2>&1 | grep -qv "BSD_SED_NO_FALLBACK" || true
}

@test "detects PIPESTATUS after || true" {
  create_test_script "bad-pipestatus.sh" 'cmd1 | cmd2 || true
EXIT_CODE=${PIPESTATUS[0]}'

  # Should fail
  cd "$TEST_DIR/.." && ! "$LINT_SCRIPT" 2>&1 | grep -q "PIPESTATUS_AFTER_OR_TRUE"
}

@test "accepts PIPESTATUS with fallback" {
  create_test_script "good-pipestatus.sh" 'cmd1 | cmd2 || _exit=${PIPESTATUS[0]:-$?}'

  # Should pass (the pattern checks for the fallback)
  cd "$TEST_DIR/.." && "$LINT_SCRIPT" 2>&1 | grep -qv "PIPESTATUS_AFTER_OR_TRUE" || true
}

@test "detects local outside function" {
  create_test_script "bad-local.sh" 'local foo="bar"
echo "$foo"'

  # Should fail
  cd "$TEST_DIR/.." && ! "$LINT_SCRIPT" 2>&1 | grep -q "LOCAL_OUTSIDE_FUNCTION"
}

@test "accepts local inside function" {
  create_test_script "good-local.sh" 'my_function() {
  local foo="bar"
  echo "$foo"
}'

  # Should pass
  cd "$TEST_DIR/.." && "$LINT_SCRIPT" 2>&1 | grep -qv "LOCAL_OUTSIDE_FUNCTION" || true
}
