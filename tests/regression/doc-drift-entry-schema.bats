#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/drift-log.sh::drift_log_append|drift_log_entry_count|_drift_entry_path|_drift_kind_valid

# Tests for the structured per-doc/per-branch drift entry schema.
#
# Covers:
#   1. Per-doc/per-branch entry file layout, including release/1.2-style branch names.
#   2. drift_log_append writes all eight fields correctly.
#   3. kind validation: invalid value → non-zero + stderr; all valid values accepted.
#   4. Accumulate-in-place: same (doc, assertion) appends PR to existing entry.
#   5. Different assertion → new entry line in the same file.
#   6. drift_log_entry_count --branch, --doc, --doc --branch, total (no args).
#   7. drift_log_entry_count FILE_PATH: legacy flat-log mode kept working.
#   8. Concurrent-append safety: lock_acquire/lock_release used (structural).

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB_DIR="$PROJECT_ROOT/lib"
  DRIFT_LOG_LIB="$LIB_DIR/utils/drift-log.sh"

  _TMPDIR="$(mktemp -d)"
  cd "$_TMPDIR"

  export RITE_PROJECT_ROOT="$_TMPDIR"
  export RITE_STATE_DIR="$_TMPDIR/.rite/state"
  export RITE_LIB_DIR="$LIB_DIR"
  export RITE_VERBOSE=false

  mkdir -p "$RITE_STATE_DIR"

  # Source deps in order; lock.sh before drift-log.sh so the guard in
  # drift-log.sh sees lock_acquire already defined.
  source "$LIB_DIR/utils/config.sh" 2>/dev/null || true
  source "$LIB_DIR/utils/colors.sh" 2>/dev/null || true
  source "$LIB_DIR/utils/logging.sh" 2>/dev/null || true
  source "$LIB_DIR/utils/lock.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: drift-log.sh uses a function-sentinel guard (declare -f drift_log_append); no pre-source stubs are defined before this source.
  source "$DRIFT_LOG_LIB" 2>/dev/null || true
  # Runbook §3: restore flags after last source (never set +e).
  set +u; set +o pipefail
  # Re-stub print_* AFTER all sources (runbook §2).
  print_info() { :; }
  print_warning() { :; }
}

teardown() {
  cd /
  rm -rf "$_TMPDIR"
}

# ---------------------------------------------------------------------------
# 1. Per-doc/per-branch layout
# ---------------------------------------------------------------------------

@test "_drift_entry_path: creates correct path for main branch" {
  local expected_slug="docs--architecture--behavioral-design.md"
  local result
  result="$(_drift_entry_path "docs/architecture/behavioral-design.md" "main")"
  case "$result" in
    *"/doc-drift/main/${expected_slug}.log") true ;;
    *) false ;;
  esac
}

@test "drift_log_append: entry file is created under RITE_STATE_DIR/doc-drift" {
  drift_log_append "docs/architecture/behavioral-design.md" "main" \
    "97" "42" "Gate Block-on-Any" "addition" "lib/utils/test-gate.sh"

  local entry_file
  entry_file="$(_drift_entry_path "docs/architecture/behavioral-design.md" "main")"
  [ -f "$entry_file" ]
}

@test "drift_log_append: release/1.2-style branch creates nested directory" {
  drift_log_append "docs/foo.md" "release/1.2" \
    "99" "50" "assertion text" "addition" "lib/utils/bar.sh"

  local entry_file
  entry_file="$(_drift_entry_path "docs/foo.md" "release/1.2")"
  [ -f "$entry_file" ]
  [ -d "$RITE_STATE_DIR/doc-drift/release/1.2" ]
}

@test "_drift_entry_path: doc slug replaces all / with -- for release/1.2 branch" {
  local result
  result="$(_drift_entry_path "docs/architecture/adr-001.md" "release/1.2")"
  case "$result" in
    *"/doc-drift/release/1.2/docs--architecture--adr-001.md.log") true ;;
    *) false ;;
  esac
}

# ---------------------------------------------------------------------------
# 2. Eight fields
# ---------------------------------------------------------------------------

@test "drift_log_append: entry line contains all eight tab-separated fields" {
  drift_log_append "docs/architecture/behavioral-design.md" "main" \
    "97" "42" "Gate Block-on-Any" "addition" "lib/utils/test-gate.sh"

  local entry_file entry
  entry_file="$(_drift_entry_path "docs/architecture/behavioral-design.md" "main")"
  entry="$(cat "$entry_file")"

  echo "$entry" | grep -q "doc=docs/architecture/behavioral-design.md"
  echo "$entry" | grep -q "branch=main"
  echo "$entry" | grep -qE "pr=[0-9]"
  echo "$entry" | grep -qE "issue=[0-9]"
  echo "$entry" | grep -q "assertion=Gate Block-on-Any"
  echo "$entry" | grep -q "kind=addition"
  echo "$entry" | grep -q "evidence=lib/utils/test-gate.sh"
  echo "$entry" | grep -qE "recorded=[0-9]{4}-[0-9]{2}-[0-9]{2}T"
}

@test "drift_log_append: issue=- when no issue number provided" {
  drift_log_append "docs/foo.md" "main" "1" "-" "" "addition" "evidence"

  local entry_file
  entry_file="$(_drift_entry_path "docs/foo.md" "main")"
  grep -q "issue=-" "$entry_file"
}

@test "drift_log_append: empty assertion stored as assertion= (empty value)" {
  drift_log_append "docs/foo.md" "main" "1" "-" "" "addition" "evidence"

  local entry_file
  entry_file="$(_drift_entry_path "docs/foo.md" "main")"
  grep -q "assertion=" "$entry_file"
}

# ---------------------------------------------------------------------------
# 3. KIND validation
# ---------------------------------------------------------------------------

@test "drift_log_append: invalid kind returns non-zero exit" {
  run drift_log_append "docs/foo.md" "main" "1" "-" "A" "invalid-kind" "evidence"
  [ "$status" -ne 0 ]
}

@test "drift_log_append: invalid kind prints error to stderr" {
  run drift_log_append "docs/foo.md" "main" "1" "-" "A" "bad-kind" "evidence"
  # bats captures stderr in $output when using 'run'
  echo "$output" | grep -qi "invalid kind"
}

@test "drift_log_append: invalid kind does not create entry file" {
  run drift_log_append "docs/foo.md" "main" "1" "-" "A" "invalid-kind" "evidence"
  local entry_file
  entry_file="$(_drift_entry_path "docs/foo.md" "main")"
  [ ! -f "$entry_file" ]
}

@test "drift_log_append: all five valid kind values are accepted" {
  local doc_base="docs/kind-test"
  local kinds="addition refinement contradiction test-scope reference-missing"
  for kind in $kinds; do
    run drift_log_append "${doc_base}-${kind}.md" "main" "1" "-" "A" "$kind" "ev"
    [ "$status" -eq 0 ]
  done
}

# ---------------------------------------------------------------------------
# 4. Accumulate-in-place: same (doc, assertion) appends PR, no duplicate
# ---------------------------------------------------------------------------

@test "drift_log_append: repeat (doc, assertion) appends PR to existing entry" {
  drift_log_append "docs/architecture/behavioral-design.md" "main" \
    "97" "42" "Gate Block-on-Any" "addition" "lib/utils/test-gate.sh"
  drift_log_append "docs/architecture/behavioral-design.md" "main" \
    "98" "43" "Gate Block-on-Any" "refinement" "lib/utils/gate-runners.sh"

  local entry_file
  entry_file="$(_drift_entry_path "docs/architecture/behavioral-design.md" "main")"

  # Only ONE entry line (not two)
  local line_count
  line_count="$(grep -c 'doc=' "$entry_file" || true)"
  [ "$line_count" -eq 1 ]

  # Both PR numbers present in the pr= field
  grep -q "pr=97,98" "$entry_file"
}

@test "drift_log_append: different assertion creates a second entry" {
  drift_log_append "docs/architecture/behavioral-design.md" "main" \
    "97" "42" "Gate Block-on-Any" "addition" "evidence-a"
  drift_log_append "docs/architecture/behavioral-design.md" "main" \
    "98" "43" "Phase 3 Parallelism" "addition" "evidence-b"

  local entry_file
  entry_file="$(_drift_entry_path "docs/architecture/behavioral-design.md" "main")"

  local line_count
  line_count="$(grep -c 'doc=' "$entry_file" || true)"
  [ "$line_count" -eq 2 ]
}

@test "drift_log_append: different branch creates separate entry file, not accumulation" {
  drift_log_append "docs/architecture/behavioral-design.md" "main" \
    "97" "42" "Gate Block-on-Any" "addition" "evidence"
  drift_log_append "docs/architecture/behavioral-design.md" "feature-x" \
    "98" "43" "Gate Block-on-Any" "addition" "evidence"

  local ef_main ef_feat
  ef_main="$(_drift_entry_path "docs/architecture/behavioral-design.md" "main")"
  ef_feat="$(_drift_entry_path "docs/architecture/behavioral-design.md" "feature-x")"

  # Each branch has its own file with one entry
  local count_main count_feat
  count_main="$(grep -c 'doc=' "$ef_main" || true)"
  count_feat="$(grep -c 'doc=' "$ef_feat" || true)"
  [ "$count_main" -eq 1 ]
  [ "$count_feat" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 5. drift_log_entry_count new modes
# ---------------------------------------------------------------------------

@test "drift_log_entry_count --branch: counts entries for a specific branch" {
  drift_log_append "docs/a.md" "feature-x" "1" "-" "A1" "addition" "ev"
  drift_log_append "docs/b.md" "feature-x" "2" "-" "B1" "addition" "ev"
  drift_log_append "docs/a.md" "main" "3" "-" "A1" "addition" "ev"

  local count
  count="$(drift_log_entry_count --branch feature-x)"
  [ "$count" -eq 2 ]
}

@test "drift_log_entry_count --doc: counts entries for a doc across all branches" {
  drift_log_append "docs/a.md" "main" "1" "-" "A1" "addition" "ev"
  drift_log_append "docs/a.md" "feature-x" "2" "-" "A2" "addition" "ev"
  drift_log_append "docs/b.md" "main" "3" "-" "B1" "addition" "ev"

  local count
  count="$(drift_log_entry_count --doc docs/a.md)"
  [ "$count" -eq 2 ]
}

@test "drift_log_entry_count --doc --branch: counts in specific (doc,branch) file" {
  drift_log_append "docs/a.md" "main" "1" "-" "A1" "addition" "ev"
  drift_log_append "docs/a.md" "main" "2" "-" "A2" "addition" "ev"
  drift_log_append "docs/a.md" "feature-x" "3" "-" "A1" "addition" "ev"

  local count
  count="$(drift_log_entry_count --doc docs/a.md --branch main)"
  [ "$count" -eq 2 ]
}

@test "drift_log_entry_count (no args): returns total across all docs and branches" {
  drift_log_append "docs/a.md" "main" "1" "-" "A1" "addition" "ev"
  drift_log_append "docs/b.md" "main" "2" "-" "B1" "addition" "ev"
  drift_log_append "docs/a.md" "feature-x" "3" "-" "A1" "addition" "ev"

  local count
  count="$(drift_log_entry_count)"
  [ "$count" -eq 3 ]
}

@test "drift_log_entry_count: returns 0 for nonexistent branch" {
  local count
  count="$(drift_log_entry_count --branch no-such-branch)"
  [ "$count" -eq 0 ]
}

@test "drift_log_entry_count: returns 0 for nonexistent doc" {
  local count
  count="$(drift_log_entry_count --doc docs/no-such-doc.md)"
  [ "$count" -eq 0 ]
}

@test "drift_log_entry_count: returns 0 when state dir has no doc-drift subdir" {
  local count
  count="$(drift_log_entry_count)"
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 6. Legacy FILE_PATH mode backward compat
# ---------------------------------------------------------------------------

@test "drift_log_entry_count FILE_PATH: counts blocks in a legacy flat-log file" {
  local legacy_log="$_TMPDIR/legacy-drift-log.md"
  # Two entries in the old <!-- sharkrite-doc-drift pr:N --> format.
  printf '<!-- sharkrite-doc-drift pr:1 issue:- recorded:2026-01-01T00:00:00Z -->\n' > "$legacy_log"
  printf 'foo\n<!-- /sharkrite-doc-drift -->\n' >> "$legacy_log"
  printf '<!-- sharkrite-doc-drift pr:2 issue:- recorded:2026-01-02T00:00:00Z -->\n' >> "$legacy_log"
  printf 'bar\n<!-- /sharkrite-doc-drift -->\n' >> "$legacy_log"

  local count
  count="$(drift_log_entry_count "$legacy_log")"
  [ "$count" -eq 2 ]
}

@test "drift_log_entry_count FILE_PATH: returns 0 for nonexistent file" {
  local count
  count="$(drift_log_entry_count "/nonexistent/path/drift-log.md")"
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 7. Concurrent-append safety: structural check
# ---------------------------------------------------------------------------

@test "drift_log_append: uses lock_acquire for concurrent-append safety" {
  # Structural check: lock_acquire must appear in drift_log_append's body.
  # Extract the function body and verify it references lock_acquire.
  local body
  body="$(declare -f drift_log_append)"
  echo "$body" | grep -q "lock_acquire"
}

@test "drift_log_append: uses lock_release after write" {
  local body
  body="$(declare -f drift_log_append)"
  echo "$body" | grep -q "lock_release"
}

# ---------------------------------------------------------------------------
# 8. Coverage header self-check (MISSING_TEST_COVERAGE_HEADER lint)
# ---------------------------------------------------------------------------

@test "doc-drift-entry-schema.bats: coverage header present on line 2" {
  count=$(head -2 "$BATS_TEST_FILENAME" | grep -c "sharkrite-test-covers:" || true)
  [ "$count" -eq 1 ]
}
