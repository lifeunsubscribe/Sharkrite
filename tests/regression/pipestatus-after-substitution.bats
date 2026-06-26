#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-review-issues.sh
# Regression test for: Fix PIPESTATUS bugs masking provider failures
#
# Bug: assess-review-issues.sh (supervised mode) used PIPESTATUS[0]
# after a pipeline inside $() command substitution. PIPESTATUS doesn't survive
# subshells, so the read captured a stale value from the outer shell, not the
# actual provider exit code. This masked all provider failures in supervised mode.
#
# Fix: Use the temp-file pattern (same as auto mode): capture the exit
# code via `echo $? > temp_file` inside the pipeline, then read it back after
# the subshell completes.
#
# assess-review-issues.sh is a top-level executable script, NOT a function
# library. Its positional contract is:
#     assess-review-issues.sh PR_NUMBER REVIEW_FILE [--auto]
# These tests invoke it directly (supervised mode = omit --auto) and assert the
# provider's exit code is correctly propagated.

setup() {
  # Create minimal test environment
  export RITE_TEST_ROOT="${BATS_TEST_TMPDIR}/rite-test"
  export RITE_PROJECT_ROOT="$RITE_TEST_ROOT"
  export RITE_LIB_DIR="${RITE_TEST_ROOT}/lib"
  mkdir -p "$RITE_LIB_DIR/utils"
  mkdir -p "$RITE_LIB_DIR/providers"
  mkdir -p "$RITE_LIB_DIR/core"

  # The script's source guard (line 28: `if [ -z "${RITE_LIB_DIR:-}" ]`) skips
  # sourcing config.sh because RITE_LIB_DIR is already exported above. Export the
  # config values the script reads under `set -u` directly so they are defined.
  export RITE_DATA_DIR=".rite"
  export RITE_INSTALL_DIR="${RITE_TEST_ROOT}/install"
  export RITE_REVIEW_MODEL="claude-opus-4-8"
  export RITE_ASSESSMENT_MODEL=""
  export RITE_REVIEW_PROVIDER="claude"

  # Stub config.sh — provides config vars + print functions.
  cat > "$RITE_LIB_DIR/utils/config.sh" <<'CONFIG_EOF'
#!/bin/bash
RITE_LIB_DIR="${RITE_LIB_DIR}"
RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT}"
RITE_ASSESSMENT_TIMEOUT="${RITE_ASSESSMENT_TIMEOUT:-180}"
RITE_ASSESSMENT_MODEL="${RITE_ASSESSMENT_MODEL:-}"
RITE_REVIEW_MODEL="${RITE_REVIEW_MODEL:-claude-opus-4-8}"
RITE_REVIEW_PROVIDER="${RITE_REVIEW_PROVIDER:-claude}"
RITE_INSTALL_DIR="${RITE_INSTALL_DIR:-$RITE_TEST_ROOT/install}"
RITE_DATA_DIR="${RITE_DATA_DIR:-.rite}"
print_info() { echo "[INFO] $*" >&2; }
print_status() { echo "[STATUS] $*" >&2; }
print_success() { echo "[SUCCESS] $*" >&2; }
print_warning() { echo "[WARN] $*" >&2; }
print_error() { echo "[ERROR] $*" >&2; }
print_header() { echo "[HEADER] $*" >&2; }
CONFIG_EOF

  # Stub colors.sh — define color symbols the source references.
  cat > "$RITE_LIB_DIR/utils/colors.sh" <<'COLORS_EOF'
#!/bin/bash
BLUE=""; GREEN=""; RED=""; YELLOW=""; NC=""
COLORS_EOF

  # Stub logging.sh — _timer_start/_timer_end no-ops.
  cat > "$RITE_LIB_DIR/utils/logging.sh" <<'LOGGING_EOF'
#!/bin/bash
_timer_start() { :; }
_timer_end() { :; }
_diag() { :; }
LOGGING_EOF

  # Stub labels.sh — ensure_labels_exist no-op.
  cat > "$RITE_LIB_DIR/utils/labels.sh" <<'LABELS_EOF'
#!/bin/bash
ensure_labels_exist() { :; }
LABELS_EOF

  # Stub date-helpers.sh — iso_to_epoch returns a fixed epoch.
  cat > "$RITE_LIB_DIR/utils/date-helpers.sh" <<'DATE_EOF'
#!/bin/bash
iso_to_epoch() { echo 0; }
DATE_EOF

  # Stub markers.sh — assessment + source-issue markers.
  cat > "$RITE_LIB_DIR/utils/markers.sh" <<'MARKERS_EOF'
#!/bin/bash
RITE_MARKER_ASSESSMENT="sharkrite-assessment"
RITE_MARKER_SOURCE_ISSUE="sharkrite-source-issue"
MARKERS_EOF

  # Stub pr-detection.sh — gh_safe (no network), commit-time helper, regex.
  cat > "$RITE_LIB_DIR/utils/pr-detection.sh" <<'PRDETECT_EOF'
#!/bin/bash
CLOSING_ISSUE_GREP_REGEX='(Closes|closes|Fixes|fixes|Resolves|resolves) #[0-9]+'
# gh_safe: stand in for the gh wrapper. Returns empty so freshness/ledger/issue
# lookups all no-op (no prior assessment, no linked issue, no duplicates).
gh_safe() { return 0; }
# get_latest_work_commit_time: leave LATEST_COMMIT_TIME empty so the freshness
# check bails to "run fresh".
get_latest_work_commit_time() { LATEST_COMMIT_TIME=""; }
PRDETECT_EOF

  # Stub provider-interface.sh — route provider calls to the per-test stub.
  cat > "$RITE_LIB_DIR/providers/provider-interface.sh" <<'PROVIDER_EOF'
#!/bin/bash
load_provider() { :; }
provider_name() { echo "test-provider"; }
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

  # Supervised mode = omit --auto. Positional contract: PR_NUMBER REVIEW_FILE.
  export RITE_AUTO_MODE=false
  run bash "$RITE_LIB_DIR/core/assess-review-issues.sh" "123" "$REVIEW_FILE"

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

  # Supervised mode = omit --auto.
  export RITE_AUTO_MODE=false
  run bash "$RITE_LIB_DIR/core/assess-review-issues.sh" "123" "$REVIEW_FILE"

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

  # Supervised mode = omit --auto.
  export RITE_AUTO_MODE=false
  run bash "$RITE_LIB_DIR/core/assess-review-issues.sh" "123" "$REVIEW_FILE"

  # Should succeed
  [ "$status" -eq 0 ]

  # Should output the assessment classification
  [[ "$output" =~ "ACTIONABLE_NOW" ]]
}
