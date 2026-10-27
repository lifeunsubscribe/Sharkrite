#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite-health-report
# tests/regression/health-report-cr-precompute.bats
#
# Verifies that bin/rite-health-report pre-computes CR_TOP5_ISSUES and
# CR_MEDIAN_DURATION_S in bash from CR_LINES before passing data to Claude,
# instead of delegating those arithmetic operations to the LLM.
#
# All tests invoke bin/rite-health-report --compute-cr-top5-block or
# --compute-cr-median-block directly with RITE_HEALTH_LOGFILES pointing at
# fixture files so that any production change is immediately reflected —
# no inline pipeline copy can drift.

load '../helpers/setup'

setup() {
  setup_test_tmpdir
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# CR_TOP5_ISSUES tests
# ---------------------------------------------------------------------------

@test "CR_TOP5_ISSUES: empty CR_LINES returns N/A" {
  run env RITE_HEALTH_LOGFILES="" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-top5-block
  [ "$status" -eq 0 ]
  [ "$output" = "N/A" ]
}

@test "CR_TOP5_ISSUES: single issue appears once" {
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=42 pr=55 duration_s=30" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-top5-block
  [ "$status" -eq 0 ]
  [ "$output" = "#42 (1x)" ]
}

@test "CR_TOP5_ISSUES: same issue repeated counts correctly" {
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=42 pr=55 duration_s=30" \
    "[diag] CONFLICT_RESOLVER context=divergence outcome=failed issue=42 pr=55 duration_s=45" \
    "[diag] CONFLICT_RESOLVER context=mid_run_rebase outcome=cap_hit issue=42 pr=55 duration_s=60" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-top5-block
  [ "$status" -eq 0 ]
  [ "$output" = "#42 (3x)" ]
}

@test "CR_TOP5_ISSUES: multiple issues sorted by frequency descending" {
  # Issue 99: 3x, issue 42: 2x, issue 7: 1x
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=99 pr=100 duration_s=10" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=99 pr=100 duration_s=20" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=99 pr=100 duration_s=30" \
    "[diag] CONFLICT_RESOLVER context=divergence outcome=failed issue=42 pr=50 duration_s=40" \
    "[diag] CONFLICT_RESOLVER context=divergence outcome=failed issue=42 pr=50 duration_s=50" \
    "[diag] CONFLICT_RESOLVER context=mid_run_rebase outcome=resolved issue=7 pr=8 duration_s=60" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-top5-block
  [ "$status" -eq 0 ]
  # Highest-frequency issue must come first
  [[ "$output" == "#99 (3x)"* ]]
  [[ "$output" == *"#42 (2x)"* ]]
  [[ "$output" == *"#7 (1x)"* ]]
}

@test "CR_TOP5_ISSUES: caps at 5 issues even when more exist" {
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=1 pr=1 duration_s=10" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=10" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=3 pr=3 duration_s=10" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=4 pr=4 duration_s=10" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=5 pr=5 duration_s=10" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=6 pr=6 duration_s=10" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-top5-block
  [ "$status" -eq 0 ]
  # N entries have N-1 commas; cap at 5 means at most 4 commas
  comma_count=$(echo "$output" | tr -cd ',' | wc -c | tr -d ' ')
  [ "$comma_count" -le 4 ]
}

@test "CR_TOP5_ISSUES: bare-marker guard — empty issue= field is ignored" {
  # skipped_no_resolver lines have issue= with no digits — must not produce output
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=skipped_no_resolver issue= pr=" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-top5-block
  [ "$status" -eq 0 ]
  [ "$output" = "N/A" ]
}

@test "CR_TOP5_ISSUES: output is deterministic across two runs" {
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=99 pr=100 duration_s=10" \
    "[diag] CONFLICT_RESOLVER context=divergence outcome=failed issue=42 pr=50 duration_s=40" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=99 pr=100 duration_s=20" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-top5-block
  _first="$output"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-top5-block
  [ "$output" = "$_first" ]
}

@test "CR_TOP5_ISSUES: tie-breaking — equal-count issues ordered by issue number ascending" {
  # Issues 7, 42, 99 all appear exactly 2x.  With a non-deterministic secondary
  # sort the order would vary by platform; the fix (-k2,2n) must yield 7 < 42 < 99.
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=99 pr=100 duration_s=10" \
    "[diag] CONFLICT_RESOLVER context=divergence outcome=failed issue=42 pr=50 duration_s=40" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=7 pr=8 duration_s=20" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=42 pr=50 duration_s=30" \
    "[diag] CONFLICT_RESOLVER context=divergence outcome=failed issue=99 pr=100 duration_s=50" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=7 pr=8 duration_s=60" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-top5-block
  [ "$status" -eq 0 ]
  # All three issues have count=2; lowest issue number must come first
  [[ "$output" == "#7 (2x), #42 (2x), #99 (2x)" ]]
}

# ---------------------------------------------------------------------------
# CR_MEDIAN_DURATION_S tests
# ---------------------------------------------------------------------------

@test "CR_MEDIAN_DURATION_S: empty CR_LINES returns N/A" {
  run env RITE_HEALTH_LOGFILES="" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-median-block
  [ "$status" -eq 0 ]
  [ "$output" = "N/A" ]
}

@test "CR_MEDIAN_DURATION_S: lines with no duration_s field return N/A" {
  # skipped_no_resolver lines have no duration_s field
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=skipped_no_resolver issue=42 pr=55" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-median-block
  [ "$status" -eq 0 ]
  [ "$output" = "N/A" ]
}

@test "CR_MEDIAN_DURATION_S: single duration value" {
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=42 pr=55 duration_s=45" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-median-block
  [ "$status" -eq 0 ]
  [ "$output" = "45s" ]
}

@test "CR_MEDIAN_DURATION_S: odd count — picks middle value" {
  # Sorted: 10, 30, 50 — median is 30
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=1 pr=1 duration_s=30" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=10" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=3 pr=3 duration_s=50" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-median-block
  [ "$status" -eq 0 ]
  [ "$output" = "30s" ]
}

@test "CR_MEDIAN_DURATION_S: even count — integer average of two middle values" {
  # Sorted: 10, 20, 40, 80 — median is (20+40)/2 = 30
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=1 pr=1 duration_s=20" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=80" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=3 pr=3 duration_s=10" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=4 pr=4 duration_s=40" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-median-block
  [ "$status" -eq 0 ]
  [ "$output" = "30s" ]
}

@test "CR_MEDIAN_DURATION_S: even count with odd sum truncates via integer division" {
  # Sorted: 10, 11 — median is (10+11)/2 = 10 (integer division truncates)
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=1 pr=1 duration_s=10" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=11" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-median-block
  [ "$status" -eq 0 ]
  [ "$output" = "10s" ]
}

@test "CR_MEDIAN_DURATION_S: skipped_no_resolver lines (no duration_s) do not affect median" {
  # skipped line has no duration_s; durations: 20, 40 — median is (20+40)/2 = 30
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=skipped_no_resolver issue=1 pr=1" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=40" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=3 pr=3 duration_s=20" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-median-block
  [ "$status" -eq 0 ]
  [ "$output" = "30s" ]
}

@test "CR_MEDIAN_DURATION_S: output is deterministic across two runs" {
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=1 pr=1 duration_s=10" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=30" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=3 pr=3 duration_s=50" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-median-block
  _first="$output"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-median-block
  [ "$output" = "$_first" ]
}

@test "CR_MEDIAN_DURATION_S: large duration values handled correctly" {
  # 1800s (30m) and 3600s (1h) — median is (1800+3600)/2 = 2700
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=1 pr=1 duration_s=1800" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=3600" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-median-block
  [ "$status" -eq 0 ]
  [ "$output" = "2700s" ]
}

@test "CR_MEDIAN_DURATION_S: skipped_no_resolver lines are excluded by outcome even if they carry duration_s" {
  # Robustness test for future log-format changes: a skipped_no_resolver line that
  # hypothetically gains a duration_s=0 field must still be excluded (by the
  # grep -v 'outcome=skipped_no_resolver' filter, not merely by field absence).
  # Remaining durations: 20, 40 — median is (20+40)/2 = 30, not (0+20+40)/3.
  printf '%s\n' \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=skipped_no_resolver issue=1 pr=1 duration_s=0" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=40" \
    "[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=3 pr=3 duration_s=20" \
    > "$RITE_TEST_TMPDIR/log.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-cr-median-block
  [ "$status" -eq 0 ]
  [ "$output" = "30s" ]
}
