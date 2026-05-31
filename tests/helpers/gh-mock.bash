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
    echo "gh: mock failure (call #${_GH_MOCK_CALL_COUNT})" >&2
    return "${GH_MOCK_EXIT_CODE:-1}"
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

# Reset mock state (call in test setup)
reset_gh_mock() {
  _GH_MOCK_CALL_COUNT=0
  unset GH_MOCK_FAIL_NTH
  unset GH_MOCK_EXIT_CODE
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
