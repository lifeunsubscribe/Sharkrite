#!/usr/bin/env bats
# sharkrite-test-covers: install.sh, lib/core/plan-issues.sh, lib/providers/claude.sh
#
# Regression test: install.sh must ship runbooks to $INSTALL_DIR/docs/
#
# Background:
#   install.sh copies lib/, bin/, templates/, and config/ but historically
#   skipped docs/.  rite plan (plan-issues.sh:348) and the Phase 4 dev-prompt
#   builder (lib/providers/claude.sh:452) both probe:
#
#     $RITE_INSTALL_DIR/docs/issue-runbook.md
#     ${RITE_INSTALL_DIR:-$HOME/.rite}/docs/test-authoring-runbook.md
#
#   On a standard (non-symlinked) install neither file is present, so the
#   existence gate hides the miss with zero signal — runbooks are silently
#   omitted from every `rite plan` and every Phase 4 prompt.
#
# Tests:
#   1. install.sh copies docs/issue-runbook.md to $INSTALL_DIR/docs/
#   2. install.sh copies docs/test-authoring-runbook.md to $INSTALL_DIR/docs/
#   3. The paths probed by plan-issues.sh resolve in the installed layout
#   4. The paths probed by lib/providers/claude.sh resolve in the installed layout

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# setup: run install.sh into a temp prefix so nothing touches $HOME/.rite
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  # Redirect all install targets into the test tmpdir:
  #   RITE_INSTALL_DIR  → $RITE_TEST_TMPDIR/install  (overrides $HOME/.rite)
  #   HOME              → $RITE_TEST_TMPDIR/home      (keeps ~/.config/rite and
  #                                                    ~/.local/bin out of $HOME)
  export _INSTALL_PREFIX="${RITE_TEST_TMPDIR}/install"
  export _FAKE_HOME="${RITE_TEST_TMPDIR}/home"
  mkdir -p "$_INSTALL_PREFIX" "$_FAKE_HOME"

  # Run install.sh with:
  #   - RITE_INSTALL_DIR  so INSTALL_DIR="${RITE_INSTALL_DIR:-$HOME/.rite}" resolves
  #     to our temp prefix.
  #   - HOME override so CONFIG_DIR ($HOME/.config/rite) and BIN_DIR
  #     ($HOME/.local/bin) also land under the temp tree.
  #   - stdin from /dev/null so any unexpected read -p fails fast rather than
  #     blocking.  In practice all deps are present in the test environment so
  #     no interactive prompts fire.
  #
  # NOTE: install.sh is an executable script, not a lib — run it as a subprocess.
  RITE_INSTALL_DIR="$_INSTALL_PREFIX" \
  HOME="$_FAKE_HOME" \
  RITE_BIN_DIR="$_FAKE_HOME/.local/bin" \
  bash "${RITE_REPO_ROOT}/install.sh" </dev/null >/dev/null 2>&1
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Test 1: issue-runbook.md is present in installed docs/
# ---------------------------------------------------------------------------

@test "install.sh ships docs/issue-runbook.md to INSTALL_DIR/docs/" {
  [ -f "${_INSTALL_PREFIX}/docs/issue-runbook.md" ] || {
    echo "FAIL: ${_INSTALL_PREFIX}/docs/issue-runbook.md not found after install"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 2: test-authoring-runbook.md is present in installed docs/
# ---------------------------------------------------------------------------

@test "install.sh ships docs/test-authoring-runbook.md to INSTALL_DIR/docs/" {
  [ -f "${_INSTALL_PREFIX}/docs/test-authoring-runbook.md" ] || {
    echo "FAIL: ${_INSTALL_PREFIX}/docs/test-authoring-runbook.md not found after install"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 3: plan-issues.sh probed path resolves in the installed layout
#
# plan-issues.sh:348 probes:
#   "$RITE_INSTALL_DIR/docs/issue-runbook.md"
# ---------------------------------------------------------------------------

@test "plan-issues.sh install-dir probe path resolves after install" {
  # Simulate exactly what plan-issues.sh does: use RITE_INSTALL_DIR to build
  # the fallback path and assert it is a readable file.
  _probe="${_INSTALL_PREFIX}/docs/issue-runbook.md"
  [ -f "$_probe" ] || {
    echo "FAIL: plan-issues.sh probe path not found: $_probe"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 4: lib/providers/claude.sh probed path resolves in the installed layout
#
# claude.sh:452 probes:
#   "${RITE_INSTALL_DIR:-$HOME/.rite}/docs/test-authoring-runbook.md"
# ---------------------------------------------------------------------------

@test "lib/providers/claude.sh install-dir probe path resolves after install" {
  # Simulate exactly what claude.sh does: prefer RITE_INSTALL_DIR, fall back
  # to $HOME/.rite.
  _probe="${_INSTALL_PREFIX:-${_FAKE_HOME}/.rite}/docs/test-authoring-runbook.md"
  [ -f "$_probe" ] || {
    echo "FAIL: claude.sh probe path not found: $_probe"
    false
  }
}
