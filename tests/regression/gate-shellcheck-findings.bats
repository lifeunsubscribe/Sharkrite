#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-verdict.sh::_gate_build_verdict, lib/utils/gate-verdict.sh, Makefile

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: gate-verdict.sh uses a function-sentinel guard (declare -f _gate_write_json); pre-source _diag() stub is preserved on source.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/gate-verdict.sh"
  set +u; set +o pipefail
}

# ─── Unit: _parse_lint_line handles shellcheck gcc format ─────────────────────

@test "_parse_lint_line: parses shellcheck gcc format violation" {
  # gcc format: file:line:col: level: message [SCnnnn]
  run _parse_lint_line "lib/core/docs-command.sh:42:3: warning: In POSIX sh, trap argument should be a simple string. [SC2064]"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -q '"rule":"SC2064"'
  echo "$output" | grep -q '"file":"lib/core/docs-command.sh"'
  echo "$output" | grep -q '"line":"42"'
}

@test "_parse_lint_line: returns non-zero for non-shellcheck lines" {
  run _parse_lint_line "Running shellcheck..."
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_parse_lint_line: still parses custom-lint format" {
  run _parse_lint_line "lib/bar.sh:88: [BARE_MARKER_GREP] Unanchored marker grep"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -q '"rule":"BARE_MARKER_GREP"'
}

# ─── Integration: full gate emits lint findings from shellcheck failure ────────

@test "gate: shellcheck gcc violation produces lint[] finding with SC code, file, line" {
  # Converted (issue #1241): pre-built lint raw output — no stub make/bats/git.
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf 'lib/core/docs-command.sh:42:3: warning: In POSIX sh, trap argument should be a simple string. [SC2064]\n' \
    > "$_lint_raw"
  printf 'TAP version 13\n1..1\nok 1 stub\n' > "$_tests_raw"

  _rc=0; _gate_build_verdict "$_lint_raw" "$_tests_raw" 1 0 "$_out" "" "" || _rc=$?
  [ "$_rc" -eq 1 ]

  # lint[] must contain at least one item with SC2064
  run jq -r '.lint | length' "$_out"
  [ "$output" -ge 1 ]

  run jq -r '.lint[0].rule' "$_out"
  [ "$output" = "SC2064" ]

  run jq -r '.lint[0].file' "$_out"
  [ "$output" = "lib/core/docs-command.sh" ]

  run jq -r '.lint[0].line' "$_out"
  [ "$output" = "42" ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

@test "gate: lint_count in TEST_GATE diag counts shellcheck violations" {
  # Converted (issue #1241): pre-built lint raw output with 2 violations.
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf 'lib/a.sh:10:1: warning: message one [SC2064]\nlib/b.sh:20:1: warning: message two [SC2064]\n' \
    > "$_lint_raw"
  printf 'TAP version 13\n1..1\nok 1 stub\n' > "$_tests_raw"

  _gate_build_verdict "$_lint_raw" "$_tests_raw" 1 0 "$_out" "" "" || true

  run jq -r '.lint | length' "$_out"
  [ "$output" -eq 2 ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

@test "gate: zero shellcheck violations leaves lint[] empty" {
  # Converted (issue #1241): empty lint raw output — no stub make/bats/git.
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  printf 'TAP version 13\n1..1\nok 1 stub\n' > "$_tests_raw"

  _rc=0; _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 0 "$_out" "" "" || _rc=$?
  [ "$_rc" -eq 0 ]

  run jq -r '.lint | length' "$_out"
  [ "$output" -eq 0 ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}
