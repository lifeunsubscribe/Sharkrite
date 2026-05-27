#!/usr/bin/env bats
# Regression test for: Fix PIPESTATUS bugs masking provider failures
#
# Bug #2: local-review.sh:270-271 used `cmd || true` followed by
# `REVIEW_EXIT=${PIPESTATUS[0]:-$?}`. Since there's no pipeline and `|| true`
# makes $? always 0, PIPESTATUS[0] read a stale value. The exit code was
# hardcoded to 0, and all downstream error detection was dead code.
#
# Bug #3: claude.sh:98-99 and 110-111 used `pipeline || true` followed by
# `_exit_code=${PIPESTATUS[0]}`. The `|| true` runs `true` as a simple command,
# resetting PIPESTATUS to (0) before the read. Every Claude CLI failure
# (including usage cap detection) was silently swallowed.
#
# Fix: For Bug #2, capture $? directly with set +e/set -e. For Bug #3, move the
# PIPESTATUS read into the || branch: `|| _exit_code=${PIPESTATUS[0]}` so it
# reads before any other command runs.

setup() {
  # Create minimal test environment
  export RITE_TEST_ROOT="${BATS_TEST_TMPDIR}/rite-test"
  export RITE_PROJECT_ROOT="$RITE_TEST_ROOT"
  export RITE_LIB_DIR="${RITE_TEST_ROOT}/lib"
  mkdir -p "$RITE_LIB_DIR/utils"
  mkdir -p "$RITE_LIB_DIR/providers"
  mkdir -p "$RITE_LIB_DIR/core"

  # Stub config.sh
  cat > "$RITE_LIB_DIR/utils/config.sh" <<'CONFIG_EOF'
#!/bin/bash
RITE_LIB_DIR="${RITE_LIB_DIR}"
RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT}"
RITE_REVIEW_MODEL="${RITE_REVIEW_MODEL:-}"
print_info() { echo "[INFO] $*" >&2; }
print_status() { echo "[STATUS] $*" >&2; }
print_warning() { echo "[WARN] $*" >&2; }
print_error() { echo "[ERROR] $*" >&2; }
print_header() { echo "[HEADER] $*" >&2; }
RED=""; YELLOW=""; NC=""
CONFIG_EOF

  # Stub provider-interface.sh that dispatches to test stubs
  cat > "$RITE_LIB_DIR/providers/provider-interface.sh" <<'PROVIDER_EOF'
#!/bin/bash
provider_run_prompt() {
  # Call through to test stub
  "${RITE_TEST_PROVIDER_CMD}" "$@"
}
PROVIDER_EOF

  # Copy actual files from the real repo
  REAL_RITE_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  cp "${REAL_RITE_ROOT}/lib/core/local-review.sh" "$RITE_LIB_DIR/core/"
  cp "${REAL_RITE_ROOT}/lib/providers/claude.sh" "$RITE_LIB_DIR/providers/"

  # Copy dependencies for claude.sh
  cp "${REAL_RITE_ROOT}/lib/utils/run-with-timeout.sh" "$RITE_LIB_DIR/utils/" 2>/dev/null || true
}

teardown() {
  rm -rf "$RITE_TEST_ROOT"
}

# =============================================================================
# Bug #2: local-review.sh || true with PIPESTATUS
# =============================================================================

@test "local-review.sh: provider exit 1 propagates correctly (was masked by || true + stale PIPESTATUS)" {
  # Create a stub provider that exits 1 with empty output
  export RITE_TEST_PROVIDER_CMD="${RITE_TEST_ROOT}/stub-provider-fail.sh"
  cat > "$RITE_TEST_PROVIDER_CMD" <<'STUB_EOF'
#!/bin/bash
exit 1
STUB_EOF
  chmod +x "$RITE_TEST_PROVIDER_CMD"

  # Source the script
  source "$RITE_LIB_DIR/utils/config.sh"
  source "$RITE_LIB_DIR/providers/provider-interface.sh"

  # Mock dependencies
  export ISSUE_NUMBER=123
  export RITE_AUTO_MODE=true

  # Create stub detect_sensitivity_areas function
  detect_sensitivity_areas() { echo ""; }
  export -f detect_sensitivity_areas

  # Run the review script — should detect provider failure
  run bash -c "source '$RITE_LIB_DIR/core/local-review.sh'"

  # Should fail (exit 1 due to provider error)
  [ "$status" -eq 1 ]

  # Should report the actual exit code (not 0)
  [[ "$output" =~ "Review failed (exit code: 1)" ]]
}

@test "local-review.sh: provider exit 5 (usage cap) propagates correctly" {
  # Create a stub provider that exits 5 (usage cap)
  export RITE_TEST_PROVIDER_CMD="${RITE_TEST_ROOT}/stub-provider-cap.sh"
  cat > "$RITE_TEST_PROVIDER_CMD" <<'STUB_EOF'
#!/bin/bash
echo "Usage cap exceeded" >&2
exit 5
STUB_EOF
  chmod +x "$RITE_TEST_PROVIDER_CMD"

  # Source the script
  source "$RITE_LIB_DIR/utils/config.sh"
  source "$RITE_LIB_DIR/providers/provider-interface.sh"

  # Mock dependencies
  export ISSUE_NUMBER=123
  export RITE_AUTO_MODE=true

  # Create stub detect_sensitivity_areas function
  detect_sensitivity_areas() { echo ""; }
  export -f detect_sensitivity_areas

  # Run the review script — should detect exit 5
  run bash -c "source '$RITE_LIB_DIR/core/local-review.sh'"

  # Should fail
  [ "$status" -eq 1 ]

  # Should report exit code 5 (not 0)
  [[ "$output" =~ "Review failed (exit code: 5)" ]]
}

# =============================================================================
# Bug #3: claude.sh || true clobbering PIPESTATUS
# =============================================================================

@test "claude.sh: pipeline failure exit 1 propagates correctly (was masked by || true)" {
  # Test the actual claude provider code path

  # Create a stub claude command that exits 1
  export RITE_TEST_CLAUDE_CMD="${RITE_TEST_ROOT}/stub-claude-fail"
  cat > "$RITE_TEST_CLAUDE_CMD" <<'STUB_EOF'
#!/bin/bash
exit 1
STUB_EOF
  chmod +x "$RITE_TEST_CLAUDE_CMD"

  # Create stub run_with_timeout that just runs the command
  cat > "$RITE_LIB_DIR/utils/run-with-timeout.sh" <<'TIMEOUT_EOF'
#!/bin/bash
run_with_timeout() {
  local timeout="$1"
  shift
  "$@"
}
TIMEOUT_EOF

  # Source claude provider
  source "$RITE_LIB_DIR/utils/config.sh"
  export CLAUDE_PROVIDER_CMD="$RITE_TEST_CLAUDE_CMD"
  export RITE_DEV_MODEL="test-model"
  source "$RITE_LIB_DIR/utils/run-with-timeout.sh"
  source "$RITE_LIB_DIR/providers/claude.sh"

  # Run claude_provider_run_session — should detect failure
  run claude_provider_run_session "test prompt" 300 "test-model" true

  # Should fail with exit code 1 (not 0)
  [ "$status" -eq 1 ]
}

@test "claude.sh: pipeline failure exit 5 (usage cap) propagates correctly" {
  # Create a stub claude command that exits 5
  export RITE_TEST_CLAUDE_CMD="${RITE_TEST_ROOT}/stub-claude-cap"
  cat > "$RITE_TEST_CLAUDE_CMD" <<'STUB_EOF'
#!/bin/bash
exit 5
STUB_EOF
  chmod +x "$RITE_TEST_CLAUDE_CMD"

  # Create stub run_with_timeout
  cat > "$RITE_LIB_DIR/utils/run-with-timeout.sh" <<'TIMEOUT_EOF'
#!/bin/bash
run_with_timeout() {
  local timeout="$1"
  shift
  "$@"
}
TIMEOUT_EOF

  # Source claude provider
  source "$RITE_LIB_DIR/utils/config.sh"
  export CLAUDE_PROVIDER_CMD="$RITE_TEST_CLAUDE_CMD"
  export RITE_DEV_MODEL="test-model"
  source "$RITE_LIB_DIR/utils/run-with-timeout.sh"
  source "$RITE_LIB_DIR/providers/claude.sh"

  # Run claude_provider_run_session — should detect exit 5
  run claude_provider_run_session "test prompt" 300 "test-model" true

  # Should fail with exit code 5 (not 0)
  [ "$status" -eq 5 ]
}

@test "claude.sh: pipeline success (exit 0) works correctly" {
  # Create a stub claude command that succeeds
  export RITE_TEST_CLAUDE_CMD="${RITE_TEST_ROOT}/stub-claude-ok"
  cat > "$RITE_TEST_CLAUDE_CMD" <<'STUB_EOF'
#!/bin/bash
echo "Success output"
exit 0
STUB_EOF
  chmod +x "$RITE_TEST_CLAUDE_CMD"

  # Create stub run_with_timeout
  cat > "$RITE_LIB_DIR/utils/run-with-timeout.sh" <<'TIMEOUT_EOF'
#!/bin/bash
run_with_timeout() {
  local timeout="$1"
  shift
  "$@"
}
TIMEOUT_EOF

  # Source claude provider
  source "$RITE_LIB_DIR/utils/config.sh"
  export CLAUDE_PROVIDER_CMD="$RITE_TEST_CLAUDE_CMD"
  export RITE_DEV_MODEL="test-model"
  source "$RITE_LIB_DIR/utils/run-with-timeout.sh"
  source "$RITE_LIB_DIR/providers/claude.sh"

  # Run claude_provider_run_session — should succeed
  run claude_provider_run_session "test prompt" 300 "test-model" true

  # Should succeed
  [ "$status" -eq 0 ]
}
