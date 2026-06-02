#!/usr/bin/env bash
# tests/helpers/gh-mock-state.bash
#
# Shared stateful mock state library — used by BOTH gh-mock.bash (in-process
# bash function mock) and gh-mock-binary.sh (subprocess binary mock).
#
# This file contains the pure stateful logic: search/lag/store operations on
# the GH_MOCK_STATE_DIR files.  It does NOT handle concurrency locking —
# that is the responsibility of each caller:
#   - gh-mock.bash:        sequential-only, no locking needed
#   - gh-mock-binary.sh:   wraps mutating calls in flock(1)
#
# All state lives in files under GH_MOCK_STATE_DIR:
#   issues.json          — tracked issues array
#   pr-comments.json     — comments by PR number
#   search-lag.txt       — eventual-consistency lag counter
#   next-issue-num.txt   — sequential issue number counter
#
# issue view not-found contract (unified):
#   Returns empty string and exits/returns 0.
#   Rationale: gh-mock-binary.sh simulates the real gh CLI as seen through
#   gh_safe (lib/utils/gh-retry.sh), which converts 404-not-found on READ
#   operations to empty output + exit 0.  gh-mock.bash previously returned
#   exit 1 — that was a divergence from the binary contract and from what
#   assess-and-resolve.sh actually receives from the real gh CLI.  Both mocks
#   now agree on exit 0 + empty for not-found.
#
# Usage:
#   source tests/helpers/gh-mock-state.bash
#   # Then call functions like _gh_mock_state_issue_list, etc.
#   # Caller is responsible for setting GH_MOCK_STATE_DIR.

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f _gh_mock_state_init >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# State file path helpers
# ---------------------------------------------------------------------------

_gh_mock_state_issues_file()   { echo "${GH_MOCK_STATE_DIR}/issues.json"; }
_gh_mock_state_comments_file() { echo "${GH_MOCK_STATE_DIR}/pr-comments.json"; }
_gh_mock_state_lag_file()      { echo "${GH_MOCK_STATE_DIR}/search-lag.txt"; }
_gh_mock_state_next_num_file() { echo "${GH_MOCK_STATE_DIR}/next-issue-num.txt"; }

# ---------------------------------------------------------------------------
# _gh_mock_state_init
#
# Initialize all state files in GH_MOCK_STATE_DIR.
# Called by setup_gh_mock_state() and reset_gh_mock().
# Safe to call multiple times — overwrites existing state.
# ---------------------------------------------------------------------------
_gh_mock_state_init() {
  echo "[]"  > "$(_gh_mock_state_issues_file)"
  echo "{}"  > "$(_gh_mock_state_comments_file)"
  echo "0"   > "$(_gh_mock_state_next_num_file)"
  # Seed index lag counter: 0 = no lag, N = N searches return empty before visible
  echo "${GH_MOCK_ISSUE_INDEX_LAG:-0}" > "$(_gh_mock_state_lag_file)"
}

# ---------------------------------------------------------------------------
# _gh_mock_state_issue_list
#
# Implements: gh issue list --search "..." [--state ...] [--json ...] [--jq ...]
#
# Simulates the two search patterns used by assess-and-resolve.sh:
#   in:body  → match substring in issue body (primary dedup search)
#   in:title → match substring in issue title (fallback dedup search)
#
# Handles search-index lag: when the lag counter > 0, body/title searches
# return an empty JSON array and decrement the counter.
#
# LOCKING NOTE: The lag counter decrement (read-compute-write) is NOT
# protected here.  Sequential callers (gh-mock.bash) need no lock.
# Concurrent callers (gh-mock-binary.sh) MUST acquire the state lock before
# calling this function and release it after.
#
# Returns: JSON array (possibly filtered by --jq) to stdout.
# Exit: 0 always (empty result is not an error).
# ---------------------------------------------------------------------------
_gh_mock_state_issue_list() {
  local _search="" _state="OPEN" _jq_filter="" _json_fields=""

  # Parse flags (mirroring the flags used by assess-and-resolve.sh)
  while [ $# -gt 0 ]; do
    case "$1" in
      --search|-S) _search="$2"; shift 2 ;;
      --state)
        # Normalize to uppercase so it matches stored "OPEN"/"CLOSED" values.
        # assess-and-resolve.sh passes --state open (lowercase).
        _state=$(echo "$2" | tr '[:lower:]' '[:upper:]')
        shift 2 ;;
      --json)  _json_fields="$2"; shift 2 ;;
      --jq)    _jq_filter="$2";   shift 2 ;;
      --limit) shift 2 ;;   # accepted but unused
      *)       shift ;;
    esac
  done

  local _issues_file
  _issues_file=$(_gh_mock_state_issues_file)

  # Apply search-index lag: decrement counter; return empty while counter > 0.
  # Only applied to content searches (in:body / in:title) — not other list calls.
  if echo "$_search" | grep -qE 'in:(body|title)'; then
    local _lag_file
    _lag_file=$(_gh_mock_state_lag_file)
    local _lag
    _lag=$(cat "$_lag_file" 2>/dev/null || echo "0")
    # Guard against empty or non-numeric content (e.g. truncated write) to
    # prevent "integer expression expected" under set -e.
    [[ "$_lag" =~ ^[0-9]+$ ]] || _lag=0
    if [ "$_lag" -gt 0 ]; then
      echo $((_lag - 1)) > "$_lag_file"
      # Return empty array; let caller's --jq handle it
      if [ -n "$_jq_filter" ]; then
        echo "[]" | jq -r "$_jq_filter" 2>/dev/null || true
      else
        echo "[]"
      fi
      return 0
    fi
  fi

  # Build jq filter to select matching issues.
  # Use test() with a token-boundary suffix instead of contains() to prevent
  # false-positive dedup matches: "sharkrite-source-issue:5" must not match an
  # issue body containing "sharkrite-source-issue:55".
  #
  # The suffix ([^[:alnum:]_-]|$) requires the match to be followed by a
  # non-token character or end-of-string. We avoid negative lookahead (?!...)
  # because bash history expansion mangles the `!` inside double-quoted strings.
  #
  # Quoted search terms: GitHub search supports quoting to force literal phrase
  # matching (e.g., "sharkrite-source-issue:42" in:body).  The mock strips the
  # outer quotes from each quoted token before matching — the body never contains
  # the literal quote characters.
  local _jq_select
  if echo "$_search" | grep -q 'in:body'; then
    # Extract the marker/term before " in:body", then strip outer double-quotes
    # from any quoted tokens (e.g., "sharkrite-source-issue:42" → sharkrite-source-issue:42).
    #
    # COVERAGE GAP: Multi-token search (e.g., assess-review-issues.sh builds
    # "sharkrite-source-issue:N keyword1 keyword2 in:body") is not faithfully simulated
    # here.  The mock concatenates all tokens into a single regex term, so it tests as a
    # substring match rather than the independent-token AND matching GitHub's real search
    # engine performs.  Tests for the multi-token path exercise the mock's approximation,
    # not real GitHub behavior.  The body-verification guard in assess-review-issues.sh
    # is the reliable correctness guarantee; this mock path is a best-effort smoke test.
    local _term
    _term=$(echo "$_search" | sed 's/ in:body.*//' | sed 's/^ *//' | sed 's/ *$//')
    _term=$(echo "$_term" | sed 's/"//g')
    local _term_lower
    _term_lower=$(echo "$_term" | tr '[:upper:]' '[:lower:]')
    local _escaped_term
    _escaped_term=$(printf '%s' "$_term_lower" | sed 's/[.[\*^$()+?{}|\\]/\\&/g')
    _jq_select="[.[] | select((.body | ascii_downcase | test(\"${_escaped_term}([^[:alnum:]_-]|\$)\")) and (.state == \"$_state\"))]"
  elif echo "$_search" | grep -q 'in:title'; then
    # Extract the term after "in:title ", then strip outer double-quotes
    # from any quoted tokens.
    local _term
    _term=$(echo "$_search" | sed 's/.*in:title *//' | sed 's/ *$//')
    _term=$(echo "$_term" | sed 's/"//g')
    local _term_lower
    _term_lower=$(echo "$_term" | tr '[:upper:]' '[:lower:]')
    local _escaped_term
    _escaped_term=$(printf '%s' "$_term_lower" | sed 's/[.[\*^$()+?{}|\\]/\\&/g')
    _jq_select="[.[] | select((.title | ascii_downcase | test(\"${_escaped_term}([^[:alnum:]_-]|\$)\")) and (.state == \"$_state\"))]"
  else
    # No in: qualifier — return all issues matching the state filter
    _jq_select="[.[] | select(.state == \"$_state\")]"
  fi

  local _result
  _result=$(jq -r "$_jq_select" "$_issues_file" 2>/dev/null || echo "[]")

  # Apply --jq filter if provided (e.g., '.[0].number')
  if [ -n "$_jq_filter" ]; then
    echo "$_result" | jq -r "$_jq_filter" 2>/dev/null || true
  else
    echo "$_result"
  fi
}

# ---------------------------------------------------------------------------
# _gh_mock_state_issue_create
#
# Implements: gh issue create --title T --body-file F [--label L]
#
# Records the issue in state and prints a GitHub-style URL to stdout.
# Issue numbers start at 1000 + sequential counter to avoid collisions
# with fixture-based issue numbers.
#
# Uses jq --rawfile (not --arg) to read the body so that HTML comment
# characters (e.g. <!-- -->) are not escaped as <\!-- by macOS jq 1.7.x.
#
# LOCKING NOTE: The read-compute-write on the issue counter and JSON array is
# NOT atomic here.  Sequential callers (gh-mock.bash) need no lock.
# Concurrent callers (gh-mock-binary.sh) MUST acquire the state lock before
# calling this function and release it after:
#   READ  _seq from next-issue-num.txt
#   WRITE _seq+1 back to next-issue-num.txt
#   WRITE new entry to issues.json (via tmp+mv)
#
# Outputs: issue URL (https://github.com/mock/repo/issues/NNNN)
# Exit: 0 on success, non-zero on jq failure.
# ---------------------------------------------------------------------------
_gh_mock_state_issue_create() {
  local _title="" _body_file="" _label=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --title)     _title="$2";     shift 2 ;;
      --body-file) _body_file="$2"; shift 2 ;;
      --label)     _label="$2";     shift 2 ;;
      *)           shift ;;
    esac
  done

  # Use a temp file for the body so --rawfile can read it.
  # --rawfile preserves special characters (e.g. ! in <!--) that --arg escapes.
  local _tmp_body_file=""
  local _body_source=""
  if [ -n "$_body_file" ] && [ -f "$_body_file" ]; then
    _body_source="$_body_file"
  else
    _tmp_body_file=$(mktemp)
    # Ensure the temp file is removed on any exit path (including jq failure).
    # shellcheck disable=SC2064
    trap "rm -f '${_tmp_body_file}'" RETURN
    _body_source="$_tmp_body_file"
    : > "$_body_source"   # empty body
  fi

  # Assign sequential issue number.
  # READ → COMPUTE → WRITE: non-atomic — see LOCKING NOTE above.
  local _num_file
  _num_file=$(_gh_mock_state_next_num_file)
  local _seq
  _seq=$(cat "$_num_file" 2>/dev/null || echo "0")
  # Guard against empty or non-numeric content to prevent arithmetic errors.
  [[ "$_seq" =~ ^[0-9]+$ ]] || _seq=0
  local _issue_num
  _issue_num=$(( _seq + 1000 ))
  echo $(( _seq + 1 )) > "$_num_file"

  local _issues_file
  _issues_file=$(_gh_mock_state_issues_file)

  # Append the new issue to the tracked list.
  # READ → MERGE → WRITE (via tmp+mv): the mv is atomic, but the read-merge
  # window between two callers is not — see LOCKING NOTE above.
  jq --argjson num "$_issue_num" \
     --arg title "$_title" \
     --rawfile body "$_body_source" \
     --arg label "$_label" \
     --arg state "OPEN" \
     '. += [{"number": $num, "title": $title, "body": $body, "label": $label, "state": $state, "url": ("https://github.com/mock/repo/issues/" + ($num | tostring))}]' \
     "$_issues_file" > "${_issues_file}.tmp" && mv "${_issues_file}.tmp" "$_issues_file"

  [ -n "$_tmp_body_file" ] && rm -f "$_tmp_body_file" || true

  # NOTE: The lag counter is intentionally NOT reset here.  Resetting it on
  # every create would make it impossible to model the multi-issue concurrent-
  # index-lag scenario that assess-and-resolve.sh's retry loop guards against.
  # The counter is a global budget shared across all creates in a test; it is
  # seeded once at init time and decremented by each content search until exhausted.

  echo "https://github.com/mock/repo/issues/${_issue_num}"
}

# ---------------------------------------------------------------------------
# _gh_mock_state_issue_view
#
# Implements: gh issue view N [--json url|body|state --jq FILTER]
#
# Returns data for a tracked issue.  Returns empty string (exit 0) if the
# issue is not in the stateful store — simulating how gh_safe (the real
# caller's wrapper in lib/utils/gh-retry.sh) converts a 404 "not found" to
# empty output + exit 0 for READ operations.
#
# This unified not-found behavior is intentionally the same in both gh-mock.bash
# and gh-mock-binary.sh.  assess-and-resolve.sh treats empty output as a
# transient API failure and preserves the dedup guarantee (does not clear
# evidence); it does NOT expect exit 1 from a missing issue.
#
# Callers of mock_gh / the binary that need to distinguish "not found" from
# "found" must check for empty output, not the exit code.
#
# CONTRACT: Callers must NOT rely on exit code for found/not-found distinction.
#   - Issue found    → non-empty output, exit 0
#   - Issue not found → empty output,     exit 0
# Use [ -z "$output" ] to detect not-found, never [ "$status" -ne 0 ].
#
# Exit: 0 always (not-found is not an error from the caller's perspective).
# ---------------------------------------------------------------------------
_gh_mock_state_issue_view() {
  local _issue_num="${1:-}"
  shift || true

  local _jq_filter="" _json_fields=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --jq)   _jq_filter="$2"; shift 2 ;;
      --json) _json_fields="$2"; shift 2 ;;
      *)      shift ;;
    esac
  done

  local _issues_file
  _issues_file=$(_gh_mock_state_issues_file)

  local _issue
  _issue=$(jq --argjson num "${_issue_num:-0}" \
    '.[] | select(.number == $num)' \
    "$_issues_file" 2>/dev/null || true)

  if [ -z "$_issue" ]; then
    # Not in state — return empty (exit 0).
    # This mirrors gh_safe's behavior: 404 on a READ op → empty output + exit 0.
    # assess-and-resolve.sh treats empty output as a transient API failure and
    # preserves the dedup guarantee rather than clearing evidence.
    echo ""
    return 0
  fi

  if [ -n "$_jq_filter" ]; then
    echo "$_issue" | jq -r "$_jq_filter" 2>/dev/null || true
  else
    echo "$_issue"
  fi
}

# ---------------------------------------------------------------------------
# _gh_mock_state_pr_comment
#
# Implements: gh pr comment N --body-file F
#
# Records a comment on the PR in state.
#
# Uses jq --rawfile (not --arg) to read the body so that HTML comment
# characters (e.g. <!-- -->) are not escaped as <\!-- by macOS jq 1.7.x.
# The assess-and-resolve.sh dedup logic posts marker comments containing
# <!-- sharkrite-followup-issue:N --> and then checks for them via
# `contains("<!-- sharkrite-followup-issue:")` — this only works correctly
# when the stored body is not escaped.
#
# LOCKING NOTE: The read-merge-write of pr-comments.json is NOT atomic here.
# Sequential callers (gh-mock.bash) need no lock.
# Concurrent callers (gh-mock-binary.sh) MUST acquire the state lock before
# calling this function and release it after.
#
# Exit: 0 on success, non-zero on jq failure.
# ---------------------------------------------------------------------------
_gh_mock_state_pr_comment() {
  local _pr_num="${1:-}"
  shift || true

  local _body_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --body-file) _body_file="$2"; shift 2 ;;
      *)           shift ;;
    esac
  done

  # Use a temp file when body_file is not provided
  local _tmp_body_file=""
  local _body_source=""
  if [ -n "$_body_file" ] && [ -f "$_body_file" ]; then
    _body_source="$_body_file"
  else
    _tmp_body_file=$(mktemp)
    # Ensure the temp file is removed on any exit path (including jq failure).
    # shellcheck disable=SC2064
    trap "rm -f '${_tmp_body_file}'" RETURN
    _body_source="$_tmp_body_file"
    : > "$_body_source"
  fi

  local _comments_file
  _comments_file=$(_gh_mock_state_comments_file)

  # Append comment to the PR's comment list
  jq --arg pr "$_pr_num" \
     --rawfile body "$_body_source" \
     'if has($pr) then .[$pr] += [{"body": $body}]
      else .[$pr] = [{"body": $body}]
      end' \
     "$_comments_file" > "${_comments_file}.tmp" && mv "${_comments_file}.tmp" "$_comments_file"

  [ -n "$_tmp_body_file" ] && rm -f "$_tmp_body_file" || true
}

# ---------------------------------------------------------------------------
# _gh_mock_state_issue_set_state
#
# Mutates the `state` field of a tracked issue in issues.json.
#
# Usage: _gh_mock_state_issue_set_state ISSUE_NUMBER NEW_STATE
#   ISSUE_NUMBER — numeric issue number (e.g. 1000)
#   NEW_STATE    — "OPEN" or "CLOSED"
#
# This allows tests to simulate an issue being closed after it was created,
# which exercises the CLOSED-evidence clearing branch in assess-and-resolve.sh
# (lines 1180-1183): when local evidence points to a CLOSED issue, the script
# clears the stale evidence file and continues the dedup check.
#
# LOCKING NOTE: Not lock-protected.  Sequential callers (tests) need no lock.
# Concurrent callers would need to wrap in flock — not currently needed.
#
# Exit: 0 on success, non-zero on jq failure.
# ---------------------------------------------------------------------------
_gh_mock_state_issue_set_state() {
  local _issue_num="${1:-}"
  local _new_state="${2:-OPEN}"

  local _issues_file
  _issues_file=$(_gh_mock_state_issues_file)

  jq --argjson num "${_issue_num:-0}" \
     --arg state "$_new_state" \
     '[.[] | if .number == $num then .state = $state else . end]' \
     "$_issues_file" > "${_issues_file}.tmp" \
  && mv "${_issues_file}.tmp" "$_issues_file"
}

# ---------------------------------------------------------------------------
# _gh_mock_state_pr_view
#
# Implements: gh pr view N --json comments [--jq FILTER]
#
# Returns comments array for the PR.  Handles the specific jq filter used by
# assess-and-resolve.sh to detect sharkrite-followup-issue markers:
#   '[.comments[].body | select(contains("<!-- sharkrite-followup-issue:"))] | length'
#
# This function handles ALL gh pr view calls when a jq filter is present (not
# just the sharkrite-followup-issue routing used by gh-mock-binary.sh).
# gh-mock.bash routes all pr view calls here; gh-mock-binary.sh uses the
# filter to distinguish stateful vs. fixture-backed calls.
#
# Exit: 0 always.
# ---------------------------------------------------------------------------
_gh_mock_state_pr_view() {
  local _pr_num="${1:-}"
  shift || true

  local _jq_filter="" _json_fields=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --jq)   _jq_filter="$2"; shift 2 ;;
      --json) _json_fields="$2"; shift 2 ;;
      *)      shift ;;
    esac
  done

  local _comments_file
  _comments_file=$(_gh_mock_state_comments_file)

  # Build a PR-shaped object with a comments array, as gh pr view returns
  local _pr_comments
  _pr_comments=$(jq --arg pr "$_pr_num" \
    'if has($pr) then .[$pr] else [] end' \
    "$_comments_file" 2>/dev/null || echo "[]")

  local _pr_object
  _pr_object=$(jq -n --argjson comments "$_pr_comments" '{"comments": $comments}')

  if [ -n "$_jq_filter" ]; then
    echo "$_pr_object" | jq -r "$_jq_filter" 2>/dev/null || echo "0"
  else
    echo "$_pr_object"
  fi
}
