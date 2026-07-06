# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 18: Unbalanced or duplicated sharkrite-extract marker pairs
#
# sharkrite-extract markers delimit code blocks for sed range extraction in
# regression tests (pattern: `# sharkrite-extract: <name>-start` / `<name>-end`).
# Two failure modes exist that sed's /start/,/end/p silently mishandles:
#
#   1. Missing marker: sed finds no range boundaries → empty output. Any
#      downstream [ -n "$VAR" ] guard or content-anchor check will fail, but
#      the failure message says nothing about the root cause (marker removal).
#
#   2. Duplicate marker: sed opens the range at the first start marker and
#      closes at the first matching end marker, including everything between
#      multiple loop copies. The extracted code is over-broad and wrong, but
#      the non-empty and content-anchor checks still pass — a silent mis-extraction.
#
# This rule requires exactly-one-of-each: one start and one end per unique
# marker name, with start appearing before end. Non-1 counts are violations.
#
# Scope: source files only (bin/, lib/, tools/) — test files (tests/) are
# intentionally excluded because regression tests legitimately reference marker
# names inside grep patterns and heredoc fixture scripts to validate the
# extraction behavior. Scanning tests/ would produce false positives on those
# intentional multi-occurrence strings. The bats codebase-sweep test in
# tests/regression/marker-sed-extraction-validation.bats independently verifies
# all real source-file markers are balanced.
#
# File list: reuses SHELL_FILES (built above) — same find flags (-L), same
# exclusions (test-fixtures-temp*, sharkrite-lint.sh), and already includes
# any RITE_LINT_EXTRA_DIRS entries. No separate find block needed.
echo "Checking for unbalanced or duplicated sharkrite-extract marker pairs..."

if [ "${#SHELL_FILES[@]}" -eq 0 ]; then
  print_warning "tools/sharkrite-lint.sh" "0" "UNBALANCED_EXTRACT_MARKERS" \
    "Rule 18 found no source files to scan — check that bin/, lib/, and tools/ exist under PROJECT_ROOT ($PROJECT_ROOT)"
fi

# Collect all start markers across all files, then verify each has exactly one
# matching end marker in the same file. Use awk to extract (file, marker_name)
# pairs efficiently.
# Guard against empty array explicitly: grep with an empty argument list reads
# from stdin, which would block indefinitely under automation.
# AWK outputs tab-separated "file\tlinenum\tcontent" so that paths containing
# colons (e.g. CI matrix job paths like /home/runner/work/my:project/file.sh)
# parse correctly — colon-based field splitting breaks on such paths.
_r18_starts=""
_r18_ends=""
if [ "${#SHELL_FILES[@]}" -gt 0 ]; then
  _r18_starts=$(awk '/# sharkrite-extract: .*-start/ { print FILENAME "\t" FNR "\t" $0 }' \
    "${SHELL_FILES[@]}" 2>/dev/null || true)
  _r18_ends=$(awk '/# sharkrite-extract: .*-end/ { print FILENAME "\t" FNR "\t" $0 }' \
    "${SHELL_FILES[@]}" 2>/dev/null || true)
fi

# Collect unique (file, marker_name) pairs from start markers.
# For each, verify the count in that file is exactly 1 for both start and end.
declare -A _seen_pairs
while IFS= read -r _hit; do
  [ -z "$_hit" ] && continue
  # Format: file<TAB>linenum<TAB>  # sharkrite-extract: <name>-start
  # Tab-separated: safe for paths containing colons
  _hit_file=$(echo "$_hit" | cut -f1)
  _hit_line=$(echo "$_hit" | cut -f2)
  _hit_name=$(echo "$_hit" | grep -oE 'sharkrite-extract: [a-z0-9_-]+-start' | sed 's/-start$//' | sed 's/sharkrite-extract: //' || true)
  [ -z "$_hit_name" ] && continue

  _pair_key="${_hit_file}::${_hit_name}"
  # Only process each (file, name) pair once
  [ "${_seen_pairs[$_pair_key]+set}" = "set" ] && continue
  _seen_pairs[$_pair_key]=1

  # Count start occurrences in this file
  _start_count=$(grep -c "# sharkrite-extract: ${_hit_name}-start" "$_hit_file" 2>/dev/null || true)
  # Count end occurrences in this file
  _end_count=$(grep -c "# sharkrite-extract: ${_hit_name}-end" "$_hit_file" 2>/dev/null || true)

  if [ "$_start_count" -ne 1 ]; then
    print_violation "$_hit_file" "$_hit_line" "UNBALANCED_EXTRACT_MARKERS" \
      "sharkrite-extract marker '${_hit_name}-start' appears ${_start_count} times (expected 1) — sed range extraction will mis-extract or yield empty output"
  fi
  if [ "$_end_count" -ne 1 ]; then
    print_violation "$_hit_file" "$_hit_line" "UNBALANCED_EXTRACT_MARKERS" \
      "sharkrite-extract marker '${_hit_name}-end' appears ${_end_count} times (expected 1) — sed range extraction will mis-extract or yield empty output"
  fi

  # Verify start appears before end (line ordering)
  if [ "$_start_count" -eq 1 ] && [ "$_end_count" -eq 1 ]; then
    _start_line=$(grep -n "# sharkrite-extract: ${_hit_name}-start" "$_hit_file" 2>/dev/null | cut -d: -f1 || true)
    _end_line=$(grep -n "# sharkrite-extract: ${_hit_name}-end" "$_hit_file" 2>/dev/null | cut -d: -f1 || true)
    if [ -n "$_start_line" ] && [ -n "$_end_line" ] && [ "$_start_line" -ge "$_end_line" ]; then
      print_violation "$_hit_file" "$_start_line" "UNBALANCED_EXTRACT_MARKERS" \
        "sharkrite-extract marker '${_hit_name}-start' (line ${_start_line}) does not precede '${_hit_name}-end' (line ${_end_line}) — sed range extraction will yield empty output"
    fi
  fi
done <<< "$_r18_starts"

# Also flag end markers that have no corresponding start in the same file.
# No (file, name) deduplication here: each occurrence of an orphaned end marker
# is its own violation. If two end markers share a name but no start exists, both
# lines must be reported individually. Pairs already processed by the start-marker
# loop above (i.e., where a start exists) are still skipped via _seen_pairs to
# avoid double-reporting the same (file, name) problem.
while IFS= read -r _hit; do
  [ -z "$_hit" ] && continue
  # Tab-separated: file<TAB>linenum<TAB>content — safe for paths containing colons
  _hit_file=$(echo "$_hit" | cut -f1)
  _hit_line=$(echo "$_hit" | cut -f2)
  _hit_name=$(echo "$_hit" | grep -oE 'sharkrite-extract: [a-z0-9_-]+-end' | sed 's/-end$//' | sed 's/sharkrite-extract: //' || true)
  [ -z "$_hit_name" ] && continue

  _pair_key="${_hit_file}::${_hit_name}"

  # If this (file, name) pair was already processed via starts, skip it.
  # The start-marker loop already reported the imbalance (e.g. end count != 1).
  [ "${_seen_pairs[$_pair_key]+set}" = "set" ] && continue

  # End marker exists but no start marker — orphaned end.
  # Report each occurrence individually: two orphaned ends = two violations.
  _start_count=$(grep -c "# sharkrite-extract: ${_hit_name}-start" "$_hit_file" 2>/dev/null || true)
  if [ "$_start_count" -eq 0 ]; then
    print_violation "$_hit_file" "$_hit_line" "UNBALANCED_EXTRACT_MARKERS" \
      "sharkrite-extract marker '${_hit_name}-end' has no matching '${_hit_name}-start' in the same file — sed range extraction will yield empty output"
  fi
done <<< "$_r18_ends"

