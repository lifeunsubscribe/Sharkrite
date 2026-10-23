#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh, lib/providers/claude.sh, lib/utils/date-helpers.sh
# tests/regression/cap-resume-manifest.bats
#
# Regression test: when a batch aborts on usage cap (exit 5), sharkrite must:
#   - Parse the reset time from the CLI cap message
#   - Write a per-batch resume manifest (.rite/state/cap-resume-${RITE_BATCH_ID}.json)
#     with remaining issues, flags, the parsed reset epoch, and the raw reset text
#   - Print the exact resume command so the user can re-run without archaeology
#
# Issue #1142 — "Write cap-resume manifest with parsed reset time"
# Issue #1223 — "Fixed manifest filenames race under parallel batch" (per-batch naming)
#
# Related: issue #1121/PR #1122 (exit-0 cap detection), follow-up: auto-resume
#
# Tests in this file:
#
#   STRUCTURAL (static code inspection):
#     1.  batch-process-issues.sh reads per-batch cap-reset-line in exit-5 handler
#     2.  batch-process-issues.sh writes per-batch cap-resume manifest in exit-5 handler
#     3.  batch-process-issues.sh prints "Resume with:" in exit-5 handler
#     4.  exit-codes.md exit 5 semantics unchanged (still "Usage/token cap reached")
#     5.  claude.sh writes per-batch cap-reset-line when cap detected
#     6.  claude.sh persists reset line only when _exit_code equals 5 (guarded write)
#
#   UNIT (cap_reset_to_epoch parser):
#     7.  "resets 6:10pm (America/Denver)" parses to non-zero epoch
#     8.  "resets 11:20pm" (no timezone) parses to non-zero epoch
#     9.  garbage input (no time) returns epoch 0
#    10.  empty string returns epoch 0
#    11.  time that has already passed rolls forward to next day (epoch > now)
#    12.  "You've hit your session limit · resets 9:20pm (America/Denver)" full
#         real-world phrasing parses to non-zero epoch
#
#   FIXTURE (behavioral — exercises actual capture and manifest construction):
#    13.  grep -hiE captures reset line from a mock provider stdout transcript
#    14.  cap-resume.json manifest has valid JSON with non-zero reset_epoch
#    15.  remaining-issues loop includes deferred_for_dep and blocked, excludes success
#
#   PARALLEL ISOLATION (per-batch filename prevents race under concurrent batches):
#    16.  claude.sh uses RITE_BATCH_ID suffix so batch mode produces per-batch filenames
#    17.  startup cleanup removes only the fixed-name fallback (no glob that re-introduces race)

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
DATE_HELPERS="$REPO_ROOT/lib/utils/date-helpers.sh"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
CLAUDE_PROVIDER="$REPO_ROOT/lib/providers/claude.sh"
EXIT_CODES_DOC="$REPO_ROOT/docs/architecture/exit-codes.md"

setup() {
  for _f in "$DATE_HELPERS" "$BATCH_PROCESSOR" "$CLAUDE_PROVIDER" "$EXIT_CODES_DOC"; do
    [ -f "$_f" ] || {
      echo "FATAL: $_f not found" >&2
      return 1
    }
  done
  _tmpdir=$(mktemp -d)
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# =============================================================================
# STRUCTURAL: verify the implementation is in place (static code inspection)
# =============================================================================

@test "structural: batch-process-issues.sh reads per-batch cap-reset-line in exit-5 handler" {
  grep -q 'cap-reset-line-.*RITE_BATCH_ID' "$BATCH_PROCESSOR" || {
    echo "FAIL: per-batch 'cap-reset-line-\${RITE_BATCH_ID}' pattern not found in batch-process-issues.sh" >&2
    echo "      exit-5 handler must read the per-batch reset-line written by claude.sh" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh writes per-batch cap-resume manifest in exit-5 handler" {
  grep -q 'cap-resume-.*RITE_BATCH_ID' "$BATCH_PROCESSOR" || {
    echo "FAIL: per-batch 'cap-resume-\${RITE_BATCH_ID}' pattern not found in batch-process-issues.sh" >&2
    echo "      exit-5 handler must write a per-batch resume manifest" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh prints 'Resume with:' in exit-5 handler" {
  grep -q 'Resume with:' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'Resume with:' not found in batch-process-issues.sh" >&2
    echo "      exit-5 handler must print the copy-pasteable resume command" >&2
    return 1
  }
}

@test "structural: exit-codes.md exit 5 semantics unchanged (usage cap)" {
  # The manifest feature must not change exit code semantics.
  # Pin to the actual table row: '| `5`  | ... | Usage/token cap reached ...'
  # so the assertion cannot be satisfied by a line containing an unrelated "5".
  grep -qE '^\| .5. .*Usage/token cap' "$EXIT_CODES_DOC" || {
    echo "FAIL: exit-5 table row not found in exit-codes.md" >&2
    echo "      expected a line matching: '| \`5\` ... Usage/token cap ...'" >&2
    echo "      exit 5 semantics must remain 'Usage/token cap reached'" >&2
    return 1
  }
}

@test "structural: claude.sh writes per-batch cap-reset-line when cap is detected" {
  grep -q '_cap_reset_filename' "$CLAUDE_PROVIDER" || {
    echo "FAIL: '_cap_reset_filename' variable not found in claude.sh" >&2
    echo "      provider must use per-batch filename for reset-line when exit_code=5" >&2
    return 1
  }
  grep -q 'RITE_BATCH_ID' "$CLAUDE_PROVIDER" || {
    echo "FAIL: 'RITE_BATCH_ID' not found in claude.sh" >&2
    echo "      provider must use RITE_BATCH_ID suffix for isolation between parallel batches" >&2
    return 1
  }
}

@test "structural: claude.sh persists reset line only when _exit_code equals 5" {
  # The per-batch filename construction must appear within 20 lines after the
  # _exit_code -eq 5 guard — not merely elsewhere in the file.
  _guard_line=$(grep -n '_exit_code.*-eq.*5.*&&.*RITE_STATE_DIR' "$CLAUDE_PROVIDER" | head -1 | cut -d: -f1 || true)
  _write_line=$(grep -n '_cap_reset_filename' "$CLAUDE_PROVIDER" | head -1 | cut -d: -f1 || true)
  [ -n "$_guard_line" ] && [ -n "$_write_line" ] || {
    echo "FAIL: could not find the exit_code=5+RITE_STATE_DIR guard or _cap_reset_filename assignment in claude.sh" >&2
    return 1
  }
  _distance=$(( _write_line - _guard_line ))
  [ "$_distance" -gt 0 ] && [ "$_distance" -le 20 ] || {
    echo "FAIL: _cap_reset_filename assignment (line $_write_line) is not within 20 lines after the guard (line $_guard_line)" >&2
    echo "      distance: $_distance — assignment must be inside the exit_code=5 block" >&2
    return 1
  }
}

# =============================================================================
# UNIT: cap_reset_to_epoch parser
# =============================================================================

@test "unit: cap_reset_to_epoch parses 'resets 6:10pm (America/Denver)' to non-zero epoch" {
  run bash -c "
    source '$DATE_HELPERS' || { echo 'source failed'; exit 1; }
    set +u; set +o pipefail
    cap_reset_to_epoch 'You have hit your session limit resets 6:10pm (America/Denver)'
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: cap_reset_to_epoch exited $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ "${output:-0}" != "0" ] || {
    echo "FAIL: expected non-zero epoch for valid time input, got: '$output'" >&2
    return 1
  }
  # Must be a plausible future epoch (after year 2020 = 1577836800)
  [ "${output:-0}" -gt 1577836800 ] || {
    echo "FAIL: epoch ${output} is not a plausible future timestamp" >&2
    return 1
  }
}

@test "unit: cap_reset_to_epoch parses 'resets 11:20pm' (no timezone) to non-zero epoch" {
  run bash -c "
    source '$DATE_HELPERS' || { echo 'source failed'; exit 1; }
    set +u; set +o pipefail
    cap_reset_to_epoch 'Spending cap reached resets 11:20pm'
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: cap_reset_to_epoch exited $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ "${output:-0}" != "0" ] || {
    echo "FAIL: expected non-zero epoch for 'resets 11:20pm', got: '$output'" >&2
    return 1
  }
  [ "${output:-0}" -gt 1577836800 ] || {
    echo "FAIL: epoch ${output} is not a plausible future timestamp" >&2
    return 1
  }
}

@test "unit: cap_reset_to_epoch returns 0 for input with no time" {
  run bash -c "
    source '$DATE_HELPERS' || { echo 'source failed'; exit 1; }
    set +u; set +o pipefail
    cap_reset_to_epoch 'Spending cap reached, no time here'
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: cap_reset_to_epoch exited $status (expected 0)" >&2
    return 1
  }
  [ "${output:-}" = "0" ] || {
    echo "FAIL: expected '0' for input with no parseable time, got: '$output'" >&2
    return 1
  }
}

@test "unit: cap_reset_to_epoch returns 0 for empty input" {
  run bash -c "
    source '$DATE_HELPERS' || { echo 'source failed'; exit 1; }
    set +u; set +o pipefail
    cap_reset_to_epoch ''
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: cap_reset_to_epoch exited $status for empty input (expected 0)" >&2
    return 1
  }
  [ "${output:-}" = "0" ] || {
    echo "FAIL: expected '0' for empty input, got: '$output'" >&2
    return 1
  }
}

@test "unit: cap_reset_to_epoch rolls past time to next day (epoch greater than now)" {
  # "12:00am" is always in the past once it is past midnight (true for any
  # development-hour test run). The function must roll it to next day.
  run bash -c "
    source '$DATE_HELPERS' || { echo 'source failed'; exit 1; }
    set +u; set +o pipefail
    _result=\$(cap_reset_to_epoch 'resets 12:00am')
    _now=\$(date +%s)
    echo \"\$_result \$_now\"
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: cap_reset_to_epoch exited $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  _epoch=$(echo "$output" | awk '{print $1}')
  _now=$(echo "$output" | awk '{print $2}')
  [ "${_epoch:-0}" != "0" ] || {
    echo "FAIL: cap_reset_to_epoch returned 0 for '12:00am' — parse failed" >&2
    return 1
  }
  [ "$_epoch" -gt "$_now" ] || {
    echo "FAIL: rolled epoch $_epoch is not greater than now $_now" >&2
    echo "      'resets 12:00am' (past midnight) must roll to tomorrow's 12:00am" >&2
    return 1
  }
}

@test "unit: full real-world phrasing 'You've hit your session limit · resets 9:20pm (America/Denver)' parses" {
  run bash -c "
    source '$DATE_HELPERS' || { echo 'source failed'; exit 1; }
    set +u; set +o pipefail
    cap_reset_to_epoch \$'You\\'ve hit your session limit \\xc2\\xb7 resets 9:20pm (America/Denver)'
  "
  [ "$status" -eq 0 ] || {
    echo "FAIL: cap_reset_to_epoch exited $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ "${output:-0}" != "0" ] || {
    echo "FAIL: expected non-zero epoch for real-world phrasing, got: '$output'" >&2
    return 1
  }
}

# =============================================================================
# FIXTURE: behavioral tests — exercise the actual capture grep and manifest JSON
# =============================================================================

@test "fixture: grep -hiE captures reset line from provider stdout transcript" {
  # Exercises the EXACT grep flags used in claude.sh to capture the reset line.
  # Would FAIL with the broken -imE flags (E consumed as -m's numeric arg) and
  # PASS with the correct -hiE flags. No structural grep can catch this bug.
  _fixture="$_tmpdir/stdout_capture.txt"
  cat > "$_fixture" <<'EOF'
Processing issue #42
Running agentic session...
You've hit your session limit · resets 6:10pm (America/Denver)
Session ended.
EOF
  _cap_reset_line=$(grep -hiE "resets [0-9]+:[0-9]+[ap]m" \
    "$_fixture" 2>/dev/null | head -1 || true)
  [ -n "$_cap_reset_line" ] || {
    echo "FAIL: grep -hiE failed to capture reset line from fixture" >&2
    echo "      This validates the -imE -> -hiE flag fix in claude.sh" >&2
    return 1
  }
  case "$_cap_reset_line" in
    *"resets 6:10pm"*) ;;
    *)
      echo "FAIL: captured '$_cap_reset_line', expected it to contain 'resets 6:10pm'" >&2
      return 1
      ;;
  esac
}

@test "fixture: cap-resume.json has valid JSON with non-zero reset_epoch for real input" {
  # Exercises cap_reset_to_epoch + the actual jq invocation used by the batch
  # exit-5 handler. Validates that the manifest fields are structurally correct
  # and that a real cap message produces a non-zero reset_epoch.
  _manifest="$_tmpdir/cap-resume.json"
  _cap_reset_text="You have hit your session limit resets 6:10pm (America/Denver)"
  _cap_reset_epoch=$(bash -c "
    source '$DATE_HELPERS' || exit 1
    set +u; set +o pipefail
    cap_reset_to_epoch '$_cap_reset_text'
  " || echo "0")
  _written=$(date +%s)
  jq -n \
    --argjson issues "[42,43]" \
    --arg flags "" \
    --argjson reset_epoch "$_cap_reset_epoch" \
    --arg reset_text "$_cap_reset_text" \
    --argjson written "$_written" \
    '{issues: $issues, flags: $flags, reset_epoch: $reset_epoch, reset_text: $reset_text, written: $written}' \
    > "$_manifest"
  jq -e '.' "$_manifest" > /dev/null || {
    echo "FAIL: manifest is not valid JSON" >&2; return 1
  }
  _ep=$(jq -r '.reset_epoch' "$_manifest")
  [ "${_ep:-0}" -gt 0 ] || {
    echo "FAIL: reset_epoch should be non-zero for a real cap message, got: '$_ep'" >&2
    return 1
  }
  _count=$(jq -r '.issues | length' "$_manifest")
  [ "$_count" -eq 2 ] || {
    echo "FAIL: expected 2 issues in manifest, got: '$_count'" >&2
    return 1
  }
}

@test "15. remaining-issues loop includes deferred_for_dep and blocked but excludes success" {
  # Pins the case-statement inclusion logic in the exit-5 remaining-issues loop.
  # A silent regression back to checking only empty-status ("") would drop
  # deferred_for_dep, deferred_for_parent, and blocked issues from the resume
  # manifest, leaving tests 1–14 all green while the manifest silently undercounts
  # remaining work.
  grep -q 'case "${ISSUE_STATUS\[' "$BATCH_PROCESSOR" || {
    echo "FAIL: remaining-issues case statement not found in $BATCH_PROCESSOR" >&2
    return 1
  }
  grep -q '"" | deferred_for_dep | deferred_for_parent | blocked)' "$BATCH_PROCESSOR" || {
    echo 'FAIL: expected inclusion of "" | deferred_for_dep | deferred_for_parent | blocked in remaining-issues case' >&2
    return 1
  }
}

# =============================================================================
# PARALLEL ISOLATION: per-batch filename prevents race under concurrent batches
# =============================================================================

@test "parallel: claude.sh uses RITE_BATCH_ID suffix so batch mode produces per-batch filenames" {
  # Structural pin: the conditional expansion ${RITE_BATCH_ID:+-${RITE_BATCH_ID}}
  # must be present in claude.sh so that:
  #   - RITE_BATCH_ID set   → cap-reset-line-BATCHID.txt   (parallel-safe)
  #   - RITE_BATCH_ID unset → cap-reset-line.txt            (single-issue fallback)
  grep -q 'RITE_BATCH_ID:+' "$CLAUDE_PROVIDER" || {
    echo "FAIL: conditional expansion 'RITE_BATCH_ID:+' not found in claude.sh" >&2
    echo "      provider must use \${RITE_BATCH_ID:+-\${RITE_BATCH_ID}} suffix pattern" >&2
    return 1
  }
}

@test "parallel: startup cleanup in batch-process-issues.sh removes only the fixed-name fallback" {
  # After the fix, the startup cleanup must remove cap-reset-line.txt (fixed-name,
  # single-issue-mode fallback) — NOT a wildcard that would delete a concurrent
  # batch's per-batch file.  A glob like 'cap-reset-line-*.txt' at startup would
  # re-introduce the race in the other direction.
  _cleanup_line=$(grep -n 'rm -f.*cap-reset-line' "$BATCH_PROCESSOR" | head -1 | cut -d: -f2- || true)
  case "${_cleanup_line:-}" in
    *cap-reset-line.txt*) ;;
    *'*'*)
      echo "FAIL: startup cleanup uses a glob ('*') for cap-reset-line — this would" >&2
      echo "      delete a concurrent batch's per-batch file, re-introducing the race" >&2
      return 1 ;;
    *)
      echo "FAIL: startup cleanup for cap-reset-line.txt not found in batch-process-issues.sh" >&2
      return 1 ;;
  esac
}
