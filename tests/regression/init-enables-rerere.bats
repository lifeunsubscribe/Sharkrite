#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite
# tests/regression/init-enables-rerere.bats
#
# Regression tests: rite --init must enable git rerere when it is unset,
# leave an explicit false intact, and remain idempotent across two runs.
#
# Bug context (issue #1527):
#   rite --sync / mid-run drift / stale-branch resume all rebase feature
#   branches onto a fast-moving base. Without rerere the LLM conflict
#   resolver is paid to solve the same conflict on every rebase.
#   rr-cache lives in the git common dir, so enabling it once at --init
#   serves all worktrees automatically.
#
# Tests:
#   STRUCTURAL (grep bin/rite — verify logic is correct):
#     1. The rerere block is present (guards on _rerere_current)
#     2. The write-failure path is non-fatal (print_info, not exit)
#     3. CLAUDE.md documents rite --init and rerere
#
#   BEHAVIORAL (driver script in temp git repo):
#     4. Unset rerere → becomes true after the block runs
#     5. rerere.autoupdate is also set when rerere is unset
#     6. Explicit false → untouched after the block runs
#     7. Already-true → still true (idempotent)
#
# Verification command:
#   bats tests/regression/init-enables-rerere.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
RITE_BIN="$REPO_ROOT/bin/rite"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

setup() {
  [ -f "$RITE_BIN" ] || { echo "FATAL: $RITE_BIN not found" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Helper: write a small driver script that runs the rerere block from
# bin/rite inline inside a fresh git repo.
# ---------------------------------------------------------------------------
# The driver:
#   1. Creates a bare-minimum git repo in $BATS_TEST_TMPDIR/repo
#   2. Stubs print_* functions so no terminal output is emitted
#   3. Runs the rerere config block from bin/rite inline
#   4. Exits 0 on success
_write_rerere_driver() {
  local _script="$1"
  local _pre_config="${2:-}"   # optional: shell command to run before the block

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand (_pre_config, BATS_TEST_TMPDIR)
  cat > "$_script" <<DRIVER_EOF
#!/usr/bin/env bash
set -euo pipefail

RITE_PROJECT_ROOT="\$BATS_TEST_TMPDIR/repo"
mkdir -p "\$RITE_PROJECT_ROOT"
git -C "\$RITE_PROJECT_ROOT" init -q

${_pre_config}

print_success() { :; }
print_info()    { :; }
print_warning() { :; }
print_error()   { :; }

# ── BEGIN: rerere block from bin/rite ──────────────────────────────────────
_rerere_current=\$(git -C "\$RITE_PROJECT_ROOT" config --get rerere.enabled 2>/dev/null || true)
if [ -z "\$_rerere_current" ]; then
  if git -C "\$RITE_PROJECT_ROOT" config rerere.enabled true \
     && git -C "\$RITE_PROJECT_ROOT" config rerere.autoupdate true; then
    print_success "Enabled git rerere (conflict-resolution cache)"
  else
    print_info "Could not enable git rerere — set manually: git config rerere.enabled true"
  fi
elif [ "\$_rerere_current" = "true" ]; then
  print_info "git rerere already enabled"
else
  print_info "git rerere is explicitly disabled (rerere.enabled=\${_rerere_current}); leaving as-is"
fi
# ── END: rerere block ──────────────────────────────────────────────────────
DRIVER_EOF

  chmod +x "$_script"
}

# =============================================================================
# STRUCTURAL: bin/rite
# =============================================================================

@test "structural: rerere block reads current value before writing" {
  grep -qE '_rerere_current' "$RITE_BIN" || {
    echo "FAIL: No _rerere_current variable in bin/rite" >&2
    echo "      The block must read the current rerere.enabled value before writing" >&2
    return 1
  }

  grep -qE 'config rerere\.enabled true' "$RITE_BIN" || {
    echo "FAIL: No 'git config rerere.enabled true' in bin/rite" >&2
    echo "      The block must set rerere.enabled when it is unset" >&2
    return 1
  }

  grep -qE 'config rerere\.autoupdate true' "$RITE_BIN" || {
    echo "FAIL: No 'git config rerere.autoupdate true' in bin/rite" >&2
    echo "      The block must also set rerere.autoupdate" >&2
    return 1
  }
}

@test "structural: explicit false path is non-fatal (leaving as-is message)" {
  grep -qE 'leaving as-is' "$RITE_BIN" || {
    echo "FAIL: 'leaving as-is' message not found in bin/rite" >&2
    echo "      The block must leave an explicit rerere.enabled=false intact" >&2
    return 1
  }
}

@test "structural: write-failure path uses print_info not exit" {
  grep -qE 'Could not enable git rerere' "$RITE_BIN" || {
    echo "FAIL: write-failure fallback message not found in bin/rite" >&2
    echo "      Expected 'Could not enable git rerere' print_info fallback" >&2
    return 1
  }

  # The write-failure message must not be followed by an exit on the same line
  grep -E 'Could not enable git rerere' "$RITE_BIN" | grep -qE 'exit' && {
    echo "FAIL: write-failure line contains 'exit' — must be non-fatal" >&2
    return 1
  } || true
}

@test "structural: CLAUDE.md documents rite --init with rerere" {
  grep -qE 'rerere' "$CLAUDE_MD" || {
    echo "FAIL: 'rerere' not found in CLAUDE.md" >&2
    echo "      rite --init rerere behavior must be documented in Phase Commands" >&2
    return 1
  }

  grep -qE 'rite --init' "$CLAUDE_MD" || {
    echo "FAIL: 'rite --init' not found in CLAUDE.md Phase Commands" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: driver script in temp git repo
# =============================================================================

@test "behavioral: unset rerere → enabled after block runs" {
  _driver="$BATS_TEST_TMPDIR/rerere-driver.sh"
  _write_rerere_driver "$_driver"

  run bash "$_driver"
  [ "$status" -eq 0 ] || {
    echo "FAIL: driver exited $status. Output: $output" >&2
    return 1
  }

  _repo="$BATS_TEST_TMPDIR/repo"
  _got=$(git -C "$_repo" config --get rerere.enabled 2>/dev/null || true)
  [ "$_got" = "true" ] || {
    echo "FAIL: rerere.enabled not set to 'true'; got: '${_got}'" >&2
    return 1
  }
}

@test "behavioral: unset rerere → rerere.autoupdate also set" {
  _driver="$BATS_TEST_TMPDIR/rerere-autoupdate-driver.sh"
  _write_rerere_driver "$_driver"

  run bash "$_driver"
  [ "$status" -eq 0 ] || {
    echo "FAIL: driver exited $status. Output: $output" >&2
    return 1
  }

  _repo="$BATS_TEST_TMPDIR/repo"
  _got=$(git -C "$_repo" config --get rerere.autoupdate 2>/dev/null || true)
  [ "$_got" = "true" ] || {
    echo "FAIL: rerere.autoupdate not set to 'true'; got: '${_got}'" >&2
    return 1
  }
}

@test "behavioral: explicit rerere.enabled=false is preserved, not overwritten" {
  _driver="$BATS_TEST_TMPDIR/rerere-false-driver.sh"
  _pre='git -C "$RITE_PROJECT_ROOT" config rerere.enabled false'
  _write_rerere_driver "$_driver" "$_pre"

  run bash "$_driver"
  [ "$status" -eq 0 ] || {
    echo "FAIL: driver exited $status. Output: $output" >&2
    return 1
  }

  _repo="$BATS_TEST_TMPDIR/repo"
  _got=$(git -C "$_repo" config --get rerere.enabled 2>/dev/null || true)
  [ "$_got" = "false" ] || {
    echo "FAIL: rerere.enabled changed from 'false'; got: '${_got}'" >&2
    echo "      An explicit false must survive --init (operator choice)" >&2
    return 1
  }
}

@test "behavioral: already-true rerere is idempotent (stays true)" {
  _driver="$BATS_TEST_TMPDIR/rerere-idempotent-driver.sh"
  _pre='git -C "$RITE_PROJECT_ROOT" config rerere.enabled true'
  _write_rerere_driver "$_driver" "$_pre"

  run bash "$_driver"
  [ "$status" -eq 0 ] || {
    echo "FAIL: driver exited $status. Output: $output" >&2
    return 1
  }

  _repo="$BATS_TEST_TMPDIR/repo"
  _got=$(git -C "$_repo" config --get rerere.enabled 2>/dev/null || true)
  [ "$_got" = "true" ] || {
    echo "FAIL: rerere.enabled changed from 'true'; got: '${_got}'" >&2
    return 1
  }
}
