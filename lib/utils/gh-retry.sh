#!/bin/bash
# gh-retry.sh
# Safe gh CLI wrapper with retry logic for transient failures.
#
# Provides:
#   gh_safe <gh-args...>   — drop-in replacement for raw gh calls
#
# Behavior:
#   - Retries on 429 (rate-limited) and 5xx server errors with exponential backoff
#   - Returns empty output (exit 0) on 404 / "not found" for READ operations only
#     (view, list, diff, status, checks — resource may not exist yet, that's ok)
#   - Propagates real exit code on 404 for WRITE operations
#     (merge, close, edit, comment, create, api PUT/POST/DELETE/PATCH — 404 is a real error)
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
#
# Defaults are set BEFORE the re-source guard. `gh_safe` is exported via
# `export -f gh_safe` at end-of-file, so subprocesses inherit the function but NOT the
# vars. If a subprocess re-sources this file, the guard would skip the
# default-setting block and gh_safe would die with "unbound variable" under
# set -u. Setting defaults first — and exporting them — keeps subprocesses
# safe.
# ---------------------------------------------------------------------------

# Maximum number of total attempts (1 = no retry)
: "${RITE_GH_MAX_RETRIES:=3}"
export RITE_GH_MAX_RETRIES

# Maximum sleep between retries in seconds
: "${RITE_GH_RETRY_MAX_SLEEP:=30}"
export RITE_GH_RETRY_MAX_SLEEP

# Re-source guard: skip the function definitions if already loaded
# (idempotent sourcing). Must come AFTER defaults so subprocess re-sourcing
# still gets the env vars.
if declare -f gh_safe >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# _gh_is_read_op — returns 0 (true) if the gh subcommand is a read-only op
#
# Read operations: pr view/list/diff/checks/status, issue view/list/status,
#   repo view/list, release view/list, run view/list, workflow view/list,
#   api GET (or bare api with no -X flag)
#
# Write/mutating operations return 1 (false): merge, close, edit, comment,
#   create, reopen, delete, approve, request-reviews, lock, unlock, pin,
#   unpin, transfer, archive, rename, set-default, enable, disable,
#   api with -X PUT/POST/DELETE/PATCH
# ---------------------------------------------------------------------------
_gh_is_read_op() {
  # Inspect args to determine if this is a read-only gh call.
  # $@ is the full argument list passed to gh_safe (e.g., pr view 123 --json ...)
  local -a args=("$@")
  local subcommand="${args[0]:-}"
  local verb="${args[1]:-}"

  # api subcommand: read only if no explicit -X flag, or -X GET
  if [ "$subcommand" = "api" ]; then
    # Use case/shift-style walk on a local array copy to avoid the fragile
    # index-arithmetic pattern (args[$((i+1))]) that misparsed if args were
    # inserted between --method and its value.
    local -a _walk=("${args[@]}")
    while [ ${#_walk[@]} -gt 0 ]; do
      case "${_walk[0]}" in
        -X|--method)
          local method="${_walk[1]:-GET}"
          # Only GET is a read; PUT/POST/DELETE/PATCH are writes
          [ "${method^^}" = "GET" ] && return 0 || return 1
          ;;
      esac
      _walk=("${_walk[@]:1}")  # shift: drop first element
    done
    # No -X flag → defaults to GET → read
    return 0
  fi

  # For all other subcommands, check the verb (second token)
  case "$verb" in
    view|list|diff|checks|status|browse)
      return 0
      ;;
    *)
      # Everything else (merge, close, edit, comment, create, reopen,
      # delete, approve, request-reviews, lock, unlock, pin, unpin,
      # transfer, archive, rename, set-default, enable, disable, etc.)
      return 1
      ;;
  esac
}

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

    # Not-found: PR/issue/resource doesn't exist
    # For READ operations: expected (resource may not exist yet) → return empty, exit 0
    # For WRITE operations: a real error (can't merge/close a non-existent PR) → propagate
    if echo "$stderr_content" | grep -qiE \
        "not found|no pull requests|could not resolve|HTTP 404|404 Not Found|does not exist"; then
      if _gh_is_read_op "$@"; then
        rm -f "$stderr_file"
        echo ""
        return 0
      else
        # Write op got a 404 — fall through to propagate the real exit code
        rm -f "$stderr_file"
        echo "$stderr_content" >&2
        return "$exit_code"
      fi
    fi

    # Rate-limited (429) or GitHub server errors (5xx) — retry with backoff
    #
    # Regex framing: HTTP status codes are matched in three forms:
    #
    #   1. HTTP-prefixed:       "HTTP 503", "(HTTP 429)" — gh pr diff / API errors
    #   2. Bare parenthesised:  "(503)", "(429)"         — gh CLI "Service Unavailable (503)"
    #   3. Bare unframed:       "429", "503"             — observed in raw gh output
    #      e.g. "error: 503 Service Unavailable", curl-level messages, some gh versions
    #
    # All numeric status arms share a trailing anchor invariant — the char after the
    # status code must not be a digit or colon (or end of string). Arms that match the
    # code in a position where ")" could follow (HTTP-prefix and bare unframed) also
    # exclude ")" from the trailing set: ([^0-9:)]|$). This prevents matching digits
    # embedded in larger numbers (e.g. "5001", "14290"), avoids false positives like
    # "HTTP 503:" or "configuration line 503:" (colon excluded), and prevents the bare
    # unframed arm from matching the code inside "(HTTP 503):" via the ")" separator.
    #
    # HTTP-prefixed forms — trailing anchor applied uniformly:
    # Both "HTTP NNN" and "(HTTP NNN)" use ([^0-9:)]|$) — the trailing char must NOT
    # be a digit, colon, or closing paren. This prevents:
    #   "HTTP 503:" — colon excluded → no match ✓
    #   "(HTTP 503):" — arm 1 sees "HTTP 503)" and ")" is excluded → no match ✓
    # The "(HTTP NNN)" form (arm 2) uses ([^0-9:]|$) after the closing paren — ")"
    # is already consumed as part of the literal "\)" in the pattern, so ")" in the
    # exclusion set is not needed there.
    #
    # Bare parenthesised forms — same trailing anchor:
    # \(429\) and \(5[0-9][0-9]\) match the gh CLI pattern "Service Unavailable (503)"
    # where the code appears at the end of the message. The trailing anchor prevents
    # false positives like "Error in module (503): bad config" or "(5031)".
    #
    # Bare unframed arm — trailing anchor also excludes ')':
    # Uses ([^0-9:)]|$) to prevent matching the numeric code inside "(HTTP 503):" —
    # where "503" is followed by ")" (satisfies [^0-9:] but is part of the paren-HTTP
    # form). "(HTTP NNN)" forms are already covered by the explicit paren-HTTP arm
    # (arm 2) which applies the colon-exclusion on the char after the closing paren.
    #
    # Text-based tokens (rate limit, server error, etc.) are long enough to be
    # unambiguous and need no additional anchoring.
    if echo "$stderr_content" | grep -qiE \
        "HTTP (429|5[0-9][0-9])([^0-9:)]|$)|\(HTTP (429|5[0-9][0-9])\)([^0-9:]|$)|\(429\)([^0-9:]|$)|\(5[0-9][0-9]\)([^0-9:]|$)|(^|[^0-9])(429|5[0-9][0-9])([^0-9:)]|$)|rate limit|secondary rate|too many requests|server error"; then
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
    #
    # CONTRACT (merge-pr.sh coupling):
    # merge-pr.sh calls gh_safe via _do_merge which captures combined stdout+stderr
    # with 2>&1. The 409 "Head branch was modified" detection — the grep in
    # `_do_merge` that matches `grep -qiE "Head branch was modified|409"` —
    # relies on this `echo "$stderr_content" >&2` reaching MERGE_OUTPUT through that
    # redirect. Changing this line to suppress stderr (e.g., redirecting to a temp
    # file, or gating on a verbosity flag) would silently disable SHA-mismatch recovery.
    # Regression test: tests/regression/merge-pr-sha-mismatch-detection.bats
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

# Make functions available to sourcing scripts and subshells
export -f _gh_is_read_op
export -f gh_safe
