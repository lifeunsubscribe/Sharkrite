#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh
#
# Regression tests for the Tier 1 deterministic drift recording path
# (_record_tier1_drift_entries). Pins the acceptance criteria from issue #1427:
#
#   1. Trigger A: changed file IS a doc's declared enforcing test → entry with
#      kind=test-scope, evidence "changed: <test>; enforces: <doc>"
#   2. Trigger B: changed file matches covers-header path of an enforcing test →
#      entry with kind=test-scope, evidence "changed: <src>; covers: <pat>; enforces-via: <test>"
#   3. Trigger C: PR head branch has a declared-doc state file →
#      entry with kind=addition, evidence "branch: ...; declared-doc: ...; changed: ..."
#   4. No trigger fires → zero entries recorded
#   5. Zero provider calls: structural grep + stubbed-provider behavioral run
#   6. Each trigger fires independently (one-trigger-at-a-time isolation)

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT

  _TMPDIR="$(mktemp -d)"
  export RITE_PROJECT_ROOT="$_TMPDIR"
  export RITE_STATE_DIR="$_TMPDIR/.rite/state"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_DOCS_MAP_AUTO="false"
  export RITE_VERBOSE=false
  unset RITE_DOC_MODE

  mkdir -p "$RITE_STATE_DIR/doc-drift"
  mkdir -p "$_TMPDIR/docs"
  mkdir -p "$_TMPDIR/tests/regression"

  # Feature doc with a sharkrite-enforced-by marker
  printf '# Feature Doc\n\n<!-- sharkrite-enforced-by: tests/regression/t1-enforcing.bats -->\n' \
    > "$_TMPDIR/docs/feature.md"

  # A second doc with no enforced-by marker (control group)
  printf '# Plain Doc\n\nNo markers here.\n' \
    > "$_TMPDIR/docs/plain.md"

  # Enforcing test that also declares covers paths
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/core/impl.sh, lib/utils/helper.sh\n@test "x" { true; }\n' \
    > "$_TMPDIR/tests/regression/t1-enforcing.bats"

  # Minimal docs map: one row per doc (tab-separated, six fields)
  # docs_map_path() returns ${RITE_PROJECT_ROOT}/docs/docs-map.tsv
  printf '# docs-map v4\n' > "$_TMPDIR/docs/docs-map.tsv"
  printf 'docs/feature.md\t\t-\t\t\n' >> "$_TMPDIR/docs/docs-map.tsv"
  printf 'docs/plain.md\t\t-\t\t\n' >> "$_TMPDIR/docs/docs-map.tsv"

  # Load all needed functions via RITE_SOURCE_FUNCTIONS_ONLY=1
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_REPO_ROOT/lib/core/assess-documentation.sh" 2>/dev/null || true
  # Runbook §3: restore flags after last source (never set +e).
  set +u; set +o pipefail

  # Re-stub print_* AFTER sources (runbook §2 — env-var-guarded libs overwrite pre-stubs)
  print_info() { :; }
  print_warning() { :; }
  verbose_info() { :; }
  docs_map_ensure() { :; }

  # Stub provider functions — track any call as a violation
  _T1_PROVIDER_CALL_COUNT=0
  provider_run_prompt() { _T1_PROVIDER_CALL_COUNT=$((_T1_PROVIDER_CALL_COUNT + 1)); echo "stub"; }
  provider_run_prompt_with_timeout() { _T1_PROVIDER_CALL_COUNT=$((_T1_PROVIDER_CALL_COUNT + 1)); echo "stub"; }
  provider_run_streaming_prompt() { _T1_PROVIDER_CALL_COUNT=$((_T1_PROVIDER_CALL_COUNT + 1)); echo "stub"; }
}

teardown() {
  cd /
  rm -rf "$_TMPDIR"
}

# ---------------------------------------------------------------------------
# Trigger A: changed file IS a doc's declared enforcing test
# ---------------------------------------------------------------------------

@test "Trigger A: changed enforcing test fires drift entry" {
  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "99" "Closes #42" \
    "tests/regression/t1-enforcing.bats" "main" "feat/my-feature" || true

  local _cnt
  _cnt="$(drift_log_entry_count --doc docs/feature.md)"
  [ "$_cnt" -eq 1 ]
}

@test "Trigger A: entry has kind=test-scope" {
  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "99" "Closes #42" \
    "tests/regression/t1-enforcing.bats" "main" "feat/my-feature" || true

  local _ef
  _ef="$(_drift_entry_path "docs/feature.md" "main")"
  grep -q "kind=test-scope" "$_ef"
}

@test "Trigger A: evidence contains changed and enforces fields" {
  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "99" "Closes #42" \
    "tests/regression/t1-enforcing.bats" "main" "feat/my-feature" || true

  local _ef
  _ef="$(_drift_entry_path "docs/feature.md" "main")"
  grep -q "changed: tests/regression/t1-enforcing.bats" "$_ef"
  grep -q "enforces: docs/feature.md" "$_ef"
}

@test "Trigger A: assertion is the enforcing test path" {
  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "99" "Closes #42" \
    "tests/regression/t1-enforcing.bats" "main" "feat/my-feature" || true

  local _ef
  _ef="$(_drift_entry_path "docs/feature.md" "main")"
  grep -q "assertion=tests/regression/t1-enforcing.bats" "$_ef"
}

# ---------------------------------------------------------------------------
# Trigger B: changed source file matches covers-header path of enforcing test
# ---------------------------------------------------------------------------

@test "Trigger B: changed source matching covers header fires drift entry" {
  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "100" "Closes #43" \
    "lib/core/impl.sh" "main" "feat/my-feature" || true

  local _cnt
  _cnt="$(drift_log_entry_count --doc docs/feature.md)"
  [ "$_cnt" -eq 1 ]
}

@test "Trigger B: entry has kind=test-scope" {
  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "100" "Closes #43" \
    "lib/core/impl.sh" "main" "feat/my-feature" || true

  local _ef
  _ef="$(_drift_entry_path "docs/feature.md" "main")"
  grep -q "kind=test-scope" "$_ef"
}

@test "Trigger B: evidence contains changed, covers, and enforces-via fields" {
  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "100" "Closes #43" \
    "lib/core/impl.sh" "main" "feat/my-feature" || true

  local _ef
  _ef="$(_drift_entry_path "docs/feature.md" "main")"
  grep -q "changed: lib/core/impl.sh" "$_ef"
  grep -q "covers: lib/core/impl.sh" "$_ef"
  grep -q "enforces-via: tests/regression/t1-enforcing.bats" "$_ef"
}

@test "Trigger B: single-pattern covers header fires drift entry" {
  # Regression: printf '%s' (no newline) caused while-read to skip the only pattern.
  # The fix: printf '%s\n' so the loop always reads the final (or only) token.
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/core/single.sh\n@test "x" { true; }\n' \
    > "$_TMPDIR/tests/regression/t1-single.bats"
  printf '# Feature Doc\n\n<!-- sharkrite-enforced-by: tests/regression/t1-single.bats -->\n' \
    > "$_TMPDIR/docs/single.md"
  printf 'docs/single.md\t\t-\t\t\n' >> "$_TMPDIR/docs/docs-map.tsv"

  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "110" "Closes #50" \
    "lib/core/single.sh" "main" "feat/single" || true

  local _cnt
  _cnt="$(drift_log_entry_count --doc docs/single.md)"
  [ "$_cnt" -eq 1 ]
}

@test "Trigger B: last pattern in multi-pattern covers header fires drift entry" {
  # Regression: without trailing newline, the last CSV token was dropped by while-read.
  # The enforcing test has TWO covers paths; this test changes the SECOND one.
  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "111" "Closes #51" \
    "lib/utils/helper.sh" "main" "feat/last-pat" || true

  local _cnt
  _cnt="$(drift_log_entry_count --doc docs/feature.md)"
  [ "$_cnt" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Trigger C: declared-doc state file on the head branch
# ---------------------------------------------------------------------------

@test "Trigger C: declared-doc branch fires drift entry" {
  # Write declared-doc state file for the head branch slug
  printf 'docs/feature.md' > "$RITE_STATE_DIR/declared-doc-feat-declared.txt"

  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "101" "Closes #44" \
    "lib/other/file.sh" "main" "feat/declared" || true

  local _cnt
  _cnt="$(drift_log_entry_count --doc docs/feature.md)"
  [ "$_cnt" -eq 1 ]
}

@test "Trigger C: entry has kind=addition" {
  printf 'docs/feature.md' > "$RITE_STATE_DIR/declared-doc-feat-declared.txt"

  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "101" "Closes #44" \
    "lib/other/file.sh" "main" "feat/declared" || true

  local _ef
  _ef="$(_drift_entry_path "docs/feature.md" "main")"
  grep -q "kind=addition" "$_ef"
}

@test "Trigger C: evidence contains branch and declared-doc fields" {
  printf 'docs/feature.md' > "$RITE_STATE_DIR/declared-doc-feat-declared.txt"

  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "101" "Closes #44" \
    "lib/other/file.sh" "main" "feat/declared" || true

  local _ef
  _ef="$(_drift_entry_path "docs/feature.md" "main")"
  grep -q "branch: feat/declared" "$_ef"
  grep -q "declared-doc: docs/feature.md" "$_ef"
}

@test "Trigger C: branch slug replaces slashes with dashes (feat/a/b -> feat-a-b)" {
  printf 'docs/feature.md' > "$RITE_STATE_DIR/declared-doc-feat-a-b.txt"

  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "102" "Closes #45" \
    "lib/other/file.sh" "main" "feat/a/b" || true

  local _cnt
  _cnt="$(drift_log_entry_count --doc docs/feature.md)"
  [ "$_cnt" -eq 1 ]
}

# ---------------------------------------------------------------------------
# No trigger fires
# ---------------------------------------------------------------------------

@test "One-off fix with no enforced-by match records nothing" {
  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "103" "Closes #46" \
    "lib/unrelated/noop.sh" "main" "feat/unrelated" || true

  local _cnt
  _cnt="$(drift_log_entry_count)"
  [ "$_cnt" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Zero provider calls — structural grep
# ---------------------------------------------------------------------------

@test "zero provider calls: _record_tier1_drift_entries body has no provider_run call (structural)" {
  local body
  body="$(declare -f _record_tier1_drift_entries)"
  local _cnt
  _cnt="$(echo "$body" | grep -c 'provider_run' || true)"
  [ "$_cnt" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Zero provider calls — behavioral run with stubbed provider
# ---------------------------------------------------------------------------

@test "zero provider calls: behavioral run with Trigger A input makes no provider call" {
  _T1_PROVIDER_CALL_COUNT=0
  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "99" "Closes #42" \
    "tests/regression/t1-enforcing.bats" "main" "feat/my-feature" || true
  [ "$_T1_PROVIDER_CALL_COUNT" -eq 0 ]
}

@test "zero provider calls: behavioral run with Trigger B input makes no provider call" {
  _T1_PROVIDER_CALL_COUNT=0
  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "100" "Closes #43" \
    "lib/core/impl.sh" "main" "feat/my-feature" || true
  [ "$_T1_PROVIDER_CALL_COUNT" -eq 0 ]
}

@test "zero provider calls: behavioral run with Trigger C input makes no provider call" {
  printf 'docs/feature.md' > "$RITE_STATE_DIR/declared-doc-feat-declared.txt"
  _T1_PROVIDER_CALL_COUNT=0
  RITE_DOC_MODE=sync \
    _record_tier1_drift_entries "101" "Closes #44" \
    "lib/other/file.sh" "main" "feat/declared" || true
  [ "$_T1_PROVIDER_CALL_COUNT" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Coverage header self-check (MISSING_TEST_COVERAGE_HEADER lint)
# ---------------------------------------------------------------------------

@test "doc-drift-tier1-deterministic.bats: coverage header present on line 2" {
  local _cnt
  _cnt="$(head -2 "$BATS_TEST_FILENAME" | grep -c 'sharkrite-test-covers:' || true)"
  [ "$_cnt" -eq 1 ]
}
