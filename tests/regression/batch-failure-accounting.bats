#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh, lib/core/workflow-runner.sh, lib/utils/session-tracker.sh::get_session_summary|increment_failed|increment_completed
# tests/regression/batch-failure-accounting.bats
#
# The session summary counted completions but almost never counted failures, so
# its Duration and its Total Processed described different sets of issues:
#
#     Duration: 19m 24s
#     Issues Completed: 1
#     Total Processed: 1
#
# That run processed TWO issues — #1221 failed after 8m41s on the bash-4
# refusal, #1277 completed in 10m29s. 8m41s + 10m29s + 14s of batch overhead is
# exactly the 19m24s on the clock, but the only one the summary admitted to was
# #1277, so nineteen minutes looked like it went into a ten-minute issue.
#
# Cause: increment_failed had exactly ONE call site — the per-issue blocker
# branch in workflow-runner.sh. Every other way an issue can fail (the bash-4
# refusal, a failed rebase, a gate failure, a usage cap, an auth halt, a
# workflow-invariant violation) incremented nothing.
#
# Fix: batch-process-issues.sh owns failure accounting, because it is the only
# place that sees every outcome class. The blocker branch's increment is removed
# — it returns 1, which the batch already classifies and now counts, so leaving
# both would double-report one blocked issue.
#
# Tests in this file:
#   1. every FAILED_ISSUES classification also increments the failure count
#   2. the blocker branch does NOT increment (no double count)
#   3. summary arithmetic: 1 failed + 1 completed reports Total Processed 2
#   4. a clean batch still reports 0 failures and omits the Failed line

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH="$REPO_ROOT/lib/core/batch-process-issues.sh"
RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"
TRACKER="$REPO_ROOT/lib/utils/session-tracker.sh"

setup() {
  for _f in "$BATCH" "$RUNNER" "$TRACKER"; do
    [ -f "$_f" ] || { echo "FATAL: $_f not found" >&2; return 1; }
  done
  _tmpdir=$(mktemp -d)
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# Drive the tracker with a given number of failures and completions.
_summary() {
  bash -c "
    set -uo pipefail
    export SESSION_STATE_FILE='$_tmpdir/session.json'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    source '$REPO_ROOT/lib/utils/colors.sh' 2>/dev/null || true
    source '$TRACKER' 2>/dev/null || true
    printf '%s' '{\"mode\":\"test\",\"start_time\":1792532723,\"issues_completed\":0,\"issues_failed\":0}' \
      > \"\$SESSION_STATE_FILE\"
    _i=0; while [ \$_i -lt ${1:-0} ]; do increment_failed    >/dev/null 2>&1; _i=\$((_i+1)); done
    _i=0; while [ \$_i -lt ${2:-0} ]; do increment_completed >/dev/null 2>&1; _i=\$((_i+1)); done
    get_session_summary 2>/dev/null
  "
}

# =============================================================================
# STRUCTURAL
# =============================================================================

@test "every FAILED_ISSUES classification increments the failure count" {
  # Each failure class appends to FAILED_ISSUES and sets ISSUE_STATUS. Any one
  # of them that does not also increment makes Duration and Total Processed
  # describe different sets of issues.
  _appends=$(grep -c 'FAILED_ISSUES+=("\$ISSUE_NUM")' "$BATCH" || true)
  _counts=$(grep -c 'increment_failed' "$BATCH" || true)

  [ "$_appends" -gt 0 ] || {
    echo "FAIL: no FAILED_ISSUES appends found — did the file move?" >&2
    return 1
  }
  [ "$_counts" -ge "$_appends" ] || {
    echo "FAIL: $_appends failure classifications but only $_counts increments" >&2
    echo "      an uncounted failure class makes the session summary undercount" >&2
    return 1
  }
}

@test "the blocker branch does not increment (single owner, no double count)" {
  # workflow-runner's per-issue blocker branch returns 1, which the batch
  # classifies and counts. Incrementing here too would report one blocked issue
  # as two failures.
  # Comment lines mentioning the call are fine — and expected, since the
  # removal is documented there. Only an executable call is a double count.
  _live=$(grep -n 'increment_failed' "$RUNNER" \
            | grep -vE '^[0-9]+:[[:space:]]*#' || true)

  [ -z "$_live" ] || {
    echo "FAIL: workflow-runner.sh still increments the failure count:" >&2
    echo "$_live" >&2
    echo "      it returns 1, which batch-process-issues.sh already counts" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL — the exact run that exposed this
# =============================================================================

@test "summary: 1 failed + 1 completed reports Total Processed 2" {
  run _summary 1 1

  echo "$output" | grep -q 'Issues Completed: 1' || {
    echo "FAIL: expected 'Issues Completed: 1'; got: $output" >&2
    return 1
  }
  echo "$output" | grep -q 'Issues Failed: 1' || {
    echo "FAIL: expected 'Issues Failed: 1'; got: $output" >&2
    return 1
  }
  echo "$output" | grep -q 'Total Processed: 2' || {
    echo "FAIL: expected 'Total Processed: 2' — the run that exposed this" >&2
    echo "      reported 1 while the clock measured both issues" >&2
    echo "      got: $output" >&2
    return 1
  }
}

@test "summary: a clean batch reports no failures and omits the Failed line" {
  run _summary 0 3

  echo "$output" | grep -q 'Total Processed: 3' || {
    echo "FAIL: expected 'Total Processed: 3'; got: $output" >&2
    return 1
  }
  echo "$output" | grep -q 'Issues Failed' && {
    echo "FAIL: the Failed line must stay hidden when nothing failed" >&2
    echo "      got: $output" >&2
    return 1
  }
  return 0
}
