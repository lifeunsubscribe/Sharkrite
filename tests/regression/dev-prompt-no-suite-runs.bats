#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh, lib/core/claude-workflow.sh
# Regression test: the DEV-session prompt must NOT frame Phase 4 as "run the suite"
#
# The dev-session prompt is assembled from a provider preamble
# (claude_provider_dev_session_preamble) + the Workflow Instructions body in
# claude-workflow.sh. Verifies neither piece invites running the full test suite:
#   1. The preamble Phase 4 todo does NOT say "Running tests" / "verifying correctness"
#   2. The Phase 4 heading is "Test Authoring & Syntax Check" (not "Testing & Validation")
#   3. No Phase 4 cross-reference frames it as "verify everything works"
#   4. Phase 4 still affirmatively keeps its real work: write tests + bash -n
#   5. Phase 4 still prohibits make check / bats / pytest
#   6. The preamble todo skeleton includes Phase 6 (Verify Scope Boundary)
#
# Related: #466 (dev session burns timeout polling test runs). The #466 fix added
# the --disallowedTools block + body prohibition but left the contradictory
# "Phase 4: Testing & Validation - Running tests" framing in the preamble, the
# heading, and a Phase 1 cross-ref — so the model kept running the suite. This
# guards all three framing locations so the contradiction can't be reintroduced.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export PROVIDER_FILE="${RITE_LIB_DIR}/providers/claude.sh"
  export WORKFLOW_FILE="${RITE_LIB_DIR}/core/claude-workflow.sh"
  # Pin the runbook lookup to this checkout (deterministic regardless of what
  # ~/.rite contains) so the shared PREAMBLE includes the repo's
  # docs/test-authoring-runbook.md — the wording-contract assertions below then
  # cover the injected runbook content too, not just the static preamble text.
  export RITE_INSTALL_DIR="${BATS_TEST_DIRNAME}/../.."
  unset RITE_PROJECT_ROOT
  # Render the actual preamble text rather than grepping the source, so the
  # assertions track what the model really receives.
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$PROVIDER_FILE"
  set +u; set +o pipefail  # bats needs its own error handling (Rule 30; never set +e)
  export PREAMBLE
  PREAMBLE=$(claude_provider_dev_session_preamble true "dummy task")
}

# ---------------------------------------------------------------------------
# Preamble must not frame Phase 4 as running tests
# ---------------------------------------------------------------------------

@test "dev preamble Phase 4 todo does not say 'Running tests' or 'verifying correctness'" {
  if echo "$PREAMBLE" | grep -iE 'Running tests|verifying correctness'; then
    echo "FAIL: dev-session preamble still frames Phase 4 as running tests / verifying correctness"
    echo "This invites the model to run the full suite (regression of #466)."
    return 1
  fi
  true
}

@test "dev preamble Phase 4 todo is 'Test Authoring & Syntax Check'" {
  if ! echo "$PREAMBLE" | grep -q 'Phase 4: Test Authoring & Syntax Check'; then
    echo "FAIL: dev-session preamble Phase 4 todo not renamed to 'Test Authoring & Syntax Check'"
    echo "$PREAMBLE" | grep -i 'Phase 4' || true
    return 1
  fi
  true
}

@test "dev preamble todo skeleton includes Phase 6 (Verify Scope Boundary)" {
  # The Workflow Instructions body marks Phase 6 REQUIRED; the model builds its
  # todo list from the preamble, so the skeleton must list it.
  if ! echo "$PREAMBLE" | grep -qE 'Phase 6: Verify Scope Boundary'; then
    echo "FAIL: dev-session preamble todo skeleton is missing Phase 6 (Verify Scope Boundary)"
    return 1
  fi
  true
}

# ---------------------------------------------------------------------------
# Workflow Instructions body: heading + cross-refs
# ---------------------------------------------------------------------------

@test "Phase 4 heading is 'Test Authoring & Syntax Check' (not 'Testing & Validation')" {
  if grep -qE '^### Phase 4: Testing & Validation' "$WORKFLOW_FILE"; then
    echo "FAIL: Phase 4 heading still reads 'Testing & Validation' (invites running tests)"
    return 1
  fi
  if ! grep -qE '^### Phase 4: Test Authoring & Syntax Check' "$WORKFLOW_FILE"; then
    echo "FAIL: Phase 4 heading not found / not renamed"
    grep -nE '^### Phase 4' "$WORKFLOW_FILE" || true
    return 1
  fi
  true
}

@test "no Phase 4 cross-reference frames it as 'verify everything works'" {
  if grep -qiE 'Phase 4.*verify everything works' "$WORKFLOW_FILE"; then
    echo "FAIL: a Phase 4 cross-reference still says 'verify everything works'"
    grep -niE 'Phase 4.*verify everything works' "$WORKFLOW_FILE" || true
    return 1
  fi
  true
}

# ---------------------------------------------------------------------------
# Phase 4 must keep its real work and its prohibition
# ---------------------------------------------------------------------------

@test "Phase 4 still instructs writing/updating unit tests and bash -n" {
  _p4=$(sed -n '/^### Phase 4:/,/^### Phase 5:/p' "$WORKFLOW_FILE" || true)
  echo "$_p4" | grep -qiE 'unit tests' || { echo "FAIL: Phase 4 lost the 'write unit tests' instruction"; return 1; }
  echo "$_p4" | grep -q 'bash -n' || { echo "FAIL: Phase 4 lost the 'bash -n' syntax-check instruction"; return 1; }
  true
}

@test "Phase 4 still prohibits running make check / bats / pytest" {
  _p4=$(sed -n '/^### Phase 4:/,/^### Phase 5:/p' "$WORKFLOW_FILE" || true)
  if ! echo "$_p4" | grep -qiE 'Do NOT run .*make check'; then
    echo "FAIL: Phase 4 no longer prohibits running make check / bats / pytest"
    return 1
  fi
  true
}

# ---------------------------------------------------------------------------
# Test-authoring runbook injection (#863) — mirrors plan-issues.sh's
# issue-runbook load. Gated on file existence; must not touch the Phase 4
# title/prohibition framing (contract above).
# ---------------------------------------------------------------------------

@test "preamble injects the test-authoring runbook when the doc exists" {
  # setup() pinned RITE_INSTALL_DIR to the repo checkout, which ships
  # docs/test-authoring-runbook.md — the shared PREAMBLE must carry it.
  if ! echo "$PREAMBLE" | grep -qF 'Test Authoring Runbook — apply during Phase 4 (Test Authoring & Syntax Check)'; then
    echo "FAIL: preamble is missing the runbook marker line (injection broken or header reworded)"
    return 1
  fi
  # A distinctive body line proves the file CONTENT landed, not just the header.
  if ! echo "$PREAMBLE" | grep -q 'Extend-over-create'; then
    echo "FAIL: runbook marker present but runbook body content missing from preamble"
    return 1
  fi
  true
}

@test "preamble degrades cleanly when no test-authoring runbook exists" {
  export RITE_INSTALL_DIR="$BATS_TEST_TMPDIR"   # no docs/ under here
  unset RITE_PROJECT_ROOT
  _p=$(claude_provider_dev_session_preamble true "dummy task")
  if echo "$_p" | grep -q 'Test Authoring Runbook'; then
    echo "FAIL: runbook section injected even though no runbook doc exists"
    return 1
  fi
  # The rest of the preamble must be intact (todo skeleton unchanged).
  if ! echo "$_p" | grep -q 'Phase 4: Test Authoring & Syntax Check'; then
    echo "FAIL: Phase 4 todo line lost in the no-runbook path"
    return 1
  fi
  true
}

@test "injected runbook content respects the no-suite-runs wording contract" {
  # The runbook lands inside the dev preamble, so it must not reintroduce the
  # #466/#495 framing anywhere in its text (setup()'s PREAMBLE includes it, but
  # assert against the doc directly for a precise failure message).
  _runbook="${BATS_TEST_DIRNAME}/../../docs/test-authoring-runbook.md"
  [ -f "$_runbook" ] || { echo "FAIL: docs/test-authoring-runbook.md missing"; return 1; }
  if grep -iE 'Running tests|verifying correctness|Testing & Validation' "$_runbook"; then
    echo "FAIL: test-authoring runbook contains suite-running framing (regression of #466/#495)"
    return 1
  fi
  true
}
