#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, tools/sharkrite-lint.sh
# tests/regression/jq-default-brace-expansion.bats
#
# Regression test for the ${VAR:-{}} parameter expansion bug.
#
# Bug: Bash parses ${VAR:-{}} as ${VAR:-{} (default value: '{') followed by
# a literal '}'. So when VAR is non-empty, the result is "$VAR}" — corrupting
# any JSON that already ends in '}'.
#
# Live failure: rite batch died at "Processing Issue #14" with
#   jq: parse error: Unmatched '}' at line 1, column 450
# because the issue API response was 449 chars ending in '}', and the
# expansion added a stray '}'.
#
# Fix: quote the default — "${VAR:-"{}"}".
#
# Tests:
#   1. Confirm the buggy form corrupts non-empty values (negative control)
#   2. Confirm the fixed form preserves non-empty values
#   3. Confirm the fixed form returns {} for empty/unset values
#   4. Lint rule JQ_DEFAULT_BRACE flags the buggy pattern
#   5. No occurrences of the buggy pattern in tracked source files

@test "buggy form ${VAR:-{}} appends stray '}' to non-empty JSON" {
  X='{"a":1}'
  Y="${X:-{}}"
  # The bug: 7-char input becomes 8-char output with trailing '}}'
  [ "${#Y}" -eq 8 ]
  [ "${Y: -2}" = '}}' ]
}

@test "fixed form ${VAR:-\"{}\"} preserves non-empty JSON" {
  X='{"a":1}'
  Y="${X:-"{}"}"
  [ "${#Y}" -eq 7 ]
  [ "$Y" = '{"a":1}' ]
}

@test "fixed form ${VAR:-\"{}\"} returns {} for empty value" {
  X=""
  Y="${X:-"{}"}"
  [ "$Y" = '{}' ]
}

@test "fixed form ${VAR:-\"{}\"} returns {} for unset value" {
  unset X
  Y="${X:-"{}"}"
  [ "$Y" = '{}' ]
}

@test "real-world JSON survives the fixed form and parses with jq" {
  X='{"labels":[{"name":"bug"}],"state":"CLOSED","title":"x"}'
  Y="${X:-"{}"}"
  result=$(echo "$Y" | jq -r '.state')
  [ "$result" = 'CLOSED' ]
}

@test "lint rule JQ_DEFAULT_BRACE flags the buggy pattern" {
  # Inject the fixture via the supported RITE_LINT_EXTRA_DIRS mechanism and run
  # the real lint script in place. sharkrite-lint.sh recomputes PROJECT_ROOT from
  # BASH_SOURCE[0] (mirrors the Makefile anchors), so a PROJECT_ROOT env override
  # has no effect — RITE_LINT_EXTRA_DIRS is the documented injection path.
  fixture_dir="${BATS_TEST_TMPDIR}/jq-fixture"
  mkdir -p "$fixture_dir"
  cat > "$fixture_dir/buggy.sh" <<'SH'
#!/usr/bin/env bash
VAR=$(some_command)
VAR="${VAR:-{}}"
SH

  run env RITE_LINT_EXTRA_DIRS="$fixture_dir" bash "${BATS_TEST_DIRNAME}/../../tools/sharkrite-lint.sh"
  [[ "$output" == *"JQ_DEFAULT_BRACE"* ]]
}

@test "no occurrences of the buggy pattern remain in tracked source" {
  cd "${BATS_TEST_DIRNAME}/../.."
  run grep -rn ':-{}}' lib/ bin/
  [ "$status" -ne 0 ]
}
