#!/bin/bash
# gh-retry.sh
# Safe gh CLI wrapper with retry logic for transient failures.
#
# Provides:
#   gh_safe <gh-args...>   — drop-in replacement for raw gh calls
#
# Behavior:
#   - Retries on 429 (rate-limited) and 5xx server errors with exponential backoff
#   - Returns empty output (exit 0) on 404 / "not found" (PR/issue doesn't exist)
#   - Surfaces (propagates) non-transient errors so callers fail loudly
#   - On exhausted retries, propagates the final non-zero exit code
#
# Usage examples:
#   # Instead of: gh pr view "$PR_NUMBER" --json foo 2>/dev/null || echo ""
#   gh_safe pr view "$PR_NUMBER" --json foo
#
#   # Instead of: gh issue list --label "foo" 2>/dev/null || echo "[]"
#   gh_safe issue list --label "foo"
#
#   # Write operations (comment, edit, close) — still retries transient failures
#   gh_safe pr comment "$PR_NUMBER" --body-file "$FILE"
#
# Notes:
#   - Captures stderr to distinguish "not found" from "rate limited"
#   - PR_COMMENT_NOT_FOUND ("No comments found") → treated as not-found (empty, exit 0)
#   - 429 sleep intervals: 5s, 15s, 30s (capped by RITE_GH_RETRY_MAX_SLEEP)
#   - Max attempts controlled by RITE_GH_MAX_RETRIES (default: 3)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (can be overridden by environment or .rite/config)
# ---------------------------------------------------------------------------

# Maximum number of total attempts (1 = no retry)
: "${RITE_GH_MAX_RETRIES:=3}"

# Maximum sleep between retries in seconds
: "${RITE_GH_RETRY_MAX_SLEEP:=30}"

# ---------------------------------------------------------------------------
# gh_safe — safe gh wrapper with retry and not-found handling
# ---------------------------------------------------------------------------
gh_safe() {
  local attempt=1
  local sleep_secs=5
  local stderr_file
  stderr_file=$(mktemp)

  while [ "$attempt" -le "$RITE_GH_MAX_RETRIES" ]; do
    # Run gh, capturing stderr separately to inspect error messages
    local output exit_code
    output=$(gh "$@" 2>"$stderr_file") && exit_code=0 || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
      rm -f "$stderr_file"
      echo "$output"
      return 0
    fi

    local stderr_content
    stderr_content=$(cat "$stderr_file" 2>/dev/null || echo "")

    # -----------------------------------------------------------------------
    # Classify the failure
    # -----------------------------------------------------------------------

    # Not-found: PR/issue/resource doesn't exist — expected, return empty
    if echo "$stderr_content" | grep -qiE \
        "not found|no pull requests|could not resolve|HTTP 404|404 Not Found|does not exist"; then
      rm -f "$stderr_file"
      echo ""
      return 0
    fi

    # Rate-limited (429) or GitHub server errors (5xx) — retry with backoff
    if echo "$stderr_content" | grep -qiE \
        "429|rate limit|secondary rate|too many requests|500|502|503|504|server error"; then
      if [ "$attempt" -lt "$RITE_GH_MAX_RETRIES" ]; then
        # Cap sleep at RITE_GH_RETRY_MAX_SLEEP
        local actual_sleep=$(( sleep_secs < RITE_GH_RETRY_MAX_SLEEP ? sleep_secs : RITE_GH_RETRY_MAX_SLEEP ))
        echo "⚠ gh rate-limited or server error (attempt $attempt/$RITE_GH_MAX_RETRIES), retrying in ${actual_sleep}s..." >&2
        sleep "$actual_sleep"
        sleep_secs=$(( sleep_secs * 3 ))
        attempt=$(( attempt + 1 ))
        continue
      fi
    fi

    # Non-transient error — propagate stderr and exit code so caller fails loudly
    # (Do NOT swallow: auth failure, repo not found, malformed args, etc.)
    rm -f "$stderr_file"
    echo "$stderr_content" >&2
    return "$exit_code"
  done

  # Exhausted retries — return last error
  local final_stderr
  final_stderr=$(cat "$stderr_file" 2>/dev/null || echo "")
  rm -f "$stderr_file"
  if [ -n "$final_stderr" ]; then
    echo "$final_stderr" >&2
  fi
  return 1
}

# Make gh_safe available to sourcing scripts
export -f gh_safe
