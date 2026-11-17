#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-runners.sh::_normalize_pytest_test_output, lib/utils/gate-verdict.sh::_parse_bats_failure_line|_tap_failure_name, lib/utils/test-gate.sh::run_test_gate, lib/core/assess-and-resolve.sh::_build_gate_prepend_items
# sharkrite-gate-serial
# Regression: a failing pytest run reached the fix session with no test names.
#
# The gate's failure plumbing counts "^not ok" lines. pytest never prints TAP,
# so every red pytest gate logged test_count=0 and "failed (exit 1, no test
# names parsed)", wrote an empty tests[] array, and handed the fix session one
# item: "gate failure: non-zero exit with no parseable findings ... investigate
# why the test runner produced no parseable output".
#
# Live (freshup 2026-11-16/17, RITE_TEST_COMMAND="bash scripts/rite-test.sh"):
# three issues spent whole fix budgets without an edit (1020 s; 780 s then
# 1560 s) while pytest had printed, in the same log, the eight failing node
# ids and "ValueError: Constraint must have a name".
#
# Contract pinned here:
#   - every "FAILED <nodeid>" / "ERROR <nodeid>" summary line becomes one
#     named finding whose name is the node id exactly (stable across rounds,
#     runnable as `pytest <name>`)
#   - the finding's reason is the runner's own first error line, plus the last
#     bare exception line of the block when the assertion wraps another error
#   - the finding's file is the test file, and the fix item says "test
#     failure", never "bats failure" reported by `bats -r tests/`
#   - output from any other runner is left byte-identical
#
# The fixture is the real #603 gate output with the E-blocks shortened.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  FIXTURE="${BATS_TEST_DIRNAME}/../fixtures/pytest-xdist-failure-output.txt"
  export FIXTURE
  WORK=$(mktemp -d); export WORK
  NODE="tests/test_migration_chain.py"; export NODE

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: test-gate.sh uses a function-sentinel guard (declare -f run_test_gate); pre-source _diag() stub is preserved on source.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
  set +u; set +o pipefail
}

teardown() { rm -rf "${WORK:-}"; }

# Target repo with one backend change; the test command (or `make test`)
# replays the fixture and exits 1.
_make_target_repo() {
  TARGET_REPO="$WORK/repo"; export TARGET_REPO
  mkdir -p "$TARGET_REPO/backend"
  cp "$FIXTURE" "$WORK/pytest-out.txt"
  (cd "$TARGET_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && echo 'x = 1' > backend/app.py \
     && git add -A && git commit -qm init && git tag base \
     && echo 'x = 2' > backend/app.py \
     && git add -A && git commit -qm change) >/dev/null 2>&1
}

# $1 = extra shell run before the gate (exports)
_run_gate() {
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=78
    export RITE_LOG_FILE='$WORK/diag.log' RITE_STATE_DIR='$WORK/state'
    export RITE_TEST_GATE_DIFF_BASE=base RITE_GATE_FLAKE_RETRY=false
    $1
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    run_test_gate '$WORK/gate.json' '$TARGET_REPO'
  " </dev/null
}

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
# _normalize_pytest_test_output
# ---------------------------------------------------------------------------

@test "normalizer: every FAILED and ERROR summary line becomes one not-ok line" {
  cp "$FIXTURE" "$WORK/raw.txt"
  _normalize_pytest_test_output "$WORK/raw.txt"

  [ "$(grep -c '^not ok ' "$WORK/raw.txt")" = "8" ]
  grep -q "^not ok 1 ${NODE}::TestMigrationRoundTrip::test_downgrade_to_base_and_back	" "$WORK/raw.txt"
  grep -q "^not ok 3 ${NODE}::TestMigrationsRunFromEmpty::test_upgrade_head_succeeds	" "$WORK/raw.txt"
  grep -q "^not ok 8 ${NODE}::TestMigrationsRunFromEmpty::test_dropped_rating_columns_are_gone	" "$WORK/raw.txt"
}

@test "normalizer: reason is the first error line plus the wrapped exception" {
  cp "$FIXTURE" "$WORK/raw.txt"
  _normalize_pytest_test_output "$WORK/raw.txt"

  # FAILED entry: section header "____ Class.test ____" (many underscores).
  run grep "^not ok 1 " "$WORK/raw.txt"
  [[ "$output" == *"	AssertionError: initial upgrade failed: [last error line: ValueError: Constraint must have a name]" ]]

  # ERROR entry whose section header has ONE underscore each side
  # ("_ ERROR at setup of Class.test _") — the long-name shape.
  run grep "^not ok 4 " "$WORK/raw.txt"
  [[ "$output" == *"::test_migrated_schema_has_every_model_table	setup/teardown error: AssertionError: \`alembic upgrade head\` failed on an empty database. [last error line: ValueError: Constraint must have a name]" ]]
}

@test "normalizer: summary-line message is the reason when no traceback section exists" {
  cat > "$WORK/raw.txt" <<'OUT'
=========================== short test summary info ============================
FAILED tests/test_a.py::test_one - assert 1 == 2
FAILED tests/unit/test_b.py::TestB::test_two[param-1] - KeyError: 'x'
ERROR tests/test_broken.py - ImportError: cannot import name 'gone' from 'app'
ERROR tests/test_c.py::test_three
========================= 2 failed, 2 errors in 0.31s ==========================
OUT
  _normalize_pytest_test_output "$WORK/raw.txt"

  [ "$(grep -c '^not ok ' "$WORK/raw.txt")" = "4" ]
  grep -qF "not ok 1 tests/test_a.py::test_one	assert 1 == 2" "$WORK/raw.txt"
  grep -qF "not ok 2 tests/unit/test_b.py::TestB::test_two[param-1]	KeyError: 'x'" "$WORK/raw.txt"
  grep -qF "not ok 3 tests/test_broken.py	collection error: ImportError: cannot import name 'gone' from 'app'" "$WORK/raw.txt"
  grep -qF "not ok 4 tests/test_c.py::test_three	setup/teardown error" "$WORK/raw.txt"
}

@test "normalizer: a node id listed twice yields one finding; numbering continues after existing not-ok lines" {
  cat > "$WORK/raw.txt" <<'OUT'
not ok 1 - frontend: src/a.test.tsx: renders
FAILED tests/test_a.py::test_one - boom
FAILED tests/test_a.py::test_one - boom
OUT
  _normalize_pytest_test_output "$WORK/raw.txt"
  [ "$(grep -c '^not ok ' "$WORK/raw.txt")" = "2" ]
  grep -qF "not ok 2 tests/test_a.py::test_one	boom" "$WORK/raw.txt"
}

@test "normalizer: output from other runners is left byte-identical" {
  cat > "$WORK/raw.txt" <<'OUT'
1..3
ok 1 first
not ok 2 second
 FAIL  src/pages/Schedule.test.tsx > Schedule > paginates
Error: Test timed out in 5000ms.
ERROR something happened in the app log
FAILED to connect to the database
ERROR: file or directory not found: tests/nope
FAIL src/services/auth.test.ts
src/pages/Schedule.tsx(12,7): error TS6133: 'unused' is declared but its value is never read.
OUT
  cp "$WORK/raw.txt" "$WORK/before.txt"
  _normalize_pytest_test_output "$WORK/raw.txt"
  cmp -s "$WORK/raw.txt" "$WORK/before.txt"

  : > "$WORK/empty.txt"
  _normalize_pytest_test_output "$WORK/empty.txt"
  [ ! -s "$WORK/empty.txt" ]
}

@test "normalizer: more than 50 failures truncate with one +N-more line" {
  : > "$WORK/raw.txt"
  for i in $(seq 1 57); do echo "FAILED tests/test_many.py::test_${i} - boom" >> "$WORK/raw.txt"; done
  _normalize_pytest_test_output "$WORK/raw.txt"
  [ "$(grep -c '^not ok ' "$WORK/raw.txt")" = "51" ]
  grep -q '^not ok 51 \.\.\. and 7 more test failure(s) truncated' "$WORK/raw.txt"
}

@test "normalizer: ANSI-colored summary lines are read" {
  printf '\033[31mFAILED\033[0m tests/test_a.py::\033[1mtest_one\033[0m - boom\n' > "$WORK/raw.txt"
  _normalize_pytest_test_output "$WORK/raw.txt"
  grep -qF "not ok 1 tests/test_a.py::test_one	boom" "$WORK/raw.txt"
}

# ---------------------------------------------------------------------------
# _parse_bats_failure_line / _tap_failure_name
# ---------------------------------------------------------------------------

@test "parse: pytest line yields the test file, the node id as name, the runner line as reason" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _line="not ok 3 ${NODE}::TestA::test_b	setup/teardown error: AssertionError: \`x\` failed [last error line: ValueError: \"quoted\"]"
  run _parse_bats_failure_line "$_line"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.file' <<< "$output")" = "$NODE" ]
  [ "$(jq -r '.test_name' <<< "$output")" = "${NODE}::TestA::test_b" ]
  [ "$(jq -r '.reason' <<< "$output")" = "setup/teardown error: AssertionError: \`x\` failed [last error line: ValueError: \"quoted\"]" ]
}

@test "parse: a bats TAP line keeps file=bats and the default reason" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  run _parse_bats_failure_line "not ok 12 gate: handles foo.test.ts and tests/test_x.py::thing in the name"
  [ "$(jq -r '.file' <<< "$output")" = "bats" ]
  [ "$(jq -r '.test_name' <<< "$output")" = "gate: handles foo.test.ts and tests/test_x.py::thing in the name" ]
  [ "$(jq -r '.reason' <<< "$output")" = "assertion failed" ]

  run _parse_bats_failure_line "not ok 1 [tests_not_run] some planned test"
  [ "$(jq -r '.file' <<< "$output")" = "bats" ]
  [ "$(jq -r '.reason' <<< "$output")" = "tests_not_run" ]
}

@test "parse: a normalized jest/vitest line yields its test file" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  run _parse_bats_failure_line "not ok 2 - dashboard: src/components/AutomationFlow.test.tsx: AutomationFlow > adds a step"
  [ "$(jq -r '.file' <<< "$output")" = "src/components/AutomationFlow.test.tsx" ]
  [ "$(jq -r '.test_name' <<< "$output")" = "- dashboard: src/components/AutomationFlow.test.tsx: AutomationFlow > adds a step" ]
}

@test "digest names drop the reason tail" {
  cp "$FIXTURE" "$WORK/raw.txt"
  _normalize_pytest_test_output "$WORK/raw.txt"
  run _extract_tap_failure_names "$WORK/raw.txt"
  [ "$(grep -c . <<< "$output")" = "8" ]
  grep -qxF "${NODE}::TestMigrationRoundTrip::test_downgrade_to_base_and_back" <<< "$output"
  [[ "$output" != *"ValueError"* ]]
}

# ---------------------------------------------------------------------------
# run_test_gate — both paths that can run pytest
# ---------------------------------------------------------------------------

@test "gate: RITE_TEST_COMMAND pytest failure writes named findings and no excerpt" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _make_target_repo
  _run_gate "export RITE_TEST_COMMAND='cat $WORK/pytest-out.txt; exit 1'"
  [ "$status" -eq 1 ]

  [ "$(jq -r '.exit_code' "$WORK/gate.json")" = "1" ]
  [ "$(jq -r '.tests | length' "$WORK/gate.json")" = "8" ]
  [ "$(jq -r '[.tests[].file] | unique | join(",")' "$WORK/gate.json")" = "$NODE" ]
  [ "$(jq -r '.tests[0].test_name' "$WORK/gate.json")" = "${NODE}::TestMigrationRoundTrip::test_downgrade_to_base_and_back" ]
  [[ "$(jq -r '.tests[0].reason' "$WORK/gate.json")" == *"ValueError: Constraint must have a name"* ]]
  [ "$(jq -r '.excerpt // "none"' "$WORK/gate.json")" = "none" ]

  [[ "$output" == *"RITE_TEST_COMMAND: 8 failure(s)"* ]]
  [[ "$output" != *"no test names parsed"* ]]
  [[ "$output" == *"• ${NODE}::TestNoNewSchemaDrift::test_only_known_benign_drift_remains"* ]]
  grep -qE 'TEST_GATE outcome=failed lint_count=0 test_count=8 ' "$WORK/diag.log"
}

@test "gate: detected-runner path (make test wrapping pytest) writes named findings" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  command -v make >/dev/null 2>&1 || skip "make not installed"
  _make_target_repo
  printf 'test:\n\t@cat %s; exit 1\n' "$WORK/pytest-out.txt" > "$TARGET_REPO/Makefile"
  (cd "$TARGET_REPO" && git add -A && git commit -qm makefile) >/dev/null 2>&1
  _run_gate ""
  [ "$status" -eq 1 ]

  [ "$(jq -r '.exit_code' "$WORK/gate.json")" = "1" ]
  [ "$(jq -r '.tests | length' "$WORK/gate.json")" = "8" ]
  [ "$(jq -r '[.tests[].file] | unique | join(",")' "$WORK/gate.json")" = "$NODE" ]
  [ "$(jq -r '.excerpt // "none"' "$WORK/gate.json")" = "none" ]
  grep -qE 'TEST_GATE outcome=failed .*test_count=8 ' "$WORK/diag.log"
}

# ---------------------------------------------------------------------------
# _build_gate_prepend_items — what the fix session reads
# ---------------------------------------------------------------------------

@test "fix item: a pytest finding is a 'test failure' that names its file and never mentions bats" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  cat > "$WORK/gate.json" <<JSON
{"exit_code":1,"lint":[],"tests":[{"file":"${NODE}","test_name":"${NODE}::TestA::test_b","reason":"AssertionError: upgrade failed [last error line: ValueError: Constraint must have a name]"}]}
JSON
  _build_items "$WORK/gate.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"### [GATE] test failure: ${NODE}::TestA::test_b - ACTIONABLE_NOW"* ]]
  [[ "$output" == *"**Location:** ${NODE}"* ]]
  [[ "$output" == *"**Reason:** AssertionError: upgrade failed [last error line: ValueError: Constraint must have a name]"* ]]
  [[ "$output" == *"The project's test command (post-commit gate) reported this failure"* ]]
  [[ "$output" != *"bats"* ]]
  [[ "$output" == *"COUNT:1"* ]]
}

@test "fix item: bats findings keep the 'bats failure' header (file=bats and *.bats)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  printf '%s\n' '{"exit_code":1,"lint":[],"tests":[{"file":"bats","test_name":"first","reason":"assertion failed"},{"file":"tests/regression/x.bats","test_name":"second","reason":"assertion failed"}]}' > "$WORK/gate.json"
  _build_items "$WORK/gate.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"### [GATE] bats failure: first - ACTIONABLE_NOW"* ]]
  [[ "$output" == *"### [GATE] bats failure: second - ACTIONABLE_NOW"* ]]
  [[ "$output" == *'`bats -r tests/` (post-commit gate) reported this failure'* ]]
  [[ "$output" != *"[GATE] test failure"* ]]
}

@test "fix item: an unparsed failure with runner lines says fix what they name, not the runner" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  printf '%s\n' '{"exit_code":1,"lint":[],"tests":[],"excerpt":"src/pages/Schedule.tsx(12,7): error TS6133: unused"}' > "$WORK/gate.json"
  _build_items "$WORK/gate.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"### [GATE] gate failure: non-zero exit (exit_code=1) with no parseable findings - ACTIONABLE_NOW"* ]]
  [[ "$output" == *"**Fix Effort:** Medium (fix the failure the runner lines below name)"* ]]
  [[ "$output" == *"error TS6133"* ]]
  [[ "$output" != *"investigate why the test runner produced no parseable output"* ]]
  [[ "$output" != *"Investigate the runner (check for missing dependencies"* ]]

  # No runner lines captured: the runner really is the thing to look at.
  printf '%s\n' '{"exit_code":1,"lint":[],"tests":[]}' > "$WORK/gate.json"
  _build_items "$WORK/gate.json"
  [[ "$output" == *"**Fix Effort:** Medium (investigate why the test runner produced no parseable output)"* ]]
  [[ "$output" == *"Investigate the runner (check for missing dependencies"* ]]
}
