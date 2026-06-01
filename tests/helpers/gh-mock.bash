#!/usr/bin/env bash
# GitHub CLI (gh) mock for bats tests
#
# Usage:
# 1. Set GH_MOCK_FIXTURE_DIR to the directory containing JSON response files
# 2. Replace 'gh' calls with 'mock_gh' in your test
# 3. Fixture files should be named: <command>-<scenario>.json
#
# Example:
#   GH_MOCK_FIXTURE_DIR="tests/fixtures/gh"
#   mock_gh pr view 123 --json number,title
#   # reads from: tests/fixtures/gh/pr-view-123.json
#
# Fault injection:
#   GH_MOCK_FAIL_NTH=2  # Fail on the 2nd call
#   GH_MOCK_EXIT_CODE=1 # Exit code to return on failure
#
# Stateful deduplication mode (opt-in):
#   Set GH_MOCK_STATE_DIR to a writable temp directory before calling
#   setup_gh_mock_state.  Once active, mock_gh handles the gh commands used
#   by assess-and-resolve.sh's dedup logic with real state instead of static
#   fixtures:
#
#     gh issue list --search "... in:body"   → searches tracked issues by body
#     gh issue list --search "in:title ..."  → searches tracked issues by title
#     gh issue create --title T --body-file F → records issue, returns URL
#     gh pr comment N --body-file F           → records comment on PR N
#     gh pr view N --json comments --jq ...   → returns tracked PR comments
#     gh issue view N --json url --jq .url    → returns URL for tracked issue
#
#   Eventual consistency simulation:
#     GH_MOCK_ISSUE_INDEX_LAG=N  (default 0) — the first N body/title searches
#     after an issue is created return empty results, simulating GitHub's search
#     index lag.  Each search attempt decrements the counter; once it reaches 0
#     the issue appears in results.

# Track call count for fault injection
_GH_MOCK_CALL_COUNT=0

# Mock gh CLI command
# Reads JSON fixtures based on command + args
mock_gh() {
  local command="$1"
  shift

  # Increment call counter
  _GH_MOCK_CALL_COUNT=$((_GH_MOCK_CALL_COUNT + 1))

  # Fault injection: fail on Nth call
  if [ -n "${GH_MOCK_FAIL_NTH:-}" ] && [ "$_GH_MOCK_CALL_COUNT" -eq "$GH_MOCK_FAIL_NTH" ]; then
    if [ -n "${GH_MOCK_STDERR:-}" ]; then
      echo "$GH_MOCK_STDERR" >&2
    else
      echo "gh: mock failure (call #${_GH_MOCK_CALL_COUNT})" >&2
    fi
    return "${GH_MOCK_EXIT_CODE:-1}"
  fi

  # Fault injection: rate limit or usage cap (fixture override)
  if [ -n "${GH_MOCK_FIXTURE_OVERRIDE:-}" ]; then
    if [ -f "$GH_MOCK_FIXTURE_OVERRIDE" ]; then
      cat "$GH_MOCK_FIXTURE_OVERRIDE"
      return "${GH_MOCK_EXIT_CODE:-0}"
    fi
  fi

  # Fault injection: hang
  if [ -n "${MOCK_HANG_COMMAND:-}" ] && [ "$MOCK_HANG_COMMAND" = "gh" ]; then
    if [ "${MOCK_HANG_DURATION:-infinity}" = "infinity" ]; then
      sleep infinity
    else
      sleep "${MOCK_HANG_DURATION}"
    fi
    return 1
  fi

  # ------------------------------------------------------------------
  # Stateful deduplication mode
  #
  # When GH_MOCK_STATE_DIR is set and the directory exists, handle the
  # gh commands used by assess-and-resolve.sh dedup logic with live
  # state.  Any command not matched here falls through to fixture lookup.
  # ------------------------------------------------------------------
  if [ -n "${GH_MOCK_STATE_DIR:-}" ] && [ -d "${GH_MOCK_STATE_DIR}" ]; then
    case "$command" in
      issue)
        local subcommand="${1:-}"
        shift || true
        case "$subcommand" in
          list)
            _gh_mock_stateful_issue_list "$@"
            return $?
            ;;
          create)
            _gh_mock_stateful_issue_create "$@"
            return $?
            ;;
          view)
            # gh issue view N --json url --jq .url
            local issue_num="${1:-}"
            _gh_mock_stateful_issue_view "$issue_num" "$@"
            return $?
            ;;
        esac
        ;;
      pr)
        local subcommand="${1:-}"
        shift || true
        case "$subcommand" in
          comment)
            local pr_num="${1:-}"
            shift || true
            _gh_mock_stateful_pr_comment "$pr_num" "$@"
            return $?
            ;;
          view)
            local pr_num="${1:-}"
            _gh_mock_stateful_pr_view "$pr_num" "$@"
            return $?
            ;;
        esac
        ;;
    esac
    # Note: unmatched commands fall through to fixture lookup below
    # Restore command for fixture path — reconstruct args array
    set -- "$command" "$@"
    command="$1"
    shift
  fi

  # Determine fixture file based on command
  local fixture_name
  case "$command" in
    pr)
      local subcommand="$1"
      local identifier="${2:-default}"
      fixture_name="pr-${subcommand}-${identifier}"
      ;;
    issue)
      local subcommand="$1"
      local identifier="${2:-default}"
      fixture_name="issue-${subcommand}-${identifier}"
      ;;
    api)
      # For API calls, use the endpoint path
      local endpoint="$1"
      # Convert repos/owner/repo/pulls/123 → api-pulls-123
      fixture_name="api-$(echo "$endpoint" | sed 's|/|-|g' | sed 's|repos-[^-]*-[^-]*-||')"
      ;;
    *)
      fixture_name="${command}-default"
      ;;
  esac

  # Look for fixture file
  local fixture_dir="${GH_MOCK_FIXTURE_DIR:-${RITE_REPO_ROOT}/tests/fixtures/gh}"
  local fixture_file="${fixture_dir}/${fixture_name}.json"

  if [ ! -f "$fixture_file" ]; then
    # If specific fixture doesn't exist, try fallback
    fixture_file="${fixture_dir}/${command}-default.json"
  fi

  if [ -f "$fixture_file" ]; then
    cat "$fixture_file"
  else
    echo "gh mock: no fixture found for '${fixture_name}' or '${command}-default'" >&2
    echo "Searched in: ${fixture_dir}" >&2
    return 1
  fi
}

# ------------------------------------------------------------------
# Stateful deduplication helpers (used internally by mock_gh)
# ------------------------------------------------------------------

# State file paths (relative to GH_MOCK_STATE_DIR)
_gh_mock_issues_file()   { echo "${GH_MOCK_STATE_DIR}/issues.json"; }
_gh_mock_comments_file() { echo "${GH_MOCK_STATE_DIR}/pr-comments.json"; }
_gh_mock_lag_file()      { echo "${GH_MOCK_STATE_DIR}/search-lag.txt"; }
_gh_mock_next_num_file() { echo "${GH_MOCK_STATE_DIR}/next-issue-num.txt"; }

# Initialize stateful mode state files.
# Called by setup_gh_mock_state (below); also safe to call in test setup.
_gh_mock_init_state() {
  echo "[]"  > "$(_gh_mock_issues_file)"
  echo "{}"  > "$(_gh_mock_comments_file)"
  echo "0"   > "$(_gh_mock_next_num_file)"
  # Seed index lag counter (0 = no lag, N = N searches before issue is visible)
  echo "${GH_MOCK_ISSUE_INDEX_LAG:-0}" > "$(_gh_mock_lag_file)"
}

# gh issue list --search "..." [--state ...] [--json ...] [--jq ...]
#
# Simulates the two search patterns used by assess-and-resolve.sh:
#   in:body  → match substring in issue body (primary dedup search)
#   in:title → match substring in issue title (fallback dedup search)
#
# Handles search-index lag: if GH_MOCK_ISSUE_INDEX_LAG > 0 was set at state
# init time, the first N body/title searches return empty JSON arrays.
_gh_mock_stateful_issue_list() {
  local _search="" _state="open" _jq_filter="" _json_fields=""

  # Parse flags (mirroring the flags used by assess-and-resolve.sh)
  while [ $# -gt 0 ]; do
    case "$1" in
      --search|-S) _search="$2"; shift 2 ;;
      --state)     _state="$2";  shift 2 ;;
      --json)      _json_fields="$2"; shift 2 ;;
      --jq)        _jq_filter="$2"; shift 2 ;;
      --limit)     shift 2 ;;   # accepted but unused in mock
      *)           shift ;;
    esac
  done

  # Normalize state to uppercase so it matches the stored "OPEN"/"CLOSED" values.
  # assess-and-resolve.sh passes --state open (lowercase); the real API and our
  # stored state use uppercase ("OPEN") to match select(.state == "OPEN") at
  # assess-and-resolve.sh:1143.
  _state=$(echo "$_state" | tr '[:lower:]' '[:upper:]')

  local _issues_file
  _issues_file=$(_gh_mock_issues_file)

  # Apply search-index lag: decrement counter; return empty while counter > 0.
  # Only applied to content searches (in:body / in:title) — not other list calls.
  if echo "$_search" | grep -qE 'in:(body|title)'; then
    local _lag_file
    _lag_file=$(_gh_mock_lag_file)
    local _lag
    _lag=$(cat "$_lag_file" 2>/dev/null || echo "0")
    # Guard against empty or non-numeric content (e.g. truncated write) to
    # prevent "integer expression expected" under bats' set -e.
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
  local _jq_select
  if echo "$_search" | grep -q 'in:body'; then
    # Extract the marker/term before " in:body"
    local _term
    _term=$(echo "$_search" | sed 's/ in:body.*//' | sed 's/^ *//' | sed 's/ *$//')
    local _term_lower
    _term_lower=$(echo "$_term" | tr '[:upper:]' '[:lower:]')
    local _escaped_term
    _escaped_term=$(printf '%s' "$_term_lower" | sed 's/[.[\*^$()+?{}|\\]/\\&/g')
    _jq_select="[.[] | select((.body | ascii_downcase | test(\"${_escaped_term}([^[:alnum:]_-]|\$)\")) and (.state == \"$_state\"))]"
  elif echo "$_search" | grep -q 'in:title'; then
    # Extract the term after "in:title "
    local _term
    _term=$(echo "$_search" | sed 's/.*in:title *//' | sed 's/ *$//')
    local _term_lower
    _term_lower=$(echo "$_term" | tr '[:upper:]' '[:lower:]')
    local _escaped_term
    _escaped_term=$(printf '%s' "$_term_lower" | sed 's/[.[\*^$()+?{}|\\]/\\&/g')
    _jq_select="[.[] | select((.title | ascii_downcase | test(\"${_escaped_term}([^[:alnum:]_-]|\$)\")) and (.state == \"$_state\"))]"
  else
    # No in: qualifier — return all open issues
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

# gh issue create --title T --body-file F [--label L]
#
# Records the issue in state and returns a GitHub-style URL.
# Issue numbers start at 1000 + sequential counter to avoid collisions
# with fixture-based issue numbers.
#
# Uses jq --rawfile (not --arg) to read the body so that HTML comment
# characters (e.g. <!-- -->) are not escaped as <\!-- by macOS jq 1.7.x.
_gh_mock_stateful_issue_create() {
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
    _body_source="$_tmp_body_file"
    : > "$_body_source"   # empty body
  fi

  # Assign sequential issue number
  local _num_file
  _num_file=$(_gh_mock_next_num_file)
  local _seq
  _seq=$(cat "$_num_file" 2>/dev/null || echo "0")
  # Guard against empty or non-numeric content to prevent arithmetic errors.
  [[ "$_seq" =~ ^[0-9]+$ ]] || _seq=0
  local _issue_num=$(( _seq + 1000 ))
  echo $(( _seq + 1 )) > "$_num_file"

  local _issues_file
  _issues_file=$(_gh_mock_issues_file)

  # Append the new issue to the tracked list
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
  # index-lag scenario that assess-and-resolve.sh's retry loop (lines 1128-1167)
  # guards against.  The counter is a global budget shared across all creates
  # in a test; it is seeded once in _gh_mock_init_state and decremented by each
  # content search until exhausted.

  echo "https://github.com/mock/repo/issues/${_issue_num}"
}

# gh issue view N --json url --jq .url
#
# Returns the URL for a tracked issue.  Returns failure (exit 1) if the issue
# is not in the stateful store — there is no fixture fallback for this command.
_gh_mock_stateful_issue_view() {
  local _issue_num="${1:-}"
  shift || true

  # Parse flags (particularly --jq)
  local _jq_filter="" _json_fields=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --jq)   _jq_filter="$2"; shift 2 ;;
      --json) _json_fields="$2"; shift 2 ;;
      *)      shift ;;
    esac
  done

  local _issues_file
  _issues_file=$(_gh_mock_issues_file)

  local _issue
  _issue=$(jq --argjson num "${_issue_num:-0}" \
    '.[] | select(.number == $num)' \
    "$_issues_file" 2>/dev/null || true)

  if [ -z "$_issue" ]; then
    # Not in state — return failure immediately.  The caller in mock_gh does
    # `return $?` so this exits before any fixture lookup; there is no fixture
    # fallback for stateful issue view.  Callers should use `|| true` to handle
    # the not-found case gracefully.
    echo "gh mock: issue ${_issue_num} not in stateful store" >&2
    return 1
  fi

  if [ -n "$_jq_filter" ]; then
    echo "$_issue" | jq -r "$_jq_filter" 2>/dev/null || true
  else
    echo "$_issue"
  fi
}

# gh pr comment N --body-file F
#
# Records a comment on the PR in state.
#
# Uses jq --rawfile (not --arg) to read the body so that HTML comment
# characters (e.g. <!-- -->) are not escaped as <\!-- by macOS jq 1.7.x.
# The assess-and-resolve.sh dedup logic posts marker comments containing
# <!-- sharkrite-followup-issue:N --> and then checks for them via
# `contains("<!-- sharkrite-followup-issue:")` — this only works correctly
# when the stored body is not escaped.
_gh_mock_stateful_pr_comment() {
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
    _body_source="$_tmp_body_file"
    : > "$_body_source"
  fi

  local _comments_file
  _comments_file=$(_gh_mock_comments_file)

  # Append comment to the PR's comment list
  jq --arg pr "$_pr_num" \
     --rawfile body "$_body_source" \
     'if has($pr) then .[$pr] += [{"body": $body}]
      else .[$pr] = [{"body": $body}]
      end' \
     "$_comments_file" > "${_comments_file}.tmp" && mv "${_comments_file}.tmp" "$_comments_file"

  [ -n "$_tmp_body_file" ] && rm -f "$_tmp_body_file" || true
}

# gh pr view N --json comments [--jq FILTER]
#
# Returns comments array for the PR.  Handles the specific jq filter used by
# assess-and-resolve.sh to detect sharkrite-followup-issue markers:
#   '[.comments[].body | select(contains("<!-- sharkrite-followup-issue:"))] | length'
_gh_mock_stateful_pr_view() {
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
  _comments_file=$(_gh_mock_comments_file)

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

# ------------------------------------------------------------------
# Public API for stateful deduplication mode
# ------------------------------------------------------------------

# Initialize stateful gh mock state in GH_MOCK_STATE_DIR.
# Call this in test setup() after setting GH_MOCK_STATE_DIR.
#
# Optional: set GH_MOCK_ISSUE_INDEX_LAG=N before calling to simulate
# GitHub search-index lag (N searches return empty before issue appears).
setup_gh_mock_state() {
  if [ -z "${GH_MOCK_STATE_DIR:-}" ]; then
    echo "gh-mock: GH_MOCK_STATE_DIR must be set before calling setup_gh_mock_state" >&2
    return 1
  fi
  mkdir -p "$GH_MOCK_STATE_DIR"
  _gh_mock_init_state
}

# Return the number of tracked issues in stateful mode.
# Useful for assertions in tests.
gh_mock_issue_count() {
  local _issues_file
  _issues_file=$(_gh_mock_issues_file)
  jq 'length' "$_issues_file" 2>/dev/null || echo "0"
}

# Return the number of comments posted to a given PR in stateful mode.
# Usage: gh_mock_pr_comment_count PR_NUMBER
gh_mock_pr_comment_count() {
  local _pr_num="${1:-}"
  local _comments_file
  _comments_file=$(_gh_mock_comments_file)
  jq --arg pr "$_pr_num" \
    'if has($pr) then .[$pr] | length else 0 end' \
    "$_comments_file" 2>/dev/null || echo "0"
}

# Return the body of the Nth comment on a given PR (0-indexed).
# Usage: gh_mock_pr_comment_body PR_NUMBER INDEX
gh_mock_pr_comment_body() {
  local _pr_num="${1:-}"
  local _index="${2:-0}"
  local _comments_file
  _comments_file=$(_gh_mock_comments_file)
  jq -r --arg pr "$_pr_num" --argjson idx "$_index" \
    'if has($pr) then .[$pr][$idx].body // "" else "" end' \
    "$_comments_file" 2>/dev/null || true
}

# Reset mock state (call in test setup)
reset_gh_mock() {
  _GH_MOCK_CALL_COUNT=0
  unset GH_MOCK_FAIL_NTH
  unset GH_MOCK_EXIT_CODE
  unset GH_MOCK_FIXTURE_OVERRIDE
  unset GH_MOCK_STDERR
  unset GH_MOCK_RATE_LIMIT
  # Reinitialize stateful mode if active
  if [ -n "${GH_MOCK_STATE_DIR:-}" ] && [ -d "${GH_MOCK_STATE_DIR}" ]; then
    _gh_mock_init_state
  fi
}

# Create a gh mock fixture file
# Usage: create_gh_fixture "pr-view-123" '{"number": 123, "title": "Test PR"}'
create_gh_fixture() {
  local fixture_name="$1"
  local json_content="$2"
  local fixture_dir="${GH_MOCK_FIXTURE_DIR:-${RITE_REPO_ROOT}/tests/fixtures/gh}"

  mkdir -p "$fixture_dir"
  echo "$json_content" > "${fixture_dir}/${fixture_name}.json"
}
