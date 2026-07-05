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

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f parse_scope_boundary >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Load marker constants
_scope_checker_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_scope_checker_dir/markers.sh"

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

  # Find the Scope Boundary section — supports markdown headings (## Scope Boundary,
  # ## Scope Boundary:), bold (**Scope Boundary**, **Scope Boundary**:), and plain text.
  # Section ends at the next top-level heading or end of document.
  local scope_section
  scope_section=$(echo "$issue_body" | \
    awk '/^#+[[:space:]]*Scope Boundary[[:space:]]*:?[[:space:]]*$|^\*\*Scope Boundary\*\*[[:space:]]*:?[[:space:]]*$|^Scope Boundary:[[:space:]]*$/{found=1; next}
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
# _is_path_shaped PATTERN
#
# Returns 0 if PATTERN looks like a file/directory path or glob, 1 otherwise.
# A pattern is path-shaped when it:
#   - contains a forward slash (e.g. lib/core/foo.sh, lib/core/)
#   - ends with a recognised file extension (e.g. foo.sh, bar.bats)
#   - contains a glob metacharacter (* ? [)
# Plain prose phrases like "touch unrelated tests" are NOT path-shaped.
# ---------------------------------------------------------------------------
_is_path_shaped() {
  local pattern="$1"
  # Contains a slash → directory or full path
  if [[ "$pattern" == */* ]]; then return 0; fi
  # Ends with a common file extension
  if [[ "$pattern" =~ \.[a-zA-Z0-9]{1,6}$ ]]; then return 0; fi
  # Contains a glob metacharacter
  if [[ "$pattern" == *'*'* ]] || [[ "$pattern" == *'?'* ]] || [[ "$pattern" == *'['* ]]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _is_test_path FILE
#
# Returns 0 if FILE looks like a test file that should be implicitly allowed
# during scope-boundary checks.  Authoring tests is an expected part of Phase 4
# (Test Authoring & Syntax Check), so test files written alongside a source
# change must not generate false-positive scope warnings.
#
# Matched patterns (case-insensitive, after lowercasing):
#   tests/...          — any file under a top-level or nested tests/ directory
#   test_*.*           — test-prefixed files (test_fetch.ino, test_util.py)
#   *_test.*           — test-suffixed files (foo_test.go, bar_test.py)
#   *.test.*           — test mid-extension files (foo.test.sh, bar.test.ts)
#   *test*/*.ino       — .ino files inside any directory whose name contains "test"
#
# NOTE: This whitelist applies ONLY to the "file must match a DO bullet" check.
# Explicit DO NOT bullets still override it — if an issue says
# "DO NOT: tests/regression/secret.bats", that file is still flagged even if
# it matches a test-path pattern.
# ---------------------------------------------------------------------------
_is_test_path() {
  local file="$1"
  local _f
  _f=$(echo "$file" | tr '[:upper:]' '[:lower:]' | sed 's|^\./||' || true)

  # tests/ directory prefix (e.g. tests/regression/foo.bats)
  if [[ "$_f" == tests/* ]]; then return 0; fi
  # Nested tests/ directory anywhere in the path (e.g. src/tests/foo.sh)
  if [[ "$_f" == */tests/* ]]; then return 0; fi

  # Extract just the filename (last component after final /)
  local _basename="${_f##*/}"

  # test_*.* — test-prefixed files (test_fetch.ino, test_util.py)
  if [[ "$_basename" == test_*.* ]]; then return 0; fi

  # *_test.* — test-suffixed files (foo_test.go, bar_test.py)
  if [[ "$_basename" == *_test.* ]]; then return 0; fi

  # *.test.* — test mid-extension (foo.test.sh, bar.test.ts)
  if [[ "$_basename" == *.test.* ]]; then return 0; fi

  # *test*/*.ino — .ino files inside a directory whose name contains "test"
  # Extract the parent directory name (second-to-last component)
  local _dir="${_f%/*}"
  local _dirname="${_dir##*/}"
  if [[ "$_dirname" == *test* ]] && [[ "$_basename" == *.ino ]]; then return 0; fi

  return 1
}

# ---------------------------------------------------------------------------
# _file_matches_pattern FILE PATTERN
#
# Returns 0 if FILE (lowercased) starts with or equals PATTERN (lowercased).
# PATTERN may be:
#   - an exact file path   (lib/core/foo.sh)
#   - a directory prefix   (lib/core/ or lib/core)
#   - a wildcard glob      (lib/core/*.sh)  — matched via bash glob, only
#     when the pattern is path-shaped (guards against glob injection from
#     arbitrary prose in issue text)
#
# Non-path-shaped patterns (prose phrases) are never matched here; callers
# that want prose substring matching must handle that separately.
# ---------------------------------------------------------------------------
_file_matches_pattern() {
  local file="$1"
  local pattern="$2"

  file=$(echo "$file" | tr '[:upper:]' '[:lower:]' | sed 's|^\./||' || true)
  pattern=$(echo "$pattern" | tr '[:upper:]' '[:lower:]' | sed 's|^\./||' || true)

  # Skip non-path-shaped patterns — they have no meaning as path matchers
  if ! _is_path_shaped "$pattern"; then return 1; fi

  # Strip trailing slash from pattern for prefix comparison
  local pattern_no_slash="${pattern%/}"

  # Exact match
  if [ "$file" = "$pattern" ]; then return 0; fi

  # Prefix match (file is inside a directory the pattern names)
  if [[ "$file" == "${pattern_no_slash}"/* ]] || [[ "$file" == "${pattern_no_slash}" ]]; then
    return 0
  fi

  # Glob match via bash — only reached for path-shaped patterns (guards against
  # glob injection from arbitrary issue prose). Unquoted $pattern is intentional
  # so [[ == ]] performs glob matching, not literal comparison.
  # shellcheck disable=SC2254,SC2053
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

  # Collect changed files vs origin/main (or all staged/modified if no origin/main).
  # Use --name-status to capture per-file status codes (A=added, D=deleted, M=modified,
  # R=renamed, etc.) so the test-path whitelist can be restricted to added files only.
  local _changed_files=()
  # _added_files_set is a newline-separated list of paths that are newly added (A status).
  # Only added test files are implicitly whitelisted; deleted/modified test files are not.
  local _added_files_set=""
  local _git_diff_status
  if git -C "$worktree_path" rev-parse --verify origin/main >/dev/null 2>&1; then
    _git_diff_status=$(git -C "$worktree_path" diff --name-status origin/main...HEAD 2>/dev/null || true)
  else
    _git_diff_status=$(git -C "$worktree_path" diff --name-status HEAD 2>/dev/null || true)
  fi

  # Parse name-status output: each line is "<STATUS>\t<path>" (or for renames:
  # "R<score>\t<old>\t<new>").  Extract the file path and record added files.
  while IFS=$'\t' read -r _status _path1 _path2; do
    [ -z "$_status" ] && continue
    # For renames the "new" name is in _path2; for everything else it is in _path1.
    local _fpath
    case "$_status" in
      R*) _fpath="${_path2:-}" ;;
      *)  _fpath="${_path1:-}" ;;
    esac
    [ -z "$_fpath" ] && continue
    _changed_files+=("$_fpath")
    # Track added files for the test-path whitelist
    case "$_status" in
      A*) _added_files_set="${_added_files_set}${_fpath}"$'\n' ;;
    esac
  done <<< "$_git_diff_status"

  # Also include uncommitted changes (files staged or modified but not yet committed).
  # git status --porcelain format: "XY path" where X=index status, Y=worktree status.
  local _uncommitted_status
  _uncommitted_status=$(git -C "$worktree_path" status --porcelain 2>/dev/null | \
    grep -v '^??' || true)
  while IFS= read -r _pline; do
    [ -z "$_pline" ] && continue
    # First two chars are status codes; rest (after the space at col 3) is path.
    # Rename format: "R  old -> new" — take the name after " -> ".
    local _xy="${_pline:0:2}"
    local _pfile="${_pline:3}"
    # Handle rename format: "old -> new"
    if [[ "$_pfile" == *" -> "* ]]; then
      _pfile="${_pfile##* -> }"
    fi
    [ -z "$_pfile" ] && continue
    _changed_files+=("$_pfile")
    # Track staged additions for the whitelist (index status is first char)
    local _idx_status="${_xy:0:1}"
    case "$_idx_status" in
      A) _added_files_set="${_added_files_set}${_pfile}"$'\n' ;;
    esac
  done <<< "$_uncommitted_status"

  # Deduplicate _changed_files while preserving order (bash 3.2-compatible loop).
  local _seen=""
  local _deduped_files=()
  for _f in "${_changed_files[@]+"${_changed_files[@]}"}"; do
    [ -z "$_f" ] && continue
    if [[ "$_seen" != *$'\n'"${_f}"$'\n'* ]]; then
      _seen="${_seen}"$'\n'"${_f}"$'\n'
      _deduped_files+=("$_f")
    fi
  done
  _changed_files=("${_deduped_files[@]+"${_deduped_files[@]}"}")

  if [ "${#_changed_files[@]}" -eq 0 ]; then
    return 0
  fi

  # Evaluate each changed file against patterns
  local _violations=()
  for _file in "${_changed_files[@]}"; do
    local _file_norm
    _file_norm=$(echo "$_file" | tr '[:upper:]' '[:lower:]' | sed 's|^\./||' || true)

    # Check DO NOT patterns first (explicit exclusion wins).
    # +idiom REQUIRED: this file is #!/bin/bash (bash 3.2 on macOS), where a
    # bare [@] expansion of an empty array crashes under set -u — a Scope
    # Boundary with a DO: line but no DO NOT: line leaves _donot_patterns
    # empty. (An earlier comment here wrongly assumed bash-4 empty-array
    # semantics.)
    #
    # Two matching strategies:
    #   - Path-shaped patterns  → use _file_matches_pattern (prefix/glob)
    #   - Prose patterns        → substring match: the file path contains a
    #     word from the prose phrase (e.g. "touch unrelated tests" matches
    #     any file whose path contains "unrelated" or "tests")
    local _donot_match=false
    for _pat in "${_donot_patterns[@]+"${_donot_patterns[@]}"}"; do
      [ -z "${_pat:-}" ] && continue
      if _is_path_shaped "$_pat"; then
        # Path-shaped: use standard prefix/glob matching
        if _file_matches_pattern "$_file_norm" "$_pat"; then
          _donot_match=true
          break
        fi
      else
        # Prose phrase: check whether any significant word in the phrase
        # appears as a substring of the file path (case-insensitive, already
        # lowercased).  Skip stop-words (do, not, the, a, an, touch, any).
        local _prose_pat_lower
        _prose_pat_lower=$(echo "$_pat" | tr '[:upper:]' '[:lower:]')
        local _word
        for _word in $_prose_pat_lower; do
          # Skip common stop-words that would over-match.
          # "tests" is excluded because it matches every file under tests/
          # when the intent is to exclude a specific class of tests (e.g.
          # "unrelated tests").  More specific words like "unrelated" still
          # fire as intended.
          case "$_word" in
            do|not|the|a|an|touch|any|to|in|of|and|or|with|for|all|tests|test|files|file|changes|code) continue ;;
          esac
          if [[ "$_file_norm" == *"$_word"* ]]; then
            _donot_match=true
            break
          fi
        done
        [ "$_donot_match" = true ] && break
      fi
    done

    if [ "$_donot_match" = true ]; then
      _violations+=("$_file")
      continue
    fi

    # If DO patterns exist, the file must match at least one — UNLESS it is a
    # newly-added test file.  Authoring tests is expected Phase 4 behaviour;
    # test files ADDED alongside a source change should not produce false-positive
    # scope warnings simply because the issue's DO bullets list only source paths.
    #
    # CRITICAL: the whitelist applies ONLY to added (A-status) paths.  Deleted or
    # modified test files must still be evaluated — deleting an unrelated test is
    # exactly the bug class this subsystem was built to catch (issue #49/PR #121).
    # Restricting to added paths prevents the whitelist from silently allowing
    # deletions of test files that were never meant to be touched.
    #
    # Explicit DO NOT bullets still win (checked above) — the test-path whitelist
    # only suppresses the "not covered by any DO bullet" violation for new tests.
    if [ "${#_do_patterns[@]}" -gt 0 ]; then
      # Silently allow recognised test paths that are ADDED (not deleted/modified).
      if _is_test_path "$_file_norm" && \
         [[ "$_added_files_set" == *$'\n'"${_file}"$'\n'* || \
            "$_added_files_set" == "${_file}"$'\n'* ]]; then
        continue
      fi

      # A DO bullet may contain prose mixed with paths (e.g. "tweak the regex
      # in lib/core/foo.sh").  When the full bullet text contains spaces, split
      # it on whitespace and test only the path-shaped tokens — this prevents
      # prose words from being used as path prefixes (which would never match)
      # and ensures real path mentions inside prose DO bullets are honoured.
      local _do_match=false
      # +idiom: a Scope Boundary with DO NOT: but no DO: leaves _do_patterns
      # empty — bare [@] crashes bash 3.2 under set -u (sibling of the
      # _donot_patterns fix above).
      for _pat in "${_do_patterns[@]+"${_do_patterns[@]}"}"; do
        [ -z "$_pat" ] && continue
        if [[ "$_pat" == *" "* ]]; then
          # Prose bullet: try each whitespace-separated token that is path-shaped
          local _token
          for _token in $_pat; do
            if _is_path_shaped "$_token" && _file_matches_pattern "$_file_norm" "$_token"; then
              _do_match=true
              break
            fi
          done
          [ "$_do_match" = true ] && break
        else
          if _file_matches_pattern "$_file_norm" "$_pat"; then
            _do_match=true
            break
          fi
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
# scope_boundary_is_enforceable ISSUE_BODY
#
# Returns 0 (enforceable) when:
#   - the body has no Scope Boundary section (no DO patterns to enforce), OR
#   - at least one DO bullet contains a path-shaped token (file path, dir
#     prefix, or glob).
#
# Returns 1 (NOT enforceable) only when DO bullets exist but every one of them
# is pure prose. In that case check_scope_boundary would flag every changed
# file as a violation (no path can match a prose-only DO), so the caller
# should skip the check and log a diag line instead of emitting noise.
# ---------------------------------------------------------------------------
scope_boundary_is_enforceable() {
  local issue_body="${1:-}"

  if [ -z "$issue_body" ] || [ "$issue_body" = "null" ]; then
    return 0
  fi

  local _parsed
  _parsed=$(parse_scope_boundary "$issue_body")

  local _do_patterns=()
  local _in_do=false
  while IFS= read -r _line; do
    if [ "$_line" = "DO_PATTERNS_START" ]; then _in_do=true; continue; fi
    if [ "$_line" = "DO_PATTERNS_END" ];   then _in_do=false; continue; fi
    if [ "$_in_do" = true ] && [ -n "$_line" ]; then
      _do_patterns+=("$_line")
    fi
  done <<< "$_parsed"

  # No DO patterns parsed — check_scope_boundary handles this case (returns 0
  # silently). Treat as enforceable so we don't short-circuit the no-scope path.
  if [ "${#_do_patterns[@]}" -eq 0 ]; then
    return 0
  fi

  local _pat _token
  for _pat in "${_do_patterns[@]}"; do
    [ -z "$_pat" ] && continue
    if [[ "$_pat" == *" "* ]]; then
      for _token in $_pat; do
        if _is_path_shaped "$_token"; then return 0; fi
      done
    else
      if _is_path_shaped "$_pat"; then return 0; fi
    fi
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

  # Extract file list (strip "VIOLATION: " prefix) and format as backtick bullets.
  # Pre-build the list before the heredoc to avoid awk expansion inside heredoc body.
  local _files _bullet_list
  _files=$(echo "$violations_text" | grep "^VIOLATION:" | sed 's/^VIOLATION: //' || true)
  _bullet_list=$(echo "$_files" | awk '{print "- `" $0 "`"}' || true)

  # sharkrite-lint disable UNQUOTED_HEREDOC - variables must expand inside warning body
  cat <<EOF

---

<!-- ${RITE_MARKER_SCOPE_WARNING} -->
## ⚠️ Scope Boundary Warning

This PR modifies **${_count}** file(s) that may be outside the issue's declared scope:

${_bullet_list}

The issue's **Scope Boundary** section lists allowed changes. These files were either
explicitly listed under **DO NOT** or not covered by any **DO** bullet.

**Action required:** Review these files before merging. If the scope expansion is
intentional, no action needed — this warning is informational only.

EOF
}
