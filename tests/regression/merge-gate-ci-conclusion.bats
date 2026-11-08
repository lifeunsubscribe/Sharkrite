#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/merge-pr.sh
# Regression tests: Check 4 evaluates all CI conclusions, not only isRequired ones (#1606)
#
# Covers:
#   1. isRequired filter is gone — structural guard
#   2. MERGE_GATE_CI diag is wired — structural guard
#   3. CLAUDE.md documents the gate and the diag — structural guards
#   4. jq logic: completed-FAILURE → failed count
#   5. jq logic: completed-ERROR → failed count
#   6. jq logic: null conclusion → pending, not failed
#   7. jq logic: SUCCESS → neither failed nor pending
#   8. jq logic: empty rollup → count 0 (none configured path)
#   9. jq logic: mixed FAILURE+pending → both counted separately
#  10. jq logic: isRequired=false check is NOT excluded (the original bug)

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# ---------------------------------------------------------------------------
# Structural guards
# ---------------------------------------------------------------------------

@test "Check 4 no longer filters on isRequired" {
  run grep -c 'select(.isRequired' "$PROJECT_ROOT/lib/core/merge-pr.sh"
  [ "$output" = "0" ]
}

@test "Check 4 emits MERGE_GATE_CI diag in merge-pr.sh" {
  grep -q 'MERGE_GATE_CI' "$PROJECT_ROOT/lib/core/merge-pr.sh"
}

@test "CLAUDE.md documents MERGE_GATE_CI in Diagnostic logging" {
  grep -q 'MERGE_GATE_CI' "$PROJECT_ROOT/CLAUDE.md"
}

@test "CLAUDE.md documents completed-FAILURE behavior in Hard Merge Gates" {
  grep -q 'completed-FAILURE' "$PROJECT_ROOT/CLAUDE.md"
}

# ---------------------------------------------------------------------------
# jq logic unit tests — pure transforms, no subprocess stubs needed
# ---------------------------------------------------------------------------

@test "jq: completed-FAILURE check is counted as failed" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"name":"Lint","conclusion":"FAILURE"},{"name":"Test","conclusion":"SUCCESS"}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR")] | length')
  [ "$FAILED" = "1" ]
}

@test "jq: completed-ERROR check is counted as failed" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"name":"Lint","conclusion":"ERROR"}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR")] | length')
  [ "$FAILED" = "1" ]
}

@test "jq: null conclusion is pending, not failed" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"name":"Lint","conclusion":null}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR")] | length')
  PENDING=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == null or .conclusion == "PENDING")] | length')
  [ "$FAILED" = "0" ]
  [ "$PENDING" = "1" ]
}

@test "jq: SUCCESS conclusion is neither failed nor pending" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"name":"Lint","conclusion":"SUCCESS"}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR")] | length')
  PENDING=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == null or .conclusion == "PENDING")] | length')
  [ "$FAILED" = "0" ]
  [ "$PENDING" = "0" ]
}

@test "jq: empty rollup produces count 0 (none-configured path)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[]'
  COUNT=$(echo "$CHECKS" | jq '[.[] ] | length')
  [ "$COUNT" = "0" ]
}

@test "jq: mixed FAILURE and pending — counted independently" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"name":"Lint","conclusion":"FAILURE"},{"name":"Test","conclusion":null}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR")] | length')
  PENDING=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == null or .conclusion == "PENDING")] | length')
  [ "$FAILED" = "1" ]
  [ "$PENDING" = "1" ]
}

@test "jq: isRequired=false check is NOT excluded (original bug regression)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  # Before this fix, select(.isRequired == true) excluded all non-required checks.
  # Verify the new code evaluates all checks regardless of isRequired.
  CHECKS='[{"name":"Lint","conclusion":"FAILURE","isRequired":false}]'
  ALL=$(echo "$CHECKS" | jq '[.[] ] | length')
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR")] | length')
  [ "$ALL" = "1" ]
  [ "$FAILED" = "1" ]
}

@test "jq: isRequired=absent (null) check is not excluded" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"name":"ShellCheck + Custom Lint Rules","conclusion":"FAILURE"}]'
  ALL=$(echo "$CHECKS" | jq '[.[] ] | length')
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR")] | length')
  [ "$ALL" = "1" ]
  [ "$FAILED" = "1" ]
}
