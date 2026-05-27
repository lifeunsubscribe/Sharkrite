#!/usr/bin/env bats
# Test suite for issue #8: Make empty Claude assessment fail loud, not
#
# Verifies that empty assessment output (transient API failure) causes a loud
# failure (exit 1) rather than silently falling back to heuristic filter that
# returns NO_ACTIONABLE_ITEMS and allows merge without proper assessment.

setup() {
  # Source utils for color codes and print functions
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "${RITE_LIB_DIR}/utils/config.sh"

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

  # Create a mock provider that returns empty output
  export MOCK_PROVIDER_DIR=$(mktemp -d)
  export PATH="$MOCK_PROVIDER_DIR:$PATH"

  # Mock provider_run_prompt_with_timeout to return empty output
  cat > "$MOCK_PROVIDER_DIR/provider_run_prompt_with_timeout" <<'MOCK_EOF'
#!/bin/bash
# Mock provider that returns empty stdout with exit 0 (simulates transient API failure)
echo "" # Empty output
exit 0
MOCK_EOF
  chmod +x "$MOCK_PROVIDER_DIR/provider_run_prompt_with_timeout"

  # Mock gh command
  cat > "$MOCK_PROVIDER_DIR/gh" <<'MOCK_EOF'
#!/bin/bash
# Mock gh to avoid GitHub API calls
exit 0
MOCK_EOF
  chmod +x "$MOCK_PROVIDER_DIR/gh"
}

teardown() {
  rm -f "$MOCK_REVIEW_FILE"
  rm -rf "$MOCK_PROVIDER_DIR"
}

# Test that empty assessment output causes exit 1, not silent NO_ACTIONABLE_ITEMS
@test "assess-review-issues.sh: empty assessment output fails loud (exit 1)" {
  # Mock the provider interface functions to return empty output
  provider_run_prompt_with_timeout() {
    echo ""  # Empty output (transient API failure)
    return 0
  }
  provider_detect_error() {
    echo "UNKNOWN"
    return 1
  }
  export -f provider_run_prompt_with_timeout
  export -f provider_detect_error

  # Run assess-review-issues.sh and expect it to exit 1 (not 0)
  run bash -c "
    source '${RITE_LIB_DIR}/utils/config.sh'
    export PR_NUMBER=42
    export ISSUE_NUMBER=8
    export AUTO_MODE=true

    # Mock functions
    provider_run_prompt_with_timeout() { echo ''; return 0; }
    provider_detect_error() { echo 'UNKNOWN'; return 1; }
    export -f provider_run_prompt_with_timeout
    export -f provider_detect_error

    # Mock check_assessment_freshness to return empty (no cached assessment)
    check_assessment_freshness() { return 1; }
    export -f check_assessment_freshness

    # Run the assessment with review content
    REVIEW_CONTENT=\$(cat '$MOCK_REVIEW_FILE')
    export REVIEW_CONTENT

    # This should exit 1, not 0
    bash '${RITE_LIB_DIR}/core/assess-review-issues.sh' '$PR_NUMBER'
  "

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
  export ATTEMPT_COUNTER=$(mktemp)
  echo "0" > "$ATTEMPT_COUNTER"

  run bash -c "
    source '${RITE_LIB_DIR}/utils/config.sh'
    export PR_NUMBER=42
    export ISSUE_NUMBER=8
    export AUTO_MODE=true
    export ATTEMPT_COUNTER='$ATTEMPT_COUNTER'

    # Mock provider that counts attempts
    provider_run_prompt_with_timeout() {
      COUNT=\$(cat \"\$ATTEMPT_COUNTER\")
      COUNT=\$((COUNT + 1))
      echo \"\$COUNT\" > \"\$ATTEMPT_COUNTER\"
      echo ''  # Always return empty
      return 0
    }
    provider_detect_error() { echo 'UNKNOWN'; return 1; }
    check_assessment_freshness() { return 1; }

    export -f provider_run_prompt_with_timeout
    export -f provider_detect_error
    export -f check_assessment_freshness

    REVIEW_CONTENT=\$(cat '$MOCK_REVIEW_FILE')
    export REVIEW_CONTENT

    bash '${RITE_LIB_DIR}/core/assess-review-issues.sh' '$PR_NUMBER' 2>&1
  "

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
  run bash -c "
    source '${RITE_LIB_DIR}/utils/config.sh'
    export PR_NUMBER=42
    export ISSUE_NUMBER=8
    export AUTO_MODE=true

    # Mock provider that returns valid assessment
    provider_run_prompt_with_timeout() {
      cat <<'ASSESSMENT_EOF'
### Input Validation Missing - ACTIONABLE_NOW
Severity: HIGH
The user input is not validated before processing.

### Documentation Outdated - DISMISSED
Severity: LOW
Not critical for this PR.
ASSESSMENT_EOF
      return 0
    }
    provider_detect_error() { echo 'UNKNOWN'; return 1; }
    check_assessment_freshness() { return 1; }

    export -f provider_run_prompt_with_timeout
    export -f provider_detect_error
    export -f check_assessment_freshness

    REVIEW_CONTENT=\$(cat '$MOCK_REVIEW_FILE')
    export REVIEW_CONTENT

    # Mock gh pr comment to avoid GitHub API
    gh() { return 0; }
    export -f gh

    bash '${RITE_LIB_DIR}/core/assess-review-issues.sh' '$PR_NUMBER' 2>&1
  "

  # Should succeed (exit 0)
  [ "$status" -eq 0 ]

  # Should contain assessment output
  [[ "$output" =~ "ACTIONABLE_NOW" ]]
}

# Test that non-zero exit codes fail immediately without retry
@test "assess-review-issues.sh: non-zero exit fails immediately (no retry)" {
  export ATTEMPT_COUNTER=$(mktemp)
  echo "0" > "$ATTEMPT_COUNTER"

  run bash -c "
    source '${RITE_LIB_DIR}/utils/config.sh'
    export PR_NUMBER=42
    export ISSUE_NUMBER=8
    export AUTO_MODE=true
    export ATTEMPT_COUNTER='$ATTEMPT_COUNTER'

    # Mock provider that returns exit 1 and counts attempts
    provider_run_prompt_with_timeout() {
      COUNT=\$(cat \"\$ATTEMPT_COUNTER\")
      COUNT=\$((COUNT + 1))
      echo \"\$COUNT\" > \"\$ATTEMPT_COUNTER\"
      echo ''
      return 1  # Non-zero exit
    }
    provider_detect_error() { echo 'RATE_LIMITED'; return 0; }
    check_assessment_freshness() { return 1; }

    export -f provider_run_prompt_with_timeout
    export -f provider_detect_error
    export -f check_assessment_freshness

    REVIEW_CONTENT=\$(cat '$MOCK_REVIEW_FILE')
    export REVIEW_CONTENT

    bash '${RITE_LIB_DIR}/core/assess-review-issues.sh' '$PR_NUMBER' 2>&1
  "

  # Should fail
  [ "$status" -eq 1 ]

  # Should have attempted only ONCE (no retry on non-zero exit)
  ATTEMPTS=$(cat "$ATTEMPT_COUNTER")
  [ "$ATTEMPTS" -eq 1 ]

  # Should mention the error type
  [[ "$output" =~ "RATE_LIMITED" ]]

  # Clean up
  rm -f "$ATTEMPT_COUNTER"
}
