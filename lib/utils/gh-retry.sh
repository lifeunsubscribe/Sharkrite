#!/bin/bash
# lib/utils/gh-retry.sh
# Retry wrapper for gh CLI calls that handles transient failures.
#
# Distinguishes "resource not found" (404) from "rate limited" (429) or
# server errors (5xx), so callers don't silently proceed with empty data
# after a transient GitHub API hiccup.
#
# Usage:
#   source this file, then replace:
#     gh pr view "$PR" --json foo 2>/dev/null || echo ""
#   with:
#     gh_safe pr view "$PR" --json foo
#
# On success: prints gh stdout, returns 0
# On 404/not-found: prints nothing, returns 1  (resource genuinely absent)
# On exhausted retries: prints error to stderr, returns 1  (surfaces failure)
#
# Config:
#   GH_SAFE_MAX_RETRIES  - number of retries (default: 3)
#   GH_SAFE_RETRY_DELAY  - seconds between retries (default: 5)
#   GH_SAFE_TIMEOUT      - per-attempt timeout in seconds (default: 30)

set -euo pipefail

# ---------------------------------------------------------------------------
# gh_safe [gh-args...]
#
# Wraps `gh [args]` with retry logic. Retries on rate-limit (429) and
# transient server errors (5xx). Does NOT retry on 404 (not found) or
# other client errors (4xx).
#
# Outputs:
#   stdout: gh command output on success
#   stderr: retry/error messages (so callers can capture stdout cleanly)
#
# Returns:
#   0  success
#   1  resource not found (404) — caller should treat as absent
#   1  all retries exhausted — caller should treat as failure (not empty data)
# ---------------------------------------------------------------------------
gh_safe() {
  local max_retries="${GH_SAFE_MAX_RETRIES:-3}"
  local retry_delay="${GH_SAFE_RETRY_DELAY:-5}"
  local timeout_secs="${GH_SAFE_TIMEOUT:-30}"
  local attempt=0
  local gh_stderr_file
  gh_stderr_file=$(mktemp)

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$((attempt + 1))

    # Run gh with a timeout (prevents indefinite hangs on network issues).
    # Capture stderr to parse the error message for classification.
    local gh_output=""
    local gh_exit=0

    # timeout(1) is available on Linux; gtimeout via coreutils on macOS.
    # Fall back to running without timeout if neither is present.
    local timeout_cmd=""
    if command -v timeout >/dev/null 2>&1; then
      timeout_cmd="timeout $timeout_secs"
    elif command -v gtimeout >/dev/null 2>&1; then
      timeout_cmd="gtimeout $timeout_secs"
    fi

    if [ -n "$timeout_cmd" ]; then
      gh_output=$($timeout_cmd gh "$@" 2>"$gh_stderr_file") || gh_exit=$?
    else
      gh_output=$(gh "$@" 2>"$gh_stderr_file") || gh_exit=$?
    fi

    if [ "$gh_exit" -eq 0 ]; then
      # Success — print output and return
      rm -f "$gh_stderr_file"
      printf '%s' "$gh_output"
      return 0
    fi

    local gh_stderr_content
    gh_stderr_content=$(cat "$gh_stderr_file" || true)

    # Classify the failure:
    #
    # 404 / not found — resource genuinely doesn't exist.  Do NOT retry;
    # the caller should handle the absent resource.
    if echo "$gh_stderr_content" | grep -qiE '404|not found|Could not resolve to a node|no pull requests found|no issues found'; then
      rm -f "$gh_stderr_file"
      return 1
    fi

    # 422 / validation errors — bad request, retrying won't help.
    if echo "$gh_stderr_content" | grep -qiE '422|Unprocessable Entity|validation failed'; then
      echo "gh_safe: validation error (422) on 'gh $*' — not retrying" >&2
      echo "$gh_stderr_content" >&2
      rm -f "$gh_stderr_file"
      return 1
    fi

    # Timeout (exit 124 from timeout(1)) — treat as transient, retry.
    if [ "$gh_exit" -eq 124 ]; then
      echo "gh_safe: attempt $attempt/$max_retries timed out after ${timeout_secs}s on 'gh $*'" >&2
    # 429 or rate-limit — transient, retry after delay.
    elif echo "$gh_stderr_content" | grep -qiE '429|rate limit|secondary rate'; then
      echo "gh_safe: attempt $attempt/$max_retries rate-limited on 'gh $*' — waiting ${retry_delay}s" >&2
    # 5xx server errors — transient, retry.
    elif echo "$gh_stderr_content" | grep -qiE '5[0-9][0-9]|server error|internal server error|service unavailable|bad gateway'; then
      echo "gh_safe: attempt $attempt/$max_retries server error on 'gh $*' — waiting ${retry_delay}s" >&2
    # Unknown / other error — retry up to limit, then surface.
    else
      echo "gh_safe: attempt $attempt/$max_retries failed (exit $gh_exit) on 'gh $*'" >&2
      if [ -n "$gh_stderr_content" ]; then
        echo "$gh_stderr_content" >&2
      fi
    fi

    if [ "$attempt" -ge "$max_retries" ]; then
      echo "gh_safe: all $max_retries attempts failed for 'gh $*' — surfacing failure" >&2
      rm -f "$gh_stderr_file"
      return 1
    fi

    sleep "$retry_delay"
  done

  rm -f "$gh_stderr_file"
  return 1
}
