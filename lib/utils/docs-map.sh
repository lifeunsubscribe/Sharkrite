#!/bin/bash
# lib/utils/docs-map.sh
#
# Deterministic docs-map builder. Inventories user documentation —
#   docs/**/*.md, README.md, CLAUDE.md (each only if present)
# — into .rite/state/docs-map.tsv, recording each file's headings and
# the HEAD SHA they were captured at.
#
# TSV format:
#   Line 1 (comment header): # docs-map v1 sha=<HEAD sha> built=<ISO-8601 UTC>
#   Remaining rows:           file_path<TAB>last_verified_sha<TAB>adr_flag<TAB>heading_level<TAB>heading_text
#
# Columns:
#   file_path          — project-relative path, e.g. README.md
#   last_verified_sha  — HEAD SHA at build time (later cluster-B issues update per-file)
#   adr_flag           — "adr" or "-"
#   heading_level      — 1-6 (number of leading # characters), or empty for files with no headings
#   heading_text       — heading text with leading #s and whitespace stripped; tabs stripped
#
# Files with zero headings get one row with empty heading_level and heading_text so
# they still appear in the inventory.
#
# No LLM involvement: the builder is fully deterministic.
# No consent-mode gating: builds regardless of .rite/doc-sync.md or RITE_DOC_MODE.
#
# Public API:
#   docs_map_path    — echoes the absolute path to the TSV map file
#   docs_map_build   — full rebuild; atomic write via temp file + mv
#   docs_map_ensure  — rebuilds when map is missing (no-op on SHA mismatch —
#                      cluster-B issues update last_verified_sha per-file and a
#                      full rebuild would clobber those audit records)
#
# Configuration:
#   RITE_DOCS_MAP_AUTO  (default: true) — set to "false" to suppress auto-rebuild
#                                         in docs_map_ensure

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing).
# Sentinel: docs_map_build — stable, defined only by this file.
if declare -f docs_map_build >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Bootstrap: ensure RITE_PROJECT_ROOT and RITE_STATE_DIR are available.
# In production, config.sh is always loaded first; the guard here makes this
# file sourceable standalone (e.g. during the re-source safety regression test).
# ---------------------------------------------------------------------------
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _DOCS_MAP_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_DOCS_MAP_SELF_DIR/config.sh"
fi

# ---------------------------------------------------------------------------
# RITE_DOCS_MAP_AUTO: controls whether docs_map_ensure auto-rebuilds.
# Defined here (not in config.sh) because it's consumed only by this library.
# config.sh sets the canonical export; this is a fallback for standalone use.
# ---------------------------------------------------------------------------
RITE_DOCS_MAP_AUTO="${RITE_DOCS_MAP_AUTO:-true}"

# ---------------------------------------------------------------------------
# docs_map_path
#
# Echo the absolute path to the docs-map TSV file.
# ---------------------------------------------------------------------------
docs_map_path() {
  local state_dir="${RITE_STATE_DIR:-${RITE_PROJECT_ROOT:-.}/.rite/state}"
  echo "${state_dir}/docs-map.tsv"
}

# ---------------------------------------------------------------------------
# _docs_map_is_adr_file FILE_PATH
#
# Returns 0 (true) when the given absolute path matches the ADR pattern:
#   docs/**/*adr*.md (case-insensitive), matching the find pattern used by
#   _collect_auto_docs() in lib/core/plan-issues.sh (~lines 131-132).
# Returns 1 (false) otherwise.
#
# We test only the basename (not the full path) so the pattern is consistent
# with the find-based discovery that uses -name, not -path.
# ---------------------------------------------------------------------------
_docs_map_is_adr_file() {
  local filepath="$1"
  local basename_only
  basename_only="$(basename "$filepath")"
  # Case-insensitive ADR match: filename contains "adr" in any case.
  # Use a case statement for bash 3.2 compatibility (no [[ =~ ]] with IGNORECASE).
  case "$basename_only" in
    *[Aa][Dd][Rr]*.md) return 0 ;;
    *)                  return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# _docs_map_heading_level LINE
#
# Echo the heading level (1-6) for a line that starts with one or more '#'.
# If the line is not a heading, echo empty string.
# ---------------------------------------------------------------------------
_docs_map_heading_level() {
  local line="$1"
  local hashes=""
  local rest="$line"
  # Count leading '#' characters (POSIX parameter expansion, bash 3.2 safe).
  while [ "${rest#\#}" != "$rest" ]; do
    hashes="${hashes}#"
    rest="${rest#\#}"
  done
  local level="${#hashes}"
  if [ "$level" -ge 1 ] && [ "$level" -le 6 ]; then
    echo "$level"
  else
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# _docs_map_heading_text LINE
#
# Strip leading '#' chars and surrounding whitespace from a heading line.
# Also strip any embedded tab characters (per spec: "tabs stripped from
# heading text on write").
# ---------------------------------------------------------------------------
_docs_map_heading_text() {
  local line="$1"
  # Strip leading '#' characters
  while [ "${line#\#}" != "$line" ]; do
    line="${line#\#}"
  done
  # Strip leading whitespace (POSIX: ${var#"${var%%[! ]*}"}  is overkill; use
  # a simple loop for portability without sed — but actually sed is fine here
  # and simpler; the CLAUDE.md style note says SC2001 is disabled).
  # Strip leading spaces/tabs:
  line="${line# }"
  line="${line#	}"
  # Strip trailing spaces/tabs (simple approach: no trailing whitespace expected in headings)
  line="${line% }"
  line="${line%	}"
  # Strip all embedded tab characters (replace with spaces per spec intent):
  # Use parameter expansion loop — no sed dependency for this simple case.
  local result=""
  local char
  local i=0
  local len="${#line}"
  while [ "$i" -lt "$len" ]; do
    # Extract one character at position $i using bash substring expansion
    char="${line:$i:1}"
    if [ "$char" = "	" ]; then
      # tab → skip (strip per spec)
      true
    else
      result="${result}${char}"
    fi
    i=$((i + 1))
  done
  echo "$result"
}

# ---------------------------------------------------------------------------
# docs_map_build
#
# Full rebuild of the docs-map TSV. Atomic: writes to a temp file and then
# mv's into place so concurrent readers never see a partial map.
#
# Inventory set (each only if present at build time):
#   1. docs/**/*.md  (recursive, sorted)
#   2. README.md     (project root)
#   3. CLAUDE.md     (project root)
#
# No-op guard: RITE_DOCS_MAP_AUTO is NOT checked here — docs_map_build always
# rebuilds. The auto-rebuild opt-out lives in docs_map_ensure.
# ---------------------------------------------------------------------------
docs_map_build() {
  local project_root="${RITE_PROJECT_ROOT:-.}"
  local state_dir="${RITE_STATE_DIR:-${project_root}/.rite/state}"
  local map_file="${state_dir}/docs-map.tsv"

  # Ensure state directory exists (mkdir -p is idempotent)
  mkdir -p "$state_dir"

  # Capture HEAD SHA (no -e guard: git rev-parse HEAD fails only in a non-repo,
  # which is caught earlier by config.sh; || true keeps set -e from firing if
  # somehow invoked outside a repo in tests).
  local head_sha
  head_sha="$(git -C "$project_root" rev-parse HEAD 2>/dev/null || echo "unknown")"

  # ISO-8601 UTC timestamp for the header.
  # BSD date: date -u +%Y-%m-%dT%H:%M:%SZ
  # GNU date: date -u +%Y-%m-%dT%H:%M:%SZ  (identical format, both work)
  local built_ts
  built_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Write to temp file for atomic replace
  local tmp_file
  tmp_file="$(mktemp "${state_dir}/docs-map.tsv.XXXXXX")"
  # Ensure cleanup if we exit unexpectedly before mv
  # (not using EXIT trap per test-runbook Rule 4 — this function is not a @test body;
  #  the trap is fine in a library function but we use a local var for simplicity)

  # Line 1: comment header
  printf '# docs-map v1 sha=%s built=%s\n' "$head_sha" "$built_ts" > "$tmp_file"

  # -------------------------------------------------------------------------
  # Collect inventory: docs/**/*.md + README.md + CLAUDE.md
  # Use a while-read loop for bash 3.2 compatibility (no mapfile/readarray).
  # -------------------------------------------------------------------------
  local -a inventory_files=()
  local _f

  # 1. docs/**/*.md — find all .md files under docs/ sorted alphabetically
  if [ -d "${project_root}/docs" ]; then
    while IFS= read -r _f; do
      inventory_files+=("$_f")
    done < <(find "${project_root}/docs" -name "*.md" -type f 2>/dev/null | sort -u || true)
  fi

  # 2. README.md (project root, if present)
  if [ -f "${project_root}/README.md" ]; then
    inventory_files+=("${project_root}/README.md")
  fi

  # 3. CLAUDE.md (project root, if present)
  if [ -f "${project_root}/CLAUDE.md" ]; then
    inventory_files+=("${project_root}/CLAUDE.md")
  fi

  # -------------------------------------------------------------------------
  # Process each file: harvest headings and emit TSV rows
  # -------------------------------------------------------------------------
  local file_path
  for file_path in "${inventory_files[@]+"${inventory_files[@]}"}"; do
    # Compute project-relative path (strip leading project_root + /)
    local rel_path="${file_path#"${project_root}/"}"

    # Determine ADR flag
    local adr_flag="-"
    if _docs_map_is_adr_file "$file_path"; then
      adr_flag="adr"
    fi

    # Harvest headings: grep lines starting with one or more '#'
    # Use || true to prevent silent death under set -e when grep finds no match.
    local headings_raw
    headings_raw="$(grep "^#" "$file_path" 2>/dev/null || true)"

    if [ -z "$headings_raw" ]; then
      # File has zero headings: emit one row with empty level/heading so the
      # file still appears in the inventory (per spec).
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$rel_path" "$head_sha" "$adr_flag" "" "" >> "$tmp_file"
    else
      # Emit one row per heading
      local heading_line
      while IFS= read -r heading_line; do
        # Skip empty lines (shouldn't happen with grep "^#" but guard anyway)
        [ -n "$heading_line" ] || continue
        local h_level h_text
        h_level="$(_docs_map_heading_level "$heading_line")"
        h_text="$(_docs_map_heading_text "$heading_line")"
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$rel_path" "$head_sha" "$adr_flag" "$h_level" "$h_text" >> "$tmp_file"
      done <<< "$headings_raw"
    fi
  done

  # Atomic replace
  mv "$tmp_file" "$map_file"
}

# ---------------------------------------------------------------------------
# docs_map_ensure
#
# Rebuild the docs-map if it is missing. Silent except for one verbose-level
# line when a rebuild occurs.
#
# Does NOT rebuild on HEAD-SHA mismatch: later cluster-B issues update
# last_verified_sha per-file, and an auto-rebuild would clobber those records.
#
# Respects RITE_DOCS_MAP_AUTO: when set to "false" (or "0"), skips rebuild
# entirely and returns 0.
# ---------------------------------------------------------------------------
docs_map_ensure() {
  local map_file
  map_file="$(docs_map_path)"

  # Honour opt-out flag
  local auto_enabled="${RITE_DOCS_MAP_AUTO:-true}"
  if [ "$auto_enabled" = "false" ] || [ "$auto_enabled" = "0" ]; then
    return 0
  fi

  # Rebuild only when the map is missing
  if [ ! -f "$map_file" ]; then
    # Emit verbose-level message if verbose logging is available
    if declare -f verbose_info >/dev/null 2>&1; then
      verbose_info "docs-map: rebuilding missing map → $(basename "$map_file")"
    fi
    docs_map_build
  fi
}
