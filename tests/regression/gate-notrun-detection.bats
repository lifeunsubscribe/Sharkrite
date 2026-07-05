#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, tests/regression/batch-locked-issue-in-progress-status.bats
#
# Regression tests: gate observability for bats plan-vs-executed mismatch
# (issue #804, PR #828's four blind fix rounds) and the not-run name
# extraction rewrite (issue #862, PR #852's 130 phantom findings).
#
# bats-core 1.13 exits non-zero when fewer tests execute than the 1..N plan
# even with 0 reported failures, and a test killed before emitting its result
# writes NOTHING to report.tap. Before #804, the gate reported exit_code=1
# with test_count=0 — a blocking gate with zero nameable findings. The gate
# detects the mismatch (TAP plan deficit + the "Executed X instead of
# expected Y" warning in the captured pretty stream) and emits synthetic
# [tests_not_run] not-ok findings.
#
# #862 rewrote HOW the not-run names are resolved. The #840 extractor paired
# begin/result fragments from the captured pretty stream — under `--jobs N`
# that stream interleaves across workers, mismatching tests that ran fine
# (live: deficit 1 → 130 phantom findings, PR #852 gate 2026-07-03). Names
# now come from a set difference: planned @test descriptions (parsed from the
# SELECTED .bats files) minus descriptions in report.tap result lines. The
# synthetic finding count is CAPPED at the bats-reported deficit; when name
# resolution is ambiguous the gate emits deficit-many findings naming the
# affected file(s) — never phantom test names.
#
# The live swallow requires a CONJUNCTION (spec 2x2 matrix): a bats file whose
# setup() leaks `set -euo pipefail` into the bats-exec-test shell AND
# BATS_TEST_TIMEOUT set (the gate exports it). Then a failing test triggers
# bats_kill_processes_of's untolerated `kill` (bats-exec-test:263) under the
# leaked errexit, killing bats-exec-test before the `not ok` line is emitted.
#
# NOTE on fixtures: runtime-generated .bats files are written with printf,
# never heredocs — bats-preprocess rewrites heredoc-embedded @test lines into
# bats_test_function calls, which would leave the generated fixture without
# the literal @test lines the planned-set parser reads.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${RITE_LIB_DIR}/utils/test-gate.sh"
  # test-gate.sh leaks `set -euo pipefail` into this test shell — combined
  # with BATS_TEST_TIMEOUT (set by the gate) that leak is the exact swallow
  # this file guards against. Neutralize immediately after sourcing.
  set +u
  set +o pipefail
}

# =============================================================================
# UNIT: _tap_plan_deficit
# =============================================================================

@test "unit: _tap_plan_deficit counts planned-but-unreported tests across concatenated sections" {
  _tap="$BATS_TEST_TMPDIR/concat.tap"
  cat > "$_tap" <<'EOF'
1..3
ok 1 first passes
ok 3 third passes
1..2
ok 1 serial a
not ok 2 serial b
EOF
  run _tap_plan_deficit "$_tap"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "unit: _tap_plan_deficit is 0 for a fully-reported TAP file" {
  _tap="$BATS_TEST_TMPDIR/full.tap"
  cat > "$_tap" <<'EOF'
1..2
ok 1 a
not ok 2 b
EOF
  run _tap_plan_deficit "$_tap"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "unit: _tap_plan_deficit is 0 for a missing or empty file" {
  run _tap_plan_deficit "$BATS_TEST_TMPDIR/does-not-exist.tap"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# =============================================================================
# UNIT: _extract_notrun_test_names (planned-vs-TAP set difference, #862)
# =============================================================================

@test "unit: _extract_notrun_test_names names the swallowed test by planned-vs-TAP set difference" {
  _root="$BATS_TEST_TMPDIR/sd-root"
  mkdir -p "$_root/tests"
  {
    printf '#!/usr/bin/env bats\n'
    printf '@test "first passes" { true; }\n'
    printf '@test "second swallowed" { false; }\n'
    printf '@test "third passes" { true; }\n'
  } > "$_root/tests/swallow.bats"
  _tap="$BATS_TEST_TMPDIR/sd.tap"
  printf '1..3\nok 1 first passes\nok 3 third passes\n' > "$_tap"
  _fl="$BATS_TEST_TMPDIR/sd.files"
  printf 'tests/swallow.bats\n' > "$_fl"
  run _extract_notrun_test_names "$_tap" "$_fl" "$_root"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'tests/swallow.bats\tsecond swallowed')" ]
}

@test "unit: _extract_notrun_test_names does not false-positive on skipped tests" {
  # Skipped tests DO write a result line to report.tap (`ok N name # skip
  # [reason]`) — the directive must be stripped before comparison, otherwise
  # every skip would show up as a not-run test.
  _root="$BATS_TEST_TMPDIR/skip-root"
  mkdir -p "$_root/tests"
  {
    printf '#!/usr/bin/env bats\n'
    printf '@test "b skipped" { skip "why"; }\n'
    printf '@test "c swallowed" { false; }\n'
  } > "$_root/tests/skipmix.bats"
  _tap="$BATS_TEST_TMPDIR/skip.tap"
  printf '1..2\nok 1 b skipped # skip why\n' > "$_tap"
  _fl="$BATS_TEST_TMPDIR/skip.files"
  printf 'tests/skipmix.bats\n' > "$_fl"
  run _extract_notrun_test_names "$_tap" "$_fl" "$_root"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'tests/skipmix.bats\tc swallowed')" ]
}

@test "unit: _extract_notrun_test_names unescapes double-quoted descriptions (bats shell-evaluates them)" {
  # bats DOES shell-evaluate double-quoted descriptions when sourcing the
  # preprocessed file (verified on bats 1.13.0): source text `handles
  # \"quoted\" args` appears in report.tap as `handles "quoted" args`, and
  # `\$5` as `$5`. Single-quoted descriptions stay literal. The planned-set
  # parser must mirror this or every escaped description false-positives as
  # not-run (2026-07-03 review finding on #862).
  _root="$BATS_TEST_TMPDIR/esc-root"
  mkdir -p "$_root/tests"
  {
    printf '#!/usr/bin/env bats\n'
    printf '@test "handles \\"quoted\\" args" { true; }\n'
    printf '@test "costs \\$5 total" { true; }\n'
    printf "@test 'single quoted' { true; }\n"
    printf '@test "swallowed one" { false; }\n'
  } > "$_root/tests/esc.bats"
  _tap="$BATS_TEST_TMPDIR/esc.tap"
  # TAP written in REAL bats output form: escapes already collapsed.
  {
    printf '1..4\n'
    printf 'ok 1 handles "quoted" args\n'
    printf 'ok 2 costs $5 total\n'
    printf 'ok 3 single quoted\n'
  } > "$_tap"
  _fl="$BATS_TEST_TMPDIR/esc.files"
  printf 'tests/esc.bats\n' > "$_fl"
  run _extract_notrun_test_names "$_tap" "$_fl" "$_root"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'tests/esc.bats\tswallowed one')" ]
}

@test "unit: escaped descriptions verified against REAL bats TAP output" {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  # Ground truth: run real bats on an escaped-description file and feed its
  # actual report.tap to the extractor — zero tests may classify as not-run.
  _root="$BATS_TEST_TMPDIR/real-esc"
  mkdir -p "$_root/tests" "$_root/tap"
  {
    printf '#!/usr/bin/env bats\n'
    printf '@test "handles \\"quoted\\" args" { true; }\n'
    printf '@test "costs \\$5 total" { true; }\n'
  } > "$_root/tests/real.bats"
  ( cd "$_root" && BATS_REPORT_FILENAME=report.tap \
      bats --report-formatter tap --output "$_root/tap" tests/real.bats >/dev/null 2>&1 ) || true
  [ -s "$_root/tap/report.tap" ] || skip "bats --report-formatter unavailable"
  _fl="$BATS_TEST_TMPDIR/real.files"
  printf 'tests/real.bats\n' > "$_fl"
  run _extract_notrun_test_names "$_root/tap/report.tap" "$_fl" "$_root"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =============================================================================
# UNIT: _synthesize_notrun_findings (deficit cap, #862)
# =============================================================================

@test "unit: interleaved-parallel fixture — deficit 1 yields exactly 1 finding (130-for-1 regression)" {
  # Reproduces the PR #852 shape: two parallel worker files, 131 planned
  # tests, 130 reported, deficit 1. The report formatter's merged TAP has the
  # workers' results interleaved and out of order — the old pretty-stream
  # begin/result pairing produced 130 phantom findings here; the set
  # difference must yield exactly the 1 swallowed test.
  _root="$BATS_TEST_TMPDIR/ilv-root"
  mkdir -p "$_root/tests"
  _fa="$_root/tests/par-a.bats"
  _fb="$_root/tests/par-b.bats"
  printf '#!/usr/bin/env bats\n' > "$_fa"
  printf '#!/usr/bin/env bats\n' > "$_fb"
  _i=1
  while [ "$_i" -le 66 ]; do
    if [ "$_i" -eq 33 ]; then
      printf '@test "worker a test 33 swallowed mid flight" { false; }\n' >> "$_fa"
    else
      printf '@test "worker a test %s" { true; }\n' "$_i" >> "$_fa"
    fi
    _i=$(( _i + 1 ))
  done
  _i=1
  while [ "$_i" -le 65 ]; do
    printf '@test "worker b test %s" { true; }\n' "$_i" >> "$_fb"
    _i=$(( _i + 1 ))
  done
  # Merged TAP: single 1..131 plan, 130 result lines alternating between
  # workers, worker a's in REVERSE order — only test a/33 never reported.
  _raw="$BATS_TEST_TMPDIR/ilv.tap"
  printf '1..131\n' > "$_raw"
  _n=1
  _i=1
  while [ "$_i" -le 66 ]; do
    _j=$(( 67 - _i ))
    if [ "$_j" -ne 33 ]; then
      printf 'ok %s worker a test %s\n' "$_n" "$_j" >> "$_raw"
      _n=$(( _n + 1 ))
    fi
    if [ "$_i" -le 65 ]; then
      printf 'ok %s worker b test %s\n' "$_n" "$_i" >> "$_raw"
      _n=$(( _n + 1 ))
    fi
    _i=$(( _i + 1 ))
  done
  # Fixture sanity: bats' arithmetic sees exactly a deficit of 1.
  run _tap_plan_deficit "$_raw"
  [ "$output" = "1" ]

  _fl="$BATS_TEST_TMPDIR/ilv.files"
  printf 'tests/par-a.bats\ntests/par-b.bats\n' > "$_fl"
  run _synthesize_notrun_findings "$_raw" "$_fl" 1 "$_root" "Executed 130 instead of expected 131 tests"
  [ "$status" -eq 0 ]
  [ "$output" = "named=1 emitted=1" ]
  # Exactly ONE synthetic finding — not 130 — and it names the real test.
  [ "$(grep -c '\[tests_not_run\]' "$_raw")" -eq 1 ]
  grep -q '\[tests_not_run\] worker a test 33 swallowed mid flight' "$_raw"
}

@test "unit: ambiguous name resolution emits deficit-many findings naming the file, never phantom test names" {
  # TAP descriptions that do not match any planned @test line (e.g.
  # BATS_TEST_NAME_PREFIX, heredoc-inflated planned sets) make the missing
  # count disagree with the deficit. The gate must then emit exactly
  # deficit-many findings labeled with the affected file — no planned name
  # may leak into a finding it cannot prove not-run.
  _root="$BATS_TEST_TMPDIR/amb-root"
  mkdir -p "$_root/tests"
  {
    printf '#!/usr/bin/env bats\n'
    printf '@test "alpha" { true; }\n'
    printf '@test "beta" { true; }\n'
    printf '@test "gamma" { false; }\n'
  } > "$_root/tests/dyn.bats"
  _raw="$BATS_TEST_TMPDIR/amb.tap"
  printf '1..3\nok 1 pfx alpha\nok 2 pfx beta\n' > "$_raw"
  _fl="$BATS_TEST_TMPDIR/amb.files"
  printf 'tests/dyn.bats\n' > "$_fl"
  run _synthesize_notrun_findings "$_raw" "$_fl" 1 "$_root" ""
  [ "$status" -eq 0 ]
  [ "$output" = "named=0 emitted=1" ]
  [ "$(grep -c '\[tests_not_run\]' "$_raw")" -eq 1 ]
  grep -q '\[tests_not_run\] planned test in tests/dyn.bats never reported a result' "$_raw"
  ! grep -E '\[tests_not_run\].*(alpha|beta|gamma)' "$_raw"
}

@test "unit: _synthesize_notrun_findings derives the cap from the bats warning when TAP deficit is 0" {
  # TAP-fallback path: no report.tap arithmetic, only the pretty-stream
  # warning. Cap = expected - executed; with no resolvable files the label
  # falls back to the generic one.
  _raw="$BATS_TEST_TMPDIR/warn.tap"
  : > "$_raw"
  _fl="$BATS_TEST_TMPDIR/warn.files"
  : > "$_fl"
  run _synthesize_notrun_findings "$_raw" "$_fl" 0 "$BATS_TEST_TMPDIR" "Executed 280 instead of expected 283 tests"
  [ "$status" -eq 0 ]
  [ "$output" = "named=0 emitted=3" ]
  [ "$(grep -c '\[tests_not_run\]' "$_raw")" -eq 3 ]
  grep -q 'planned test in selected bats file(s) never reported a result' "$_raw"
}

@test "unit: _synthesize_notrun_findings works when TAP already has real not-ok lines (mixed-outcome, issue #847)" {
  # Regression: the old caller gate (`_tests_count -eq 0`) skipped deficit
  # detection whenever at least one `not ok` line existed in report.tap.
  # A run with 1 real failure + 1 swallowed test has _tests_count=1, so the
  # swallow was invisible. This unit test verifies that _synthesize_notrun_findings
  # itself operates correctly on a mixed TAP file (1 real failure, 1 not reported).
  _root="$BATS_TEST_TMPDIR/mixed-root"
  mkdir -p "$_root/tests"
  {
    printf '#!/usr/bin/env bats\n'
    printf '@test "passes cleanly" { true; }\n'
    printf '@test "fails with not ok" { false; }\n'
    printf '@test "swallowed by errexit leak" { false; }\n'
  } > "$_root/tests/mixed.bats"
  # TAP has 3 planned, 2 reported: 1 real not ok + 1 ok; the swallowed test
  # never wrote a result line so the plan shows deficit=1.
  _raw="$BATS_TEST_TMPDIR/mixed.tap"
  {
    printf '1..3\n'
    printf 'ok 1 passes cleanly\n'
    printf 'not ok 2 fails with not ok\n'
  } > "$_raw"
  _fl="$BATS_TEST_TMPDIR/mixed.files"
  printf 'tests/mixed.bats\n' > "$_fl"
  # Deficit = 1 (3 planned, 2 reported).
  run _tap_plan_deficit "$_raw"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  # Synthesize — must succeed and name the swallowed test even though the TAP
  # file already contains a real `not ok` line (mixed-outcome case).
  run _synthesize_notrun_findings "$_raw" "$_fl" 1 "$_root" ""
  [ "$status" -eq 0 ]
  [ "$output" = "named=1 emitted=1" ]
  # Exactly one synthetic not-run finding appended, naming the swallowed test.
  [ "$(grep -c '\[tests_not_run\]' "$_raw")" -eq 1 ]
  grep -q '\[tests_not_run\] swallowed by errexit leak' "$_raw"
  # The pre-existing real not-ok line must still be present (no corruption).
  grep -q '^not ok 2 fails with not ok$' "$_raw"
}

# =============================================================================
# UNIT: _parse_bats_failure_line synthetic-marker reason
# =============================================================================

@test "unit: _parse_bats_failure_line emits reason tests_not_run for synthetic marker lines" {
  run _parse_bats_failure_line 'not ok 1 [tests_not_run] some test — planned but never reported a result'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason":"tests_not_run"'* ]]
  [[ "$output" == *'[tests_not_run] some test'* ]]
}

@test "unit: _parse_bats_failure_line keeps assertion-failed reason for real failures" {
  run _parse_bats_failure_line 'not ok 3 a genuinely failing test'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason":"assertion failed"'* ]]
}

# =============================================================================
# BEHAVIORAL: end-to-end gate run against a live swallowed test
# =============================================================================

@test "behavioral: gate emits tests_not_run finding instead of zero findings for a swallowed test" {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  command -v make >/dev/null 2>&1 || skip "make not installed"
  command -v git >/dev/null 2>&1 || skip "git not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  # --- Fixture repo: sharkrite-shaped (Makefile with shellcheck:/lint:) ---
  _repo="$BATS_TEST_TMPDIR/swallow-repo"
  mkdir -p "$_repo/tests"
  (cd "$_repo" && git init -q && git config user.email t@t.test && git config user.name t) || return 1
  printf 'shellcheck:\n\t@true\nlint:\n\t@true\n' > "$_repo/Makefile"
  (cd "$_repo" && git add -A && git commit -qm base) || return 1
  _base=$(cd "$_repo" && git rev-parse HEAD)

  # Swallow fixture per the spec 2x2 matrix: setup() sources a file that sets
  # `set -euo pipefail` (leaks into bats-exec-test); the gate itself exports
  # BATS_TEST_TIMEOUT; the failing test then gets killed before `not ok`.
  # printf-written (not heredoc — see file header note on bats-preprocess).
  printf 'set -euo pipefail\n' > "$_repo/tests/strict-env.sh"
  {
    printf '#!/usr/bin/env bats\n'
    printf '# sharkrite-test-covers: tests/strict-env.sh\n'
    printf 'setup() { source "$BATS_TEST_DIRNAME/strict-env.sh"; }\n'
    printf '@test "passes before" { true; }\n'
    printf '@test "fails and is swallowed by leaked errexit plus timeout" { false; }\n'
    printf '@test "passes after" { true; }\n'
  } > "$_repo/tests/swallow-fixture.bats"
  (cd "$_repo" && git add -A && git commit -qm fixture) || return 1

  # --- Probe: does this bats version actually swallow? ---
  # If a future bats-core tolerates the kill at bats-exec-test:263, the failing
  # test reports a normal `not ok` and no synthetic finding is needed.
  # BATS_TEST_TIMEOUT=5, not 120: the swallow conjunction needs the timeout
  # SET (any value — the countdown must merely be alive when the test fails),
  # but its orphaned countdown holds the pipe for the FULL remaining value
  # after the kill (the spec's exactly-2:00 hanging-pipe evidence). At 120 this
  # test itself blows the gate's own 120s per-test budget; at 5 it costs ~5s.
  _probe_tap="$BATS_TEST_TMPDIR/probe-tap"
  mkdir -p "$_probe_tap"
  (cd "$_repo" && BATS_TEST_TIMEOUT=5 BATS_REPORT_FILENAME=report.tap TERM=dumb \
    bats -F pretty --report-formatter tap --output "$_probe_tap" \
    tests/swallow-fixture.bats < /dev/null > /dev/null 2>&1) || true
  _probe_notok=$(grep -c '^not ok ' "$_probe_tap/report.tap" 2>/dev/null || true)
  [ "${_probe_notok:-0}" -eq 0 ] || skip "this bats version reports the failure normally (no swallow to detect)"

  # --- Run the real gate (subshell via `run`: run_test_gate manipulates the
  # EXIT trap, which must never touch this bats shell's own result trap) ---
  _out="$BATS_TEST_TMPDIR/gate.json"
  export RITE_TEST_GATE_DIFF_BASE="$_base"
  # Same hanging-pipe economics for the inner gate: the gate honors
  # RITE_BATS_TEST_TIMEOUT for its exported BATS_TEST_TIMEOUT.
  export RITE_BATS_TEST_TIMEOUT=5
  unset RITE_GATE_BACKGROUND RITE_GATE_FORCE_FULL 2>/dev/null || true
  run run_test_gate "$_out" "$_repo"

  # Gate must block (exit 1), with a nameable finding — not test_count=0.
  [ "$status" -eq 1 ] || {
    echo "FAIL: gate exit was $status, expected 1 (blocking)" >&2
    echo "$output" >&2
    return 1
  }
  [ -s "$_out" ] || {
    echo "FAIL: gate JSON not written" >&2
    return 1
  }
  grep -q '"reason":"tests_not_run"' "$_out" || {
    echo "FAIL: gate JSON lacks reason=tests_not_run:" >&2
    cat "$_out" >&2
    return 1
  }
  _tests_len=$(jq '.tests | length' "$_out")
  [ "${_tests_len:-0}" -ge 1 ] || {
    echo "FAIL: tests[] is empty — the fix loop would get zero nameable findings:" >&2
    cat "$_out" >&2
    return 1
  }
  [ "$(jq -r '.exit_code' "$_out")" = "1" ]
  # The swallowed test is named via the planned-vs-TAP set difference (#862).
  jq -r '.tests[].test_name' "$_out" | grep -q "swallowed" || {
    echo "FAIL: synthetic finding does not name the swallowed test:" >&2
    cat "$_out" >&2
    return 1
  }
  # Deficit cap (#862): exactly ONE not-run finding for a deficit of 1 —
  # never the 130-for-1 phantom flood.
  _notrun_len=$(jq '[.tests[] | select(.reason == "tests_not_run")] | length' "$_out")
  [ "${_notrun_len:-0}" -eq 1 ] || {
    echo "FAIL: expected exactly 1 tests_not_run finding for deficit 1, got ${_notrun_len}:" >&2
    cat "$_out" >&2
    return 1
  }
}

# =============================================================================
# LANDMINE GUARD: batch-locked-issue-in-progress-status.bats
# =============================================================================

@test "structural: batch-locked-issue test file uses teardown, not an EXIT trap inside a @test" {
  _f="${BATS_TEST_DIRNAME}/batch-locked-issue-in-progress-status.bats"
  # A `trap ... EXIT` inside a @test body clobbers bats' result-emitting EXIT
  # trap: the file reports "Executed 0 instead of expected 1" and writes
  # nothing to report.tap — unconditionally (timeout-independent).
  ! grep -qE '^[[:space:]]+trap .*EXIT' "$_f"
  grep -qE '^teardown\(\)' "$_f"
}

@test "behavioral: batch-locked exit-14 integration test now reports a result line" {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  # Before the fix this exact invocation printed "Executed 0 instead of
  # expected 1 tests" and emitted NO ok/not-ok line (deterministic, with and
  # without BATS_TEST_TIMEOUT).
  run env TERM=dumb bats -f "returns 14 when phase_claude_workflow" \
    "${BATS_TEST_DIRNAME}/batch-locked-issue-in-progress-status.bats" < /dev/null
  [ "$status" -eq 0 ]
  # Note: match "not ok" FIRST — a bare *"ok 1"* check also matches "not ok 1".
  [[ "$output" != *"not ok"* ]]
  [[ "$output" == *"ok 1"* ]]
  [[ "$output" != *"Executed 0 instead of expected"* ]]
}
