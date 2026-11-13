#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-verdict.sh::_gate_runner_excerpt|_gate_write_json|_gate_build_verdict, lib/core/assess-and-resolve.sh
#
# Live (freshup #549, 2026-11-12): the gate failed on `error TS6133 ... declared
# but never read`, the verdict had no parseable findings, and the fix session
# was handed "[GATE] gate failure: non-zero exit with no parseable findings" +
# "investigate why the test runner produced no parseable output". Two rounds
# (~16 min) for one unused variable. Contract: when tests fail with nothing
# parseable, the verdict carries the runner's error lines (`excerpt`) and the
# synthesized [GATE] item quotes them.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "$RITE_LIB_DIR/utils/gate-verdict.sh"
  set +u; set +o pipefail
  T="$BATS_TEST_TMPDIR"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
}

_tsc_output() {
  cat > "$1" <<'OUT'
> frontend@0.0.0 test
> bash /Users/x/scripts/rite-test.sh
backend: 1866 passed in 61.2s
frontend/src/pages/RecipeDetail.tsx(42,9): error TS6133: 'sessionOfferDismissed' is declared but its value is never read.
tsc failed
OUT
}

@test "_gate_runner_excerpt prefers error lines and returns a JSON string" {
  _tsc_output "$T/raw.txt"
  run _gate_runner_excerpt "$T/raw.txt"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "string"' >/dev/null
  [[ "$(echo "$output" | jq -r .)" == *"error TS6133"* ]]
  [[ "$(echo "$output" | jq -r .)" == *"tsc failed"* ]]
  [[ "$(echo "$output" | jq -r .)" != *"1866 passed"* ]]
}

@test "_gate_runner_excerpt falls back to the tail when no line names an error; empty file yields nothing" {
  printf 'line a\nline b\nline c\n' > "$T/plain.txt"
  run _gate_runner_excerpt "$T/plain.txt"
  [[ "$(echo "$output" | jq -r .)" == *"line c"* ]]
  : > "$T/empty.txt"
  run _gate_runner_excerpt "$T/empty.txt"
  [ -z "$output" ]
}

@test "_gate_build_verdict: unparseable test failure carries .excerpt; parseable TAP failure does not" {
  : > "$T/lint.txt"
  _tsc_output "$T/tests.txt"
  _gate_build_verdict "$T/lint.txt" "$T/tests.txt" 0 2 "$T/gate.json" "" "abc1234" || true
  [ "$(jq -r '.exit_code' "$T/gate.json")" = "1" ]
  [ "$(jq -r '.tests | length' "$T/gate.json")" = "0" ]
  [[ "$(jq -r '.excerpt' "$T/gate.json")" == *"error TS6133"* ]]
  [ "$(jq -r '.head_sha' "$T/gate.json")" = "abc1234" ]
  printf 'not ok 1 renders the thing\n# (in test file x.bats, line 3)\n' > "$T/tap.txt"
  _gate_build_verdict "$T/lint.txt" "$T/tap.txt" 0 1 "$T/gate2.json" "" "abc1234" || true
  [ "$(jq -r '.tests | length' "$T/gate2.json")" = "1" ]
  [ "$(jq -r '.excerpt // "none"' "$T/gate2.json")" = "none" ]
}

@test "_gate_write_json: skipped, reason+sha, reason-only, sha-only and plain shapes are unchanged; excerpt appends" {
  _gate_write_json "$T/a.json" "[]" "[]" 0 true missing_deps
  [ "$(jq -c . "$T/a.json")" = '{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"missing_deps"}' ]
  _gate_write_json "$T/b.json" "[]" "[]" 1 false runner_unavailable deadbeef
  [ "$(jq -c . "$T/b.json")" = '{"lint":[],"tests":[],"exit_code":1,"reason":"runner_unavailable","head_sha":"deadbeef"}' ]
  _gate_write_json "$T/c.json" "[]" "[]" 1 false runner_unavailable
  [ "$(jq -c . "$T/c.json")" = '{"lint":[],"tests":[],"exit_code":1,"reason":"runner_unavailable"}' ]
  _gate_write_json "$T/d.json" "[]" "[]" 0 false "" deadbeef
  [ "$(jq -c . "$T/d.json")" = '{"lint":[],"tests":[],"exit_code":0,"head_sha":"deadbeef"}' ]
  _gate_write_json "$T/e.json" "[]" "[]" 0
  [ "$(jq -c . "$T/e.json")" = '{"lint":[],"tests":[],"exit_code":0}' ]
  _gate_write_json "$T/f.json" "[]" "[]" 1 false "" "" '"error TS6133: x"'
  [ "$(jq -r '.excerpt' "$T/f.json")" = "error TS6133: x" ]
}

@test "source: the synthesized [GATE] item quotes the excerpt" {
  _blk=$(sed -n '/_gate_failure_desc="gate failure: non-zero exit/,/GATE_NOW_COUNT=\$(( GATE_NOW_COUNT + 1 ))/p' "$RITE_LIB_DIR/core/assess-and-resolve.sh")
  [[ "$_blk" == *'.excerpt // ""'* ]]
  [[ "$_blk" == *'Runner output (error lines, verbatim)'* ]]
  [[ "$_blk" == *'${_gate_excerpt_block}'* ]]
}
