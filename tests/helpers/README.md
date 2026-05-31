# Sharkrite Test Helpers

This directory contains test helpers and mocks for bats tests.

## Overview

- **gh-mock.bash** - Mock GitHub CLI (gh) for testing PR/issue operations
- **claude-mock.bash** - Mock Claude CLI for testing AI interactions
- **fault-injection.bash** - Fault injection harness for testing error handling
- **git-fixtures.bash** - Git repository setup and fixture helpers
- **setup.bash** - Common test setup utilities

## Fault Injection

The fault injection harness (`fault-injection.bash`) extends the mock helpers with configurable failure modes for testing error handling, retry logic, and edge cases.

### Quick Start

```bash
# In your bats test
load 'helpers/gh-mock'
load 'helpers/claude-mock'
load 'helpers/fault-injection'

setup() {
  reset_fault_injection
}

@test "handles gh rate limit" {
  inject_gh_rate_limit

  run mock_gh pr list
  [ "$status" -eq 1 ]
  [[ "$output" == *"rate limit"* ]]
}
```

### Available Fault Patterns

#### Empty Output
```bash
inject_claude_empty_output
run mock_claude --print "fix the bug"
# Returns empty response (only stream control frames, no text)
```

#### Exit Codes
```bash
# Exit 1 with stderr
inject_gh_failure_nth 1 1
run mock_gh pr view 123
[ "$status" -eq 1 ]

# Exit 5 (usage cap)
inject_gh_usage_cap
run mock_gh api /rate_limit
[ "$status" -eq 5 ]

# Exit 124 (timeout)
inject_claude_timeout
run mock_claude --print "analyze this"
[ "$status" -eq 124 ]
```

#### Rate Limit Response
```bash
inject_gh_rate_limit
run mock_gh pr list
[[ "$output" == *"API rate limit exceeded"* ]]
```

#### Command Hang
```bash
# Hang indefinitely (use timeout wrapper in test)
inject_command_hang "claude"
run timeout 1 mock_claude --print "task"
[ "$status" -eq 124 ]  # timeout exit code

# Hang for specific duration
inject_command_hang "gh" 2  # hang for 2 seconds
```

#### Nth-Call Failures (Retry Testing)
```bash
# Fail on 2nd call only
inject_gh_failure_nth 2 1

run mock_gh pr list    # succeeds
run mock_gh pr view 1  # fails (2nd call)
run mock_gh pr view 2  # succeeds (3rd call)
```

#### Custom stderr
```bash
inject_stderr_failure "gh" "API error: not found" 1
run mock_gh pr view 999
[ "$status" -eq 1 ]
[[ "$stderr" == *"not found"* ]]
```

### Reset State

Always reset fault injection state in `setup()` to avoid cross-test contamination:

```bash
setup() {
  reset_fault_injection
  # Also resets individual mocks:
  # - reset_gh_mock
  # - reset_claude_mock
}
```

### Example: Testing Retry Logic

```bash
@test "retries gh on transient failure" {
  # Fail on 1st call, succeed on 2nd
  inject_gh_failure_nth 1 1

  # Your retry logic here
  run retry_gh_command pr list

  [ "$status" -eq 0 ]  # Eventually succeeds
}
```

### Environment Variables

The harness sets these variables (you can also set them manually):

**gh-mock:**
- `GH_MOCK_FAIL_NTH` - Fail on Nth call
- `GH_MOCK_EXIT_CODE` - Exit code to return
- `GH_MOCK_FIXTURE_OVERRIDE` - Path to custom fixture
- `GH_MOCK_STDERR` - Custom stderr message
- `GH_MOCK_RATE_LIMIT` - Enable rate limit mode

**claude-mock:**
- `CLAUDE_MOCK_FAIL_NTH` - Fail on Nth call
- `CLAUDE_MOCK_EXIT_CODE` - Exit code to return
- `CLAUDE_MOCK_SCENARIO` - Scenario name (maps to fixture)
- `CLAUDE_MOCK_FIXTURE_OVERRIDE` - Path to custom fixture
- `CLAUDE_MOCK_STDERR` - Custom stderr message

**Generic:**
- `MOCK_HANG_COMMAND` - Which command to hang (gh/claude)
- `MOCK_HANG_DURATION` - How long to hang (seconds or "infinity")

### Fixture Files

Canned failure scenarios live in `tests/fixtures/faults/`:

- `gh-rate-limit.json` - Rate limit error response
- `gh-usage-cap.json` - Usage cap error (exit 5)
- `claude-empty.jsonl` - Empty output stream
- `claude-timeout.jsonl` - Partial output (simulates timeout mid-stream)

### Creating Custom Failures

```bash
# Create a custom gh error fixture
cat > tests/fixtures/faults/gh-custom-error.json <<EOF
{
  "message": "Custom error for testing",
  "documentation_url": "https://example.com"
}
EOF

# Use it in a test
export GH_MOCK_FIXTURE_OVERRIDE="${RITE_REPO_ROOT}/tests/fixtures/faults/gh-custom-error.json"
export GH_MOCK_EXIT_CODE=1
run mock_gh pr view 123
```

## Mock Helpers

### gh-mock.bash

Mock GitHub CLI operations with fixture-based responses.

```bash
load 'helpers/gh-mock'

setup() {
  GH_MOCK_FIXTURE_DIR="tests/fixtures/gh"
  reset_gh_mock
}

@test "reads PR data" {
  run mock_gh pr view 123 --json number,title
  [ "$status" -eq 0 ]

  # Fixture file: tests/fixtures/gh/pr-view-123.json
}
```

### claude-mock.bash

Mock Claude CLI with JSONL streaming responses.

```bash
load 'helpers/claude-mock'

setup() {
  CLAUDE_MOCK_FIXTURE_DIR="tests/fixtures/claude"
  reset_claude_mock
}

@test "claude generates response" {
  run mock_claude --print "Fix the bug"
  [ "$status" -eq 0 ]

  # Extract text from JSONL stream
  text=$(echo "$output" | extract_claude_text)
  [[ "$text" == *"fixed"* ]]
}
```

## Best Practices

1. **Always reset state in setup()** - Prevents cross-test contamination
2. **Use specific failure modes** - Test each error path individually
3. **Document test intent** - Comment why you're injecting each fault
4. **Test both failure and recovery** - Don't just test that it fails
5. **Use realistic fixtures** - Match actual API responses when possible
6. **Combine patterns** - Test retry logic with Nth-call failures

## See Also

- `tests/helpers/fault-injection-self-test.bats` - Examples of all patterns
- `docs/testing/` - Testing guidelines and architecture
