#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh::claude_provider_run_agentic_session
# tests/regression/agentic-session-stream-termination.bats
#
# Two defects in how claude_provider_run_agentic_session handles its own stdout.
#
# 1. CAP FALSE POSITIVE. The usage-cap scan ran an UNANCHORED substring grep
#    over the raw stream-json capture. Every legitimate line in that capture is
#    a JSON object, so the scan also matched cap phrases carried INSIDE the
#    envelope — in tool_use inputs and tool_result bodies, which the colored
#    stream filter never renders. Seven files in this repo embed those phrases,
#    so any session that merely READ one of them could be converted to exit 5
#    whenever it also exited non-zero for an unrelated reason.
#
#    Live: issue #1169, run rite-1169-20261020-131813. The fix session was
#    blocked from filing a GitHub issue (PreToolUse deny hook), exited non-zero,
#    and the scan turned that into "Claude usage cap reached during fix session
#    — aborting batch". The log contained no cap notice anywhere.
#
#    The exit-0 branch (#1121) was already line-anchored for exactly this
#    reason; the non-zero branch was not. The scan is now per channel:
#    stdout anchored (stream-json has an envelope to anchor against), stderr
#    substring on non-zero (plain text, CLI diagnostics only) and anchored on
#    exit 0 (the #1121 contract, unchanged).
#
# 2. UNTERMINATED LAST LINE. Both stream filters use `jq -j` so text chunks
#    concatenate into prose. The final chunk left the cursor mid-line, so the
#    next workflow message printed flush against the session's own text:
#      ...do a final read-through of all modified files.❌ Claude usage cap...
#
# Tests in this file:
#   CAP SCAN
#     1. cap phrase inside the JSON envelope + non-zero exit → NOT exit 5
#     2. cap phrase at column 0 on stdout + exit 0 → exit 5  (#1121 preserved)
#     3. cap phrase at column 0 on stdout + non-zero exit → exit 5
#     4. cap phrase anywhere in stderr + non-zero exit → exit 5
#     5. unanchored cap phrase in stderr + exit 0 → NOT exit 5  (#1121 preserved)
#     6. conversion emits a CAP_DETECTED diag naming source and phrase
#   STREAM TERMINATION
#     7. session that rendered assistant output ends its stdout with a newline
#     8. capture with no assistant event adds no stray newline
#   STRUCTURAL
#     9. the stdout scan is anchored (no unanchored stdout grep survives)

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CLAUDE_PROVIDER="$REPO_ROOT/lib/providers/claude.sh"

setup() {
  [ -f "$CLAUDE_PROVIDER" ] || {
    echo "FATAL: $CLAUDE_PROVIDER not found" >&2
    return 1
  }
  _tmpdir=$(mktemp -d)
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# Build the stub dir. $1 = body of the fake `claude` (must exit explicitly).
# $2 = optional body of the fake `jq` (default: drain stdin, emit nothing).
#
# Mirrors the harness in batch-auth-halt.bats: stubs claude/jq/tee on a
# restricted PATH that keeps the system dirs the provider itself needs
# (mktemp/rm/grep/uname).
_make_stubs() {
  printf '#!/bin/bash\n%s\n' "$1" > "$_tmpdir/claude"
  chmod +x "$_tmpdir/claude"

  if [ -n "${2:-}" ]; then
    printf '#!/bin/bash\n%s\n' "$2" > "$_tmpdir/jq"
  else
    printf '#!/bin/bash\ncat >/dev/null\n' > "$_tmpdir/jq"
  fi
  chmod +x "$_tmpdir/jq"

  cat > "$_tmpdir/tee" <<'STUB'
#!/bin/bash
_cap="${@: -1}"
while IFS= read -r _line; do
  printf '%s\n' "$_line" >> "$_cap"
  printf '%s\n' "$_line"
done
STUB
  chmod +x "$_tmpdir/tee"
}

# Drive claude_provider_run_agentic_session against the stubs.
# Echoes nothing; sets $status/$output via `run` in the caller.
_session_driver() {
  cat <<DRIVER
    set -euo pipefail
    export PATH='$_tmpdir:/usr/bin:/bin'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    # claude.sh calls ensure_timeout_cmd at source time; the restricted PATH
    # has no timeout/gtimeout, so pre-mark detection as resolved or the source
    # aborts mid-file under set -e and the function never defines.
    export _RITE_TIMEOUT_CHECKED=true
    export RITE_TIMEOUT_CMD=timeout
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10
    export RITE_LOG_FILE='$_tmpdir/run.log'

    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    set +u; set +o pipefail

    run_with_timeout() { shift; "\$@"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    _claude_pretooluse_hook_path() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }
    _diag() { printf '[diag] %s\n' "\$1" >> "\$RITE_LOG_FILE"; }

    _exit=0
    claude_provider_run_agentic_session 'test prompt' 10 true '$_tmpdir/stderr.txt' || _exit=\$?
    exit \$_exit
DRIVER
}

# =============================================================================
# CAP SCAN
# =============================================================================

@test "cap: phrase inside the JSON envelope + non-zero exit does NOT become exit 5" {
  # The exact #1169 shape: a tool_result carrying the text of a repo file that
  # embeds a cap phrase, in a session that failed for an unrelated reason.
  _make_stubs 'cat <<'"'"'JSON'"'"'
{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the cap tests."}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"grep -qiE \"session limit reached\" ..."}]}}
JSON
exit 1'

  run bash -c "$(_session_driver)"

  [ "$status" -ne 5 ] || {
    echo "FAIL: envelope-internal cap phrase converted to exit 5 (#1169 regression)" >&2
    echo "      a cap phrase inside tool_result is file content, not a CLI notice" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ "$status" -eq 1 ] || {
    echo "FAIL: expected the stub's own exit 1 to survive, got: $status" >&2
    return 1
  }
}

@test "cap: column-0 notice on stdout + exit 0 becomes exit 5 (#1121 preserved)" {
  _make_stubs 'echo "You'"'"'ve hit your session limit · resets 9:20pm (America/Denver)"
exit 0'

  run bash -c "$(_session_driver)"

  [ "$status" -eq 5 ] || {
    echo "FAIL: expected exit 5 for an out-of-envelope cap notice, got: $status" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "cap: column-0 notice on stdout + non-zero exit becomes exit 5" {
  _make_stubs 'echo "Spending cap reached resets 11:20pm"
exit 1'

  run bash -c "$(_session_driver)"

  [ "$status" -eq 5 ] || {
    echo "FAIL: expected exit 5 for an out-of-envelope cap notice, got: $status" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "cap: phrase anywhere in stderr + non-zero exit becomes exit 5" {
  # stderr is plain text — CLI diagnostics only, never tool results — so the
  # broad scan stays correct there.
  _make_stubs 'echo "error: 5-hour limit reached, try again later" >&2
exit 1'

  run bash -c "$(_session_driver)"

  [ "$status" -eq 5 ] || {
    echo "FAIL: expected exit 5 for a stderr cap phrase on non-zero exit, got: $status" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "cap: unanchored stderr phrase + exit 0 does NOT become exit 5 (#1121 preserved)" {
  _make_stubs 'echo "note: the session limit reached check lives in claude.sh" >&2
exit 0'

  run bash -c "$(_session_driver)"

  [ "$status" -ne 5 ] || {
    echo "FAIL: exit-0 stderr scan must require the line anchor (#1121 contract)" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "cap: conversion emits a CAP_DETECTED diag naming source and phrase" {
  _make_stubs 'echo "Spending cap reached resets 11:20pm"
exit 1'

  run bash -c "$(_session_driver)"

  [ "$status" -eq 5 ] || {
    echo "FAIL: precondition — expected exit 5, got: $status" >&2
    return 1
  }
  grep -q 'CAP_DETECTED' "$_tmpdir/run.log" || {
    echo "FAIL: no CAP_DETECTED diag written" >&2
    echo "      a silent conversion is undiagnosable after the fact (#1169)" >&2
    echo "      log: $(cat "$_tmpdir/run.log" 2>/dev/null)" >&2
    return 1
  }
  grep -q 'CAP_DETECTED source=stdout' "$_tmpdir/run.log" || {
    echo "FAIL: diag must name the channel that matched" >&2
    echo "      log: $(cat "$_tmpdir/run.log" 2>/dev/null)" >&2
    return 1
  }
  grep -qi 'phrase=.*spending cap reached' "$_tmpdir/run.log" || {
    echo "FAIL: diag must carry the matched phrase" >&2
    echo "      log: $(cat "$_tmpdir/run.log" 2>/dev/null)" >&2
    return 1
  }
}

# =============================================================================
# STREAM TERMINATION
# =============================================================================

@test "newline: a session that rendered assistant output ends stdout with a newline" {
  # jq stub emulates the real filter's `-j`: text, no trailing newline.
  _make_stubs 'cat <<'"'"'JSON'"'"'
{"type":"assistant","message":{"content":[{"type":"text","text":"final read-through of all modified files."}]}}
JSON
exit 0' 'cat >/dev/null; printf "final read-through of all modified files."'

  # Capture the session's stdout to a file: bats strips trailing newlines from
  # $output, so the very byte under test is invisible there.
  run bash -c "exec >'$_tmpdir/out.txt' 2>/dev/null
$(_session_driver)"

  _last=$(tail -c 1 "$_tmpdir/out.txt" | od -An -c | tr -d ' ')
  [ "$_last" = '\n' ] || {
    echo "FAIL: session stdout does not end with a newline (last byte: '$_last')" >&2
    echo "      the next workflow message would print flush against it:" >&2
    echo "      ...all modified files.❌ Claude usage cap reached..." >&2
    echo "      stdout was: $(cat "$_tmpdir/out.txt")" >&2
    return 1
  }
}

@test "newline: a capture with no assistant event adds no stray newline" {
  # Nothing was rendered, so there is no line to terminate.
  _make_stubs 'cat <<'"'"'JSON'"'"'
{"type":"system","subtype":"init"}
JSON
exit 0'

  run bash -c "exec >'$_tmpdir/out.txt' 2>/dev/null
$(_session_driver)"

  _bytes=$(wc -c < "$_tmpdir/out.txt" | tr -d ' ')
  [ "$_bytes" = "0" ] || {
    echo "FAIL: expected 0 bytes of stdout, got: $_bytes" >&2
    echo "      an unconditional newline would print a blank line per session" >&2
    echo "      stdout was: $(cat "$_tmpdir/out.txt")" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL
# =============================================================================

@test "structural: no unanchored cap grep reads the stdout capture" {
  # The whole #1169 bug in one assertion: if any grep of _stdout_capture uses
  # a cap pattern without a '^' anchor, the false positive is back.
  _bad=$(grep -n '_stdout_capture' "$CLAUDE_PROVIDER" \
           | grep -i 'cap reached\|limit reached' \
           | grep -v '\^(' || true)
  [ -z "$_bad" ] || {
    echo "FAIL: unanchored cap pattern reads the stream-json capture:" >&2
    echo "$_bad" >&2
    echo "      stdout is stream-json — scan it line-anchored (see #1169)" >&2
    return 1
  }
}
