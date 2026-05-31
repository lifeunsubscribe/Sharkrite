#!/usr/bin/env bats
# Regression test for #14: Adopt gh_safe retry across all vulnerable gh calls
#
# Two failure modes this test suite covers:
#
#   1. RETRY: mock gh to return 429 once then succeed — gh_safe retries and
#      returns the successful output (caller gets data instead of empty).
#
#   2. LOUD FAILURE: mock gh to fail 3 times with 429 — gh_safe exhausts
#      retries and propagates the non-zero exit code (caller surfaces failure
#      rather than silently proceeding with empty data).
#
# Fault-injection approach: a fake `gh` binary is prepended to PATH that reads
# a "remaining failures" counter from a temp file and either emits a 429-style
# error or succeeds (outputting a JSON fixture).

setup() {
  export RITE_TEST_ROOT="${BATS_TEST_TMPDIR}/gh-safe-test"
  mkdir -p "$RITE_TEST_ROOT"

  # Create the fake-gh binary
  export FAKE_GH_DIR="$RITE_TEST_ROOT/fake-bin"
  mkdir -p "$FAKE_GH_DIR"

  # Counter file: how many failures remain before the fake gh succeeds
  export FAIL_COUNTER_FILE="$RITE_TEST_ROOT/fail-counter"

  cat > "$FAKE_GH_DIR/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Fake gh: reads FAIL_COUNTER_FILE to decide whether to fail or succeed.
# Each invocation decrements the counter by 1.
# When counter <= 0: output success JSON and exit 0.
# When counter >  0: output a 429 error to stderr and exit 1.

COUNTER_FILE="${FAIL_COUNTER_FILE:-/tmp/fail-counter}"

# Read current count (default 0 if file missing)
remaining=0
[ -f "$COUNTER_FILE" ] && remaining=$(cat "$COUNTER_FILE")

if [ "$remaining" -gt 0 ]; then
  # Decrement counter
  echo $((remaining - 1)) > "$COUNTER_FILE"
  # Emit 429-style error
  echo "rate limit exceeded: 429 Too Many Requests" >&2
  exit 1
else
  # Emit success fixture
  echo '{"number": 42, "title": "Test PR", "state": "OPEN"}'
  exit 0
fi
FAKE_GH
  chmod +x "$FAKE_GH_DIR/gh"

  # Prepend fake bin to PATH
  export PATH="$FAKE_GH_DIR:$PATH"

  # Find project root
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export GH_RETRY_SH="$PROJECT_ROOT/lib/utils/gh-retry.sh"
}

teardown() {
  rm -rf "$RITE_TEST_ROOT"
}

# ---------------------------------------------------------------------------
# Test 1: gh_safe retries once on 429 and returns the successful output
# ---------------------------------------------------------------------------
@test "gh_safe retries on 429 and succeeds after transient failure" {
  # Set fake gh to fail exactly once, then succeed
  echo "1" > "$FAIL_COUNTER_FILE"

  # Disable sleep for speed (override with env-aware backoff)
  # gh_safe sleeps 2^attempt seconds — set RITE_GH_RETRY_MAX to limit retries
  export RITE_GH_RETRY_MAX=3

  # Run gh_safe in a subshell that sources gh-retry.sh
  run bash -c "
    source '$GH_RETRY_SH'
    # Reduce backoff for test speed: override sleep command in subshell
    sleep() { :; }  # no-op sleep
    export -f sleep
    result=\$(gh_safe pr view 42 --json number,title,state 2>/dev/null || echo 'FAILED')
    echo \"\$result\"
  "

  # Should succeed (exit 0)
  [ "$status" -eq 0 ]

  # Output should contain the success JSON (number=42), not "FAILED"
  [[ "$output" =~ '"number": 42' ]] || [[ "$output" =~ '"number":42' ]]
  [[ "$output" != *"FAILED"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: gh_safe propagates failure after exhausting retries (caller sees error)
# ---------------------------------------------------------------------------
@test "gh_safe propagates failure after exhausting all retries" {
  # Set fake gh to fail 10 times (well beyond RITE_GH_RETRY_MAX)
  echo "10" > "$FAIL_COUNTER_FILE"

  export RITE_GH_RETRY_MAX=3

  # Run gh_safe — should fail after 3 retries
  run bash -c "
    source '$GH_RETRY_SH'
    # No-op sleep to keep the test fast
    sleep() { :; }
    export -f sleep
    gh_safe pr view 42 --json number,title,state 2>/dev/null
  "

  # Should fail (non-zero exit code) — caller surfaces the failure
  [ "$status" -ne 0 ]

  # Output should be empty (no data returned on failure)
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Test 3: gh_safe passes through non-transient errors immediately (no retry)
# ---------------------------------------------------------------------------
@test "gh_safe does not retry on non-transient errors (non-429 error)" {
  # Create a fake gh that fails with a non-transient error (e.g., 404)
  cat > "$FAKE_GH_DIR/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Always fail with a 404-style message (not a transient error)
echo "GraphQL: Could not resolve to a PullRequest (404 Not Found)" >&2
exit 1
FAKE_GH
  chmod +x "$FAKE_GH_DIR/gh"

  # Track how many times gh is invoked
  INVOCATION_FILE="$RITE_TEST_ROOT/invocations"
  echo "0" > "$INVOCATION_FILE"

  cat > "$FAKE_GH_DIR/gh" <<FAKE_GH
#!/usr/bin/env bash
count=\$(cat "$INVOCATION_FILE")
echo \$((count + 1)) > "$INVOCATION_FILE"
echo "GraphQL: Could not resolve to a PullRequest (404 Not Found)" >&2
exit 1
FAKE_GH
  chmod +x "$FAKE_GH_DIR/gh"

  export RITE_GH_RETRY_MAX=3

  run bash -c "
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    gh_safe pr view 9999 --json number 2>/dev/null
  "

  # Should fail
  [ "$status" -ne 0 ]

  # Should have only been called ONCE (no retries for non-transient errors)
  invocations=$(cat "$INVOCATION_FILE")
  [ "$invocations" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 4: Lint rule GH_CALL_BYPASSES_GH_SAFE detects unguarded gh calls
# ---------------------------------------------------------------------------
@test "lint rule GH_CALL_BYPASSES_GH_SAFE detects bare gh pr/issue/api calls" {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  # Create a temp script with an unguarded gh pr call
  # Put it in lib/ so the linter scans it
  LINT_TEST_DIR="$PROJECT_ROOT/lib/test-fixtures-temp-ghsafe"
  mkdir -p "$LINT_TEST_DIR"

  cat > "$LINT_TEST_DIR/unsafe-gh.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
PR_JSON=$(gh pr view 42 --json title 2>/dev/null || echo "")
echo "$PR_JSON"
EOF

  run bash -c "cd '$PROJECT_ROOT' && tools/sharkrite-lint.sh 2>&1"

  # Cleanup before assertions (always)
  rm -rf "$LINT_TEST_DIR"

  # Lint should fail with our new rule
  [ "$status" -eq 1 ]
  [[ "$output" =~ "GH_CALL_BYPASSES_GH_SAFE" ]]
  [[ "$output" =~ "unsafe-gh.sh" ]]
}

# ---------------------------------------------------------------------------
# Test 5: Lint rule passes for gh_safe-wrapped calls
# ---------------------------------------------------------------------------
@test "lint rule GH_CALL_BYPASSES_GH_SAFE does not fire for gh_safe calls" {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  # Verify no violations in the current codebase (all calls should use gh_safe)
  run bash -c "cd '$PROJECT_ROOT' && grep -rnE 'gh (pr|issue|api) [^|]*2>/dev/null \\|\\| (echo|true)' lib/ bin/ | grep -v 'gh_safe' | wc -l"

  [ "$status" -eq 0 ]
  # Should be 0 hits (trimmed)
  [ "${output// /}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 6: gh_safe is a drop-in replacement — passes all arguments through
# ---------------------------------------------------------------------------
@test "gh_safe passes all arguments verbatim to gh" {
  # Create a fake gh that captures and echoes its arguments
  cat > "$FAKE_GH_DIR/gh" <<'FAKE_GH'
#!/usr/bin/env bash
echo "args: $*"
exit 0
FAKE_GH
  chmod +x "$FAKE_GH_DIR/gh"

  run bash -c "
    source '$GH_RETRY_SH'
    gh_safe pr view 42 --json title --jq '.title'
  "

  [ "$status" -eq 0 ]
  [[ "$output" == "args: pr view 42 --json title --jq .title" ]]
}
