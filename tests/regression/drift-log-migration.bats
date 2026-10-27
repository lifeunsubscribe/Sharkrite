#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/drift-log.sh::migrate_legacy_drift_log

# Tests for migrate_legacy_drift_log: one-time conversion of the legacy
# docs/sharkrite-drift-log.md flat format into per-doc schema entries.
#
# Covers:
#   1. Parseable entries land as schema entries with correct doc/pr fields;
#      branch defaults to main when the legacy entry names none.
#   2. Unparseable content (no implicated docs) produces a catch-all
#      kind=reference-missing entry naming the archived source.
#   3. Original archived to .rite/state/drift/legacy-archive.md; migration
#      is idempotent — second call is a no-op.
#   4. Missing legacy file → silent no-op (no schema entries, no archive).

_FIXTURE_PARSEABLE='<!-- sharkrite-doc-drift pr:1299 issue:1231 recorded:2026-10-15T12:31:37Z -->
**Changed files**: lib/core/docs-command.sh, tests/regression/foo.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: CLAUDE.md omits the new pre-call warning for cap-excluded files.
<!-- /sharkrite-doc-drift -->'

_FIXTURE_UNPARSEABLE='<!-- sharkrite-doc-drift pr:1302 issue:1300 recorded:2026-10-16T09:00:00Z -->
**Changed files**: lib/utils/something.sh
**Implicated docs**:
**Suspected inaccuracy**: not assessed — provider unavailable
<!-- /sharkrite-doc-drift -->'

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB_DIR="$PROJECT_ROOT/lib"

  _TMPDIR="$(mktemp -d)"
  cd "$_TMPDIR"
  git init -q .
  git config user.email "test@test.invalid"
  git config user.name "Test"
  mkdir -p docs .rite/state

  export RITE_PROJECT_ROOT="$_TMPDIR"
  export RITE_STATE_DIR="$_TMPDIR/.rite/state"
  export RITE_LIB_DIR="$LIB_DIR"
  export RITE_VERBOSE=false

  source "$LIB_DIR/utils/config.sh" 2>/dev/null || true
  source "$LIB_DIR/utils/colors.sh" 2>/dev/null || true
  source "$LIB_DIR/utils/logging.sh" 2>/dev/null || true
  source "$LIB_DIR/utils/lock.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: drift-log.sh uses a function-sentinel guard (declare -f drift_log_append); no pre-source stubs are defined before this source.
  source "$LIB_DIR/utils/drift-log.sh" 2>/dev/null || true
  # Runbook §3: restore flags after last source.
  set +u; set +o pipefail
  print_info() { :; }
  print_warning() { :; }
}

teardown() {
  cd /
  rm -rf "$_TMPDIR"
}

# ---------------------------------------------------------------------------
# 1. Parseable entries → schema entries with correct doc/pr/branch fields
# ---------------------------------------------------------------------------

@test "migrate_legacy_drift_log: parseable entry creates schema entries per implicated doc" {
  printf '%s\n' "$_FIXTURE_PARSEABLE" > "$_TMPDIR/docs/sharkrite-drift-log.md"

  migrate_legacy_drift_log

  # Two implicated docs → two entries, each on branch=main
  local count_bd count_claude
  count_bd="$(drift_log_entry_count --doc "docs/architecture/behavioral-design.md" --branch "main")"
  count_claude="$(drift_log_entry_count --doc "CLAUDE.md" --branch "main")"
  [ "$count_bd" -eq 1 ]
  [ "$count_claude" -eq 1 ]
}

@test "migrate_legacy_drift_log: schema entry has correct pr field" {
  printf '%s\n' "$_FIXTURE_PARSEABLE" > "$_TMPDIR/docs/sharkrite-drift-log.md"

  migrate_legacy_drift_log

  local entry_file
  entry_file="$(_drift_entry_path "docs/architecture/behavioral-design.md" "main")"
  grep -q 'pr=1299' "$entry_file"
}

@test "migrate_legacy_drift_log: branch defaults to main for legacy entries" {
  printf '%s\n' "$_FIXTURE_PARSEABLE" > "$_TMPDIR/docs/sharkrite-drift-log.md"

  migrate_legacy_drift_log

  local entry_file
  entry_file="$(_drift_entry_path "CLAUDE.md" "main")"
  grep -q 'branch=main' "$entry_file"
}

# ---------------------------------------------------------------------------
# 2. Unparseable content → catch-all reference-missing entry
# ---------------------------------------------------------------------------

@test "migrate_legacy_drift_log: block with empty doc list becomes catch-all reference-missing entry" {
  printf '%s\n' "$_FIXTURE_UNPARSEABLE" > "$_TMPDIR/docs/sharkrite-drift-log.md"

  migrate_legacy_drift_log

  local archive_rel=".rite/state/drift/legacy-archive.md"
  local count
  count="$(drift_log_entry_count --doc "$archive_rel" --branch "main")"
  [ "$count" -ge 1 ]

  local entry_file
  entry_file="$(_drift_entry_path "$archive_rel" "main")"
  grep -q 'kind=reference-missing' "$entry_file"
}

# ---------------------------------------------------------------------------
# 3. Archive created; idempotence — second run is a no-op
# ---------------------------------------------------------------------------

@test "migrate_legacy_drift_log: archives original at RITE_STATE_DIR/drift/legacy-archive.md" {
  printf '%s\n' "$_FIXTURE_PARSEABLE" > "$_TMPDIR/docs/sharkrite-drift-log.md"

  migrate_legacy_drift_log

  [ -f "$RITE_STATE_DIR/drift/legacy-archive.md" ]
}

@test "migrate_legacy_drift_log: removes original legacy file after migration" {
  printf '%s\n' "$_FIXTURE_PARSEABLE" > "$_TMPDIR/docs/sharkrite-drift-log.md"

  migrate_legacy_drift_log

  [ ! -f "$_TMPDIR/docs/sharkrite-drift-log.md" ]
}

@test "migrate_legacy_drift_log: second call is a no-op (idempotent)" {
  printf '%s\n' "$_FIXTURE_PARSEABLE" > "$_TMPDIR/docs/sharkrite-drift-log.md"

  migrate_legacy_drift_log

  local count_after_first
  count_after_first="$(drift_log_entry_count --total)"

  # Re-create legacy file to confirm second run doesn't re-process it
  mkdir -p "$_TMPDIR/docs"
  printf '%s\n' "$_FIXTURE_PARSEABLE" > "$_TMPDIR/docs/sharkrite-drift-log.md"

  migrate_legacy_drift_log

  local count_after_second
  count_after_second="$(drift_log_entry_count --total)"

  [ "$count_after_first" -eq "$count_after_second" ]
}

# ---------------------------------------------------------------------------
# 4. Missing legacy file → silent no-op
# ---------------------------------------------------------------------------

@test "migrate_legacy_drift_log: missing legacy file is a silent no-op" {
  [ ! -f "$_TMPDIR/docs/sharkrite-drift-log.md" ]

  migrate_legacy_drift_log

  [ ! -f "$RITE_STATE_DIR/drift/legacy-archive.md" ]
  local total
  total="$(drift_log_entry_count --total)"
  [ "$total" -eq 0 ]
}
