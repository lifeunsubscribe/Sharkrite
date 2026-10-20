#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-verdict.sh::_gate_build_verdict, lib/utils/test-gate.sh, lib/utils/gate-runners.sh, lib/utils/gate-verdict.sh
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

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: test-gate.sh uses a function-sentinel guard (declare -f run_test_gate); pre-source _diag() stub is preserved on source.
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
# Integration: _normalize_node_test_output + _gate_build_verdict against the
# real captured jest/vitest fixture (LeadFlow PR #587).
# Converted from run_test_gate (issue #1241): no stub npm/RITE_TEST_COMMAND,
# no git fixture, no subprocess — pure verdict-seam calls.
# ---------------------------------------------------------------------------

@test "integration: failing npm test yields non-empty gate JSON tests[] after normalization" {
  # Note: diag test_count is not asserted here; it is verified in tests that call
  # run_test_gate directly. This test verifies the normalizer → verdict seam path:
  # normalizer produces ^not ok lines, and _gate_build_verdict builds a non-empty tests[].
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  _raw=$(mktemp); _lint_raw=$(mktemp); _out=$(mktemp)
  cp "$FIXTURE" "$_raw"
  _normalize_node_test_output "$_raw"

  _not_ok_count=$(grep -c '^not ok ' "$_raw" || true)
  [ "$_not_ok_count" -ge 1 ]

  _rc=0; _gate_build_verdict "$_lint_raw" "$_raw" 0 1 "$_out" "" "" || _rc=$?
  [ "$_rc" -eq 1 ]

  run jq -r '.exit_code' "$_out"
  [ "$output" = "1" ]

  # The regression this file pins: tests[] must NOT be empty for jest/vitest.
  run jq -r '.tests | length' "$_out"
  [ "$output" -gt 0 ]
  run jq -r '.tests[].test_name' "$_out"
  echo "$output" | grep -q 'backfill-lead-gsi-keys.test.ts'
  echo "$output" | grep -q 'AutomationFlow.test.tsx'

  rm -f "$_raw" "$_lint_raw" "$_out"
}

@test "integration: RITE_TEST_COMMAND failure path — normalizer produces nonzero not-ok count" {
  # Converted (issue #1241): _normalize_node_test_output covers the
  # RITE_TEST_COMMAND normalization path identically to the npm-test path.
  # The regression this pins is that _not_ok_count (the gate's test_count)
  # is nonzero after normalization — i.e., the normalizer produces ^not ok lines.
  # Note: diag test_count assertions belong in run_test_gate-based e2e tests;
  # this test verifies the normalizer-count via the verdict seam only.
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  _raw=$(mktemp); _lint_raw=$(mktemp); _out=$(mktemp)
  cp "$FIXTURE" "$_raw"
  _normalize_node_test_output "$_raw"

  _not_ok_count=$(grep -c '^not ok ' "$_raw" || true)
  [ "$_not_ok_count" -ge 1 ]

  _rc=0; _gate_build_verdict "$_lint_raw" "$_raw" 0 1 "$_out" "" "" || _rc=$?
  [ "$_rc" -eq 1 ]

  run jq -r '.exit_code' "$_out"
  [ "$output" = "1" ]

  rm -f "$_raw" "$_lint_raw" "$_out"
}

@test "integration: node-flavored RITE_TEST_COMMAND failure yields non-empty gate JSON tests[] (issue #846)" {
  # Regression: pre-fix the RITE_TEST_COMMAND branch hardcoded tests:[] even
  # when _normalize_node_test_output produced ^not ok lines — diag test_count
  # was nonzero but the fix loop got zero named findings (diag/JSON inconsistency).
  # Converted (issue #1241): assert _norm_count == _json_count directly.
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  _raw=$(mktemp); _lint_raw=$(mktemp); _out=$(mktemp)
  cp "$FIXTURE" "$_raw"
  _normalize_node_test_output "$_raw"

  # The regression this test pins: tests[] must NOT be empty for a failing
  # normalizer run that emits jest/vitest output (normalizer produces ^not ok lines).
  _norm_count=$(grep -c '^not ok ' "$_raw" || true)
  [ "$_norm_count" -gt 0 ]

  _gate_build_verdict "$_lint_raw" "$_raw" 0 1 "$_out" "" "" || true
  run jq -r '.tests | length' "$_out"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]

  # Named findings must carry recognizable test names from the fixture.
  run jq -r '.tests[].test_name' "$_out"
  echo "$output" | grep -q 'backfill-lead-gsi-keys.test.ts'
  echo "$output" | grep -q 'AutomationFlow.test.tsx'

  # Norm count and JSON length must agree (the inconsistency that prompted issue #846).
  _json_count=$(jq -r '.tests | length' "$_out")
  [ "$_norm_count" = "$_json_count" ]

  rm -f "$_raw" "$_lint_raw" "$_out"
}

@test "e2e pin #846: RITE_TEST_COMMAND branch in test-gate.sh calls _normalize_node_test_output" {
  # Regression pin for issue #846. The converted verdict-seam tests call _gate_build_verdict
  # directly after running _normalize_node_test_output — they cannot detect if the
  # RITE_TEST_COMMAND branch in test-gate.sh stops calling the normalizer.
  # Pre-fix: that branch hardcoded tests:[] even when normalization produced ^not ok lines,
  # so diag test_count was nonzero but the fix loop received zero named findings
  # (live: LeadFlow PR #587 — 53+ real failures across vitest + 2 jest workspaces,
  # diag said test_count=0, fix session investigated blind).
  local _sh="${RITE_LIB_DIR}/utils/test-gate.sh"
  grep -q '_normalize_node_test_output' "$_sh"
  grep -q 'RITE_TEST_COMMAND' "$_sh"
}

@test "integration: passing RITE_TEST_COMMAND still yields tests:[] and exit 0" {
  # Non-regression: passing output (no jest/vitest failure markers) must not
  # produce spurious test findings. Converted (issue #1241): empty normalizer
  # output → empty lint_raw + empty not-ok lines → exit 0, tests[]=0.
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  _raw=$(mktemp); _lint_raw=$(mktemp); _out=$(mktemp)
  printf 'Tests passed.\n' > "$_raw"
  _normalize_node_test_output "$_raw"

  _rc=0; _gate_build_verdict "$_lint_raw" "$_raw" 0 0 "$_out" "" "" || _rc=$?
  [ "$_rc" -eq 0 ]

  run jq -r '.exit_code' "$_out"
  [ "$output" = "0" ]
  run jq -r '.tests | length' "$_out"
  [ "$output" = "0" ]

  rm -f "$_raw" "$_lint_raw" "$_out"
}
