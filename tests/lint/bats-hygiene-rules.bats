#!/usr/bin/env bats
# sharkrite-test-covers: tools/*-lint.sh
#
# Regression tests for the two bats-hygiene lint rules added after the
# 2026-07-01 not-run incident (failing tests swallowed to "not run" by the
# post-commit gate, four blind fix rounds on issue #804):
#
#   TRAP_EXIT_IN_BATS_TEST  — trap ... EXIT inside a @test body clobbers
#     bats' result-emitting EXIT trap; the test's result is silently dropped
#     ("Executed N instead of expected M tests"). Cleanup belongs in teardown().
#
#   BATS_SETUP_STRICT_LEAK  — setup()/setup_file() sourcing a lib file leaks
#     set -u / pipefail into the bats-exec-test shell; combined with
#     BATS_TEST_TIMEOUT the leaked flags kill bats-exec-test at its
#     timeout-countdown cleanup (bats-exec-test:263 kill without || true)
#     before the 'not ok' line is emitted. The guard `set +u; set +o pipefail`
#     must follow the source. (NOT `set +e` — bats' failure detection relies
#     on errexit; with it off a failing test reports ok.)

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LINT_SCRIPT="${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"
  TEST_REPO=$(mktemp -d)
  export TEST_REPO
  # Mirror the project structure the lint script expects
  mkdir -p "$TEST_REPO/tests/regression" "$TEST_REPO/tests/fixtures"
  mkdir -p "$TEST_REPO/lib/utils" "$TEST_REPO/tools"
  echo '#!/bin/bash' > "$TEST_REPO/lib/utils/foo.sh"
  # Speed: RITE_LINT_FILES restricts the SHELL_FILES rules (1-28) to a single
  # real file, so each `run bash "$LINT_SCRIPT"` costs well under a second.
  # The bats-scoped rules under test here (TRAP_EXIT_IN_BATS_TEST,
  # BATS_SETUP_STRICT_LEAK, like MISSING_TEST_COVERAGE_HEADER) use
  # `find tests ...` relative to cwd and are NOT affected by the filter.
  export RITE_LINT_FILES="${RITE_REPO_ROOT}/lib/utils/colors.sh"
}

teardown() {
  rm -rf "$TEST_REPO"
}

# Emit a representative bats test-opening line for a fixture file.
#
# CRITICAL: the '@test' token is produced via printf, never written literally
# at the start of a line in THIS file. bats' test discovery scans the source
# line-by-line for /^[[:space:]]*@test/ and does NOT understand heredocs — a
# literal '@test "fixture"' inside a fixture block here would be miscounted
# as a real test in this suite (see missing-test-coverage-header.bats for the
# original regression).
_emit_test_open() { printf '@test "%s" {\n' "${1:-fixture}"; }

# ---------------------------------------------------------------------------
# TRAP_EXIT_IN_BATS_TEST
# ---------------------------------------------------------------------------

@test "TRAP_EXIT_IN_BATS_TEST: flags trap ... EXIT inside a @test body" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    _emit_test_open "does cleanup wrong"
    echo '  _tmpdir=$(mktemp -d)'
    echo "  trap \"rm -rf '\$_tmpdir'\" EXIT"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/trap-in-test.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  echo "$output" | grep -q "TRAP_EXIT_IN_BATS_TEST"
  echo "$output" | grep -q "trap-in-test.bats:5 - TRAP_EXIT_IN_BATS_TEST"
}

@test "TRAP_EXIT_IN_BATS_TEST: does not flag trap in teardown()" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'teardown() {'
    echo '  trap - EXIT'
    echo '  rm -rf "$_tmpdir"'
    echo '}'
    _emit_test_open "clean"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/trap-in-teardown.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "trap-in-teardown.bats.*TRAP_EXIT_IN_BATS_TEST"
}

@test "TRAP_EXIT_IN_BATS_TEST: does not flag trap inside a heredoc fixture" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    _emit_test_open "writes a fixture script"
    echo "  cat > \"\$BATS_TEST_TMPDIR/fixture.sh\" <<'FIXTURE'"
    echo '#!/bin/bash'
    echo 'TMPDIR_LOCAL="$(mktemp -d)"'
    echo "trap 'rm -rf \"\$TMPDIR_LOCAL\"' EXIT"
    echo 'FIXTURE'
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/trap-in-heredoc.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "trap-in-heredoc.bats.*TRAP_EXIT_IN_BATS_TEST"
}

@test "TRAP_EXIT_IN_BATS_TEST: does not flag non-EXIT traps in @test bodies" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    _emit_test_open "signal handling"
    echo "  trap 'echo interrupted' INT TERM"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/trap-non-exit.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "trap-non-exit.bats.*TRAP_EXIT_IN_BATS_TEST"
}

@test "TRAP_EXIT_IN_BATS_TEST: suppression comment on preceding line is honored" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    _emit_test_open "suppressed"
    echo '  # sharkrite-lint disable TRAP_EXIT_IN_BATS_TEST - Reason: fixture string for a child shell'
    echo "  trap 'true' EXIT"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/trap-suppressed.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "trap-suppressed.bats.*TRAP_EXIT_IN_BATS_TEST"
}

# ---------------------------------------------------------------------------
# BATS_SETUP_STRICT_LEAK
# ---------------------------------------------------------------------------

@test "BATS_SETUP_STRICT_LEAK: flags setup() sourcing config.sh without a guard" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup() {'
    echo '  source "$RITE_LIB_DIR/utils/config.sh"'
    echo '}'
    _emit_test_open "leaky"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/setup-leak.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  echo "$output" | grep -q "BATS_SETUP_STRICT_LEAK"
  echo "$output" | grep -q "setup-leak.bats:4 - BATS_SETUP_STRICT_LEAK"
}

@test "BATS_SETUP_STRICT_LEAK: passes when guard follows the source" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup() {'
    echo '  source "${RITE_REPO_ROOT}/lib/utils/config.sh"'
    echo '  set +u; set +o pipefail  # bats needs its own error handling'
    echo '}'
    _emit_test_open "guarded"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/setup-guarded.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "setup-guarded.bats.*BATS_SETUP_STRICT_LEAK"
}

@test "BATS_SETUP_STRICT_LEAK: guard BEFORE the source does not count" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup() {'
    echo '  set +u  # too early: the source below re-enables strict mode'
    echo '  source "$RITE_LIB_DIR/utils/config.sh"'
    echo '}'
    _emit_test_open "guard too early"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/setup-guard-early.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  echo "$output" | grep -q "setup-guard-early.bats:5 - BATS_SETUP_STRICT_LEAK"
}

@test "BATS_SETUP_STRICT_LEAK: flags setup_file() too" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup_file() {'
    echo '  source "${RITE_LIB_DIR}/utils/config.sh"'
    echo '}'
    _emit_test_open "leaky file setup"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/setup-file-leak.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  echo "$output" | grep -q "setup-file-leak.bats:4 - BATS_SETUP_STRICT_LEAK"
}

@test "BATS_SETUP_STRICT_LEAK: does not flag source inside a heredoc fixture" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup() {'
    echo "  cat > \"\$BATS_TEST_TMPDIR/stub.sh\" <<'STUB'"
    echo '#!/bin/bash'
    echo 'source "$RITE_LIB_DIR/utils/config.sh"'
    echo 'STUB'
    echo '}'
    _emit_test_open "fixture writer"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/setup-heredoc.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "setup-heredoc.bats.*BATS_SETUP_STRICT_LEAK"
}

@test "BATS_SETUP_STRICT_LEAK: does not flag non-lib sources (helpers)" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup() {'
    echo '  source "${RITE_REPO_ROOT}/tests/helpers/setup.bash"'
    echo '  setup_test_tmpdir'
    echo '}'
    _emit_test_open "helper user"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/setup-helper.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "setup-helper.bats.*BATS_SETUP_STRICT_LEAK"
}

@test "BATS_SETUP_STRICT_LEAK: does not flag sources inside @test bodies" {
  # Scope is setup()/setup_file() only — a leak from a source inside one @test
  # affects only that test, and the sweep/rule deliberately target the shared
  # setup path that poisons every test in the file.
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    _emit_test_open "sources inline"
    echo '  source "$RITE_LIB_DIR/utils/config.sh"'
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/test-body-source.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "test-body-source.bats.*BATS_SETUP_STRICT_LEAK"
}

@test "BATS_SETUP_STRICT_LEAK: suppression comment on preceding line is honored" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup() {'
    echo '  # sharkrite-lint disable BATS_SETUP_STRICT_LEAK - Reason: intentionally testing leaked flags'
    echo '  source "$RITE_LIB_DIR/utils/config.sh"'
    echo '}'
    _emit_test_open "suppressed leak"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/setup-suppressed.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "setup-suppressed.bats.*BATS_SETUP_STRICT_LEAK"
}
