#!/usr/bin/env bash
# Claude CLI mock for bats tests
#
# Usage:
# 1. Set CLAUDE_MOCK_FIXTURE_DIR to the directory containing JSONL stream files
# 2. Replace 'claude' calls with 'mock_claude' in your test
# 3. Fixture files should be named: <scenario>.jsonl (one JSON object per line)
#
# Example:
#   CLAUDE_MOCK_FIXTURE_DIR="tests/fixtures/claude"
#   mock_claude --print "Fix the bug" --project ./
#   # reads from: tests/fixtures/claude/default.jsonl
#
# Fixture format (JSONL - streaming API format):
#   {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
#   {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I'll fix"}}
#   {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" the bug"}}
#   {"type":"content_block_stop","index":0}
#
# Fault injection:
#   CLAUDE_MOCK_EXIT_CODE=1    # Exit code to return
#   CLAUDE_MOCK_DELAY=0.1      # Delay between lines (simulate streaming)
#   CLAUDE_MOCK_FAIL_NTH=2     # Fail on the Nth call
#   CLAUDE_MOCK_FIXTURE_OVERRIDE=/path/to/fixture.jsonl  # Override fixture file
#   CLAUDE_MOCK_STDERR="error message"  # Custom stderr output

# Track call count for fault injection
_CLAUDE_MOCK_CALL_COUNT=0

# Mock claude CLI command
# Reads JSONL fixtures and streams them line by line
mock_claude() {
  # Increment call counter
  _CLAUDE_MOCK_CALL_COUNT=$((_CLAUDE_MOCK_CALL_COUNT + 1))

  # Fault injection: fail on Nth call
  if [ -n "${CLAUDE_MOCK_FAIL_NTH:-}" ] && [ "$_CLAUDE_MOCK_CALL_COUNT" -eq "$CLAUDE_MOCK_FAIL_NTH" ]; then
    if [ -n "${CLAUDE_MOCK_STDERR:-}" ]; then
      echo "$CLAUDE_MOCK_STDERR" >&2
    else
      echo "claude: mock failure (call #${_CLAUDE_MOCK_CALL_COUNT})" >&2
    fi
    return "${CLAUDE_MOCK_EXIT_CODE:-1}"
  fi

  # Fault injection: hang
  if [ -n "${MOCK_HANG_COMMAND:-}" ] && [ "$MOCK_HANG_COMMAND" = "claude" ]; then
    if [ "${MOCK_HANG_DURATION:-infinity}" = "infinity" ]; then
      sleep infinity
    else
      sleep "${MOCK_HANG_DURATION}"
    fi
    return 1
  fi

  # Parse args to determine scenario
  local scenario="${CLAUDE_MOCK_SCENARIO:-default}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --print)
        # Acknowledged but doesn't affect mock behavior
        shift
        ;;
      --scenario)
        scenario="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  # Determine fixture file
  local fixture_file

  # Check for fixture override first (fault injection)
  if [ -n "${CLAUDE_MOCK_FIXTURE_OVERRIDE:-}" ]; then
    fixture_file="$CLAUDE_MOCK_FIXTURE_OVERRIDE"
  else
    local fixture_dir="${CLAUDE_MOCK_FIXTURE_DIR:-${RITE_REPO_ROOT}/tests/fixtures/claude}"
    fixture_file="${fixture_dir}/${scenario}.jsonl"

    if [ ! -f "$fixture_file" ]; then
      fixture_file="${fixture_dir}/default.jsonl"
    fi
  fi

  if [ ! -f "$fixture_file" ]; then
    echo "claude mock: no fixture found for scenario '${scenario}'" >&2
    echo "Searched: ${fixture_file}" >&2
    return "${CLAUDE_MOCK_EXIT_CODE:-1}"
  fi

  # Stream the fixture file (simulating Claude's streaming API)
  local delay="${CLAUDE_MOCK_DELAY:-0}"

  while IFS= read -r line; do
    echo "$line"

    # Add delay if requested (for realistic streaming simulation)
    if [ "$delay" != "0" ]; then
      sleep "$delay"
    fi
  done < "$fixture_file"

  # Return configured exit code
  return "${CLAUDE_MOCK_EXIT_CODE:-0}"
}

# Extract text content from JSONL stream
# Usage: extract_claude_text < fixture.jsonl
extract_claude_text() {
  grep '"type":"text_delta"' | grep -o '"text":"[^"]*"' | sed 's/"text":"//;s/"$//' | tr -d '\n'
}

# Create a claude mock fixture (simple text response)
# Usage: create_claude_fixture "scenario-name" "Response text here"
create_claude_fixture() {
  local scenario="$1"
  local response_text="$2"
  local fixture_dir="${CLAUDE_MOCK_FIXTURE_DIR:-${RITE_REPO_ROOT}/tests/fixtures/claude}"

  mkdir -p "$fixture_dir"

  # Create JSONL fixture with text split into chunks (simulate streaming)
  local fixture_file="${fixture_dir}/${scenario}.jsonl"
  {
    echo '{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}'

    # Split text into words and emit deltas
    echo "$response_text" | tr ' ' '\n' | while read -r word; do
      if [ -n "$word" ]; then
        # Escape quotes in JSON
        local escaped_word="${word//\"/\\\"}"
        echo "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"${escaped_word} \"}}"
      fi
    done

    echo '{"type":"content_block_stop","index":0}'
  } > "$fixture_file"
}

# Reset mock state
reset_claude_mock() {
  _CLAUDE_MOCK_CALL_COUNT=0
  unset CLAUDE_MOCK_EXIT_CODE
  unset CLAUDE_MOCK_DELAY
  unset CLAUDE_MOCK_FAIL_NTH
  unset CLAUDE_MOCK_SCENARIO
  unset CLAUDE_MOCK_FIXTURE_OVERRIDE
  unset CLAUDE_MOCK_STDERR
}
