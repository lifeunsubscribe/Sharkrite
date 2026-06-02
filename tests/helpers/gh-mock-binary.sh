#!/usr/bin/env bash
# tests/helpers/gh-mock-binary.sh
#
# Standalone mock gh binary for assess-and-resolve.sh integration tests.
# Intended to be copied/linked into a test's mock-bin directory.
#
# Reads runtime state from environment variables:
#   GH_MOCK_STATE_DIR     — directory containing stateful dedup state files
#   GH_MOCK_PR_VIEW_FILE  — path to JSON fixture for `gh pr view` responses
#
# Supported commands:
#   gh pr view PR --json comments [--jq FILTER]
#     → sharkrite-followup-issue filter: routes to stateful comment store
#     → all other filters: serves GH_MOCK_PR_VIEW_FILE
#   gh pr comment PR --body-file F
#     → records comment in stateful comment store
#   gh issue list --search "..." --state open --json number [--jq FILTER]
#     → in:body search: substring match against stateful issue bodies
#     → in:title search: substring match against stateful issue titles
#     → honours GH_MOCK_ISSUE_INDEX_LAG (search-lag.txt counter)
#   gh issue create --title T --body-file F [--label L]
#     → records issue in stateful store; returns URL
#   gh issue view N [--json url|body|state --jq FILTER]
#     → returns data for tracked issue; empty string if not found (exit 0)
#   gh label create / gh label list
#     → no-op (succeed silently)
#   All other commands
#     → succeed silently (exit 0, no output)
#
# Concurrency model:
#   This binary is invoked as a subprocess — multiple concurrent invocations
#   share the same GH_MOCK_STATE_DIR files.  All state-mutating operations
#   (issue create, pr comment, lag-counter decrement) are serialised with
#   flock(1) on GH_MOCK_STATE_DIR/state.lock.  Falls back to no-op if flock
#   is absent (documents the sequential-only behaviour for such environments).

set -euo pipefail

# Source the shared stateful logic library.
# The binary is typically copied into a temp mock-bin dir; the library
# lives alongside the original binary in tests/helpers/.  To find it,
# resolve the directory of this script using BASH_SOURCE[0], which gives
# the path of the currently-executing file regardless of how it was invoked.
_binary_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers/gh-mock-state.bash
source "${_binary_dir}/gh-mock-state.bash"
unset _binary_dir

# ---------------------------------------------------------------------------
# State file paths (top-level vars for use in lock/unlock helpers that run
# before entering the command blocks).
# These shadow the functions from gh-mock-state.bash with pre-computed values
# so the lock helpers don't need to call functions dynamically.
# ---------------------------------------------------------------------------
_issues_file="${GH_MOCK_STATE_DIR}/issues.json"
_comments_file="${GH_MOCK_STATE_DIR}/pr-comments.json"
_lag_file="${GH_MOCK_STATE_DIR}/search-lag.txt"
_next_num_file="${GH_MOCK_STATE_DIR}/next-issue-num.txt"

# Shared lock file that serialises all state-mutating operations in this binary.
# This binary is invoked as a subprocess — multiple concurrent invocations
# (e.g. parallel assess-and-resolve.sh runs) share the same GH_MOCK_STATE_DIR
# files.  Without a lock the read-compute-write sequences for the issue counter
# and JSON state files are non-atomic, making issue numbers non-unique and JSON
# writes lossy under parallelism.
#
# Lock strategy: flock(1) on a dedicated lock file.  flock is available on
# macOS (via Homebrew util-linux) and natively on Linux.  We fall back to a
# no-op (document-only guard) if flock is absent, which preserves the prior
# sequential-only behaviour for environments without it.
#
# Callers: the lock is acquired/released around every state-mutating command
# block (issue create, pr comment, lag-counter decrement) using the helper
# functions _gh_mock_lock / _gh_mock_unlock defined below.
_state_lock_file="${GH_MOCK_STATE_DIR}/state.lock"

# _GH_MOCK_LOCK_FD holds the file descriptor allocated by bash automatic FD
# allocation ({var}>) so that _gh_mock_lock and _gh_mock_unlock share it
# without passing it as a parameter (eliminating the eval injection vector).
_GH_MOCK_LOCK_FD=""

# _gh_mock_lock
#   Acquires an exclusive flock on _state_lock_file.  Uses bash automatic FD
#   allocation ({_GH_MOCK_LOCK_FD}>) so the kernel picks an unused descriptor —
#   no hard-coded FD number, no eval, no injection risk.
#   If flock is unavailable, emits a warning and continues without locking
#   (sequential-only fallback — adequate for all current callers).
_gh_mock_lock() {
  if command -v flock >/dev/null 2>&1; then
    # Bash automatic FD allocation: {_GH_MOCK_LOCK_FD}> opens the lock file on
    # a kernel-chosen descriptor and stores the number in _GH_MOCK_LOCK_FD.
    # This avoids both hard-coded FD 9 (inherited-FD conflict) and eval (injection).
    exec {_GH_MOCK_LOCK_FD}>"$_state_lock_file"
    flock -w 30 "$_GH_MOCK_LOCK_FD" 2>/dev/null || {
      echo "gh-mock-binary: WARNING: could not acquire state lock within 30s" >&2
    }
  fi
}

# _gh_mock_unlock
#   Releases the flock held on _GH_MOCK_LOCK_FD and closes it.
_gh_mock_unlock() {
  if command -v flock >/dev/null 2>&1; then
    flock -u "$_GH_MOCK_LOCK_FD" 2>/dev/null || true
    exec {_GH_MOCK_LOCK_FD}>&- 2>/dev/null || true
    _GH_MOCK_LOCK_FD=""
  fi
}

# ---- gh pr view ----
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  _pr_num="${3:-}"
  _json_fields=""
  _jq_filter=""
  shift 3 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) _json_fields="$2"; shift 2 ;;
      --jq)   _jq_filter="$2";   shift 2 ;;
      *)      shift ;;
    esac
  done

  # Route sharkrite-followup-issue marker checks to stateful comment store
  # (dedup retry loop Source 4 in assess-and-resolve.sh)
  if echo "${_jq_filter:-}" | grep -q 'sharkrite-followup-issue'; then
    _gh_mock_state_pr_view "$_pr_num" --jq "${_jq_filter:-}"
    exit 0
  fi

  # All other pr view calls: serve from GH_MOCK_PR_VIEW_FILE
  _raw="{}"
  [ -f "${GH_MOCK_PR_VIEW_FILE:-}" ] && _raw=$(cat "$GH_MOCK_PR_VIEW_FILE")

  if [ -n "$_jq_filter" ]; then
    echo "$_raw" | jq -r "$_jq_filter" 2>/dev/null || true
  else
    echo "$_raw"
  fi
  exit 0
fi

# ---- gh pr comment (record follow-up marker comment) ----
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
  _pr_num="${3:-}"
  _body_file=""
  shift 3 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --body-file) _body_file="$2"; shift 2 ;;
      *)           shift ;;
    esac
  done

  # Acquire state lock before modifying shared comments file.
  # The read-merge-write of pr-comments.json is non-atomic; concurrent
  # invocations without the lock would silently clobber each other's writes.
  _gh_mock_lock
  trap '_gh_mock_unlock' EXIT
  _gh_mock_state_pr_comment "$_pr_num" ${_body_file:+--body-file "$_body_file"}
  _gh_mock_unlock
  trap - EXIT
  exit 0
fi

# ---- gh issue list (dedup search) ----
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  _search="" _state="OPEN" _jq_filter="" _json_fields=""
  shift 2
  # Capture all remaining args to pass through to the shared function
  _list_args=("$@")

  # Apply search-index lag for content searches.
  # Acquire the state lock around the lag-counter read-decrement-write to
  # prevent two concurrent search calls from both reading the same counter
  # value and each decrementing it independently (which would burn two lag
  # slots instead of one, causing premature index visibility).
  #
  # Parse --search value inline to check for in:(body|title) before deciding
  # whether locking is needed for the lag decrement.
  _search_val=""
  _i=0
  while [ "$_i" -lt "${#_list_args[@]}" ]; do
    _arg="${_list_args[$_i]}"
    if [ "$_arg" = "--search" ] || [ "$_arg" = "-S" ]; then
      _i=$((_i + 1))
      _search_val="${_list_args[$_i]:-}"
    fi
    _i=$((_i + 1))
  done

  if echo "$_search_val" | grep -qE 'in:(body|title)'; then
    _gh_mock_lock
    trap '_gh_mock_unlock' EXIT
    _lag=$(cat "$_lag_file" 2>/dev/null || echo "0")
    [[ "$_lag" =~ ^[0-9]+$ ]] || _lag=0
    if [ "$_lag" -gt 0 ]; then
      echo $((_lag - 1)) > "$_lag_file"
      _gh_mock_unlock
      trap - EXIT
      # Parse --jq from the args to apply the empty-array filter
      _jq_f=""
      _i=0
      while [ "$_i" -lt "${#_list_args[@]}" ]; do
        if [ "${_list_args[$_i]}" = "--jq" ]; then
          _i=$((_i + 1))
          _jq_f="${_list_args[$_i]:-}"
        fi
        _i=$((_i + 1))
      done
      if [ -n "$_jq_f" ]; then
        echo "[]" | jq -r "$_jq_f" 2>/dev/null || true
      else
        echo "[]"
      fi
      exit 0
    fi
    _gh_mock_unlock
    trap - EXIT
  fi

  # Delegate to shared library (no locking needed for the read-only search)
  _gh_mock_state_issue_list "${_list_args[@]}"
  exit 0
fi

# ---- gh issue create ----
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  shift 2
  _create_args=("$@")

  # Acquire the state lock before the read-compute-write sequence.
  #
  # Without the lock, two concurrent invocations could both read the same
  # _seq value, compute the same _issue_num, and write the same counter back —
  # producing duplicate issue numbers and a last-writer-wins clobber of the
  # issues.json append.  The lock serialises all three steps atomically:
  #   READ  _seq from _next_num_file
  #   WRITE _seq+1 back to _next_num_file
  #   WRITE new issue entry to issues.json (via tmp+mv)
  _gh_mock_lock
  trap '_gh_mock_unlock' EXIT
  _url=$(_gh_mock_state_issue_create "${_create_args[@]}")
  _gh_mock_unlock
  trap - EXIT

  echo "$_url"
  exit 0
fi

# ---- gh issue view (state check + URL/body lookup) ----
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  _issue_num="${3:-}"
  shift 3 2>/dev/null || true
  # Delegate to shared library (read-only, no locking needed)
  _gh_mock_state_issue_view "$_issue_num" "$@"
  exit 0
fi

# ---- gh label create / list (no-op) ----
if [ "${1:-}" = "label" ]; then
  exit 0
fi

# ---- Fallback: succeed silently ----
exit 0
