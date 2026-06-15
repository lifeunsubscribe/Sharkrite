#!/usr/bin/env bats
# sharkrite-test-covers: tools/*-lint.sh
#
# Regression test for the MISSING_TEST_COVERAGE_HEADER lint rule.
# After PR #480 backfilled covers headers on all 142 bats files and
# the gate's default flipped (headerless = skipped), this rule enforces
# that every new bats file declares coverage so future tests participate
# in targeted selection.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LINT_SCRIPT="${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"
  TEST_REPO=$(mktemp -d)
  export TEST_REPO
  # Mirror the project structure the lint script expects
  mkdir -p "$TEST_REPO/tests/regression" "$TEST_REPO/tests/helpers" "$TEST_REPO/tests/fixtures"
  mkdir -p "$TEST_REPO/lib/utils" "$TEST_REPO/tools"
  # Minimal lib files so the lint script's other rules don't crash
  echo '#!/bin/bash' > "$TEST_REPO/lib/utils/foo.sh"
  echo '#!/bin/bash' > "$TEST_REPO/tools/example-lint.sh"
}

teardown() {
  rm -rf "$TEST_REPO"
}

# Emit a representative bats test line for a fixture file.
#
# CRITICAL: the '@test' token is produced via printf, never written literally
# at the start of a line in THIS file. bats' test discovery scans the source
# line-by-line for /^[[:space:]]*@test/ and does NOT understand heredocs — so a
# literal '@test "fixture"' inside a fixture heredoc here gets miscounted as a
# real test in this suite. The previous version had four such lines, all named
# "fixture", which made bats abort the entire run with "Duplicate test name(s)"
# and broke `make test` (regression from #481, 2026-06-08). Building the line
# with printf keeps the WRITTEN fixture fully representative (it really contains
# `@test "fixture" { true; }`) while emitting zero phantom tests in this suite.
_emit_test_line() { printf '@test "%s" { true; }\n' "${1:-fixture}"; }

@test "MISSING_TEST_COVERAGE_HEADER: flags a bats file without the header" {
  {
    echo '#!/usr/bin/env bats'
    _emit_test_line
  } > "$TEST_REPO/tests/regression/no-header.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  echo "$output" | grep -q "MISSING_TEST_COVERAGE_HEADER"
  echo "$output" | grep -q "no-header.bats"
}

@test "MISSING_TEST_COVERAGE_HEADER: passes when header is present" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    _emit_test_line
  } > "$TEST_REPO/tests/regression/with-header.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "MISSING_TEST_COVERAGE_HEADER.*with-header.bats"
}

@test "MISSING_TEST_COVERAGE_HEADER: skips tests/helpers/ (support files)" {
  {
    echo '#!/usr/bin/env bats'
    _emit_test_line helper
  } > "$TEST_REPO/tests/helpers/helper.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "MISSING_TEST_COVERAGE_HEADER.*tests/helpers/helper.bats"
}

@test "MISSING_TEST_COVERAGE_HEADER: skips tests/fixtures/ (support files)" {
  {
    echo '#!/usr/bin/env bats'
    _emit_test_line
  } > "$TEST_REPO/tests/fixtures/fixture.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "MISSING_TEST_COVERAGE_HEADER.*tests/fixtures/fixture.bats"
}

@test "MISSING_TEST_COVERAGE_HEADER: accepts header in first 5 lines" {
  {
    echo '#!/usr/bin/env bats'
    echo '# Some leading comment'
    echo '#'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    _emit_test_line
  } > "$TEST_REPO/tests/regression/header-line-4.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "MISSING_TEST_COVERAGE_HEADER.*header-line-4.bats"
}
