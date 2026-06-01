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
#     → returns data for tracked issue; empty string if not found
#   gh label create / gh label list
#     → no-op (succeed silently)
#   All other commands
#     → succeed silently (exit 0, no output)

set -euo pipefail

_issues_file="${GH_MOCK_STATE_DIR}/issues.json"
_comments_file="${GH_MOCK_STATE_DIR}/pr-comments.json"
_lag_file="${GH_MOCK_STATE_DIR}/search-lag.txt"
_next_num_file="${GH_MOCK_STATE_DIR}/next-issue-num.txt"

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
    _pr_comments=$(jq --arg pr "$_pr_num" \
      'if has($pr) then .[$pr] else [] end' "$_comments_file" 2>/dev/null || echo "[]")
    _pr_object=$(jq -n --argjson c "$_pr_comments" '{"comments":$c}')
    if [ -n "$_jq_filter" ]; then
      echo "$_pr_object" | jq -r "$_jq_filter" 2>/dev/null || echo "0"
    else
      echo "$_pr_object"
    fi
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

  _tmp_body=$(mktemp)
  [ -n "$_body_file" ] && [ -f "$_body_file" ] && cp "$_body_file" "$_tmp_body" || : > "$_tmp_body"

  jq --arg pr "$_pr_num" \
     --rawfile body "$_tmp_body" \
     'if has($pr) then .[$pr] += [{"body": $body}]
      else .[$pr] = [{"body": $body}]
      end' \
     "$_comments_file" > "${_comments_file}.tmp" \
  && mv "${_comments_file}.tmp" "$_comments_file"

  rm -f "$_tmp_body"
  exit 0
fi

# ---- gh issue list (dedup search) ----
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  _search="" _state="OPEN" _jq_filter="" _json_fields=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --search|-S) _search="$2"; shift 2 ;;
      --state)     _state=$(echo "$2" | tr '[:lower:]' '[:upper:]'); shift 2 ;;
      --json)      _json_fields="$2"; shift 2 ;;
      --jq)        _jq_filter="$2"; shift 2 ;;
      --limit)     shift 2 ;;
      *)           shift ;;
    esac
  done

  # Apply search-index lag for content searches
  if echo "$_search" | grep -qE 'in:(body|title)'; then
    _lag=$(cat "$_lag_file" 2>/dev/null || echo "0")
    [[ "$_lag" =~ ^[0-9]+$ ]] || _lag=0
    if [ "$_lag" -gt 0 ]; then
      echo $((_lag - 1)) > "$_lag_file"
      if [ -n "$_jq_filter" ]; then
        echo "[]" | jq -r "$_jq_filter" 2>/dev/null || true
      else
        echo "[]"
      fi
      exit 0
    fi
  fi

  # Build jq select expression based on search type.
  # The search term is lowercased and special regex chars are escaped so it
  # can be embedded safely in a jq `test()` expression.
  #
  # Word-boundary guard: `([^[:alnum:]_-]|$)` after the term prevents numeric
  # prefix false-positives (e.g. "src-issue:5" must not match "src-issue:55").
  # GitHub's real search uses tokenised indexing; we approximate it here with
  # a POSIX character-class negative lookahead-equivalent.
  if echo "$_search" | grep -q 'in:body'; then
    # Strip the " in:body" qualifier, trim whitespace, and remove quotes.
    _term=$(echo "$_search" | sed 's/ in:body.*//' | sed 's/^ *//' | sed 's/ *$//' | sed 's/"//g')
    _tl=$(echo "$_term" | tr '[:upper:]' '[:lower:]')
    # Escape jq regex metacharacters so the term is treated as a literal string.
    _esc=$(printf '%s' "$_tl" | sed 's/[.[\*^$()+?{}|\\]/\\&/g')
    _sel="[.[] | select((.body | ascii_downcase | test(\"${_esc}([^[:alnum:]_-]|\$)\")) and (.state == \"$_state\"))]"
  elif echo "$_search" | grep -q 'in:title'; then
    # Strip the "in:title" qualifier, trim whitespace, and remove quotes.
    _term=$(echo "$_search" | sed 's/.*in:title *//' | sed 's/ *$//' | sed 's/"//g')
    _tl=$(echo "$_term" | tr '[:upper:]' '[:lower:]')
    # Escape jq regex metacharacters so the term is treated as a literal string.
    _esc=$(printf '%s' "$_tl" | sed 's/[.[\*^$()+?{}|\\]/\\&/g')
    _sel="[.[] | select((.title | ascii_downcase | test(\"${_esc}([^[:alnum:]_-]|\$)\")) and (.state == \"$_state\"))]"
  else
    _sel="[.[] | select(.state == \"$_state\")]"
  fi

  _result=$(jq -r "$_sel" "$_issues_file" 2>/dev/null || echo "[]")

  if [ -n "$_jq_filter" ]; then
    echo "$_result" | jq -r "$_jq_filter" 2>/dev/null || true
  else
    echo "$_result"
  fi
  exit 0
fi

# ---- gh issue create ----
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  _title="" _body_file="" _label=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)     _title="$2";     shift 2 ;;
      --body-file) _body_file="$2"; shift 2 ;;
      --label)     _label="$2";     shift 2 ;;
      *)           shift ;;
    esac
  done

  _seq=$(cat "$_next_num_file" 2>/dev/null || echo "0")
  [[ "$_seq" =~ ^[0-9]+$ ]] || _seq=0
  _issue_num=$(( _seq + 1000 ))
  echo $(( _seq + 1 )) > "$_next_num_file"

  # Use rawfile so HTML comment characters are not escaped
  _tmp_body=$(mktemp)
  [ -n "$_body_file" ] && [ -f "$_body_file" ] && cp "$_body_file" "$_tmp_body" || : > "$_tmp_body"

  jq --argjson num "$_issue_num" \
     --arg title "$_title" \
     --rawfile body "$_tmp_body" \
     --arg label "$_label" \
     --arg state "OPEN" \
     '. += [{"number": $num, "title": $title, "body": $body, "label": $label, "state": $state, "url": ("https://github.com/mock/repo/issues/" + ($num | tostring))}]' \
     "$_issues_file" > "${_issues_file}.tmp" \
  && mv "${_issues_file}.tmp" "$_issues_file"

  rm -f "$_tmp_body"
  echo "https://github.com/mock/repo/issues/${_issue_num}"
  exit 0
fi

# ---- gh issue view (state check + URL/body lookup) ----
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  _issue_num="${3:-}"
  _jq_filter=""
  shift 3 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --jq)   _jq_filter="$2"; shift 2 ;;
      --json) shift 2 ;;
      *)      shift ;;
    esac
  done

  _issue=$(jq --argjson num "${_issue_num:-0}" \
    '.[] | select(.number == $num)' "$_issues_file" 2>/dev/null || true)

  if [ -z "$_issue" ]; then
    # Not in stateful store — return empty (treated as transient API failure by
    # assess-and-resolve.sh evidence-validation: preserves dedup guarantee)
    echo ""
    exit 0
  fi

  if [ -n "$_jq_filter" ]; then
    echo "$_issue" | jq -r "$_jq_filter" 2>/dev/null || true
  else
    echo "$_issue"
  fi
  exit 0
fi

# ---- gh label create / list (no-op) ----
if [ "${1:-}" = "label" ]; then
  exit 0
fi

# ---- Fallback: succeed silently ----
exit 0
