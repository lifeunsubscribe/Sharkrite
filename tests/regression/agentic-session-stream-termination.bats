#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh::claude_provider_run_agentic_session
# tests/regression/agentic-session-stream-termination.bats
#
# Regression tests for issue #1367: cap scan anchoring + last-line newline
# termination in claude_provider_run_agentic_session.
# Extended by issue #1409: auth-failure scan anchoring (exit 18 sibling).
#
# Problem 1 (cap false-abort): the non-zero exit branch scanned stdout with an
# unanchored substring grep, so a cap phrase inside the JSON envelope (e.g. in
# a tool_use input or the text of a session editing this very detection) matched,
# converted exit 1 → exit 5, and aborted the batch. Live failure: issue #1169,
# rite-1169-20261020-131813 — the fix session was blocked by the PreToolUse deny
# hook, exited 1, and the scan reported "Claude usage limit reached".
#
# Problem 2 (no trailing newline): both stream filters use jq -j (join output)
# which never appends a trailing newline, so every workflow message printed after
# a session ran flush against the session's own text.
#
# Problem 3 (auth-failure false-abort, issue #1409): the exit-18 branch also
# scanned stdout with an unanchored grep, so an auth phrase inside the JSON
# envelope (e.g. a session editing or documenting the detection) converted
# exit 1 → exit 18 (batch-fatal), halting the entire batch for a false positive.
# Same root cause as Problem 1; fixed with the same ^( anchoring on stdout.
#
# Tests:
#   STRUCTURAL (static code inspection):
#     1. stdout cap scan is line-anchored (acceptance-criterion grep)
#     2. CAP_DETECTED diagnostic present with channel= field
#     8. stdout auth-failure scan is line-anchored
#
#   UNIT (non-zero exit — JSON-embedded cap phrase must not false-abort):
#     3. cap phrase inside JSON assistant message + exit 1 → stays exit 1
#     4. cap phrase at column 0 (bare-line notice) + exit 1 → exit 5
#     4b. "Claude usage limit reached" bare-line + exit 1 → exit 5
#     5. cap phrase in stderr + exit 1 → exit 5 (stderr stays unanchored)
#
#   UNIT (non-zero exit — JSON-embedded auth phrase must not false-abort):
#     9.  auth phrase inside JSON assistant message + exit 1 → stays exit 1
#     10. auth phrase at column 0 (bare-line notice) + exit 1 → exit 18
#     11. auth phrase in stderr + exit 1 → exit 18 (stderr stays unanchored)
#
#   UNIT (newline termination):
#     6. session with assistant text output ends stdout with newline
#     7. session with no assistant output adds no blank line

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CLAUDE_PROVIDER="$REPO_ROOT/lib/providers/claude.sh"

setup() {
  [ -f "$CLAUDE_PROVIDER" ] || {
    echo "FATAL: $CLAUDE_PROVIDER not found" >&2
    return 1
  }
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# =============================================================================
# STRUCTURAL: verify anchoring and diagnostic in implementation
# =============================================================================

@test "structural: stdout cap scan is line-anchored (no _stdout_capture+limit-reached line without ^()" {
  # Acceptance criterion from issue #1367:
  #   grep -n '_stdout_capture' lib/providers/claude.sh | grep -i 'limit reached' | grep -v '\^('
  # must return nothing. Any line that references _stdout_capture AND a cap
  # phrase must anchor the pattern with ^( so the match is column-0 only.
  _result=$(grep -n '_stdout_capture' "$CLAUDE_PROVIDER" | grep -i 'limit reached' | grep -v '\^(' || true)
  [ -z "$_result" ] || {
    echo "FAIL: unanchored stdout cap scan found — lines with _stdout_capture and 'limit reached' without ^(:" >&2
    printf '%s\n' "$_result" >&2
    echo "      Every stdout grep for cap phrases must be anchored with ^( to prevent" >&2
    echo "      false-abort when the phrase appears inside a JSON transcript line." >&2
    return 1
  }
}

@test "structural: CAP_DETECTED diagnostic present with channel= field" {
  grep -qE "CAP_DETECTED.*channel=" "$CLAUDE_PROVIDER" || {
    echo "FAIL: 'CAP_DETECTED channel=' not found in claude.sh" >&2
    echo "      The cap conversion must emit a diagnostic naming the channel and phrase." >&2
    return 1
  }
}

@test "structural: stdout auth-failure scan is line-anchored (no _stdout_capture+auth-phrase without ^()" {
  # Acceptance criterion from issue #1409:
  # Any line that references _stdout_capture AND an auth phrase must anchor
  # the pattern with ^( so the match is column-0 only.
  _result=$(grep -n '_stdout_capture' "$CLAUDE_PROVIDER" | grep -iE 'api key|/login|authentication' | grep -v '\^(' || true)
  [ -z "$_result" ] || {
    echo "FAIL: unanchored stdout auth-failure scan found — lines with _stdout_capture and auth phrases without ^(:" >&2
    printf '%s\n' "$_result" >&2
    echo "      Every stdout grep for auth phrases must be anchored with ^( to prevent" >&2
    echo "      false-abort when the phrase appears inside a JSON transcript line." >&2
    return 1
  }
}

# =============================================================================
# UNIT: non-zero exit + JSON-embedded phrase must not false-abort
#
# Strategy: stub claude to emit a JSON line containing a cap phrase as text
# content inside an assistant message, then exit 1.  The provider must NOT
# detect a cap (exit 5) — the phrase is inside the envelope, not a bare-line
# out-of-envelope notice.
#
# Uses real jq and tee from /usr/bin:/bin (same reasoning as batch-auth-halt.bats
# test 'unit: cap phrase INSIDE a JSON transcript line + exit 0 → stays 0'):
# stubbing jq masked exactly this class of bug.
# =============================================================================

@test "unit: cap phrase inside JSON assistant message + exit 1 → stays exit 1 (no false abort)" {
  _tmpdir=$(mktemp -d)

  # Stub claude: emit a valid stream-json assistant message whose text body
  # contains a cap phrase, then exit 1 (generic failure).  The phrase is
  # INSIDE the JSON envelope — it must not be detected as a cap.
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"note: spending cap reached is the detection phrase being tested\"}]}}"
exit 1
STUB
  chmod +x "$_tmpdir/claude"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:/usr/bin:/bin'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    export _RITE_TIMEOUT_CHECKED=true
    export RITE_TIMEOUT_CMD=timeout
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10
    _sc=\$(mktemp)
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    set +u; set +o pipefail
    run_with_timeout() { shift; \"\$@\"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    _claude_pretooluse_hook_path() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }
    _exit=0
    claude_provider_run_agentic_session 'test prompt' 10 true \"\$_sc\" || _exit=\$?
    exit \$_exit
  "

  [ "$status" -eq 1 ] || {
    echo "FAIL: expected exit 1 (generic failure), got: $status" >&2
    echo "      A cap phrase inside a JSON transcript line must not produce exit 5." >&2
    echo "      This was the live failure in issue #1169: the fix session's transcript" >&2
    echo "      contained the phrase inside a JSON line, but the unanchored scan matched." >&2
    return 1
  }
}

@test "unit: cap phrase at column 0 (bare-line notice) + exit 1 → exit 5" {
  _tmpdir=$(mktemp -d)

  # Stub claude: emit the bare-line cap notice (out-of-envelope, column 0) and exit 1.
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
echo "Spending cap reached resets 11:20pm"
exit 1
STUB
  chmod +x "$_tmpdir/claude"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:/usr/bin:/bin'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    export _RITE_TIMEOUT_CHECKED=true
    export RITE_TIMEOUT_CMD=timeout
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10
    _sc=\$(mktemp)
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    set +u; set +o pipefail
    run_with_timeout() { shift; \"\$@\"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    _claude_pretooluse_hook_path() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }
    _exit=0
    claude_provider_run_agentic_session 'test prompt' 10 true \"\$_sc\" || _exit=\$?
    exit \$_exit
  "

  [ "$status" -eq 5 ] || {
    echo "FAIL: expected exit 5 for bare-line cap notice, got: $status" >&2
    return 1
  }
}

@test "unit: 'Claude usage limit reached' bare-line + exit 1 → exit 5" {
  _tmpdir=$(mktemp -d)

  # Stub claude: emit the "Claude usage limit reached" bare-line notice at
  # column 0 (out-of-envelope, as the CLI emits it) and exit 1.
  # Regression tripwire for the (claude )? fix at lib/providers/claude.sh:213 —
  # without the optional-prefix, "Claude usage limit reached" was not matched
  # on the stdout non-zero path and the session exited 1 (generic failure)
  # instead of exit 5 (cap-abort), so the batch continued rather than halting.
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
echo "Claude usage limit reached resets 11:20pm"
exit 1
STUB
  chmod +x "$_tmpdir/claude"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:/usr/bin:/bin'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    export _RITE_TIMEOUT_CHECKED=true
    export RITE_TIMEOUT_CMD=timeout
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10
    _sc=\$(mktemp)
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    set +u; set +o pipefail
    run_with_timeout() { shift; \"\$@\"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    _claude_pretooluse_hook_path() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }
    _exit=0
    claude_provider_run_agentic_session 'test prompt' 10 true \"\$_sc\" || _exit=\$?
    exit \$_exit
  "

  [ "$status" -eq 5 ] || {
    echo "FAIL: expected exit 5 for 'Claude usage limit reached' bare-line, got: $status" >&2
    echo "      The (claude )? prefix in the stdout cap scan regex is required so" >&2
    echo "      'Claude usage limit reached' is matched. Without it the session exits 1" >&2
    echo "      and the batch continues rather than halting the cap-abort path." >&2
    return 1
  }
}

@test "unit: cap phrase in stderr + exit 1 → exit 5 (stderr is always CLI output, stays unanchored)" {
  _tmpdir=$(mktemp -d)

  # Stub claude: write the cap phrase to stderr (not at column 0) and exit 1.
  # stderr is always the CLI's own output, never the transcript — so the
  # substring (unanchored) match on stderr must still fire.
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
echo "Error: spending cap reached resets 11:20pm" >&2
exit 1
STUB
  chmod +x "$_tmpdir/claude"

  _sc=$(mktemp)

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:/usr/bin:/bin'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    export _RITE_TIMEOUT_CHECKED=true
    export RITE_TIMEOUT_CMD=timeout
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    set +u; set +o pipefail
    run_with_timeout() { shift; \"\$@\"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    _claude_pretooluse_hook_path() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }
    _exit=0
    claude_provider_run_agentic_session 'test prompt' 10 true '$_sc' || _exit=\$?
    exit \$_exit
  "

  [ "$status" -eq 5 ] || {
    echo "FAIL: expected exit 5 for stderr cap phrase, got: $status" >&2
    echo "      stderr is always CLI output — unanchored match must fire." >&2
    return 1
  }

  rm -f "$_sc"
}

# =============================================================================
# UNIT: non-zero exit + JSON-embedded auth phrase must not false-abort (exit 18)
#
# Same strategy as the cap tests above: stub claude to emit a JSON line whose
# text body contains an auth phrase, then exit 1. The provider must NOT detect
# an auth failure (exit 18) — the phrase is inside the envelope, not a bare-line
# out-of-envelope CLI error.
# =============================================================================

@test "unit: auth phrase inside JSON assistant message + exit 1 → stays exit 1 (no false auth-abort)" {
  _tmpdir=$(mktemp -d)

  # Stub claude: emit a valid stream-json assistant message whose text body
  # contains an auth phrase, then exit 1 (generic failure). The phrase is
  # INSIDE the JSON envelope — it must not be detected as an auth failure.
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"note: invalid api key is the detection phrase being tested here\"}]}}"
exit 1
STUB
  chmod +x "$_tmpdir/claude"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:/usr/bin:/bin'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    export _RITE_TIMEOUT_CHECKED=true
    export RITE_TIMEOUT_CMD=timeout
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10
    _sc=\$(mktemp)
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    set +u; set +o pipefail
    run_with_timeout() { shift; \"\$@\"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    _claude_pretooluse_hook_path() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }
    _exit=0
    claude_provider_run_agentic_session 'test prompt' 10 true \"\$_sc\" || _exit=\$?
    exit \$_exit
  "

  [ "$status" -eq 1 ] || {
    echo "FAIL: expected exit 1 (generic failure), got: $status" >&2
    echo "      An auth phrase inside a JSON transcript line must not produce exit 18." >&2
    echo "      Unanchored stdout scan converts exit 1 → exit 18 (batch-fatal) on false match." >&2
    return 1
  }
}

@test "unit: auth phrase at column 0 (bare-line CLI error) + exit 1 → exit 18" {
  _tmpdir=$(mktemp -d)

  # Stub claude: emit the bare-line auth error (out-of-envelope, column 0) and exit 1.
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
echo "Invalid API key · Please run /login"
exit 1
STUB
  chmod +x "$_tmpdir/claude"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:/usr/bin:/bin'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    export _RITE_TIMEOUT_CHECKED=true
    export RITE_TIMEOUT_CMD=timeout
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10
    _sc=\$(mktemp)
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    set +u; set +o pipefail
    run_with_timeout() { shift; \"\$@\"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    _claude_pretooluse_hook_path() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }
    _exit=0
    claude_provider_run_agentic_session 'test prompt' 10 true \"\$_sc\" || _exit=\$?
    exit \$_exit
  "

  [ "$status" -eq 18 ] || {
    echo "FAIL: expected exit 18 for bare-line auth error, got: $status" >&2
    echo "      'Invalid API key' at column 0 must trigger the auth-failure path." >&2
    return 1
  }
}

@test "unit: auth phrase in stderr + exit 1 → exit 18 (stderr is always CLI output, stays unanchored)" {
  _tmpdir=$(mktemp -d)

  # Stub claude: write the auth phrase to stderr (not at column 0) and exit 1.
  # stderr is always the CLI's own output — the unanchored stderr match must fire.
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
echo "API Error: 401 invalid authentication credentials, please run /login" >&2
exit 1
STUB
  chmod +x "$_tmpdir/claude"

  _sc=$(mktemp)

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:/usr/bin:/bin'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    export _RITE_TIMEOUT_CHECKED=true
    export RITE_TIMEOUT_CMD=timeout
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    set +u; set +o pipefail
    run_with_timeout() { shift; \"\$@\"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    _claude_pretooluse_hook_path() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }
    _exit=0
    claude_provider_run_agentic_session 'test prompt' 10 true '$_sc' || _exit=\$?
    exit \$_exit
  "

  [ "$status" -eq 18 ] || {
    echo "FAIL: expected exit 18 for stderr auth error, got: $status" >&2
    echo "      stderr is always CLI output — unanchored match must fire." >&2
    return 1
  }

  rm -f "$_sc"
}

# =============================================================================
# UNIT: newline termination
#
# jq -j never appends a trailing newline; without the fix the next workflow
# message runs flush against the session's text output.
#
# These tests capture the agentic session's stdout to a file (not via bats'
# `run`, which strips trailing newlines from $output) and check the last byte.
# =============================================================================

@test "unit: session with assistant text output terminates stdout with newline" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  _tmpdir=$(mktemp -d)
  _out="$_tmpdir/session.out"

  # Stub claude: emit a valid stream-json assistant text message and exit 0.
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hello from the session\"}]}}"
echo "{\"type\":\"result\",\"result\":null}"
exit 0
STUB
  chmod +x "$_tmpdir/claude"

  bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:/usr/bin:/bin'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    export _RITE_TIMEOUT_CHECKED=true
    export RITE_TIMEOUT_CMD=timeout
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10
    _sc=\$(mktemp)
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    set +u; set +o pipefail
    run_with_timeout() { shift; \"\$@\"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    _claude_pretooluse_hook_path() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }
    claude_provider_run_agentic_session 'test prompt' 10 true \"\$_sc\" || true
  " > "$_out" 2>/dev/null || true

  [ -f "$_out" ] || {
    echo "FAIL: session output file not created" >&2
    return 1
  }
  [ -s "$_out" ] || {
    echo "FAIL: session output is empty — jq did not render the assistant text" >&2
    return 1
  }

  # Last byte must be 0a (newline). tail -c 1 | od converts to hex.
  _last_byte=$(tail -c 1 "$_out" | od -An -tx1 | tr -d ' \n' || true)
  [ "$_last_byte" = "0a" ] || {
    echo "FAIL: last byte is '${_last_byte}' (expected '0a' = newline)" >&2
    echo "      jq -j does not emit a trailing newline; the fix must add one via printf '\\n'." >&2
    return 1
  }
}

@test "unit: session with no assistant output adds no blank line" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  _tmpdir=$(mktemp -d)
  _out="$_tmpdir/session.out"

  # Stub claude: emit only a non-assistant result line (no text rendered).
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
echo "{\"type\":\"result\",\"result\":null}"
exit 0
STUB
  chmod +x "$_tmpdir/claude"

  bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:/usr/bin:/bin'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    export _RITE_TIMEOUT_CHECKED=true
    export RITE_TIMEOUT_CMD=timeout
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10
    _sc=\$(mktemp)
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    set +u; set +o pipefail
    run_with_timeout() { shift; \"\$@\"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    _claude_pretooluse_hook_path() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }
    claude_provider_run_agentic_session 'test prompt' 10 true \"\$_sc\" || true
  " > "$_out" 2>/dev/null || true

  # Output must be empty (jq produced nothing for non-assistant input) OR must
  # not end with a blank line (two consecutive newlines = spurious blank line).
  if [ -s "$_out" ]; then
    _last_two=$(tail -c 2 "$_out" | od -An -tx1 | tr -d ' \n' || true)
    [ "$_last_two" != "0a0a" ] || {
      echo "FAIL: output ends with blank line (\\n\\n) — fix emitted spurious newline" >&2
      echo "      printf '\\n' must only fire when an assistant message was present." >&2
      return 1
    }
  fi
}
