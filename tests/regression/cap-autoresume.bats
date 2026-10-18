#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/cap-resume.sh, lib/core/batch-process-issues.sh
# tests/regression/cap-autoresume.bats
#
# Regression tests: opt-in auto-resume after a usage-cap abort (issue #1143).
#
# When RITE_CAP_AUTORESUME=true and the cap-resume manifest has a valid future
# reset_epoch, batch-process-issues.sh must:
#   - Wait (with caffeinate on AC power, without on battery)
#   - exec rite with the remaining issues from the manifest (exactly once)
#   - NOT re-schedule when the manifest already has resumed:true
#
# When the flag is off (or unset), behavior must be byte-identical to before:
#   - attempt_cap_autoresume returns 0, caller proceeds to break
#
# Tests in this file:
#
#   STRUCTURAL:
#     1.  cap-resume.sh is sourced in batch-process-issues.sh
#     2.  attempt_cap_autoresume is called in the exit-5 handler
#     3.  RITE_CAP_AUTORESUME is documented in config/rite.conf.example
#     4.  RITE_CAP_AUTORESUME appears in CLAUDE.md session-limits section
#
#   UNIT / BEHAVIORAL (via recording stubs):
#     5.  Flag off → attempt_cap_autoresume returns 0 (no exec, no caffeinate)
#     6.  Flag on + future epoch + AC power → caffeinate invoked, exec'd with manifest issues
#     7.  Flag on + future epoch + battery power → caffeinate NOT invoked, exec still fires
#     8.  Second cap (resumed:true) → attempt_cap_autoresume returns 0 without exec
#     9.  Flag on + epoch 0 (unknown reset) → returns 0 without exec
#    10.  Flag on + epoch in the past → returns 0 without exec

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CAP_RESUME="$REPO_ROOT/lib/utils/cap-resume.sh"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
RITE_CONF_EXAMPLE="$REPO_ROOT/config/rite.conf.example"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

setup() {
  for _f in "$CAP_RESUME" "$BATCH_PROCESSOR" "$RITE_CONF_EXAMPLE" "$CLAUDE_MD"; do
    [ -f "$_f" ] || {
      echo "FATAL: $_f not found" >&2
      return 1
    }
  done
  _tmpdir=$(mktemp -d)
  _exec_log="$_tmpdir/exec.log"
  _caff_log="$_tmpdir/caffeinate.log"

  # Stub bin dir — prepend to PATH in behavioral tests
  _stub_bin="$_tmpdir/bin"
  mkdir -p "$_stub_bin"

  # rite stub: record argv to exec log, exit 0
  # Uses printf to avoid heredoc-in-cmdsubst on bash 3.2 (though tests run under bash 4+,
  # being explicit keeps the generator readable and lint-clean).
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s"\nexit 0\n' "$_exec_log" \
    > "$_stub_bin/rite"
  chmod +x "$_stub_bin/rite"

  # caffeinate stub: record invocation args (including -i / -t)
  printf '#!/bin/bash\necho "caffeinate $*" >> "%s"\n' "$_caff_log" \
    > "$_stub_bin/caffeinate"
  chmod +x "$_stub_bin/caffeinate"

  # pmset-AC stub: reports "AC Power"
  printf '#!/bin/bash\necho "Now drawing from '"'"'AC Power'"'"'"\n' \
    > "$_stub_bin/pmset-ac"
  chmod +x "$_stub_bin/pmset-ac"

  # pmset-battery stub: reports "Battery Power"
  printf '#!/bin/bash\necho "Now drawing from '"'"'Battery Power'"'"'"\n' \
    > "$_stub_bin/pmset-battery"
  chmod +x "$_stub_bin/pmset-battery"
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# Helper: build a cap-resume manifest in $_tmpdir/cap-resume.json.
# Arguments: issues_json(e.g."[1303,1232]") flags_str reset_epoch_offset resumed(true|false)
_make_manifest() {
  local _issues_json="${1:-[1303,1232]}"
  local _flags="${2:-}"
  local _epoch_offset="${3:-3600}"
  local _resumed="${4:-false}"
  local _future_epoch
  _future_epoch=$(( $(date +%s) + _epoch_offset ))
  jq -n \
    --argjson issues "$_issues_json" \
    --arg flags "$_flags" \
    --argjson reset_epoch "$_future_epoch" \
    --arg reset_text "resets 1:00am" \
    --argjson written "$(date +%s)" \
    --argjson resumed "$_resumed" \
    '{issues: $issues, flags: $flags, reset_epoch: $reset_epoch,
      reset_text: $reset_text, written: $written, resumed: $resumed}' \
    > "$_tmpdir/cap-resume.json"
  echo "$_tmpdir/cap-resume.json"
}

# ==============================================================================
# STRUCTURAL: static code inspection
# ==============================================================================

@test "structural: cap-resume.sh is sourced in batch-process-issues.sh" {
  grep -q 'cap-resume.sh' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'cap-resume.sh' source line not found in batch-process-issues.sh" >&2
    return 1
  }
}

@test "structural: attempt_cap_autoresume is called in the exit-5 handler" {
  # The call must appear after the exit_code -eq 5 check (within 50 lines of it)
  # to be sure it is inside the cap-abort handler, not elsewhere in the file.
  _guard_line=$(grep -n 'EXIT_CODE -eq 5' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)
  _call_line=$(grep -n 'attempt_cap_autoresume' "$BATCH_PROCESSOR" | head -1 | cut -d: -f1 || true)
  [ -n "$_guard_line" ] && [ -n "$_call_line" ] || {
    echo "FAIL: exit-code-5 guard or attempt_cap_autoresume call not found" >&2
    return 1
  }
  _distance=$(( _call_line - _guard_line ))
  [ "$_distance" -gt 0 ] && [ "$_distance" -le 100 ] || {
    echo "FAIL: attempt_cap_autoresume call (line $_call_line) is not within 100 lines" >&2
    echo "      after the EXIT_CODE -eq 5 guard (line $_guard_line)" >&2
    return 1
  }
}

@test "structural: RITE_CAP_AUTORESUME documented in config/rite.conf.example" {
  grep -q 'RITE_CAP_AUTORESUME' "$RITE_CONF_EXAMPLE" || {
    echo "FAIL: RITE_CAP_AUTORESUME not found in config/rite.conf.example" >&2
    return 1
  }
}

@test "structural: RITE_CAP_AUTORESUME appears in CLAUDE.md session-limits section" {
  grep -q 'RITE_CAP_AUTORESUME' "$CLAUDE_MD" || {
    echo "FAIL: RITE_CAP_AUTORESUME not found in CLAUDE.md" >&2
    return 1
  }
}

# ==============================================================================
# UNIT / BEHAVIORAL: recording stubs
# ==============================================================================

# Helper: subprocess preamble shared by behavioral tests.
# Defines minimal stubs for print helpers, _format_elapsed, and release_batch_lock
# so the function can run without loading the full lib stack.
# Also overrides _cap_autoresume_wait to a no-op so tests do not block.
_cap_resume_preamble() {
  cat <<'PREAMBLE'
print_info()    { echo "[info] $*"; }
print_warning() { echo "[warn] $*"; }
print_error()   { echo "[err]  $*" >&2; }
_format_elapsed() { echo "${1}s"; }
release_batch_lock() { echo "lock-released"; }
source "$CAP_RESUME"
set +u; set +o pipefail
_cap_autoresume_wait() { :; }
PREAMBLE
}

@test "behavioral: flag off → attempt_cap_autoresume returns 0 (no exec, no caffeinate)" {
  _manifest=$(_make_manifest "[42,43]" "" 3600 false)

  run bash -c "
    CAP_RESUME='$CAP_RESUME'
    $(_cap_resume_preamble)
    export RITE_CAP_AUTORESUME=false
    attempt_cap_autoresume '$_manifest'
    echo 'returned-0'
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: subprocess exited $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  # Must see 'returned-0' — function returned without exec replacing the shell
  echo "$output" | grep -q 'returned-0' || {
    echo "FAIL: expected 'returned-0' in output — function must return, not exec" >&2
    echo "      output: $output" >&2
    return 1
  }
  # rite stub must NOT have been called
  [ ! -f "$_exec_log" ] || {
    echo "FAIL: rite stub was invoked — exec should not fire when flag is off" >&2
    echo "      exec log: $(cat "$_exec_log")" >&2
    return 1
  }
  # caffeinate must NOT have been called
  [ ! -f "$_caff_log" ] || {
    echo "FAIL: caffeinate stub was invoked — must not run when flag is off" >&2
    return 1
  }
}

@test "behavioral: flag on + future epoch + AC power → caffeinate invoked, exec fires with manifest issues" {
  _manifest=$(_make_manifest "[1303,1232]" "" 3600 false)

  # Use pmset-ac as pmset (reports AC Power)
  cp "$_stub_bin/pmset-ac" "$_stub_bin/pmset"

  run bash -c "
    export PATH='$_stub_bin:$PATH'
    CAP_RESUME='$CAP_RESUME'
    EXEC_LOG='$_exec_log'
    CAFF_LOG='$_caff_log'
    $(_cap_resume_preamble)
    export RITE_CAP_AUTORESUME=true
    attempt_cap_autoresume '$_manifest'
    echo 'returned-unexpectedly'
  "
  # exec replaces the shell — rite stub exits 0, so status should be 0
  [ "$status" -eq 0 ] || {
    echo "FAIL: subprocess exited $status (expected 0 from rite stub)" >&2
    echo "      output: $output" >&2
    return 1
  }
  # 'returned-unexpectedly' must NOT appear — exec must have fired
  echo "$output" | grep -q 'returned-unexpectedly' && {
    echo "FAIL: function returned instead of exec'ing rite" >&2
    echo "      output: $output" >&2
    return 1
  } || true
  # rite stub must have been called with the manifest issues
  [ -f "$_exec_log" ] || {
    echo "FAIL: rite stub exec log not found — exec did not fire" >&2
    return 1
  }
  grep -q '1303' "$_exec_log" || {
    echo "FAIL: issue 1303 not in rite exec args" >&2
    echo "      exec log: $(cat "$_exec_log")" >&2
    return 1
  }
  grep -q '1232' "$_exec_log" || {
    echo "FAIL: issue 1232 not in rite exec args" >&2
    echo "      exec log: $(cat "$_exec_log")" >&2
    return 1
  }
  # caffeinate must have been invoked (AC power)
  [ -f "$_caff_log" ] || {
    echo "FAIL: caffeinate stub log not found — caffeinate must run on AC power" >&2
    return 1
  }
  grep -q '\-i' "$_caff_log" || {
    echo "FAIL: caffeinate not called with -i flag" >&2
    echo "      caffeinate log: $(cat "$_caff_log")" >&2
    return 1
  }
}

@test "behavioral: flag on + future epoch + battery power → caffeinate NOT invoked, exec still fires" {
  _manifest=$(_make_manifest "[1303,1232]" "" 3600 false)

  # Use pmset-battery as pmset (reports Battery Power)
  cp "$_stub_bin/pmset-battery" "$_stub_bin/pmset"

  run bash -c "
    export PATH='$_stub_bin:$PATH'
    CAP_RESUME='$CAP_RESUME'
    $(_cap_resume_preamble)
    export RITE_CAP_AUTORESUME=true
    attempt_cap_autoresume '$_manifest'
    echo 'returned-unexpectedly'
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: subprocess exited $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  # exec must have fired (rite stub ran)
  [ -f "$_exec_log" ] || {
    echo "FAIL: rite stub exec log not found — exec did not fire on battery path" >&2
    return 1
  }
  # caffeinate must NOT have been invoked
  [ ! -f "$_caff_log" ] || {
    echo "FAIL: caffeinate was invoked on battery — must only run on AC power" >&2
    echo "      caffeinate log: $(cat "$_caff_log")" >&2
    return 1
  }
  # Battery notice must appear in output
  echo "$output" | grep -qi 'battery' || {
    echo "FAIL: battery notice not printed (expected 'battery' in output)" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "behavioral: second cap (resumed:true in manifest) → returns 0 without exec" {
  _manifest=$(_make_manifest "[1303,1232]" "" 3600 true)

  run bash -c "
    export PATH='$_stub_bin:$PATH'
    CAP_RESUME='$CAP_RESUME'
    $(_cap_resume_preamble)
    export RITE_CAP_AUTORESUME=true
    attempt_cap_autoresume '$_manifest'
    echo 'returned-0'
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: subprocess exited $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  echo "$output" | grep -q 'returned-0' || {
    echo "FAIL: expected 'returned-0' — second cap must not reschedule" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ ! -f "$_exec_log" ] || {
    echo "FAIL: rite stub invoked — second cap must NOT re-schedule" >&2
    echo "      exec log: $(cat "$_exec_log")" >&2
    return 1
  }
}

@test "behavioral: flag on + epoch 0 → returns 0 without exec" {
  # reset_epoch=0 means the cap message had no parseable time
  local _manifest="$_tmpdir/cap-resume.json"
  jq -n \
    --argjson issues "[42]" --arg flags "" \
    --argjson reset_epoch 0 --arg reset_text "resets unknown" \
    --argjson written "$(date +%s)" --argjson resumed false \
    '{issues: $issues, flags: $flags, reset_epoch: $reset_epoch,
      reset_text: $reset_text, written: $written, resumed: $resumed}' \
    > "$_manifest"

  run bash -c "
    export PATH='$_stub_bin:$PATH'
    CAP_RESUME='$CAP_RESUME'
    $(_cap_resume_preamble)
    export RITE_CAP_AUTORESUME=true
    attempt_cap_autoresume '$_manifest'
    echo 'returned-0'
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: subprocess exited $status" >&2
    return 1
  }
  echo "$output" | grep -q 'returned-0' || {
    echo "FAIL: expected 'returned-0' for epoch=0 case" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ ! -f "$_exec_log" ] || {
    echo "FAIL: rite stub invoked — must not exec when reset_epoch=0" >&2
    return 1
  }
}

@test "behavioral: flag on + epoch in the past → returns 0 without exec" {
  local _manifest="$_tmpdir/cap-resume.json"
  local _past_epoch
  _past_epoch=$(( $(date +%s) - 7200 ))
  jq -n \
    --argjson issues "[42]" --arg flags "" \
    --argjson reset_epoch "$_past_epoch" --arg reset_text "resets 12:00am" \
    --argjson written "$(date +%s)" --argjson resumed false \
    '{issues: $issues, flags: $flags, reset_epoch: $reset_epoch,
      reset_text: $reset_text, written: $written, resumed: $resumed}' \
    > "$_manifest"

  run bash -c "
    export PATH='$_stub_bin:$PATH'
    CAP_RESUME='$CAP_RESUME'
    $(_cap_resume_preamble)
    export RITE_CAP_AUTORESUME=true
    attempt_cap_autoresume '$_manifest'
    echo 'returned-0'
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: subprocess exited $status" >&2
    return 1
  }
  echo "$output" | grep -q 'returned-0' || {
    echo "FAIL: expected 'returned-0' for past-epoch case" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ ! -f "$_exec_log" ] || {
    echo "FAIL: rite stub invoked — must not exec when reset_epoch is in the past" >&2
    return 1
  }
}
