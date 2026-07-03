#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/local-review.sh
#
# Regression tests for issue #823: review generation burned all 3 retries in
# 9 seconds (3s/6s backoff) inside a 20+ minute Anthropic 529 Overloaded
# incident, losing an otherwise-complete run (PR #830 was already pushed).
# The provider stderr was never surfaced — the log recorded only "exit 1",
# and the 529 root cause had to be inferred from a different issue's
# explicit error 14 minutes later.
#
# The provider retry loop in local-review.sh now:
#   1. surfaces the tail of provider stderr in every failure message
#   2. detects overloaded signatures (529 / overloaded_error, case-insensitive,
#      format-anchored) in stderr and switches to a long backoff schedule
#      (60s then 120s by default, RITE_REVIEW_OVERLOADED_BACKOFF override)
#   3. on exhaustion, says the provider was overloaded and suggests
#      re-running later
# Non-overloaded failures keep the short schedule (RITE_REVIEW_RETRY_BACKOFF).
#
# Tests assert on the emitted messages naming the schedule — NOT wall-clock
# sleeps. The overloaded backoff is overridden to 1s to keep the suite fast.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$PROJECT_ROOT/lib/core/local-review.sh"
}

# Run the REAL provider retry loop (extracted via the sharkrite-extract
# markers, same pattern as local-review-error-path.bats) with a stubbed
# provider. $1 = provider stub body, $2 = extra env setup (optional,
# evaluated after the defaults so it can override them).
_run_review_loop() {
  local stub_body="$1"
  local extra_env="${2:-}"
  local loop_code
  loop_code=$(sed -n '/# sharkrite-extract: provider-retry-loop-start/,/# sharkrite-extract: provider-retry-loop-end/p' "$SCRIPT")
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
    RITE_REVIEW_OVERLOADED_BACKOFF=1
    ${extra_env}
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

@test "529 overloaded_error stderr selects the long backoff schedule" {
  _run_review_loop "
    provider_run_prompt() {
      echo 'API Error: 529 {type:overloaded_error, message:Overloaded}' >&2
      return 1
    }
  "
  [ "$status" -eq 1 ]
  # Long schedule chosen: 1s then 2s (RITE_REVIEW_OVERLOADED_BACKOFF=1 x attempt)
  [[ "$output" == *"long overloaded backoff"* ]]
  [[ "$output" == *"retrying in 1s"* ]]
  [[ "$output" == *"retrying in 2s"* ]]
  # The short schedule (RITE_REVIEW_RETRY_BACKOFF=0 here) was NOT used
  [[ "$output" != *"retrying in 0s"* ]]
  # stderr tail surfaced in the warning, so the root cause is visible in the log
  [[ "$output" == *"stderr tail:"* ]]
  [[ "$output" == *"overloaded_error"* ]]
}

@test "overloaded exhaustion message names the overload and suggests re-running later" {
  _run_review_loop "
    provider_run_prompt() {
      echo 'API Error: 529 {type:overloaded_error, message:Overloaded}' >&2
      return 1
    }
  " "MAX_REVIEW_ATTEMPTS=1"
  [ "$status" -eq 1 ]
  # Actionable, not generic: says overloaded + re-run later
  [[ "$output" == *"provider was overloaded (529/overloaded_error)"* ]]
  [[ "$output" == *"re-run this issue later"* ]]
  # stderr tail also surfaced via print_error on the final failure
  [[ "$output" == *"Provider stderr (tail):"* ]]
}

@test "bare HTTP 529 (no overloaded_error text) selects the long backoff schedule" {
  _run_review_loop "
    provider_run_prompt() {
      echo 'Request failed with HTTP status 529' >&2
      return 1
    }
  " "MAX_REVIEW_ATTEMPTS=2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"long overloaded backoff"* ]]
  [[ "$output" == *"retrying in 1s"* ]]
}

@test "overloaded_error alone is detected case-insensitively" {
  _run_review_loop "
    provider_run_prompt() {
      echo 'anthropic api: OVERLOADED_ERROR' >&2
      return 1
    }
  " "MAX_REVIEW_ATTEMPTS=2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"long overloaded backoff"* ]]
}

@test "generic failure keeps the short backoff schedule and generic message" {
  # Sentinel overloaded backoff of 7s: if the overloaded path were wrongly
  # taken, "retrying in 7s"/"14s" would appear instead of "retrying in 0s".
  _run_review_loop "
    provider_run_prompt() {
      echo 'rate limit exceeded' >&2
      return 1
    }
  " "RITE_REVIEW_OVERLOADED_BACKOFF=7"
  [ "$status" -eq 1 ]
  [[ "$output" == *"retrying in 0s"* ]]
  [[ "$output" != *"long overloaded backoff"* ]]
  [[ "$output" != *"retrying in 7s"* ]]
  [[ "$output" != *"retrying in 14s"* ]]
  # Exhaustion message stays the generic one — no false overload claim
  [[ "$output" == *"Review failed (exit code: 1) after 3 attempts"* ]]
  [[ "$output" != *"capacity incident"* ]]
  # stderr tail still surfaced for generic failures
  [[ "$output" == *"rate limit exceeded"* ]]
  [[ "$output" == *"Provider stderr (tail):"* ]]
}

@test "format anchor: standalone-number match only — 1529 does not trigger overloaded path" {
  _run_review_loop "
    provider_run_prompt() {
      echo 'processed 1529 tokens then hit an internal error' >&2
      return 1
    }
  "
  [ "$status" -eq 1 ]
  [[ "$output" != *"long overloaded backoff"* ]]
  [[ "$output" == *"retrying in 0s"* ]]
}

@test "stderr tail is bounded: only the last lines of a long stderr are surfaced" {
  _run_review_loop "
    provider_run_prompt() {
      for _i in 1 2 3 4 5 6 7; do echo \"stub-stderr-line-\$_i\" >&2; done
      return 1
    }
  " "MAX_REVIEW_ATTEMPTS=1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stub-stderr-line-7"* ]]
  # tail -n 5 keeps lines 3-7; the first lines must not be dumped
  [[ "$output" != *"stub-stderr-line-1"* ]]
  [[ "$output" != *"stub-stderr-line-2"* ]]
}
