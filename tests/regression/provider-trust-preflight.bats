#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh::claude_provider_healthcheck, lib/core/batch-process-issues.sh
# Regression tests for the provider trust preflight (issue #1488).
#
# Claude CLI >=2.1.284 emits "has not been trusted" to stderr in untrusted
# workspaces and ignores all permissions.allow entries. These tests verify that:
#   1. claude_provider_healthcheck() returns 1 on the trust signal
#   2. The abort message contains hasTrustDialogAccepted and the repo path
#   3. A healthy stub passes with exit 0
#   4. The stub receives --print (trivial invocation, not a full agentic session)

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT

  export TEST_TMPDIR="${BATS_TEST_TMPDIR}/trust-preflight-test"
  mkdir -p "$TEST_TMPDIR"

  # Stub bin dir — prepend to PATH so fake claude overrides the real one
  export STUB_BIN="$TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"

  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  export RITE_PROJECT_ROOT="$TEST_TMPDIR/repo"
  mkdir -p "$RITE_PROJECT_ROOT"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Helper: write an untrusted-workspace stub into STUB_BIN
# ---------------------------------------------------------------------------
_make_untrusted_stub() {
  local _args_file="$TEST_TMPDIR/claude-args"
  local _repo="$RITE_PROJECT_ROOT"
  # Use printf to write the script to avoid heredoc-in-cmdsubst parse issues
  printf '#!/bin/bash\n' > "$STUB_BIN/claude"
  printf 'printf "%%s\\n" "$@" > "%s"\n' "$_args_file" >> "$STUB_BIN/claude"
  printf 'echo "Ignoring 328 permissions.allow entries: this workspace has not been trusted. Run: set projects[\"%s\"].hasTrustDialogAccepted: true in ~/.claude.json." >&2\n' \
    "$_repo" >> "$STUB_BIN/claude"
  printf 'exit 1\n' >> "$STUB_BIN/claude"
  chmod +x "$STUB_BIN/claude"
}

# ---------------------------------------------------------------------------
# Helper: write a healthy (trusted) stub into STUB_BIN
# ---------------------------------------------------------------------------
_make_trusted_stub() {
  local _args_file="$TEST_TMPDIR/claude-args"
  printf '#!/bin/bash\n' > "$STUB_BIN/claude"
  printf 'printf "%%s\\n" "$@" > "%s"\n' "$_args_file" >> "$STUB_BIN/claude"
  printf 'echo "ok"\n' >> "$STUB_BIN/claude"
  printf 'exit 0\n' >> "$STUB_BIN/claude"
  chmod +x "$STUB_BIN/claude"
}

# ---------------------------------------------------------------------------
# Test 1: untrusted stub → healthcheck returns 1
# ---------------------------------------------------------------------------
@test "provider_healthcheck: untrusted workspace returns exit 1" {
  _make_untrusted_stub

  run bash -c "
    export PATH='$STUB_BIN:\$PATH'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    source '$RITE_LIB_DIR/providers/provider-interface.sh'
    load_provider 'claude'
    provider_detect_cli 2>/dev/null || true
    provider_healthcheck
  "
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 2: abort message contains the required fix-command token
# ---------------------------------------------------------------------------
@test "provider_healthcheck: untrusted message contains hasTrustDialogAccepted" {
  _make_untrusted_stub

  run bash -c "
    export PATH='$STUB_BIN:\$PATH'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    source '$RITE_LIB_DIR/providers/provider-interface.sh'
    load_provider 'claude'
    provider_detect_cli 2>/dev/null || true
    provider_healthcheck 2>&1
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"hasTrustDialogAccepted"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: abort message contains the affected repo path
# ---------------------------------------------------------------------------
@test "provider_healthcheck: untrusted message contains repo path" {
  _make_untrusted_stub

  run bash -c "
    export PATH='$STUB_BIN:\$PATH'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    source '$RITE_LIB_DIR/providers/provider-interface.sh'
    load_provider 'claude'
    provider_detect_cli 2>/dev/null || true
    provider_healthcheck 2>&1
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"$RITE_PROJECT_ROOT"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: healthy stub → healthcheck returns 0
# ---------------------------------------------------------------------------
@test "provider_healthcheck: trusted workspace returns exit 0" {
  _make_trusted_stub

  run bash -c "
    export PATH='$STUB_BIN:\$PATH'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    source '$RITE_LIB_DIR/providers/provider-interface.sh'
    load_provider 'claude'
    provider_detect_cli 2>/dev/null || true
    provider_healthcheck 2>/dev/null
  "
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 5: stub receives --print (trivial invocation, not agentic session args)
# ---------------------------------------------------------------------------
@test "provider_healthcheck: invokes claude with --print (trivial, not --output-format stream-json)" {
  _make_trusted_stub

  bash -c "
    export PATH='$STUB_BIN:\$PATH'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    source '$RITE_LIB_DIR/providers/provider-interface.sh'
    load_provider 'claude'
    provider_detect_cli 2>/dev/null || true
    provider_healthcheck 2>/dev/null
  " || true

  [ -f "$TEST_TMPDIR/claude-args" ]
  grep -q -- "--print" "$TEST_TMPDIR/claude-args"
  # Must NOT contain the agentic-session flag (that would be an expensive full session)
  ! grep -q "stream-json" "$TEST_TMPDIR/claude-args"
}

# ---------------------------------------------------------------------------
# Test 6: provider_healthcheck is accessible via the provider_* alias
# ---------------------------------------------------------------------------
@test "load_provider wires healthcheck alias correctly" {
  _make_trusted_stub

  run bash -c "
    export PATH='$STUB_BIN:\$PATH'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    source '$RITE_LIB_DIR/providers/provider-interface.sh'
    load_provider 'claude'
    # Verify provider_healthcheck is a function (alias wired correctly)
    declare -f provider_healthcheck >/dev/null 2>&1 || { echo 'ALIAS_MISSING'; exit 1; }
    echo 'ALIAS_OK'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALIAS_OK"* ]]
}
