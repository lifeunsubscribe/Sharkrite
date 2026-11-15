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

@test "source: no vocabulary variable is referenced above the first call that sets it" {
  # Static half of the pin. The fix path runs first in the file, so the first
  # call below the function body must precede the first ${_RITE_PROJ_*} use.
  _end=$(grep -n 'sharkrite-extract: project-vocab-end' "$WORKFLOW_FILE" | cut -d: -f1)
  _bad=$(awk -v end="$_end" '
    NR <= end { next }
    /^[[:space:]]*_set_project_verification_vocab[[:space:]]*$/ { called = 1; next }
    /^[[:space:]]*#/ { next }
    /\$\{_RITE_PROJ_[A-Z_]+\}/ && !called { print NR }
  ' "$WORKFLOW_FILE")
  [ -z "$_bad" ] || { echo "used before set at line(s): $_bad"; false; }
}

@test "behavior: the mixed gate+review items section builds under set -u" {
  # Extract from the vocabulary call through the items-section build and run it
  # the way the script does: set -u, with one [GATE] item and one review item.
  _from=$(grep -n '^  _set_project_verification_vocab$' "$WORKFLOW_FILE" | head -1 | cut -d: -f1)
  _to=$(grep -n '# Build fix prompt - tool restrictions' "$WORKFLOW_FILE" | head -1 | cut -d: -f1)
  [ -n "$_from" ] && [ -n "$_to" ] && [ "$_from" -lt "$_to" ]
  sed -n "${_from},$((_to - 1))p" "$WORKFLOW_FILE" > "$FIX/section.sh"
  sed -n '/sharkrite-extract: project-vocab-start/,/sharkrite-extract: project-vocab-end/p' "$WORKFLOW_FILE" > "$FIX/vocab.sh"
  cat > "$FIX/run.sh" <<'EOS'
set -euo pipefail
source "$1/vocab.sh"
ACTIONABLE_NOW_ITEMS='### [GATE] test_x failed - ACTIONABLE_NOW
detail
### Fix the thing - ACTIONABLE_NOW
detail'
source "$1/section.sh"
printf '%s\n' "$_fix_items_section"
EOS
  RITE_PROJECT_ROOT="$FIX" RITE_TEST_COMMAND="bash scripts/rite-test.sh" run bash "$FIX/run.sh" "$FIX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"objective gate failures"* ]]
  [[ "$output" == *'bash scripts/rite-test.sh'* ]]
  [[ "$output" != *"unbound variable"* ]]
}
