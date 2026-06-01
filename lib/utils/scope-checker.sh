#!/bin/bash
# lib/utils/scope-checker.sh — Scope boundary enforcement for dev sessions
#
# Parses the "Scope Boundary" section of a GitHub issue body and compares
# it against the files changed in the current worktree.  Called after a
# Claude dev session completes (but before the commit is created) to surface
# scope violations before they silently land in a PR.
#
# Design notes:
#   - DO bullets define the allowed set.  A changed file is "in-scope" when
#     it prefix-matches at least one DO pattern (path prefix or exact file).
#   - DO NOT bullets define explicit exclusions.  A file matching a DO NOT
#     pattern is flagged even if it also matches a DO bullet.
#   - When no Scope Boundary section exists the function returns 0 (no
#     violations) so repos that don't use the section are unaffected.
#   - The check is advisory: callers decide whether to block, warn, or prompt.

set -euo pipefail

# ---------------------------------------------------------------------------
# parse_scope_boundary ISSUE_BODY
#
# Prints two sections to stdout, each terminated by a sentinel line:
#   DO_PATTERNS_START
#   <pattern>
#   ...
#   DO_PATTERNS_END
#   DONOT_PATTERNS_START
#   <pattern>
#   ...
#   DONOT_PATTERNS_END
#
# Patterns are lowercased path prefixes extracted from the bullet text.
# Example issue body bullet:  "- DO: lib/core/foo.sh"  → "lib/core/foo.sh"
# Example: "- DO: lib/core/"  → "lib/core/"
# ---------------------------------------------------------------------------
parse_scope_boundary() {
  local issue_body="$1"

  # Find the Scope Boundary section — supports both markdown bold and plain text.
  # Section ends at the next top-level heading or end of document.
  local scope_section
  scope_section=$(echo "$issue_body" | \
    awk '/^\*\*Scope Boundary\*\*|^Scope Boundary:/{found=1; next}
         found && /^(##|---|\*\*[A-Z])/{found=0}
         found{print}' || true)

  echo "DO_PATTERNS_START"
  # Extract DO bullets (but not DO NOT).
  # Use BSD-compatible sed (no /i flag — use explicit character class ranges instead).
  echo "$scope_section" | grep -iE '^\s*[-*]\s*DO:' | \
    grep -ivE 'DO[[:space:]]*NOT' | \
    sed 's/^[[:space:]]*[-*][[:space:]]*[Dd][Oo]:[[:space:]]*//' | \
    sed 's/[[:space:]]*#.*//' | \
    sed 's/[[:space:]]*$//' | \
    tr '[:upper:]' '[:lower:]' | \
    grep -v '^$' || true
  echo "DO_PATTERNS_END"

  echo "DONOT_PATTERNS_START"
  # Extract DO NOT bullets.
  echo "$scope_section" | grep -iE '^\s*[-*]\s*DO[[:space:]]*NOT:' | \
    sed 's/^[[:space:]]*[-*][[:space:]]*[Dd][Oo][[:space:]]*[Nn][Oo][Tt]:[[:space:]]*//' | \
    sed 's/[[:space:]]*#.*//' | \
    sed 's/[[:space:]]*$//' | \
    tr '[:upper:]' '[:lower:]' | \
    grep -v '^$' || true
  echo "DONOT_PATTERNS_END"
}

# ---------------------------------------------------------------------------
# _file_matches_pattern FILE PATTERN
#
# Returns 0 if FILE (lowercased) starts with or equals PATTERN (lowercased).
# PATTERN may be:
#   - an exact file path   (lib/core/foo.sh)
#   - a directory prefix   (lib/core/ or lib/core)
#   - a wildcard glob      (lib/core/*.sh)  — matched via bash glob
# ---------------------------------------------------------------------------
_file_matches_pattern() {
  local file="$1"
  local pattern="$2"

  file=$(echo "$file" | tr '[:upper:]' '[:lower:]' | sed 's|^\./||')
  pattern=$(echo "$pattern" | tr '[:upper:]' '[:lower:]' | sed 's|^\./||')

  # Strip trailing slash from pattern for prefix comparison
  local pattern_no_slash="${pattern%/}"

  # Exact match
  if [ "$file" = "$pattern" ]; then return 0; fi

  # Prefix match (file is inside a directory the pattern names)
  if [[ "$file" == "${pattern_no_slash}"/* ]] || [[ "$file" == "${pattern_no_slash}" ]]; then
    return 0
  fi

  # Glob match via bash
  # shellcheck disable=SC2254
  if [[ "$file" == $pattern ]]; then return 0; fi

  return 1
}

# ---------------------------------------------------------------------------
# check_scope_boundary ISSUE_BODY [WORKTREE_PATH]
#
# Compares changed files in the current git worktree against the DO/DO NOT
# patterns parsed from ISSUE_BODY.
#
# Outputs violations to stdout (one file per line, prefixed with "VIOLATION: ").
# Also outputs info/warning lines to stderr.
#
# Returns:
#   0 — no violations (or no Scope Boundary section found)
#   1 — one or more violations detected
# ---------------------------------------------------------------------------
check_scope_boundary() {
  local issue_body="${1:-}"
  local worktree_path="${2:-$(pwd)}"

  # No issue body → nothing to check
  if [ -z "$issue_body" ] || [ "$issue_body" = "null" ]; then
    return 0
  fi

  # Parse scope boundary section
  local _parsed
  _parsed=$(parse_scope_boundary "$issue_body")

  # Extract DO patterns
  local _do_patterns=()
  local _in_do=false
  while IFS= read -r _line; do
    if [ "$_line" = "DO_PATTERNS_START" ]; then _in_do=true; continue; fi
    if [ "$_line" = "DO_PATTERNS_END" ];   then _in_do=false; continue; fi
    if [ "$_in_do" = true ] && [ -n "$_line" ]; then
      _do_patterns+=("$_line")
    fi
  done <<< "$_parsed"

  # Extract DO NOT patterns
  local _donot_patterns=()
  local _in_donot=false
  while IFS= read -r _line; do
    if [ "$_line" = "DONOT_PATTERNS_START" ]; then _in_donot=true; continue; fi
    if [ "$_line" = "DONOT_PATTERNS_END" ];   then _in_donot=false; continue; fi
    if [ "$_in_donot" = true ] && [ -n "$_line" ]; then
      _donot_patterns+=("$_line")
    fi
  done <<< "$_parsed"

  # If no patterns found at all, no Scope Boundary section is present → skip
  if [ "${#_do_patterns[@]}" -eq 0 ] && [ "${#_donot_patterns[@]}" -eq 0 ]; then
    return 0
  fi

  # Collect changed files vs origin/main (or all staged/modified if no origin/main)
  local _changed_files=()
  local _git_diff_files
  if git -C "$worktree_path" rev-parse --verify origin/main >/dev/null 2>&1; then
    _git_diff_files=$(git -C "$worktree_path" diff --name-only origin/main...HEAD 2>/dev/null || true)
  else
    _git_diff_files=$(git -C "$worktree_path" diff --name-only HEAD 2>/dev/null || true)
  fi

  # Also include uncommitted changes (files staged or modified but not yet committed)
  local _uncommitted
  _uncommitted=$(git -C "$worktree_path" status --porcelain 2>/dev/null | \
    grep -v '^??' | sed 's/^...//' | sed 's/ -> .*//' || true)

  # Merge and deduplicate
  local _all_files_raw
  _all_files_raw=$(printf '%s\n%s\n' "$_git_diff_files" "$_uncommitted" | \
    grep -v '^$' | sort -u || true)

  while IFS= read -r _f; do
    [ -n "$_f" ] && _changed_files+=("$_f")
  done <<< "$_all_files_raw"

  if [ "${#_changed_files[@]}" -eq 0 ]; then
    return 0
  fi

  # Evaluate each changed file against patterns
  local _violations=()
  for _file in "${_changed_files[@]}"; do
    local _file_norm
    _file_norm=$(echo "$_file" | tr '[:upper:]' '[:lower:]' | sed 's|^\./||')

    # Check DO NOT patterns first (explicit exclusion wins).
    # _donot_patterns is always declared with local _donot_patterns=() so the
    # array expansion is safe even when empty (bash 4+ empty array behaviour).
    local _donot_match=false
    for _pat in "${_donot_patterns[@]}"; do
      [ -z "${_pat:-}" ] && continue
      if _file_matches_pattern "$_file_norm" "$_pat"; then
        _donot_match=true
        break
      fi
    done

    if [ "$_donot_match" = true ]; then
      _violations+=("$_file")
      continue
    fi

    # If DO patterns exist, the file must match at least one
    if [ "${#_do_patterns[@]}" -gt 0 ]; then
      local _do_match=false
      for _pat in "${_do_patterns[@]}"; do
        [ -z "$_pat" ] && continue
        if _file_matches_pattern "$_file_norm" "$_pat"; then
          _do_match=true
          break
        fi
      done
      if [ "$_do_match" = false ]; then
        _violations+=("$_file")
      fi
    fi
  done

  if [ "${#_violations[@]}" -eq 0 ]; then
    return 0
  fi

  # Output violations
  for _v in "${_violations[@]}"; do
    echo "VIOLATION: $_v"
  done

  return 1
}

# ---------------------------------------------------------------------------
# format_scope_warning VIOLATIONS_TEXT
#
# Formats a human-readable scope violation warning for PR body insertion.
# VIOLATIONS_TEXT is the multi-line output from check_scope_boundary.
# ---------------------------------------------------------------------------
format_scope_warning() {
  local violations_text="$1"

  # Count violations
  local _count
  _count=$(echo "$violations_text" | grep -c "^VIOLATION:" || true)

  # Extract file list (strip "VIOLATION: " prefix)
  local _files
  _files=$(echo "$violations_text" | grep "^VIOLATION:" | sed 's/^VIOLATION: //' || true)

  cat <<EOF

---

## ⚠️ Scope Boundary Warning

This PR modifies **${_count}** file(s) that may be outside the issue's declared scope:

$(echo "$_files" | awk '{print "- `" $0 "`"}')

The issue's **Scope Boundary** section lists allowed changes. These files were either
explicitly listed under **DO NOT** or not covered by any **DO** bullet.

**Action required:** Review these files before merging. If the scope expansion is
intentional, no action needed — this warning is informational only.

EOF
}
