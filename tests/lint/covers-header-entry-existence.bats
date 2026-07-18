#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/25-bats-files-must-declare-test-coverage-via-sh.sh, tools/sharkrite-lint.sh
#
# Regression test for the STALE_TEST_COVERAGE_ENTRY lint rule (#1023 / Rule 36).
# A covers-header entry naming a source that does not exist (renamed, deleted,
# or a typo) is a silent coverage hole: the gate can never select the test on
# that path. The rule flags non-glob entries that do not resolve to a real file;
# glob entries are exempt; inline suppression is honored.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LINT_SCRIPT="${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"
  TEST_REPO=$(mktemp -d)
  export TEST_REPO
  mkdir -p "$TEST_REPO/tests/regression" "$TEST_REPO/tests/helpers" "$TEST_REPO/tests/fixtures"
  mkdir -p "$TEST_REPO/lib/core" "$TEST_REPO/lib/utils" "$TEST_REPO/tools"
  # A real source the fixtures can legitimately claim to cover.
  echo '#!/bin/bash' > "$TEST_REPO/lib/core/real.sh"
  echo '#!/bin/bash' > "$TEST_REPO/lib/utils/other.sh"
}

teardown() { rm -rf "$TEST_REPO"; }

# @test lines built via printf so bats' line-based discovery never miscounts the
# fixture bodies as real tests in THIS suite (the #481 phantom-test trap).
_emit_test_line() { printf '@test "%s" { true; }\n' "${1:-fixture}"; }

# Run the driver in the TEST_REPO and return only Rule 36's lines.
_run_rule36() {
  ( cd "$TEST_REPO" && bash "$LINT_SCRIPT" 2>&1 ) | grep 'STALE_TEST_COVERAGE_ENTRY' || true
}

@test "STALE_TEST_COVERAGE_ENTRY: flags a covers entry that does not exist on disk" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/core/does-not-exist.sh'
    _emit_test_line
  } > "$TEST_REPO/tests/regression/ghost.bats"
  run _run_rule36
  [ -n "$output" ]
  [[ "$output" == *"does-not-exist.sh"* ]]
  [[ "$output" == *"ghost.bats"* ]]
}

@test "STALE_TEST_COVERAGE_ENTRY: passes when every entry exists" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/core/real.sh, lib/utils/other.sh'
    _emit_test_line
  } > "$TEST_REPO/tests/regression/good.bats"
  run _run_rule36
  [ -z "$output" ]
}

@test "STALE_TEST_COVERAGE_ENTRY: one bad entry among good ones is flagged" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/core/real.sh, lib/core/renamed-away.sh'
    _emit_test_line
  } > "$TEST_REPO/tests/regression/mixed.bats"
  run _run_rule36
  [[ "$output" == *"renamed-away.sh"* ]]
  [[ "$output" != *"real.sh"* ]]
}

@test "STALE_TEST_COVERAGE_ENTRY: glob entries are exempt (never resolved)" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/*.sh, lib/**'
    _emit_test_line
  } > "$TEST_REPO/tests/regression/globby.bats"
  run _run_rule36
  [ -z "$output" ]
}

@test "STALE_TEST_COVERAGE_ENTRY: inline suppression on the preceding line silences it" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-lint disable STALE_TEST_COVERAGE_ENTRY - Reason: path generated at runtime'
    echo '# sharkrite-test-covers: lib/core/generated-later.sh'
    _emit_test_line
  } > "$TEST_REPO/tests/regression/suppressed.bats"
  run _run_rule36
  [ -z "$output" ]
}

@test "STALE_TEST_COVERAGE_ENTRY: helpers/ and fixtures/ are not scanned" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/core/nope.sh'
    _emit_test_line
  } > "$TEST_REPO/tests/helpers/helper.bats"
  run _run_rule36
  [ -z "$output" ]
}
