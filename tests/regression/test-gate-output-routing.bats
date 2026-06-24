#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# Regression test: gate raw output routing + compact terminal digest.
#
# The gate's raw bats/lint output is voluminous and interleaves badly with
# other phases (the backgrounded review-loop gate streams concurrent with
# review generation; a single failing test can replay a whole nested rite
# transcript). The gate routes that raw stream to the run log only
# (RITE_LOG_FILE) and prints a compact digest to the terminal instead.
#
# Verifies:
#   1. With RITE_LOG_FILE set: raw bats output lands in the LOG, not on stdout.
#   2. The terminal (stdout) gets the compact "[test-gate] bats:" digest and
#      names the blocking failure.
#   3. With RITE_LOG_FILE unset: falls back to stdout (output never lost).

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export PR_NUMBER="777"
  _diag() { true; }
  export -f _diag 2>/dev/null || true
}

# Build a minimal Sharkrite-style project root (passing shellcheck/lint targets).
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

@test "gate routes raw bats output to the log (not stdout) and prints a digest" {
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
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH=\"${_stub_dir}:\$PATH\" run_test_gate '${_gate_out}' '${_proj}'
  " || true

  # The noisy raw pretty stream must NOT appear on the terminal (stdout)...
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

@test "gate falls back to stdout when RITE_LOG_FILE is unset (output never lost)" {
  _stub_dir="${BATS_TEST_TMPDIR}/routing_stub_nolog"
  _make_failing_bats_stub "$_stub_dir"
  _proj=$(_make_stub_project)
  _gate_out="${BATS_TEST_TMPDIR}/gate_out_nolog.json"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export PR_NUMBER='777'
    export RITE_TEST_GATE_DIFF_BASE='HEAD'
    unset RITE_LOG_FILE
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
