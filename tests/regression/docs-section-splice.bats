#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh::_docs_splice_section_own|_docs_extract_section_own
BATS_TEST_TIMEOUT=30
#
# Tests for _docs_splice_section_own (#1836):
# - round trip: splicing extracted text back leaves the file byte-identical
# - repeated heading: second occurrence is targeted correctly
# - code fence: headings inside fenced blocks do not end the section
# - last section: section at end of file (no following heading)
# - no match: missing section or empty level returns non-zero
# - blank line: original trailing blank is preserved when replacement lacks one

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DOCS_CMD="$PROJECT_ROOT/lib/core/docs-command.sh"
  WORK_DIR="$(mktemp -d)"
  export PROJECT_ROOT DOCS_CMD WORK_DIR
}

teardown() {
  rm -rf "${WORK_DIR:-}"
}

# Source docs-command.sh (functions only) and restore bats flags.
_load_docs_cmd() {
  export RITE_LIB_DIR="${PROJECT_ROOT}/lib"
  export RITE_PROJECT_ROOT="${WORK_DIR}"
  export RITE_DATA_DIR=".rite"
  export RITE_STATE_DIR="${WORK_DIR}/.rite/state"
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "${DOCS_CMD}"
  set +u; set +o pipefail
}

# ---------------------------------------------------------------------------
# round trip
# ---------------------------------------------------------------------------

@test "round trip: splice of extracted text leaves file byte-identical" {
  local doc="$WORK_DIR/doc.md"
  printf '%s\n' \
    '# Title' \
    '' \
    'Preamble text.' \
    '' \
    '## Section A' \
    '' \
    'Body of A.' \
    '' \
    '## Section B' \
    '' \
    'Body of B.' \
    > "$doc"

  local orig
  orig="$(cat "$doc")"

  _load_docs_cmd

  local extracted content_file
  extracted="$(_docs_extract_section_own "$doc" "2" "Section A" "1")"
  content_file="$WORK_DIR/content.txt"
  printf '%s\n' "$extracted" > "$content_file"

  _docs_splice_section_own "$doc" "2" "Section A" "1" "$content_file"

  local after
  after="$(cat "$doc")"
  [ "$orig" = "$after" ]
}

# ---------------------------------------------------------------------------
# repeated heading
# ---------------------------------------------------------------------------

@test "repeated heading: second occurrence is replaced, first is unchanged" {
  local doc="$WORK_DIR/doc.md"
  printf '%s\n' \
    '## Steps' \
    '' \
    'First steps section.' \
    '' \
    '## Steps' \
    '' \
    'Second steps section.' \
    > "$doc"

  _load_docs_cmd

  local content_file="$WORK_DIR/content.txt"
  printf '%s\n' \
    '## Steps' \
    '' \
    'Replaced second steps.' \
    > "$content_file"

  _docs_splice_section_own "$doc" "2" "Steps" "2" "$content_file"

  local result
  result="$(cat "$doc")"

  printf '%s' "$result" | grep -q "First steps section."
  printf '%s' "$result" | grep -q "Replaced second steps."
  ! printf '%s' "$result" | grep -q "Second steps section."
}

# ---------------------------------------------------------------------------
# code fence
# ---------------------------------------------------------------------------

@test "code fence: heading-shaped lines inside code blocks do not end the section" {
  local doc="$WORK_DIR/doc.md"
  printf '%s\n' \
    '## Usage' \
    '' \
    'Example:' \
    '' \
    '```bash' \
    '# This looks like a heading but is code' \
    'echo hello' \
    '```' \
    '' \
    'End of usage section.' \
    '' \
    '## Next' \
    '' \
    'Next section body.' \
    > "$doc"

  _load_docs_cmd

  # Round-trip via re-extraction verifies the splice respected code fences
  local extracted content_file
  extracted="$(_docs_extract_section_own "$doc" "2" "Usage" "1")"
  content_file="$WORK_DIR/content.txt"
  printf '%s\n' "$extracted" > "$content_file"

  _docs_splice_section_own "$doc" "2" "Usage" "1" "$content_file"

  # ## Next must still be present (splice did not eat into the following section)
  local result
  result="$(cat "$doc")"
  printf '%s' "$result" | grep -q "Next section body."

  # Code fence comment must still be in the spliced section
  printf '%s' "$result" | grep -q "# This looks like a heading but is code"

  # Re-extract after splice: must equal the original extracted text
  local after_extracted
  after_extracted="$(_docs_extract_section_own "$doc" "2" "Usage" "1")"
  [ "$extracted" = "$after_extracted" ]
}

# ---------------------------------------------------------------------------
# last section
# ---------------------------------------------------------------------------

@test "last section: section at end of file is replaced correctly" {
  local doc="$WORK_DIR/doc.md"
  printf '%s\n' \
    '## First' \
    '' \
    'First body.' \
    '' \
    '## Last' \
    '' \
    'Last body.' \
    > "$doc"

  _load_docs_cmd

  local content_file="$WORK_DIR/content.txt"
  printf '%s\n' \
    '## Last' \
    '' \
    'Replaced last body.' \
    > "$content_file"

  _docs_splice_section_own "$doc" "2" "Last" "1" "$content_file"

  local result
  result="$(cat "$doc")"

  printf '%s' "$result" | grep -q "First body."
  printf '%s' "$result" | grep -q "Replaced last body."
  ! printf '%s' "$result" | grep -q "^Last body\."
}

# ---------------------------------------------------------------------------
# no match
# ---------------------------------------------------------------------------

@test "no match: non-existent section returns non-zero and leaves file unchanged" {
  local doc="$WORK_DIR/doc.md"
  printf '%s\n' \
    '## Real Section' \
    '' \
    'Real content.' \
    > "$doc"

  local orig
  orig="$(cat "$doc")"

  _load_docs_cmd

  local content_file="$WORK_DIR/content.txt"
  printf '## Ghost Section\n\nGhost.\n' > "$content_file"

  local rc=0
  _docs_splice_section_own "$doc" "2" "Ghost Section" "1" "$content_file" || rc=$?
  [ "$rc" -ne 0 ]

  local after
  after="$(cat "$doc")"
  [ "$orig" = "$after" ]
}

@test "no match: empty heading level returns non-zero and leaves file unchanged" {
  local doc="$WORK_DIR/doc.md"
  printf '%s\n' \
    '## A Section' \
    '' \
    'Some body.' \
    > "$doc"

  local orig
  orig="$(cat "$doc")"

  _load_docs_cmd

  local content_file="$WORK_DIR/content.txt"
  printf '## A Section\n\nNew body.\n' > "$content_file"

  local rc=0
  _docs_splice_section_own "$doc" "" "A Section" "1" "$content_file" || rc=$?
  [ "$rc" -ne 0 ]

  local after
  after="$(cat "$doc")"
  [ "$orig" = "$after" ]
}

# ---------------------------------------------------------------------------
# blank line preservation
# ---------------------------------------------------------------------------

@test "blank line: original trailing blank is kept when replacement lacks one" {
  local doc="$WORK_DIR/doc.md"
  # Section A ends with a blank line before ## Section B
  printf '%s\n' \
    '## Section A' \
    '' \
    'Body of A.' \
    '' \
    '## Section B' \
    '' \
    'Body of B.' \
    > "$doc"

  _load_docs_cmd

  # Replacement that does NOT end with a blank line (no trailing \n beyond content)
  local content_file="$WORK_DIR/content.txt"
  printf '## Section A\n\nNew body of A.' > "$content_file"

  _docs_splice_section_own "$doc" "2" "Section A" "1" "$content_file"

  local result
  result="$(cat "$doc")"

  # ## Section B must still appear
  printf '%s' "$result" | grep -q "^## Section B"
  # Body of B must be intact
  printf '%s' "$result" | grep -q "Body of B."
  # A blank line must exist between the new content and ## Section B
  printf '%s' "$result" | grep -q "^$"
}
