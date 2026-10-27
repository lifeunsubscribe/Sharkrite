#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh::_record_tier1_drift_entries

# Regression tests for _record_tier1_drift_entries consent gate.
#
# When RITE_DOC_MODE is unset or set to any value other than "sync" or
# "changelog", _record_tier1_drift_entries must return immediately without
# writing any drift entries. A Trigger C state file is present in all tests so
# the consent gate is the only reason no entry should be written.
#
# Covers:
#   1. No drift entry when RITE_DOC_MODE is unset.
#   2. No drift entry when RITE_DOC_MODE=off.
#   3. Drift entry IS recorded when RITE_DOC_MODE=changelog (positive control).
#   4. Drift entry IS recorded when RITE_DOC_MODE=sync (positive control).

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB_DIR="$PROJECT_ROOT/lib"

  _TMPDIR="$(mktemp -d)"
  cd "$_TMPDIR"
  git init -q .
  git config user.email "test@test.invalid"
  git config user.name "Test"
  touch .gitkeep
  git add .gitkeep
  git commit -q -m "init"

  export RITE_PROJECT_ROOT="$_TMPDIR"
  export RITE_STATE_DIR="$_TMPDIR/.rite/state"
  mkdir -p "$RITE_STATE_DIR"
  export RITE_LIB_DIR="$LIB_DIR"
  export RITE_VERBOSE=false

  # Pre-stub load_provider so no real Claude provider is loaded.
  # provider-interface.sh uses a function-sentinel guard (declare -f load_provider).
  load_provider() { :; }

  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: assess-documentation.sh uses a function-sentinel guard (declare -f update_conventions_from_marker); load_provider pre-stub is preserved because provider-interface.sh also uses a function-sentinel guard (declare -f load_provider) and returns immediately when load_provider is already defined.
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$LIB_DIR/core/assess-documentation.sh" 2>/dev/null || true

  # Runbook §3: restore flags after last source.
  set +u; set +o pipefail

  # Re-stub print_* AFTER last source (runbook §2).
  print_info() { :; }
  print_warning() { :; }
  verbose_info() { :; }
  print_error() { :; }

  # Trigger C state file present for all tests so the consent gate is the only
  # reason entries would be withheld.
  printf 'docs/architecture/behavioral-design.md' \
    > "$RITE_STATE_DIR/declared-doc-fix-test.txt"
}

teardown() {
  cd /
  rm -rf "$_TMPDIR"
}

# ---------------------------------------------------------------------------
# 1. No drift entry when RITE_DOC_MODE is unset
# ---------------------------------------------------------------------------

@test "_record_tier1_drift_entries: no entry when RITE_DOC_MODE is unset" {
  unset RITE_DOC_MODE

  _record_tier1_drift_entries \
    "10" "Closes #9" "lib/core/foo.sh" "main" "fix/test"

  _log_path="$(drift_log_path)"
  [ ! -f "$_log_path" ]
}

# ---------------------------------------------------------------------------
# 2. No drift entry when RITE_DOC_MODE=off
# ---------------------------------------------------------------------------

@test "_record_tier1_drift_entries: no entry when RITE_DOC_MODE=off" {
  export RITE_DOC_MODE="off"

  _record_tier1_drift_entries \
    "10" "Closes #9" "lib/core/foo.sh" "main" "fix/test"

  _log_path="$(drift_log_path)"
  [ ! -f "$_log_path" ]
}

# ---------------------------------------------------------------------------
# 3. Drift entry IS recorded when RITE_DOC_MODE=changelog (positive control)
# ---------------------------------------------------------------------------

@test "_record_tier1_drift_entries: entry recorded when RITE_DOC_MODE=changelog" {
  export RITE_DOC_MODE="changelog"

  _record_tier1_drift_entries \
    "10" "Closes #9" "lib/core/foo.sh" "main" "fix/test"

  _log_path="$(drift_log_path)"
  [ -f "$_log_path" ]
  _count="$(drift_log_entry_count "$_log_path")"
  [ "$_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 4. Drift entry IS recorded when RITE_DOC_MODE=sync (positive control)
# ---------------------------------------------------------------------------

@test "_record_tier1_drift_entries: entry recorded when RITE_DOC_MODE=sync" {
  export RITE_DOC_MODE="sync"

  _record_tier1_drift_entries \
    "10" "Closes #9" "lib/core/foo.sh" "main" "fix/test"

  _log_path="$(drift_log_path)"
  [ -f "$_log_path" ]
  _count="$(drift_log_entry_count "$_log_path")"
  [ "$_count" -eq 1 ]
}
