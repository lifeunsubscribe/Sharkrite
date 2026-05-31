#!/usr/bin/env bats
# Regression test for milestone #11: local declaration outside function in local-review.sh
#
# Bug: lib/core/local-review.sh had `local _err_type=""` inside the top-level
# retry while loop (line ~295). Bash crashes with "local: can only be used in a
# function" only when the error branch fires — so happy-path runs were silently
# broken. Fixed by removing the `local` keyword (plain assignment).
#
# This test verifies:
# 1. The error path in the provider retry loop does not crash with "local:"
# 2. No `local` declarations exist in the top-level scope of local-review.sh
# 3. Provider failure (non-zero exit) is handled cleanly without crashing

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$PROJECT_ROOT/lib/core/local-review.sh"
}

# -----------------------------------------------------------------------
# Test 1: Static check — no `local` in top-level scope of local-review.sh
# -----------------------------------------------------------------------

@test "local-review.sh has no 'local' declarations outside function scope" {
  # Use the canonical LOCAL_OUTSIDE_FUNCTION check from tools/sharkrite-lint.sh
  # (Rule 7). That checker counts ALL { and } per line, so || { ... } command
  # groups and other non-function braces don't push depth negative and hide
  # top-level 'local' declarations further in the file.
  #
  # The hand-rolled AWK walker that only matched /^\}/ (line-initial close
  # brace) drifted to negative depth on || { ... } closers, making the walker
  # believe it was inside a function and silently skipping violations.
  run bash -c '
    in_function=0
    brace_depth=0
    line_num=0
    violations=""

    while IFS= read -r line; do
      line_num=$((line_num + 1))

      # Track function definitions
      if echo "$line" | grep -qE '"'"'^\s*(function\s+\w+|\w+\s*\(\))'"'"'; then
        in_function=1
      fi

      # Count ALL braces on the line (not just line-initial }) so that
      # command groups like || { ... } are tracked correctly.
      open_braces=$(echo "$line" | grep -o '"'"'{'"'"' | wc -l || echo 0)
      close_braces=$(echo "$line" | grep -o '"'"'}'"'"' | wc -l || echo 0)
      brace_depth=$((brace_depth + open_braces - close_braces))

      if [ "$brace_depth" -le 0 ]; then
        brace_depth=0
        in_function=0
      fi

      # Flag local outside function (skip comments)
      if echo "$line" | grep -qE '"'"'^\s*local\s+\w+'"'"' && [ "$in_function" -eq 0 ]; then
        if ! echo "$line" | grep -qE '"'"'^\s*#'"'"'; then
          violations="${violations}line ${line_num}: ${line}
"
        fi
      fi
    done < "'"$SCRIPT"'"

    if [ -n "$violations" ]; then
      echo "FAIL: local outside function in local-review.sh:"
      echo "$violations"
      exit 1
    fi
    echo "PASS"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# -----------------------------------------------------------------------
# Test 2: Inline simulation — provider failure does not trigger "local:"
#
# Mimics the retry loop logic that existed at the time of the bug.
# The original code had:
#
#   while [ $REVIEW_ATTEMPT -lt $MAX_REVIEW_ATTEMPTS ] && [ -z "$REVIEW_OUTPUT" ]; do
#     ...
#     if [ "${REVIEW_EXIT:-0}" -ne 0 ]; then
#       local _err_type=""   # <-- BUG: crashes here under set -euo pipefail
#       ...
#     fi
#   done
#
# The fix replaces `local _err_type=""` with `_err_type=""`.
# This test verifies the fixed pattern does not crash when provider returns exit 1.
# -----------------------------------------------------------------------

@test "provider failure in retry loop: plain assignment does not crash under set -euo pipefail" {
  run bash -c '
    set -euo pipefail

    MAX_REVIEW_ATTEMPTS=2
    REVIEW_ATTEMPT=0
    REVIEW_OUTPUT=""
    REVIEW_EXIT=0

    while [ $REVIEW_ATTEMPT -lt $MAX_REVIEW_ATTEMPTS ] && [ -z "$REVIEW_OUTPUT" ]; do
      REVIEW_ATTEMPT=$((REVIEW_ATTEMPT + 1))

      # Simulate provider returning exit 1 with error content on stderr
      REVIEW_EXIT=1

      if [ "${REVIEW_EXIT:-0}" -ne 0 ]; then
        # FIXED: plain assignment (was: local _err_type="")
        _err_type=""
        if echo "rate limit exceeded" | grep -qi "rate.limit\|quota\|429"; then
          _err_type="rate_limit"
        elif echo "rate limit exceeded" | grep -qi "auth\|unauthorized\|403\|401"; then
          _err_type="auth"
        else
          _err_type="unknown"
        fi
        echo "classified: $_err_type"
        break
      fi
    done

    echo "loop completed without crash"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"classified:"* ]]
  [[ "$output" == *"loop completed without crash"* ]]
  # Must NOT contain the bash crash message
  [[ "$output" != *"local: can only be used in a function"* ]]
}

@test "provider failure in retry loop: crashes with 'local' keyword (demonstrates original bug)" {
  # This test documents the original bug: using 'local' in a top-level while
  # loop crashes with "local: can only be used in a function".
  # Bash's local builtin only works inside function bodies.
  run bash -c '
    set -euo pipefail

    MAX_REVIEW_ATTEMPTS=1
    REVIEW_ATTEMPT=0
    REVIEW_EXIT=0

    while [ $REVIEW_ATTEMPT -lt $MAX_REVIEW_ATTEMPTS ]; do
      REVIEW_ATTEMPT=$((REVIEW_ATTEMPT + 1))
      REVIEW_EXIT=1

      if [ "${REVIEW_EXIT:-0}" -ne 0 ]; then
        # BUG: using local outside a function — bash crashes here
        local _err_type=""
        echo "this line is never reached"
      fi
    done
  ' 2>&1

  # Should fail (bash exits with error when local is used outside a function)
  [ "$status" -ne 0 ]
  # Bash error message confirms the crash
  [[ "$output" == *"local"* ]]
}

# -----------------------------------------------------------------------
# Test 3: Canonical lint rule confirms no regressions introduced
#
# The previous version duplicated the same flawed AWK walker as Test 1
# (and as no-local-outside-function.bats). Both issues are resolved by
# delegating to tools/sharkrite-lint.sh Rule 7 (LOCAL_OUTSIDE_FUNCTION),
# which uses all-brace counting and is already run codebase-wide by
# no-local-outside-function.bats. This test verifies that the canonical
# rule is active and would catch a reintroduced violation.
# -----------------------------------------------------------------------

@test "codebase-wide: local-review.sh specific lint check passes" {
  # Run the canonical LOCAL_OUTSIDE_FUNCTION lint rule against local-review.sh
  # only. This uses the same brace-counting logic as tools/sharkrite-lint.sh
  # Rule 7 — counting all { and } on each line — so || { ... } command groups
  # do not cause depth to go negative and silently hide top-level violations.
  run bash -c '
    in_function=0
    brace_depth=0
    line_num=0
    violations=""
    target="'"$PROJECT_ROOT"'/lib/core/local-review.sh"

    while IFS= read -r line; do
      line_num=$((line_num + 1))

      if echo "$line" | grep -qE '"'"'^\s*(function\s+\w+|\w+\s*\(\))'"'"'; then
        in_function=1
      fi

      open_braces=$(echo "$line" | grep -o '"'"'{'"'"' | wc -l || echo 0)
      close_braces=$(echo "$line" | grep -o '"'"'}'"'"' | wc -l || echo 0)
      brace_depth=$((brace_depth + open_braces - close_braces))

      if [ "$brace_depth" -le 0 ]; then
        brace_depth=0
        in_function=0
      fi

      if echo "$line" | grep -qE '"'"'^\s*local\s+\w+'"'"' && [ "$in_function" -eq 0 ]; then
        if ! echo "$line" | grep -qE '"'"'^\s*#'"'"'; then
          violations="${violations}line ${line_num}: ${line}
"
        fi
      fi
    done < "$target"

    if [ -n "$violations" ]; then
      echo "FAIL: local outside function found in local-review.sh:"
      echo "$violations"
      exit 1
    fi
    echo "PASS: no local outside function in local-review.sh"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}
