#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/local-review.sh
#
# Regression tests for issue #1590: when a review provider call fails,
# local-review.sh reported only the stderr tail — but claude --print writes
# usage-cap and API-error notices to stdout, not stderr.
#
# Live failure (2026-10-27): two batches had every review exit 1 in ~2s.
# The log showed only five "Permission allow rule ... has a wildcard" warnings
# from stderr. The actual cause — "You're out of usage credits." on stdout —
# was invisible.
#
# The fix: capture a tail of REVIEW_OUTPUT (stdout) alongside the existing
# CLAUDE_ERROR (stderr) tail and report both channels, labelled, on failure.
# The 529/overloaded classifier is extended to scan stdout as well, so a
# stdout-channel 529 gets the long backoff schedule.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$PROJECT_ROOT/lib/core/local-review.sh"
}

# Run the REAL provider retry loop (extracted via sharkrite-extract markers)
# with a stubbed provider.  $1 = provider stub body, $2 = extra env (optional).
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

# ---------------------------------------------------------------------------
# stdout-only failure
# ---------------------------------------------------------------------------

@test "stdout-only failure: stdout tail appears in failure message" {
  _run_review_loop "
    provider_run_prompt() {
      echo 'You are out of usage credits.'
      return 1
    }
  " "MAX_REVIEW_ATTEMPTS=1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Provider stdout (tail):"* ]]
  [[ "$output" == *"You are out of usage credits."* ]]
  # stderr tail block must NOT appear (stderr was empty)
  [[ "$output" != *"Provider stderr (tail):"* ]]
}

# ---------------------------------------------------------------------------
# both channels: stderr must not crowd out stdout
# ---------------------------------------------------------------------------

@test "stderr warnings do not crowd out stdout cause: both tails reported" {
  _run_review_loop "
    provider_run_prompt() {
      echo 'Permission allow rule matchPatterns has a wildcard' >&2
      echo 'Permission allow rule another has a wildcard' >&2
      echo 'You are out of usage credits.'
      return 1
    }
  " "MAX_REVIEW_ATTEMPTS=1"
  [ "$status" -eq 1 ]
  # Both channels must appear, labelled
  [[ "$output" == *"Provider stderr (tail):"* ]]
  [[ "$output" == *"Provider stdout (tail):"* ]]
  [[ "$output" == *"You are out of usage credits."* ]]
  [[ "$output" == *"wildcard"* ]]
}

# ---------------------------------------------------------------------------
# empty stdout: no spurious stdout section
# ---------------------------------------------------------------------------

@test "empty stdout: no Provider stdout tail block emitted" {
  _run_review_loop "
    provider_run_prompt() {
      echo 'rate limit exceeded' >&2
      return 1
    }
  " "MAX_REVIEW_ATTEMPTS=1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Provider stderr (tail):"* ]]
  [[ "$output" != *"Provider stdout (tail):"* ]]
}

# ---------------------------------------------------------------------------
# 529 on stdout: long backoff schedule
# ---------------------------------------------------------------------------

@test "529 on stdout selects the long backoff schedule" {
  _run_review_loop "
    provider_run_prompt() {
      echo 'API Error: HTTP 529 Overloaded'
      return 1
    }
  " "MAX_REVIEW_ATTEMPTS=2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"long overloaded backoff"* ]]
  [[ "$output" == *"retrying in 1s"* ]]
  # Sentinel: short schedule (backoff=0) must NOT appear
  [[ "$output" != *"retrying in 0s"* ]]
}

@test "overloaded_error on stdout selects the long backoff schedule" {
  _run_review_loop "
    provider_run_prompt() {
      echo 'type: overloaded_error'
      return 1
    }
  " "MAX_REVIEW_ATTEMPTS=2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"long overloaded backoff"* ]]
}

# ---------------------------------------------------------------------------
# stdout tail bounded
# ---------------------------------------------------------------------------

@test "stdout tail is bounded: only the last lines of a long stdout are surfaced" {
  _run_review_loop "
    provider_run_prompt() {
      for _i in 1 2 3 4 5 6 7; do echo \"stub-stdout-line-\$_i\"; done
      return 1
    }
  " "MAX_REVIEW_ATTEMPTS=1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stub-stdout-line-7"* ]]
  # tail -n 5 keeps lines 3-7; first lines must not appear
  [[ "$output" != *"stub-stdout-line-1"* ]]
  [[ "$output" != *"stub-stdout-line-2"* ]]
}

# ---------------------------------------------------------------------------
# retry path: stdout tail appears in warning, not only on final failure
# ---------------------------------------------------------------------------

@test "stdout tail appears in retry warning messages, not only on final failure" {
  _run_review_loop "
    provider_run_prompt() {
      echo 'credits exhausted notice'
      return 1
    }
  " "MAX_REVIEW_ATTEMPTS=3"
  [ "$status" -eq 1 ]
  # At least one WARNING containing the stdout text must appear (retries 1 and 2)
  [[ "$output" == *"[WARNING]"* ]]
  [[ "$output" == *"Provider stdout (tail):"* ]]
  [[ "$output" == *"credits exhausted notice"* ]]
}

# ---------------------------------------------------------------------------
# happy path: no extra output
# ---------------------------------------------------------------------------

@test "happy path: no stdout tail block emitted on successful review" {
  _run_review_loop "
    provider_run_prompt() {
      echo '## Code Review'
      echo 'Findings: [CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 0]'
    }
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"REVIEW_CAPTURED"* ]]
  [[ "$output" != *"Provider stdout (tail):"* ]]
  [[ "$output" != *"Provider stderr (tail):"* ]]
}
