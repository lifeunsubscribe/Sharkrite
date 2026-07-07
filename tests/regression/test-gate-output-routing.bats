#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, lib/core/workflow-runner.sh
# Regression test: gate raw output routing for summary mode and verbose mode.
#
# Summary mode (default, RITE_GATE_VERBOSE unset):
#   Raw runner output → RITE_LOG_FILE via direct-append (two-channel convention).
#   Console sees only the compact digest + named failures.
#   Works for both BACKGROUND and FOREGROUND invocations.
#
# Verbose mode (RITE_GATE_VERBOSE=true or RITE_VERBOSE=true):
#   BACKGROUND gate (RITE_GATE_BACKGROUND=1): raw → log (avoid interleave).
#   FOREGROUND gate: raw → stdout (live progress, no phantom hang).
#
# Verifies:
#   1. SUMMARY mode + RITE_LOG_FILE set → raw in LOG, compact digest on stdout.
#   2. SUMMARY mode + RITE_LOG_FILE unset → raw silently to /dev/null; digest still on stdout.
#   3. SUMMARY mode + FOREGROUND → raw goes to log (not stdout), digest on stdout.
#   4. VERBOSE mode + FOREGROUND → raw streams LIVE to stdout (legacy hang-fix preserved).
#   5. Structural: the two concurrent review-loop gates set RITE_GATE_BACKGROUND=1.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export PR_NUMBER="777"
  _diag() { true; }
  export -f _diag 2>/dev/null || true
}

_make_stub_project() {
  local dir
  dir=$(mktemp -d "${BATS_TEST_TMPDIR}/routing_proj_XXXXXX")
  mkdir -p "$dir/tests"
  cat > "$dir/Makefile" <<'MAKEFILE'
shellcheck:
	@true
lint:
	@true
MAKEFILE
  # A dummy .bats file ensures _total_bats > 0 so the gate does not short-circuit
  # with "no bats suite" before invoking the stub bats binary.
  printf '#!/usr/bin/env bats\n@test "stub" { true; }\n' > "$dir/tests/stub.bats"
  echo "$dir"
}

# Fake bats: supports --report-formatter (detection passes), prints a unique
# RAW_PRETTY_MARKER to stdout (the noisy stream), writes a failing TAP report,
# and exits 1.
_make_failing_bats_stub() {
  local stub_dir="$1"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<'STUBEOF'
#!/bin/bash
# Detection string so _bats_has_report_formatter() passes: --report-formatter
_out_dir=""
_prev=""
for _a in "$@"; do
  if [ "$_prev" = "--output" ]; then _out_dir="$_a"; fi
  _prev="$_a"
done
echo "RAW_PRETTY_MARKER this is the noisy failing-test transcript"
if [ -n "$_out_dir" ]; then
  mkdir -p "$_out_dir"
  printf 'TAP version 13\n1..2\nok 1 passing-one\nnot ok 2 blocking-failure-xyz\n' \
    > "$_out_dir/report.tap"
fi
exit 1
STUBEOF
  chmod +x "$stub_dir/bats"
}

@test "SUMMARY mode: raw bats output goes to log (not stdout) and digest appears on stdout" {
  # Default (no RITE_GATE_VERBOSE): raw output suppressed from console regardless
  # of whether the gate is BACKGROUND or FOREGROUND.
  _stub_dir="${BATS_TEST_TMPDIR}/routing_stub"
  _make_failing_bats_stub "$_stub_dir"
  _proj=$(_make_stub_project)
  _gate_out="${BATS_TEST_TMPDIR}/gate_out.json"
  _log="${BATS_TEST_TMPDIR}/run.log"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export PR_NUMBER='777'
    export RITE_TEST_GATE_DIFF_BASE='HEAD'
    export RITE_LOG_FILE='${_log}'
    export RITE_GATE_BACKGROUND=1
    unset RITE_GATE_VERBOSE
    unset RITE_VERBOSE
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH=\"${_stub_dir}:\$PATH\" run_test_gate '${_gate_out}' '${_proj}'
  " || true

  # Summary mode: the noisy raw pretty stream must NOT appear on the terminal...
  ! echo "$output" | grep -q 'RAW_PRETTY_MARKER' \
    || { echo "FAIL: raw bats output leaked onto stdout in summary mode"; echo "$output"; return 1; }
  # ...it must be captured in the run log instead.
  [ -f "$_log" ] || { echo "FAIL: run log not written"; return 1; }
  grep -q 'RAW_PRETTY_MARKER' "$_log" \
    || { echo "FAIL: raw bats output not routed to the run log"; cat "$_log"; return 1; }

  # The terminal gets the compact digest naming the blocking failure.
  echo "$output" | grep -q '\[test-gate\] bats:' \
    || { echo "FAIL: bats digest missing from stdout"; echo "$output"; return 1; }
  echo "$output" | grep -q 'blocking-failure-xyz' \
    || { echo "FAIL: blocking failure not named in digest"; echo "$output"; return 1; }
}

@test "SUMMARY mode + no RITE_LOG_FILE: raw silently to /dev/null; digest still on stdout" {
  # Without a log file configured, raw output goes to /dev/null in summary mode.
  # The compact digest (including named failures) is still visible on stdout so
  # the user knows what failed — the gate never drops failure names.
  _stub_dir="${BATS_TEST_TMPDIR}/routing_stub_nolog"
  _make_failing_bats_stub "$_stub_dir"
  _proj=$(_make_stub_project)
  _gate_out="${BATS_TEST_TMPDIR}/gate_out_nolog.json"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export PR_NUMBER='777'
    export RITE_TEST_GATE_DIFF_BASE='HEAD'
    unset RITE_LOG_FILE
    export RITE_GATE_BACKGROUND=1
    unset RITE_GATE_VERBOSE
    unset RITE_VERBOSE
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH=\"${_stub_dir}:\$PATH\" run_test_gate '${_gate_out}' '${_proj}'
  " || true

  # No log configured: raw output goes to /dev/null (not stdout).
  ! echo "$output" | grep -q 'RAW_PRETTY_MARKER' \
    || { echo "FAIL: raw output leaked to stdout (should be /dev/null in summary mode)"; echo "$output"; return 1; }
  # But the digest (named failures) still surfaces on stdout.
  echo "$output" | grep -q 'blocking-failure-xyz' \
    || { echo "FAIL: blocking failure name missing from stdout when no log configured"; echo "$output"; return 1; }
}

@test "SUMMARY mode + FOREGROUND: raw goes to log (not stdout), digest on stdout" {
  # Summary mode applies to FOREGROUND gates too — the issue was console noise
  # from repeated npm error trailers. Foreground no longer streams raw to stdout
  # by default; it goes to the log like the background path.
  _stub_dir="${BATS_TEST_TMPDIR}/routing_stub_fg_summary"
  _make_failing_bats_stub "$_stub_dir"
  _proj=$(_make_stub_project)
  _gate_out="${BATS_TEST_TMPDIR}/gate_out_fg_summary.json"
  _log="${BATS_TEST_TMPDIR}/run_fg_summary.log"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export PR_NUMBER='777'
    export RITE_TEST_GATE_DIFF_BASE='HEAD'
    export RITE_LOG_FILE='${_log}'
    unset RITE_GATE_BACKGROUND
    unset RITE_GATE_VERBOSE
    unset RITE_VERBOSE
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH=\"${_stub_dir}:\$PATH\" run_test_gate '${_gate_out}' '${_proj}'
  " || true

  # Summary mode (foreground): raw must NOT stream to stdout.
  ! echo "$output" | grep -q 'RAW_PRETTY_MARKER' \
    || { echo "FAIL: raw bats output leaked to stdout in foreground summary mode"; echo "$output"; return 1; }
  # Raw must be in the log.
  [ -f "$_log" ] || { echo "FAIL: run log not written for foreground gate"; return 1; }
  grep -q 'RAW_PRETTY_MARKER' "$_log" \
    || { echo "FAIL: raw bats output not in run log for foreground gate"; cat "$_log"; return 1; }
  # Digest still appears on stdout.
  echo "$output" | grep -q 'blocking-failure-xyz' \
    || { echo "FAIL: blocking failure not named in digest"; echo "$output"; return 1; }
}

@test "VERBOSE mode + FOREGROUND: raw streams LIVE to stdout (hang-fix preserved)" {
  # With RITE_GATE_VERBOSE=true a foreground gate restores live streaming so
  # developers can watch progress without tailing the log file.
  _stub_dir="${BATS_TEST_TMPDIR}/routing_stub_fg_verbose"
  _make_failing_bats_stub "$_stub_dir"
  _proj=$(_make_stub_project)
  _gate_out="${BATS_TEST_TMPDIR}/gate_out_fg_verbose.json"
  _log="${BATS_TEST_TMPDIR}/run_fg_verbose.log"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export PR_NUMBER='777'
    export RITE_TEST_GATE_DIFF_BASE='HEAD'
    export RITE_LOG_FILE='${_log}'
    unset RITE_GATE_BACKGROUND
    export RITE_GATE_VERBOSE=true
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH=\"${_stub_dir}:\$PATH\" run_test_gate '${_gate_out}' '${_proj}'
  " || true

  # Verbose + foreground: raw stream IS visible live on the terminal.
  echo "$output" | grep -q 'RAW_PRETTY_MARKER' \
    || { echo "FAIL: verbose foreground gate hid raw output from stdout"; echo "$output"; return 1; }
}

@test "structural: the two concurrent review-loop gates set RITE_GATE_BACKGROUND=1" {
  # Only the backgrounded (concurrent) gate launches may suppress the live stream.
  # Both `run_test_gate ... &` calls in workflow-runner.sh must carry the flag;
  # foreground callers (post-merge-verify, fastpath) must not.
  local _wr="${RITE_LIB_DIR}/core/workflow-runner.sh"
  local _flagged _backgrounded
  _flagged=$(grep -cE 'RITE_GATE_BACKGROUND=1 .*run_test_gate .*&' "$_wr" || true)
  _backgrounded=$(grep -cE 'run_test_gate "\$_(gate_output|init_gate)_file" "\$WORKTREE_PATH" &' "$_wr" || true)
  [ "$_backgrounded" -eq 2 ]   # the two known backgrounded launches
  [ "$_flagged" -eq 2 ]        # both carry RITE_GATE_BACKGROUND=1
}
