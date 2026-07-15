#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/docs-map.sh
# Regression tests for the deterministic docs-map builder.
#
# Tests use a temporary fixture repo so they are hermetic — they do not
# depend on the shape of the sharkrite repo itself (which has no *adr*.md
# files, making ADR flagging untestable without a fixture).

setup() {
  # RITE_REPO_ROOT is the sharkrite source root (set by lib-resource-safety
  # convention; derive it from the test file location for standalone runs).
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT

  # Create a temporary fixture repo for each test
  FIXTURE_DIR="$(mktemp -d)"
  export FIXTURE_DIR

  # Initialise as a git repo so docs_map_build can call git rev-parse HEAD
  git -C "$FIXTURE_DIR" init -q
  git -C "$FIXTURE_DIR" config user.email "test@example.com"
  git -C "$FIXTURE_DIR" config user.name "Test"

  # Create minimal docs structure
  mkdir -p "$FIXTURE_DIR/docs/architecture"
  mkdir -p "$FIXTURE_DIR/.rite/state"

  # README.md with headings
  printf '# README Title\n## Section A\n## Section B\n' > "$FIXTURE_DIR/README.md"

  # CLAUDE.md with headings
  printf '# CLAUDE Title\n## Identity\n' > "$FIXTURE_DIR/CLAUDE.md"

  # A regular doc under docs/
  printf '# Behavioral Design\n## Overview\n### Detail\n' > \
    "$FIXTURE_DIR/docs/architecture/behavioral-design.md"

  # An ADR-pattern file (case-insensitive match)
  printf '# ADR 001 Example\n## Context\n## Decision\n' > \
    "$FIXTURE_DIR/docs/adr-001-example.md"

  # A doc with zero headings (only paragraph text)
  printf 'No headings in this file.\nJust prose.\n' > \
    "$FIXTURE_DIR/docs/no-headings.md"

  # Initial git commit so HEAD is valid
  git -C "$FIXTURE_DIR" add -A
  git -C "$FIXTURE_DIR" commit -q -m "fixture"

  # Capture HEAD SHA for assertions
  FIXTURE_HEAD="$(git -C "$FIXTURE_DIR" rev-parse HEAD)"
  export FIXTURE_HEAD

  # Set env vars for the library under test
  export RITE_PROJECT_ROOT="$FIXTURE_DIR"
  export RITE_STATE_DIR="$FIXTURE_DIR/.rite/state"
  # Reset RITE_DOCS_MAP_AUTO to default for each test
  export RITE_DOCS_MAP_AUTO="true"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

# ---------------------------------------------------------------------------
# Helper: source the library under test in a fresh subshell with set flags
# reset (per test-runbook Rule 3: restore bats' shell flags after last source).
# ---------------------------------------------------------------------------
_source_docs_map() {
  # Source with flags reset so set -e from the lib doesn't swallow test assertions
  RITE_SOURCE_FUNCTIONS_ONLY=0 source "$RITE_REPO_ROOT/lib/utils/docs-map.sh"
  set +u
  set +o pipefail
}

# ---------------------------------------------------------------------------
# 1. Library shape: all three public functions are defined after sourcing
# ---------------------------------------------------------------------------
@test "docs-map: all three public functions defined after source" {
  _source_docs_map
  declare -f docs_map_build >/dev/null
  declare -f docs_map_ensure >/dev/null
  declare -f docs_map_path >/dev/null
}

# ---------------------------------------------------------------------------
# 2. Re-source safety: double-source must not crash under set -euo pipefail
# ---------------------------------------------------------------------------
@test "docs-map: double-source safe under set -euo pipefail" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$FIXTURE_DIR'
    export RITE_STATE_DIR='$FIXTURE_DIR/.rite/state'
    source '$RITE_REPO_ROOT/lib/utils/docs-map.sh' 2>/dev/null
    source '$RITE_REPO_ROOT/lib/utils/docs-map.sh' 2>/dev/null
    declare -f docs_map_build docs_map_ensure docs_map_path >/dev/null && echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

# ---------------------------------------------------------------------------
# 3. docs_map_build: map file is created
# ---------------------------------------------------------------------------
@test "docs-map: build creates the map file" {
  _source_docs_map
  docs_map_build
  [ -f "$RITE_STATE_DIR/docs-map.tsv" ]
}

# ---------------------------------------------------------------------------
# 4. Map header records current HEAD SHA
# ---------------------------------------------------------------------------
@test "docs-map: header contains current HEAD sha" {
  _source_docs_map
  docs_map_build
  local header
  header="$(head -1 "$RITE_STATE_DIR/docs-map.tsv")"
  [[ "$header" == *"sha=${FIXTURE_HEAD}"* ]]
}

# ---------------------------------------------------------------------------
# 5. Inventory: README.md, CLAUDE.md, and docs/architecture/behavioral-design.md
#    all appear in the map (column 1)
# ---------------------------------------------------------------------------
@test "docs-map: inventory includes README.md CLAUDE.md and docs files" {
  _source_docs_map
  docs_map_build
  local files
  files="$(cut -f1 "$RITE_STATE_DIR/docs-map.tsv" | sort -u)"
  echo "$files" | grep -qF "README.md"
  echo "$files" | grep -qF "CLAUDE.md"
  echo "$files" | grep -qF "docs/architecture/behavioral-design.md"
}

# ---------------------------------------------------------------------------
# 6. ADR flagging: adr-001-example.md gets "adr" in column 3;
#    regular docs get "-"
# ---------------------------------------------------------------------------
@test "docs-map: ADR-pattern file flagged as adr; regular doc flagged as -" {
  _source_docs_map
  docs_map_build
  # ADR file must have "adr" in column 3
  local adr_rows
  adr_rows="$(grep -F "docs/adr-001-example.md" "$RITE_STATE_DIR/docs-map.tsv" | \
    cut -f3 | sort -u || true)"
  [ "$adr_rows" = "adr" ]

  # Regular doc must have "-" in column 3
  local reg_rows
  reg_rows="$(grep -F "docs/architecture/behavioral-design.md" "$RITE_STATE_DIR/docs-map.tsv" | \
    cut -f3 | sort -u || true)"
  [ "$reg_rows" = "-" ]
}

# ---------------------------------------------------------------------------
# 7. File with zero headings still appears in the inventory (one row, empty
#    heading_level and heading_text)
# ---------------------------------------------------------------------------
@test "docs-map: file with no headings gets one row with empty level and text" {
  _source_docs_map
  docs_map_build
  local rows
  rows="$(grep -F "docs/no-headings.md" "$RITE_STATE_DIR/docs-map.tsv" || true)"
  # There should be exactly one row
  local count
  count="$(echo "$rows" | grep -c "docs/no-headings.md" || true)"
  [ "$count" -eq 1 ]
  # Column 4 (heading_level) should be empty: TSV row ends with two TABs after adr_flag
  local level
  level="$(echo "$rows" | cut -f4)"
  [ -z "$level" ]
}

# ---------------------------------------------------------------------------
# 8. Heading text and level are recorded correctly
# ---------------------------------------------------------------------------
@test "docs-map: heading level and text are recorded correctly" {
  _source_docs_map
  docs_map_build
  # README.md has "# README Title" → level 1, text "README Title"
  local readme_rows
  readme_rows="$(grep -F "README.md" "$RITE_STATE_DIR/docs-map.tsv" || true)"

  local h1_row
  h1_row="$(echo "$readme_rows" | awk -F'\t' '$4 == "1"' | head -1)"
  [[ "$h1_row" == *"README Title"* ]]

  local h2_row
  h2_row="$(echo "$readme_rows" | awk -F'\t' '$4 == "2"' | head -1)"
  [[ "$h2_row" == *"Section A"* ]]
}

# ---------------------------------------------------------------------------
# 9. Rebuild is idempotent at the same HEAD (identical non-header rows)
# ---------------------------------------------------------------------------
@test "docs-map: build is idempotent at the same HEAD" {
  _source_docs_map
  docs_map_build
  # Copy the data rows (skip header)
  local copy1
  copy1="$(grep -v '^#' "$RITE_STATE_DIR/docs-map.tsv" || true)"
  docs_map_build
  local copy2
  copy2="$(grep -v '^#' "$RITE_STATE_DIR/docs-map.tsv" || true)"
  [ "$copy1" = "$copy2" ]
}

# ---------------------------------------------------------------------------
# 10. docs_map_ensure auto-rebuilds a missing map
# ---------------------------------------------------------------------------
@test "docs_map_ensure: auto-rebuilds when map is missing" {
  _source_docs_map
  # Confirm map does not exist yet
  rm -f "$RITE_STATE_DIR/docs-map.tsv"
  [ ! -f "$RITE_STATE_DIR/docs-map.tsv" ]
  # ensure should build it
  docs_map_ensure
  [ -f "$RITE_STATE_DIR/docs-map.tsv" ]
}

# ---------------------------------------------------------------------------
# 11. docs_map_ensure with RITE_DOCS_MAP_AUTO=false: suppresses rebuild
# ---------------------------------------------------------------------------
@test "docs_map_ensure: RITE_DOCS_MAP_AUTO=false suppresses auto-rebuild" {
  _source_docs_map
  rm -f "$RITE_STATE_DIR/docs-map.tsv"
  RITE_DOCS_MAP_AUTO=false docs_map_ensure
  [ ! -f "$RITE_STATE_DIR/docs-map.tsv" ]
}

# ---------------------------------------------------------------------------
# 12. docs_map_ensure is a no-op when map already exists (does not overwrite)
# ---------------------------------------------------------------------------
@test "docs_map_ensure: no-op when map already exists" {
  _source_docs_map
  docs_map_build
  # Record mtime-like proxy: inode content checksum
  local before
  before="$(cat "$RITE_STATE_DIR/docs-map.tsv")"
  docs_map_ensure
  local after
  after="$(cat "$RITE_STATE_DIR/docs-map.tsv")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# 13. Builder is not gated on consent mode (no .rite/doc-sync.md, no RITE_DOC_MODE)
# ---------------------------------------------------------------------------
@test "docs-map: builds without .rite/doc-sync.md and without RITE_DOC_MODE" {
  _source_docs_map
  # Explicitly unset any doc-mode variable and ensure no doc-sync.md exists
  unset RITE_DOC_MODE 2>/dev/null || true
  rm -f "$FIXTURE_DIR/.rite/doc-sync.md"
  docs_map_build
  [ -f "$RITE_STATE_DIR/docs-map.tsv" ]
}

# ---------------------------------------------------------------------------
# 14. Paths in map are project-relative (not absolute)
# ---------------------------------------------------------------------------
@test "docs-map: file_path column is project-relative, not absolute" {
  _source_docs_map
  docs_map_build
  # No row in column 1 should start with '/'
  local abs_paths
  abs_paths="$(cut -f1 "$RITE_STATE_DIR/docs-map.tsv" | grep '^/' || true)"
  [ -z "$abs_paths" ]
}

# ---------------------------------------------------------------------------
# 15. last_verified_sha column (column 2) equals HEAD SHA for all data rows
# ---------------------------------------------------------------------------
@test "docs-map: last_verified_sha column equals HEAD SHA for all data rows" {
  _source_docs_map
  docs_map_build
  # Every data row (non-comment) should have FIXTURE_HEAD in column 2
  local bad_rows
  bad_rows="$(grep -v '^#' "$RITE_STATE_DIR/docs-map.tsv" | \
    awk -F'\t' -v sha="$FIXTURE_HEAD" '$2 != sha' || true)"
  [ -z "$bad_rows" ]
}
