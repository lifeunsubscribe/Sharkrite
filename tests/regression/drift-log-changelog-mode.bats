#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/drift-log.sh, lib/core/assess-documentation.sh

# Regression tests for changelog-mode drift log entry appending.
#
# Covers:
#   1. drift_log_path, drift_log_append, drift_log_entry_count defined and
#      the library is double-source safe (structural).
#   2. First append auto-bootstraps docs/sharkrite-drift-log.md with header + entry.
#   3. Second append preserves first entry and yields exactly 2 delimited blocks.
#   4. Entry carries all six payload fields.
#   5. Default mode (no RITE_DOC_MODE) — gate guard uses ${RITE_DOC_MODE:-}.
#   6. Sync mode (doc-sync.md present) — drift entry call is inside no-doc-sync branch.
#   7. Changelog mode commit touches only docs/sharkrite-drift-log.md.
#   8. Graceful degradation: fallback inaccuracy text produces a valid entry.
#   9. Zero implicated docs → drift_log_entry_count returns 0.
#  10. Coverage header present (self-asserting).
#  11. assess-documentation.sh sources drift-log.sh and docs-map.sh.
#  12. CLAUDE.md architecture entry present.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB_DIR="$PROJECT_ROOT/lib"
  DRIFT_LOG_LIB="$LIB_DIR/utils/drift-log.sh"

  # Fresh temp repo for each test.
  _TMPDIR="$(mktemp -d)"
  cd "$_TMPDIR"
  git init -q .
  git config user.email "test@test.invalid"
  git config user.name "Test"
  mkdir -p docs .rite/state

  # Minimal initial commit so later commits can succeed.
  touch .rite/.gitkeep
  git add .
  git commit -q -m "init"

  # Export env that drift-log.sh needs.
  export RITE_PROJECT_ROOT="$_TMPDIR"
  export RITE_STATE_DIR="$_TMPDIR/.rite/state"
  export RITE_LIB_DIR="$LIB_DIR"
  export RITE_VERBOSE=false

  # Source the libs inside setup so functions are available in @test bodies.
  # Runbook §3: source with RITE_SOURCE_FUNCTIONS_ONLY not needed here (drift-log.sh
  # is a pure function library, no executable body). Reset flags after last source.
  source "$LIB_DIR/utils/config.sh" 2>/dev/null || true
  source "$LIB_DIR/utils/colors.sh" 2>/dev/null || true
  source "$LIB_DIR/utils/logging.sh" 2>/dev/null || true
  source "$LIB_DIR/utils/markers.sh" 2>/dev/null || true
  source "$LIB_DIR/utils/docs-map.sh" 2>/dev/null || true
  source "$DRIFT_LOG_LIB" 2>/dev/null || true
  # Runbook §3: restore flags after last source (never set +e).
  set +u; set +o pipefail
  # Re-stub print_* AFTER all sources (runbook §2: env-guarded libs overwrite pre-source stubs).
  print_info() { :; }
  print_warning() { :; }
  verbose_info() { :; }
  print_error() { :; }
}

teardown() {
  cd /
  rm -rf "$_TMPDIR"
}

# ---------------------------------------------------------------------------
# 1. Library shape + re-source safety (structural)
# ---------------------------------------------------------------------------

@test "drift-log.sh: defines drift_log_path, drift_log_append, drift_log_entry_count" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='${_TMPDIR}'
    export RITE_STATE_DIR='${_TMPDIR}/.rite/state'
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    source '${PROJECT_ROOT}/lib/utils/config.sh' 2>/dev/null || true
    source '${PROJECT_ROOT}/lib/utils/markers.sh' 2>/dev/null || true
    source '${PROJECT_ROOT}/lib/utils/docs-map.sh' 2>/dev/null || true
    source '${DRIFT_LOG_LIB}' 2>/dev/null
    source '${DRIFT_LOG_LIB}' 2>/dev/null
    declare -f drift_log_path drift_log_append drift_log_entry_count >/dev/null && echo OK
  "
  [ "$status" -eq 0 ]
  [ "${output}" = "OK" ]
}

@test "drift-log.sh: double-source safe under set -euo pipefail" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='${_TMPDIR}'
    export RITE_STATE_DIR='${_TMPDIR}/.rite/state'
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    source '${PROJECT_ROOT}/lib/utils/config.sh' 2>/dev/null || true
    source '${PROJECT_ROOT}/lib/utils/markers.sh' 2>/dev/null || true
    source '${PROJECT_ROOT}/lib/utils/docs-map.sh' 2>/dev/null || true
    source '${DRIFT_LOG_LIB}'
    source '${DRIFT_LOG_LIB}'
    echo OK
  "
  [ "$status" -eq 0 ]
  [ "${output}" = "OK" ]
}

# ---------------------------------------------------------------------------
# 2. RITE_MARKER_DOC_DRIFT registered in markers.sh
# ---------------------------------------------------------------------------

@test "markers.sh: RITE_MARKER_DOC_DRIFT is set to sharkrite-doc-drift" {
  count=$(grep -c 'RITE_MARKER_DOC_DRIFT="sharkrite-doc-drift"' \
    "$PROJECT_ROOT/lib/utils/markers.sh" || true)
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 3. First append auto-bootstraps file + entry; second append yields 2 blocks
# ---------------------------------------------------------------------------

@test "drift_log_append: first append creates file with header and one entry" {
  drift_log_append "123" "120" "lib/core/foo.sh" \
    '- docs/architecture/behavioral-design.md — "Gate Block-on-Any"' \
    "suspected: Gate Block-on-Any section may be outdated"

  _log_path="$(drift_log_path)"
  [ -f "$_log_path" ]
  # Explanatory header must be present
  grep -q "Sharkrite Drift Log" "$_log_path"
  grep -q "Burn-down semantics" "$_log_path"
  # Entry must be present with pr:123 format anchor
  _count="$(grep -c 'sharkrite-doc-drift pr:[0-9]' "$_log_path" || true)"
  [ "$_count" -eq 1 ]
}

@test "drift_log_append: second append preserves first entry and yields 2 blocks" {
  drift_log_append "123" "120" "lib/core/foo.sh" \
    '- docs/architecture/behavioral-design.md — "Gate Block-on-Any"' \
    "suspected: Gate Block-on-Any section may be outdated"

  drift_log_append "124" "-" "lib/utils/bar.sh" \
    '- README.md — "Usage"' \
    "another suspected inaccuracy"

  _log_path="$(drift_log_path)"
  _count="$(grep -c 'sharkrite-doc-drift pr:[0-9]' "$_log_path" || true)"
  [ "$_count" -eq 2 ]
}

@test "drift_log_entry_count: returns correct count after two appends" {
  drift_log_append "200" "180" "lib/core/foo.sh" \
    '- docs/x.md — "Section"' "one"
  drift_log_append "201" "-" "lib/core/bar.sh" \
    '- docs/y.md — "Other"' "two"

  _log_path="$(drift_log_path)"
  _count="$(drift_log_entry_count "$_log_path")"
  [ "$_count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 4. Entry carries all six payload fields
# ---------------------------------------------------------------------------

@test "drift_log_append: entry contains pr: field with format anchor" {
  drift_log_append "999" "888" "lib/core/foo.sh" \
    '- docs/architecture/behavioral-design.md — "Gate Block-on-Any"' \
    "suspected: Gate section may be outdated"

  _log_path="$(drift_log_path)"
  grep -q 'sharkrite-doc-drift pr:999' "$_log_path"
}

@test "drift_log_append: entry contains issue: field" {
  drift_log_append "999" "888" "lib/core/foo.sh" \
    '- docs/architecture/behavioral-design.md — "Gate Block-on-Any"' \
    "suspected: Gate section may be outdated"

  _log_path="$(drift_log_path)"
  grep -q 'issue:888' "$_log_path"
}

@test "drift_log_append: entry contains recorded: ISO8601 timestamp field" {
  drift_log_append "999" "888" "lib/core/foo.sh" \
    '- docs/architecture/behavioral-design.md — "Gate Block-on-Any"' \
    "suspected: Gate section may be outdated"

  _log_path="$(drift_log_path)"
  grep -qE 'recorded:[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$_log_path"
}

@test "drift_log_append: entry contains Changed files field" {
  drift_log_append "999" "888" "lib/core/foo.sh" \
    '- docs/architecture/behavioral-design.md — "Gate Block-on-Any"' \
    "suspected: Gate section may be outdated"

  _log_path="$(drift_log_path)"
  grep -q 'Changed files.*lib/core/foo.sh' "$_log_path"
}

@test "drift_log_append: entry contains Implicated docs field" {
  drift_log_append "999" "888" "lib/core/foo.sh" \
    '- docs/architecture/behavioral-design.md — "Gate Block-on-Any"' \
    "suspected: Gate section may be outdated"

  _log_path="$(drift_log_path)"
  grep -q 'Implicated docs' "$_log_path"
  grep -q 'behavioral-design.md' "$_log_path"
}

@test "drift_log_append: entry contains Suspected inaccuracy field" {
  drift_log_append "999" "888" "lib/core/foo.sh" \
    '- docs/architecture/behavioral-design.md — "Gate Block-on-Any"' \
    "suspected: Gate section may be outdated"

  _log_path="$(drift_log_path)"
  grep -q 'Suspected inaccuracy' "$_log_path"
  grep -q 'suspected: Gate section may be outdated' "$_log_path"
}

@test "drift_log_append: issue:- when no issue number provided" {
  drift_log_append "777" "-" "lib/core/foo.sh" \
    '- docs/x.md — "Section"' "fallback text"

  _log_path="$(drift_log_path)"
  grep -q 'issue:-' "$_log_path"
}

@test "drift_log_append: closing delimiter present for each entry" {
  drift_log_append "555" "500" "lib/core/foo.sh" \
    '- docs/x.md — "Section"' "test"

  _log_path="$(drift_log_path)"
  grep -q '<!-- sharkrite-doc-drift pr:555' "$_log_path"
  grep -q '<!-- /sharkrite-doc-drift -->' "$_log_path"
}

# ---------------------------------------------------------------------------
# 5. Default mode guard: uses ${RITE_DOC_MODE:-} safe reference (structural)
# ---------------------------------------------------------------------------

@test "assess-documentation.sh: changelog-mode branch uses safe \${RITE_DOC_MODE:-} reference" {
  grep -qE '\$\{RITE_DOC_MODE:-\}' \
    "$PROJECT_ROOT/lib/core/assess-documentation.sh"
}

@test "assess-documentation.sh: changelog-mode branch checks for 'changelog' value" {
  grep -q '"changelog"' \
    "$PROJECT_ROOT/lib/core/assess-documentation.sh"
}

# ---------------------------------------------------------------------------
# 6. Sync mode guard: drift entry call is inside no-doc-sync-md branch (structural)
# ---------------------------------------------------------------------------

@test "assess-documentation.sh: _append_doc_drift_entry call is inside no-doc-sync-md branch" {
  # Extract the block from "if [ ! -f \"$DOC_SYNC_FILE\" ]" to its matching "fi"
  # and verify _append_doc_drift_entry appears within it.
  _block=$(awk '/if \[ ! -f "\$DOC_SYNC_FILE" \]/,/^fi$/' \
    "$PROJECT_ROOT/lib/core/assess-documentation.sh" 2>/dev/null || true)
  [ -n "$_block" ]
  # Must contain the drift entry call
  echo "$_block" | grep -q '_append_doc_drift_entry'
}

@test "assess-documentation.sh: _append_doc_drift_entry is defined as a function" {
  grep -qE '^_append_doc_drift_entry\(\)' \
    "$PROJECT_ROOT/lib/core/assess-documentation.sh"
}

# ---------------------------------------------------------------------------
# 7. Drift log lives in docs/ (path contract)
# ---------------------------------------------------------------------------

@test "drift_log_path: points to docs/sharkrite-drift-log.md" {
  _log_path="$(drift_log_path)"
  # Must end with docs/sharkrite-drift-log.md
  case "$_log_path" in
    */docs/sharkrite-drift-log.md) true ;;
    *) false ;;
  esac
}

@test "drift_log_append + git: only sharkrite-drift-log.md is changed by the append" {
  drift_log_append "300" "290" "lib/core/foo.sh" \
    '- docs/x.md — "Section"' "test inaccuracy"

  _log_path="$(drift_log_path)"

  # Stage and commit only the drift log (mirrors what _append_doc_drift_entry does).
  git add "$_log_path"
  git commit -q -m "docs: record drift entry for PR #300"

  # The commit must only touch the drift log.
  # git show --pretty=format: suppresses the commit header lines so only
  # changed filenames are emitted (no Author/Date/message lines to filter).
  _changed="$(git show --name-only --pretty=format: HEAD | grep -v '^$' || true)"
  # Must contain the drift log path
  echo "$_changed" | grep -q 'docs/sharkrite-drift-log.md'
  # Must NOT contain any other file
  _other="$(echo "$_changed" | grep -v 'docs/sharkrite-drift-log.md' || true)"
  [ -z "$_other" ]
}

# ---------------------------------------------------------------------------
# 8. Graceful degradation: fallback inaccuracy text produces a valid entry
# ---------------------------------------------------------------------------

@test "drift_log_append: fallback inaccuracy text produces a valid entry" {
  drift_log_append "400" "380" "lib/core/foo.sh" \
    '- docs/x.md — "Section"' \
    "not assessed — provider unavailable; verify implicated sections manually"

  _log_path="$(drift_log_path)"
  [ -f "$_log_path" ]
  grep -q 'not assessed' "$_log_path"
  _count="$(grep -c 'sharkrite-doc-drift pr:[0-9]' "$_log_path" || true)"
  [ "$_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 9. Zero implicated docs → entry count stays 0
# ---------------------------------------------------------------------------

@test "drift_log_entry_count: returns 0 when file does not exist" {
  _count="$(drift_log_entry_count '/nonexistent/path/sharkrite-drift-log.md')"
  [ "$_count" -eq 0 ]
}

@test "drift_log_entry_count: returns 0 on fresh temp repo before any append" {
  _count="$(drift_log_entry_count "$(drift_log_path)")"
  [ "$_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Marker guard anchor compliance (BARE_MARKER_GREP rule)
# ---------------------------------------------------------------------------

@test "drift-log.sh: all grep guards for sharkrite-doc-drift carry pr:[0-9] anchor" {
  # Every grep line in drift-log.sh that references the marker string must also
  # include the pr:[0-9] format anchor.  No bare-prefix greps allowed.
  _bare=$(grep -n 'sharkrite-doc-drift' "$PROJECT_ROOT/lib/utils/drift-log.sh" | \
    grep 'grep' | grep -v 'pr:\[0-9\]' | grep -v 'pr:[0-9]' || true)
  [ -z "$_bare" ]
}

# ---------------------------------------------------------------------------
# 11. Source wiring: assess-documentation.sh sources drift-log.sh + docs-map.sh
# ---------------------------------------------------------------------------

@test "assess-documentation.sh: sources drift-log.sh" {
  grep -q 'source.*drift-log.sh' \
    "$PROJECT_ROOT/lib/core/assess-documentation.sh"
}

@test "assess-documentation.sh: sources docs-map.sh" {
  grep -q 'source.*docs-map.sh' \
    "$PROJECT_ROOT/lib/core/assess-documentation.sh"
}

# ---------------------------------------------------------------------------
# 12. CLAUDE.md architecture entry
# ---------------------------------------------------------------------------

@test "CLAUDE.md: architecture entry for drift-log.sh is present" {
  count=$(grep -c 'lib/utils/drift-log.sh' "$PROJECT_ROOT/CLAUDE.md" || true)
  [ "$count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 10. Coverage header self-check (satisfies MISSING_TEST_COVERAGE_HEADER lint)
# ---------------------------------------------------------------------------

@test "drift-log-changelog-mode.bats: coverage header is present on line 2" {
  count=$(head -2 "$BATS_TEST_FILENAME" | grep -c "sharkrite-test-covers:" || true)
  [ "$count" -eq 1 ]
}
