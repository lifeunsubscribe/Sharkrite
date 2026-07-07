#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/27-tr-with-a-multibyte-utf-8-replacement-delete.sh, tools/sharkrite-lint.sh
# Tests for Rule 26: TR_MULTIBYTE_REPLACEMENT
#
# Verifies that the lint rule flags `tr` calls whose SET operands contain a
# multibyte UTF-8 char (tr is byte-oriented and emits only the first byte —
# garbage), and does NOT flag ascii-only tr, multibyte in comments, multibyte
# in upstream/downstream pipeline stages, or heredoc prose documenting the bug.
#
# Bug context: lib/utils/blocker-rules.sh used `tr '\n' '↵'` to visualize
# newlines in a diag log; tr emitted 0xE2 (first byte of ↵). Fixed by switching
# to bash parameter expansion ${base_branch_raw//$'\n'/↵}.
#
# Fixture injection: fixtures are written into BATS_TEST_TMPDIR and injected via
# RITE_LINT_EXTRA_DIRS so the linter scans them without touching the project's
# own lib/ tree.

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/tr-mb-fixtures/lib/utils"
  mkdir -p "$FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR"
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR}/tr-mb-fixtures"
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

@test "rule fires: tr to single-quoted multibyte replacement" {
  _run_lint_with_fixture "bad-single" '#!/bin/bash
vis=$(echo "$raw" | tr '"'"'\n'"'"' '"'"'↵'"'"')'
  [[ "$output" == *"TR_MULTIBYTE_REPLACEMENT"* ]]
  [[ "$output" == *"bad-single"* ]]
}

@test "rule fires: tr to double-quoted multibyte replacement" {
  _run_lint_with_fixture "bad-double" '#!/bin/bash
vis=$(echo "$raw" | tr "\n" "↵")'
  [[ "$output" == *"TR_MULTIBYTE_REPLACEMENT"* ]]
  [[ "$output" == *"bad-double"* ]]
}

@test "rule fires: tr -d with multibyte delete char" {
  _run_lint_with_fixture "bad-delete" '#!/bin/bash
clean=$(echo "$x" | tr -d '"'"'→'"'"')'
  [[ "$output" == *"TR_MULTIBYTE_REPLACEMENT"* ]]
  [[ "$output" == *"bad-delete"* ]]
}

@test "rule fires: second tr in a chain is the bad one" {
  _run_lint_with_fixture "bad-chain" '#!/bin/bash
out=$(echo "$x" | tr '"'"' '"'"' '"'"'-'"'"' | tr '"'"'\n'"'"' '"'"'↵'"'"')'
  [[ "$output" == *"TR_MULTIBYTE_REPLACEMENT"* ]]
  [[ "$output" == *"bad-chain"* ]]
}

# --------------------------------------------------------------------------
# Should PASS (no violations from this rule)
# --------------------------------------------------------------------------

@test "rule passes: ascii-only tr [:upper:]/[:lower:]" {
  _run_lint_with_fixture "good-ascii" '#!/bin/bash
lower=$(echo "$x" | tr '"'"'[:upper:]'"'"' '"'"'[:lower:]'"'"')'
  local r26; r26=$(echo "$output" | grep "TR_MULTIBYTE_REPLACEMENT" || true)
  [[ "$r26" != *"good-ascii"* ]]
}

@test "rule passes: multibyte only in a trailing comment" {
  _run_lint_with_fixture "good-comment" '#!/bin/bash
j=$(echo "$x" | tr '"'"'\n'"'"' '"'"','"'"')   # join ≈ csv'
  local r26; r26=$(echo "$output" | grep "TR_MULTIBYTE_REPLACEMENT" || true)
  [[ "$r26" != *"good-comment"* ]]
}

@test "rule passes: multibyte only in an upstream pipeline stage" {
  _run_lint_with_fixture "good-upstream" '#!/bin/bash
lower=$(echo "café" | tr '"'"'[:upper:]'"'"' '"'"'[:lower:]'"'"')'
  local r26; r26=$(echo "$output" | grep "TR_MULTIBYTE_REPLACEMENT" || true)
  [[ "$r26" != *"good-upstream"* ]]
}

@test "rule passes: multibyte only in a downstream pipeline stage" {
  _run_lint_with_fixture "good-downstream" '#!/bin/bash
out=$(echo "$x" | tr '"'"'[:upper:]'"'"' '"'"'[:lower:]'"'"' | sed '"'"'s/a/→/'"'"')'
  local r26; r26=$(echo "$output" | grep "TR_MULTIBYTE_REPLACEMENT" || true)
  [[ "$r26" != *"good-downstream"* ]]
}

@test "rule passes: heredoc body documenting the tr bug" {
  _run_lint_with_fixture "good-heredoc" '#!/bin/bash
doc() {
  cat <<'"'"'EOF'"'"'
To visualize newlines, run: echo "$x" | tr '"'"'\n'"'"' '"'"'↵'"'"'
EOF
}'
  local r26; r26=$(echo "$output" | grep "TR_MULTIBYTE_REPLACEMENT" || true)
  [[ "$r26" != *"good-heredoc"* ]]
}

@test "rule passes: suppression comment on preceding line" {
  _run_lint_with_fixture "good-suppressed" '#!/bin/bash
# sharkrite-lint disable TR_MULTIBYTE_REPLACEMENT - Reason: documented intentional usage
vis=$(echo "$raw" | tr '"'"'\n'"'"' '"'"'↵'"'"')'
  local r26; r26=$(echo "$output" | grep "TR_MULTIBYTE_REPLACEMENT" || true)
  [[ "$r26" != *"good-suppressed"* ]]
}

# --------------------------------------------------------------------------
# Codebase sweep + rule presence
# --------------------------------------------------------------------------

@test "codebase: zero TR_MULTIBYTE_REPLACEMENT violations in the project tree" {
  unset RITE_LINT_EXTRA_DIRS
  run bash "$LINT_SCRIPT"
  local v; v=$(echo "$output" | grep "TR_MULTIBYTE_REPLACEMENT" || true)
  if [ -n "$v" ]; then echo "$v" >&3; false; fi
}

@test "lint rule TR_MULTIBYTE_REPLACEMENT is defined in sharkrite-lint.sh" {
  # Post-#952 the linter is driver + tools/lint-rules/ fragments — rule
  # bodies live in the fragments, so the assertion must search both.
  run grep -qr "TR_MULTIBYTE_REPLACEMENT" "$LINT_SCRIPT" "$(dirname "$LINT_SCRIPT")/lint-rules"
  [ "$status" -eq 0 ]
}
