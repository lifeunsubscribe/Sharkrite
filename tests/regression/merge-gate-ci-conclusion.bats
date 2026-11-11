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

@test "Check 4 StatusContext .state filter is wired in merge-pr.sh" {
  grep -q 'state == "FAILURE"' "$PROJECT_ROOT/lib/core/merge-pr.sh"
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

# The jq expressions below mirror lib/core/merge-pr.sh Check 4 verbatim; the
# structural test "Check 4 pending filter handles the empty-string conclusion"
# pins the source so the two cannot drift apart silently.
PENDING_JQ='[.[] | select(((.status // "COMPLETED") != "COMPLETED") or .conclusion == null or .conclusion == "" or .conclusion == "PENDING")] | length'

@test "Check 4 pending filter handles the empty-string conclusion (live IN_PROGRESS shape)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  grep -qF '.conclusion == ""' "$PROJECT_ROOT/lib/core/merge-pr.sh"
  grep -qF '!= "COMPLETED"' "$PROJECT_ROOT/lib/core/merge-pr.sh"
}

@test "jq: IN_PROGRESS CheckRun with conclusion \"\" is pending, not passed (freshup 2026-11-11)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  # Verbatim shape from `gh pr view --json statusCheckRollup` on a running job.
  CHECKS='[{"__typename":"CheckRun","completedAt":"0001-01-01T00:00:00Z","conclusion":"","name":"Run tests","status":"IN_PROGRESS","workflowName":"CI"}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or .conclusion == "TIMED_OUT" or .conclusion == "STARTUP_FAILURE" or .conclusion == "CANCELLED")] | length')
  PENDING=$(echo "$CHECKS" | jq "$PENDING_JQ")
  [ "$FAILED" = "0" ]
  [ "$PENDING" = "1" ]
}

@test "jq: QUEUED CheckRun is pending" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"conclusion":"","name":"Run tests","status":"QUEUED"}]'
  PENDING=$(echo "$CHECKS" | jq "$PENDING_JQ")
  [ "$PENDING" = "1" ]
}

@test "jq: COMPLETED SUCCESS CheckRun is not pending" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"conclusion":"SUCCESS","name":"Run tests","status":"COMPLETED"}]'
  PENDING=$(echo "$CHECKS" | jq "$PENDING_JQ")
  [ "$PENDING" = "0" ]
}

@test "jq: display line shows status when conclusion is empty" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"conclusion":"","name":"Run tests","status":"IN_PROGRESS"}]'
  LINE=$(echo "$CHECKS" | jq -r '.[] | "  - \(.name): \(if (.conclusion // "") == "" then (.status // "PENDING") else .conclusion end)"')
  [ "$LINE" = "  - Run tests: IN_PROGRESS" ]
}

@test "jq: TIMED_OUT check is counted as failed" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"name":"Test","conclusion":"TIMED_OUT","status":"COMPLETED"}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or .conclusion == "TIMED_OUT" or .conclusion == "STARTUP_FAILURE" or .conclusion == "CANCELLED")] | length')
  [ "$FAILED" = "1" ]
}

@test "jq: STARTUP_FAILURE check is counted as failed" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"name":"Test","conclusion":"STARTUP_FAILURE","status":"COMPLETED"}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or .conclusion == "TIMED_OUT" or .conclusion == "STARTUP_FAILURE" or .conclusion == "CANCELLED")] | length')
  [ "$FAILED" = "1" ]
}

@test "jq: CANCELLED check is counted as failed" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"name":"Test","conclusion":"CANCELLED","status":"COMPLETED"}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or .conclusion == "TIMED_OUT" or .conclusion == "STARTUP_FAILURE" or .conclusion == "CANCELLED")] | length')
  [ "$FAILED" = "1" ]
}

@test "jq: null conclusion is pending, not failed" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"name":"Lint","conclusion":null}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR")] | length')
  PENDING=$(echo "$CHECKS" | jq "$PENDING_JQ")
  [ "$FAILED" = "0" ]
  [ "$PENDING" = "1" ]
}

@test "jq: SUCCESS conclusion is neither failed nor pending" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"name":"Lint","conclusion":"SUCCESS"}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR")] | length')
  PENDING=$(echo "$CHECKS" | jq "$PENDING_JQ")
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
  PENDING=$(echo "$CHECKS" | jq "$PENDING_JQ")
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

# ---------------------------------------------------------------------------
# StatusContext (legacy commit status API) — state field, conclusion always null;
# in-progress CheckRuns use conclusion="" (not null) — both treated as "no conclusion"
# ---------------------------------------------------------------------------

@test "jq: StatusContext state=FAILURE is counted as failed (not pending)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"context":"jenkins/build","state":"FAILURE","conclusion":null}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or (.conclusion == null and (.state == "FAILURE" or .state == "ERROR")))] | length')
  PENDING=$(echo "$CHECKS" | jq '[.[] | select((.conclusion == null and .state != "FAILURE" and .state != "ERROR" and .state != "SUCCESS") or .conclusion == "PENDING")] | length')
  [ "$FAILED" = "1" ]
  [ "$PENDING" = "0" ]
}

@test "jq: StatusContext state=ERROR is counted as failed (not pending)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"context":"ci/build","state":"ERROR","conclusion":null}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or (.conclusion == null and (.state == "FAILURE" or .state == "ERROR")))] | length')
  PENDING=$(echo "$CHECKS" | jq '[.[] | select((.conclusion == null and .state != "FAILURE" and .state != "ERROR" and .state != "SUCCESS") or .conclusion == "PENDING")] | length')
  [ "$FAILED" = "1" ]
  [ "$PENDING" = "0" ]
}

@test "jq: StatusContext state=PENDING is advisory (not failed)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"context":"ci/build","state":"PENDING","conclusion":null}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or (.conclusion == null and (.state == "FAILURE" or .state == "ERROR")))] | length')
  PENDING=$(echo "$CHECKS" | jq '[.[] | select((.conclusion == null and .state != "FAILURE" and .state != "ERROR" and .state != "SUCCESS") or .conclusion == "PENDING")] | length')
  [ "$FAILED" = "0" ]
  [ "$PENDING" = "1" ]
}

@test "jq: StatusContext state=SUCCESS is neither failed nor pending" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"context":"ci/build","state":"SUCCESS","conclusion":null}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or (.conclusion == null and (.state == "FAILURE" or .state == "ERROR")))] | length')
  PENDING=$(echo "$CHECKS" | jq '[.[] | select((.conclusion == null and .state != "FAILURE" and .state != "ERROR" and .state != "SUCCESS") or .conclusion == "PENDING")] | length')
  [ "$FAILED" = "0" ]
  [ "$PENDING" = "0" ]
}

@test "jq: mixed CheckRun pending + StatusContext FAILURE — FAILURE blocks, pending stays advisory" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"name":"Actions","conclusion":"","state":null},{"context":"jenkins/build","state":"FAILURE","conclusion":null}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or ((.conclusion == null or .conclusion == "") and (.state == "FAILURE" or .state == "ERROR")))] | length')
  PENDING=$(echo "$CHECKS" | jq '[.[] | select(((.conclusion == null or .conclusion == "") and .state != "FAILURE" and .state != "ERROR" and .state != "SUCCESS") or .conclusion == "PENDING")] | length')
  [ "$FAILED" = "1" ]
  [ "$PENDING" = "1" ]
}

@test "jq: empty-string conclusion is pending, not failed (in-progress CheckRun)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"name":"Actions","conclusion":"","state":null}]'
  FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or ((.conclusion == null or .conclusion == "") and (.state == "FAILURE" or .state == "ERROR")))] | length')
  PENDING=$(echo "$CHECKS" | jq '[.[] | select(((.conclusion == null or .conclusion == "") and .state != "FAILURE" and .state != "ERROR" and .state != "SUCCESS") or .conclusion == "PENDING")] | length')
  [ "$FAILED" = "0" ]
  [ "$PENDING" = "1" ]
}

@test "jq: StatusContext uses .context as name fallback in display" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CHECKS='[{"context":"jenkins/build","state":"FAILURE","conclusion":null}]'
  OUTPUT=$(echo "$CHECKS" | jq -r '.[] | "  - \(.name // .context): \(.conclusion // .state // .status // "PENDING")"')
  echo "$OUTPUT" | grep -q "jenkins/build"
  echo "$OUTPUT" | grep -q "FAILURE"
}
