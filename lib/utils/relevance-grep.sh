#!/bin/bash
# lib/utils/relevance-grep.sh — Codebase grep for "Relevant prior art" injection
#
# Scans issue body text for:
#   - File paths matching [a-z_/-]+\.(sh|md|conf|bats)
#   - Backticked symbols matching `[a-z_]+()`  (function calls)
#   - Backticked symbols matching `$[A-Z_]+`   (env vars)
#
# For each found symbol/path, runs rg (if available) or grep -rn under lib/ and
# bin/, captures the top 3 call-site lines, and formats the output as:
#
#   Existing usages of `foo()`:
#     - lib/core/workflow-runner.sh:421
#     - lib/utils/timeout.sh:78
#
# This output is injected into the "Relevant prior art" block in the Phase 1
# prompt by build_relevant_prior_art() in claude-workflow.sh.
#
# Self-reference filter (#774/#776): when the issue names a file it intends to
# MODIFY, that file's own self-naming header-comment line must NOT be surfaced
# as prior-art "existing usage" of itself. See _is_self_reference below.
#
# See: docs/architecture/tag-index-system.md → "Codebase Grep (hardening layer)"

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f relevance_grep >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# =============================================================================
# Internal helpers
# =============================================================================

# _is_self_reference SYMBOL FILE_LINE
#
# #774/#776 self-reference filter.
#
# Returns 0 (true) when SYMBOL is a file path AND FILE_LINE ("path:lineno")
# points at that same file's own header-comment self-reference — i.e. the line
# is a shell comment (first non-space char is `#`) that names the file. When an
# issue names a file it intends to MODIFY, the file's only occurrence under
# lib/bin is often its own header comment (`# lib/utils/foo.sh — ...`); listing
# that as prior-art "existing usage" of itself is noise, not prior art.
#
# Returns 1 (false) for genuine cross-file references, non-comment lines, or
# when SYMBOL is not a file path (function calls / env vars never self-match).
#
# Arguments:
#   $1 — symbol that was searched for (e.g. lib/utils/foo.sh)
#   $2 — a "path:lineno" hit emitted by _grep_symbol
_is_self_reference() {
  local symbol="$1"
  local file_line="$2"

  # Only file paths can self-reference; backticked symbols cannot.
  case "$symbol" in
    *.sh|*.md|*.conf|*.bats) : ;;
    *) return 1 ;;
  esac

  # Split "path:lineno" — lineno is the trailing :N segment.
  local hit_path="${file_line%:*}"
  local hit_line="${file_line##*:}"
  [ -z "$hit_path" ] && return 1
  [ -z "$hit_line" ] && return 1
  case "$hit_line" in
    *[!0-9]*|'') return 1 ;;  # lineno must be all digits
  esac

  # The hit must be IN the file the symbol names (basename match handles the
  # path-prefix variance between the issue's reference and the on-disk path).
  local symbol_base="${symbol##*/}"
  local hit_base="${hit_path##*/}"
  [ "$symbol_base" = "$hit_base" ] || return 1

  # Read the offending line and check it is a comment that names the file.
  [ -f "$hit_path" ] || return 1
  local line_content
  line_content=$(sed -n "${hit_line}p" "$hit_path" 2>/dev/null || true)
  [ -z "$line_content" ] && return 1

  # First non-space character must be `#` (shell comment / header line).
  case "$line_content" in
    \#*|[[:space:]]*\#*|[[:space:]]*) : ;;
    *) return 1 ;;
  esac
  # Be strict: trimmed leading whitespace, then a `#`.
  local trimmed="${line_content#"${line_content%%[![:space:]]*}"}"
  case "$trimmed" in
    \#*) : ;;
    *) return 1 ;;
  esac

  # And the comment line must mention the file (by basename or full symbol).
  case "$line_content" in
    *"$symbol"*|*"$symbol_base"*) return 0 ;;
    *) return 1 ;;
  esac
}

# _grep_symbol SYMBOL SEARCH_DIRS...
#
# Greps for SYMBOL under SEARCH_DIRS and returns at most 3 matching lines
# in "file:line" format (no surrounding context).
#
# Arguments:
#   $1 — literal symbol to search for (passed as a fixed string to grep)
#   $2+ — directories to search under
#
# Output: up to 3 lines of "path:lineno" to stdout.  Empty on no match.
# Never fails (|| true on all grep calls).
_grep_symbol() {
  local symbol="$1"
  shift
  local dirs=("$@")

  [ "${#dirs[@]}" -eq 0 ] && return 0
  [ -z "$symbol" ] && return 0

  local results=""

  if command -v rg >/dev/null 2>&1; then
    # rg --no-heading gives "file:line:content" — strip content, keep "file:line"
    results=$(rg --fixed-strings --line-number --no-heading \
      --max-count 3 "$symbol" "${dirs[@]}" 2>/dev/null \
      | head -3 \
      | sed 's/\(:[0-9]*\):.*/\1/' \
      || true)
  else
    # grep -rn fallback
    results=$(grep -rnF "$symbol" "${dirs[@]+"${dirs[@]}"}" 2>/dev/null \
      | head -3 \
      | sed 's/\(:[0-9]*\):.*/\1/' \
      || true)
  fi

  printf '%s' "$results"
}

# _extract_file_paths ISSUE_TEXT
#
# Extracts file paths of the form [a-z_/-]+\.(sh|md|conf|bats) from ISSUE_TEXT.
# Outputs one match per line.
_extract_file_paths() {
  local text="$1"
  # grep -oE extracts all non-overlapping matches; || true handles no-match exit.
  # Include digits (0-9) and uppercase (A-Z) so paths like adr-001.md and
  # foo2bar.sh are not silently missed.
  printf '%s' "$text" | grep -oE '[a-zA-Z0-9_/][a-zA-Z0-9_/-]*\.(sh|md|conf|bats)' || true
}

# _extract_backtick_symbols ISSUE_TEXT
#
# Extracts backtick-delimited symbols from ISSUE_TEXT matching:
#   `[a-z_]+()`   — function call
#   `$[A-Z_]+`    — env var
#
# Outputs one match per line (with backticks stripped).
_extract_backtick_symbols() {
  local text="$1"
  # Match `func()` or `$VAR`
  printf '%s' "$text" | grep -oE '`[a-z_]+\(\)|`\$[A-Z_]+'  \
    | tr -d '`' \
    || true
}

# =============================================================================
# Public API
# =============================================================================

# relevance_grep ISSUE_TEXT PROJECT_ROOT
#
# Scans ISSUE_TEXT for file paths and backticked symbols, greps for each under
# PROJECT_ROOT/{lib,bin}, and returns formatted "Existing usages" blocks.
#
# Arguments:
#   $1 — full issue body text to scan
#   $2 — project root directory (lib/ and bin/ searched under here)
#
# Output: formatted usage blocks to stdout.  Empty string if no symbols found
# or none produce grep hits.  Never fails.
relevance_grep() {
  local issue_text="$1"
  local project_root="${2:-${RITE_PROJECT_ROOT:-$(pwd)}}"

  [ -z "$issue_text" ] && return 0

  # Directories to search — only descend into lib/ and bin/
  local search_dirs=()
  [ -d "${project_root}/lib" ] && search_dirs+=("${project_root}/lib")
  [ -d "${project_root}/bin" ] && search_dirs+=("${project_root}/bin")
  [ "${#search_dirs[@]}" -eq 0 ] && return 0

  local output=""

  # --- File paths ---
  local file_paths
  file_paths=$(_extract_file_paths "$issue_text" || true)

  local fpath
  while IFS= read -r fpath; do
    [ -z "$fpath" ] && continue

    local hits
    hits=$(_grep_symbol "$fpath" "${search_dirs[@]+"${search_dirs[@]}"}" || true)
    [ -z "$hits" ] && continue

    # Collect non-self-reference hits first so a block with only a
    # self-reference (#774/#776) emits no header at all.
    local kept=""
    local hit
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      if _is_self_reference "$fpath" "$hit"; then
        continue
      fi
      kept="${kept}  - ${hit}"$'\n'
    done <<< "$hits"

    [ -z "$kept" ] && continue
    output="${output}Existing usages of \`${fpath}\`:"$'\n'
    output="${output}${kept}"
    output="${output}"$'\n'
  done <<< "$file_paths"

  # --- Backtick symbols (function calls and env vars) ---
  local symbols
  symbols=$(_extract_backtick_symbols "$issue_text" || true)

  # Deduplicate symbols
  local deduped_symbols
  deduped_symbols=$(printf '%s\n' "$symbols" | sort -u || true)

  local sym
  while IFS= read -r sym; do
    [ -z "$sym" ] && continue

    local hits
    hits=$(_grep_symbol "$sym" "${search_dirs[@]+"${search_dirs[@]}"}" || true)
    [ -z "$hits" ] && continue

    output="${output}Existing usages of \`${sym}\`:"$'\n'
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      output="${output}  - ${hit}"$'\n'
    done <<< "$hits"
    output="${output}"$'\n'
  done <<< "$deduped_symbols"

  printf '%s' "$output"
}
