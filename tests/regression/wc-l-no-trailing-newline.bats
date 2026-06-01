#!/usr/bin/env bats
# tests/regression/wc-l-no-trailing-newline.bats
#
# Regression tests for issue #119: Strip newline fixes — wc -l undercount edge case
#
# wc -l counts newline characters, not lines. A diff (or any content) whose last
# line has no trailing newline returns wc -l == 0 even when real content exists.
# This caused false "No code to review" rejections in bin/rite when the PR diff
# happened to be a single line with no trailing newline.
#
# Verifies:
# 1. bin/rite diff gate uses wc -c (byte count) so single-line no-newline diffs
#    are not falsely rejected.
# 2. local-review.sh uses printf '%s\n' wrapping so DIFF_LINES is accurate for
#    diffs ending without a trailing newline.
# 3. assess-documentation.sh uses printf '%s\n' wrapping for all truncation-safety
#    checks, so single-line LLM output is not incorrectly treated as "no output".
# 4. The underlying shell behavior is demonstrated (wc -l vs wc -c).

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Test 1: Demonstrate the root-cause shell behavior
# ---------------------------------------------------------------------------

@test "wc -l returns 0 for single-line string with no trailing newline" {
  # This demonstrates the exact bug: printf without \n causes wc -l to return 0
  result=$(printf 'no trailing newline' | wc -l | tr -d ' ')
  [ "$result" -eq 0 ]
}

@test "wc -c returns non-zero for single-line string with no trailing newline" {
  # wc -c counts bytes, so it correctly detects content regardless of newlines
  result=$(printf 'no trailing newline' | wc -c | tr -d ' ')
  [ "$result" -gt 0 ]
}

@test "printf '%s\n' wrapping makes wc -l return 1 for single-line no-newline content" {
  # The fix used in local-review.sh and assess-documentation.sh
  content="single line no newline"
  result=$(printf '%s\n' "$content" | wc -l | tr -d ' ')
  [ "$result" -eq 1 ]
}

@test "printf '%s\n' wrapping does not double-count trailing newline content" {
  # Multi-line content with its own trailing newline should not get an extra line.
  # NOTE: $() strips trailing newlines from command substitution, so 'content'
  # holds "line one\nline two" (no trailing newline) regardless of printf's \n.
  # printf '%s\n' then adds exactly one \n → "line one\nline two\n" = 2 newlines.
  # wc -l must return exactly 2, not 3 (double-count would be a regression).
  content="$(printf 'line one\nline two\n')"
  result=$(printf '%s\n' "$content" | wc -l | tr -d ' ')
  [ "$result" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Test 2: bin/rite uses wc -c (byte count) for the diff gate
# ---------------------------------------------------------------------------

@test "bin/rite: diff gate uses wc -c not wc -l" {
  RITE_BIN="${RITE_REPO_ROOT}/bin/rite"

  # The gate must use wc -c (byte count) to avoid the no-trailing-newline edge case
  WC_C_COUNT=$(grep -c "DIFF_BYTES.*wc -c" "$RITE_BIN" || true)
  [ "$WC_C_COUNT" -ge 1 ]
}

@test "bin/rite: diff gate does NOT use wc -l for the no-code-to-review check" {
  RITE_BIN="${RITE_REPO_ROOT}/bin/rite"

  # Verify there's no longer a wc -l feeding into DIFF_LINES for the gate;
  # the gate variable should now be DIFF_BYTES
  # (Other uses of wc -l in rite for unrelated purposes are fine)
  WC_L_GATE_COUNT=$(grep -c "DIFF_LINES.*wc -l" "$RITE_BIN" || true)
  [ "$WC_L_GATE_COUNT" -eq 0 ]
}

@test "bin/rite: wc -c gate accepts single-line no-newline diff" {
  # Simulate the gate logic directly: a single-line diff with no trailing newline
  # must produce DIFF_BYTES > 0
  single_line_diff="diff --git a/foo.sh b/foo.sh"  # no trailing newline

  # Write a temp script that exercises the fixed gate logic
  gate_script="$RITE_TEST_TMPDIR/gate_test.sh"
  diff_file="$RITE_TEST_TMPDIR/diff_content.txt"

  # Store without trailing newline (printf, not echo)
  printf '%s' "$single_line_diff" > "$diff_file"

  cat > "$gate_script" <<'GATE_EOF'
#!/usr/bin/env bash
set -euo pipefail
DIFF_BYTES=$(cat "$1" | wc -c | tr -d ' ')
if [ "${DIFF_BYTES:-0}" -eq 0 ]; then
  echo "REJECTED"
  exit 1
fi
echo "ACCEPTED"
exit 0
GATE_EOF
  chmod +x "$gate_script"

  run "$gate_script" "$diff_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACCEPTED"* ]]
}

@test "bin/rite: wc -c gate correctly rejects truly empty diff" {
  # An actually empty diff (zero bytes) must still be rejected
  empty_diff=""

  gate_script="$RITE_TEST_TMPDIR/gate_test_empty.sh"
  diff_file="$RITE_TEST_TMPDIR/diff_empty.txt"

  # Empty file (zero bytes)
  printf '' > "$diff_file"

  cat > "$gate_script" <<'GATE_EOF'
#!/usr/bin/env bash
set -euo pipefail
DIFF_BYTES=$(cat "$1" | wc -c | tr -d ' ')
if [ "${DIFF_BYTES:-0}" -eq 0 ]; then
  echo "REJECTED"
  exit 1
fi
echo "ACCEPTED"
exit 0
GATE_EOF
  chmod +x "$gate_script"

  run "$gate_script" "$diff_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REJECTED"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: local-review.sh uses printf '%s\n' wrapping for DIFF_LINES
# ---------------------------------------------------------------------------

@test "local-review.sh: DIFF_LINES assignment uses printf '%s\n' wrapping" {
  SCRIPT_PATH="${RITE_REPO_ROOT}/lib/core/local-review.sh"

  # Must use printf '%s\n' ... | wc -l for DIFF_LINES
  PRINTF_COUNT=$(grep -c "printf '%s\\\\n' \"\\\$PR_DIFF\" | wc -l" "$SCRIPT_PATH" || true)
  [ "$PRINTF_COUNT" -ge 1 ]
}

@test "local-review.sh: single-line no-newline diff produces DIFF_LINES >= 1" {
  # Simulate the fixed DIFF_LINES calculation with a no-trailing-newline diff
  PR_DIFF="diff --git a/foo.sh b/foo.sh"  # one line, no trailing newline

  DIFF_LINES=$(printf '%s\n' "$PR_DIFF" | wc -l | tr -d ' ')
  [ "$DIFF_LINES" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 4: assess-documentation.sh uses printf '%s\n' wrapping
# ---------------------------------------------------------------------------

@test "assess-documentation.sh: all wc -l calls use printf '%s\n' wrapping" {
  SCRIPT_PATH="${RITE_REPO_ROOT}/lib/core/assess-documentation.sh"

  # Count bare echo ... | wc -l patterns (should be zero after the fix)
  BARE_ECHO_WC=$(grep -cE 'echo "\$[A-Za-z_]+" \| wc -l' "$SCRIPT_PATH" || true)
  [ "$BARE_ECHO_WC" -eq 0 ]
}

@test "assess-documentation.sh: truncation check with single-line no-newline output passes" {
  # Simulate the truncation-safety check: single-line no-newline output must NOT
  # be counted as 0 lines (which would trigger a false truncation rejection)
  single_line_output="This is a one-line architecture note"

  output_lines=$(printf '%s\n' "$single_line_output" | wc -l | tr -d ' ')
  [ "$output_lines" -ge 1 ]
}

@test "assess-documentation.sh: output_lines -gt 1 guard accepts two-line output" {
  # Verify the guard threshold logic works correctly after the fix
  two_line_output="$(printf 'line one\nline two')"  # no trailing newline

  output_lines=$(printf '%s\n' "$two_line_output" | wc -l | tr -d ' ')
  [ "$output_lines" -gt 1 ]
}

# ---------------------------------------------------------------------------
# Test 5: Static checks — the fix is present in the source files
# ---------------------------------------------------------------------------

@test "bin/rite: contains DIFF_BYTES variable name (wc -c fix)" {
  RITE_BIN="${RITE_REPO_ROOT}/bin/rite"
  COUNT=$(grep -c "DIFF_BYTES" "$RITE_BIN" || true)
  [ "$COUNT" -ge 1 ]
}

@test "bin/rite: No-code-to-review error message still present" {
  RITE_BIN="${RITE_REPO_ROOT}/bin/rite"
  COUNT=$(grep -c "No code to review" "$RITE_BIN" || true)
  [ "$COUNT" -ge 1 ]
}

@test "local-review.sh: contains printf wc -l pattern for DIFF_LINES" {
  SCRIPT_PATH="${RITE_REPO_ROOT}/lib/core/local-review.sh"
  COUNT=$(grep -c "printf '%s\\\\n'" "$SCRIPT_PATH" || true)
  [ "$COUNT" -ge 1 ]
}

@test "assess-documentation.sh: contains printf wc -l pattern for line counting" {
  SCRIPT_PATH="${RITE_REPO_ROOT}/lib/core/assess-documentation.sh"
  COUNT=$(grep -c "printf '%s\\\\n'" "$SCRIPT_PATH" || true)
  [ "$COUNT" -ge 1 ]
}
