#!/usr/bin/env bats
# Regression test for: Fix PIPESTATUS bugs masking provider failures
#
# Bug: assess-review-issues.sh:632-633 (supervised mode) used PIPESTATUS[0]
# after a pipeline inside $() command substitution. PIPESTATUS doesn't survive
# subshells, so the read captured a stale value from the outer shell, not the
# actual provider exit code. This masked all provider failures in supervised mode.
#
# Fix: Use the temp-file pattern (same as line 568 auto mode): capture the exit
# code via `echo $? > temp_file` inside the pipeline, then read it back after
# the subshell completes.

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
RITE_ASSESSMENT_TIMEOUT="${RITE_ASSESSMENT_TIMEOUT:-180}"
RITE_ASSESSMENT_MODEL="${RITE_ASSESSMENT_MODEL:-}"
print_info() { echo "[INFO] $*" >&2; }
print_status() { echo "[STATUS] $*" >&2; }
print_warning() { echo "[WARN] $*" >&2; }
print_error() { echo "[ERROR] $*" >&2; }
print_header() { echo "[HEADER] $*" >&2; }
RED=""; YELLOW=""; NC=""
CONFIG_EOF

  # Stub provider-interface.sh
  cat > "$RITE_LIB_DIR/providers/provider-interface.sh" <<'PROVIDER_EOF'
#!/bin/bash
provider_run_prompt() {
  # Call through to test stub
  "${RITE_TEST_PROVIDER_CMD}" "$@"
}
provider_run_prompt_with_timeout() {
  # Call through to test stub
  "${RITE_TEST_PROVIDER_CMD}" "$@"
}
provider_detect_error() {
  echo "UNKNOWN_ERROR"
}
PROVIDER_EOF

  # Copy actual assess-review-issues.sh from the real repo
  REAL_RITE_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  cp "${REAL_RITE_ROOT}/lib/core/assess-review-issues.sh" "$RITE_LIB_DIR/core/"
}

teardown() {
  rm -rf "$RITE_TEST_ROOT"
}

@test "supervised mode: provider exit 1 propagates correctly (was masked by stale PIPESTATUS)" {
  # Create a stub provider that exits 1 with empty output
  export RITE_TEST_PROVIDER_CMD="${RITE_TEST_ROOT}/stub-provider-fail.sh"
  cat > "$RITE_TEST_PROVIDER_CMD" <<'STUB_EOF'
#!/bin/bash
exit 1
STUB_EOF
  chmod +x "$RITE_TEST_PROVIDER_CMD"

  # Mock a review content file
  REVIEW_FILE="${RITE_TEST_ROOT}/review.md"
  cat > "$REVIEW_FILE" <<'REVIEW_EOF'
# Review

### Item 1 - ACTIONABLE_NOW
Something bad.
REVIEW_EOF

  # Source the script and run in supervised mode (RITE_AUTO_MODE=false)
  export RITE_AUTO_MODE=false
  source "$RITE_LIB_DIR/utils/config.sh"
  source "$RITE_LIB_DIR/providers/provider-interface.sh"
  source "$RITE_LIB_DIR/core/assess-review-issues.sh"

  # Run assess_review_issues — should detect the provider failure
  run assess_review_issues "$REVIEW_FILE" "123" "/tmp/test-wt"

  # Should fail (exit 1 due to provider error detection)
  [ "$status" -eq 1 ]

  # Should report the actual exit code (not 0)
  [[ "$output" =~ "Provider exited with code 1" ]]
}

@test "supervised mode: provider exit 5 (usage cap) propagates correctly" {
  # Create a stub provider that exits 5 (usage cap) with stderr content
  export RITE_TEST_PROVIDER_CMD="${RITE_TEST_ROOT}/stub-provider-cap.sh"
  cat > "$RITE_TEST_PROVIDER_CMD" <<'STUB_EOF'
#!/bin/bash
echo "Usage cap exceeded" >&2
exit 5
STUB_EOF
  chmod +x "$RITE_TEST_PROVIDER_CMD"

  # Mock a review content file
  REVIEW_FILE="${RITE_TEST_ROOT}/review.md"
  cat > "$REVIEW_FILE" <<'REVIEW_EOF'
# Review

### Item 1 - ACTIONABLE_NOW
Something bad.
REVIEW_EOF

  # Source the script and run in supervised mode
  export RITE_AUTO_MODE=false
  source "$RITE_LIB_DIR/utils/config.sh"
  source "$RITE_LIB_DIR/providers/provider-interface.sh"
  source "$RITE_LIB_DIR/core/assess-review-issues.sh"

  # Run assess_review_issues — should detect exit 5
  run assess_review_issues "$REVIEW_FILE" "123" "/tmp/test-wt"

  # Should fail
  [ "$status" -eq 1 ]

  # Should report exit code 5 (not 0)
  [[ "$output" =~ "Provider exited with code 5" ]]
}

@test "supervised mode: provider success (exit 0) works correctly" {
  # Create a stub provider that succeeds with valid output
  export RITE_TEST_PROVIDER_CMD="${RITE_TEST_ROOT}/stub-provider-ok.sh"
  cat > "$RITE_TEST_PROVIDER_CMD" <<'STUB_EOF'
#!/bin/bash
echo "ACTIONABLE_NOW"
echo ""
echo "### Item 1 - ACTIONABLE_NOW"
echo "Fix this thing."
exit 0
STUB_EOF
  chmod +x "$RITE_TEST_PROVIDER_CMD"

  # Mock a review content file
  REVIEW_FILE="${RITE_TEST_ROOT}/review.md"
  cat > "$REVIEW_FILE" <<'REVIEW_EOF'
# Review

### Item 1 - ACTIONABLE_NOW
Something bad.
REVIEW_EOF

  # Source the script and run in supervised mode
  export RITE_AUTO_MODE=false
  source "$RITE_LIB_DIR/utils/config.sh"
  source "$RITE_LIB_DIR/providers/provider-interface.sh"
  source "$RITE_LIB_DIR/core/assess-review-issues.sh"

  # Run assess_review_issues — should succeed
  run assess_review_issues "$REVIEW_FILE" "123" "/tmp/test-wt"

  # Should succeed
  [ "$status" -eq 0 ]

  # Should output the assessment classification
  [[ "$output" =~ "ACTIONABLE_NOW" ]]
}
