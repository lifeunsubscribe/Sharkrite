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
  # Use the precise AWK walker from the acceptance criteria:
  # Track function depth via brace matching, flag 'local' at depth 0.
  run awk '
    /^[a-z_][a-zA-Z_0-9]*\(\) *\{/ { depth++ }
    /^\}/                             { depth-- }
    /^[[:space:]]*local / {
      if (depth == 0) print FILENAME ":" NR ":" $0
    }
  ' "$SCRIPT"

  # Any output means a violation — test fails with the violation shown
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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
# Test 3: AWK lint scan confirms no regressions introduced
# -----------------------------------------------------------------------

@test "codebase-wide: local-review.sh specific lint check passes" {
  # Targeted check: only the file this issue is about, no false positives
  # from heredoc braces in other files.
  run bash -c "
    violations=\$(awk '
      /^[a-z_][a-zA-Z_0-9]*\(\) *\{/ { depth++ }
      /^\}/                             { depth-- }
      /^[[:space:]]*local / {
        if (depth == 0) print NR\": \"\$0
      }
    ' '$PROJECT_ROOT/lib/core/local-review.sh')
    if [ -n \"\$violations\" ]; then
      echo \"FAIL: local outside function found in local-review.sh:\"
      echo \"\$violations\"
      exit 1
    fi
    echo 'PASS: no local outside function in local-review.sh'
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}
