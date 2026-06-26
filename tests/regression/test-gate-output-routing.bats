#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, lib/core/workflow-runner.sh
# Regression test: gate raw output routing is CONDITIONAL on concurrency.
#
#   - BACKGROUND gate (RITE_GATE_BACKGROUND=1) runs concurrent with review
#     generation, so its voluminous raw bats/lint output is routed to the run log
#     only (RITE_LOG_FILE) and the terminal gets a compact digest — no interleave.
#   - FOREGROUND gate (default: post-merge-verify, fastpath, standalone) has no
#     concurrent output to protect, so routing to the log would make a multi-minute
#     run look like a HANG. It streams live to the terminal instead (the FIFO-tee
#     still logs it). Live progress beats a phantom hang.
#
# Verifies:
#   1. BACKGROUND + RITE_LOG_FILE set → raw lands in the LOG, not stdout; digest
#      + blocking-failure name on stdout.
#   2. BACKGROUND + RITE_LOG_FILE unset → falls back to stdout (never lost).
#   3. FOREGROUND (no flag) + RITE_LOG_FILE set → raw streams LIVE to stdout (the
#      fix for the "looks like a hang" complaint).

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

@test "BACKGROUND gate routes raw bats output to the log (not stdout) and prints a digest" {
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
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH=\"${_stub_dir}:\$PATH\" run_test_gate '${_gate_out}' '${_proj}'
  " || true

  # Background: the noisy raw pretty stream must NOT appear on the terminal...
  ! echo "$output" | grep -q 'RAW_PRETTY_MARKER' \
    || { echo "FAIL: raw bats output leaked onto stdout"; echo "$output"; return 1; }
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

@test "BACKGROUND gate falls back to stdout when RITE_LOG_FILE is unset (output never lost)" {
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
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH=\"${_stub_dir}:\$PATH\" run_test_gate '${_gate_out}' '${_proj}'
  " || true

  # With no log configured, raw output falls back to stdout so nothing is lost.
  echo "$output" | grep -q 'RAW_PRETTY_MARKER' \
    || { echo "FAIL: raw output lost when RITE_LOG_FILE unset"; echo "$output"; return 1; }
}

@test "FOREGROUND gate streams raw output LIVE to stdout even with RITE_LOG_FILE set (no phantom hang)" {
  # The fix: a foreground gate (no RITE_GATE_BACKGROUND) must show live progress
  # on the terminal — routing it to the log made a long bats run look frozen.
  _stub_dir="${BATS_TEST_TMPDIR}/routing_stub_fg"
  _make_failing_bats_stub "$_stub_dir"
  _proj=$(_make_stub_project)
  _gate_out="${BATS_TEST_TMPDIR}/gate_out_fg.json"
  _log="${BATS_TEST_TMPDIR}/run_fg.log"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export PR_NUMBER='777'
    export RITE_TEST_GATE_DIFF_BASE='HEAD'
    export RITE_LOG_FILE='${_log}'
    unset RITE_GATE_BACKGROUND
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH=\"${_stub_dir}:\$PATH\" run_test_gate '${_gate_out}' '${_proj}'
  " || true

  # Foreground: raw stream IS visible live on the terminal (the anti-hang fix),
  # even though a log is configured.
  echo "$output" | grep -q 'RAW_PRETTY_MARKER' \
    || { echo "FAIL: foreground gate hid raw output from stdout (the hang feeling)"; echo "$output"; return 1; }
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
