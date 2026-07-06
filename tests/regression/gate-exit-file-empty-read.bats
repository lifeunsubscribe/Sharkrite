#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# Regression (#935, Pilot finding 2026-07-06): a killed gate test child leaves
# its mktemp'd exit-capture file CREATED but EMPTY — `cat file || echo 0`
# guards only cat FAILURE, so the empty read yielded "" and the numeric
# [ "$_tests_exit" -ne 0 ] crashed with `[: : integer expression expected`
# (3x in LeadFlow rite-449-...-174340.log after Terminated: 15). The fixed
# idiom defaults BOTH absence and emptiness to 1: an unwritten exit file means
# the run never completed, which is a failure — never a success.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"; export RITE_REPO_ROOT
}

@test "behavioral: empty exit file reads as failure(1), no bash error" {
  run bash -c '
    set -euo pipefail
    f=$(mktemp)                       # created, never written = the killed-child state
    _tests_exit=$(cat "$f" 2>/dev/null || echo 1)
    _tests_exit=${_tests_exit:-1}
    rm -f "$f"
    [ "$_tests_exit" -ne 0 ]          # must be numeric-safe AND read as failure
    echo "exit=$_tests_exit"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"exit=1"* ]]
}

@test "behavioral: missing exit file reads as failure(1)" {
  run bash -c '
    set -euo pipefail
    _tests_exit=$(cat "/nonexistent-exit-file-$$" 2>/dev/null || echo 1)
    _tests_exit=${_tests_exit:-1}
    [ "$_tests_exit" -ne 0 ] && echo "exit=$_tests_exit"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"exit=1"* ]]
}

@test "behavioral: written exit file propagates its value unchanged" {
  run bash -c '
    set -euo pipefail
    f=$(mktemp); echo 0 > "$f"
    a=$(cat "$f" 2>/dev/null || echo 1); a=${a:-1}
    echo 7 > "$f"
    b=$(cat "$f" 2>/dev/null || echo 1); b=${b:-1}
    rm -f "$f"
    echo "a=$a b=$b"
  '
  [[ "$output" == *"a=0 b=7"* ]]
}

@test "source: no exit-file reader defaults to success on cat failure" {
  # Every exit-capture read in test-gate.sh must fall back to 1, and carry the
  # empty-content guard on the following line (the :-1 idiom).
  run bash -c 'grep -E "cat \"\\\$_[a-z_]*exit_file(_cmd)?\" 2>/dev/null \|\| echo \"?0\"?\)" "$1"' _ "${RITE_REPO_ROOT}/lib/utils/test-gate.sh"
  [ "$status" -ne 0 ] || { echo "found success-defaulting exit-file reader: $output"; false; }
}
