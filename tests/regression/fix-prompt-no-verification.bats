#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Regression test: FIX_PROMPT must NOT instruct Claude to run test/lint commands
#
# Verifies:
#   1. FIX_PROMPT step 5 does NOT mention make check, bats, pytest, or project test commands
#   2. FIX_PROMPT step 5 DOES contain bash -n syntax-check instruction
#   3. FIX_PROMPT Scope section does NOT tell Claude to run tests/lint
#   4. The 1800s hardcoded FIX_TIMEOUT is gone (replaced by proportional formula)
#
# Related issue: #448 (Move verification out of fix session)
# Problem: Fix session burned full 1800s running make check + bats before commit;
#          outer gate then ran bats tests/ non-recursively (found 0 tests).

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export WORKFLOW_FILE="${RITE_LIB_DIR}/core/claude-workflow.sh"
}

# ---------------------------------------------------------------------------
# FIX_PROMPT must not contain project test/lint invocations
# ---------------------------------------------------------------------------

@test "FIX_PROMPT does not affirmatively instruct Claude to run make check" {
  # Extract the FIX_PROMPT heredoc section and verify it doesn't tell Claude to RUN make check.
  # NOTE: "Do NOT run make check" (prohibition) is expected and correct — we only fail if
  # the prompt POSITIVELY instructs "Run make check" or "run make check" (affirmative).
  _fix_prompt_block=$(sed -n '/FIX_PROMPT+="## Instructions/,/\$EXIT_INSTRUCTION"/p' "$WORKFLOW_FILE" || true)
  # Affirmative instruction patterns (no preceding "NOT" or "not")
  # grep -v excludes lines containing "Do NOT", "do not", "DO NOT" before "make check"
  _affirmative=$(echo "$_fix_prompt_block" | grep -iE 'run.*make check' | grep -ivE 'do not run|not run' || true)
  if [ -n "$_affirmative" ]; then
    echo "FAIL: FIX_PROMPT affirmatively instructs Claude to run 'make check'"
    echo "Affirmative match(es):"
    echo "$_affirmative"
    return 1
  fi
  true
}

@test "FIX_PROMPT does not affirmatively instruct Claude to run bats tests" {
  _fix_prompt_block=$(sed -n '/FIX_PROMPT+="## Instructions/,/\$EXIT_INSTRUCTION"/p' "$WORKFLOW_FILE" || true)
  # Lines mentioning "bats tests" that are NOT prohibitions (do not run / not run)
  _affirmative=$(echo "$_fix_prompt_block" | grep -iE 'run.*bats tests|bats tests.*run' | grep -ivE 'do not run|not run|Do NOT' || true)
  if [ -n "$_affirmative" ]; then
    echo "FAIL: FIX_PROMPT affirmatively instructs Claude to run 'bats tests'"
    echo "Affirmative match(es):"
    echo "$_affirmative"
    return 1
  fi
  true
}

@test "FIX_PROMPT does not affirmatively instruct Claude to run pytest tests" {
  _fix_prompt_block=$(sed -n '/FIX_PROMPT+="## Instructions/,/\$EXIT_INSTRUCTION"/p' "$WORKFLOW_FILE" || true)
  _affirmative=$(echo "$_fix_prompt_block" | grep -iE 'run.*pytest tests|pytest tests.*run' | grep -ivE 'do not run|not run|Do NOT' || true)
  if [ -n "$_affirmative" ]; then
    echo "FAIL: FIX_PROMPT affirmatively instructs Claude to run 'pytest tests'"
    echo "Affirmative match(es):"
    echo "$_affirmative"
    return 1
  fi
  true
}

# ---------------------------------------------------------------------------
# FIX_PROMPT must contain bash -n syntax-check instruction
# ---------------------------------------------------------------------------

@test "FIX_PROMPT step 5 instructs Claude to run bash -n syntax checks" {
  _fix_prompt_block=$(sed -n '/FIX_PROMPT+="## Instructions/,/\$EXIT_INSTRUCTION"/p' "$WORKFLOW_FILE" || true)
  if ! echo "$_fix_prompt_block" | grep -q 'bash -n'; then
    echo "FAIL: FIX_PROMPT does not instruct Claude to run 'bash -n'"
    return 1
  fi
  true
}

@test "FIX_PROMPT Scope section does NOT tell Claude to run tests/lint" {
  # The ## Scope section should not reference running make check, bats, or pytest
  _scope_block=$(sed -n '/^## Scope/,/^\$EXIT_INSTRUCTION/p' "$WORKFLOW_FILE" || true)
  # Scope must say DO NOT run make check/bats/pytest
  if echo "$_scope_block" | grep -qE '^- Run (make check|bats|pytest)'; then
    echo "FAIL: ## Scope section tells Claude to run tests/lint"
    echo "$_scope_block" | grep -E '^- Run'
    return 1
  fi
  true
}

# ---------------------------------------------------------------------------
# FIX_TIMEOUT must use proportional formula (not hardcoded 1800)
# ---------------------------------------------------------------------------

@test "FIX_TIMEOUT uses proportional formula (not bare hardcoded 1800)" {
  # The old pattern was: FIX_TIMEOUT=${RITE_FIX_TIMEOUT:-1800}
  # The new pattern uses _default_fix_timeout computed from count
  # Verify the old bare-1800 pattern is gone
  if grep -qE 'FIX_TIMEOUT=\$\{RITE_FIX_TIMEOUT:-1800\}' "$WORKFLOW_FILE"; then
    echo "FAIL: FIX_TIMEOUT still uses bare hardcoded 1800s default"
    grep -n 'FIX_TIMEOUT' "$WORKFLOW_FILE"
    return 1
  fi
  true
}

@test "FIX_TIMEOUT formula includes _default_fix_timeout variable" {
  if ! grep -q '_default_fix_timeout' "$WORKFLOW_FILE"; then
    echo "FAIL: _default_fix_timeout variable not found in claude-workflow.sh"
    return 1
  fi
  true
}

@test "FIX_TIMEOUT formula uses 300 + 240 * count" {
  if ! grep -q '300 + 240' "$WORKFLOW_FILE"; then
    echo "FAIL: proportional formula '300 + 240 * count' not found in claude-workflow.sh"
    return 1
  fi
  true
}

@test "RITE_FIX_TIMEOUT env var still overrides formula" {
  # Verify the env var override pattern exists: ${RITE_FIX_TIMEOUT:-$_default_fix_timeout}
  if ! grep -q 'RITE_FIX_TIMEOUT:-' "$WORKFLOW_FILE"; then
    echo "FAIL: RITE_FIX_TIMEOUT env var override not found"
    return 1
  fi
  true
}
