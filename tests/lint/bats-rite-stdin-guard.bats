#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/37-bats-rite-invocation-needs-dev-null-stdin.sh, tools/sharkrite-lint.sh
#
# Regression test for the BATS_RITE_STDIN_GUARD lint rule (Rule 37).
# A .bats test that executes the real bin/rite (directly or via a symlink)
# without `< /dev/null` can hang the gate to its 1800s watchdog under --jobs 8
# (a rite child grabs the tty, SIGTTIN stops the process group — the rite-804 /
# #1031 freeze). The rule flags command-position `bash …/rite` invocations that
# lack the guard; comments, string assertions, piped stdin, and suppression are
# exempt.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LINT_SCRIPT="${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"
  TEST_REPO=$(mktemp -d)
  export TEST_REPO
  mkdir -p "$TEST_REPO/tests/regression" "$TEST_REPO/tests/helpers" "$TEST_REPO/tests/fixtures"
  mkdir -p "$TEST_REPO/lib/utils" "$TEST_REPO/tools" "$TEST_REPO/bin"
  echo '#!/bin/bash' > "$TEST_REPO/lib/utils/foo.sh"
}

teardown() { rm -rf "$TEST_REPO"; }

_emit_test_line() { printf '@test "%s" { true; }\n' "${1:-fixture}"; }
_run_rule37() {
  ( cd "$TEST_REPO" && bash "$LINT_SCRIPT" 2>&1 ) | grep 'BATS_RITE_STDIN_GUARD' || true
}

@test "BATS_RITE_STDIN_GUARD: flags an unguarded run bash …/bin/rite" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: bin/rite'
    printf '@test "x" {\n  run bash "$RITE_REPO_ROOT/bin/rite" --help\n}\n'
  } > "$TEST_REPO/tests/regression/bad.bats"
  run _run_rule37
  [ -n "$output" ]
  [[ "$output" == *"bad.bats"* ]]
}

@test "BATS_RITE_STDIN_GUARD: passes when < /dev/null is present" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: bin/rite'
    printf '@test "x" {\n  run bash "$RITE_REPO_ROOT/bin/rite" --help < /dev/null\n}\n'
  } > "$TEST_REPO/tests/regression/good.bats"
  run _run_rule37
  [ -z "$output" ]
}

@test "BATS_RITE_STDIN_GUARD: flags a symlinked fake-bin rite invocation too" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: bin/rite'
    printf '@test "x" {\n  run bash "$_fake_bin/rite" --full-suite\n}\n'
  } > "$TEST_REPO/tests/regression/symlink.bats"
  run _run_rule37
  [[ "$output" == *"symlink.bats"* ]]
}

@test "BATS_RITE_STDIN_GUARD: piped stdin is exempt (not a tty)" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: bin/rite'
    printf '@test "x" {\n  echo hi | bash "$RITE_REPO_ROOT/bin/rite" plan\n}\n'
  } > "$TEST_REPO/tests/regression/piped.bats"
  run _run_rule37
  [ -z "$output" ]
}

@test "BATS_RITE_STDIN_GUARD: a comment mentioning bash bin/rite is not an execution" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: bin/rite'
    printf '@test "x" {\n  # example: bash "$RITE_REPO_ROOT/bin/rite" --help\n  true\n}\n'
  } > "$TEST_REPO/tests/regression/comment.bats"
  run _run_rule37
  [ -z "$output" ]
}

@test "BATS_RITE_STDIN_GUARD: a string assertion mentioning rite is not flagged" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: bin/rite'
    printf '@test "x" {\n  [[ "$output" == *"bash /x/bin/rite ran"* ]]\n}\n'
  } > "$TEST_REPO/tests/regression/assert.bats"
  run _run_rule37
  [ -z "$output" ]
}

@test "BATS_RITE_STDIN_GUARD: inline suppression on the preceding line silences it" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: bin/rite'
    printf '@test "x" {\n  # sharkrite-lint disable BATS_RITE_STDIN_GUARD - Reason: feeds interactive input\n  run bash "$RITE_REPO_ROOT/bin/rite" --supervised\n}\n'
  } > "$TEST_REPO/tests/regression/suppressed.bats"
  run _run_rule37
  [ -z "$output" ]
}
