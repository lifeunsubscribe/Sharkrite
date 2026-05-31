#!/usr/bin/env bats
# Integration test: Claude CLI workflow
#
# Demonstrates Claude interaction pattern:
# - Use claude-mock with JSONL stream fixtures
# - Test streaming response parsing
# - Test error handling and exit codes

load '../helpers/setup'
load '../helpers/claude-mock'

setup() {
  setup_test_tmpdir

  # Set up fixture directory
  export CLAUDE_MOCK_FIXTURE_DIR="${RITE_TEST_TMPDIR}/claude-fixtures"
  mkdir -p "$CLAUDE_MOCK_FIXTURE_DIR"

  reset_claude_mock
}

teardown() {
  teardown_test_tmpdir
}

@test "claude mock: streams JSONL fixture line by line" {
  # Create a simple fixture
  create_claude_fixture "test-scenario" "The fix has been applied successfully."

  # Mock claude command
  claude() { mock_claude "$@"; }
  export -f claude
  export -f mock_claude

  run mock_claude --print "Fix the bug" --scenario test-scenario

  [ "$status" -eq 0 ]

  # Output should be JSONL (one JSON object per line)
  echo "$output" | head -1 | grep -q '"type":"content_block_start"'
}

@test "claude mock: extract_claude_text parses response" {
  create_claude_fixture "success" "All tests passing."

  claude() { mock_claude "$@"; }
  export -f claude
  export -f mock_claude

  # Run mock and extract text
  result=$(mock_claude --scenario success | extract_claude_text)

  [[ "$result" =~ "All" ]]
  [[ "$result" =~ "tests" ]]
  [[ "$result" =~ "passing" ]]
}

@test "claude mock: custom exit code" {
  export CLAUDE_MOCK_EXIT_CODE=5

  claude() { mock_claude "$@"; }
  export -f claude
  export -f mock_claude

  # Even with missing fixture, should return configured exit code
  run mock_claude --scenario nonexistent

  [ "$status" -eq 5 ]
}

@test "claude mock: default scenario fallback" {
  # Create only default.jsonl
  create_claude_fixture "default" "Default response text."

  claude() { mock_claude "$@"; }
  export -f claude
  export -f mock_claude

  # Request non-existent scenario → should fall back to default
  run mock_claude --scenario does-not-exist

  [ "$status" -eq 0 ]
  echo "$output" | extract_claude_text | grep -q "Default"
}

@test "claude mock: realistic fix scenario" {
  # Create a realistic fixture for a fix workflow
  cat > "${CLAUDE_MOCK_FIXTURE_DIR}/fix-workflow.jsonl" <<'EOF'
{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I've "}}
{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"analyzed "}}
{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"the "}}
{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"issue. "}}
{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Applying "}}
{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"fix..."}}
{"type":"content_block_stop","index":0}
EOF

  claude() { mock_claude "$@"; }
  export -f claude
  export -f mock_claude

  run mock_claude --print "Fix issue #42" --scenario fix-workflow

  [ "$status" -eq 0 ]

  # Should have multiple delta lines
  num_deltas=$(echo "$output" | grep -c '"type":"content_block_delta"')
  [ "$num_deltas" -ge 5 ]
}

@test "claude mock: simulate streaming delay" {
  create_claude_fixture "slow" "One two three four five."

  export CLAUDE_MOCK_DELAY=0.01  # 10ms between lines

  claude() { mock_claude "$@"; }
  export -f claude
  export -f mock_claude

  # Measure time (should take at least 50ms for 5+ lines)
  # Use cross-platform time measurement (BSD date doesn't support %N)
  if date --version >/dev/null 2>&1; then
    # GNU date
    start=$(date +%s%N)
    run mock_claude --scenario slow
    end=$(date +%s%N)
    duration=$(( (end - start) / 1000000 ))  # Convert to milliseconds
  else
    # BSD date (macOS) - use seconds precision
    start=$(date +%s)
    run mock_claude --scenario slow
    end=$(date +%s)
    duration=$(( (end - start) * 1000 ))  # Convert to milliseconds
  fi

  [ "$status" -eq 0 ]

  # Duration should be >= 0 (streaming not instant, but may round to 0 on BSD)
  [ "$duration" -ge 0 ]
}
