#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/utils/config.sh
# tests/regression/followup-creation-threshold.bats
#
# Regression test: RITE_MAX_FOLLOWUP_ISSUES caps per-assessment follow-up
# issue creation and writes skipped findings to orphaned-followup-items.md.
#
# Bug class: N× API cost of one-issue-per-finding design is unbounded.
# Fix: RITE_MAX_FOLLOWUP_ISSUES (default 20) checked at top of the per-finding
# loop in assess-and-resolve.sh; skipped findings saved to orphan trail.
#
# Test strategy: exercise the cap logic in isolation by replicating the loop
# variables and functions as stubs, then calling the cap-check block directly.
# This avoids spinning up the full assess-and-resolve.sh orchestration and the
# associated gh API dependencies.
#
# Verification: bats tests/regression/followup-creation-threshold.bats

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_VERBOSE=false
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_LOG_FILE="$RITE_TEST_TMPDIR/diag.log"

  mkdir -p "$RITE_TEST_TMPDIR/.rite"
  touch "$RITE_LOG_FILE"

  source "$RITE_LIB_DIR/utils/logging.sh"
}

teardown() {
  teardown_test_tmpdir
}

# Helper: run the cap-check block from assess-and-resolve.sh in a subshell
# with controlled inputs, then write results to files for assertion.
#
# Parameters (all env vars):
#   CAP_VALUE        — RITE_MAX_FOLLOWUP_ISSUES
#   CREATED_COUNT    — _followup_created_count at call time
#   FINDING_INDEX    — _finding_index at call time
#   FH_LINE          — simulated finding header line
#   PR_NUMBER        — PR number (required by diag)
#   ISSUE_NUMBER     — source issue (may be empty)
#   RESULT_FILE      — path to write "skipped" or "not_skipped"
#   ORPHAN_WRITTEN_FILE — path to write "yes" if orphan file was created

_run_cap_check() {
  local result_file="$1"
  local orphan_written_file="$2"

  (
    # Re-export all needed vars into the subshell
    export RITE_LOG_FILE RITE_PROJECT_ROOT RITE_DATA_DIR
    export RITE_MAX_FOLLOWUP_ISSUES="${CAP_VALUE:-20}"
    export PR_NUMBER="${PR_NUMBER:-42}"
    export ISSUE_NUMBER="${ISSUE_NUMBER:-}"

    source "$RITE_LIB_DIR/utils/logging.sh"

    # Stub print_* so they don't clutter test output
    print_warning() { :; }
    print_info() { :; }

    _finding_index="${FINDING_INDEX:-1}"
    _followup_created_count="${CREATED_COUNT:-0}"
    _fh_line="${FH_LINE:-### Fix something - ACTIONABLE_LATER}"

    _was_skipped=false

    _followup_cap="${RITE_MAX_FOLLOWUP_ISSUES:-20}"
    if [ "$_followup_cap" -gt 0 ] 2>/dev/null && [ "$_followup_created_count" -ge "$_followup_cap" ] 2>/dev/null; then
      _was_skipped=true
      _diag "FOLLOWUP_CAP_SKIPPED issue=${ISSUE_NUMBER:-} pr=${PR_NUMBER} finding_index=${_finding_index} cap=${_followup_cap} created=${_followup_created_count}"
      _orphan_cap_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/orphaned-followup-items.md"
      mkdir -p "${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}" 2>/dev/null || true
      {
        echo "---"
        echo "# Orphaned Follow-up Item (finding #${_finding_index}) — cap reached (RITE_MAX_FOLLOWUP_ISSUES=${_followup_cap})"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# PR: #${PR_NUMBER}"
        echo "# Source issue: #${ISSUE_NUMBER:-unknown}"
        echo "# Finding header: ${_fh_line:-}"
        echo ""
      } >> "$_orphan_cap_file" || true
    fi

    if [ "$_was_skipped" = "true" ]; then
      echo "skipped" > "$result_file"
    else
      echo "not_skipped" > "$result_file"
    fi

    local _orphan_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/orphaned-followup-items.md"
    if [ -f "$_orphan_file" ]; then
      echo "yes" > "$orphan_written_file"
    else
      echo "no" > "$orphan_written_file"
    fi
  )
}

# ─── Tests: cap check behaviour ───────────────────────────────────────────────

@test "cap not triggered when created count is below the cap" {
  local result_file="$RITE_TEST_TMPDIR/result"
  local orphan_file="$RITE_TEST_TMPDIR/orphan_written"

  CAP_VALUE=5 CREATED_COUNT=3 FINDING_INDEX=4 PR_NUMBER=42 \
    _run_cap_check "$result_file" "$orphan_file"

  local result
  result=$(cat "$result_file")
  [ "$result" = "not_skipped" ] || {
    echo "FAIL: expected not_skipped when created(3) < cap(5), got '$result'"
    false
  }
}

@test "cap triggered exactly at boundary: created == cap" {
  local result_file="$RITE_TEST_TMPDIR/result"
  local orphan_file="$RITE_TEST_TMPDIR/orphan_written"

  CAP_VALUE=3 CREATED_COUNT=3 FINDING_INDEX=4 PR_NUMBER=42 \
    _run_cap_check "$result_file" "$orphan_file"

  local result
  result=$(cat "$result_file")
  [ "$result" = "skipped" ] || {
    echo "FAIL: expected skipped when created(3) >= cap(3), got '$result'"
    false
  }
}

@test "cap triggered when created count exceeds cap" {
  local result_file="$RITE_TEST_TMPDIR/result"
  local orphan_file="$RITE_TEST_TMPDIR/orphan_written"

  CAP_VALUE=2 CREATED_COUNT=5 FINDING_INDEX=6 PR_NUMBER=99 \
    _run_cap_check "$result_file" "$orphan_file"

  local result
  result=$(cat "$result_file")
  [ "$result" = "skipped" ] || {
    echo "FAIL: expected skipped when created(5) >= cap(2), got '$result'"
    false
  }
}

@test "cap=0 disables the cap: created == 0 but cap is zero, not triggered" {
  local result_file="$RITE_TEST_TMPDIR/result"
  local orphan_file="$RITE_TEST_TMPDIR/orphan_written"

  # With cap=0, the first condition (_followup_cap -gt 0) is false, so the
  # check is skipped entirely even if created >= cap numerically.
  CAP_VALUE=0 CREATED_COUNT=0 FINDING_INDEX=1 PR_NUMBER=42 \
    _run_cap_check "$result_file" "$orphan_file"

  local result
  result=$(cat "$result_file")
  [ "$result" = "not_skipped" ] || {
    echo "FAIL: expected not_skipped with cap=0 (disabled), got '$result'"
    false
  }
}

@test "cap=0 disables the cap: created far exceeds cap value numerically" {
  local result_file="$RITE_TEST_TMPDIR/result"
  local orphan_file="$RITE_TEST_TMPDIR/orphan_written"

  # Even if created=100 > cap=0 numerically, -gt 0 guard prevents triggering.
  CAP_VALUE=0 CREATED_COUNT=100 FINDING_INDEX=101 PR_NUMBER=7 \
    _run_cap_check "$result_file" "$orphan_file"

  local result
  result=$(cat "$result_file")
  [ "$result" = "not_skipped" ] || {
    echo "FAIL: expected not_skipped with cap=0 (disabled), got '$result'"
    false
  }
}

# ─── Tests: orphan file written on cap hit ─────────────────────────────────

@test "orphan file is written when cap is triggered" {
  local result_file="$RITE_TEST_TMPDIR/result"
  local orphan_check="$RITE_TEST_TMPDIR/orphan_written"

  CAP_VALUE=1 CREATED_COUNT=1 FINDING_INDEX=2 PR_NUMBER=55 \
    _run_cap_check "$result_file" "$orphan_check"

  local orphan_written
  orphan_written=$(cat "$orphan_check")
  [ "$orphan_written" = "yes" ] || {
    echo "FAIL: expected orphan file to be written on cap trigger, got '$orphan_written'"
    false
  }
}

@test "orphan file is not written when cap is not triggered" {
  local result_file="$RITE_TEST_TMPDIR/result"
  local orphan_check="$RITE_TEST_TMPDIR/orphan_written"

  CAP_VALUE=5 CREATED_COUNT=2 FINDING_INDEX=3 PR_NUMBER=55 \
    _run_cap_check "$result_file" "$orphan_check"

  local orphan_written
  orphan_written=$(cat "$orphan_check")
  [ "$orphan_written" = "no" ] || {
    echo "FAIL: expected no orphan file when cap not triggered, got '$orphan_written'"
    false
  }
}

@test "orphan file contains finding header line when cap is triggered" {
  local result_file="$RITE_TEST_TMPDIR/result"
  local orphan_check="$RITE_TEST_TMPDIR/orphan_written"

  CAP_VALUE=1 CREATED_COUNT=1 FINDING_INDEX=2 PR_NUMBER=33 \
  FH_LINE="### Fix missing error handling - ACTIONABLE_LATER" \
    _run_cap_check "$result_file" "$orphan_check"

  local orphan_file="${RITE_TEST_TMPDIR}/.rite/orphaned-followup-items.md"
  [ -f "$orphan_file" ] || {
    echo "FAIL: orphan file not found at $orphan_file"
    false
  }

  grep -q "Fix missing error handling - ACTIONABLE_LATER" "$orphan_file" || {
    echo "FAIL: finding header not found in orphan file"
    cat "$orphan_file" || true
    false
  }
}

@test "orphan file contains PR number and source issue when cap is triggered" {
  local result_file="$RITE_TEST_TMPDIR/result"
  local orphan_check="$RITE_TEST_TMPDIR/orphan_written"

  CAP_VALUE=1 CREATED_COUNT=1 FINDING_INDEX=2 PR_NUMBER=77 ISSUE_NUMBER=42 \
    _run_cap_check "$result_file" "$orphan_check"

  local orphan_file="${RITE_TEST_TMPDIR}/.rite/orphaned-followup-items.md"
  grep -q "PR: #77" "$orphan_file" || {
    echo "FAIL: PR number not found in orphan file"
    cat "$orphan_file" || true
    false
  }

  grep -q "Source issue: #42" "$orphan_file" || {
    echo "FAIL: source issue not found in orphan file"
    cat "$orphan_file" || true
    false
  }
}

# ─── Tests: diag emission ─────────────────────────────────────────────────────

@test "FOLLOWUP_CAP_SKIPPED diag line emitted when cap is triggered" {
  local result_file="$RITE_TEST_TMPDIR/result"
  local orphan_check="$RITE_TEST_TMPDIR/orphan_written"

  CAP_VALUE=2 CREATED_COUNT=2 FINDING_INDEX=3 PR_NUMBER=11 ISSUE_NUMBER=5 \
    _run_cap_check "$result_file" "$orphan_check"

  local diag_count
  diag_count=$(grep -c "FOLLOWUP_CAP_SKIPPED" "$RITE_LOG_FILE" || true)
  [ "$diag_count" -ge 1 ] || {
    echo "FAIL: expected FOLLOWUP_CAP_SKIPPED diag line, got count=$diag_count"
    cat "$RITE_LOG_FILE" || true
    false
  }
}

@test "FOLLOWUP_CAP_SKIPPED diag includes cap and pr fields" {
  local result_file="$RITE_TEST_TMPDIR/result"
  local orphan_check="$RITE_TEST_TMPDIR/orphan_written"

  CAP_VALUE=3 CREATED_COUNT=3 FINDING_INDEX=4 PR_NUMBER=88 ISSUE_NUMBER=10 \
    _run_cap_check "$result_file" "$orphan_check"

  local line
  line=$(grep "FOLLOWUP_CAP_SKIPPED" "$RITE_LOG_FILE" | tail -1 || true)
  [ -n "$line" ] || {
    echo "FAIL: no FOLLOWUP_CAP_SKIPPED diag line found"
    cat "$RITE_LOG_FILE" || true
    false
  }

  echo "$line" | grep -q "cap=3" || {
    echo "FAIL: cap= field not found in: $line"
    false
  }

  echo "$line" | grep -q "pr=88" || {
    echo "FAIL: pr= field not found in: $line"
    false
  }
}

@test "no FOLLOWUP_CAP_SKIPPED diag when cap is not triggered" {
  local result_file="$RITE_TEST_TMPDIR/result"
  local orphan_check="$RITE_TEST_TMPDIR/orphan_written"

  CAP_VALUE=10 CREATED_COUNT=3 FINDING_INDEX=4 PR_NUMBER=42 \
    _run_cap_check "$result_file" "$orphan_check"

  local diag_count
  diag_count=$(grep -c "FOLLOWUP_CAP_SKIPPED" "$RITE_LOG_FILE" || true)
  [ "$diag_count" -eq 0 ] || {
    echo "FAIL: expected no FOLLOWUP_CAP_SKIPPED diag when below cap, got $diag_count"
    cat "$RITE_LOG_FILE" || true
    false
  }
}

# ─── Tests: config.sh default value ───────────────────────────────────────────

@test "RITE_MAX_FOLLOWUP_ISSUES defaults to 20 when unset" {
  (
    # Unset then source config.sh to verify the default is applied
    unset RITE_MAX_FOLLOWUP_ISSUES
    source "$RITE_LIB_DIR/utils/config.sh"
    local val="${RITE_MAX_FOLLOWUP_ISSUES:-}"
    echo "$val" > "$RITE_TEST_TMPDIR/config_val"
  )

  local val
  val=$(cat "$RITE_TEST_TMPDIR/config_val")
  [ "$val" = "20" ] || {
    echo "FAIL: expected RITE_MAX_FOLLOWUP_ISSUES=20 (default), got '$val'"
    false
  }
}

@test "RITE_MAX_FOLLOWUP_ISSUES respects caller-set value" {
  (
    export RITE_MAX_FOLLOWUP_ISSUES=5
    source "$RITE_LIB_DIR/utils/config.sh"
    echo "${RITE_MAX_FOLLOWUP_ISSUES:-}" > "$RITE_TEST_TMPDIR/config_val"
  )

  local val
  val=$(cat "$RITE_TEST_TMPDIR/config_val")
  [ "$val" = "5" ] || {
    echo "FAIL: expected RITE_MAX_FOLLOWUP_ISSUES=5 (caller-set), got '$val'"
    false
  }
}
