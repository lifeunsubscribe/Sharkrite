#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/38-raw-origin-main-ref-in-becomes-target-files.sh, tools/sharkrite-lint.sh
# Tests for Rule 38: RAW_ORIGIN_MAIN_REF
#
# Verifies that the lint rule correctly flags literal origin/main (slash and
# two-word forms) in non-comment lines of the ten §5.2 BECOMES-TARGET files,
# stays silent on out-of-scope files and comment lines, and honors preceding-line
# suppression markers.
#
# Design: docs/architecture/branch-flag-design.md §5/§6.4
# Issue: #1052
#
# Fixture injection:
#   Fixtures are written into BATS_TEST_TMPDIR/raw-main-ref-fixtures/ with
#   subdirectory paths that match the in-scope file suffixes
#   (e.g. lib/core/claude-workflow.sh). RITE_LINT_EXTRA_DIRS points the driver
#   at the fixture root so the case-based suffix filter in the rule admits them.

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"
  export SHARKRITE_LINT_ONLY=38

  FIXTURE_ROOT="${BATS_TEST_TMPDIR}/raw-main-ref-fixtures"
  mkdir -p "$FIXTURE_ROOT/lib/core"
  mkdir -p "$FIXTURE_ROOT/lib/utils"
  export RITE_LINT_EXTRA_DIRS="$FIXTURE_ROOT"
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR}/raw-main-ref-fixtures"
  unset RITE_LINT_EXTRA_DIRS
  unset SHARKRITE_LINT_ONLY
}

# Helper: write a fixture at the given relative path and run lint.
_run_lint_with_fixture() {
  local rel_path="$1"
  local content="$2"
  printf '%s\n' "$content" > "$FIXTURE_ROOT/$rel_path"
  run bash "$LINT_SCRIPT"
}

# ---------------------------------------------------------------------------
# Should FIRE (violations)
# ---------------------------------------------------------------------------

@test "rule fires: slash-form origin/main in an in-scope-named fixture" {
  _run_lint_with_fixture "lib/core/claude-workflow.sh" '#!/bin/bash
set -euo pipefail
do_diff() {
  git diff origin/main...HEAD
}'
  [[ "$output" == *"RAW_ORIGIN_MAIN_REF"* ]]
}

@test "rule fires: two-word form 'git fetch origin main' in an in-scope fixture" {
  _run_lint_with_fixture "lib/core/workflow-runner.sh" '#!/bin/bash
set -euo pipefail
do_fetch() {
  git fetch origin main --quiet
}'
  [[ "$output" == *"RAW_ORIGIN_MAIN_REF"* ]]
}

@test "rule fires: two-word form 'git_fetch_safe origin main' in an in-scope fixture" {
  _run_lint_with_fixture "lib/utils/stale-branch.sh" '#!/bin/bash
set -euo pipefail
do_fetch() {
  git_fetch_safe origin main || return 1
}'
  [[ "$output" == *"RAW_ORIGIN_MAIN_REF"* ]]
}

@test "rule fires: origin/main in merge-pr.sh in-scope path" {
  _run_lint_with_fixture "lib/core/merge-pr.sh" '#!/bin/bash
set -euo pipefail
do_ff() {
  git pull --ff-only origin main
}'
  [[ "$output" == *"RAW_ORIGIN_MAIN_REF"* ]]
}

# ---------------------------------------------------------------------------
# Should PASS (no violations from this rule)
# ---------------------------------------------------------------------------

@test "rule stays silent on out-of-scope file containing origin/main (post-merge-verify.sh)" {
  _run_lint_with_fixture "lib/utils/post-merge-verify.sh" '#!/bin/bash
set -euo pipefail
do_verify() {
  git diff origin/main...HEAD
}'
  local r38_lines
  r38_lines=$(echo "$output" | grep "RAW_ORIGIN_MAIN_REF" || true)
  [[ "$r38_lines" != *"post-merge-verify"* ]]
}

@test "rule stays silent on out-of-scope divergence-handler.sh containing origin/main" {
  _run_lint_with_fixture "lib/utils/divergence-handler.sh" '#!/bin/bash
set -euo pipefail
classify() {
  git log --not origin/main HEAD
}'
  local r38_lines
  r38_lines=$(echo "$output" | grep "RAW_ORIGIN_MAIN_REF" || true)
  [[ "$r38_lines" != *"divergence-handler"* ]]
}

@test "rule stays silent on full-line comment containing origin/main in an in-scope file" {
  _run_lint_with_fixture "lib/core/claude-workflow.sh" '#!/bin/bash
set -euo pipefail
# This compares against origin/main to detect drift
do_thing() {
  echo "no literal ref here"
}'
  local r38_lines
  r38_lines=$(echo "$output" | grep "RAW_ORIGIN_MAIN_REF" || true)
  [[ -z "$r38_lines" ]]
}

@test "rule stays silent on origin/mainline (no false positive from longer ref names)" {
  _run_lint_with_fixture "lib/core/workflow-runner.sh" '#!/bin/bash
set -euo pipefail
do_thing() {
  git fetch origin mainline
}'
  local r38_lines
  r38_lines=$(echo "$output" | grep "RAW_ORIGIN_MAIN_REF" || true)
  [[ -z "$r38_lines" ]]
}

@test "rule stays silent on parameterized origin/\$base_branch (already resolved)" {
  _run_lint_with_fixture "lib/utils/stale-branch.sh" '#!/bin/bash
set -euo pipefail
do_thing() {
  local base_branch="$1"
  git fetch origin "$base_branch" --quiet
}'
  local r38_lines
  r38_lines=$(echo "$output" | grep "RAW_ORIGIN_MAIN_REF" || true)
  [[ -z "$r38_lines" ]]
}

@test "rule stays silent: suppression on preceding line is honored" {
  _run_lint_with_fixture "lib/core/claude-workflow.sh" '#!/bin/bash
set -euo pipefail
do_diff() {
  # sharkrite-lint disable RAW_ORIGIN_MAIN_REF - Reason: trunk-health, intentionally main
  git diff origin/main...HEAD
}'
  local r38_lines
  r38_lines=$(echo "$output" | grep "RAW_ORIGIN_MAIN_REF" || true)
  [[ -z "$r38_lines" ]]
}

@test "rule stays silent: suppression honored for two-word form" {
  _run_lint_with_fixture "lib/utils/stale-branch.sh" '#!/bin/bash
set -euo pipefail
do_fetch() {
  # sharkrite-lint disable RAW_ORIGIN_MAIN_REF - Reason: creates target from trunk, intentionally main
  git_fetch_safe origin main || return 1
}'
  local r38_lines
  r38_lines=$(echo "$output" | grep "RAW_ORIGIN_MAIN_REF" || true)
  [[ -z "$r38_lines" ]]
}

@test "rule fires: suppression on non-adjacent line (intervening comment) does NOT suppress" {
  # The suppression contract is immediately-preceding-line only.
  # An ordinary comment between the marker and the flagged code must not block the violation.
  _run_lint_with_fixture "lib/core/claude-workflow.sh" '#!/bin/bash
set -euo pipefail
do_diff() {
  # sharkrite-lint disable RAW_ORIGIN_MAIN_REF - Reason: trunk-health
  # This is an intervening comment, not the suppression target
  git diff origin/main...HEAD
}'
  [[ "$output" == *"RAW_ORIGIN_MAIN_REF"* ]]
}

@test "rule fires: 'origin main failed' matches (space after main is non-alnum)" {
  # The space between 'main' and 'failed' satisfies [^[:alnum:]_-], so this DOES fire.
  # In the real codebase this site is suppressed (see workflow-runner.sh verify_already_fixed_on_main).
  _run_lint_with_fixture "lib/core/workflow-runner.sh" '#!/bin/bash
set -euo pipefail
do_thing() {
  print_info "git fetch origin main failed to run"
}'
  [[ "$output" == *"RAW_ORIGIN_MAIN_REF"* ]]
}

# ---------------------------------------------------------------------------
# Codebase sweep: full tree has zero RAW_ORIGIN_MAIN_REF violations
# ---------------------------------------------------------------------------

@test "codebase: full tree has zero RAW_ORIGIN_MAIN_REF violations" {
  # Every remaining literal origin/main in the ten BECOMES-TARGET files must
  # carry a reasoned inline suppression. This test proves the §5/§6.4 partition
  # is fully annotated — a missing suppression turns CI red immediately.
  unset RITE_LINT_EXTRA_DIRS   # scan only the project tree, not fixtures

  run bash "$LINT_SCRIPT"

  local r38_violations
  r38_violations=$(echo "$output" | grep "RAW_ORIGIN_MAIN_REF" || true)

  if [ -n "$r38_violations" ]; then
    echo "RAW_ORIGIN_MAIN_REF violations found:" >&3
    echo "$r38_violations" >&3
    false
  fi
}

@test "lint rule RAW_ORIGIN_MAIN_REF is defined in sharkrite-lint fragments" {
  run grep -qr "RAW_ORIGIN_MAIN_REF" "$LINT_SCRIPT" "$(dirname "$LINT_SCRIPT")/lint-rules"
  [ "$status" -eq 0 ]
}
