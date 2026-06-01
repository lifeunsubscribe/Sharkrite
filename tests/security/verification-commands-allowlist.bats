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

  # Stub functions that the verification code expects
  print_status() { echo "[STATUS] $*" >&2; }
  print_warning() { echo "[WARNING] $*" >&2; }
  print_success() { echo "[SUCCESS] $*" >&2; }
  print_info() { echo "[INFO] $*" >&2; }
  export -f print_status print_warning print_success print_info

  # Mock issue number (used in log output)
  issue_number="999"

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
  # We'll test it in isolation by sourcing just that section.
  # The extracted body lives inside a function in workflow-runner.sh and therefore
  # uses 'local' declarations.  Wrap it in a function definition so 'local' is
  # valid when run at the top level via 'bash verify-parser.sh'.
  {
    echo '_run_verify_check() {'
    sed -n '/# ── Pre-dev verification/,/# Call claude-workflow/p' \
      "$BATS_TEST_DIRNAME/../../lib/core/workflow-runner.sh"
    echo '}'
    echo '_run_verify_check'
  } > "$TEST_DIR/verify-parser.sh"

  # Guard: verify the extraction produced a non-empty file containing the
  # expected sentinel string from the production source.  If the comment
  # markers in workflow-runner.sh ever change, this assertion fails loudly
  # here in setup() rather than producing confusing downstream test failures.
  grep -q 'Verification Commands' "$TEST_DIR/verify-parser.sh" || {
    echo "setup() error: verify-parser.sh extraction failed or is empty — comment markers in workflow-runner.sh may have changed" >&2
    return 1
  }
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
  bash "$TEST_DIR/verify-parser.sh"

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
  bash "$TEST_DIR/verify-parser.sh"

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
  bash "$TEST_DIR/verify-parser.sh"

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
  bash "$TEST_DIR/verify-parser.sh"

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
  bash "$TEST_DIR/verify-parser.sh"

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
  bash "$TEST_DIR/verify-parser.sh"

  # Our mock npm should have been called
  [ -f "$TEST_DIR/.npm-called" ]
}

# ── Edge case: Verification Commands is the last section (issue #52/53) ────────

@test "extracts commands when Verification Commands is the last section (no trailing ##)" {
  # Regression test for issue #52/#53:
  # The original sed range /^## Verification Commands/,/^## /p requires a
  # closing ## header to terminate the range.  The replacement awk-based
  # extractor accumulates lines until EOF, so the last section works too.
  rm -f "$TEST_DIR/.pytest-called"

  # Issue body where ## Verification Commands is the LAST section — no ## after it
  ISSUE_BODY=$(cat <<'EOF'
## Description
Test issue

## Acceptance Criteria
- [ ] Test passes

## Verification Commands
```bash
pytest tests/
```
EOF
)

  export ISSUE_BODY
  export ISSUE_ALREADY_RESOLVED=false
  export TEST_DIR

  cd "$TEST_DIR"
  bash "$TEST_DIR/verify-parser.sh"

  # pytest should have been called even though there is no trailing ## header
  [ -f "$TEST_DIR/.pytest-called" ]
}

@test "extracts LAST verification block when multiple sections exist" {
  # Regression test for issue #52/#53:
  # Issues generated from assessment sometimes embed parent-issue context that
  # also contains a ## Verification Commands section.  The awk extractor resets
  # on each header match, so only the LAST block's commands are run.
  rm -f "$TEST_DIR/.pytest-called"
  rm -f "$TEST_DIR/.npm-called"

  # Issue body with TWO ## Verification Commands sections.
  # The first has "npm test" (old/inherited), the second has "pytest tests/" (current).
  # Only "pytest" from the last block should run; "npm" should NOT.
  ISSUE_BODY=$(cat <<'EOF'
## Context From Parent Issue

## Verification Commands
```bash
npm test
```

## New Description
Updated scope

## Verification Commands
```bash
pytest tests/
```
EOF
)

  export ISSUE_BODY
  export ISSUE_ALREADY_RESOLVED=false
  export TEST_DIR

  cd "$TEST_DIR"
  bash "$TEST_DIR/verify-parser.sh"

  # Only the LAST block's command (pytest) should have run
  [ -f "$TEST_DIR/.pytest-called" ]
  # npm from the first (stale) block must NOT have been called
  [ ! -f "$TEST_DIR/.npm-called" ]
}
