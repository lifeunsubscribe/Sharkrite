#!/usr/bin/env bats
# sharkrite-test-covers: tools/*-lint.sh
# Tests for Rule 26: BSD_DATE_PARSE_Z_WITHOUT_U
#
# Verifies the lint rule flags BSD `date -jf` invocations that parse a Z/UTC
# timestamp to epoch (+%s) without -u (which silently skews the epoch by the
# local UTC offset), and correctly passes the safe forms: -u present (any flag
# ordering), %z numeric-offset formats, date-only/no-Z formats, and non-epoch
# display conversions.
#
# Fixture injection: fixtures are written into BATS_TEST_TMPDIR and injected via
# RITE_LINT_EXTRA_DIRS so the linter scans them without touching lib/.

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/date-jf-fixtures"
  mkdir -p "$FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
  unset RITE_LINT_EXTRA_DIRS
}

_run_lint_with_fixture() {
  local name="$1"
  local content="$2"
  printf '%s\n' "$content" > "$FIXTURE_DIR/${name}.sh"
  run bash "$LINT_SCRIPT"
}

# ---------------------------------------------------------------------------
# Should FIRE
# ---------------------------------------------------------------------------

@test "rule fires: date -jf Z-format to +%s without -u" {
  _run_lint_with_fixture "bad-jf" '#!/usr/bin/env bash
e=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s)'
  [[ "$output" == *"BSD_DATE_PARSE_Z_WITHOUT_U"* ]]
}

@test "rule fires: date -j -f (split flags) Z-format to +%s without -u" {
  _run_lint_with_fixture "bad-split" '#!/usr/bin/env bash
e=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s")'
  [[ "$output" == *"BSD_DATE_PARSE_Z_WITHOUT_U"* ]]
}

# ---------------------------------------------------------------------------
# Should PASS
# ---------------------------------------------------------------------------

@test "rule passes: -u present (date -u -jf)" {
  _run_lint_with_fixture "good-u" '#!/usr/bin/env bash
e=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s)'
  [[ "$output" != *"BSD_DATE_PARSE_Z_WITHOUT_U"* ]]
}

@test "rule passes: -u fused in flag cluster (date -juf)" {
  _run_lint_with_fixture "good-juf" '#!/usr/bin/env bash
e=$(date -juf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s)'
  [[ "$output" != *"BSD_DATE_PARSE_Z_WITHOUT_U"* ]]
}

@test "rule passes: %z numeric-offset format (timezone-safe)" {
  _run_lint_with_fixture "good-pctz" '#!/usr/bin/env bash
e=$(date -jf "%Y-%m-%dT%H:%M:%S%z" "$ts" +%s)'
  [[ "$output" != *"BSD_DATE_PARSE_Z_WITHOUT_U"* ]]
}

@test "rule passes: date-only format (no Z, no time-of-day skew)" {
  _run_lint_with_fixture "good-dateonly" '#!/usr/bin/env bash
e=$(date -j -f "%Y-%m-%d" "$d" +%s)'
  [[ "$output" != *"BSD_DATE_PARSE_Z_WITHOUT_U"* ]]
}

@test "rule passes: Z-format but non-epoch display output (+%b)" {
  _run_lint_with_fixture "good-display" '#!/usr/bin/env bash
d=$(date -j -f "%Y-%m-%d %H:%M:%S" "$x" "+%b %d, %Y - %-I:%M %p %Z")'
  [[ "$output" != *"BSD_DATE_PARSE_Z_WITHOUT_U"* ]]
}

@test "rule passes: suppression comment on preceding line" {
  _run_lint_with_fixture "good-suppress" '#!/usr/bin/env bash
# sharkrite-lint disable BSD_DATE_PARSE_Z_WITHOUT_U - Reason: intentional local parse
e=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s)'
  [[ "$output" != *"BSD_DATE_PARSE_Z_WITHOUT_U"* ]]
}
