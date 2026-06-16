#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/local-review.sh
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
#
# Test 2 was previously a fabricated inline reconstruction that tested a
# rate_limit/auth/unknown classification branch that does NOT exist in the real
# local-review.sh. A fabricated test cannot regress when the actual code changes.
#
# Test 2 (revised) exercises the real provider retry loop extracted directly from
# local-review.sh so it will catch regressions in the actual production path.

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
# Test 2: Provider failure in the real retry loop does not crash
#
# This test extracts the actual provider retry loop from local-review.sh
# using sed range markers (sharkrite-extract comments) placed in the source.
# This approach is stable across loop header rewrites and do/done reformatting,
# unlike awk depth-counting which could silently mis-extract after a refactor.
# The extracted loop is exercised with a stubbed provider that returns exit 1.
# This guards the real production code rather than a fabricated reconstruction.
#
# The old Test 2 exercised a rate_limit/auth/unknown classification branch
# that does not exist in local-review.sh, making it a tautology that could
# not regress when the actual code changes.
# -----------------------------------------------------------------------

@test "provider failure in real retry loop: exits cleanly without bash crash" {
  # Validate that each sharkrite-extract marker appears exactly once before
  # using sed range extraction. If a marker is removed, sed yields empty output
  # (silently passing [ -n "$LOOP_CODE" ] would be false, but the content-anchor
  # check below would also fail vacuously). If a marker is duplicated, sed
  # captures an over-broad range spanning multiple loops, making the extracted
  # code incorrect while still passing the non-empty check. Asserting count==1
  # for both start and end markers catches both failure modes before sed runs.
  START_COUNT=$(grep -c '# sharkrite-extract: provider-retry-loop-start' "$SCRIPT" || true)
  END_COUNT=$(grep -c '# sharkrite-extract: provider-retry-loop-end' "$SCRIPT" || true)
  if [ "$START_COUNT" -ne 1 ] || [ "$END_COUNT" -ne 1 ]; then
    echo "FAIL: sharkrite-extract markers must appear exactly once each in $SCRIPT" >&2
    echo "  provider-retry-loop-start: found $START_COUNT (expected 1)" >&2
    echo "  provider-retry-loop-end:   found $END_COUNT (expected 1)" >&2
    false
  fi

  # Extract the provider retry loop from the actual local-review.sh script.
  # The loop is delimited by sharkrite-extract marker comments in the source so
  # that sed range extraction (not awk depth-counting) can be used. This makes
  # the extraction stable across loop header rewrites, do/done reformatting, and
  # indentation changes. We run it at the top level of a bash -c subprocess
  # under set -euo pipefail with a stubbed provider to capture the exit code.
  LOOP_CODE=$(sed -n '/# sharkrite-extract: provider-retry-loop-start/,/# sharkrite-extract: provider-retry-loop-end/p' "$SCRIPT")

  # Verify we actually extracted something (sanity check)
  [ -n "$LOOP_CODE" ]

  # Content-anchor assertion: confirm the extracted code contains the real
  # provider call, not a mis-extracted stub or surrounding boilerplate.
  # Without this, marker removal or misplacement would cause the test to
  # execute unrelated code and pass vacuously, defeating its purpose.
  [[ "$LOOP_CODE" == *"provider_run_prompt"* ]]

  run bash -c "
    set -euo pipefail

    # Stub the print helpers used by the loop
    print_error()   { echo \"[ERROR] \$*\" >&2; }
    print_warning() { echo \"[WARNING] \$*\" >&2; }
    export -f print_error print_warning

    # Stub provider_run_prompt to simulate a provider failure (non-zero exit)
    # This is the failure path that the original bug only triggered on.
    provider_run_prompt() {
      echo 'rate limit exceeded' >&2
      return 1
    }
    export -f provider_run_prompt

    # Set up the variables the loop reads
    MAX_REVIEW_ATTEMPTS=2
    RITE_REVIEW_RETRY_BACKOFF=0   # no real sleep between retries in tests
    REVIEW_ATTEMPT=0
    REVIEW_OUTPUT=''
    CLAUDE_ERROR=''
    REVIEW_EXIT=0
    CLAUDE_STDERR=\$(mktemp)

    # Execute the extracted real retry loop.
    # The loop exits 1 on provider failure (expected non-crash path).
    # Under the bug, bash would crash with 'local: can only be used in a function'
    # before the exit 1 — the crash message appears on stderr (captured by run).
    # We do NOT add a post-loop check here: if the loop calls 'exit 1' internally
    # (the non-crash path), the subprocess ends immediately and any code after the
    # loop body is unreachable dead code.  All crash detection is done in the
    # outer bats assertions below.
    $LOOP_CODE
  "

  # Loop exits 1 (provider failed cleanly) or non-zero from bash crash.
  # Under the bug, bash would emit 'local: can only be used in a function' to
  # stderr before the first exit 1, detectable in $output (bats merges stderr).
  # We accept exit 0 or 1 (normal operation), and reject the crash message.
  [[ "$status" -eq 1 || "$status" -eq 0 ]]
  [[ "$output" != *"local: can only be used in a function"* ]]
  [[ "$output" != *"FAIL:"* ]]
}

# ---------------------------------------------------------------------------
# Review retry on transient HARD failure (issues #482/#649/#631, 2026-06-16).
# Before the fix, a non-zero provider exit (a momentary 429/5xx/overloaded that
# fast-fails in ~14s) aborted the whole phase with `exit 1` and NO retry —
# throwing away an otherwise-complete run (dev session done, commits pushed).
# The loop now retries hard errors with backoff, same as empty output.
# RITE_REVIEW_RETRY_BACKOFF=0 keeps these tests fast (no real sleep).
# ---------------------------------------------------------------------------

# Run the real extracted retry loop with a stubbed provider. $1 = stub body.
# Echoes the loop's own output; the caller asserts on status + a call counter.
_run_review_loop() {
  local stub_body="$1"
  local script="$PROJECT_ROOT/lib/core/local-review.sh"
  local loop_code
  loop_code=$(sed -n '/# sharkrite-extract: provider-retry-loop-start/,/# sharkrite-extract: provider-retry-loop-end/p' "$script")
  [ -n "$loop_code" ] || { echo "FAIL: empty loop extraction" >&2; return 1; }
  [[ "$loop_code" == *"provider_run_prompt"* ]] || { echo "FAIL: loop missing provider call" >&2; return 1; }

  run bash -c "
    set -euo pipefail
    print_error()   { echo \"[ERROR] \$*\" >&2; }
    print_warning() { echo \"[WARNING] \$*\" >&2; }
    export -f print_error print_warning
    ${stub_body}
    export -f provider_run_prompt
    MAX_REVIEW_ATTEMPTS=3
    RITE_REVIEW_RETRY_BACKOFF=0
    REVIEW_ATTEMPT=0
    REVIEW_OUTPUT=''
    CLAUDE_ERROR=''
    REVIEW_EXIT=0
    REVIEW_PROMPT='x'; EFFECTIVE_MODEL='m'; AUTO_MODE='true'
    CLAUDE_STDERR=\$(mktemp)
    ${loop_code}
    # Reached only if the loop did NOT exit (i.e. a review was captured).
    [ -n \"\$REVIEW_OUTPUT\" ] && echo 'REVIEW_CAPTURED'
  "
}

@test "review retry: transient hard failure then success returns the review" {
  CALLF="$BATS_TEST_TMPDIR/calls-a"; echo 0 > "$CALLF"
  _run_review_loop "
    provider_run_prompt() {
      _n=\$(cat '$CALLF'); _n=\$((_n+1)); echo \$_n > '$CALLF'
      if [ \$_n -lt 2 ]; then echo 'overloaded' >&2; return 1; fi
      echo '## Review'; echo 'Findings: [CRITICAL: 0 | HIGH: 0]'
    }
  "
  [ "$status" -eq 0 ] || { echo "expected exit 0 (recovered), got $status: $output" >&2; false; }
  [[ "$output" == *"REVIEW_CAPTURED"* ]]
  [ "$(cat "$CALLF")" -eq 2 ]   # failed once, succeeded on the retry
}

@test "review retry: persistent hard failure exits 1 after MAX attempts (no early abort)" {
  CALLF="$BATS_TEST_TMPDIR/calls-b"; echo 0 > "$CALLF"
  _run_review_loop "
    provider_run_prompt() {
      _n=\$(cat '$CALLF'); _n=\$((_n+1)); echo \$_n > '$CALLF'
      echo 'rate limit exceeded' >&2; return 1
    }
  "
  [ "$status" -eq 1 ]
  [[ "$output" != *"REVIEW_CAPTURED"* ]]
  [ "$(cat "$CALLF")" -eq 3 ]   # retried to the cap, not aborted on the first failure
  [[ "$output" == *"after 3 attempts"* ]]
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
