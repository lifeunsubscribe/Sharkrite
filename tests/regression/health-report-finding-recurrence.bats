#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite-health-report
# tests/regression/health-report-finding-recurrence.bats
#
# Verifies that bin/rite-health-report pre-computes RF_BLOCK from ACTIONABLE_NOW
# finding headers in log files:
#   - A title appearing 2+ times → block present with count
#   - All-unique titles → block absent
#   - Reasoning-text mention of ACTIONABLE_NOW (no ### header) → NOT counted
#   - [GATE] entries excluded from both title and category tallies
#   - Catch-all categories (codequality) excluded from the category backstop
#
# All tests invoke bin/rite-health-report --compute-rf-block directly with
# RITE_HEALTH_LOGFILES pointing at fixture files so that any production change
# is immediately reflected — no inline pipeline copy can drift.

load '../helpers/setup'

setup() {
  setup_test_tmpdir
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Scenario 1: title appearing 2x across two log files → block present
# ---------------------------------------------------------------------------

@test "RF_BLOCK: title appearing 2x across two logs is present with count" {
  printf '### Missing input validation - ACTIONABLE_NOW\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### Missing input validation - ACTIONABLE_NOW\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-rf-block
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recurring finding classes"* ]]
  [[ "$output" == *"2x: missing input validation"* ]]
}

# ---------------------------------------------------------------------------
# Scenario 2: all-unique titles → block absent
# ---------------------------------------------------------------------------

@test "RF_BLOCK: all-unique titles produce empty block" {
  printf '### Missing input validation - ACTIONABLE_NOW\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### Unhandled error path - ACTIONABLE_NOW\n**Category:** correctness\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-rf-block
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Scenario 3: reasoning-text mention of ACTIONABLE_NOW (no ### header) NOT counted
# ---------------------------------------------------------------------------

@test "RF_BLOCK: reasoning-text mention of ACTIONABLE_NOW without ### header is not counted" {
  # Log has two occurrences of the phrase but neither is a structured header
  printf 'This was the previous ACTIONABLE_NOW item that was already fixed.\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf 'The prior ACTIONABLE_NOW finding addressed the same concern.\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-rf-block
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Additional correctness: LATER and DISMISSED headers are not counted
# ---------------------------------------------------------------------------

@test "RF_BLOCK: ACTIONABLE_LATER and DISMISSED headers do not trigger block" {
  printf '### Missing input validation - ACTIONABLE_LATER\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### Missing input validation - DISMISSED\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-rf-block
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Category backstop: a specific (non-catch-all) category appearing 4x triggers
# the coarse-backstop path even when all finding titles are unique
# ---------------------------------------------------------------------------

@test "RF_BLOCK: category appearing 4x triggers category backstop even with unique titles" {
  printf '### Alpha finding - ACTIONABLE_NOW\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### Beta finding - ACTIONABLE_NOW\n**Category:** security\n' \
    >> "$RITE_TEST_TMPDIR/log1.log"
  printf '### Gamma finding - ACTIONABLE_NOW\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  printf '### Delta finding - ACTIONABLE_NOW\n**Category:** security\n' \
    >> "$RITE_TEST_TMPDIR/log2.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-rf-block
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recurring finding classes"* ]]
  [[ "$output" == *"By category"* ]]
  [[ "$output" == *"4x: security"* ]]
}

# ---------------------------------------------------------------------------
# Threshold knob: RITE_HEALTH_RECURRENCE_MIN=3 suppresses a 2x title
# ---------------------------------------------------------------------------

@test "RF_BLOCK: RITE_HEALTH_RECURRENCE_MIN=3 suppresses a title that appears only 2x" {
  printf '### Missing input validation - ACTIONABLE_NOW\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### Missing input validation - ACTIONABLE_NOW\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  run env RITE_HEALTH_RECURRENCE_MIN=3 \
    RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-rf-block
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Normalization: case and extra whitespace do not create spurious distinct entries
# ---------------------------------------------------------------------------

@test "RF_BLOCK: title normalization — case and whitespace differences collapse to same entry" {
  printf '### Missing Input Validation - ACTIONABLE_NOW\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### missing  input  validation - ACTIONABLE_NOW\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-rf-block
  [ "$status" -eq 0 ]
  # Both forms should normalize to the same title and produce a 2x entry
  [[ "$output" == *"2x: missing input validation"* ]]
}

# ---------------------------------------------------------------------------
# No logs / empty logs → block absent
# ---------------------------------------------------------------------------

@test "RF_BLOCK: no log files produces empty block" {
  run env RITE_HEALTH_LOGFILES="" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-rf-block
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# [GATE] exclusion: test-failure headers must not inflate the recurrence tally
# (behavioral pin for the grep -v '^### \[GATE\]' filter at bin/rite-health-report)
# ---------------------------------------------------------------------------

@test "RF_BLOCK: [GATE] header appearing 2x produces empty block" {
  printf '### [GATE] ACTIONABLE_NOW: 2 test failures (bats exit 1) - ACTIONABLE_NOW\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### [GATE] ACTIONABLE_NOW: 2 test failures (bats exit 1) - ACTIONABLE_NOW\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-rf-block
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# [GATE]+Category: awk GATE exclusion must suppress Category lines too
# (mutation coverage for /^### \[GATE\]/{capture=0; next})
# Uses a non-catch-all category (security) so removing the awk rule causes the
# category backstop to fire even after the codequality exclusion fix.
# ---------------------------------------------------------------------------

@test "RF_BLOCK: [GATE] headers with Category lines do not inflate category backstop" {
  # 4x [GATE] entries each with Category: security — without the awk GATE
  # exclusion rule the category backstop (threshold=4) would fire and produce
  # non-empty output.  Deleting that one awk line must make this test fail.
  printf '### [GATE] failure 1 - ACTIONABLE_NOW\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### [GATE] failure 2 - ACTIONABLE_NOW\n**Category:** security\n' \
    >> "$RITE_TEST_TMPDIR/log1.log"
  printf '### [GATE] failure 3 - ACTIONABLE_NOW\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  printf '### [GATE] failure 4 - ACTIONABLE_NOW\n**Category:** security\n' \
    >> "$RITE_TEST_TMPDIR/log2.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-rf-block
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Catch-all category backstop: CodeQuality alone must NOT produce a recurrence line
# (backstop fix: _RECURRENCE_CAT_EXCLUDES prevents catch-all buckets from firing)
# ---------------------------------------------------------------------------

@test "RF_BLOCK: catch-all category (CodeQuality) alone does not produce a recurrence line" {
  # 4x findings all with Category: CodeQuality and unique titles.
  # Before the fix the category backstop would fire (codequality >= threshold=4).
  # After the fix codequality is excluded from the backstop entirely.
  printf '### Alpha finding - ACTIONABLE_NOW\n**Category:** CodeQuality\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### Beta finding - ACTIONABLE_NOW\n**Category:** CodeQuality\n' \
    >> "$RITE_TEST_TMPDIR/log1.log"
  printf '### Gamma finding - ACTIONABLE_NOW\n**Category:** CodeQuality\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  printf '### Delta finding - ACTIONABLE_NOW\n**Category:** CodeQuality\n' \
    >> "$RITE_TEST_TMPDIR/log2.log"
  run env RITE_HEALTH_LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    "$RITE_REPO_ROOT/bin/rite-health-report" --compute-rf-block
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Drift guard: production grep filter excludes [GATE] entries from title tally
# (structural pin complementing the behavioral pin in test 9 above)
# ---------------------------------------------------------------------------

@test "bin/rite-health-report contains the grep filter that excludes [GATE] from title tally" {
  # Pin the specific grep -v form at ~line 320 of bin/rite-health-report.
  # Removing that filter turns test 9 red (behavioral); this structural pin
  # ensures the filter is present even before the behavioral tests run.
  grep -qF "grep -v '^### \[GATE\]'" "$RITE_REPO_ROOT/bin/rite-health-report"
}
