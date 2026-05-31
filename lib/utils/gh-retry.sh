#!/bin/bash
# lib/utils/gh-retry.sh — gh_safe: retry wrapper for the GitHub CLI
#
# Wraps `gh` commands with automatic retry on transient failures (429, 5xx)
# while distinguishing "resource not found" (no retry) from "rate limited"
# (retry with backoff).
#
# Problem without this wrapper:
#   Bare `gh pr/issue/api` calls with `2>/dev/null || echo ""` swallow both
#   "resource not found" (expected) AND "rate limited" (transient). Callers
#   silently proceed with empty data, producing ghost PRs, skipped comments,
#   and the 2026-05-26 stale-main bug class.
#
# With gh_safe: retries on 429/5xx up to RITE_GH_RETRY_MAX times with
# exponential backoff, propagating only real failures (404, auth errors).
#
# Usage:
#   gh_safe <gh-subcommands-and-flags>
#
#   Drop-in replacement for `gh`. Every flag after `gh_safe` is passed verbatim
#   to the real `gh` binary, so callers need only rename `gh` → `gh_safe`:
#
#     PR_JSON=$(gh_safe pr view "$N" --json title 2>/dev/null || echo "")
#
# Retry policy:
#   - Retries: up to RITE_GH_RETRY_MAX (default: 3)
#   - Backoff: 2^attempt seconds (2s, 4s, 8s)
#   - Triggers: exit code 1 with stderr containing "429", "rate limit",
#               "502", "503", "504", or "timeout"
#   - No-retry: exit 0 (success), or any error WITHOUT those patterns
#               (e.g., 404 "not found" propagates immediately)
#
# Stderr passthrough:
#   gh_safe passes stderr from `gh` to the caller. If the caller suppresses
#   it with 2>/dev/null, transient-error messages are hidden — that's fine,
#   since gh_safe retries transparently. Final-failure messages ARE visible.

set -euo pipefail

# Guard against double-sourcing
[ "${_GH_RETRY_SOURCED:-}" = "1" ] && return 0
_GH_RETRY_SOURCED=1

# Maximum retry attempts for transient gh failures.
# Can be overridden via environment: RITE_GH_RETRY_MAX=5 rite ...
RITE_GH_RETRY_MAX="${RITE_GH_RETRY_MAX:-3}"

# ===========================================================================
# gh_safe — retry-aware wrapper for the gh CLI
#
# Arguments: identical to gh (subcommand + flags passed verbatim)
# Returns:   exit code from gh (0 on success, non-zero on persistent failure)
# Stderr:    passes gh stderr through; logs retry attempts to stderr
# ===========================================================================
gh_safe() {
  local _attempt=0
  local _exit=0
  local _stderr_file
  _stderr_file=$(mktemp)

  while [ "$_attempt" -le "$RITE_GH_RETRY_MAX" ]; do
    _exit=0

    # Run gh, capturing stderr to detect transient error patterns.
    # stdout flows directly to the caller (no buffering).
    gh "$@" 2>"$_stderr_file" || _exit=$?

    if [ "$_exit" -eq 0 ]; then
      # Success — pass any stderr through (informational output) and return
      cat "$_stderr_file" >&2
      rm -f "$_stderr_file"
      return 0
    fi

    # Check if this looks like a transient failure worth retrying
    local _stderr_content
    _stderr_content=$(cat "$_stderr_file")

    # Emit stderr so the caller sees what went wrong (or suppresses via 2>/dev/null)
    echo "$_stderr_content" >&2

    # Detect transient patterns: rate limit (429), server errors (5xx), timeouts
    if echo "$_stderr_content" | grep -qiE '429|rate.?limit|502|503|504|timed? ?out|connection.?reset|network'; then
      _attempt=$((_attempt + 1))
      if [ "$_attempt" -le "$RITE_GH_RETRY_MAX" ]; then
        local _backoff=$(( 2 ** _attempt ))
        echo "gh_safe: transient failure (attempt ${_attempt}/${RITE_GH_RETRY_MAX}), retrying in ${_backoff}s..." >&2
        sleep "$_backoff"
        continue
      fi
      # Exhausted retries
      echo "gh_safe: gave up after ${RITE_GH_RETRY_MAX} retries (last exit: ${_exit})" >&2
    fi

    # Non-transient failure (404, auth error, etc.) or retries exhausted —
    # propagate exit code to caller
    rm -f "$_stderr_file"
    return "$_exit"
  done

  rm -f "$_stderr_file"
  return "$_exit"
}
