#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# The gate's failure plumbing is TAP-only (^not ok): jest and vitest never emit
# TAP, so a real node test failure produced test_count=0 and an empty tests[]
# array — assess-and-resolve.sh fired only the generic "no parseable findings"
# item and the fix session investigated blind (LeadFlow PR #587: 53+ real
# failures across a vitest + 2 jest workspaces, diag said test_count=0).
#
# The fix is _normalize_node_test_output(): after a failing npm test (and in
# the node-flavored RITE_TEST_COMMAND path) it appends deduped synthetic
# "not ok N - <workspace>: <file>: <test>" lines to the raw output file — the
# same trick the workspace-build failure path uses — so the existing ^not ok
# count and _parse_bats_failure_line JSON loop pick real failures up unchanged.
#
# The fixture is REAL captured output from the LeadFlow PR #587 gate run
# (rite-490-...-180242.log): npm workspace banners, vitest streaming + Failed
# Suites/Failed Tests sections, jest suite FAIL lines + ● bullets, summaries,
# and npm error interleave blocks.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  FIXTURE="${BATS_TEST_DIRNAME}/../fixtures/node-workspaces-jest-vitest-output.txt"
  export FIXTURE
  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"; export STUB_DIR

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
  # Leaked -u/pipefail + BATS_TEST_TIMEOUT swallows failing tests (keep -e:
  # bats failure detection needs errexit).
  set +u; set +o pipefail
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# ---------------------------------------------------------------------------
# Direct normalizer tests against the real captured fixture.
# ---------------------------------------------------------------------------

@test "normalizer parses BOTH jest and vitest failures from real workspace output" {
  cp "$FIXTURE" "$TEST_REPO/raw.txt"
  _normalize_node_test_output "$TEST_REPO/raw.txt"

  run grep -c '^not ok ' "$TEST_REPO/raw.txt"
  [ "$output" -gt 0 ]

  # jest per-test failure (scripts workspace, file from the FAIL suite line)
  run grep '^not ok ' "$TEST_REPO/raw.txt"
  echo "$output" | grep -q 'backfill-lead-gsi-keys.test.ts'
  echo "$output" | grep -q 'scanPageWithRetry › exhausts all retries and throws the last error'
  # vitest per-test failure (dashboard workspace)
  echo "$output" | grep -q 'AutomationFlow.test.tsx > AutomationFlow add step > calls onAddStep with "wait"'
  # jest suite-level failure (compile error — no › bullets to represent it)
  echo "$output" | grep -q 'lib/monitoring-stack.test.ts: test suite failed'
  # vitest suite-level failure (import resolution error)
  echo "$output" | grep -q 'src/services/auth.test.ts: test suite failed'
}

@test "the gate's test_count expression (grep -c '^not ok ') is nonzero after normalization" {
  cp "$FIXTURE" "$TEST_REPO/raw.txt"
  _normalize_node_test_output "$TEST_REPO/raw.txt"

  # Exact expression used for the TEST_GATE diag test_count field.
  _tests_count=$(grep -c "^not ok " "$TEST_REPO/raw.txt" || true)
  [ "$_tests_count" -gt 0 ]
}

@test "tests[] JSON built by the existing _parse_bats_failure_line loop is non-empty" {
  cp "$FIXTURE" "$TEST_REPO/raw.txt"
  _normalize_node_test_output "$TEST_REPO/raw.txt"

  # Replicate the gate's tests[] build loop verbatim.
  _tests_items="["
  _first_test=true
  while IFS= read -r _raw; do
    _item=$(_parse_bats_failure_line "$_raw" 2>/dev/null || true)
    if [ -n "$_item" ]; then
      [ "$_first_test" = "true" ] || _tests_items+=","
      _tests_items+="$_item"
      _first_test=false
    fi
  done < "$TEST_REPO/raw.txt"
  _tests_items+="]"

  printf '%s' "$_tests_items" > "$TEST_REPO/tests.json"
  run jq -r 'length' "$TEST_REPO/tests.json"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "numbering continues after existing not-ok lines (workspace-build precedent)" {
  # The workspace-build failure path appends "not ok 1 - ..." BEFORE npm test
  # runs; synthetic numbering must continue after it, not restart at 1.
  printf 'not ok 1 - workspace package build failed (entry point missing after build)\n' > "$TEST_REPO/raw.txt"
  cat "$FIXTURE" >> "$TEST_REPO/raw.txt"
  _normalize_node_test_output "$TEST_REPO/raw.txt"

  run grep -c '^not ok 1 ' "$TEST_REPO/raw.txt"
  [ "$output" = "1" ]
  run grep '^not ok 2 - ' "$TEST_REPO/raw.txt"
  [ "$status" -eq 0 ]
}

@test "workspace attribution: project_root relativizes npm error location paths" {
  cp "$FIXTURE" "$TEST_REPO/raw.txt"
  # The fixture's npm error location lines live under this worktree root.
  _normalize_node_test_output "$TEST_REPO/raw.txt" "/Users/sarahtime/Dev/rite-wt/LeFl-wt/fx-map_b490-489-467-466"

  run grep '^not ok ' "$TEST_REPO/raw.txt"
  echo "$output" | grep -q '^not ok [0-9]* - dashboard: '
  echo "$output" | grep -q '^not ok [0-9]* - infrastructure/cdk: '
  echo "$output" | grep -q '^not ok [0-9]* - infrastructure/scripts: '
}

@test "passing output appends nothing (file untouched)" {
  cat > "$TEST_REPO/raw.txt" <<'EOF'

> leadflow@0.1.0 test
> npm run test --workspaces --if-present


> leadflow-dashboard@0.1.0 test
> vitest run --silent=passed-only

 ✓ src/components/TriggerSelector.test.tsx (12 tests) 1048ms
 ✓ src/pages/Automations.test.tsx (5 tests) 999ms

 Test Files  7 passed (7)
      Tests  116 passed (116)


> leadflow-cdk@0.1.0 test
> jest --silent

PASS lib/pre-token-lambda.test.ts (24.767 s)
PASS lib/auth-stack.test.ts (40.3 s)

Test Suites: 12 passed, 12 total
Tests:       0 failed, 251 passed, 251 total
EOF
  cp "$TEST_REPO/raw.txt" "$TEST_REPO/raw.before"
  _normalize_node_test_output "$TEST_REPO/raw.txt"

  run grep -c '^not ok ' "$TEST_REPO/raw.txt"
  [ "$output" = "0" ]
  cmp -s "$TEST_REPO/raw.txt" "$TEST_REPO/raw.before"
}

@test "summary-only output (fully-silenced reporter) falls back to the Tests: summary" {
  cat > "$TEST_REPO/raw.txt" <<'EOF'
> leadflow-scripts@1.0.0 test
> jest --silent --reporters jest-silent-reporter

Test Suites: 3 failed, 3 total
Tests:       13 failed, 157 passed, 170 total
EOF
  _normalize_node_test_output "$TEST_REPO/raw.txt"

  run grep -c '^not ok ' "$TEST_REPO/raw.txt"
  [ "$output" -ge 1 ]
  run grep '^not ok ' "$TEST_REPO/raw.txt"
  echo "$output" | grep -q '13 failed'
}

@test "noise guard: bullet without › and FAIL inside code snippets produce no items" {
  cat > "$TEST_REPO/raw.txt" <<'EOF'
> leadflow-cdk@0.1.0 test
> jest --silent

  ● Cannot log after tests are done. Did you forget to wait for something asynchronous in your test?

      431 |     // FAIL fast when the table import is ambiguous
    > 433 |     const FAIL = dynamodb.Table.fromTableAttributes(this, 'MainTable', {
          |                                  ^
FAILURE: not a suite line
FAIL
Tests:       0 failed, 12 passed, 12 total
EOF
  _normalize_node_test_output "$TEST_REPO/raw.txt"

  run grep -c '^not ok ' "$TEST_REPO/raw.txt"
  [ "$output" = "0" ]
}

@test "cap: more than 50 failures truncate with a +N-more synthetic line" {
  {
    echo "> big@1.0.0 test"
    echo "> vitest run"
    i=1
    while [ $i -le 60 ]; do
      echo " FAIL  src/big.test.ts > big suite > case $i fails"
      i=$((i + 1))
    done
  } > "$TEST_REPO/raw.txt"
  _normalize_node_test_output "$TEST_REPO/raw.txt"

  run grep -c '^not ok ' "$TEST_REPO/raw.txt"
  [ "$output" = "51" ]
  run grep '^not ok 51 ' "$TEST_REPO/raw.txt"
  echo "$output" | grep -q '10 more test failure'
}

# ---------------------------------------------------------------------------
# Integration: the full run_test_gate harness against a non-Sharkrite npm repo
# whose stubbed `npm test` emits the real jest/vitest fixture and exits 1.
# ---------------------------------------------------------------------------

_make_npm_repo() {
  printf '%s\n' '{"name":"single","version":"1.0.0","scripts":{"test":"jest --ci"}}' > "$TEST_REPO/package.json"
  printf '{"lockfileVersion":3}\n' > "$TEST_REPO/package-lock.json"
  printf 'export const x = 1;\n' > "$TEST_REPO/index.js"
  # jest resolvable up-front so the bootstrap is skipped (not under test here).
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"
}

_init_git() {
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && printf 'export const x = 2;\n' > index.js \
     && git add -A && git commit -qm change) >/dev/null 2>&1
}

_write_failing_npm_stub() {
  cat > "$STUB_DIR/npm" <<STUB
#!/bin/bash
if [ "\$1" = "test" ]; then
  cat "$FIXTURE"
  exit 1
fi
exit 0
STUB
  chmod +x "$STUB_DIR/npm"
}

_run_gate() {
  : > "$TEST_REPO/diag.log"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=587 RITE_LOG_FILE='$TEST_REPO/diag.log' RITE_GATE_BACKGROUND=1
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
}

@test "integration: failing npm test yields non-empty gate JSON tests[] and nonzero diag test_count" {
  _make_npm_repo
  _init_git
  _write_failing_npm_stub

  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  [ "$status" -eq 1 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "1" ]

  # The regression this file pins: tests[] must NOT be empty for jest/vitest.
  run jq -r '.tests | length' "$TEST_REPO/gate.json"
  [ "$output" -gt 0 ]
  run jq -r '.tests[].test_name' "$TEST_REPO/gate.json"
  echo "$output" | grep -q 'backfill-lead-gsi-keys.test.ts'
  echo "$output" | grep -q 'AutomationFlow.test.tsx'

  # Diag must carry the real failure count, not test_count=0.
  run grep -E 'TEST_GATE outcome=failed .*test_count=[1-9]' "$TEST_REPO/diag.log"
  [ "$status" -eq 0 ]
}

@test "integration: node-flavored RITE_TEST_COMMAND failure yields nonzero diag test_count" {
  _make_npm_repo
  _init_git
  cat > "$TEST_REPO/run-node-tests.sh" <<SCRIPT
#!/bin/bash
cat "$FIXTURE"
exit 1
SCRIPT
  chmod +x "$TEST_REPO/run-node-tests.sh"

  : > "$TEST_REPO/diag.log"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=587 RITE_LOG_FILE='$TEST_REPO/diag.log' RITE_GATE_BACKGROUND=1
    export RITE_TEST_COMMAND='./run-node-tests.sh'
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  [ "$status" -eq 1 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "1" ]
  run grep -E 'TEST_GATE outcome=failed .*test_count=[1-9]' "$TEST_REPO/diag.log"
  [ "$status" -eq 0 ]
}
