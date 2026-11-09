#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/plan-issues.sh
# tests/regression/plan-reads-docs-map.bats
#
# Regression tests for map-driven doc auto-discovery in plan-issues.sh.
# Issue #1424: Route plan discovery via docs map.
#
# Verifies acceptance criteria:
#   1. When docs-map.tsv (v4) is present, _collect_auto_docs consults the map;
#      sections are loaded by anchor (file § heading), not as whole files.
#   2. A section past the byte cap is still discoverable — the prompt lists
#      its file + anchor in the discoverability index even when not loaded.
#   3. ADR-typed and README rows keep their always-load-in-full contract;
#      feature sections fill toward the cap in stable (map) order.
#   4. No docs map (or pre-v4 format) → falls back to whole-file discovery.
#   5. RITE_PLAN_DOC_BYTE_CAP=0 disables all content loading.
#   6. RITE_PLAN_INCLUDE_README=false skips README even in map-driven path.
#   7. Zero provider calls in discovery: _collect_auto_docs makes no provider
#      calls (structural grep on the implementation).

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_INSTALL_DIR="${RITE_REPO_ROOT}"
  export RITE_DATA_DIR=".rite"
  export RITE_PLAN_DOC_BYTE_CAP=50000
  export RITE_PLAN_MAX_ESTIMATE="2hr"
  export RITE_PLAN_DOCS=""
  export RITE_PLAN_DRYRUN_DUMP_PROMPT=""

  mkdir -p "$RITE_TEST_TMPDIR/.rite"
  mkdir -p "$RITE_TEST_TMPDIR/docs"

  # Stub print_* (no colors.sh needed)
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }

  # Extract the three discovery functions + _plan_extract_section from plan-issues.sh
  # using brace-counting awk so we don't pull in the interactive plan_issues() body.
  eval "$(awk '
    /^_plan_extract_section[(][)]/ { in_fn=1; depth=0 }
    /^_collect_auto_docs_whole_file[(][)]/ { in_fn=1; depth=0 }
    /^_collect_auto_docs_via_map[(][)]/ { in_fn=1; depth=0 }
    /^_collect_auto_docs[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"

  # Restore bats error handling after any library sourcing above
  set +u; set +o pipefail
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write a minimal v4 docs-map TSV to $RITE_TEST_TMPDIR/docs/docs-map.tsv.
# Args: one or more rows as "rel_path<TAB>sha<TAB>adr_flag<TAB>level<TAB>text<TAB>fp<TAB>type<TAB>rubric<TAB>tags<TAB>note"
_write_map() {
  local map_file="$RITE_TEST_TMPDIR/docs/docs-map.tsv"
  printf '# docs-map v4 sha=abc123 built=2026-10-25T00:00:00Z\n' > "$map_file"
  local row
  for row in "$@"; do
    printf '%s\n' "$row" >> "$map_file"
  done
}

# Build a row string for _write_map.
# Usage: _map_row REL_PATH TYPE [LEVEL] [HEADING_TEXT]
_map_row() {
  local rel_path="$1"
  local dtype="$2"
  local level="${3:-}"
  local text="${4:-}"
  local adr_flag="-"
  [ "$dtype" = "adr" ] && adr_flag="adr"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$rel_path" "abc123" "$adr_flag" "$level" "$text" "fp_${rel_path}_${level}" "$dtype" "-" "-" "-"
}

# ---------------------------------------------------------------------------
# Test 1: Map-driven path — section loaded by anchor, not whole file
#
# A feature doc has two sections.  Only the first section is referenced in
# the map and fits within the cap.  _collect_auto_docs must load only that
# section (by anchor) and the output must contain the section anchor label
# "§ Section One" rather than a bare file label.
# ---------------------------------------------------------------------------

@test "map-driven: section loaded by anchor (file § heading) not whole file" {
  # Feature doc with two sections
  cat > "$RITE_TEST_TMPDIR/docs/feature.md" <<'DOC'
# Section One

SENTINEL_SEC_ONE

Content of section one.

# Section Two

SENTINEL_SEC_TWO

Content of section two.
DOC

  _write_map \
    "$(_map_row "docs/feature.md" "feature" "1" "Section One")" \
    "$(_map_row "docs/feature.md" "feature" "1" "Section Two")"

  local result
  result=$(_collect_auto_docs)

  # Must contain the section anchor label format "§ Section One"
  echo "$result" | grep -q "§ Section One" || {
    echo "FAIL: section anchor label not found in output" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }

  # Must contain section one content
  echo "$result" | grep -q "SENTINEL_SEC_ONE" || {
    echo "FAIL: section one content not loaded" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Test 2: Over-cap section is discoverable (index, not silently dropped)
#
# Two feature sections; byte cap set so only the first fits.  The second
# section must appear in the discoverability index block ("AVAILABLE SECTIONS")
# but its content must NOT be in the output.
# ---------------------------------------------------------------------------

@test "map-driven: over-cap section appears in discoverability index" {
  cat > "$RITE_TEST_TMPDIR/docs/big.md" <<'DOC'
# Small Section

SHORT_CONTENT

# Large Section

OVER_CAP_SENTINEL large section content that exceeds the tiny cap
DOC

  _write_map \
    "$(_map_row "docs/big.md" "feature" "1" "Small Section")" \
    "$(_map_row "docs/big.md" "feature" "1" "Large Section")"

  # Set a tiny cap so only "Small Section" fits
  export RITE_PLAN_DOC_BYTE_CAP=60

  local result
  result=$(_collect_auto_docs)

  # Small section content must be loaded
  echo "$result" | grep -q "SHORT_CONTENT" || {
    echo "FAIL: small section content not loaded" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }

  # Over-cap section content must NOT be loaded
  if echo "$result" | grep -q "OVER_CAP_SENTINEL"; then
    echo "FAIL: over-cap section content was loaded despite exceeding cap" >&2
    false
  fi

  # Over-cap section must appear in the discoverability index
  echo "$result" | grep -q "AVAILABLE SECTIONS" || {
    echo "FAIL: discoverability index block absent" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
  echo "$result" | grep -q "Large Section" || {
    echo "FAIL: over-cap section 'Large Section' not in discoverability index" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Test 3a: ADR rows always load in full (always-load contract)
#
# An ADR file is represented in the map as type=adr.  Its content must load
# in full even when the byte cap is tiny.
# ---------------------------------------------------------------------------

@test "map-driven: ADR rows load in full regardless of byte cap" {
  cat > "$RITE_TEST_TMPDIR/docs/ADR-001-test.md" <<'DOC'
# ADR-001

ADR_SENTINEL_FULL_LOAD

This decision is important.
DOC

  _write_map \
    "$(_map_row "docs/ADR-001-test.md" "adr" "1" "ADR-001")"

  # Tiny cap that would block feature docs
  export RITE_PLAN_DOC_BYTE_CAP=10

  local result
  result=$(_collect_auto_docs)

  echo "$result" | grep -q "ADR_SENTINEL_FULL_LOAD" || {
    echo "FAIL: ADR content not loaded despite always-load contract" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Test 3b: README row loads in full when RITE_PLAN_INCLUDE_README is true
# ---------------------------------------------------------------------------

@test "map-driven: README row loads in full when RITE_PLAN_INCLUDE_README not disabled" {
  printf '# My Project\n\nREADME_SENTINEL\n' > "$RITE_TEST_TMPDIR/README.md"

  _write_map \
    "$(_map_row "README.md" "other" "" "")"

  export RITE_PLAN_INCLUDE_README=true

  local result
  result=$(_collect_auto_docs)

  echo "$result" | grep -q "README_SENTINEL" || {
    echo "FAIL: README content not loaded" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Test 3c: Feature sections fill toward cap in stable (map) order
#
# Three feature sections; cap lets only the first two fit.  The third must be
# in the index.  The two loaded sections must appear in map order.
# ---------------------------------------------------------------------------

@test "map-driven: feature sections fill cap in stable map order; third goes to index" {
  cat > "$RITE_TEST_TMPDIR/docs/phases.md" <<'DOC'
# Phase One

PHASE_ONE_SENTINEL

Phase one content here.

# Phase Two

PHASE_TWO_SENTINEL

Phase two content here.

# Phase Three

PHASE_THREE_SENTINEL

Phase three content here.
DOC

  _write_map \
    "$(_map_row "docs/phases.md" "feature" "1" "Phase One")" \
    "$(_map_row "docs/phases.md" "feature" "1" "Phase Two")" \
    "$(_map_row "docs/phases.md" "feature" "1" "Phase Three")"

  # Cap: Phase One (~40B) + Phase Two (~40B) fit; Phase Three would exceed
  export RITE_PLAN_DOC_BYTE_CAP=120

  local result
  result=$(_collect_auto_docs)

  echo "$result" | grep -q "PHASE_ONE_SENTINEL" || {
    echo "FAIL: Phase One not loaded" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
  echo "$result" | grep -q "PHASE_TWO_SENTINEL" || {
    echo "FAIL: Phase Two not loaded" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }

  # Phase Three must be in discoverability index, not content
  if echo "$result" | grep -q "PHASE_THREE_SENTINEL"; then
    echo "FAIL: Phase Three content loaded despite exceeding cap" >&2
    false
  fi
  echo "$result" | grep -q "Phase Three" || {
    echo "FAIL: Phase Three not in discoverability index" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Test 4: No docs map → falls back to whole-file discovery
#
# When docs/docs-map.tsv does not exist, _collect_auto_docs must fall back to
# whole-file discovery.  A doc file placed in docs/ must appear in the output
# via the whole-file path (bare file label, no "§" anchor).
# ---------------------------------------------------------------------------

@test "no docs map: falls back to whole-file discovery unchanged" {
  # No docs-map.tsv written
  cat > "$RITE_TEST_TMPDIR/docs/design.md" <<'DOC'
# Design

WHOLE_FILE_SENTINEL

Design document content.
DOC

  local result
  result=$(_collect_auto_docs)

  echo "$result" | grep -q "WHOLE_FILE_SENTINEL" || {
    echo "FAIL: whole-file fallback did not load doc content" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }

  # Output must use bare file label (no § anchor) for whole-file loading
  if echo "$result" | grep -q " § "; then
    echo "FAIL: whole-file path produced section-anchor label" >&2
    false
  fi
}

# ---------------------------------------------------------------------------
# Test 4b: Pre-v4 docs map → falls back to whole-file discovery
# ---------------------------------------------------------------------------

@test "pre-v4 docs map: falls back to whole-file discovery" {
  # Write a v3-format map header
  printf '# docs-map v3 sha=abc123\n' > "$RITE_TEST_TMPDIR/docs/docs-map.tsv"
  printf 'docs/design.md\tabc123\t-\t1\tDesign\tfp\tfeature\t-\t-\t-\n' \
    >> "$RITE_TEST_TMPDIR/docs/docs-map.tsv"

  cat > "$RITE_TEST_TMPDIR/docs/design.md" <<'DOC'
# Design

V3_FALLBACK_SENTINEL
DOC

  local result
  result=$(_collect_auto_docs)

  echo "$result" | grep -q "V3_FALLBACK_SENTINEL" || {
    echo "FAIL: pre-v4 map did not trigger whole-file fallback" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Test 5: RITE_PLAN_DOC_BYTE_CAP=0 disables all content loading
# ---------------------------------------------------------------------------

@test "RITE_PLAN_DOC_BYTE_CAP=0 disables auto-discovery (map-driven and fallback)" {
  cat > "$RITE_TEST_TMPDIR/docs/feature.md" <<'DOC'
# Section

CAP_ZERO_SENTINEL
DOC

  _write_map \
    "$(_map_row "docs/feature.md" "feature" "1" "Section")"

  export RITE_PLAN_DOC_BYTE_CAP=0

  local result
  result=$(_collect_auto_docs)

  if echo "$result" | grep -q "CAP_ZERO_SENTINEL"; then
    echo "FAIL: content loaded despite RITE_PLAN_DOC_BYTE_CAP=0" >&2
    false
  fi

  # Empty output when cap=0
  [ -z "$result" ] || [ "$(printf '%s' "$result" | tr -d '[:space:]')" = "" ] || {
    echo "FAIL: non-empty output despite cap=0" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Test 6: RITE_PLAN_INCLUDE_README=false skips README in map-driven path
# ---------------------------------------------------------------------------

@test "map-driven: RITE_PLAN_INCLUDE_README=false skips README" {
  printf '# My Project\n\nREADME_SHOULD_NOT_APPEAR\n' > "$RITE_TEST_TMPDIR/README.md"

  _write_map \
    "$(_map_row "README.md" "other" "" "")"

  export RITE_PLAN_INCLUDE_README=false

  local result
  result=$(_collect_auto_docs)

  if echo "$result" | grep -q "README_SHOULD_NOT_APPEAR"; then
    echo "FAIL: README loaded despite RITE_PLAN_INCLUDE_README=false" >&2
    false
  fi
}

# ---------------------------------------------------------------------------
# Test 7: Zero provider calls in discovery (structural grep)
#
# The functions _collect_auto_docs, _collect_auto_docs_via_map, and
# _collect_auto_docs_whole_file must not call any provider_* function
# (the six functions that constitute the provider interface).
# ---------------------------------------------------------------------------

@test "structural: _collect_auto_docs functions contain zero provider calls" {
  # Extract the discovery functions from plan-issues.sh
  local _fn_block
  _fn_block="$(awk '
    /^_plan_extract_section[(][)]/ { in_fn=1; depth=0 }
    /^_collect_auto_docs_whole_file[(][)]/ { in_fn=1; depth=0 }
    /^_collect_auto_docs_via_map[(][)]/ { in_fn=1; depth=0 }
    /^_collect_auto_docs[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"

  # None of the provider_* entry points may appear in the extracted block
  local _provider_calls
  _provider_calls=$(printf '%s\n' "$_fn_block" | \
    grep -E 'provider_run_|provider_detect_cli|provider_resolve_model|load_provider' || true)

  if [ -n "$_provider_calls" ]; then
    echo "FAIL: discovery functions contain provider calls:" >&2
    echo "$_provider_calls" >&2
    false
  fi
}

# ---------------------------------------------------------------------------
# Test 8: _plan_extract_section — named section extraction
# ---------------------------------------------------------------------------

@test "_plan_extract_section extracts the correct named section" {
  cat > "$RITE_TEST_TMPDIR/docs/multi.md" <<'DOC'
# First Section

FIRST_SECTION_CONTENT

## Sub-heading

Sub content.

# Second Section

SECOND_SECTION_CONTENT

# Third Section

THIRD_SECTION_CONTENT
DOC

  local result
  result=$(_plan_extract_section "$RITE_TEST_TMPDIR/docs/multi.md" "1" "Second Section")

  echo "$result" | grep -q "SECOND_SECTION_CONTENT" || {
    echo "FAIL: target section content not extracted" >&2
    echo "--- extracted ---" >&2
    echo "$result" >&2
    false
  }

  if echo "$result" | grep -q "FIRST_SECTION_CONTENT"; then
    echo "FAIL: prior section content leaked into extraction" >&2
    false
  fi

  if echo "$result" | grep -q "THIRD_SECTION_CONTENT"; then
    echo "FAIL: subsequent section content leaked into extraction" >&2
    false
  fi
}

# ---------------------------------------------------------------------------
# Test 9: _plan_extract_section — preamble (no heading level/text)
# ---------------------------------------------------------------------------

@test "_plan_extract_section extracts preamble (pre-first-heading content)" {
  cat > "$RITE_TEST_TMPDIR/docs/preamble.md" <<'DOC'
PREAMBLE_CONTENT

This is introductory text before any heading.

# First Heading

HEADING_CONTENT
DOC

  local result
  result=$(_plan_extract_section "$RITE_TEST_TMPDIR/docs/preamble.md" "" "")

  echo "$result" | grep -q "PREAMBLE_CONTENT" || {
    echo "FAIL: preamble content not extracted" >&2
    echo "--- extracted ---" >&2
    echo "$result" >&2
    false
  }

  if echo "$result" | grep -q "HEADING_CONTENT"; then
    echo "FAIL: post-heading content included in preamble extraction" >&2
    false
  fi
}

# ---------------------------------------------------------------------------
# Test 10: Explicit doc_paths are skipped in map-driven discovery
#
# When the caller passes an explicit doc path to _collect_auto_docs, that
# file's sections must not appear twice in the output (no double-injection).
# ---------------------------------------------------------------------------

@test "map-driven: explicit doc path is not double-injected" {
  cat > "$RITE_TEST_TMPDIR/docs/explicit.md" <<'DOC'
# Explicit Section

EXPLICIT_SENTINEL
DOC

  _write_map \
    "$(_map_row "docs/explicit.md" "feature" "1" "Explicit Section")"

  local explicit_path="$RITE_TEST_TMPDIR/docs/explicit.md"

  # Pass the explicit path as an already-loaded path
  local result
  result=$(_collect_auto_docs "$explicit_path")

  local count
  count=$(printf '%s\n' "$result" | grep -c "EXPLICIT_SENTINEL" || true)
  [ "$count" -le 1 ] || {
    echo "FAIL: EXPLICIT_SENTINEL appeared $count times (double-injection)" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Backslash heading: ENVIRON avoids awk -v escape processing
#
# A heading that contains a backslash (e.g. "Match \r?") would be mangled by
# awk -v tgt_text="..." which processes C-escape sequences.  The extractor now
# passes the value via ENVIRON["TGT_TEXT"] which is never escape-processed.
# ---------------------------------------------------------------------------

@test "backslash heading: section with backslash in title is correctly extracted" {
  cat > "$RITE_TEST_TMPDIR/docs/regex.md" <<'DOC'
# Match \r?

BACKSLASH_SECTION_CONTENT

# Other Section

OTHER_CONTENT
DOC

  _write_map \
    "$(_map_row "docs/regex.md" "feature" "1" 'Match \r?')" \
    "$(_map_row "docs/regex.md" "feature" "1" "Other Section")"

  local result
  result=$(_collect_auto_docs)

  echo "$result" | grep -q "BACKSLASH_SECTION_CONTENT" || {
    echo "FAIL: backslash-heading section not found — awk -v escape processing bug" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Duplicate headings: second occurrence is reachable
#
# A file with two sections sharing the same title and level — the map references
# both.  The extractor must return each section's distinct content, not the first
# occurrence twice.
# ---------------------------------------------------------------------------

@test "duplicate headings: second occurrence is extracted correctly" {
  cat > "$RITE_TEST_TMPDIR/docs/dup.md" <<'DOC'
# Regression Test

FIRST_OCCURRENCE_CONTENT

# Regression Test

SECOND_OCCURRENCE_CONTENT

# Other Section

OTHER_CONTENT
DOC

  _write_map \
    "$(_map_row "docs/dup.md" "feature" "1" "Regression Test")" \
    "$(_map_row "docs/dup.md" "feature" "1" "Regression Test")" \
    "$(_map_row "docs/dup.md" "feature" "1" "Other Section")"

  export RITE_PLAN_DOC_BYTE_CAP=50000

  local result
  result=$(_collect_auto_docs)

  echo "$result" | grep -q "FIRST_OCCURRENCE_CONTENT" || {
    echo "FAIL: first occurrence content not found" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
  echo "$result" | grep -q "SECOND_OCCURRENCE_CONTENT" || {
    echo "FAIL: second occurrence content not found — duplicate heading always resolved to first" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Stale map: missing file is indexed, not silently dropped
#
# A map row that references a file which no longer exists on disk must NOT be
# silently skipped — its anchor must appear in the discoverability index so
# readers know it exists in the map.
# ---------------------------------------------------------------------------

@test "stale map: section for non-existent file appears in discoverability index" {
  # Write map with a path that does not exist on disk
  _write_map \
    "$(_map_row "docs/ghost.md" "feature" "1" "Missing Section")"

  # Set a non-zero cap so feature sections are processed
  export RITE_PLAN_DOC_BYTE_CAP=50000

  local result
  result=$(_collect_auto_docs)

  echo "$result" | grep -q "ghost.md" || {
    echo "FAIL: stale-map anchor not found in output — silent drop instead of index entry" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Stale map: heading that no longer exists is indexed, not silently dropped
#
# A map row references a heading that no longer appears in the file.  The
# section cannot be extracted, but the anchor must appear in the
# discoverability index.
# ---------------------------------------------------------------------------

@test "stale map: heading absent from file appears in discoverability index" {
  cat > "$RITE_TEST_TMPDIR/docs/updated.md" <<'DOC'
# Current Section

CURRENT_CONTENT
DOC

  # Map references a heading that does not exist in the file
  _write_map \
    "$(_map_row "docs/updated.md" "feature" "1" "Deleted Section")" \
    "$(_map_row "docs/updated.md" "feature" "1" "Current Section")"

  export RITE_PLAN_DOC_BYTE_CAP=50000

  local result
  result=$(_collect_auto_docs)

  # Current section content must be loaded
  echo "$result" | grep -q "CURRENT_CONTENT" || {
    echo "FAIL: current section not loaded" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }

  # Deleted section heading must appear in the discoverability index
  echo "$result" | grep -q "Deleted Section" || {
    echo "FAIL: deleted section anchor not in discoverability index" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
}
