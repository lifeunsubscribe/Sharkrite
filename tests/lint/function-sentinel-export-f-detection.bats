#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/22-function-sentinel-re-source-guard-combined-w.sh, tools/sharkrite-lint.sh
# Tests for Rule 22: FUNCTION_SENTINEL_GUARD_WITH_EXPORT_F
#
# The combo of `if declare -f <fn>; then return 0; fi` (function-sentinel
# re-source guard) + `export -f <fn>` at the bottom of the same file is unsafe.
# Subprocesses of a parent that already sourced an older version of the file
# inherit the parent's exported functions; the guard sees the inherited stale
# function, short-circuits, and never redefines anything — so functions added
# to the file after the parent started never appear in the subprocess.
#
# Live failure: PR #350 added detect_lib_shrinkage to blocker-rules.sh mid-batch.
# Every subsequent batch issue's create-pr.sh subprocess inherited stale exports
# from batch-process-issues.sh, the function-sentinel guard fired, and
# detect_lib_shrinkage was never defined → "command not found" → batch died.
#
# Fix the file ships with: variable-sentinel guard that is NOT exported.
# Subprocesses see the variable unset → re-source against the on-disk file.
#
# See: lib/utils/blocker-rules.sh:18-38 (canonical pattern)
#      tests/regression/blocker-rules-stale-inherited-functions.bats (behavior)

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"

  FIXTURE_DIR="${BATS_TEST_TMPDIR}/fn-sentinel-export-f-fixtures"
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
# Should FIRE (violations)
# ---------------------------------------------------------------------------

@test "rule fires: function-sentinel guard + export -f in same file" {
  _run_lint_with_fixture "bad-combo" '#!/bin/bash
set -euo pipefail

if declare -f my_func >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

my_func() { echo "hello"; }

export -f my_func'

  [[ "$output" == *"FUNCTION_SENTINEL_GUARD_WITH_EXPORT_F"* ]]
  [[ "$output" == *"bad-combo"* ]]
}

@test "rule fires: guard further down (after env var defaults), still unsafe" {
  _run_lint_with_fixture "bad-late-guard" '#!/bin/bash
set -euo pipefail

# Env var defaults must come before the guard so subprocess re-source still
# gets them. The guard still triggers Rule 22 because export -f exists below.
: "${MY_CONFIG_VAR:=default}"
export MY_CONFIG_VAR

if declare -f my_func >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

my_func() { echo "hello"; }

export -f my_func'

  [[ "$output" == *"FUNCTION_SENTINEL_GUARD_WITH_EXPORT_F"* ]]
  [[ "$output" == *"bad-late-guard"* ]]
}

# ---------------------------------------------------------------------------
# Should PASS (no violation)
# ---------------------------------------------------------------------------

@test "rule passes: variable-sentinel guard + export -f (the fix)" {
  _run_lint_with_fixture "good-var-guard" '#!/bin/bash
set -euo pipefail

if [ "${_FIXTURE_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_FIXTURE_LOADED=true

my_func() { echo "hello"; }

export -f my_func'

  local r22_lines
  r22_lines=$(echo "$output" | grep "FUNCTION_SENTINEL_GUARD_WITH_EXPORT_F" || true)
  [[ "$r22_lines" != *"good-var-guard"* ]]
}

@test "rule passes: function-sentinel guard WITHOUT export -f (safe — no inheritance vector)" {
  _run_lint_with_fixture "good-fn-guard-no-export" '#!/bin/bash
set -euo pipefail

if declare -f my_func >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

my_func() { echo "hello"; }'

  local r22_lines
  r22_lines=$(echo "$output" | grep "FUNCTION_SENTINEL_GUARD_WITH_EXPORT_F" || true)
  [[ "$r22_lines" != *"good-fn-guard-no-export"* ]]
}

@test "rule passes: dependency check (if ! declare -f X; then source ...) is not a guard" {
  _run_lint_with_fixture "good-dep-check" '#!/bin/bash
set -euo pipefail

# Variable guard at top — the canonical safe pattern.
if [ "${_FIXTURE_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_FIXTURE_LOADED=true

# This is a dependency check, not a re-source guard — Rule 22 must not be
# confused by it. The body sources another file, it does not return 0.
if ! declare -f some_dep_fn >/dev/null 2>&1; then
  source "/dev/null"
fi

my_func() { echo "hello"; }

export -f my_func'

  local r22_lines
  r22_lines=$(echo "$output" | grep "FUNCTION_SENTINEL_GUARD_WITH_EXPORT_F" || true)
  [[ "$r22_lines" != *"good-dep-check"* ]]
}

@test "rule passes: no export -f means no inheritance trap (rule does not fire)" {
  _run_lint_with_fixture "no-export-f-at-all" '#!/bin/bash
set -euo pipefail

if declare -f my_func >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

my_func() { echo "no exports here"; }

# No `export -f` line anywhere — no trap to fall into.'

  local r22_lines
  r22_lines=$(echo "$output" | grep "FUNCTION_SENTINEL_GUARD_WITH_EXPORT_F" || true)
  [[ "$r22_lines" != *"no-export-f-at-all"* ]]
}

# ---------------------------------------------------------------------------
# Codebase invariant: no current lib/ file should hit this rule
# ---------------------------------------------------------------------------

@test "codebase: no lib files have FUNCTION_SENTINEL_GUARD_WITH_EXPORT_F violations" {
  unset RITE_LINT_EXTRA_DIRS
  run bash "$LINT_SCRIPT"
  local r22_lines
  r22_lines=$(echo "$output" | grep "FUNCTION_SENTINEL_GUARD_WITH_EXPORT_F" || true)
  [ -z "$r22_lines" ]
}
