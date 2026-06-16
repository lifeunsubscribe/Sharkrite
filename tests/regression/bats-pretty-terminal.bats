#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, Makefile
# Regression test: bats --pretty for terminal output (issue #484, #542)
#
# Verifies:
#   1. _bats_has_report_formatter() detects --report-formatter in the bats binary
#   2. The gate invokes bats with -F pretty + --report-formatter tap when supported
#      (behavioral: stub bats logs argv; test asserts on logged args)
#   3. The gate reads report.tap (not pretty stdout) for JSON failure parsing
#      (behavioral: stub emits pretty ✗ to stdout AND not-ok to report.tap; assert 1 JSON entry)
#   4. JSON builder output is byte-identical: same keys, same structure
#   5. Fallback to tee-captured TAP when --report-formatter is unavailable
#      (behavioral: stub without detection string; assert JSON gets failure entry via tee path)
#   6. Makefile test target: pretty detection + recursive -r tests/ invocation
#      (behavioral: stub bats logs argv; make test exercised directly)

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export TEST_WORKSPACE
  TEST_WORKSPACE=$(mktemp -d)
  export PR_NUMBER="999"
  # Mock _diag — logging side effects not needed
  _diag() { true; }
  export -f _diag 2>/dev/null || true
}

teardown() {
  rm -rf "${TEST_WORKSPACE:-}"
}

# ---------------------------------------------------------------------------
# _bats_has_report_formatter detection
# ---------------------------------------------------------------------------

@test "_bats_has_report_formatter: returns 0 when bats binary contains --report-formatter" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    # Create a fake bats binary that contains the --report-formatter string
    _fake_bats=\$(mktemp)
    printf '#!/bin/bash\necho --report-formatter\n' > \"\$_fake_bats\"
    chmod +x \"\$_fake_bats\"
    PATH=\"\$(dirname \"\$_fake_bats\"):\$PATH\" _bats_has_report_formatter
    _ret=\$?
    rm -f \"\$_fake_bats\"
    exit \$_ret
  "
  [ "$status" -eq 0 ]
}

@test "_bats_has_report_formatter: returns 1 when bats binary lacks --report-formatter" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    # Create a fake bats binary WITHOUT --report-formatter
    _fake_bats=\$(mktemp)
    printf '#!/bin/bash\necho -t --tap\n' > \"\$_fake_bats\"
    chmod +x \"\$_fake_bats\"
    PATH=\"\$(dirname \"\$_fake_bats\"):\$PATH\" _bats_has_report_formatter
    _ret=\$?
    rm -f \"\$_fake_bats\"
    # Must be non-zero (not found)
    [ \"\$_ret\" -ne 0 ]
  "
  [ "$status" -eq 0 ]
}

@test "_bats_has_report_formatter: returns 1 when bats is not on PATH" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    # Run in an empty PATH so bats cannot be found
    PATH=/nonexistent _bats_has_report_formatter
    _ret=\$?
    [ \"\$_ret\" -ne 0 ]
  "
  [ "$status" -eq 0 ]
}

@test "_bats_has_report_formatter: installed bats (1.5+) is detected correctly" {
  # This verifies the real installed bats is handled — no mocking.
  # If bats is not installed the test is skipped gracefully.
  if ! command -v bats >/dev/null 2>&1; then
    skip "bats not installed"
  fi
  # Determine expected outcome based on installed bats version.
  # --report-formatter was introduced in bats-core 1.5.0; any version >= 1.5
  # must return has_report_formatter, older versions return no_report_formatter.
  _bats_version=$(bats --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")
  _bats_major=${_bats_version%%.*}
  _bats_minor=${_bats_version##*.}
  if [ "${_bats_major:-0}" -gt 1 ] || \
     { [ "${_bats_major:-0}" -eq 1 ] && [ "${_bats_minor:-0}" -ge 5 ]; }; then
    _expected="has_report_formatter"
  else
    _expected="no_report_formatter"
  fi
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    if _bats_has_report_formatter; then
      echo 'has_report_formatter'
    else
      echo 'no_report_formatter'
    fi
  "
  [ "$status" -eq 0 ]
  # Assert the specific expected outcome — both outcomes accepted masks the detection bug.
  [ "$output" = "$_expected" ]
}

# ---------------------------------------------------------------------------
# Gate uses -F pretty + --report-formatter tap when supported (behavioral)
# ---------------------------------------------------------------------------
# These tests verify the actual pretty→report.tap→parser pipeline, not
# source-string presence.  A stub project + fake bats binary drives the gate
# through the full run_test_gate() code path and asserts on the JSON output.
# ---------------------------------------------------------------------------

# _make_stub_project — helper to build a minimal Sharkrite-style project root
# in BATS_TEST_TMPDIR with passing shellcheck/lint targets and a tests/ dir.
# Prints the project root path.
#
# git diff is called inside run_test_gate with RITE_TEST_GATE_DIFF_BASE='HEAD'
# to compute the changed-file set.  When no git repo exists the command returns
# non-zero but the `|| true` in test-gate.sh makes _changed_files="" — which
# triggers FORCE_FULL bats selection.  That is fine for our pipeline tests:
# the fake bats binary handles any invocation regardless of which files are
# selected.
_make_stub_project() {
  local dir
  dir=$(mktemp -d "${BATS_TEST_TMPDIR}/stub_project_XXXXXX")
  mkdir -p "$dir/tests"
  # Sharkrite detection requires both `shellcheck:` and `lint:` targets.
  # Targets output nothing and exit 0 so the gate treats lint as clean.
  cat > "$dir/Makefile" <<'MAKEFILE'
shellcheck:
	@true
lint:
	@true
MAKEFILE
  echo "$dir"
}

@test "gate invokes bats with -F pretty + --report-formatter tap when supported (behavioral)" {
  # Build a fake bats binary that CONTAINS '--report-formatter' (so detection
  # passes) and logs its argv to a file when invoked, then exits 0.
  _stub_dir="${BATS_TEST_TMPDIR}/bats_pretty_stub"
  mkdir -p "$_stub_dir"
  _args_log="${BATS_TEST_TMPDIR}/bats_args.log"
  cat > "$_stub_dir/bats" <<STUB
#!/bin/bash
# Contains the detection string so _bats_has_report_formatter() returns 0:
# --report-formatter
printf '%s\n' "\$@" >> "${_args_log}"
# Write a minimal TAP report.tap when --output DIR is given
_out_dir=""
_prev=""
for _a in "\$@"; do
  if [ "\$_prev" = "--output" ]; then _out_dir="\$_a"; fi
  _prev="\$_a"
done
if [ -n "\$_out_dir" ]; then
  mkdir -p "\$_out_dir"
  printf 'TAP version 13\n1..1\nok 1 stub passing test\n' > "\$_out_dir/report.tap"
fi
exit 0
STUB
  chmod +x "$_stub_dir/bats"

  _proj=$(_make_stub_project)
  _gate_out="${BATS_TEST_TMPDIR}/gate_out.json"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export PR_NUMBER='888'
    export RITE_TEST_GATE_DIFF_BASE='HEAD'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH='${_stub_dir}:\$PATH' run_test_gate '${_gate_out}' '${_proj}'
  "
  # Gate must exit 0 (all pass) and produce valid JSON
  [ "$status" -eq 0 ]
  [ -f "$_gate_out" ]

  # Verify the fake bats was called with -F pretty
  [ -f "$_args_log" ]
  grep -q '\-F' "$_args_log" \
    || { echo "FAIL: -F pretty not found in bats args"; cat "$_args_log"; return 1; }
  grep -q 'pretty' "$_args_log" \
    || { echo "FAIL: pretty not found in bats args"; cat "$_args_log"; return 1; }
  # Verify --report-formatter tap was passed
  grep -q -- '--report-formatter' "$_args_log" \
    || { echo "FAIL: --report-formatter not in bats args"; cat "$_args_log"; return 1; }
  grep -q 'tap' "$_args_log" \
    || { echo "FAIL: tap not in bats args"; cat "$_args_log"; return 1; }
}

@test "gate parses failures from TAP report.tap not from pretty stdout (behavioral)" {
  # Verifies the pretty→report.tap→_parse_bats_failure_line pipeline:
  #   - bats emits pretty output (✗ lines) to stdout  [must NOT be parsed]
  #   - bats writes TAP to report.tap                 [must be the parser input]
  # The stub has 1 TAP failure; if the gate mistakenly parsed pretty stdout
  # it would see 0 (pretty ✗ lines don't match ^not ok) or parse incorrectly.
  _stub_dir="${BATS_TEST_TMPDIR}/bats_tap_pipe_stub"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/bats" <<'STUBEOF'
#!/bin/bash
# Detection string — must be present so _bats_has_report_formatter() passes:
# --report-formatter
# Parse --output DIR from argv
_out_dir=""
_prev=""
for _a in "$@"; do
  if [ "$_prev" = "--output" ]; then _out_dir="$_a"; fi
  _prev="$_a"
done
# Emit pretty-format output to stdout (what terminal sees via FIFO-tee)
echo " ✗ failing test name"
# Write TAP to report.tap — this is what _parse_bats_failure_line must read
if [ -n "$_out_dir" ]; then
  mkdir -p "$_out_dir"
  printf 'TAP version 13\n1..1\nnot ok 1 failing test name\n' > "$_out_dir/report.tap"
fi
exit 1
STUBEOF
  chmod +x "$_stub_dir/bats"

  _proj=$(_make_stub_project)
  _gate_out="${BATS_TEST_TMPDIR}/gate_tap_pipe_out.json"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export PR_NUMBER='888'
    export RITE_TEST_GATE_DIFF_BASE='HEAD'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH='${_stub_dir}:\$PATH' run_test_gate '${_gate_out}' '${_proj}'
  " || true
  # Gate exits 1 because bats failed; JSON must still be written
  [ -f "$_gate_out" ]

  # JSON must have exactly 1 tests entry with the TAP-sourced name
  _tests_count=$(grep -o '"test_name"' "$_gate_out" | wc -l | tr -d ' ')
  [ "$_tests_count" -eq 1 ] \
    || { echo "FAIL: expected 1 tests entry; got $_tests_count"; cat "$_gate_out"; return 1; }
  grep -q 'failing test name' "$_gate_out" \
    || { echo "FAIL: test_name from TAP not in JSON"; cat "$_gate_out"; return 1; }
}

@test "gate falls back to tee-captured TAP output when pretty not supported (behavioral)" {
  # When _bats_has_report_formatter() returns 1 (old bats), the gate must
  # use the tee→_tests_raw_file fallback.  The stub binary does NOT contain
  # '--report-formatter', so detection fails.  The stub writes TAP to stdout;
  # the gate tees it into the raw file.  JSON must contain the failure entry.
  _stub_dir="${BATS_TEST_TMPDIR}/bats_fallback_stub"
  mkdir -p "$_stub_dir"
  # Note: the stub body must NOT contain the literal '--report-formatter'
  # string because _bats_has_report_formatter() greps the binary file.
  # This stub omits it intentionally so detection returns 1 (fallback path).
  cat > "$_stub_dir/bats" <<'STUBEOF'
#!/bin/bash
# Older bats style — no report-formatter support.
# Output plain TAP to stdout (old bats behavior).
echo "TAP version 13"
echo "1..1"
echo "not ok 1 fallback test name"
exit 1
STUBEOF
  chmod +x "$_stub_dir/bats"

  _proj=$(_make_stub_project)
  _gate_out="${BATS_TEST_TMPDIR}/gate_fallback_out.json"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export PR_NUMBER='888'
    export RITE_TEST_GATE_DIFF_BASE='HEAD'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH='${_stub_dir}:\$PATH' run_test_gate '${_gate_out}' '${_proj}'
  " || true
  # Gate exits 1; JSON still written
  [ -f "$_gate_out" ]

  # JSON must have the failure entry from the tee-captured TAP
  _tests_count=$(grep -o '"test_name"' "$_gate_out" | wc -l | tr -d ' ')
  [ "$_tests_count" -eq 1 ] \
    || { echo "FAIL: expected 1 tests entry from tee fallback; got $_tests_count"; cat "$_gate_out"; return 1; }
  grep -q 'fallback test name' "$_gate_out" \
    || { echo "FAIL: test_name from tee fallback not in JSON"; cat "$_gate_out"; return 1; }
}

@test "test-gate.sh _bats_tap_dir is PID-scoped to prevent glob collision" {
  # The tap dir name must include $$ (current PID) to isolate concurrent runs.
  run grep -n '_bats_tap_dir.*\$\$\|mktemp.*_bats_tap_dir\|rite_gate_tap' \
    "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'$$'* || "$output" == *"rite_gate_tap"* ]]
}

@test "test-gate.sh _bats_tap_dir is cleaned up (rm -rf, not glob)" {
  # Cleanup must use the specific variable, never a glob, per temp-file-isolation contract.
  run grep -n 'rm.*_bats_tap_dir' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_bats_tap_dir"* ]]
  # Must NOT use a glob pattern (e.g. /tmp/rite_gate_tap_*.*)
  run grep -n 'rm.*rite_gate_tap_\*' "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -ne 0 ]
}

@test "test-gate.sh trap handler also cleans up _bats_tap_dir" {
  # The EXIT trap must include _bats_tap_dir cleanup so it fires on crash too.
  run grep -n 'trap.*_bats_tap_dir\|_bats_tap_dir.*trap' "${RITE_LIB_DIR}/utils/test-gate.sh"
  # Either a direct grep on the trap body or on the pattern near the trap line
  # A simpler check: the trap body (line 459) must reference _bats_tap_dir.
  _trap_section=$(sed -n "/trap '.*_gate_exit_status/,/EXIT$/p" \
    "${RITE_LIB_DIR}/utils/test-gate.sh" 2>/dev/null || true)
  echo "$_trap_section" | grep -q '_bats_tap_dir' || {
    echo "FAIL: EXIT trap does not clean up _bats_tap_dir" >&2
    echo "Trap section:" >&2
    echo "$_trap_section" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# JSON parser regression: TAP content preserved for ^not ok parsing
# ---------------------------------------------------------------------------

@test "_parse_bats_failure_line still parses TAP 'not ok N test name' format" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    result=\$(_parse_bats_failure_line 'not ok 3 my failing test' 2>/dev/null || true)
    echo \"\$result\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"test_name"'* ]]
  [[ "$output" == *"my failing test"* ]]
}

@test "_parse_bats_failure_line: passing 'ok N' TAP line returns nothing" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    result=\$(_parse_bats_failure_line 'ok 1 my passing test' 2>/dev/null || true)
    echo \"result:[\$result]\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "result:[]" ]]
}

@test "_parse_bats_failure_line: pretty-formatted output line returns nothing (no false positives)" {
  # The pretty formatter outputs '✓ test name' or '✗ test name' lines.
  # These must NOT be mistaken for TAP failures by the parser.
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    # Simulate a pretty-formatter line (✓ test passed)
    result=\$(_parse_bats_failure_line ' ✓ my test name' 2>/dev/null || true)
    echo \"result:[\$result]\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "result:[]" ]]
}

# ---------------------------------------------------------------------------
# Makefile: test target behavior — pretty detection and invocation (behavioral)
# ---------------------------------------------------------------------------
# These tests exercise the Makefile's bats detection logic by stubbing the
# bats binary and running `make test`, then asserting on what args were passed.
# ---------------------------------------------------------------------------

@test "Makefile test target passes -F pretty when bats supports --report-formatter (behavioral)" {
  # Create a fake bats that contains '--report-formatter' in its binary (so the
  # Makefile's grep-based detection fires) and logs its argv so we can inspect
  # which formatter flag was selected.
  _stub_dir="${BATS_TEST_TMPDIR}/mk_pretty_bats"
  mkdir -p "$_stub_dir"
  _mk_args_log="${BATS_TEST_TMPDIR}/mk_bats_args.log"
  # The stub must contain '--report-formatter' as a literal string in its body
  # because the Makefile does: grep -q -- '--report-formatter' "$(command -v bats)"
  cat > "$_stub_dir/bats" <<STUB
#!/bin/bash
# --report-formatter
printf '%s\n' "\$@" >> "${_mk_args_log}"
exit 0
STUB
  chmod +x "$_stub_dir/bats"

  # Set up a temp dir with the project Makefile and a tests/ directory
  _mk_dir="${BATS_TEST_TMPDIR}/mk_pretty_proj"
  mkdir -p "$_mk_dir/tests"
  cp "${BATS_TEST_DIRNAME}/../../Makefile" "$_mk_dir/Makefile"

  run env -i HOME="$HOME" PATH="${_stub_dir}:/usr/bin:/bin" \
    make -C "$_mk_dir" test
  [ "$status" -eq 0 ]

  # The Makefile must have invoked bats with -F pretty
  [ -f "$_mk_args_log" ] || { echo "FAIL: bats was never invoked"; return 1; }
  grep -q '\-F' "$_mk_args_log" \
    || { echo "FAIL: -F not passed to bats"; cat "$_mk_args_log"; return 1; }
  grep -q 'pretty' "$_mk_args_log" \
    || { echo "FAIL: pretty not passed to bats"; cat "$_mk_args_log"; return 1; }
}

@test "Makefile test target omits -F pretty when bats lacks report-formatter support (behavioral)" {
  # Fake bats that does NOT contain the detection string in its binary —
  # Makefile's `grep -q -- '--report-formatter' $(command -v bats)` must fail
  # and the Makefile must fall back to invoking bats without -F pretty.
  # IMPORTANT: the stub body must not contain '--report-formatter' as a literal
  # string, otherwise the grep detection would (correctly) fire.
  _stub_dir="${BATS_TEST_TMPDIR}/mk_fallback_bats"
  mkdir -p "$_stub_dir"
  _mk_fb_args_log="${BATS_TEST_TMPDIR}/mk_fb_bats_args.log"
  cat > "$_stub_dir/bats" <<STUB
#!/bin/bash
# Older bats — no enhanced reporting support.
printf '%s\n' "\$@" >> "${_mk_fb_args_log}"
exit 0
STUB
  chmod +x "$_stub_dir/bats"

  _mk_dir="${BATS_TEST_TMPDIR}/mk_fallback_proj"
  mkdir -p "$_mk_dir/tests"
  cp "${BATS_TEST_DIRNAME}/../../Makefile" "$_mk_dir/Makefile"

  run env -i HOME="$HOME" PATH="${_stub_dir}:/usr/bin:/bin" \
    make -C "$_mk_dir" test
  [ "$status" -eq 0 ]

  [ -f "$_mk_fb_args_log" ] || { echo "FAIL: bats was never invoked"; return 1; }
  # Must NOT have -F pretty
  if grep -q '\-F' "$_mk_fb_args_log" && grep -q 'pretty' "$_mk_fb_args_log"; then
    echo "FAIL: -F pretty was passed despite missing --report-formatter support"
    cat "$_mk_fb_args_log"
    return 1
  fi
}

@test "Makefile test target always passes -r tests/ for recursive invocation (behavioral)" {
  # Even with pretty enabled, the recursive flag must be present so the full
  # suite runs rather than a single file.
  _stub_dir="${BATS_TEST_TMPDIR}/mk_recurse_bats"
  mkdir -p "$_stub_dir"
  _mk_rec_args_log="${BATS_TEST_TMPDIR}/mk_rec_bats_args.log"
  cat > "$_stub_dir/bats" <<STUB
#!/bin/bash
# --report-formatter
printf '%s\n' "\$@" >> "${_mk_rec_args_log}"
exit 0
STUB
  chmod +x "$_stub_dir/bats"

  _mk_dir="${BATS_TEST_TMPDIR}/mk_recurse_proj"
  mkdir -p "$_mk_dir/tests"
  cp "${BATS_TEST_DIRNAME}/../../Makefile" "$_mk_dir/Makefile"

  run env -i HOME="$HOME" PATH="${_stub_dir}:/usr/bin:/bin" \
    make -C "$_mk_dir" test
  [ "$status" -eq 0 ]

  [ -f "$_mk_rec_args_log" ] || { echo "FAIL: bats was never invoked"; return 1; }
  # -r and tests/ must both appear (order: bats -F pretty -r tests/)
  grep -q '\-r' "$_mk_rec_args_log" \
    || { echo "FAIL: -r not passed to bats"; cat "$_mk_rec_args_log"; return 1; }
  grep -q 'tests/' "$_mk_rec_args_log" \
    || { echo "FAIL: tests/ not passed to bats"; cat "$_mk_rec_args_log"; return 1; }
}

# ---------------------------------------------------------------------------
# Parallel jobs (--jobs N) + pretty formatter + TAP pipeline (issue #606)
# ---------------------------------------------------------------------------
# These tests verify that enabling --jobs N does NOT break the pretty+TAP
# pipeline.  The real production path is always: parallel jobs active (when
# GNU parallel is installed) AND pretty formatter active (bats-core 1.5+).
# Prior test coverage verified each dimension independently; these tests
# verify their combination.
# ---------------------------------------------------------------------------

@test "gate passes --jobs N alongside -F pretty when RITE_BATS_JOBS is set (behavioral)" {
  # When RITE_BATS_JOBS=2 and bats supports --report-formatter, the gate
  # must include BOTH --jobs 2 AND -F pretty in the same invocation.
  # The stub logs all argv so we can assert on the full arg list.
  _stub_dir="${BATS_TEST_TMPDIR}/bats_jobs_pretty_stub"
  mkdir -p "$_stub_dir"
  _args_log="${BATS_TEST_TMPDIR}/bats_jobs_pretty_args.log"
  cat > "$_stub_dir/bats" <<STUB
#!/bin/bash
# Detection string: --report-formatter
printf '%s\n' "\$@" >> "${_args_log}"
# Write a minimal passing TAP report to any --output dir provided
_out_dir=""
_prev=""
for _a in "\$@"; do
  if [ "\$_prev" = "--output" ]; then _out_dir="\$_a"; fi
  _prev="\$_a"
done
if [ -n "\$_out_dir" ]; then
  mkdir -p "\$_out_dir"
  printf 'TAP version 13\n1..1\nok 1 stub passing test\n' > "\$_out_dir/report.tap"
fi
exit 0
STUB
  chmod +x "$_stub_dir/bats"

  _proj=$(_make_stub_project)
  _gate_out="${BATS_TEST_TMPDIR}/gate_jobs_pretty_out.json"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export PR_NUMBER='888'
    export RITE_TEST_GATE_DIFF_BASE='HEAD'
    export RITE_BATS_JOBS=2
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH='${_stub_dir}:\$PATH' run_test_gate '${_gate_out}' '${_proj}'
  "
  [ "$status" -eq 0 ]
  [ -f "$_gate_out" ]
  [ -f "$_args_log" ]

  # Both --jobs and the job count must be present in the logged args
  grep -q -- '--jobs' "$_args_log" \
    || { echo "FAIL: --jobs not passed to bats"; cat "$_args_log"; return 1; }
  grep -A1 -- '--jobs' "$_args_log" | grep -qx '2' \
    || { echo "FAIL: job count '2' not the operand immediately after --jobs in bats args"; cat "$_args_log"; return 1; }

  # Pretty formatter must also be present — --jobs must not have displaced it
  grep -q -- '-F' "$_args_log" \
    || { echo "FAIL: -F pretty not passed to bats alongside --jobs"; cat "$_args_log"; return 1; }
  grep -q 'pretty' "$_args_log" \
    || { echo "FAIL: pretty not in bats args when --jobs active"; cat "$_args_log"; return 1; }

  # TAP report-formatter must be present too
  grep -q -- '--report-formatter' "$_args_log" \
    || { echo "FAIL: --report-formatter missing when --jobs active"; cat "$_args_log"; return 1; }
}

@test "gate reads TAP report.tap (not pretty stdout) when --jobs N is active (behavioral)" {
  # Verifies that the pretty→report.tap→_parse_bats_failure_line pipeline
  # still reads the TAP file — not stdout — when --jobs N is in effect.
  # The stub emits a pretty ✗ line to stdout AND writes a TAP failure to
  # report.tap.  Enabling RITE_BATS_JOBS=2 must not change the parser's
  # input source: JSON must contain the TAP-sourced failure, not a doubled
  # or misread entry from pretty stdout.
  _stub_dir="${BATS_TEST_TMPDIR}/bats_jobs_tap_src_stub"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/bats" <<'STUBEOF'
#!/bin/bash
# Detection string: --report-formatter
# Parse --output DIR from argv
_out_dir=""
_prev=""
for _a in "$@"; do
  if [ "$_prev" = "--output" ]; then _out_dir="$_a"; fi
  _prev="$_a"
done
# Pretty output to stdout — must NOT be parsed as a failure
echo " ✗ parallel tap failing test"
# TAP report to file — this is what the gate must parse
if [ -n "$_out_dir" ]; then
  mkdir -p "$_out_dir"
  printf 'TAP version 13\n1..1\nnot ok 1 parallel tap failing test\n' > "$_out_dir/report.tap"
fi
exit 1
STUBEOF
  chmod +x "$_stub_dir/bats"

  _proj=$(_make_stub_project)
  _gate_out="${BATS_TEST_TMPDIR}/gate_jobs_tap_src_out.json"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export PR_NUMBER='888'
    export RITE_TEST_GATE_DIFF_BASE='HEAD'
    export RITE_BATS_JOBS=2
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH='${_stub_dir}:\$PATH' run_test_gate '${_gate_out}' '${_proj}'
  " || true
  # Gate exits 1 because bats failed; JSON must still be written
  [ -f "$_gate_out" ]

  # Must have exactly 1 tests entry — the TAP-sourced failure
  _tests_count=$(grep -o '"test_name"' "$_gate_out" | wc -l | tr -d ' ')
  [ "$_tests_count" -eq 1 ] \
    || { echo "FAIL: expected 1 tests entry; got $_tests_count"; cat "$_gate_out"; return 1; }
  grep -q 'parallel tap failing test' "$_gate_out" \
    || { echo "FAIL: TAP-sourced failure name not in JSON"; cat "$_gate_out"; return 1; }
}

@test "gate captures multiple TAP failures from report.tap when --jobs N is active (behavioral)" {
  # When parallel jobs produce multiple failing tests, the TAP report.tap
  # aggregates all of them into a single file.  The gate must parse ALL
  # 'not ok' lines — not just the first — even when --jobs N was in effect.
  _stub_dir="${BATS_TEST_TMPDIR}/bats_jobs_multi_fail_stub"
  mkdir -p "$_stub_dir"
  cat > "$_stub_dir/bats" <<'STUBEOF'
#!/bin/bash
# Detection string: --report-formatter
_out_dir=""
_prev=""
for _a in "$@"; do
  if [ "$_prev" = "--output" ]; then _out_dir="$_a"; fi
  _prev="$_a"
done
# Two pretty ✗ lines to stdout (simulating two failing files under --jobs)
echo " ✗ parallel job one failure"
echo " ✗ parallel job two failure"
# TAP report with both failures — the gate must parse both
if [ -n "$_out_dir" ]; then
  mkdir -p "$_out_dir"
  printf 'TAP version 13\n1..2\nnot ok 1 parallel job one failure\nnot ok 2 parallel job two failure\n' > "$_out_dir/report.tap"
fi
exit 1
STUBEOF
  chmod +x "$_stub_dir/bats"

  _proj=$(_make_stub_project)
  _gate_out="${BATS_TEST_TMPDIR}/gate_jobs_multi_fail_out.json"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export PR_NUMBER='888'
    export RITE_TEST_GATE_DIFF_BASE='HEAD'
    export RITE_BATS_JOBS=2
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    PATH='${_stub_dir}:\$PATH' run_test_gate '${_gate_out}' '${_proj}'
  " || true
  [ -f "$_gate_out" ]

  # Both failures must appear in the JSON output
  _tests_count=$(grep -o '"test_name"' "$_gate_out" | wc -l | tr -d ' ')
  [ "$_tests_count" -eq 2 ] \
    || { echo "FAIL: expected 2 tests entries from parallel TAP; got $_tests_count"; cat "$_gate_out"; return 1; }
  grep -q 'parallel job one failure' "$_gate_out" \
    || { echo "FAIL: first TAP failure missing from JSON"; cat "$_gate_out"; return 1; }
  grep -q 'parallel job two failure' "$_gate_out" \
    || { echo "FAIL: second TAP failure missing from JSON"; cat "$_gate_out"; return 1; }
}
