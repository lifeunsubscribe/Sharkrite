#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# Regression tests for the gate baseline-diff (new-vs-pre-existing classifier).
#
# The gate must block only on failures THIS change introduced, not on the
# accumulated pre-existing red baseline on origin/main (the "gate-green gap":
# ~30 reds made every failure look the same, so failing tests merged). These
# tests pin:
#   1. _tap_failure_name canonicalization (used by both sides of the diff)
#   2. _classify_test_failures: all-new / all-pre-existing / mixed
#   3. Fail-safe fallback (unresolvable base → flag all)
#   4. Operator valve (RITE_GATE_BASELINE_DIFF=false → flag all, no probe)
#   5. Per-base-SHA cache hit (no re-probe)
#   6. End-to-end with a REAL detached-worktree baseline run
#
# NOTE 1: _classify_test_failures MUST be called directly (not via $()/run) — it
# sets _GATE_* globals a subshell would discard, and returns NEW names via an
# out-file arg. Tests read names from $OUT and assert globals inline.
#
# NOTE 2: bats preprocesses EVERY "@test" line in this file — even ones inside a
# heredoc. So fixtures cannot be written with a literal "@test" token here, or
# they'd be mangled to bats' internal form. _write_fixture builds the token at
# runtime so the fixture file gets real "@test ..." lines.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export RITE_REPO_ROOT
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # shellcheck source=/dev/null
  source "${RITE_REPO_ROOT}/lib/utils/test-gate.sh"

  TEST_REPO=$(mktemp -d)
  export TEST_REPO
  export RITE_STATE_DIR="$TEST_REPO/.rite/state"
  mkdir -p "$RITE_STATE_DIR" "$TEST_REPO/tests/regression"
  OUT="$TEST_REPO/new.txt"

  # A selected bats file whose @test names the classifier attributes failures to.
  _write_fixture "$TEST_REPO/tests/regression/sample.bats" \
    "test alpha" true \
    "test beta" true \
    "test gamma" true

  # Minimal real git repo so `git rev-parse <base>` resolves.
  (cd "$TEST_REPO" \
     && git init -q \
     && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base) >/dev/null 2>&1

  # Branch TAP: alpha+beta fail, gamma passes.
  BRANCH_TAP="$TEST_REPO/branch.tap"
  printf 'ok 3 test gamma\nnot ok 1 test alpha\nnot ok 2 test beta\n' > "$BRANCH_TAP"

  # Stub marker — the stubbed probe runs in $() (subshell), so detect "was it
  # called" via a file side effect, not a variable.
  STUB_MARKER="$TEST_REPO/stub-called"
}

teardown() {
  [ -n "${TEST_REPO:-}" ] && rm -rf "$TEST_REPO"
}

# Write a runnable .bats fixture with real "@test" lines. The token is built at
# runtime ('@'"test") so THIS file's source contains no literal "@test" for
# bats to preprocess. Args: path, then (name body) pairs.
_write_fixture() {
  local _path="$1"; shift
  local _t='@'"test"
  : > "$_path"
  while [ "$#" -ge 2 ]; do
    printf '%s "%s" { %s; }\n' "$_t" "$1" "$2" >> "$_path"
    shift 2
  done
}

# Override the worktree-running probe with a deterministic stub that reports a
# given set of baseline-red names (via $STUB_REDS) and records that it ran.
_stub_baseline() {
  eval '_compute_baseline_red_names() {
    printf "%s" "$STUB_REDS"
    echo called >> "'"$STUB_MARKER"'"
  }'
}

# ---------------------------------------------------------------------------
# _tap_failure_name
# ---------------------------------------------------------------------------

@test "_tap_failure_name strips prefix and trailing whitespace" {
  run _tap_failure_name "not ok 12 some descriptive name   "
  [ "$status" -eq 0 ]
  [ "$output" = "some descriptive name" ]
}

# ---------------------------------------------------------------------------
# _classify_test_failures — stubbed baseline
# ---------------------------------------------------------------------------

@test "classify: no baseline reds → all failures are NEW" {
  export STUB_REDS=""
  _stub_baseline
  _classify_test_failures "$BRANCH_TAP" "tests/regression/sample.bats" "$TEST_REPO" "HEAD" "$OUT"
  grep -Fxq "test alpha" "$OUT"
  grep -Fxq "test beta" "$OUT"
  [ "$_GATE_TOTAL_FAIL" -eq 2 ]
  [ "$_GATE_NEW_FAIL" -eq 2 ]
  [ "$_GATE_PREEXISTING_FAIL" -eq 0 ]
  [ "$_GATE_BASELINE_MODE" = "computed" ]
  [ -f "$STUB_MARKER" ]
}

@test "classify: all failures red at baseline → zero NEW (suppressed)" {
  export STUB_REDS=$'test alpha\ntest beta'
  _stub_baseline
  _classify_test_failures "$BRANCH_TAP" "tests/regression/sample.bats" "$TEST_REPO" "HEAD" "$OUT"
  [ ! -s "$OUT" ]   # no NEW names emitted
  [ "$_GATE_NEW_FAIL" -eq 0 ]
  [ "$_GATE_PREEXISTING_FAIL" -eq 2 ]
}

@test "classify: mixed → only the new failure is emitted" {
  export STUB_REDS="test alpha"   # alpha pre-existing, beta new
  _stub_baseline
  _classify_test_failures "$BRANCH_TAP" "tests/regression/sample.bats" "$TEST_REPO" "HEAD" "$OUT"
  run cat "$OUT"
  [ "$output" = "test beta" ]
  [ "$_GATE_NEW_FAIL" -eq 1 ]
  [ "$_GATE_PREEXISTING_FAIL" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Fail-safe + operator valve
# ---------------------------------------------------------------------------

@test "classify: unresolvable diff base → fallback flags ALL (fail-safe)" {
  export STUB_REDS=""
  _stub_baseline
  _classify_test_failures "$BRANCH_TAP" "tests/regression/sample.bats" "$TEST_REPO" "no-such-ref-xyz" "$OUT"
  [ "$_GATE_BASELINE_MODE" = "fallback" ]
  [ "$_GATE_NEW_FAIL" -eq 2 ]
  [ ! -f "$STUB_MARKER" ]   # never probed
}

@test "classify: RITE_GATE_BASELINE_DIFF=false disables (flag all, no probe)" {
  export STUB_REDS="test alpha"
  _stub_baseline
  RITE_GATE_BASELINE_DIFF=false _classify_test_failures "$BRANCH_TAP" "tests/regression/sample.bats" "$TEST_REPO" "HEAD" "$OUT"
  [ "$_GATE_BASELINE_MODE" = "disabled" ]
  [ "$_GATE_NEW_FAIL" -eq 2 ]
  [ ! -f "$STUB_MARKER" ]   # valve short-circuits before any probe
}

# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

@test "classify: per-base-SHA cache hit skips the probe" {
  local _sha
  _sha=$(cd "$TEST_REPO" && git rev-parse HEAD)
  # Pre-seed the cache: sample.bats already probed, alpha known red at baseline.
  printf '{"probed_files":["tests/regression/sample.bats"],"red_names":["test alpha"]}\n' \
    > "$RITE_STATE_DIR/gate-baseline-reds-${_sha}.json"
  export STUB_REDS="SHOULD-NOT-BE-USED"
  _stub_baseline
  _classify_test_failures "$BRANCH_TAP" "tests/regression/sample.bats" "$TEST_REPO" "HEAD" "$OUT"
  run cat "$OUT"
  [ "$output" = "test beta" ]      # alpha suppressed from cache, beta new
  [ "$_GATE_BASELINE_MODE" = "cached" ]
  [ ! -f "$STUB_MARKER" ]          # cache hit → no probe ran
}

# ---------------------------------------------------------------------------
# End-to-end: real detached-worktree baseline run (no stub)
# ---------------------------------------------------------------------------

@test "classify: probe-size cap → skip probe + flag-all (no near-full second suite)" {
  # 13 selected files, each with its own failing test → _to_probe(13) > cap(12).
  # The probe must be skipped (no near-full re-run) and fail-safe to flag-all.
  local _sel="" _i _name
  : > "$TEST_REPO/branch13.tap"
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
    _name="capfail-$_i"
    _write_fixture "$TEST_REPO/tests/regression/cap$_i.bats" "$_name" false
    _sel="${_sel}tests/regression/cap$_i.bats"$'\n'
    printf 'not ok %s %s\n' "$_i" "$_name" >> "$TEST_REPO/branch13.tap"
  done
  (cd "$TEST_REPO" && git add -A && git commit -qm cap) >/dev/null 2>&1
  export STUB_REDS="capfail-1"   # would suppress one IF the probe ran — but the cap skips it
  _stub_baseline
  RITE_GATE_BASELINE_MAX_PROBE_FILES=12 \
    _classify_test_failures "$TEST_REPO/branch13.tap" "$_sel" "$TEST_REPO" "HEAD" "$OUT"
  [ "$_GATE_BASELINE_MODE" = "capped" ]
  [ "$_GATE_NEW_FAIL" -eq 13 ]     # all flagged new (fail-safe over-block), none suppressed
  [ ! -f "$STUB_MARKER" ]          # probe never ran → no near-full re-run, no deadlock risk
}

@test "integration: real baseline run separates new regression from pre-existing red" {
  # Base commit: alpha PASSES, preexist FAILS.
  _write_fixture "$TEST_REPO/tests/regression/sample.bats" \
    "test alpha" true \
    "test preexist" false
  (cd "$TEST_REPO" && git add -A && git commit -qm "base with preexisting red") >/dev/null 2>&1
  local _base_sha
  _base_sha=$(cd "$TEST_REPO" && git rev-parse HEAD)

  # Branch change: alpha now FAILS too (a NEW regression); preexist still fails.
  _write_fixture "$TEST_REPO/tests/regression/sample.bats" \
    "test alpha" false \
    "test preexist" false
  (cd "$TEST_REPO" && git add -A && git commit -qm "branch breaks alpha") >/dev/null 2>&1

  # Branch TAP reflects branch state: both fail.
  printf 'not ok 1 test alpha\nnot ok 2 test preexist\n' > "$BRANCH_TAP"

  # Run in a clean env so the nested bats invocation inside the baseline worktree
  # does not inherit this outer bats run's BATS_* tmpdirs. Read NEW names + the
  # _GATE_* counts the (direct) call leaves behind.
  run env -u BATS_TEST_TMPDIR -u BATS_FILE_TMPDIR -u BATS_RUN_TMPDIR \
        -u BATS_TEST_NAME -u BATS_TEST_NUMBER \
        bash -c "
          set -euo pipefail
          export RITE_LIB_DIR='$RITE_LIB_DIR' RITE_STATE_DIR='$RITE_STATE_DIR'
          source '$RITE_LIB_DIR/utils/test-gate.sh'
          _classify_test_failures '$BRANCH_TAP' 'tests/regression/sample.bats' '$TEST_REPO' '$_base_sha' '$OUT'
          echo \"NEW=[\$(cat '$OUT')]\"
          echo \"COUNTS new=\$_GATE_NEW_FAIL pre=\$_GATE_PREEXISTING_FAIL mode=\$_GATE_BASELINE_MODE\"
        "
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NEW=[test alpha]"* ]]          # only the new regression
  [[ "$output" == *"new=1 pre=1"* ]]                # preexist correctly suppressed
  [[ "$output" == *"mode=computed"* ]]
}
