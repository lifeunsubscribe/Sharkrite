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
#
# Uses printf '%s' instead of echo to avoid the echo round-trip, which would
# mangle pointer text containing backslashes, $() sequences, or other special
# characters that echo may interpret or expand.
_ti_build_pointer_text() {
  local text=""
  local p
  for p in "${TAG_POINTERS[@]+"${TAG_POINTERS[@]}"}"; do
    text="${text}${p}
"
  done
  printf '%s' "$text"
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
# Write helpers (Stage 2 — post-merge tag-index updates)
# =============================================================================

# tag_index_ensure_file
#
# Creates docs/architecture/tag-index.md with the bootstrap scaffold if it
# does not already exist.  Mirrors the conventions.md bootstrap pattern in
# assess-documentation.sh::update_conventions_from_marker.
#
# Returns 0 on success (file existed or was created).
tag_index_ensure_file() {
  if [ -f "$TAG_INDEX_FILE" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$TAG_INDEX_FILE")"
  cat > "$TAG_INDEX_FILE" <<'BOOTSTRAP_EOF'
# Tag Index

**Auto-maintained — do not hand-edit.** See `docs/architecture/tag-index-system.md`.

---

BOOTSTRAP_EOF
}

# tag_index_ensure_heading TAG
#
# Ensures a `## TAG` heading exists in tag-index.md.  Creates it (appended at
# the end of the file) when missing.  No-op when the heading already exists.
# Assumes tag_index_ensure_file has already been called.
#
# Arguments:
#   $1 — tag name (the heading text after "## ")
tag_index_ensure_heading() {
  local tag="$1"

  # Already present — no-op
  if grep -qxF -- "## ${tag}" "$TAG_INDEX_FILE" 2>/dev/null; then
    return 0
  fi

  # Append a new heading section at the end of the file
  {
    echo ""
    echo "## ${tag}"
    echo ""
  } >> "$TAG_INDEX_FILE"
}

# tag_index_add_pointer TAG SOURCE_FILE HEADING
#
# Adds a pointer line under the ## TAG heading in tag-index.md.  Idempotent:
# does nothing when the exact pointer (source_file → heading) already exists
# under that tag.
#
# Returns 0 on success.
# Returns 1 with an error message on stderr when the ## TAG heading is absent —
# callers must call tag_index_ensure_heading before this function.
#
# Pointer format:  - conventions.md → Heading Text
#
# Arguments:
#   $1 — tag name (must be an existing heading — call tag_index_ensure_heading first)
#   $2 — source catalog file short name (e.g. "conventions.md")
#   $3 — heading text in the source catalog (e.g. "grep -c pattern")
tag_index_add_pointer() {
  local tag="$1"
  local source_file="$2"
  local heading="$3"
  local pointer_line="- ${source_file} → ${heading}"

  # Idempotency check: scan lines under ## TAG for an exact pointer match.
  # We use awk to look only within the target tag's section (between ## TAG
  # and the next ## or end of file) rather than a global grep, so a pointer
  # in a different tag's section does not suppress a legitimate new addition.
  local _already_present
  _already_present=$(awk -v tag="## ${tag}" -v ptr="${pointer_line}" '
    $0 == tag      { in_tag=1; next }
    in_tag && /^## / { in_tag=0 }
    in_tag && $0 == ptr { print "yes"; exit }
  ' "$TAG_INDEX_FILE" || true)

  if [ "$_already_present" = "yes" ]; then
    return 0
  fi

  # Insert the pointer immediately after the ## TAG heading line.
  # Strategy: awk rewrites the file via a temp file — when it sees the target
  # heading, it prints the heading then inserts the new pointer line.
  # The `inserted` flag prevents duplicate insertions if the heading appears
  # more than once (should not happen in a well-formed index, but be defensive).
  #
  # The END block exits with status 1 when inserted==0, meaning the heading was
  # never found in the file.  This causes _awk_exit to be non-zero, which is
  # caught below to surface a diagnostic instead of silently no-oping.
  local _tmp
  _tmp=$(mktemp)
  local _awk_exit=0
  awk -v tag="## ${tag}" -v ptr="${pointer_line}" '
    BEGIN { inserted=0 }
    $0 == tag && !inserted {
      print
      print ptr
      inserted=1
      next
    }
    { print }
    END { exit !inserted }
  ' "$TAG_INDEX_FILE" > "$_tmp" || _awk_exit=$?

  if [ -s "$_tmp" ] && [ "$_awk_exit" -eq 0 ]; then
    mv "$_tmp" "$TAG_INDEX_FILE"
  else
    rm -f "$_tmp"
    # Non-zero _awk_exit means the heading was not found (inserted==0 at END).
    # Report the missing heading so the caller can diagnose the problem rather
    # than silently dropping the pointer.
    if [ "$_awk_exit" -ne 0 ]; then
      echo "tag_index_add_pointer: heading '## ${tag}' not found in ${TAG_INDEX_FILE} — pointer not inserted (call tag_index_ensure_heading first)" >&2
      return 1
    fi
  fi
}

# update_tag_index_from_block TAG_LINE NEW_TAGS_BLOCK SOURCE_CATALOG SOURCE_HEADING PR_NUMBER
#
# Called from update_conventions_from_marker after a convention block is
# processed.  Reads the block's `tags:` and `new-tags:` fields and updates
# tag-index.md accordingly:
#   - For each tag in `tags:`, ensures the heading exists and adds a pointer.
#   - For each tag in `new-tags:`, does the same (the lint rule enforces that
#     new-tags entries must have a justification; this function just creates them).
#
# Arguments:
#   $1 — raw `tags:` line content (comma-separated tag names, or empty)
#   $2 — raw `new-tags:` block content (newline-separated "  - tag: justif", or empty)
#   $3 — source catalog short name (e.g. "conventions.md")
#   $4 — heading text from the convention entry (the title field)
#   $5 — PR number (for informational messages only)
update_tag_index_from_block() {
  local tags_line="$1"
  local new_tags_block="$2"
  local source_catalog="$3"
  local source_heading="$4"
  local pr_number="$5"

  # Collect all tags: start with tags: field, then add new-tags: entries
  local all_tags=""

  # Parse comma-separated tags: field.
  # Use a herestring (<<< "$tags_line") so tr's output always has a trailing
  # newline — without it, 'while read' silently drops the last token because
  # read treats a line with no terminating newline as incomplete.
  if [ -n "$tags_line" ]; then
    local _tag
    while IFS= read -r _tag; do
      _tag="${_tag#"${_tag%%[![:space:]]*}"}"  # ltrim
      _tag="${_tag%"${_tag##*[![:space:]]}"}"  # rtrim
      [ -z "$_tag" ] && continue
      if [ -z "$all_tags" ]; then
        all_tags="$_tag"
      else
        all_tags="${all_tags}
${_tag}"
      fi
    done < <(tr ',' '\n' <<< "$tags_line" || true)
  fi

  # Parse new-tags: block (format: "  - tagname: justification" per spec)
  if [ -n "$new_tags_block" ]; then
    local _ntag_line _ntag
    while IFS= read -r _ntag_line; do
      # Match "  - tagname:" or "- tagname:" patterns
      if echo "$_ntag_line" | grep -qE '^[[:space:]]*-[[:space:]]+[a-zA-Z0-9_-]+:'; then
        _ntag=$(echo "$_ntag_line" | grep -oE '[a-zA-Z0-9_-]+:' | head -1 | sed 's/:$//' || true)
        [ -z "$_ntag" ] && continue
        # Add only if not already in all_tags
        if ! printf '%s\n' "$all_tags" | grep -qxF "$_ntag" 2>/dev/null; then
          if [ -z "$all_tags" ]; then
            all_tags="$_ntag"
          else
            all_tags="${all_tags}
${_ntag}"
          fi
        fi
      fi
    done <<< "$new_tags_block"
  fi

  # No tags to process — nothing to do
  if [ -z "$all_tags" ]; then
    return 0
  fi

  # Ensure tag-index.md exists (bootstrap if missing)
  tag_index_ensure_file

  # Process each tag
  local _tag
  while IFS= read -r _tag; do
    [ -z "$_tag" ] && continue
    tag_index_ensure_heading "$_tag"
    if ! tag_index_add_pointer "$_tag" "$source_catalog" "$source_heading"; then
      verbose_info "  tag-index: skipped tag '${_tag}' — heading not found after ensure (PR #${pr_number})"
      continue
    fi
    verbose_info "  tag-index: updated tag '${_tag}' ← ${source_catalog} → ${source_heading} (PR #${pr_number})"
  done <<< "$all_tags"
}

# =============================================================================
# Justification audit log (Stage 3 foundation)
# =============================================================================

# tag_index_log_history <action> <pr_number> <args...> — append a deduped audit
# line to .rite/tag-index-history.log. Best-effort; never propagates failure.
#   justified  <tag> <justification>  -> "tag: <tag> | <justification>"
#   added      <tag> <file> <heading> -> "added <tag> → <file> → <heading>"  (→ matches the index separator, #762)
#   merged     <tag> <into>           -> "merged <tag> into <into>"
# Dedup (#761): a date-independent entry already logged for this PR is not re-appended.
tag_index_log_history() {
  local action="$1" pr_number="$2"; shift 2
  local timestamp; timestamp=$(date +%Y-%m-%d 2>/dev/null || echo "unknown-date")
  local detail
  case "$action" in
    justified) detail="tag: $1 | $2" ;;
    added)     detail="added $1 → $2 → $3" ;;
    merged)    detail="merged $1 into $2" ;;
    *)         detail="$action: $*" ;;
  esac
  local audit_line="${timestamp} | PR #${pr_number} | ${detail}"
  verbose_info "  tag-index: ${audit_line}"
  local log_dir="${RITE_PROJECT_ROOT:-}/.rite"
  local log_file="${log_dir}/tag-index-history.log"
  if [ -d "$log_dir" ] || mkdir -p "$log_dir" 2>/dev/null; then
    if [ -f "$log_file" ] && grep -qF "PR #${pr_number} | ${detail}" "$log_file" 2>/dev/null; then
      return 0
    fi
    printf '%s\n' "$audit_line" >> "$log_file" 2>/dev/null || true
  fi
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
