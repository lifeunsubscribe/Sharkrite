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
# See: docs/architecture/tag-index-system.md → "Codebase Grep (hardening layer)"

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f relevance_grep >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# =============================================================================
# Internal helpers
# =============================================================================

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
    results=$(grep -rnF "$symbol" "${dirs[@]}" 2>/dev/null \
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
    hits=$(_grep_symbol "$fpath" "${search_dirs[@]}" || true)
    [ -z "$hits" ] && continue

    output="${output}Existing usages of \`${fpath}\`:"$'\n'
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      output="${output}  - ${hit}"$'\n'
    done <<< "$hits"
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
    hits=$(_grep_symbol "$sym" "${search_dirs[@]}" || true)
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
