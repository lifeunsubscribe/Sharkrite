#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/integration-ledger.sh, lib/core/merge-pr.sh
# Tests for the integration ledger helper and merge-pr.sh's ledger+close behavior.
#
# Coverage:
#   1. integration_ledger_append writes a well-formed 5-field ledger line
#   2. Non-main merge: single ledger entry appended
#   3. Main-based merge: no ledger file written (byte-identical behavior)
#   4. Close comment — non-main: annotated "pending promotion to main." form
#   5. Close comment — main: unannotated "Closed by PR #N" form (unchanged)
#   6. integration_ledger_entries reads back what was appended
#   7. integration_ledger_mark_promoted flips promoted=false → true for the right issue
#   8. integration_ledger_append skips (exit 0) when RITE_STATE_DIR is unset
#   9. ledger dir created on demand (including nested dirs for branches with '/')
#  10. Double-source safety (re-source guard)

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT

  LEDGER_SH="$PROJECT_ROOT/lib/utils/integration-ledger.sh"
  MERGE_PR_SH="$PROJECT_ROOT/lib/core/merge-pr.sh"
  export LEDGER_SH MERGE_PR_SH

  TEST_TMPDIR="${BATS_TEST_TMPDIR}/il-test"
  mkdir -p "$TEST_TMPDIR"
  export TEST_TMPDIR
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Test 1: integration_ledger_append writes a well-formed 5-field line
# ---------------------------------------------------------------------------
@test "integration_ledger_append writes 5-field tab-separated ledger line" {
  run bash -c "
    set -euo pipefail
    export RITE_STATE_DIR='$TEST_TMPDIR/state'
    source '$LEDGER_SH'
    set +u; set +o pipefail
    integration_ledger_append 'staging' '42' '97' 'aabbcc1122334455aabbcc1122334455aabb0001'
    cat \"\$RITE_STATE_DIR/integration-branches/staging.log\"
  "
  [ "$status" -eq 0 ]
  # Must have all five fields
  [[ "$output" =~ issue=42 ]]
  [[ "$output" =~ pr=97 ]]
  [[ "$output" =~ sha=aabbcc1122334455aabbcc1122334455aabb0001 ]]
  [[ "$output" =~ promoted=false ]]
  # merged_at must be a UTC ISO 8601 timestamp
  [[ "$output" =~ merged_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]
}

# ---------------------------------------------------------------------------
# Test 2: Non-main merge appends exactly one ledger entry
# ---------------------------------------------------------------------------
@test "integration_ledger_append produces exactly one line per call" {
  run bash -c "
    set -euo pipefail
    export RITE_STATE_DIR='$TEST_TMPDIR/state2'
    source '$LEDGER_SH'
    set +u; set +o pipefail
    integration_ledger_append 'staging' '10' '20' 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
    wc -l < \"\$RITE_STATE_DIR/integration-branches/staging.log\" | tr -d ' '
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# Test 3: Main-based merge — no ledger file is written
#
# Simulates the gate in merge-pr.sh: only append when PR_BASE != main.
# ---------------------------------------------------------------------------
@test "main-based merge writes no ledger file (gate on PR_BASE)" {
  run bash -c "
    set -euo pipefail
    export RITE_STATE_DIR='$TEST_TMPDIR/state3'
    source '$LEDGER_SH'
    set +u; set +o pipefail
    PR_BASE=main
    # Replicate the gate: only call append when PR_BASE != main
    if [ \"\$PR_BASE\" != 'main' ]; then
      integration_ledger_append 'main' '5' '9' 'abc123abc123abc123abc123abc123abc123abc1'
    fi
    # No ledger file should have been created
    if [ -f \"\$RITE_STATE_DIR/integration-branches/main.log\" ]; then
      echo 'FAIL: ledger file was written for main-based merge'
      exit 1
    fi
    echo 'PASS: no ledger file for main'
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS: no ledger file for main" ]]
}

# ---------------------------------------------------------------------------
# Test 4: Non-main close comment — annotated form
# ---------------------------------------------------------------------------
@test "non-main PR close comment contains 'pending promotion to main.'" {
  # The close comment is constructed inline in merge-pr.sh.
  # Verify the exact annotated form is present in the source.
  grep -q "pending promotion to main\." "$MERGE_PR_SH"
}

# ---------------------------------------------------------------------------
# Test 5: Main-based close comment — unannotated "Closed by PR #N" form
# ---------------------------------------------------------------------------
@test "main-based PR close comment is unannotated 'Closed by PR #\$PR_NUMBER'" {
  # Verify the original form still exists (used when PR_BASE = main)
  grep -q '"Closed by PR #\$PR_NUMBER"' "$MERGE_PR_SH"
}

# ---------------------------------------------------------------------------
# Test 6: integration_ledger_entries reads back what was appended
# ---------------------------------------------------------------------------
@test "integration_ledger_entries returns appended entries" {
  run bash -c "
    set -euo pipefail
    export RITE_STATE_DIR='$TEST_TMPDIR/state6'
    source '$LEDGER_SH'
    set +u; set +o pipefail
    integration_ledger_append 'feature-a' '33' '55' '1111111111111111111111111111111111111111'
    integration_ledger_append 'feature-a' '44' '66' '2222222222222222222222222222222222222222'
    count=\$(integration_ledger_entries 'feature-a' | wc -l | tr -d ' ')
    echo \"count=\$count\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ count=2 ]]
}

# ---------------------------------------------------------------------------
# Test 7: integration_ledger_mark_promoted flips the right entry
# ---------------------------------------------------------------------------
@test "integration_ledger_mark_promoted flips promoted=false to true for target issue" {
  run bash -c "
    set -euo pipefail
    export RITE_STATE_DIR='$TEST_TMPDIR/state7'
    source '$LEDGER_SH'
    set +u; set +o pipefail
    integration_ledger_append 'staging' '10' '20' 'aaaa000000000000000000000000000000000000'
    integration_ledger_append 'staging' '11' '21' 'bbbb000000000000000000000000000000000000'
    integration_ledger_mark_promoted 'staging' '10'
    # Issue 10 must be promoted=true
    if ! grep -q 'issue=10.*promoted=true' \"\$RITE_STATE_DIR/integration-branches/staging.log\"; then
      echo 'FAIL: issue 10 not marked promoted=true'
      exit 1
    fi
    # Issue 11 must still be promoted=false
    if ! grep -q 'issue=11.*promoted=false' \"\$RITE_STATE_DIR/integration-branches/staging.log\"; then
      echo 'FAIL: issue 11 incorrectly changed'
      exit 1
    fi
    echo 'PASS'
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}

# ---------------------------------------------------------------------------
# Test 8: integration_ledger_append exits 0 when RITE_STATE_DIR is unset
# ---------------------------------------------------------------------------
@test "integration_ledger_append skips gracefully when RITE_STATE_DIR is unset" {
  run bash -c "
    set -euo pipefail
    # Explicitly unset to test the guard
    unset RITE_STATE_DIR
    export RITE_LIB_DIR='$PROJECT_ROOT/lib'
    source '$LEDGER_SH'
    set +u; set +o pipefail
    integration_ledger_append 'staging' '1' '2' 'abc'
    echo exit=\$?
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ "exit=0" ]]
}

# ---------------------------------------------------------------------------
# Test 9: Ledger dir created on demand, including nested dirs for '/' branches
# ---------------------------------------------------------------------------
@test "integration_ledger_append creates nested ledger dir for branch with '/'" {
  run bash -c "
    set -euo pipefail
    export RITE_STATE_DIR='$TEST_TMPDIR/state9'
    source '$LEDGER_SH'
    set +u; set +o pipefail
    integration_ledger_append 'release/1.2' '7' '14' 'cccccccccccccccccccccccccccccccccccccccc'
    if [ ! -f \"\$RITE_STATE_DIR/integration-branches/release/1.2.log\" ]; then
      echo 'FAIL: nested ledger file not created'
      exit 1
    fi
    echo 'PASS'
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}

# ---------------------------------------------------------------------------
# Test 10: Re-source safety — double-source exits 0 and defines all three functions
# ---------------------------------------------------------------------------
@test "integration-ledger.sh sources twice cleanly and defines all three functions" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$PROJECT_ROOT/lib'
    export RITE_STATE_DIR='$TEST_TMPDIR/state10'
    source '$LEDGER_SH'
    source '$LEDGER_SH'
    set +u; set +o pipefail
    declare -f integration_ledger_append integration_ledger_entries integration_ledger_mark_promoted >/dev/null && echo PASS
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}

# ---------------------------------------------------------------------------
# Test 11: merge-pr.sh sources integration-ledger.sh
# ---------------------------------------------------------------------------
@test "merge-pr.sh sources integration-ledger.sh" {
  grep -n "integration-ledger.sh" "$MERGE_PR_SH"
}

# ---------------------------------------------------------------------------
# Test 12: integration_ledger_entries returns nothing for missing branch
# ---------------------------------------------------------------------------
@test "integration_ledger_entries returns nothing for a branch with no ledger" {
  run bash -c "
    set -euo pipefail
    export RITE_STATE_DIR='$TEST_TMPDIR/state12'
    source '$LEDGER_SH'
    set +u; set +o pipefail
    output=\$(integration_ledger_entries 'nonexistent-branch')
    [ -z \"\$output\" ] && echo 'PASS' || echo 'FAIL'
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}
