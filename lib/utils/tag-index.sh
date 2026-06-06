#!/bin/bash
# lib/utils/tag-index.sh — Tag index parsing and CLI rendering
#
# Implements the read path for the tag-index system:
#   rite --tags              Full index
#   rite --tags <tag>        Pointers for a specific tag
#   rite --tags --orphans    Catalog entries not pointed at by any tag
#   rite --tags --history    Sonnet-merge log (stub — populated in Stage 3)
#
# File format (docs/architecture/tag-index.md):
#   # Tag Index
#   **Auto-maintained — do not hand-edit.**
#   ---
#   ## <tag>
#   - <catalog-file>.md → <Heading Text>
#   ...
#
# See: docs/architecture/tag-index-system.md for the full spec.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f show_tag_index >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config and dependencies if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _TAG_INDEX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_TAG_INDEX_SCRIPT_DIR/config.sh"
fi
source "$RITE_LIB_DIR/utils/colors.sh"

# =============================================================================
# Constants
# =============================================================================

TAG_INDEX_FILE="${RITE_PROJECT_ROOT:-}/docs/architecture/tag-index.md"
CONVENTIONS_FILE="${RITE_PROJECT_ROOT:-}/docs/architecture/conventions.md"
ENCOUNTERED_FILE="${RITE_PROJECT_ROOT:-}/docs/architecture/encountered-issues.md"

# Regex patterns for arrow separators stored at module level to prevent bash
# from parsing ">" in "->" as an output redirect when used inline in [[ =~ ]].
# Both unicode arrow (→, U+2192) and ASCII arrow (->) are supported.
_TI_UNICODE_ARROW_RE="→[[:space:]]*(.+)$"
_TI_ASCII_ARROW_RE="->[[:space:]]*(.+)$"

# =============================================================================
# Parsing
# =============================================================================

# parse_tag_index
#
# Reads tag-index.md and populates parallel arrays:
#   TAG_NAMES[]         — tag name (from ## heading)
#   TAG_POINTER_COUNTS[] — number of pointers for each tag
#   TAG_POINTERS[]       — all pointers, concatenated; use offsets to slice
#   TAG_POINTER_OFFSETS[] — start index in TAG_POINTERS for each tag
#
# Also sets:
#   TAG_TOTAL_COUNT    — number of unique tags
#   TAG_TOTAL_POINTERS — total number of pointer entries
#
# Returns 0 on success, 1 if tag-index.md doesn't exist.
TAG_NAMES=()
TAG_POINTER_COUNTS=()
TAG_POINTERS=()
TAG_POINTER_OFFSETS=()
TAG_TOTAL_COUNT=0
TAG_TOTAL_POINTERS=0

parse_tag_index() {
  TAG_NAMES=()
  TAG_POINTER_COUNTS=()
  TAG_POINTERS=()
  TAG_POINTER_OFFSETS=()
  TAG_TOTAL_COUNT=0
  TAG_TOTAL_POINTERS=0

  if [ ! -f "$TAG_INDEX_FILE" ]; then
    return 1
  fi

  local current_tag=""
  local current_count=0
  local _line

  while IFS= read -r _line; do
    # Skip the H1 title line ("# Tag Index") and metadata lines
    if [[ "$_line" =~ ^#[[:space:]] ]]; then
      continue
    fi

    # Detect H2 tag headings: "## tagname"
    if [[ "$_line" =~ ^##[[:space:]]+(.+)$ ]]; then
      # Save previous tag's count before starting the next tag
      if [ -n "$current_tag" ]; then
        TAG_POINTER_COUNTS+=("$current_count")
      fi
      current_tag="${BASH_REMATCH[1]}"
      # Trim trailing whitespace
      current_tag="${current_tag%"${current_tag##*[![:space:]]}"}"
      TAG_NAMES+=("$current_tag")
      TAG_POINTER_OFFSETS+=("$TAG_TOTAL_POINTERS")
      current_count=0
      continue
    fi

    # Detect pointer entries: "- <file>.md → <Heading>"
    if [[ "$_line" =~ ^-[[:space:]] ]] && [ -n "$current_tag" ]; then
      # Strip leading "- "
      local pointer="${_line#- }"
      if [ -n "$pointer" ]; then
        TAG_POINTERS+=("$pointer")
        current_count=$((current_count + 1))
        TAG_TOTAL_POINTERS=$((TAG_TOTAL_POINTERS + 1))
      fi
    fi
  done < "$TAG_INDEX_FILE"

  # Save last tag's count
  if [ -n "$current_tag" ]; then
    TAG_POINTER_COUNTS+=("$current_count")
  fi

  TAG_TOTAL_COUNT="${#TAG_NAMES[@]}"
  return 0
}

# =============================================================================
# Orphan helpers
# =============================================================================

# _ti_extract_ptr_heading POINTER_TEXT
#
# Extracts the heading portion from a pointer string.
# Pointer format: "file.md → Heading Text"  or  "file.md -> Heading Text"
# Outputs the heading text to stdout, or empty string if not parseable.
_ti_extract_ptr_heading() {
  local ptr="$1"
  local heading=""
  if [[ "$ptr" =~ $_TI_UNICODE_ARROW_RE ]]; then
    heading="${BASH_REMATCH[1]}"
    heading="${heading%"${heading##*[![:space:]]}"}"
  elif [[ "$ptr" =~ $_TI_ASCII_ARROW_RE ]]; then
    heading="${BASH_REMATCH[1]}"
    heading="${heading%"${heading##*[![:space:]]}"}"
  fi
  echo "$heading"
}

# _ti_is_heading_pointed HEADING ALL_POINTER_TEXT
#
# Returns 0 (true) if HEADING is referenced by any pointer in ALL_POINTER_TEXT.
# Comparison is case-insensitive with spaces/dashes normalized.
#
# Arguments:
#   $1 — heading text to search for
#   $2 — newline-separated block of all pointer strings
_ti_is_heading_pointed() {
  local heading="$1"
  local all_ptr_text="$2"
  local norm_heading
  norm_heading=$(echo "$heading" | tr '[:upper:]' '[:lower:]' | tr -s ' -' ' ')

  local ptr
  while IFS= read -r ptr; do
    [ -z "$ptr" ] && continue
    local ptr_heading
    ptr_heading=$(_ti_extract_ptr_heading "$ptr")
    if [ -z "$ptr_heading" ]; then
      continue
    fi
    local norm_ptr
    norm_ptr=$(echo "$ptr_heading" | tr '[:upper:]' '[:lower:]' | tr -s ' -' ' ')
    if [ "$norm_heading" = "$norm_ptr" ]; then
      return 0  # found — heading is pointed at
    fi
  done <<< "$all_ptr_text"

  return 1  # not found — heading is an orphan
}

# _ti_build_pointer_text
#
# Builds a newline-separated string of all pointer entries from the currently
# parsed TAG_POINTERS array. Outputs to stdout.
_ti_build_pointer_text() {
  local text=""
  local p
  for p in "${TAG_POINTERS[@]+"${TAG_POINTERS[@]}"}"; do
    text="${text}${p}
"
  done
  echo "$text"
}

# _ti_count_orphans_in_file CATALOG_FILE ALL_POINTER_TEXT
#
# Counts H2 headings in CATALOG_FILE that are not pointed at by any
# entry in ALL_POINTER_TEXT. Outputs the count to stdout.
_ti_count_orphans_in_file() {
  local catalog_file="$1"
  local all_ptr_text="$2"
  local count=0

  [ -f "$catalog_file" ] || { echo "$count"; return 0; }

  local _line
  while IFS= read -r _line; do
    if [[ "$_line" =~ ^##[[:space:]]+(.+)$ ]]; then
      local heading="${BASH_REMATCH[1]}"
      heading="${heading%"${heading##*[![:space:]]}"}"
      if ! _ti_is_heading_pointed "$heading" "$all_ptr_text"; then
        count=$((count + 1))
      fi
    fi
  done < "$catalog_file"

  echo "$count"
}

# _ti_print_orphans_in_file CATALOG_FILE SHORT_NAME ALL_POINTER_TEXT
#
# Prints orphan headings (those not referenced by any pointer) from
# CATALOG_FILE, prefixed with SHORT_NAME. Outputs only display lines (no count).
_ti_print_orphans_in_file() {
  local catalog_file="$1"
  local short_name="$2"
  local all_ptr_text="$3"

  [ -f "$catalog_file" ] || return 0

  local _line
  while IFS= read -r _line; do
    if [[ "$_line" =~ ^##[[:space:]]+(.+)$ ]]; then
      local heading="${BASH_REMATCH[1]}"
      heading="${heading%"${heading##*[![:space:]]}"}"
      if ! _ti_is_heading_pointed "$heading" "$all_ptr_text"; then
        echo "  $short_name → $heading"
      fi
    fi
  done < "$catalog_file"
}

# _ti_count_orphan_headings
#
# Counts orphan headings across both catalog files.
# Requires TAG_POINTERS to be populated by parse_tag_index.
# Outputs the total count to stdout.
_ti_count_orphan_headings() {
  local all_ptr_text
  all_ptr_text=$(_ti_build_pointer_text)

  local conv_count enc_count
  conv_count=$(_ti_count_orphans_in_file "$CONVENTIONS_FILE" "$all_ptr_text")
  enc_count=$(_ti_count_orphans_in_file "$ENCOUNTERED_FILE" "$all_ptr_text")

  echo $(( conv_count + enc_count ))
}

# =============================================================================
# Rendering
# =============================================================================

# render_tag_index_full
#
# Prints the full tag index in the format specified by the CLI spec:
#
#   Tag Index (N tags, M pointers)
#
#     tagname              (K entries)
#       → conventions.md → Heading text
#       ...
#
#   Untagged catalog entries: N
#     (use --tags --orphans to list)
render_tag_index_full() {
  if ! parse_tag_index; then
    echo "No tag-index yet — will populate on first PR with \`tags:\` block"
    return 0
  fi

  local untagged_count
  untagged_count=$(_ti_count_orphan_headings)

  echo ""
  echo "Tag Index ($TAG_TOTAL_COUNT tags, $TAG_TOTAL_POINTERS pointers)"

  if [ "$TAG_TOTAL_COUNT" -eq 0 ]; then
    echo ""
    echo "  (no tags defined)"
    echo ""
  else
    echo ""
    local i
    for i in "${!TAG_NAMES[@]}"; do
      local tag="${TAG_NAMES[$i]}"
      local count="${TAG_POINTER_COUNTS[$i]}"
      local offset="${TAG_POINTER_OFFSETS[$i]}"

      # Right-pad tag name to 20 chars for alignment
      local padded_tag
      printf -v padded_tag '%-20s' "$tag"

      local entry_word="entries"
      [ "$count" -eq 1 ] && entry_word="entry"
      printf "  %s (%d %s)\n" "$padded_tag" "$count" "$entry_word"

      # Print pointers for this tag
      local j
      for (( j=offset; j<offset+count; j++ )); do
        echo "    → ${TAG_POINTERS[$j]}"
      done
      echo ""
    done
  fi

  echo "Untagged catalog entries: ${untagged_count}"
  echo "  (use --tags --orphans to list)"
  echo ""
}

# render_tag_index_single TAG
#
# Prints pointers for a specific tag, or a "no such tag" message.
render_tag_index_single() {
  local target_tag="$1"

  if ! parse_tag_index; then
    echo "No tag-index yet — will populate on first PR with \`tags:\` block"
    return 0
  fi

  local target_lower
  target_lower=$(echo "$target_tag" | tr '[:upper:]' '[:lower:]')

  local i
  for i in "${!TAG_NAMES[@]}"; do
    local tag_lower
    tag_lower=$(echo "${TAG_NAMES[$i]}" | tr '[:upper:]' '[:lower:]')

    if [ "$tag_lower" = "$target_lower" ]; then
      local count="${TAG_POINTER_COUNTS[$i]}"
      local offset="${TAG_POINTER_OFFSETS[$i]}"
      local entry_word="entries"
      [ "$count" -eq 1 ] && entry_word="entry"
      echo ""
      echo "Tag: ${TAG_NAMES[$i]} ($count $entry_word)"
      echo ""
      local j
      for (( j=offset; j<offset+count; j++ )); do
        echo "  → ${TAG_POINTERS[$j]}"
      done
      echo ""
      return 0
    fi
  done

  echo "No such tag: $target_tag"
  return 0
}

# render_tag_index_orphans
#
# Lists catalog headings (## level) from conventions.md and encountered-issues.md
# that are not pointed at by any tag in the index.
render_tag_index_orphans() {
  # Load index if present; orphan scan works even with an empty/missing index
  # (all headings are orphans when there's no index).
  parse_tag_index || true

  local all_ptr_text
  all_ptr_text=$(_ti_build_pointer_text)

  echo ""
  echo "Untagged catalog entries:"
  echo ""

  # Print orphan lines directly (no count embedded in output)
  local conv_lines enc_lines
  conv_lines=$(_ti_print_orphans_in_file "$CONVENTIONS_FILE" "conventions.md" "$all_ptr_text")
  enc_lines=$(_ti_print_orphans_in_file "$ENCOUNTERED_FILE" "encountered-issues.md" "$all_ptr_text")

  [ -n "$conv_lines" ] && echo "$conv_lines"
  [ -n "$enc_lines" ] && echo "$enc_lines"

  # Count orphans separately (uses the same logic as the display, avoids head -n -1)
  local total_orphans
  total_orphans=$(_ti_count_orphan_headings)

  if [ "$total_orphans" -eq 0 ]; then
    echo "  (none — all catalog headings are tagged)"
  fi

  echo ""
  echo "Total untagged: $total_orphans"
  echo ""
}

# render_tag_index_history
#
# Stub — Stage 3 will populate the actual merge log from doc-assessment runs.
render_tag_index_history() {
  echo ""
  echo "Tag index history: no history yet"
  echo "  (populated in Stage 3 when doc-assessment runs drift reconciliation)"
  echo ""
}

# =============================================================================
# Top-level dispatcher
# =============================================================================

# show_tag_index [--orphans | --history | <tag>]
#
# Called from bin/rite with the sub-arg following --tags.
show_tag_index() {
  local subarg="${1:-}"

  case "$subarg" in
    --orphans)
      render_tag_index_orphans
      ;;
    --history)
      render_tag_index_history
      ;;
    "")
      render_tag_index_full
      ;;
    -*)
      echo "Unknown --tags flag: $subarg" >&2
      echo "Usage: rite --tags [<tag> | --orphans | --history]" >&2
      return 1
      ;;
    *)
      # Treat as a tag name lookup
      render_tag_index_single "$subarg"
      ;;
  esac
}
