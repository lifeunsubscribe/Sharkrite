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
#
# Concurrency model — SEQUENTIAL ONLY for stateful writes:
#   The stateful issue-create function delegates to _gh_mock_state_issue_create
#   (from gh-mock-state.bash) which uses a read-compute-write sequence that is
#   NOT lock-protected.  All current bats tests invoke mock_gh sequentially
#   (single bats process, no parallel subshells), so the race is latent.
#   Do NOT call mock_gh issue create from parallel subshells — use
#   tests/helpers/gh-mock-binary.sh (via PATH override) for tests that require
#   concurrent gh invocations; it wraps the same sequence in flock(1) and is
#   safe for concurrent subprocess use.

# Source the shared stateful logic library.
# Derive path from this file's location so the source works regardless of
# where the test is run from.
_gh_mock_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers/gh-mock-state.bash
source "${_gh_mock_self_dir}/gh-mock-state.bash"
unset _gh_mock_self_dir

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
    # Track whether a subcommand was consumed by shift so the fallthrough
    # reconstruction can restore it.  Initialise to empty — only the issue
    # and pr branches set this before shifting.
    local _stateful_subcommand=""
    case "$command" in
      issue)
        # CONTRACT: set _stateful_subcommand BEFORE shift so the fallthrough
        # reconstruction below (set -- "$command" "$_stateful_subcommand" "$@")
        # can re-insert the subcommand into the positional args.  Any new branch
        # that calls shift MUST follow this same pattern — omitting it causes the
        # fixture lookup to receive an empty subcommand slot (e.g. "issue--42"
        # instead of "issue-edit-42"), silently failing to find the fixture.
        _stateful_subcommand="${1:-}"
        shift || true
        case "$_stateful_subcommand" in
          list)
            _gh_mock_state_issue_list "$@"
            return $?
            ;;
          create)
            _gh_mock_state_issue_create "$@"
            return $?
            ;;
          view)
            # gh issue view N --json url --jq .url
            local issue_num="${1:-}"
            _gh_mock_state_issue_view "$issue_num" "$@"
            return $?
            ;;
        esac
        ;;
      pr)
        # CONTRACT: set _stateful_subcommand BEFORE shift — same requirement as
        # the issue branch above.  See comment there for the full rationale.
        _stateful_subcommand="${1:-}"
        shift || true
        case "$_stateful_subcommand" in
          comment)
            local pr_num="${1:-}"
            shift || true
            _gh_mock_state_pr_comment "$pr_num" "$@"
            return $?
            ;;
          view)
            local pr_num="${1:-}"
            _gh_mock_state_pr_view "$pr_num" "$@"
            return $?
            ;;
        esac
        ;;
    esac
    # Unmatched command/subcommand — fall through to fixture lookup below.
    # Reconstruct the full positional args: command + subcommand (re-insert if
    # it was consumed by the shift above) + any remaining args.  Without this,
    # the fixture lookup receives $1="" instead of $1="<subcommand>", causing
    # fixture_name to be built as "issue--42" instead of "issue-edit-42".
    if [ -n "$_stateful_subcommand" ]; then
      set -- "$command" "$_stateful_subcommand" "$@"
    else
      set -- "$command" "$@"
    fi
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
# Backward-compatibility aliases — delegate to the shared library
#
# These wrappers maintain the original internal function names
# (_gh_mock_*) so any tests or code that references them directly
# continues to work.  They also expose the state file path helpers
# under the original names used in reset_gh_mock() and elsewhere.
# ------------------------------------------------------------------

# State file path aliases (original names → shared library)
_gh_mock_issues_file()   { _gh_mock_state_issues_file; }
_gh_mock_comments_file() { _gh_mock_state_comments_file; }
_gh_mock_lag_file()      { _gh_mock_state_lag_file; }
_gh_mock_next_num_file() { _gh_mock_state_next_num_file; }

# Initialization alias (original name → shared library)
# grep -rn "_gh_mock_init_state" tests/ confirms no test currently calls this
# directly, but the alias is added for consistency with the alias set above and
# to ensure forward-compatibility if any test is added that references the
# pre-deduplication name.
_gh_mock_init_state() { _gh_mock_state_init "$@"; }

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
  _gh_mock_state_init
}

# Return the number of tracked issues in stateful mode.
# Useful for assertions in tests.
gh_mock_issue_count() {
  local _issues_file
  _issues_file=$(_gh_mock_state_issues_file)
  jq 'length' "$_issues_file" 2>/dev/null || echo "0"
}

# Return the number of comments posted to a given PR in stateful mode.
# Usage: gh_mock_pr_comment_count PR_NUMBER
gh_mock_pr_comment_count() {
  local _pr_num="${1:-}"
  local _comments_file
  _comments_file=$(_gh_mock_state_comments_file)
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
  _comments_file=$(_gh_mock_state_comments_file)
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
    _gh_mock_state_init
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
