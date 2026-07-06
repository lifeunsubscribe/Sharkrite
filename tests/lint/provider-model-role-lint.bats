#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/31-empty-model-arg-to-a-provider-run-function-s.sh, tools/lint-rules/32-direct-claude-provider-call-in-lib-core-or-l.sh, tools/sharkrite-lint.sh
# Tests for Rule 31 (PROVIDER_MODEL_FALLTHROUGH) and Rule 32 (DIRECT_PROVIDER_CALL).
#
# Rule 31: passing "" as the model arg to provider_run_prompt /
#   provider_run_prompt_with_timeout / provider_run_streaming_prompt silently falls
#   through to resolve_model "review" (opus). Callers must pass an explicit role.
#   (Live defect: plan-issues.sh + bin/rite doc classification rode opus via "".)
#
# Rule 32: lib/core and lib/utils must be provider-agnostic — they call the
#   provider_* aliases, never the claude-prefixed claude_provider_* implementations.
#
# Fixture injection: fixtures are written under a lib/utils/-shaped path in
# BATS_TEST_TMPDIR and injected via RITE_LINT_EXTRA_DIRS. Rule 31 scans all
# SHELL_FILES; Rule 32 is path-scoped to lib/core|lib/utils, so the lib/utils
# path segment makes it fire.

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export LINT_SCRIPT PROJECT_ROOT

  FIXTURE_ROOT="${BATS_TEST_TMPDIR}/model-role-fixtures"
  FIXTURE_DIR="${FIXTURE_ROOT}/lib/utils"
  mkdir -p "$FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR"
}

teardown() {
  rm -rf "${FIXTURE_ROOT:-/nonexistent}"
  unset RITE_LINT_EXTRA_DIRS
}

_run_lint_with_fixture() {
  local name="$1"
  local content="$2"
  printf '%s\n' "$content" > "$FIXTURE_DIR/${name}.sh"
  run bash "$LINT_SCRIPT"
}

# ===========================================================================
# Rule 31: PROVIDER_MODEL_FALLTHROUGH
# ===========================================================================

@test "Rule 31 fires: streaming prompt with bare \"\" model arg" {
  _run_lint_with_fixture "bad-streaming" '#!/bin/bash
foo() {
  provider_run_streaming_prompt "$PROMPT" "" 2>/dev/null
}'
  [[ "$output" == *"- PROVIDER_MODEL_FALLTHROUGH:"* ]]
}

@test "Rule 31 fires: prompt_with_timeout with bare \"\" model arg" {
  _run_lint_with_fixture "bad-timeout" '#!/bin/bash
foo() {
  OUT=$(provider_run_prompt_with_timeout "$PROMPT" "" true 300)
}'
  [[ "$output" == *"- PROVIDER_MODEL_FALLTHROUGH:"* ]]
}

@test "Rule 31 passes: explicit role via provider_resolve_model" {
  _run_lint_with_fixture "good-explicit" '#!/bin/bash
foo() {
  provider_run_streaming_prompt "$PROMPT" "$(provider_resolve_model plan)" 2>/dev/null
}'
  [[ "$output" != *"- PROVIDER_MODEL_FALLTHROUGH:"* ]]
}

@test "Rule 31 respects inline suppression" {
  _run_lint_with_fixture "suppressed" '#!/bin/bash
foo() {
  # sharkrite-lint disable PROVIDER_MODEL_FALLTHROUGH - Reason: deliberate default in a test shim
  provider_run_streaming_prompt "$PROMPT" "" 2>/dev/null
}'
  [[ "$output" != *"- PROVIDER_MODEL_FALLTHROUGH:"* ]]
}

# ===========================================================================
# Rule 32: DIRECT_PROVIDER_CALL
# ===========================================================================

@test "Rule 32 fires: direct claude_provider_resolve_model in lib/utils" {
  _run_lint_with_fixture "bad-direct" '#!/bin/bash
foo() {
  local m
  m=$(claude_provider_resolve_model doc_assessment)
  echo "$m"
}'
  [[ "$output" == *"- DIRECT_PROVIDER_CALL:"* ]]
}

@test "Rule 32 passes: agnostic provider_resolve_model" {
  _run_lint_with_fixture "good-agnostic" '#!/bin/bash
foo() {
  local m
  m=$(provider_resolve_model doc_assessment)
  echo "$m"
}'
  [[ "$output" != *"- DIRECT_PROVIDER_CALL:"* ]]
}

@test "Rule 32 exempts comments mentioning claude_provider_*" {
  _run_lint_with_fixture "comment-only" '#!/bin/bash
# In production this used to call claude_provider_resolve_model directly.
foo() {
  local m
  m=$(provider_resolve_model doc_assessment)
  echo "$m"
}'
  [[ "$output" != *"- DIRECT_PROVIDER_CALL:"* ]]
}

# ===========================================================================
# Integration: the real tree is clean of both classes
# ===========================================================================

@test "project tree has no PROVIDER_MODEL_FALLTHROUGH or DIRECT_PROVIDER_CALL violations" {
  unset RITE_LINT_EXTRA_DIRS   # scan only the project tree, not fixtures
  run bash "$LINT_SCRIPT"
  [[ "$output" != *"- PROVIDER_MODEL_FALLTHROUGH:"* ]]
  [[ "$output" != *"- DIRECT_PROVIDER_CALL:"* ]]
}
