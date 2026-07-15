# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 19: Raw sharkrite-* marker literals in shell source files
#
# All sharkrite-* marker strings must be referenced via the RITE_MARKER_*
# constants defined in lib/utils/markers.sh. Hard-coded literals scattered
# across files make future renames error-prone and inconsistent.
#
# Allowlist (files where literal marker strings are required or expected):
#   - lib/utils/markers.sh        — the canonical source-of-truth definitions
#   - lib/utils/drift-log.sh      — format-implementing library for RITE_MARKER_DOC_DRIFT;
#                                   holds a fallback literal for standalone-source safety
#                                   (markers.sh may not be loaded in test subshells)
#   - tests/                      — bats tests may grep for/assert on marker strings
#   - tools/sharkrite-lint.sh     — this file; rule definitions contain the pattern
#
# Comment lines (lines where # precedes the marker) are skipped: inline
# documentation and sharkrite-lint disable comments are not functional code.
#
# The grep in jq filter strings that already use $RITE_MARKER_* would not
# produce literal "sharkrite-" strings; this rule catches places that still
# have the string baked in as a literal.
echo "Checking for raw sharkrite-* marker literals (use RITE_MARKER_* constants)..."

for file in "${SHELL_FILES[@]}"; do
  # Allowlist: markers.sh (definitions), drift-log.sh (format owner with fallback
  # literal for standalone-source safety), and this lint file.
  if [[ "$file" == */lib/utils/markers.sh ]] || \
     [[ "$file" == */lib/utils/drift-log.sh ]] || \
     [[ "$file" == */tools/sharkrite-lint.sh ]]; then
    continue
  fi

  while IFS=: read -r line_num line_content; do
    # Skip full-line comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Skip inline comments: if "sharkrite-" appears only after a # on the same line
    # (i.e., the non-comment portion does not contain sharkrite-), skip it.
    # Strip everything from the first # (that is not inside a string) — heuristic:
    # remove from unquoted # onwards and check if sharkrite- is still present.
    _code_part=$(echo "$line_content" | sed 's/#.*//' || true)
    if ! echo "$_code_part" | grep -qE 'sharkrite-[a-z]'; then
      continue
    fi
    # Code portion still has a literal — flag it
    print_violation "$file" "$line_num" "RAW_MARKER_LITERAL" \
      "literal 'sharkrite-*' marker string — use the RITE_MARKER_* constant from lib/utils/markers.sh instead"
  done < <(grep -n 'sharkrite-[a-z]' "$file" 2>/dev/null || true)
done

