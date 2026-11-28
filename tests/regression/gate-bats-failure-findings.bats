#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-verdict.sh::_tap_bats_items_json|_tap_bats_item_with_loc|_gate_build_verdict, lib/core/assess-and-resolve.sh::_build_gate_prepend_items
# Regression: bats gate findings had no file or line information.
#
# When a bats test fails the gate's TAP report contains:
#   not ok N description
#   # (in test file tests/regression/foo.bats, line 42)
#   #   `assert_equal "$x" "y"' failed
#
# The existing _parse_bats_failure_line read only the first line and produced
# file="bats", reason="assertion failed" for every failure. The fix session
# received no location information and had to grep for the test name.
#
# Contract pinned here:
#   - a bats TAP failure with a location comment produces file=the .bats path
#     and reason="line N: assertion" (or "line N" when no assertion is captured)
#   - two-line form "(from function … in test file <path>, line N)" works too
#   - path is repo-relative (PROJECT_ROOT stripped)
#   - a plain "not ok" with no following comment still falls back to
#     file="bats", reason="assertion failed" (unchanged contract)
#   - fix items for bats failures still use the "bats failure" header

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  WORK=$(mktemp -d); export WORK

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: gate-verdict.sh uses a function-sentinel guard (declare -f _gate_write_json); pre-source _diag() stub is preserved on source.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/gate-verdict.sh"
  set +u; set +o pipefail
}

teardown() { rm -rf "${WORK:-}"; }

# Emit GATE_PREPEND_ITEMS for a gate JSON through the shipped builder.
_build_items() {
  run env \
    RITE_LIB_DIR="$RITE_LIB_DIR" \
    RITE_SOURCE_FUNCTIONS_ONLY=1 \
    RITE_GATE_FINDINGS="$1" \
    bash -c '
      source "$RITE_LIB_DIR/core/assess-and-resolve.sh"
      set +u; set +o pipefail
      print_warning() { true; }; print_status() { true; }; print_info() { true; }
      GATE_PREPEND_ITEMS=""
      GATE_NOW_COUNT=0
      _gate_verdict_is_stale=false
      _build_gate_prepend_items
      printf "%s" "$GATE_PREPEND_ITEMS"
      echo "COUNT:$GATE_NOW_COUNT"
    '
}

# ---------------------------------------------------------------------------
# _tap_bats_items_json
# ---------------------------------------------------------------------------

@test "parse: single-line location comment yields file and line in reason" {
  cat > "$WORK/tap.txt" <<'TAP'
1..1
not ok 1 my test name
# (in test file tests/regression/foo.bats, line 42)
#   `assert_equal "$x" "y"' failed
TAP
  run _tap_bats_items_json "$WORK/tap.txt" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *'"file":"tests/regression/foo.bats"'* ]]
  [[ "$output" == *'"reason":"line 42: assert_equal \"\$x\" \"y\""'* ]]
  [[ "$output" == *'"test_name":"my test name"'* ]]
}

@test "parse: two-line location form (from function … in test file) is handled" {
  cat > "$WORK/tap.txt" <<'TAP'
1..1
not ok 1 some test
# (from function `assert_success' in file /usr/local/lib/bats-assert/assert.bash, line 61,
#  in test file tests/unit/bar.bats, line 17)
#   `assert_success' failed
TAP
  run _tap_bats_items_json "$WORK/tap.txt" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *'"file":"tests/unit/bar.bats"'* ]]
  [[ "$output" == *'"reason":"line 17: assert_success"'* ]]
}

@test "parse: PROJECT_ROOT is stripped from an absolute bats path" {
  cat > "$WORK/tap.txt" <<TAP
1..1
not ok 1 my test
# (in test file /Users/dev/myproject/tests/e2e/x.bats, line 5)
#   \`run cmd' failed
TAP
  run _tap_bats_items_json "$WORK/tap.txt" "/Users/dev/myproject"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"file":"tests/e2e/x.bats"'* ]]
  [[ "$output" != *'"/Users/dev/myproject'* ]]
}

@test "parse: a bats TAP line with no location comment keeps file=bats and default reason" {
  cat > "$WORK/tap.txt" <<'TAP'
1..1
not ok 1 plain bats test with no comment
TAP
  run _tap_bats_items_json "$WORK/tap.txt" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *'"file":"bats"'* ]]
  [[ "$output" == *'"reason":"assertion failed"'* ]]
  [[ "$output" == *'"test_name":"plain bats test with no comment"'* ]]
}

@test "parse: location comment under a flake-flipped ok line is ignored" {
  cat > "$WORK/tap.txt" <<'TAP'
1..2
ok 1 cleared by flake retry
# (in test file tests/regression/flaked.bats, line 10)
#   `run foo' failed
not ok 2 still failing test
# (in test file tests/regression/real.bats, line 20)
#   `assert_output bar' failed
TAP
  run _tap_bats_items_json "$WORK/tap.txt" ""
  [ "$status" -eq 0 ]
  # Only one item — the ok line is ignored
  [[ "$output" == *'"file":"tests/regression/real.bats"'* ]]
  [[ "$output" != *'"file":"tests/regression/flaked.bats"'* ]]
}

@test "parse: multiple failures each carry their own file and line" {
  cat > "$WORK/tap.txt" <<'TAP'
1..2
not ok 1 first test
# (in test file tests/regression/a.bats, line 7)
#   `[ "$x" = "y" ]' failed
not ok 2 second test
# (in test file tests/regression/b.bats, line 33)
#   `assert_equal "$actual" "expected"' failed
TAP
  run _tap_bats_items_json "$WORK/tap.txt" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *'"file":"tests/regression/a.bats"'* ]]
  [[ "$output" == *'"file":"tests/regression/b.bats"'* ]]
  [[ "$output" == *'"reason":"line 7:'* ]]
  [[ "$output" == *'"reason":"line 33:'* ]]
}

# ---------------------------------------------------------------------------
# fix items via _build_gate_prepend_items
# ---------------------------------------------------------------------------

@test "fix item: bats finding with real path uses 'bats failure' header and names the file" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  printf '%s\n' '{"exit_code":1,"lint":[],"tests":[{"file":"tests/regression/foo.bats","test_name":"my failing test","reason":"line 42: assert_equal \"$x\" \"y\""}]}' > "$WORK/gate.json"
  _build_items "$WORK/gate.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'### [GATE] bats failure: my failing test - ACTIONABLE_NOW'* ]]
  [[ "$output" == *'**Location:** tests/regression/foo.bats'* ]]
  [[ "$output" == *'**Reason:** line 42: assert_equal'* ]]
  [[ "$output" == *'`bats -r tests/` (post-commit gate) reported this failure'* ]]
  [[ "$output" == *'Location is the test file; Reason is the line and failed assertion'* ]]
  [[ "$output" == *'COUNT:1'* ]]
}
