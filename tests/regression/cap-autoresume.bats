#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/cap-resume.sh, lib/core/batch-process-issues.sh
# tests/regression/cap-autoresume.bats
#
# Regression test: opt-in auto-resume of a batch after a usage-cap reset.
#
# Issue #1143 — "Opt-in auto-resume of batch after cap reset"
#
# Tests in this file:
#
#   STRUCTURAL (static code inspection):
#     1.  RITE_CAP_AUTORESUME documented in config/rite.conf.example
#     2.  RITE_CAP_AUTORESUME mentioned in CLAUDE.md
#     3.  batch-process-issues.sh sets _CAP_ABORT=true near the cap break
#     4.  batch-process-issues.sh calls attempt_cap_autoresume
#     5.  batch-process-issues.sh sources cap-resume.sh
#     6.  batch-process-issues.sh propagates _RITE_CAP_RESUMED=1 → manifest resumed=true
#
#   UNIT (attempt_cap_autoresume in cap-resume.sh):
#     7.  Flag off (RITE_CAP_AUTORESUME unset/false) → returns 1, no exec
#     8.  Flag on, future epoch, AC power → caffeinate invoked and exec-wraps rite
#     9.  Flag on, future epoch, battery power → caffeinate NOT invoked, rite still exec'd
#    10.  Flag on, manifest resumed=true → returns 1, no exec (one-resume guard)
#    11.  Flag on, reset_epoch=0 (past/unknown) → returns 1, no exec

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
CAP_RESUME="$REPO_ROOT/lib/utils/cap-resume.sh"
CONF_EXAMPLE="$REPO_ROOT/config/rite.conf.example"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

setup() {
  for _f in "$BATCH_PROCESSOR" "$CAP_RESUME" "$CONF_EXAMPLE" "$CLAUDE_MD"; do
    [ -f "$_f" ] || {
      echo "FATAL: $_f not found" >&2
      return 1
    }
  done
  _tmpdir=$(mktemp -d)
  # Capture jq's real directory so PATH-restricted bash -c subshells can still
  # find it; Homebrew macOS installs jq in /opt/homebrew/bin or /usr/local/bin,
  # not /usr/bin, so a hard-coded /usr/bin:/bin PATH causes jq calls to fail or
  # silently fall back to the || echo "0" defaults, breaking epoch comparisons.
  _jq_dir=$(dirname "$(command -v jq 2>/dev/null || echo "/usr/bin/jq")")
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# =============================================================================
# STRUCTURAL
# =============================================================================

@test "structural: RITE_CAP_AUTORESUME documented in config/rite.conf.example" {
  grep -q 'RITE_CAP_AUTORESUME' "$CONF_EXAMPLE" || {
    echo "FAIL: 'RITE_CAP_AUTORESUME' not found in config/rite.conf.example" >&2
    echo "      Rule 36 requires new RITE_* vars to be documented in a config example" >&2
    return 1
  }
}

@test "structural: RITE_CAP_AUTORESUME mentioned in CLAUDE.md" {
  grep -q 'RITE_CAP_AUTORESUME' "$CLAUDE_MD" || {
    echo "FAIL: 'RITE_CAP_AUTORESUME' not found in CLAUDE.md" >&2
    echo "      Documentation impact requires a mention in CLAUDE.md session-limits" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh sets _CAP_ABORT=true near cap break" {
  grep -q '_CAP_ABORT=true' "$BATCH_PROCESSOR" || {
    echo "FAIL: '_CAP_ABORT=true' not found in batch-process-issues.sh" >&2
    echo "      exit-5 handler must set _CAP_ABORT=true before break" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh calls attempt_cap_autoresume" {
  grep -q 'attempt_cap_autoresume' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'attempt_cap_autoresume' not found in batch-process-issues.sh" >&2
    echo "      batch must call attempt_cap_autoresume after the issue loop" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh sources cap-resume.sh" {
  grep -q 'cap-resume.sh' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'cap-resume.sh' not found in batch-process-issues.sh sources" >&2
    return 1
  }
}

@test "structural: attempt_cap_autoresume call site passes \$_manifest_path not fixed cap-resume.json" {
  # The manifest writer uses a per-batch filename (cap-resume-${RITE_BATCH_ID}.json).
  # The call site must pass $_manifest_path, not re-derive the old fixed name —
  # otherwise the [ -f ] check inside attempt_cap_autoresume always fails and the
  # feature never fires.
  grep -n 'attempt_cap_autoresume' "$BATCH_PROCESSOR" | grep -q 'cap-resume\.json' && {
    echo "FAIL: attempt_cap_autoresume call site still uses literal 'cap-resume.json'" >&2
    echo "      Pass \$_manifest_path (set by the cap-abort writer) instead" >&2
    return 1
  }
  grep -q 'attempt_cap_autoresume.*_manifest_path' "$BATCH_PROCESSOR" || {
    echo "FAIL: attempt_cap_autoresume call site does not pass \$_manifest_path" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh propagates _RITE_CAP_RESUMED=1 → manifest resumed=true" {
  # cap-resume.sh exports _RITE_CAP_RESUMED=1 before exec; the manifest writer in
  # batch-process-issues.sh must read it and write resumed=true in the next run's
  # manifest so a second cap in the resumed batch cannot trigger another auto-resume.
  grep -q '_RITE_CAP_RESUMED' "$BATCH_PROCESSOR" || {
    echo "FAIL: _RITE_CAP_RESUMED reference not found in batch-process-issues.sh" >&2
    echo "      cap-resume.sh exports _RITE_CAP_RESUMED=1 before exec; batch must honour it" >&2
    return 1
  }
  grep -q '_resumed_val="true"' "$BATCH_PROCESSOR" || {
    echo "FAIL: _resumed_val=\"true\" assignment not found in batch-process-issues.sh" >&2
    echo "      The manifest writer must set resumed=true when _RITE_CAP_RESUMED=1" >&2
    return 1
  }
  grep -qE '\-\-argjson resumed|resumed.*_resumed_val' "$BATCH_PROCESSOR" || {
    echo "FAIL: manifest jq call does not pass the resumed value to the JSON output" >&2
    return 1
  }
}

# =============================================================================
# UNIT: attempt_cap_autoresume
# Helper: write a minimal manifest file
# =============================================================================

_write_manifest() {
  local path="$1" issues="$2" flags="${3:-}" reset_epoch="${4:-0}" resumed="${5:-false}"
  local issues_json=""
  for _i in $issues; do
    [ -n "$issues_json" ] && issues_json="${issues_json},"
    issues_json="${issues_json}${_i}"
  done
  cat > "$path" <<EOF
{
  "issues": [${issues_json}],
  "flags": "${flags}",
  "reset_epoch": ${reset_epoch},
  "reset_text": "resets 11:59pm",
  "written": $(date +%s),
  "resumed": ${resumed}
}
EOF
}

@test "unit: flag off (RITE_CAP_AUTORESUME unset) → attempt_cap_autoresume returns 1, no exec" {
  _manifest="$_tmpdir/cap-resume.json"
  _future=$(( $(date +%s) + 3600 ))
  _write_manifest "$_manifest" "42 43" "" "$_future" "false"

  # Stub rite: if exec'd it would write a marker; if the function correctly returns 1
  # the marker must NOT exist.
  cat > "$_tmpdir/rite" <<'STUB'
#!/bin/bash
touch "$MARKER_FILE"
exit 0
STUB
  chmod +x "$_tmpdir/rite"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:/usr/bin:/bin'
    export MARKER_FILE='$_tmpdir/exec-marker'
    # RITE_CAP_AUTORESUME intentionally unset
    source '$CAP_RESUME'
    set +u; set +o pipefail
    attempt_cap_autoresume '$_manifest'
    exit 0
  "

  # Function returns 1 (non-zero), so the bash -c exits non-zero too
  [ "$status" -ne 0 ] || {
    echo "FAIL: expected non-zero exit (function should return 1), got: $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ ! -f "$_tmpdir/exec-marker" ] || {
    echo "FAIL: rite stub was exec'd even though RITE_CAP_AUTORESUME was unset" >&2
    return 1
  }
}

@test "unit: flag on, future epoch, AC power → caffeinate invoked, rite exec'd with issues" {
  _manifest="$_tmpdir/cap-resume.json"
  # reset_epoch = 1 second from now so the wait loop exits immediately
  _future=$(( $(date +%s) + 1 ))
  _write_manifest "$_manifest" "42 43" "" "$_future" "false"

  # Stub rite: records its args and exits 0
  cat > "$_tmpdir/rite" <<'STUB'
#!/bin/bash
echo "rite-invoked: $*" > "$MARKER_FILE"
exit 0
STUB
  chmod +x "$_tmpdir/rite"

  # Stub caffeinate: records invocation; when given a non-flag positional arg
  # (i.e. exec caffeinate -i <rite> <issues>) proxies to it so rite runs.
  cat > "$_tmpdir/caffeinate" <<'STUB'
#!/bin/bash
echo "caffeinate: $*" >> "$CAFFEINATE_LOG"
# Collect positional (non-flag) args to exec the wrapped command, if any.
_pos_args=()
for _a in "$@"; do
  case "$_a" in
    -*) continue ;;
    *) _pos_args+=("$_a") ;;
  esac
done
[ "${#_pos_args[@]}" -gt 0 ] && exec "${_pos_args[@]}"
exit 0
STUB
  chmod +x "$_tmpdir/caffeinate"

  # Stub pmset: reports AC Power
  cat > "$_tmpdir/pmset" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "-g" ] && [ "${2:-}" = "ps" ]; then
  echo "Now drawing from 'AC Power'"
fi
STUB
  chmod +x "$_tmpdir/pmset"

  # Stub sleep: no-op so the wait loop exits instantly
  cat > "$_tmpdir/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$_tmpdir/sleep"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:$_jq_dir:/usr/bin:/bin'
    export RITE_CAP_AUTORESUME=true
    export MARKER_FILE='$_tmpdir/exec-marker'
    export CAFFEINATE_LOG='$_tmpdir/caffeinate.log'
    source '$CAP_RESUME'
    set +u; set +o pipefail
    attempt_cap_autoresume '$_manifest'
  "

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (rite stub exits 0 after exec), got: $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ -f "$_tmpdir/exec-marker" ] || {
    echo "FAIL: rite stub marker not found — exec was not called" >&2
    echo "      output: $output" >&2
    return 1
  }
  grep -q "42" "$_tmpdir/exec-marker" || {
    echo "FAIL: rite was not invoked with issue 42" >&2
    echo "      marker: $(cat "$_tmpdir/exec-marker")" >&2
    return 1
  }
  [ -f "$_tmpdir/caffeinate.log" ] || {
    echo "FAIL: caffeinate was not invoked on AC power" >&2
    echo "      output: $output" >&2
    return 1
  }
  # Assert rite was passed as the exec target to caffeinate (not just that caffeinate
  # ran as a background hold).  cap-resume.sh line: exec caffeinate -i "$_rite_bin" ...
  grep -q "rite" "$_tmpdir/caffeinate.log" || {
    echo "FAIL: caffeinate log does not show rite as exec target — exec was not caffeinate-wrapped" >&2
    echo "      caffeinate log: $(cat "$_tmpdir/caffeinate.log")" >&2
    return 1
  }
}

@test "unit: flag on, future epoch, battery power → caffeinate NOT invoked, rite still exec'd" {
  _manifest="$_tmpdir/cap-resume.json"
  _future=$(( $(date +%s) + 1 ))
  _write_manifest "$_manifest" "55" "" "$_future" "false"

  cat > "$_tmpdir/rite" <<'STUB'
#!/bin/bash
echo "rite-invoked: $*" > "$MARKER_FILE"
exit 0
STUB
  chmod +x "$_tmpdir/rite"

  # Stub caffeinate: records if called (should NOT be called on battery)
  cat > "$_tmpdir/caffeinate" <<'STUB'
#!/bin/bash
echo "caffeinate: $*" >> "$CAFFEINATE_LOG"
exit 0
STUB
  chmod +x "$_tmpdir/caffeinate"

  # Stub pmset: reports Battery Power
  cat > "$_tmpdir/pmset" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "-g" ] && [ "${2:-}" = "ps" ]; then
  echo "Now drawing from 'Battery Power'"
fi
STUB
  chmod +x "$_tmpdir/pmset"

  cat > "$_tmpdir/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$_tmpdir/sleep"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:$_jq_dir:/usr/bin:/bin'
    export RITE_CAP_AUTORESUME=true
    export MARKER_FILE='$_tmpdir/exec-marker'
    export CAFFEINATE_LOG='$_tmpdir/caffeinate.log'
    source '$CAP_RESUME'
    set +u; set +o pipefail
    attempt_cap_autoresume '$_manifest'
  "

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (rite stub), got: $status" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ -f "$_tmpdir/exec-marker" ] || {
    echo "FAIL: rite stub marker not found — exec was not called on battery path" >&2
    return 1
  }
  [ ! -f "$_tmpdir/caffeinate.log" ] || {
    echo "FAIL: caffeinate was invoked on battery power — should be skipped" >&2
    echo "      caffeinate log: $(cat "$_tmpdir/caffeinate.log")" >&2
    return 1
  }
}

@test "unit: resumed=true in manifest → returns 1, no exec (one-resume guard)" {
  _manifest="$_tmpdir/cap-resume.json"
  _future=$(( $(date +%s) + 3600 ))
  # manifest already marked resumed
  _write_manifest "$_manifest" "42" "" "$_future" "true"

  cat > "$_tmpdir/rite" <<'STUB'
#!/bin/bash
touch "$MARKER_FILE"
exit 0
STUB
  chmod +x "$_tmpdir/rite"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:$_jq_dir:/usr/bin:/bin'
    export RITE_CAP_AUTORESUME=true
    export MARKER_FILE='$_tmpdir/exec-marker'
    source '$CAP_RESUME'
    set +u; set +o pipefail
    attempt_cap_autoresume '$_manifest'
    exit 0
  "

  [ "$status" -ne 0 ] || {
    echo "FAIL: expected non-zero exit (function should return 1 — already resumed), got: $status" >&2
    return 1
  }
  [ ! -f "$_tmpdir/exec-marker" ] || {
    echo "FAIL: rite stub was exec'd even though manifest was already resumed" >&2
    return 1
  }
}

@test "unit: reset_epoch=0 (unknown/past) → returns 1, no exec" {
  _manifest="$_tmpdir/cap-resume.json"
  _write_manifest "$_manifest" "42" "" "0" "false"

  cat > "$_tmpdir/rite" <<'STUB'
#!/bin/bash
touch "$MARKER_FILE"
exit 0
STUB
  chmod +x "$_tmpdir/rite"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:$_jq_dir:/usr/bin:/bin'
    export RITE_CAP_AUTORESUME=true
    export MARKER_FILE='$_tmpdir/exec-marker'
    source '$CAP_RESUME'
    set +u; set +o pipefail
    attempt_cap_autoresume '$_manifest'
    exit 0
  "

  [ "$status" -ne 0 ] || {
    echo "FAIL: expected non-zero exit (epoch 0 is in the past), got: $status" >&2
    return 1
  }
  [ ! -f "$_tmpdir/exec-marker" ] || {
    echo "FAIL: rite stub was exec'd even though reset_epoch=0" >&2
    return 1
  }
}
