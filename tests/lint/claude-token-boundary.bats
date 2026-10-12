#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh, tools/lint-rules/09-claude-specific-tokens-in-lib-core-provider.sh
#
# Rule 09 SLASH_EXIT boundary: a doc-path reference like
# "docs/architecture/exit-codes.md" in a trailing comment must NOT trip the
# provider-token rule, while a genuine "/exit" token still must.
# Live FP: batch-process-issues.sh:999 killed issue #916's gate (2026-10-12).
#
# Fixture injection via RITE_LINT_EXTRA_DIRS (same harness as
# sleep-infinity-detection.bats); lint invocations scoped per the
# SHARKRITE_LINT_ONLY convention (#1088).

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/rule09-fixtures"
  mkdir -p "$FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR"
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR}/rule09-fixtures"
  unset RITE_LINT_EXTRA_DIRS
}

_run_rule9_with_fixture() {
  local name="$1"
  local content="$2"
  printf '%s\n' "$content" > "$FIXTURE_DIR/${name}.sh"
  SHARKRITE_LINT_ONLY=09 run bash "$LINT_SCRIPT"
}

@test "rule 09 silent: /exit-codes.md doc reference in trailing comment" {
  _run_rule9_with_fixture "fp-exit-codes" '#!/bin/bash
set -euo pipefail
exit 20  # exit 20: green-main preflight halt (see docs/architecture/exit-codes.md)'
  [[ "$output" != *"fp-exit-codes"* ]]
}

@test "rule 09 fires: genuine /exit token in a prompt string" {
  _run_rule9_with_fixture "real-exit" '#!/bin/bash
set -euo pipefail
PROMPT="When all phases are complete, immediately exit with /exit"'
  [[ "$output" == *"real-exit"* ]]
  [[ "$output" == *"/exit"* ]]
}

@test "rule 09 fires: /exit at end of line" {
  _run_rule9_with_fixture "eol-exit" '#!/bin/bash
set -euo pipefail
INSTRUCTION=/exit'
  [[ "$output" == *"eol-exit"* ]]
}
