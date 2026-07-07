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
  # Gap-filler stubs APPENDED to PATH (real binaries win): CI runners lack
  # the `claude` CLI, so install.sh's dep precheck hits its interactive
  # "Continue anyway?" read — with stdin at /dev/null that aborts the install
  # before any copy and all four tests fail on CI while passing locally.
  local _dep_stubs="${RITE_TEST_TMPDIR}/dep-stubs"
  mkdir -p "$_dep_stubs"
  for _dep in claude gh jq git; do
    if ! command -v "$_dep" >/dev/null 2>&1; then
      printf '#!/bin/sh\nexit 0\n' > "$_dep_stubs/$_dep"
      chmod +x "$_dep_stubs/$_dep"
    fi
  done

  # `yes n |` (not </dev/null): install.sh has three OPTIONAL read -p prompts
  # (deps-continue, brew bash, GNU parallel). On CI runners the parallel
  # prompt fires (no parallel binary, brew present) and read-at-EOF dies
  # under set -e BEFORE any copy — so the suite failed on CI while passing
  # locally where all optional tools exist. A stream of "n" declines every
  # optional install deterministically; the deps-continue prompt never fires
  # because the stubs above satisfy the dep check.
  RITE_INSTALL_DIR="$_INSTALL_PREFIX" \
  HOME="$_FAKE_HOME" \
  RITE_BIN_DIR="$_FAKE_HOME/.local/bin" \
  PATH="$PATH:$_dep_stubs" \
  bash -c 'yes n | bash "$1" >/dev/null 2>&1' _ "${RITE_REPO_ROOT}/install.sh"
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
# Extracts the install-dir branch of the probe from plan-issues.sh so this
# test stays bound to the actual loader path rather than a hardcoded copy.
# ---------------------------------------------------------------------------

@test "plan-issues.sh install-dir probe path resolves after install" {
  # Extract the install-dir probe from the source — the elif branch that
  # tests "$RITE_INSTALL_DIR/docs/issue-runbook.md".  grep for the literal
  # text and pull the path token so this test breaks if the loader drifts.
  _probe_expr=$(grep -oE '\$RITE_INSTALL_DIR/docs/issue-runbook\.md' \
    "${RITE_REPO_ROOT}/lib/core/plan-issues.sh" | head -1 || true)
  [ -n "$_probe_expr" ] || {
    echo "FAIL: could not extract RITE_INSTALL_DIR probe from plan-issues.sh"
    false
  }
  # Evaluate the expression with RITE_INSTALL_DIR bound to the test prefix.
  RITE_INSTALL_DIR="$_INSTALL_PREFIX" \
    _probe=$(eval echo "$_probe_expr")
  [ -f "$_probe" ] || {
    echo "FAIL: plan-issues.sh probe path not found: $_probe"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 4: lib/providers/claude.sh probed path resolves in the installed layout
#
# Extracts the install-dir branch of the probe from claude.sh so this test
# stays bound to the actual loader path rather than a hardcoded copy.
# ---------------------------------------------------------------------------

@test "lib/providers/claude.sh install-dir probe path resolves after install" {
  # Extract the install-dir probe from the source — the elif branch that
  # tests "${RITE_INSTALL_DIR:-$HOME/.rite}/docs/test-authoring-runbook.md".
  _probe_expr=$(grep -oE '\$\{RITE_INSTALL_DIR:-\$HOME/\.rite\}/docs/test-authoring-runbook\.md' \
    "${RITE_REPO_ROOT}/lib/providers/claude.sh" | head -1 || true)
  [ -n "$_probe_expr" ] || {
    echo "FAIL: could not extract RITE_INSTALL_DIR probe from lib/providers/claude.sh"
    false
  }
  # Evaluate the expression with RITE_INSTALL_DIR and HOME bound to the test
  # prefix/fake-home so the fallback also resolves under the test tree.
  RITE_INSTALL_DIR="$_INSTALL_PREFIX" HOME="$_FAKE_HOME" \
    _probe=$(eval echo "$_probe_expr")
  [ -f "$_probe" ] || {
    echo "FAIL: claude.sh probe path not found: $_probe"
    false
  }
}
