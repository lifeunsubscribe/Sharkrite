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

# ---------------------------------------------------------------------------
# BATS_STUB_OVERWRITE
# ---------------------------------------------------------------------------

@test "BATS_STUB_OVERWRITE: flags gh_safe stub defined before source of transitive loader without re-stub" {
  # The canonical failure: a pre-source gh_safe() stub is silently overwritten
  # by gh-retry.sh's unconditional function definition when workflow-runner.sh
  # is sourced. Without a re-stub the real gh_safe queries live GitHub.
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup() {'
    echo '  gh_safe() { echo "stub"; }'
    echo '  source "$RITE_LIB_DIR/core/workflow-runner.sh"'
    echo '}'
    _emit_test_open "stub missing re-stub"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/stub-overwrite-bad.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  echo "$output" | grep -q "BATS_STUB_OVERWRITE"
  echo "$output" | grep -q "stub-overwrite-bad.bats:4 - BATS_STUB_OVERWRITE"
}

@test "BATS_STUB_OVERWRITE: passes when gh_safe is re-stubbed after source" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup() {'
    echo '  gh_safe() { echo "stub"; }'
    echo '  source "$RITE_LIB_DIR/core/workflow-runner.sh"'
    echo '  # Re-stub AFTER source: gh-retry.sh overwrites the pre-source stub'
    echo '  gh_safe() { echo "re-stub"; }'
    echo '}'
    _emit_test_open "correctly re-stubbed"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/stub-overwrite-good.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "stub-overwrite-good.bats.*BATS_STUB_OVERWRITE"
}

@test "BATS_STUB_OVERWRITE: does not flag gh_safe stub defined only after source" {
  # A stub defined only after source is correct (no pre-source stub at all)
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup() {'
    echo '  source "$RITE_LIB_DIR/core/workflow-runner.sh"'
    echo '  gh_safe() { echo "post-stub only"; }'
    echo '}'
    _emit_test_open "post-stub only"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/stub-overwrite-post-only.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "stub-overwrite-post-only.bats.*BATS_STUB_OVERWRITE"
}

@test "BATS_STUB_OVERWRITE: does not flag gh_safe stub in a bats file with no lib source" {
  # A bats file that defines gh_safe() but never sources a transitive loader
  # has no overwrite risk.
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup() {'
    echo '  gh_safe() { echo "stub"; }'
    echo '}'
    _emit_test_open "no lib source"
    echo '  run gh_safe pr view 1'
    echo '  [ "$status" -eq 0 ]'
    echo '}'
  } > "$TEST_REPO/tests/regression/stub-overwrite-no-source.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "stub-overwrite-no-source.bats.*BATS_STUB_OVERWRITE"
}

@test "BATS_STUB_OVERWRITE: does not flag gh_safe stub inside a heredoc fixture" {
  # A gh_safe() definition inside a heredoc is fixture content — it's part of
  # a child script, not a bats-level stub that gets overwritten at source time.
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    _emit_test_open "fixture writer"
    printf "  cat > \"\$BATS_TEST_TMPDIR/harness.sh\" <<'EOF'\n"
    echo '#!/bin/bash'
    echo 'gh_safe() { echo "harness stub"; }'
    echo 'source "$RITE_LIB_DIR/core/workflow-runner.sh"'
    echo 'EOF'
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/stub-overwrite-heredoc.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "stub-overwrite-heredoc.bats.*BATS_STUB_OVERWRITE"
}

@test "BATS_STUB_OVERWRITE: suppression comment on preceding line is honored" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup() {'
    echo '  # sharkrite-lint disable BATS_STUB_OVERWRITE - Reason: gh-retry.sh is itself the file under test'
    echo '  gh_safe() { echo "stub"; }'
    echo '  source "$RITE_LIB_DIR/core/workflow-runner.sh"'
    echo '}'
    _emit_test_open "suppressed"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/stub-overwrite-suppressed.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "stub-overwrite-suppressed.bats.*BATS_STUB_OVERWRITE"
}

@test "BATS_STUB_OVERWRITE: flags when source is gh-retry.sh directly" {
  # Direct source of gh-retry.sh also overwrites any pre-stub
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup() {'
    echo '  gh_safe() { echo "stub"; }'
    echo '  source "$RITE_LIB_DIR/utils/gh-retry.sh"'
    echo '}'
    _emit_test_open "direct gh-retry source"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/stub-overwrite-direct.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  echo "$output" | grep -q "BATS_STUB_OVERWRITE"
  echo "$output" | grep -q "stub-overwrite-direct.bats:4 - BATS_STUB_OVERWRITE"
}

# ---------------------------------------------------------------------------
# BATS_FILE_SCOPE_ENV_READ
# ---------------------------------------------------------------------------

@test "BATS_FILE_SCOPE_ENV_READ: flags file-scope assignment reading RITE_LIB_DIR" {
  # The _WORKFLOW_FILE landmine: file-scope code reading $RITE_LIB_DIR is
  # evaluated at bats load time, before setup() runs — RITE_LIB_DIR may be
  # unset or stale at that point.
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'WORKFLOW_FILE="$RITE_LIB_DIR/core/claude-workflow.sh"'
    echo 'setup() { true; }'
    _emit_test_open "uses file-scope var"
    echo '  [ -n "$WORKFLOW_FILE" ]'
    echo '}'
  } > "$TEST_REPO/tests/regression/file-scope-env-bad.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  echo "$output" | grep -q "BATS_FILE_SCOPE_ENV_READ"
  echo "$output" | grep -q "file-scope-env-bad.bats:3 - BATS_FILE_SCOPE_ENV_READ"
}

@test "BATS_FILE_SCOPE_ENV_READ: flags file-scope assignment reading RITE_PROJECT_ROOT" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'DATA_DIR="${RITE_PROJECT_ROOT}/.rite"'
    _emit_test_open "reads RITE_PROJECT_ROOT at file scope"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/file-scope-env-root.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  echo "$output" | grep -q "BATS_FILE_SCOPE_ENV_READ"
  echo "$output" | grep -q "file-scope-env-root.bats:3 - BATS_FILE_SCOPE_ENV_READ"
}

@test "BATS_FILE_SCOPE_ENV_READ: passes for file-scope assignment using BATS_TEST_FILENAME" {
  # BATS_* vars are bats-provided at parse time — safe for file-scope use
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"'
    echo 'WORKFLOW_RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"'
    _emit_test_open "uses bats-provided var"
    echo '  [ -n "$REPO_ROOT" ]'
    echo '}'
  } > "$TEST_REPO/tests/regression/file-scope-env-bats.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "file-scope-env-bats.bats.*BATS_FILE_SCOPE_ENV_READ"
}

@test "BATS_FILE_SCOPE_ENV_READ: does not flag RITE_* reads inside setup()" {
  # Inside setup() is depth > 0 — not file scope, always safe
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo 'setup() {'
    echo '  WORKFLOW_FILE="${RITE_LIB_DIR}/core/claude-workflow.sh"'
    echo '  export WORKFLOW_FILE'
    echo '}'
    _emit_test_open "reads RITE_ inside setup"
    echo '  [ -n "$WORKFLOW_FILE" ]'
    echo '}'
  } > "$TEST_REPO/tests/regression/file-scope-env-in-setup.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "file-scope-env-in-setup.bats.*BATS_FILE_SCOPE_ENV_READ"
}

@test "BATS_FILE_SCOPE_ENV_READ: does not flag RITE_* reads inside a @test body" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    _emit_test_open "reads RITE_ inside test"
    echo '  WORKFLOW_FILE="$RITE_LIB_DIR/core/claude-workflow.sh"'
    echo '  [ -n "$WORKFLOW_FILE" ]'
    echo '}'
  } > "$TEST_REPO/tests/regression/file-scope-env-in-test.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "file-scope-env-in-test.bats.*BATS_FILE_SCOPE_ENV_READ"
}

@test "BATS_FILE_SCOPE_ENV_READ: does not flag RITE_* inside a heredoc fixture at file scope" {
  # Heredoc content is fixture code — not bats-shell file-scope assignments
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    _emit_test_open "writes fixture at file scope"
    printf "  cat > \"\$BATS_TEST_TMPDIR/stub.sh\" <<'EOF'\n"
    echo 'RITE_LIB_DIR="/dev/null/stub"'
    echo 'EOF'
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/file-scope-env-heredoc.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "file-scope-env-heredoc.bats.*BATS_FILE_SCOPE_ENV_READ"
}

@test "BATS_FILE_SCOPE_ENV_READ: suppression comment on preceding line is honored" {
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/utils/foo.sh'
    echo '# sharkrite-lint disable BATS_FILE_SCOPE_ENV_READ - Reason: RITE_LIB_DIR is guaranteed set by the test harness before bats loads this file'
    echo 'WORKFLOW_FILE="$RITE_LIB_DIR/core/claude-workflow.sh"'
    _emit_test_open "suppressed"
    echo '  true'
    echo '}'
  } > "$TEST_REPO/tests/regression/file-scope-env-suppressed.bats"
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "file-scope-env-suppressed.bats.*BATS_FILE_SCOPE_ENV_READ"
}

# ---------------------------------------------------------------------------
# Targeted-gate early-exit regression (bats-only RITE_LINT_FILES)
# ---------------------------------------------------------------------------
#
# Regression for the issue where the early-exit guard at tools/sharkrite-lint.sh
# (the SHELL_FILES empty-intersection check) fired before Rules 34/35 got a
# chance to run when RITE_LINT_FILES contained ONLY .bats file paths.  The fix
# pre-computes the bats intersection and gates the early-exit on BOTH being empty.
#
# Strategy: set RITE_LINT_FILES to a single real .bats file from the actual
# project tests/ directory.  Before the fix this caused exit 0 with
# "no in-scope shell files ... skipping"; after the fix lint proceeds and
# emits "targeted scope" (Rules 34/35 run their bats scan, finding 0 violations
# in a clean file).
@test "early-exit guard does not fire when RITE_LINT_FILES contains only a .bats file" {
  # Pick a real bats file from the project under test.  Any clean file will do;
  # we use THIS test file — it's guaranteed to exist and to be violation-free
  # for BATS_STUB_OVERWRITE and BATS_FILE_SCOPE_ENV_READ (it has no gh_safe
  # pre-source stubs and no file-scope RITE_* reads).
  _this_bats_file="${BATS_TEST_FILENAME}"
  # Run from the real project root so SHELL_FILES (bin/lib/tools) is populated
  # but RITE_LINT_FILES has no shell-file intersection — only the .bats path.
  run env RITE_LINT_FILES="$_this_bats_file" bash "$LINT_SCRIPT"
  # Must NOT exit with the "skipping" short-circuit message.
  ! echo "$output" | grep -q "no in-scope shell files in targeted set"
  # Must reach the "targeted scope" or completion path instead.
  echo "$output" | grep -qE "targeted scope|All custom lint checks passed|Found [0-9]+ violation"
}
