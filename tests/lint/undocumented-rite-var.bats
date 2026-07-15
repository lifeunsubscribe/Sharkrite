#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/36-undocumented-rite-var-read-in-lib.sh, tools/sharkrite-lint.sh
# Tests for Rule 36: UNDOCUMENTED_RITE_VAR
#
# Verifies that the lint rule correctly flags RITE_* variable reads in lib/
# that are absent from both config/project.conf.example and
# config/rite.conf.example (and not in the ledger), and passes on documented
# vars, ledgered vars, and suppressed lines.
#
# Fixture injection:
#   Fixtures are written into BATS_TEST_TMPDIR and injected via
#   RITE_LINT_EXTRA_DIRS so the linter scans them without touching the
#   project's own lib/ tree. Each test creates a lib/-structured dir
#   so the rule (scoped to lib/*.sh) fires correctly.

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"

  # Fixture directory: mimic lib/utils/ structure so Rule 36 fires
  # (rule filters SHELL_FILES to */lib/*.sh)
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/r36-fixtures/lib/utils"
  mkdir -p "$FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="${BATS_TEST_TMPDIR}/r36-fixtures/lib/utils"
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR}/r36-fixtures"
  unset RITE_LINT_EXTRA_DIRS
}

# Helper: write a fixture file and run lint.
_run_lint_with_fixture() {
  local name="$1"
  local content="$2"
  printf '%s\n' "$content" > "$FIXTURE_DIR/${name}.sh"
  run bash "$LINT_SCRIPT"
}

# ---------------------------------------------------------------------------
# Should FIRE (violation): brand-new RITE_* var absent from both config
# examples and not in the ledger.
# RITE_TOTALLY_NEW_UNDOCUMENTED_VAR is intentionally absent from both
# config examples and the ledger — it should fire.
# ---------------------------------------------------------------------------

@test "rule fires: undocumented RITE_TOTALLY_NEW_UNDOCUMENTED_VAR read in lib/" {
  _run_lint_with_fixture "bad-new-rite-var" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_BAD_R36_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_BAD_R36_LOADED=true

do_something() {
  local val="${RITE_TOTALLY_NEW_UNDOCUMENTED_VAR:-}"
  echo "$val"
}'

  [[ "$output" == *"UNDOCUMENTED_RITE_VAR"* ]]
}

# ---------------------------------------------------------------------------
# Should PASS: var present in config/project.conf.example (documented set).
# RITE_ASSESSMENT_TIMEOUT is documented in project.conf.example line 74.
# ---------------------------------------------------------------------------

@test "rule passes: RITE_ASSESSMENT_TIMEOUT is documented in project.conf.example" {
  _run_lint_with_fixture "good-documented-var" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_GOOD_R36A_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_GOOD_R36A_LOADED=true

check_timeout() {
  local t="${RITE_ASSESSMENT_TIMEOUT:-300}"
  echo "$t"
}'

  local r36_lines
  r36_lines=$(echo "$output" | grep "UNDOCUMENTED_RITE_VAR" || true)
  [[ "$r36_lines" != *"good-documented-var"* ]]
}

# ---------------------------------------------------------------------------
# Should PASS: var present in the ledger (pre-existing exemption).
# RITE_GATE_FLAKE_RETRY is in the ledger but absent from both config examples.
# ---------------------------------------------------------------------------

@test "rule passes: RITE_GATE_FLAKE_RETRY is in the ledger (pre-existing exemption)" {
  _run_lint_with_fixture "good-ledgered-var" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_GOOD_R36B_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_GOOD_R36B_LOADED=true

run_gate() {
  local retry="${RITE_GATE_FLAKE_RETRY:-0}"
  echo "$retry"
}'

  local r36_lines
  r36_lines=$(echo "$output" | grep "UNDOCUMENTED_RITE_VAR" || true)
  [[ "$r36_lines" != *"good-ledgered-var"* ]]
}

# ---------------------------------------------------------------------------
# Should PASS: suppression comment on the preceding line silences the rule.
# ---------------------------------------------------------------------------

@test "rule passes: suppression comment on preceding line" {
  _run_lint_with_fixture "good-suppressed-var" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_GOOD_R36C_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_GOOD_R36C_LOADED=true

do_internal() {
  # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_INTERNAL_ONLY_MARKER is a private runtime signal, not a config var; _RITE_ prefix cannot be used as it collides with re-source guard naming
  local val="${RITE_INTERNAL_ONLY_MARKER:-}"
  echo "$val"
}'

  local r36_lines
  r36_lines=$(echo "$output" | grep "UNDOCUMENTED_RITE_VAR" || true)
  [[ "$r36_lines" != *"good-suppressed-var"* ]]
}

# ---------------------------------------------------------------------------
# Should PASS: full-line comments with RITE_ vars are ignored.
# ---------------------------------------------------------------------------

@test "rule passes: full-line comment containing a RITE_ var is skipped" {
  _run_lint_with_fixture "good-comment-only-r36" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_GOOD_R36D_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_GOOD_R36D_LOADED=true

# Uses RITE_TOTALLY_NEW_UNDOCUMENTED_VAR — see config.sh
do_something() {
  echo "hello"
}'

  local r36_lines
  r36_lines=$(echo "$output" | grep "UNDOCUMENTED_RITE_VAR" || true)
  [[ "$r36_lines" != *"good-comment-only-r36"* ]]
}

# ---------------------------------------------------------------------------
# Should FIRE: multiple RITE_* vars on one line — second var must not escape.
# Before the fix, head -1 extracted only the first var; any undocumented second
# var on the same line was silently skipped.
# ---------------------------------------------------------------------------

@test "rule fires: second undocumented RITE_* var on same line is also detected" {
  _run_lint_with_fixture "bad-two-vars-on-line" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_BAD_R36_TWO_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_BAD_R36_TWO_LOADED=true

compare_timeouts() {
  [ "${RITE_ASSESSMENT_TIMEOUT:-300}" = "${RITE_TOTALLY_NEW_UNDOCUMENTED_VAR:-}" ]
}'

  [[ "$output" == *"UNDOCUMENTED_RITE_VAR"* ]]
  [[ "$output" == *"RITE_TOTALLY_NEW_UNDOCUMENTED_VAR"* ]]
}

# ---------------------------------------------------------------------------
# Should PASS: all vars on a line are documented — no false positives.
# ---------------------------------------------------------------------------

@test "rule passes: multiple documented vars on the same line" {
  _run_lint_with_fixture "good-two-documented-vars" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_GOOD_R36E_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_GOOD_R36E_LOADED=true

compare() {
  [ "${RITE_ASSESSMENT_TIMEOUT:-300}" = "${RITE_MAX_SESSION_HOURS:-12}" ]
}'

  local r36_lines
  r36_lines=$(echo "$output" | grep "UNDOCUMENTED_RITE_VAR" || true)
  [[ "$r36_lines" != *"good-two-documented-vars"* ]]
}

# ---------------------------------------------------------------------------
# Should PASS: suppression comment covers all vars on the line (not just first).
# ---------------------------------------------------------------------------

@test "rule passes: suppression comment silences all vars on a multi-var line" {
  _run_lint_with_fixture "good-suppressed-multivar" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_GOOD_R36F_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_GOOD_R36F_LOADED=true

compare_internal() {
  # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: both vars are private runtime signals, not config vars
  [ "${RITE_INTERNAL_SIGNAL_A:-}" = "${RITE_INTERNAL_SIGNAL_B:-}" ]
}'

  local r36_lines
  r36_lines=$(echo "$output" | grep "UNDOCUMENTED_RITE_VAR" || true)
  [[ "$r36_lines" != *"good-suppressed-multivar"* ]]
}

# ---------------------------------------------------------------------------
# Structural: Rule 36 file and ledger exist and are found by driver.
# ---------------------------------------------------------------------------

@test "lint rule UNDOCUMENTED_RITE_VAR exists in lint-rules directory" {
  run grep -qr "UNDOCUMENTED_RITE_VAR" "$(dirname "$LINT_SCRIPT")/lint-rules"
  [ "$status" -eq 0 ]
}

@test "ledger file exists and contains RITE_GATE_FLAKE_RETRY" {
  local ledger
  ledger="$(dirname "$LINT_SCRIPT")/lint-rules/36-undocumented-rite-var.ledger"
  [ -f "$ledger" ]
  grep -qxF "RITE_GATE_FLAKE_RETRY" "$ledger"
}
