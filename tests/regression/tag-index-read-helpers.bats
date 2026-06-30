#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/tag-index.sh
# Regression test: Stage 4 read-path helpers in lib/utils/tag-index.sh
#
# Covers the two net-new helpers added for S4-1 (#403 decomposition):
#
#   slice_section CATALOG_FILE HEADING [MAX_BYTES]
#     - match: returns the H2 section body (heading line included)
#     - no-match: empty output, exit 0
#     - case-insensitive / dash-normalised heading match
#     - over-cap: truncates at MAX_BYTES, appends "..." + "→ see full: <file>#<anchor>"
#     - under-cap: returns the section unchanged
#
#   lookup_tag_pointers TAGS_CSV [INDEX_FILE]
#     - emits sorted/deduped "<file>.md → <Heading>" pointers for matching tags
#     - case-insensitive tag match
#     - empty output + exit 0 for: no-match, empty CSV, missing index
#     - #772 regression: MUST NOT mutate the global TAG_INDEX_FILE on the
#       success path, the parse-fail path, OR the empty-result path.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_INSTALL_DIR="$RITE_REPO_ROOT"

  mkdir -p "$RITE_TEST_TMPDIR/docs/architecture"

  TAG_INDEX_PATH="$RITE_TEST_TMPDIR/docs/architecture/tag-index.md"
  CATALOG_PATH="$RITE_TEST_TMPDIR/docs/architecture/conventions.md"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Run a snippet with tag-index.sh sourced. $1 = bash body.
# ---------------------------------------------------------------------------
_run_helper() {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    $1
  "
}

# ---------------------------------------------------------------------------
# Seed a hand-crafted tag-index.md (tags out of order to exercise sort -u).
# ---------------------------------------------------------------------------
_seed_tag_index() {
  cat > "$TAG_INDEX_PATH" <<'EOTAG'
# Tag Index

**Auto-maintained — do not hand-edit.**

---

## set-e

- conventions.md → grep -c pattern
- conventions.md → Silent death: pipelines inside $()
- encountered-issues.md → Bare-prefix marker grep

## subshell

- conventions.md → Subshell variable loss
- conventions.md → grep -c pattern
EOTAG
}

# ---------------------------------------------------------------------------
# Seed a catalog with a short section and a long section.
# ---------------------------------------------------------------------------
_seed_catalog() {
  {
    echo "# Conventions"
    echo ""
    echo "## Short heading"
    echo ""
    echo "A small body line."
    echo ""
    echo "## Big Section"
    echo ""
    # ~50 lines of filler to comfortably exceed a small MAX_BYTES cap
    local i
    for i in $(seq 1 50); do
      echo "Filler line number $i with enough text to add up to many bytes."
    done
    echo ""
    echo "## Trailing heading"
    echo ""
    echo "End."
  } > "$CATALOG_PATH"
}

# ===========================================================================
# slice_section
# ===========================================================================

@test "slice_section: match returns the H2 section body including the heading" {
  _seed_catalog
  _run_helper "slice_section '$CATALOG_PATH' 'Short heading'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Short heading"* ]]
  [[ "$output" == *"A small body line."* ]]
  # Must stop at the next H2 — not bleed into "Big Section"
  [[ "$output" != *"Filler line number 1"* ]]
  [[ "$output" != *"Big Section"* ]]
}

@test "slice_section: no-match yields empty output and exit 0" {
  _seed_catalog
  _run_helper "slice_section '$CATALOG_PATH' 'No Such Heading'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "slice_section: missing file yields empty output and exit 0" {
  _run_helper "slice_section '$RITE_TEST_TMPDIR/does-not-exist.md' 'Short heading'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "slice_section: heading match is case-insensitive and dash-normalised" {
  _seed_catalog
  # "short-heading" with dash + different case must still match "Short heading"
  _run_helper "slice_section '$CATALOG_PATH' 'SHORT-HEADING'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Short heading"* ]]
  [[ "$output" == *"A small body line."* ]]
}

@test "slice_section: under-cap section is returned unchanged (no truncation suffix)" {
  _seed_catalog
  _run_helper "slice_section '$CATALOG_PATH' 'Short heading' 5120"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Short heading"* ]]
  [[ "$output" == *"A small body line."* ]]
  # No truncation artifacts when under the cap
  [[ "$output" != *"see full:"* ]]
}

@test "slice_section: over-cap truncates and appends '...' + see-full pointer with anchor" {
  _seed_catalog
  # Force truncation with a tiny cap.
  _run_helper "slice_section '$CATALOG_PATH' 'Big Section' 200"
  [ "$status" -eq 0 ]
  [[ "$output" == *"..."* ]]
  [[ "$output" == *"→ see full: $CATALOG_PATH#big-section"* ]]
  # Truncated: should not contain the last filler line.
  [[ "$output" != *"Filler line number 50"* ]]
}

@test "slice_section: byte cap is honoured (truncated body <= MAX_BYTES)" {
  _seed_catalog
  # Capture only the body portion up to the appended notice and assert its byte
  # length does not exceed the cap.
  _run_helper "
    out=\$(slice_section '$CATALOG_PATH' 'Big Section' 200)
    body=\$(printf '%s\n' \"\$out\" | sed '/^\.\.\.\$/,\$d')
    printf '%s' \"\$body\" | LC_ALL=C wc -c | tr -d ' '
  "
  [ "$status" -eq 0 ]
  [ "$output" -le 200 ]
}

# ===========================================================================
# lookup_tag_pointers
# ===========================================================================

@test "lookup_tag_pointers: emits sorted/deduped pointers for matching tags" {
  _seed_tag_index
  # Both tags share "conventions.md → grep -c pattern" — sort -u must dedupe it.
  _run_helper "lookup_tag_pointers 'set-e,subshell' '$TAG_INDEX_PATH'"
  [ "$status" -eq 0 ]
  # Exactly 4 unique pointers across the two tags (5 raw, 1 duplicate).
  line_count=$(printf '%s\n' "$output" | grep -c '→' || true)
  [ "$line_count" -eq 4 ]
  [[ "$output" == *"conventions.md → grep -c pattern"* ]]
  [[ "$output" == *"conventions.md → Subshell variable loss"* ]]
  [[ "$output" == *"encountered-issues.md → Bare-prefix marker grep"* ]]
  # Deduped: only one occurrence of the shared pointer.
  dup_count=$(printf '%s\n' "$output" | grep -c 'grep -c pattern' || true)
  [ "$dup_count" -eq 1 ]
  # Sorted: output equals its own sort -u.
  sorted=$(printf '%s\n' "$output" | sort -u)
  [ "$output" = "$sorted" ]
}

@test "lookup_tag_pointers: tag match is case-insensitive" {
  _seed_tag_index
  _run_helper "lookup_tag_pointers 'SET-E' '$TAG_INDEX_PATH'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"conventions.md → grep -c pattern"* ]]
}

@test "lookup_tag_pointers: no-match tag yields empty output and exit 0" {
  _seed_tag_index
  _run_helper "lookup_tag_pointers 'no-such-tag' '$TAG_INDEX_PATH'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lookup_tag_pointers: empty CSV yields empty output and exit 0" {
  _seed_tag_index
  _run_helper "lookup_tag_pointers '' '$TAG_INDEX_PATH'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lookup_tag_pointers: missing index file yields empty output and exit 0" {
  _run_helper "lookup_tag_pointers 'set-e' '$RITE_TEST_TMPDIR/no-index.md'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# #772 regression: lookup_tag_pointers MUST NOT mutate global TAG_INDEX_FILE.
# ---------------------------------------------------------------------------

@test "#772: TAG_INDEX_FILE unchanged on the success path" {
  _seed_tag_index
  _run_helper "
    TAG_INDEX_FILE='SENTINEL'
    lookup_tag_pointers 'set-e' '$TAG_INDEX_PATH' >/dev/null
    printf '%s' \"\$TAG_INDEX_FILE\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "SENTINEL" ]
}

@test "#772: TAG_INDEX_FILE unchanged on the parse-fail (missing index) path" {
  _run_helper "
    TAG_INDEX_FILE='SENTINEL'
    lookup_tag_pointers 'set-e' '$RITE_TEST_TMPDIR/no-index.md' >/dev/null
    printf '%s' \"\$TAG_INDEX_FILE\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "SENTINEL" ]
}

@test "#772: TAG_INDEX_FILE unchanged on the empty-result (no tag match) path" {
  _seed_tag_index
  _run_helper "
    TAG_INDEX_FILE='SENTINEL'
    lookup_tag_pointers 'no-such-tag' '$TAG_INDEX_PATH' >/dev/null
    printf '%s' \"\$TAG_INDEX_FILE\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "SENTINEL" ]
}
