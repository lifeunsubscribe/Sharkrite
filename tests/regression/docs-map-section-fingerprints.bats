#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/docs-map.sh
# Regression tests for per-section content fingerprints in the docs-map builder.
#
# Covers: fingerprint column (col 6), preamble section rows, headingless-file
# rows, determinism, and content-change detection.

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT

  FIXTURE_DIR="$(mktemp -d)"
  export FIXTURE_DIR

  git -C "$FIXTURE_DIR" init -q
  git -C "$FIXTURE_DIR" config user.email "test@example.com"
  git -C "$FIXTURE_DIR" config user.name "Test"

  mkdir -p "$FIXTURE_DIR/docs"
  mkdir -p "$FIXTURE_DIR/.rite/state"

  # A file that starts directly with a heading (no preamble).
  printf '# Alpha\nBody of alpha.\n## Sub-Alpha\nSub content.\n' \
    > "$FIXTURE_DIR/docs/no-preamble.md"

  # A file with preamble content before the first heading.
  printf 'Preamble line one.\nPreamble line two.\n\n# Beta\nBody of beta.\n' \
    > "$FIXTURE_DIR/docs/with-preamble.md"

  # A file with zero headings (plain prose).
  printf 'No headings here.\nJust two lines.\n' \
    > "$FIXTURE_DIR/docs/headingless.md"

  # A file with a heading inside a fenced code block (must NOT be treated as a section boundary).
  printf '# Real Heading\nSome intro.\n```\n# fake heading inside fence\n```\nOutro.\n' \
    > "$FIXTURE_DIR/docs/fence-heading.md"

  git -C "$FIXTURE_DIR" add -A
  git -C "$FIXTURE_DIR" commit -q -m "fixture"

  FIXTURE_HEAD="$(git -C "$FIXTURE_DIR" rev-parse HEAD)"
  export FIXTURE_HEAD

  export RITE_PROJECT_ROOT="$FIXTURE_DIR"
  export RITE_STATE_DIR="$FIXTURE_DIR/.rite/state"
  MAP_FILE="$FIXTURE_DIR/docs/docs-map.tsv"
  export MAP_FILE
  export RITE_DOCS_MAP_AUTO="true"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

_source_docs_map() {
  RITE_SOURCE_FUNCTIONS_ONLY=0 source "$RITE_REPO_ROOT/lib/utils/docs-map.sh"
  set +u
  set +o pipefail
}

# ---------------------------------------------------------------------------
# 1. Map header is v4 format
# ---------------------------------------------------------------------------
@test "docs-map fingerprints: header is docs-map v4" {
  _source_docs_map
  docs_map_build
  local header
  header="$(head -1 "$MAP_FILE")"
  [[ "$header" == "# docs-map v4 sha="* ]]
}

# ---------------------------------------------------------------------------
# 2. Every data row has exactly 10 tab-separated columns
# ---------------------------------------------------------------------------
@test "docs-map fingerprints: every data row has 10 columns" {
  _source_docs_map
  docs_map_build
  # Count rows that do NOT have exactly 10 tab-separated fields
  local bad_rows
  bad_rows="$(grep -v '^#' "$MAP_FILE" | \
    awk -F'\t' 'NF != 10' || true)"
  [ -z "$bad_rows" ]
}

# ---------------------------------------------------------------------------
# 3. Fingerprint column (col 6) is a 64-char lowercase hex string for heading rows
# ---------------------------------------------------------------------------
@test "docs-map fingerprints: fingerprint is 64-char hex for heading rows" {
  _source_docs_map
  docs_map_build
  # For rows with a non-empty heading_level (column 4), column 6 must be 64-char hex.
  local bad_fps
  bad_fps="$(grep -v '^#' "$MAP_FILE" | \
    awk -F'\t' '$4 != "" && $6 !~ /^[0-9a-f]{64}$/ {print}' || true)"
  [ -z "$bad_fps" ]
}

# ---------------------------------------------------------------------------
# 4. Headingless file: one row, column 4 empty, column 6 is 64-char hex
# ---------------------------------------------------------------------------
@test "docs-map fingerprints: headingless file gets one row with fingerprint" {
  _source_docs_map
  docs_map_build
  local rows
  rows="$(grep -F "docs/headingless.md" "$MAP_FILE" || true)"

  # Exactly one row
  local count
  count="$(printf '%s\n' "$rows" | grep -c "docs/headingless.md" || true)"
  [ "$count" -eq 1 ]

  # heading_level (col 4) is empty
  local h_level
  h_level="$(printf '%s\n' "$rows" | cut -f4)"
  [ -z "$h_level" ]

  # fingerprint (col 6) is 64-char hex
  local fp
  fp="$(printf '%s\n' "$rows" | cut -f6)"
  [[ "$fp" =~ ^[0-9a-f]{64}$ ]]
}

# ---------------------------------------------------------------------------
# 5. File with preamble: preamble row (empty heading) + heading rows
# ---------------------------------------------------------------------------
@test "docs-map fingerprints: file with preamble emits a preamble row" {
  _source_docs_map
  docs_map_build
  local rows
  rows="$(grep -F "docs/with-preamble.md" "$MAP_FILE" || true)"

  # Should have 2 rows: preamble (empty h_level) + "Beta" section
  local count
  count="$(printf '%s\n' "$rows" | grep -c "docs/with-preamble.md" || true)"
  [ "$count" -eq 2 ]

  # One row has empty heading_level (the preamble row)
  local preamble_rows
  preamble_rows="$(printf '%s\n' "$rows" | awk -F'\t' '$4 == ""' || true)"
  [ -n "$preamble_rows" ]

  # The preamble row has a non-empty fingerprint (64-char hex)
  local preamble_fp
  preamble_fp="$(printf '%s\n' "$preamble_rows" | cut -f6)"
  [[ "$preamble_fp" =~ ^[0-9a-f]{64}$ ]]
}

# ---------------------------------------------------------------------------
# 6. File starting with a heading: NO preamble row
# ---------------------------------------------------------------------------
@test "docs-map fingerprints: file starting with heading has no preamble row" {
  _source_docs_map
  docs_map_build
  local rows
  rows="$(grep -F "docs/no-preamble.md" "$MAP_FILE" || true)"

  # All rows should have non-empty heading_level (no preamble row)
  local preamble_rows
  preamble_rows="$(printf '%s\n' "$rows" | awk -F'\t' '$4 == ""' || true)"
  [ -z "$preamble_rows" ]
}

# ---------------------------------------------------------------------------
# 7. Heading inside a fenced code block is NOT treated as a section boundary
# ---------------------------------------------------------------------------
@test "docs-map fingerprints: heading inside fence is not a section boundary" {
  _source_docs_map
  docs_map_build
  local rows
  rows="$(grep -F "docs/fence-heading.md" "$MAP_FILE" || true)"

  # File has one real heading → exactly 1 row (no preamble, no fake heading row)
  local count
  count="$(printf '%s\n' "$rows" | grep -c "docs/fence-heading.md" || true)"
  [ "$count" -eq 1 ]

  # The row's heading text is "Real Heading" (the fake fence heading is absent)
  local h_text
  h_text="$(printf '%s\n' "$rows" | cut -f5)"
  [ "$h_text" = "Real Heading" ]
}

# ---------------------------------------------------------------------------
# 8. Determinism: two consecutive builds produce byte-identical data rows
# ---------------------------------------------------------------------------
@test "docs-map fingerprints: consecutive builds produce byte-identical data rows" {
  _source_docs_map
  docs_map_build
  local copy1
  copy1="$(grep -v '^#' "$MAP_FILE" || true)"

  docs_map_build
  local copy2
  copy2="$(grep -v '^#' "$MAP_FILE" || true)"

  [ "$copy1" = "$copy2" ]
}

# ---------------------------------------------------------------------------
# 9. Changing file content produces a different fingerprint
# ---------------------------------------------------------------------------
@test "docs-map fingerprints: changed content produces different fingerprint" {
  _source_docs_map
  docs_map_build
  local fp_before
  fp_before="$(grep -F "docs/headingless.md" "$MAP_FILE" | \
    cut -f6 || true)"

  # Modify the headingless file and rebuild (no new commit needed — HEAD SHA
  # is the same but content changes; fingerprint must still change)
  printf 'Completely different content.\n' > "$FIXTURE_DIR/docs/headingless.md"
  docs_map_build

  local fp_after
  fp_after="$(grep -F "docs/headingless.md" "$MAP_FILE" | \
    cut -f6 || true)"

  [ "$fp_before" != "$fp_after" ]
}

# ---------------------------------------------------------------------------
# 10. Preamble fingerprint differs from heading-section fingerprint for the
#     same file (sanity check — distinct content → distinct fingerprints)
# ---------------------------------------------------------------------------
@test "docs-map fingerprints: preamble and heading section have different fingerprints" {
  _source_docs_map
  docs_map_build
  local rows
  rows="$(grep -F "docs/with-preamble.md" "$MAP_FILE" || true)"

  local preamble_fp heading_fp
  preamble_fp="$(printf '%s\n' "$rows" | awk -F'\t' '$4 == ""' | cut -f6)"
  heading_fp="$(printf '%s\n' "$rows" | awk -F'\t' '$4 != ""' | cut -f6)"

  [ -n "$preamble_fp" ]
  [ -n "$heading_fp" ]
  [ "$preamble_fp" != "$heading_fp" ]
}

# ---------------------------------------------------------------------------
# 11. Trailing-whitespace normalization: lines with trailing spaces fingerprint
#     identically to the same lines without trailing spaces
# ---------------------------------------------------------------------------
@test "docs-map fingerprints: trailing whitespace on lines does not change fingerprint" {
  _source_docs_map
  docs_map_build
  local fp_before
  fp_before="$(grep -F "docs/headingless.md" "$MAP_FILE" | \
    cut -f6 || true)"

  # Append trailing spaces to every line and rebuild; fingerprint must be unchanged.
  sed 's/$/ /' "$FIXTURE_DIR/docs/headingless.md" > "$FIXTURE_DIR/docs/headingless.md.tmp"
  mv "$FIXTURE_DIR/docs/headingless.md.tmp" "$FIXTURE_DIR/docs/headingless.md"
  docs_map_build

  local fp_after
  fp_after="$(grep -F "docs/headingless.md" "$MAP_FILE" | \
    cut -f6 || true)"

  [ "$fp_before" = "$fp_after" ]
}

# ---------------------------------------------------------------------------
# 12. No-trailing-newline: editing the final line of a file changes fingerprint
# ---------------------------------------------------------------------------
@test "docs-map fingerprints: editing final line of no-trailing-newline file changes fingerprint" {
  # Create a file without a trailing newline (printf without \n at end).
  printf 'Only line, no newline at end' > "$FIXTURE_DIR/docs/no-newline.md"
  git -C "$FIXTURE_DIR" add -A
  git -C "$FIXTURE_DIR" commit -q -m "no-newline fixture"

  _source_docs_map
  docs_map_build
  local fp_before
  fp_before="$(grep -F "docs/no-newline.md" "$MAP_FILE" | \
    cut -f6 || true)"

  # Modify the final (only) line.
  printf 'Different line, no newline at end' > "$FIXTURE_DIR/docs/no-newline.md"
  docs_map_build

  local fp_after
  fp_after="$(grep -F "docs/no-newline.md" "$MAP_FILE" | \
    cut -f6 || true)"

  [ "$fp_before" != "$fp_after" ]
}

# ---------------------------------------------------------------------------
# 13. docs_map_ensure upgrades a pre-v4 map to v4
# ---------------------------------------------------------------------------
@test "docs-map ensure: pre-v4 map triggers a rebuild to v4" {
  _source_docs_map
  # Write a v2-style header to simulate a pre-existing map that pre-dates v4.
  local map_file
  map_file="$(docs_map_path)"
  mkdir -p "$(dirname "$map_file")"
  printf '# docs-map v2 sha=abc built=2026-01-01\n' > "$map_file"
  printf 'docs/headingless.md\tabc\t-\t\t\tabc123\n' >> "$map_file"

  # docs_map_ensure should detect v2 (non-v4) and rebuild.
  docs_map_ensure

  local header
  header="$(head -1 "$map_file")"
  [[ "$header" == "# docs-map v4"* ]]
}
