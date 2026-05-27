#!/usr/bin/env bats
# Security tests for verification commands allowlist (no eval)

setup() {
  # Create temp directory for test files
  TEST_DIR=$(mktemp -d)
  CANARY_PREFIX="/tmp/rite-rce-canary"

  # Source the workflow runner to get phase_pre_start_checks
  RITE_LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
  RITE_PROJECT_ROOT="$TEST_DIR"

  # Mock dependencies
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  source "$RITE_LIB_DIR/utils/notifications.sh" 2>/dev/null || true

  # Create mock commands in PATH
  MOCK_BIN="$TEST_DIR/bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"

  # Mock pytest - creates a marker file when called
  cat > "$MOCK_BIN/pytest" <<'EOF'
#!/bin/bash
touch "$TEST_DIR/.pytest-called"
exit 0
EOF
  chmod +x "$MOCK_BIN/pytest"

  # Mock npm - creates a marker file when called
  cat > "$MOCK_BIN/npm" <<'EOF'
#!/bin/bash
touch "$TEST_DIR/.npm-called"
exit 0
EOF
  chmod +x "$MOCK_BIN/npm"

  # Mock gh (GitHub CLI)
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$MOCK_BIN/gh"

  # Extract and source the verification command parser function
  # We'll test it in isolation by sourcing just that section
  sed -n '/# ── Pre-dev verification/,/# Call claude-workflow/p' \
    "$BATS_TEST_DIRNAME/../../lib/core/workflow-runner.sh" > "$TEST_DIR/verify-parser.sh"
}

teardown() {
  # Clean up canary files
  rm -f ${CANARY_PREFIX}-*
  rm -rf "$TEST_DIR"
}

# Helper to create a synthetic issue body with verification commands
create_issue_body() {
  local commands="$1"
  cat <<EOF
## Description
Test issue

## Verification Commands
\`\`\`bash
$commands
\`\`\`

## Acceptance Criteria
- [ ] Test passes
EOF
}

@test "rejects RCE attempt: touch /tmp/rite-rce-canary" {
  CANARY_FILE="${CANARY_PREFIX}-$$"

  # Create issue body with RCE payload
  ISSUE_BODY=$(create_issue_body "touch $CANARY_FILE")

  # The parser should reject the command (touch not in allowlist)
  # Even if somehow executed, canary should NOT be created

  # Source verification section with mocked ISSUE_BODY
  export ISSUE_BODY
  export ISSUE_ALREADY_RESOLVED=false

  # Run the verification check (should skip touch command)
  cd "$TEST_DIR"
  bash -c "$(cat "$TEST_DIR/verify-parser.sh")" || true

  # Canary file should NOT exist
  [ ! -f "$CANARY_FILE" ]
}

@test "rejects command injection: pytest; touch /tmp/canary" {
  CANARY_FILE="${CANARY_PREFIX}-semicolon-$$"

  # Semicolon should be rejected by token validation
  ISSUE_BODY=$(create_issue_body "pytest; touch $CANARY_FILE")

  export ISSUE_BODY
  export ISSUE_ALREADY_RESOLVED=false

  cd "$TEST_DIR"
  bash -c "$(cat "$TEST_DIR/verify-parser.sh")" || true

  # Canary should NOT exist (semicolon rejected)
  [ ! -f "$CANARY_FILE" ]
}

@test "rejects command chaining: pytest && rm -rf /tmp/x" {
  CANARY_DIR="${CANARY_PREFIX}-dir-$$"
  mkdir -p "$CANARY_DIR"

  # Double-ampersand should be rejected
  ISSUE_BODY=$(create_issue_body "pytest && rm -rf $CANARY_DIR")

  export ISSUE_BODY
  export ISSUE_ALREADY_RESOLVED=false

  cd "$TEST_DIR"
  bash -c "$(cat "$TEST_DIR/verify-parser.sh")" || true

  # Directory should still exist (rm not executed)
  [ -d "$CANARY_DIR" ]
  rm -rf "$CANARY_DIR"
}

@test "rejects command substitution: pytest \$(touch /tmp/canary)" {
  CANARY_FILE="${CANARY_PREFIX}-subst-$$"

  # Command substitution $() should be rejected
  ISSUE_BODY=$(create_issue_body "pytest \$(touch $CANARY_FILE)")

  export ISSUE_BODY
  export ISSUE_ALREADY_RESOLVED=false

  cd "$TEST_DIR"
  bash -c "$(cat "$TEST_DIR/verify-parser.sh")" || true

  # Canary should NOT exist (parentheses rejected)
  [ ! -f "$CANARY_FILE" ]
}

@test "allows legitimate pytest command" {
  # Clean slate
  rm -f "$TEST_DIR/.pytest-called"

  ISSUE_BODY=$(create_issue_body "pytest tests/")

  export ISSUE_BODY
  export ISSUE_ALREADY_RESOLVED=false
  export TEST_DIR

  cd "$TEST_DIR"
  bash -c "$(cat "$TEST_DIR/verify-parser.sh")" || true

  # Our mock pytest should have been called
  [ -f "$TEST_DIR/.pytest-called" ]
}

@test "allows legitimate npm test command" {
  # Clean slate
  rm -f "$TEST_DIR/.npm-called"

  ISSUE_BODY=$(create_issue_body "npm test")

  export ISSUE_BODY
  export ISSUE_ALREADY_RESOLVED=false
  export TEST_DIR

  cd "$TEST_DIR"
  bash -c "$(cat "$TEST_DIR/verify-parser.sh")" || true

  # Our mock npm should have been called
  [ -f "$TEST_DIR/.npm-called" ]
}
