#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-reporter.sh::_batch_followups_created|_batch_print_stats, lib/core/assess-and-resolve.sh, lib/core/assess-review-issues.sh
# tests/regression/batch-followups-created-stats.bats
#
# A batch reports how many issues it completed but never how many it CREATED,
# so the follow-up volume a run generates is invisible at the point you would
# act on it. You had to count follow-ups by hand to judge the generation rate.
#
# The number is harvested from FOLLOWUP_CREATED diag lines in the run's own log
# rather than queried from GitHub: _diag writes directly to RITE_LOG_FILE and
# every slot in a batch inherits that path, so the log is a complete and
# self-scoped record. No API call, no cross-batch bleed, works offline.
#
# Both per-issue creation sites must emit the diag — the rolled-up follow-up in
# assess-and-resolve.sh and the ACTIONABLE_LATER per-item issue in
# assess-review-issues.sh. Instrumenting only one undercounts whichever shape a
# batch's findings happened to take.
#
# Tests in this file:
#   HARVEST (_batch_followups_created)
#     1. harvests issue numbers from FOLLOWUP_CREATED diag lines
#     2. deduplicates and sorts numerically
#     3. empty when RITE_LOG_FILE is unset
#     4. empty when RITE_LOG_FILE points at a missing file
#     5. empty (not an error) when the log has no FOLLOWUP_CREATED lines
#     6. ignores followup=unknown (created but number unparseable)
#     7. does NOT match the promote-path sibling diags
#   DISPLAY (_batch_print_stats)
#     8. prints the count and the issue list when follow-ups were created
#     9. prints "Issues Created:   0" when none were
#   INSTRUMENTATION
#    10. assess-and-resolve.sh emits FOLLOWUP_CREATED on its creation path
#    11. assess-review-issues.sh emits FOLLOWUP_CREATED on its creation path

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_REPORTER="$REPO_ROOT/lib/core/batch-reporter.sh"
ASSESS_AND_RESOLVE="$REPO_ROOT/lib/core/assess-and-resolve.sh"
ASSESS_REVIEW_ISSUES="$REPO_ROOT/lib/core/assess-review-issues.sh"

setup() {
  for _f in "$BATCH_REPORTER" "$ASSESS_AND_RESOLVE" "$ASSESS_REVIEW_ISSUES"; do
    [ -f "$_f" ] || {
      echo "FATAL: $_f not found" >&2
      return 1
    }
  done
  _tmpdir=$(mktemp -d)
  _log="$_tmpdir/batch.log"
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# Write a log line in the exact shape _diag produces: "[diag] HH:MM:SS | MSG".
_diag_line() {
  printf '[diag] 14:02:11 | %s\n' "$1" >> "$_log"
}

_harvest() {
  run bash -c "
    set -euo pipefail
    source '$BATCH_REPORTER'
    set +u; set +o pipefail
    ${1:-export RITE_LOG_FILE='$_log'}
    _batch_followups_created
  "
}

# =============================================================================
# HARVEST
# =============================================================================

@test "harvest: issue numbers come out of FOLLOWUP_CREATED diag lines" {
  _diag_line "FOLLOWUP_CREATED issue=1213 pr=1340 followup=1348"
  _diag_line "FOLLOWUP_CREATED issue=1213 pr=1340 followup=1349"

  _harvest

  [ "$status" -eq 0 ] || {
    echo "FAIL: harvest exited $status: $output" >&2
    return 1
  }
  [ "$output" = "1348
1349" ] || {
    echo "FAIL: expected 1348 and 1349, got: '$output'" >&2
    return 1
  }
}

@test "harvest: duplicates collapse and output is sorted numerically" {
  # A re-entered assess loop can log the same creation twice; and 1350 arriving
  # before 1349 must not come out in log order.
  _diag_line "FOLLOWUP_CREATED issue=1213 pr=1340 followup=1350"
  _diag_line "FOLLOWUP_CREATED issue=1214 pr=1341 followup=1349"
  _diag_line "FOLLOWUP_CREATED issue=1213 pr=1340 followup=1350"

  _harvest

  [ "$output" = "1349
1350" ] || {
    echo "FAIL: expected deduped ascending '1349\\n1350', got: '$output'" >&2
    return 1
  }
}

@test "harvest: empty when RITE_LOG_FILE is unset (--no-log run)" {
  _harvest "unset RITE_LOG_FILE || true"

  [ "$status" -eq 0 ] || {
    echo "FAIL: must succeed with no log, exited $status: $output" >&2
    return 1
  }
  [ -z "$output" ] || {
    echo "FAIL: expected no output, got: '$output'" >&2
    return 1
  }
}

@test "harvest: empty when RITE_LOG_FILE points at a missing file" {
  _harvest "export RITE_LOG_FILE='$_tmpdir/nope.log'"

  [ "$status" -eq 0 ] || {
    echo "FAIL: must succeed when the log is absent, exited $status" >&2
    return 1
  }
  [ -z "$output" ] || {
    echo "FAIL: expected no output, got: '$output'" >&2
    return 1
  }
}

@test "harvest: empty and successful when the log has no FOLLOWUP_CREATED lines" {
  # grep finding nothing must not take down the caller under pipefail.
  _diag_line "WORKFLOW_COMPLETE issue=1213 iterations=1"
  _diag_line "ASSESSMENT issue=1213 retry=1 now=0 later=0 dismissed=3"

  _harvest

  [ "$status" -eq 0 ] || {
    echo "FAIL: no-match harvest exited $status: $output" >&2
    return 1
  }
  [ -z "$output" ] || {
    echo "FAIL: expected no output, got: '$output'" >&2
    return 1
  }
}

@test "harvest: followup=unknown is not counted" {
  # The issue was created but its number could not be parsed from the URL.
  # Counting it would report a number nobody can look up.
  _diag_line "FOLLOWUP_CREATED issue=1213 pr=1340 followup=unknown"
  _diag_line "FOLLOWUP_CREATED issue=1213 pr=1340 followup=1348"

  _harvest

  [ "$output" = "1348" ] || {
    echo "FAIL: expected only 1348, got: '$output'" >&2
    return 1
  }
}

@test "harvest: promote-path sibling diags do not leak into a batch's count" {
  # PROMOTE_FOLLOWUP_CREATED and PROMOTE_ASSESSED_FOLLOWUP_CREATED end in the
  # same token. The '| ' anchor pins the match to the start of the message.
  _diag_line "PROMOTE_FOLLOWUP_CREATED branch=gate-refactor pr=1279 high=1 medium=2 low=0 followup=9001"
  _diag_line "PROMOTE_ASSESSED_FOLLOWUP_CREATED branch=gate-refactor pr=1279 now=4 duplicate=4 followup=9002"
  _diag_line "FOLLOWUP_CREATED issue=1213 pr=1340 followup=1348"

  _harvest

  [ "$output" = "1348" ] || {
    echo "FAIL: promote diags leaked into the batch count; got: '$output'" >&2
    echo "      a batch must report only the follow-ups IT created" >&2
    return 1
  }
}

# =============================================================================
# DISPLAY
# =============================================================================

@test "display: the count and the issue list appear in the stats block" {
  _diag_line "FOLLOWUP_CREATED issue=1213 pr=1340 followup=1348"
  _diag_line "FOLLOWUP_CREATED issue=1213 pr=1340 followup=1349"
  _diag_line "FOLLOWUP_CREATED issue=1214 pr=1341 followup=1350"

  run bash -c "
    set -euo pipefail
    source '$BATCH_REPORTER'
    set +u; set +o pipefail
    export RITE_LOG_FILE='$_log'
    TOTAL_ISSUES=2
    COMPLETED_ISSUES=2
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=()
    AUTH_FAILURE_ISSUES=()
    ALREADY_CLOSED_AT_START_ISSUES=()
    IN_PROGRESS_ELSEWHERE_ISSUES=()
    TOTAL_DURATION=600
    declare -A ISSUE_STATUS
    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ] || {
    echo "FAIL: _batch_print_stats exited $status: $output" >&2
    return 1
  }
  echo "$output" | grep -q 'Issues Created:   3' || {
    echo "FAIL: expected 'Issues Created:   3'" >&2
    echo "      output: $output" >&2
    return 1
  }
  echo "$output" | grep -q '#1348, #1349, #1350' || {
    echo "FAIL: expected the follow-up numbers listed as '#1348, #1349, #1350'" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "display: zero is reported explicitly, not omitted" {
  # A batch that generated no new debt should say so — that is the signal.
  run bash -c "
    set -euo pipefail
    source '$BATCH_REPORTER'
    set +u; set +o pipefail
    export RITE_LOG_FILE='$_log'
    TOTAL_ISSUES=1
    COMPLETED_ISSUES=1
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=()
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=()
    AUTH_FAILURE_ISSUES=()
    ALREADY_CLOSED_AT_START_ISSUES=()
    IN_PROGRESS_ELSEWHERE_ISSUES=()
    TOTAL_DURATION=120
    declare -A ISSUE_STATUS
    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ] || {
    echo "FAIL: _batch_print_stats exited $status: $output" >&2
    return 1
  }
  echo "$output" | grep -q 'Issues Created:   0' || {
    echo "FAIL: expected 'Issues Created:   0'" >&2
    echo "      output: $output" >&2
    return 1
  }
}

# =============================================================================
# INSTRUMENTATION — both creation sites must emit, or the count undercounts
# =============================================================================

@test "instrumentation: assess-and-resolve.sh emits FOLLOWUP_CREATED when it files" {
  grep -q 'FOLLOWUP_CREATED' "$ASSESS_AND_RESOLVE" || {
    echo "FAIL: assess-and-resolve.sh does not emit FOLLOWUP_CREATED" >&2
    echo "      the rolled-up follow-up would not be counted" >&2
    return 1
  }
  grep -q 'followup=' "$ASSESS_AND_RESOLVE" || {
    echo "FAIL: the diag must carry a followup= field to be harvestable" >&2
    return 1
  }
}

@test "instrumentation: assess-review-issues.sh emits FOLLOWUP_CREATED when it files" {
  grep -q 'FOLLOWUP_CREATED' "$ASSESS_REVIEW_ISSUES" || {
    echo "FAIL: assess-review-issues.sh does not emit FOLLOWUP_CREATED" >&2
    echo "      ACTIONABLE_LATER per-item issues would not be counted, so a" >&2
    echo "      batch whose findings came out per-item would report 0 created" >&2
    return 1
  }
  grep -q 'followup=' "$ASSESS_REVIEW_ISSUES" || {
    echo "FAIL: the diag must carry a followup= field to be harvestable" >&2
    return 1
  }
}
