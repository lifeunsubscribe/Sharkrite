#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh::_set_project_verification_vocab
#
# The dev and fix prompts name the PROJECT's gate commands, not sharkrite's.
# Live (freshup #551, 2026-11-12): a React repo's fix prompt said "bash -n your
# shell files" and "Do NOT run make check, bats, pytest"; sessions either
# ignored it (ran the backend suite for 1h28m) or followed it (ran nothing).

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  WORKFLOW_FILE="$RITE_LIB_DIR/core/claude-workflow.sh"
  FIX="$(mktemp -d)"; export FIX
  eval "$(sed -n '/sharkrite-extract: project-vocab-start/,/sharkrite-extract: project-vocab-end/p' "$WORKFLOW_FILE")"
  set +u; set +o pipefail
}

teardown() { rm -rf "${FIX:-}"; }

@test "sharkrite repo: vocabulary is make check / bats / bash -n" {
  printf 'shellcheck:\n\ttrue\nlint:\n\ttrue\n' > "$FIX/Makefile"
  RITE_PROJECT_ROOT="$FIX" _set_project_verification_vocab
  [ "$_RITE_PROJ_IS_SHARKRITE" = true ]
  [[ "$_RITE_PROJ_GATE_CMDS" == *"make check"* ]]
  [[ "$_RITE_PROJ_SYNTAX_STEP" == *"bash -n"* ]]
}

@test "frontend/ node repo with root pytest: vocabulary is npm test + pytest, per-file check is tsc/py_compile, no make check" {
  mkdir -p "$FIX/frontend"
  printf '{"scripts":{"test":"vitest run"}}\n' > "$FIX/frontend/package.json"
  printf '[pytest]\n' > "$FIX/pytest.ini"
  RITE_PROJECT_ROOT="$FIX" _set_project_verification_vocab
  [ "$_RITE_PROJ_IS_SHARKRITE" = false ]
  [[ "$_RITE_PROJ_GATE_CMDS" == *'`npm test`'* ]]
  [[ "$_RITE_PROJ_GATE_CMDS" == *'`pytest`'* ]]
  [[ "$_RITE_PROJ_GATE_CMDS" != *"make check"* ]]
  [[ "$_RITE_PROJ_SYNTAX_STEP" == *"tsc --noEmit"* ]]
  [[ "$_RITE_PROJ_SYNTAX_STEP" == *"py_compile"* ]]
}

@test "RITE_TEST_COMMAND is named in the do-not-run list" {
  mkdir -p "$FIX/frontend"; printf '{"scripts":{"test":"vitest run"}}\n' > "$FIX/frontend/package.json"
  RITE_PROJECT_ROOT="$FIX" RITE_TEST_COMMAND="scripts/rite-test.sh" _set_project_verification_vocab
  [[ "$_RITE_PROJ_GATE_CMDS" == *'`scripts/rite-test.sh`'* ]]
}

@test "repo with no detectable runner: generic vocabulary, never sharkrite's" {
  RITE_PROJECT_ROOT="$FIX" _set_project_verification_vocab
  [ "$_RITE_PROJ_GATE_CMDS" = "the project's test suite" ]
  [[ "$_RITE_PROJ_SYNTAX_STEP" != *"every shell file"* ]]
}

@test "source: dev-prompt Phase 4 has a sharkrite branch and a project branch; fix prompt uses the vocabulary" {
  [ "$(grep -c '^### Phase 4: Test Authoring & Syntax Check & Lint' "$WORKFLOW_FILE")" = "2" ]
  grep -q 'If the project defines a lint script' "$WORKFLOW_FILE"
  _fix=$(sed -n '/FIX_PROMPT+="## Instructions/,/\$EXIT_INSTRUCTION"/p' "$WORKFLOW_FILE")
  [[ "$_fix" == *'${_RITE_PROJ_GATE_CMDS}'* ]]
  [[ "$_fix" == *'${_RITE_PROJ_GATE_DESC}'* ]]
  [[ "$_fix" != *'`bats -r tests/`'* ]]
}
