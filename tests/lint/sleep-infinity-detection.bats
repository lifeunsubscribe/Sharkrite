#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/26-non-portable-sleep-infinity-sleep-inf-bsd-ma.sh, tools/sharkrite-lint.sh
# Tests for Rule 26: SLEEP_INFINITY_NOT_PORTABLE
#
# Verifies the lint rule flags `sleep infinity` / `sleep inf` (which BSD/macOS
# /bin/sleep rejects — it exits immediately instead of sleeping) and passes on
# finite sleep values, documentation comments, and suppressed lines.
#
# Bug context (this session): tests/helpers/{gh-mock,claude-mock}.bash used
# `sleep infinity` to simulate a hung subprocess; on macOS BSD sleep returned
# instantly, defeating the hang. Fixed to `sleep 2147483647`.
#
# Fixture injection: fixtures are written into BATS_TEST_TMPDIR and injected via
# RITE_LINT_EXTRA_DIRS so the linter scans them without touching the project tree.

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/sleep-inf-fixtures/lib/utils"
  mkdir -p "$FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR"
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR}/sleep-inf-fixtures"
  unset RITE_LINT_EXTRA_DIRS
}

_run_lint_with_fixture() {
  local name="$1"
  local content="$2"
  printf '%s\n' "$content" > "$FIXTURE_DIR/${name}.sh"
  run bash "$LINT_SCRIPT"
}

# --------------------------------------------------------------------------
# Should FIRE
# --------------------------------------------------------------------------

@test "rule fires: sleep infinity" {
  _run_lint_with_fixture "bad-sleep-infinity" '#!/bin/bash
hang() {
  sleep infinity
}'
  [[ "$output" == *"SLEEP_INFINITY_NOT_PORTABLE"* ]]
  [[ "$output" == *"bad-sleep-infinity"* ]]
}

@test "rule fires: sleep inf" {
  _run_lint_with_fixture "bad-sleep-inf" '#!/bin/bash
hang() {
  sleep inf
}'
  [[ "$output" == *"SLEEP_INFINITY_NOT_PORTABLE"* ]]
  [[ "$output" == *"bad-sleep-inf"* ]]
}

@test "rule fires: exec sleep infinity (compound command)" {
  _run_lint_with_fixture "bad-exec-sleep" '#!/bin/bash
start() {
  exec sleep infinity
}'
  [[ "$output" == *"SLEEP_INFINITY_NOT_PORTABLE"* ]]
  [[ "$output" == *"bad-exec-sleep"* ]]
}

@test "rule fires: backgrounded subshell ( sleep infinity ) &" {
  _run_lint_with_fixture "bad-bg-sleep" '#!/bin/bash
start() {
  ( sleep infinity ) &
}'
  [[ "$output" == *"SLEEP_INFINITY_NOT_PORTABLE"* ]]
  [[ "$output" == *"bad-bg-sleep"* ]]
}

# --------------------------------------------------------------------------
# Should PASS
# --------------------------------------------------------------------------

@test "rule passes: finite sleep value (2147483647)" {
  _run_lint_with_fixture "good-finite" '#!/bin/bash
hang() {
  sleep 2147483647
}'
  local lines
  lines=$(echo "$output" | grep "SLEEP_INFINITY_NOT_PORTABLE" || true)
  [[ "$lines" != *"good-finite"* ]]
}

@test "rule passes: numeric and variable sleep values" {
  _run_lint_with_fixture "good-numeric" '#!/bin/bash
wait_a_bit() {
  sleep 0.5
  sleep 3
  sleep "$timeout"
  sleep $POLL_INTERVAL
}'
  local lines
  lines=$(echo "$output" | grep "SLEEP_INFINITY_NOT_PORTABLE" || true)
  [[ "$lines" != *"good-numeric"* ]]
}

@test "rule passes: comment documenting the non-portable pattern" {
  _run_lint_with_fixture "good-comment" '#!/bin/bash
hang() {
  # Portable forever-sleep: BSD /bin/sleep rejects sleep infinity, use a finite value
  sleep 2147483647
}'
  local lines
  lines=$(echo "$output" | grep "SLEEP_INFINITY_NOT_PORTABLE" || true)
  [[ "$lines" != *"good-comment"* ]]
}

@test "rule passes: infinity in a string comparison, not a sleep arg" {
  _run_lint_with_fixture "good-string" '#!/bin/bash
hang() {
  if [ "${MOCK_HANG_DURATION:-infinity}" = "infinity" ]; then
    sleep 2147483647
  fi
}'
  local lines
  lines=$(echo "$output" | grep "SLEEP_INFINITY_NOT_PORTABLE" || true)
  [[ "$lines" != *"good-string"* ]]
}

@test "rule passes: suppression comment on preceding line" {
  _run_lint_with_fixture "good-suppressed" '#!/bin/bash
hang() {
  # sharkrite-lint disable SLEEP_INFINITY_NOT_PORTABLE - reason: Linux-only CI helper
  sleep infinity
}'
  local lines
  lines=$(echo "$output" | grep "SLEEP_INFINITY_NOT_PORTABLE" || true)
  [[ "$lines" != *"good-suppressed"* ]]
}

# --------------------------------------------------------------------------
# Codebase sweep + rule presence
# --------------------------------------------------------------------------

@test "codebase: production tree has zero SLEEP_INFINITY_NOT_PORTABLE violations" {
  unset RITE_LINT_EXTRA_DIRS   # scan only the project tree, not fixtures
  run bash "$LINT_SCRIPT"
  local violations
  violations=$(echo "$output" | grep "SLEEP_INFINITY_NOT_PORTABLE" || true)
  if [ -n "$violations" ]; then
    echo "SLEEP_INFINITY_NOT_PORTABLE violations found:" >&3
    echo "$violations" >&3
    false
  fi
}

@test "lint rule SLEEP_INFINITY_NOT_PORTABLE is defined in sharkrite-lint.sh" {
  # Post-#952 the linter is driver + tools/lint-rules/ fragments — rule
  # bodies live in the fragments, so the assertion must search both.
  run grep -qr "SLEEP_INFINITY_NOT_PORTABLE" "$LINT_SCRIPT" "$(dirname "$LINT_SCRIPT")/lint-rules"
  [ "$status" -eq 0 ]
}
