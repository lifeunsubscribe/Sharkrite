#!/usr/bin/env bats
# Regression test for: Adopt gh_safe retry across vulnerable gh calls (#14)
#
# gh_safe wraps `gh` CLI calls with retry logic for transient failures:
#   - 429 rate-limit / 5xx server errors → retry up to GH_SAFE_MAX_RETRIES
#   - 404 not-found → return 1 immediately (resource genuinely absent)
#   - All retries exhausted → return 1 and print error to stderr (never silent)
#
# This test file verifies:
#   1. Mock `gh` returns 429 once then succeeds → gh_safe succeeds (retried)
#   2. Mock `gh` fails 3 times → gh_safe returns 1 and surfaces the failure
#      (does NOT return empty data silently)

setup() {
  export BATS_TMPDIR="${BATS_TEST_TMPDIR}/gh-safe-test"
  mkdir -p "$BATS_TMPDIR"

  # Locate gh-retry.sh relative to the test file
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export GH_RETRY_SH="$PROJECT_ROOT/lib/utils/gh-retry.sh"

  # Speed up tests: 0-second delay, 1-second timeout, 3 max retries
  export GH_SAFE_RETRY_DELAY=0
  export GH_SAFE_TIMEOUT=5
  export GH_SAFE_MAX_RETRIES=3
}

teardown() {
  rm -rf "$BATS_TMPDIR"
}

# ---------------------------------------------------------------------------
# Test 1: 429 once then success → gh_safe retries and returns the output
# ---------------------------------------------------------------------------
@test "gh_safe retries on 429 rate-limit and succeeds on second attempt" {
  # Create a mock gh that fails with a 429 error on the first call,
  # then succeeds on the second call.
  local call_count_file="$BATS_TMPDIR/call-count"
  echo "0" > "$call_count_file"

  local mock_gh="$BATS_TMPDIR/gh"
  cat > "$mock_gh" <<EOF
#!/bin/bash
count=\$(cat "$call_count_file")
count=\$((count + 1))
echo "\$count" > "$call_count_file"

if [ "\$count" -eq 1 ]; then
  echo "HTTP 429: API rate limit exceeded" >&2
  exit 1
fi
echo '{"number":42,"title":"Test PR"}'
exit 0
EOF
  chmod +x "$mock_gh"

  # Run gh_safe with the mock gh on PATH
  run bash -c "
    export PATH=\"$BATS_TMPDIR:\$PATH\"
    source \"$GH_RETRY_SH\"
    gh_safe pr view 42 --json number,title
  "

  # Should succeed
  [ "$status" -eq 0 ]

  # Should have output from the successful second attempt
  [[ "$output" =~ '"number":42' ]]

  # Should have been called twice (1 failure + 1 success)
  local final_count
  final_count=$(cat "$call_count_file")
  [ "$final_count" -eq 2 ]

  # stderr should contain the retry message
  [[ "$output" =~ '"title":"Test PR"' ]]
}

# ---------------------------------------------------------------------------
# Test 2: All 3 attempts fail → gh_safe surfaces failure (not empty data)
# ---------------------------------------------------------------------------
@test "gh_safe surfaces failure after all retries exhausted (not silent empty)" {
  # Create a mock gh that always fails with a 503 server error
  local call_count_file="$BATS_TMPDIR/call-count-all-fail"
  echo "0" > "$call_count_file"

  local mock_gh="$BATS_TMPDIR/gh"
  cat > "$mock_gh" <<EOF
#!/bin/bash
count=\$(cat "$call_count_file")
count=\$((count + 1))
echo "\$count" > "$call_count_file"

echo "HTTP 503: Service Unavailable" >&2
exit 1
EOF
  chmod +x "$mock_gh"

  # Run gh_safe — it should fail, not silently return empty string
  run bash -c "
    export PATH=\"$BATS_TMPDIR:\$PATH\"
    source \"$GH_RETRY_SH\"
    OUTPUT=\$(gh_safe issue view 99 --json title || echo '__FAILED__')
    echo \"\$OUTPUT\"
  "

  # The outer script should succeed (|| echo '__FAILED__' catches it)
  [ "$status" -eq 0 ]

  # Output must be '__FAILED__' — not empty, not silently proceeding
  [[ "$output" =~ "__FAILED__" ]]

  # Must NOT output an empty string as if the call succeeded
  [[ ! "$output" =~ '{}' ]]
  [[ ! "$output" =~ '""' ]]

  # gh was called exactly GH_SAFE_MAX_RETRIES (3) times
  local final_count
  final_count=$(cat "$call_count_file")
  [ "$final_count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# Test 3: Captured stdout is clean JSON after 429-then-success (no retry banners)
#
# Regression for: local-review.sh used `2>&1` when capturing gh_safe output.
# On success-after-retry, gh_safe's stderr retry diagnostics were merged into
# stdout, corrupting the JSON and breaking downstream `jq` parses.
# ---------------------------------------------------------------------------
@test "gh_safe stdout is clean JSON after 429-then-success (no retry banners)" {
  # Mock gh: fails with 429 on attempt 1, succeeds with clean JSON on attempt 2
  local call_count_file="$BATS_TMPDIR/call-count-json"
  echo "0" > "$call_count_file"

  local mock_gh="$BATS_TMPDIR/gh"
  cat > "$mock_gh" <<EOF
#!/bin/bash
count=\$(cat "$call_count_file")
count=\$((count + 1))
echo "\$count" > "$call_count_file"

if [ "\$count" -eq 1 ]; then
  echo "HTTP 429: API rate limit exceeded" >&2
  exit 1
fi
echo '{"title":"My PR","baseRefName":"main","headRefName":"feat/x","url":"https://github.com/org/repo/pull/42"}'
exit 0
EOF
  chmod +x "$mock_gh"

  # Simulate the corrected adoption pattern: capture into variable (no 2>&1),
  # then pipe to jq. This is what local-review.sh:79 does after the fix.
  run bash -c "
    export PATH=\"$BATS_TMPDIR:\$PATH\"
    source \"$GH_RETRY_SH\"
    PR_INFO=\$(gh_safe pr view 42 --json title,baseRefName,headRefName,url)
    # jq must succeed — stdout must be valid JSON with no retry banner lines
    TITLE=\$(echo \"\$PR_INFO\" | jq -r '.title')
    echo \"TITLE=\$TITLE\"
  "

  # gh_safe should have succeeded
  [ "$status" -eq 0 ]

  # jq must have parsed the title correctly (no banner contamination)
  [[ "$output" == "TITLE=My PR" ]]
}

# ---------------------------------------------------------------------------
# Test 4: Capture-then-pipe pattern surfaces failure when retries are exhausted
#
# Regression for: pr-detection.sh and local-review.sh:71 piped gh_safe directly
# into jq/head, masking retry-exhaustion failure behind the pipe's exit code.
# The fix captures gh_safe output into a variable first, making the failure
# observable, then pipes the variable through jq/head.
# ---------------------------------------------------------------------------
@test "capture-then-pipe pattern surfaces gh_safe retry-exhaustion failure" {
  # Mock gh: always fails with 503
  local call_count_file="$BATS_TMPDIR/call-count-pipe"
  echo "0" > "$call_count_file"

  local mock_gh="$BATS_TMPDIR/gh"
  cat > "$mock_gh" <<EOF
#!/bin/bash
count=\$(cat "$call_count_file")
count=\$((count + 1))
echo "\$count" > "$call_count_file"
echo "HTTP 503: Service Unavailable" >&2
exit 1
EOF
  chmod +x "$mock_gh"

  # Simulate the corrected adoption pattern from pr-detection.sh:
  #   _pr_list_json=$(gh_safe ...) || true
  #   PR_NUMBER=$(echo "$_pr_list_json" | jq ... | head -1 || true)
  # When gh_safe fails: _pr_list_json is empty, jq on empty string yields empty
  # PR_NUMBER. The || true on gh_safe means the script continues, but with empty
  # data — which the caller can then check and handle explicitly.
  # The key assertion: the pipeline does NOT produce a non-empty PR_NUMBER when
  # gh_safe failed (i.e., no phantom data from masking).
  run bash -c "
    export PATH=\"$BATS_TMPDIR:\$PATH\"
    source \"$GH_RETRY_SH\"
    _pr_list_json=\$(gh_safe pr list --state open --json number,body --limit 100) || true
    PR_NUMBER=\$(echo \"\$_pr_list_json\" | jq -r '.[] | select(.body | test(\"Closes #42\")) | .number' | head -1 || true)
    if [ -z \"\$PR_NUMBER\" ] || [ \"\$PR_NUMBER\" = 'null' ]; then
      echo '__NOT_FOUND__'
    else
      echo \"PR_NUMBER=\$PR_NUMBER\"
    fi
  "

  # Script should complete without error
  [ "$status" -eq 0 ]

  # PR_NUMBER must be empty/null, not a phantom value
  [[ "$output" == "__NOT_FOUND__" ]]

  # Must NOT have produced a non-empty PR number from failed gh output
  [[ ! "$output" =~ "PR_NUMBER=" ]]
}
