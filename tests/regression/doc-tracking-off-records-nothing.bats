#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh
#
# Regression tests for the RITE_DOC_MODE consent gate in _record_tier1_drift_entries.
# Pins the acceptance criterion from issue #1427:
#   "RITE_DOC_MODE off or unset records nothing"
#
# Tests verify that even when all three tier-1 triggers would otherwise fire,
# no drift entries are written when tracking is off or unset.

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

  # Set up a scenario that fires ALL three triggers when tracking IS on
  printf '# Feature Doc\n\n<!-- sharkrite-enforced-by: tests/regression/t-off.bats -->\n' \
    > "$_TMPDIR/docs/feature.md"

  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/core/impl.sh\n@test "x" { true; }\n' \
    > "$_TMPDIR/tests/regression/t-off.bats"

  printf '# docs-map v4\n' > "$RITE_STATE_DIR/docs-map.tsv"
  printf 'docs/feature.md\t\t-\t\t\n' >> "$RITE_STATE_DIR/docs-map.tsv"

  # Declared-doc state file for Trigger C
  printf 'docs/feature.md' > "$RITE_STATE_DIR/declared-doc-feat-off.txt"

  # Load functions via RITE_SOURCE_FUNCTIONS_ONLY=1
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_REPO_ROOT/lib/core/assess-documentation.sh" 2>/dev/null || true
  set +u; set +o pipefail

  print_info() { :; }
  print_warning() { :; }
  verbose_info() { :; }
  docs_map_ensure() { :; }
}

teardown() {
  cd /
  rm -rf "$_TMPDIR"
}

# ---------------------------------------------------------------------------
# Helpers: invoke all three triggers at once
# ---------------------------------------------------------------------------

_invoke_all_triggers() {
  # Changed file = enforcing test (Trigger A)
  # Head branch has a declared-doc file (Trigger C)
  _record_tier1_drift_entries "200" "Closes #99" \
    "tests/regression/t-off.bats" "main" "feat/off" || true
}

# ---------------------------------------------------------------------------
# RITE_DOC_MODE unset: records nothing
# ---------------------------------------------------------------------------

@test "RITE_DOC_MODE unset: Trigger A fires but records nothing" {
  unset RITE_DOC_MODE
  _invoke_all_triggers
  local _cnt
  _cnt="$(drift_log_entry_count)"
  [ "$_cnt" -eq 0 ]
}

@test "RITE_DOC_MODE unset: Trigger B fires but records nothing" {
  unset RITE_DOC_MODE
  _record_tier1_drift_entries "201" "Closes #99" \
    "lib/core/impl.sh" "main" "feat/off" || true
  local _cnt
  _cnt="$(drift_log_entry_count)"
  [ "$_cnt" -eq 0 ]
}

@test "RITE_DOC_MODE unset: Trigger C fires but records nothing" {
  unset RITE_DOC_MODE
  _record_tier1_drift_entries "202" "Closes #99" \
    "lib/other/unrelated.sh" "main" "feat/off" || true
  local _cnt
  _cnt="$(drift_log_entry_count)"
  [ "$_cnt" -eq 0 ]
}

# ---------------------------------------------------------------------------
# RITE_DOC_MODE=off: records nothing
# ---------------------------------------------------------------------------

@test "RITE_DOC_MODE=off: Trigger A fires but records nothing" {
  RITE_DOC_MODE=off _invoke_all_triggers
  local _cnt
  _cnt="$(drift_log_entry_count)"
  [ "$_cnt" -eq 0 ]
}

@test "RITE_DOC_MODE=off: Trigger B fires but records nothing" {
  RITE_DOC_MODE=off _record_tier1_drift_entries "201" "Closes #99" \
    "lib/core/impl.sh" "main" "feat/off" || true
  local _cnt
  _cnt="$(drift_log_entry_count)"
  [ "$_cnt" -eq 0 ]
}

@test "RITE_DOC_MODE=off: Trigger C fires but records nothing" {
  RITE_DOC_MODE=off _record_tier1_drift_entries "202" "Closes #99" \
    "lib/other/unrelated.sh" "main" "feat/off" || true
  local _cnt
  _cnt="$(drift_log_entry_count)"
  [ "$_cnt" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Contrast: RITE_DOC_MODE=sync DOES record (control group)
# ---------------------------------------------------------------------------

@test "RITE_DOC_MODE=sync: Trigger A DOES record (contrast)" {
  RITE_DOC_MODE=sync _invoke_all_triggers
  local _cnt
  _cnt="$(drift_log_entry_count)"
  [ "$_cnt" -ge 1 ]
}

@test "RITE_DOC_MODE=changelog: Trigger A DOES record (contrast)" {
  RITE_DOC_MODE=changelog _invoke_all_triggers
  local _cnt
  _cnt="$(drift_log_entry_count)"
  [ "$_cnt" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Structural: case statement in _record_tier1_drift_entries gates on sync|changelog
# ---------------------------------------------------------------------------

@test "structural: _record_tier1_drift_entries body has sync|changelog consent gate" {
  local body
  body="$(declare -f _record_tier1_drift_entries)"
  # Must contain a case gate on RITE_DOC_MODE
  echo "$body" | grep -q 'RITE_DOC_MODE'
  echo "$body" | grep -q 'sync'
  echo "$body" | grep -q 'changelog'
}

# ---------------------------------------------------------------------------
# Coverage header self-check (MISSING_TEST_COVERAGE_HEADER lint)
# ---------------------------------------------------------------------------

@test "doc-tracking-off-records-nothing.bats: coverage header present on line 2" {
  local _cnt
  _cnt="$(head -2 "$BATS_TEST_FILENAME" | grep -c 'sharkrite-test-covers:' || true)"
  [ "$_cnt" -eq 1 ]
}
