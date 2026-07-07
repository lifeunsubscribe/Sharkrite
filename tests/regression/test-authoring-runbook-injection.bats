#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh, lib/providers/provider-interface.sh, lib/core/claude-workflow.sh
#
# Regression: fix-session prompt must inject the test-authoring runbook when
# tests/ files are in scope, and must stay silent (no injection) when they
# are not.
#
# Issue #909 scope:
#   - Fix sessions edit and author tests on every [GATE] failure — the
#     highest-churn test-editing path — but never received the runbook.
#   - Same per-repo .rite/ override chain as dev sessions.
#   - Silent no-op when neither override nor install copy exists.
#   - DO NOT grow the prompt when no tests are in play.
#
# Testing strategy:
#   Group A — claude_provider_load_test_authoring_runbook() helper (unit):
#     source claude.sh (RITE_SOURCE_FUNCTIONS_ONLY) and call the helper
#     directly with controlled RITE_INSTALL_DIR / RITE_PROJECT_ROOT values.
#   Group B — provider_load_test_authoring_runbook() alias (integration):
#     load the provider via provider-interface.sh, confirm the alias exists.
#   Group C — claude-workflow.sh structural pins (source-level):
#     grep the source for the required patterns (mirrors fix-prompt-no-
#     verification.bats approach) — avoids needing to run the full
#     FIX_REVIEW_MODE execution path.

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export RITE_REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  export PROVIDER_FILE="${RITE_LIB_DIR}/providers/claude.sh"
  export INTERFACE_FILE="${RITE_LIB_DIR}/providers/provider-interface.sh"
  export WORKFLOW_FILE="${RITE_LIB_DIR}/core/claude-workflow.sh"

  # Pin RITE_INSTALL_DIR to the repo checkout so runbook probes resolve
  # deterministically regardless of what $HOME/.rite contains.
  export RITE_INSTALL_DIR="${RITE_REPO_ROOT}"
  unset RITE_PROJECT_ROOT

  # Source claude.sh in functions-only mode so helper is callable in tests.
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$PROVIDER_FILE"
  set +u; set +o pipefail  # restore bats error handling (Rule 30; never set +e)
}

# ---------------------------------------------------------------------------
# Group A: claude_provider_load_test_authoring_runbook() unit tests
# ---------------------------------------------------------------------------

@test "load helper returns runbook content when install-dir doc exists" {
  # RITE_INSTALL_DIR points to repo checkout which ships the runbook at
  # docs/test-authoring-runbook.md — function must return non-empty.
  _out=$(claude_provider_load_test_authoring_runbook)
  [ -n "$_out" ] || {
    echo "FAIL: helper returned empty when install-dir doc exists"
    return 1
  }
  true
}

@test "load helper output includes the canonical runbook header line" {
  _out=$(claude_provider_load_test_authoring_runbook)
  echo "$_out" | grep -qF 'Test Authoring Runbook — apply during Phase 4 (Test Authoring & Syntax Check)' || {
    echo "FAIL: canonical header line absent from helper output"
    echo "--- actual output (first 5 lines) ---"
    echo "$_out" | head -5
    return 1
  }
  true
}

@test "load helper output includes runbook body content (Extend-over-create)" {
  _out=$(claude_provider_load_test_authoring_runbook)
  echo "$_out" | grep -q 'Extend-over-create' || {
    echo "FAIL: runbook body content (Extend-over-create) missing from helper output"
    return 1
  }
  true
}

@test "load helper returns empty when no runbook doc exists" {
  # Point both probe locations at a temp dir that has no docs/ subtree.
  export RITE_INSTALL_DIR="$BATS_TEST_TMPDIR"
  unset RITE_PROJECT_ROOT
  _out=$(claude_provider_load_test_authoring_runbook)
  [ -z "$_out" ] || {
    echo "FAIL: helper returned content even though no runbook doc exists"
    echo "--- actual output ---"
    echo "$_out"
    return 1
  }
  true
}

@test "load helper prefers project .rite/ override over install-dir doc" {
  # Create a project .rite/ with a distinct marker in the runbook.
  _proj_root="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$_proj_root/.rite"
  printf '# Project override runbook\nPROJECT_OVERRIDE_MARKER\n' \
    > "$_proj_root/.rite/test-authoring-runbook.md"

  export RITE_PROJECT_ROOT="$_proj_root"
  unset RITE_DATA_DIR
  _out=$(claude_provider_load_test_authoring_runbook)

  echo "$_out" | grep -q 'PROJECT_OVERRIDE_MARKER' || {
    echo "FAIL: project .rite/ override not used; install-dir doc won instead"
    echo "--- actual output ---"
    echo "$_out"
    return 1
  }
  true
}

# ---------------------------------------------------------------------------
# Group B: provider_load_test_authoring_runbook alias via provider-interface
# ---------------------------------------------------------------------------

@test "provider-interface.sh dispatches load_test_authoring_runbook alias" {
  # Source provider-interface.sh (not via RITE_SOURCE_FUNCTIONS_ONLY — it has
  # no RITE_SOURCE_FUNCTIONS_ONLY guard; it only defines functions + the
  # _LOADED_PROVIDER var, so sourcing it is side-effect-free).
  source "$INTERFACE_FILE"
  # Call load_provider to wire the aliases.
  load_provider "claude"
  # Verify the alias exists and is callable.
  if ! declare -f provider_load_test_authoring_runbook >/dev/null 2>&1; then
    echo "FAIL: provider_load_test_authoring_runbook alias not registered by load_provider"
    return 1
  fi
  true
}

@test "provider_load_test_authoring_runbook alias returns runbook content" {
  source "$INTERFACE_FILE"
  load_provider "claude"
  _out=$(provider_load_test_authoring_runbook)
  [ -n "$_out" ] || {
    echo "FAIL: provider_load_test_authoring_runbook returned empty"
    return 1
  }
  echo "$_out" | grep -qF 'Test Authoring Runbook' || {
    echo "FAIL: provider alias output missing canonical header"
    return 1
  }
  true
}

# ---------------------------------------------------------------------------
# Group C: claude-workflow.sh structural source pins
# ---------------------------------------------------------------------------

@test "fix-session code checks ACTIONABLE_NOW_ITEMS for tests/ or .bats" {
  # The runbook injection gate must grep ACTIONABLE_NOW_ITEMS for
  # 'tests/' or '.bats' — this pattern drives the DO NOT grow prompt contract.
  if ! grep -qE 'ACTIONABLE_NOW_ITEMS.*tests/|ACTIONABLE_NOW_ITEMS.*\.bats|tests/.*ACTIONABLE_NOW_ITEMS|\.bats.*ACTIONABLE_NOW_ITEMS' "$WORKFLOW_FILE"; then
    echo "FAIL: claude-workflow.sh has no test-scope gate on ACTIONABLE_NOW_ITEMS"
    echo "Expected: grep on ACTIONABLE_NOW_ITEMS for 'tests/' or '.bats'"
    return 1
  fi
  true
}

@test "fix-session code calls provider_load_test_authoring_runbook" {
  if ! grep -q 'provider_load_test_authoring_runbook' "$WORKFLOW_FILE"; then
    echo "FAIL: claude-workflow.sh does not call provider_load_test_authoring_runbook"
    return 1
  fi
  true
}

@test "fix-session prompt includes _fix_test_runbook_section variable" {
  # The variable must be referenced inside the FIX_PROMPT string so the
  # content actually reaches the model when tests are in scope.
  if ! grep -q '_fix_test_runbook_section' "$WORKFLOW_FILE"; then
    echo "FAIL: _fix_test_runbook_section not found in claude-workflow.sh"
    return 1
  fi
  true
}

@test "dev-session preamble is unchanged (uses claude_provider_load_test_authoring_runbook)" {
  # Verify the dev preamble still calls the helper (not inlined the loader).
  # This guards the #495 byte-identical contract: extraction must not silently
  # change what the dev preamble emits.
  if ! grep -q 'claude_provider_load_test_authoring_runbook' "$PROVIDER_FILE"; then
    echo "FAIL: dev preamble no longer calls claude_provider_load_test_authoring_runbook"
    echo "Extraction may have broken the dev preamble helper delegation"
    return 1
  fi
  true
}

@test "dev preamble output still contains runbook (byte-identical contract, #495)" {
  # Render the preamble and verify runbook is still injected — confirming the
  # extraction did not silently break the dev session path.
  _preamble=$(claude_provider_dev_session_preamble true "dummy task")
  echo "$_preamble" | grep -qF 'Test Authoring Runbook — apply during Phase 4 (Test Authoring & Syntax Check)' || {
    echo "FAIL: dev-session preamble no longer injects the runbook (extraction broke it)"
    return 1
  }
  echo "$_preamble" | grep -q 'Extend-over-create' || {
    echo "FAIL: dev preamble runbook body content missing after extraction"
    return 1
  }
  true
}

@test "fix-session runbook injection is conditional (no-op path present in source)" {
  # The injection must be gated — not unconditional. Confirm the _fix_test_runbook_section
  # assignment is inside an 'if' block that tests ACTIONABLE_NOW_ITEMS.
  _gate_region=$(grep -A5 '_fix_test_runbook_section=""' "$WORKFLOW_FILE" || true)
  echo "$_gate_region" | grep -q 'if ' || {
    echo "FAIL: _fix_test_runbook_section initialization not followed by a conditional"
    echo "The injection must be gated on test-scope detection, not unconditional"
    return 1
  }
  true
}

# ---------------------------------------------------------------------------
# Group C (signal 2): branch-has-tests git diff gate structural pins
# ---------------------------------------------------------------------------

@test "fix-session code checks git diff for branch tests/ changes (signal 2)" {
  # Signal 2: when the branch already has tests/ changes relative to origin/main,
  # inject the runbook even if ACTIONABLE_NOW_ITEMS doesn't mention tests/.
  # Verify the source contains a git diff --name-only check probing tests/.
  if ! grep -qE 'git diff.*--name-only.*origin/main|git diff.*--name-only.*HEAD' "$WORKFLOW_FILE"; then
    echo "FAIL: claude-workflow.sh has no git diff --name-only probe for branch tests/ changes"
    echo "Expected: git diff --name-only origin/main...HEAD piped to a grep for tests/"
    return 1
  fi
  true
}

@test "fix-session gate includes OR arm for branch-has-tests signal" {
  # The if-gate must combine both signals with ||:
  #   if ... (signal 1 ACTIONABLE_NOW_ITEMS) || [ branch has tests ]; then
  # Verify the if line that triggers runbook injection contains both signals.
  if ! grep -qE 'ACTIONABLE_NOW_ITEMS.*\|\|.*_fix_branch_has_tests|_fix_branch_has_tests.*\|\|.*ACTIONABLE_NOW_ITEMS' "$WORKFLOW_FILE"; then
    echo "FAIL: injection gate does not combine ACTIONABLE_NOW_ITEMS and _fix_branch_has_tests with ||"
    echo "Both signals must be checked so branch-level test changes trigger injection"
    return 1
  fi
  true
}
