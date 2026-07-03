#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh
# Test suite for issue #8: Make empty Claude assessment fail loud, not
#
# Verifies that empty assessment output (transient API failure) causes a loud
# failure (exit 1) rather than silently falling back to heuristic filter that
# returns NO_ACTIONABLE_ITEMS and allows merge without proper assessment.

setup() {
  # Source utils for color codes and print functions
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "${RITE_LIB_DIR}/utils/config.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  # Mock PR environment
  export PR_NUMBER=42
  export ISSUE_NUMBER=8
  export AUTO_MODE=true

  # Create a mock review file
  export MOCK_REVIEW_FILE=$(mktemp)
  cat > "$MOCK_REVIEW_FILE" <<'EOF'
## Code Review Summary

**Findings: CRITICAL: 1 | HIGH: 2 | MEDIUM: 1 | LOW: 0**

### Issues
CRITICAL: Missing input validation
HIGH: Insufficient error handling
HIGH: SQL injection risk
MEDIUM: Missing error messages
EOF

  # Create a mock provider directory
  export MOCK_PROVIDER_DIR=$(mktemp -d)
  export PATH="$MOCK_PROVIDER_DIR:$PATH"

  # Mock the Claude CLI command (what the provider actually calls)
  cat > "$MOCK_PROVIDER_DIR/claude" <<'MOCK_EOF'
#!/bin/bash
# Mock claude CLI that returns empty stdout with exit 0 (simulates transient API failure)
echo "" # Empty output
exit 0
MOCK_EOF
  chmod +x "$MOCK_PROVIDER_DIR/claude"

  # Mock gh command to avoid GitHub API calls
  cat > "$MOCK_PROVIDER_DIR/gh" <<'MOCK_EOF'
#!/bin/bash
# Mock gh - handle pr view commands that assess-review-issues.sh calls
case "$1" in
  pr)
    case "$2" in
      view)
        # Return empty JSON for PR body and comments
        echo '{"body":"Closes #8","comments":[]}'
        ;;
      comment)
        # Silently succeed
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  issue)
    case "$2" in
      view)
        # Return minimal issue details
        echo "Issue #8: Test Issue

Test issue body"
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
MOCK_EOF
  chmod +x "$MOCK_PROVIDER_DIR/gh"
}

teardown() {
  rm -f "$MOCK_REVIEW_FILE"
  rm -rf "$MOCK_PROVIDER_DIR"
}

# Test that empty assessment output causes exit 1, not silent NO_ACTIONABLE_ITEMS
@test "assess-review-issues.sh: empty assessment output fails loud (exit 1)" {
  # The mock claude command (from setup) returns empty output
  # Run assess-review-issues.sh and expect it to exit 1 (not 0)
  run bash "${RITE_LIB_DIR}/core/assess-review-issues.sh" "$PR_NUMBER" "$MOCK_REVIEW_FILE" --auto

  # Should fail (exit 1)
  [ "$status" -eq 1 ]

  # Should NOT output NO_ACTIONABLE_ITEMS
  [[ "$output" != *"NO_ACTIONABLE_ITEMS"* ]]

  # Should output error about empty assessment
  [[ "$output" =~ "empty output after" ]]
}

# Test that the script retries on empty output before failing
@test "assess-review-issues.sh: retries empty assessment before failing" {
  # Create a counter file to track retry attempts
  ATTEMPT_COUNTER=$(mktemp)
  echo "0" > "$ATTEMPT_COUNTER"

  # Create a custom mock claude that counts attempts
  cat > "$MOCK_PROVIDER_DIR/claude" <<RETRY_MOCK
#!/bin/bash
# Mock claude that counts attempts and always returns empty
COUNT=\$(cat "$ATTEMPT_COUNTER")
COUNT=\$((COUNT + 1))
echo "\$COUNT" > "$ATTEMPT_COUNTER"
echo ''  # Always return empty
exit 0
RETRY_MOCK
  chmod +x "$MOCK_PROVIDER_DIR/claude"

  run bash "${RITE_LIB_DIR}/core/assess-review-issues.sh" "$PR_NUMBER" "$MOCK_REVIEW_FILE" --auto

  # Should have attempted 2 times (MAX_ASSESSMENT_ATTEMPTS=2)
  ATTEMPTS=$(cat "$ATTEMPT_COUNTER")
  [ "$ATTEMPTS" -eq 2 ]

  # Should mention retry in output
  [[ "$output" =~ "attempt 1/2" ]]

  # Clean up
  rm -f "$ATTEMPT_COUNTER"
}

# Test that non-empty assessment succeeds
@test "assess-review-issues.sh: non-empty assessment succeeds" {
  # Create a mock claude that returns valid assessment
  cat > "$MOCK_PROVIDER_DIR/claude" <<'SUCCESS_MOCK'
#!/bin/bash
# Mock claude that returns valid assessment
cat <<'ASSESSMENT_EOF'
### Input Validation Missing - ACTIONABLE_NOW

**Severity:** HIGH
**Category:** Security
**Reasoning:** The user input is not validated before processing.
**Context:** Within PR scope.
**Location:** lib/core/assess-review-issues.sh
**Fix Effort:** <10min

### Documentation Outdated - DISMISSED

**Severity:** LOW
**Category:** Standards
**Reasoning:** Not critical for this PR.
**Context:** Out of scope.
ASSESSMENT_EOF
exit 0
SUCCESS_MOCK
  chmod +x "$MOCK_PROVIDER_DIR/claude"

  run bash "${RITE_LIB_DIR}/core/assess-review-issues.sh" "$PR_NUMBER" "$MOCK_REVIEW_FILE" --auto

  # Should succeed (exit 0)
  [ "$status" -eq 0 ]

  # Should contain assessment output
  [[ "$output" =~ "ACTIONABLE_NOW" ]]
}

# Test that non-zero exit codes fail immediately without retry
@test "assess-review-issues.sh: non-zero exit fails immediately (no retry)" {
  ATTEMPT_COUNTER=$(mktemp)
  echo "0" > "$ATTEMPT_COUNTER"

  # Create a mock claude that exits with error and counts attempts
  cat > "$MOCK_PROVIDER_DIR/claude" <<ERROR_MOCK
#!/bin/bash
# Mock claude that returns exit 1 and counts attempts
COUNT=\$(cat "$ATTEMPT_COUNTER")
COUNT=\$((COUNT + 1))
echo "\$COUNT" > "$ATTEMPT_COUNTER"
echo 'Error: Rate limited' >&2
exit 1  # Non-zero exit
ERROR_MOCK
  chmod +x "$MOCK_PROVIDER_DIR/claude"

  run bash "${RITE_LIB_DIR}/core/assess-review-issues.sh" "$PR_NUMBER" "$MOCK_REVIEW_FILE" --auto

  # Should fail
  [ "$status" -eq 1 ]

  # Should have attempted only ONCE (no retry on non-zero exit)
  ATTEMPTS=$(cat "$ATTEMPT_COUNTER")
  [ "$ATTEMPTS" -eq 1 ]

  # Should mention error
  [[ "$output" =~ "Provider exited with code 1" ]]

  # Clean up
  rm -f "$ATTEMPT_COUNTER"
}
