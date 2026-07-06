# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 17: Bare `readonly` declaration at top level in lib/ files
#
# `readonly VAR=value` at the top level of a sourced library file will crash
# with "readonly: VAR: is read-only" when the file is sourced a second time
# under `set -euo pipefail`. This is a silent killer: the script dies with
# no error output, making it extremely hard to diagnose.
#
# Safe alternatives:
#   1. Use a re-source guard (Rule 16) so the declaration never runs twice.
#      The guard alone is sufficient — the readonly line itself need not change.
#   2. Change to: VAR="${VAR:-default_value}"  (idempotent even without a guard)
#   3. Change to: declare -r VAR=value         (still crashes on re-source, but
#      at least the intent is explicit — only OK if a guard is present)
#
# This rule flags files that contain a bare top-level `readonly VAR=` line
# but do NOT have any of the accepted re-source guard patterns. Files that
# already have a guard (checked by Rule 16) are safe and are skipped here.
#
# Suppression: add a comment on the preceding line:
#   # sharkrite-lint disable UNGUARDED_READONLY - Reason: ...
echo "Checking for unguarded readonly declarations in lib/ files..."

for file in "${LIB_FILES[@]}"; do
  # Skip files with no readonly declarations at all (fast path)
  grep -q '^readonly ' "$file" 2>/dev/null || continue

  # Check if this file has an accepted re-source guard in the first 60 lines
  head60=$(head -60 "$file" 2>/dev/null)
  if echo "$head60" | grep -qE \
    'declare -f [a-z_]+ >/dev/null 2>&1|return 0 2>/dev/null|_RITE_[A-Z_]+_LOADED|RITE_SOURCE_FUNCTIONS_ONLY'; then
    # File has a guard — the readonly is protected, skip it
    continue
  fi

  # No guard present — check each `readonly` line (top-level only)
  while IFS=: read -r line_num line_content; do
    # Check for suppression comment on the preceding line
    preceding_line=""
    if [ "$line_num" -gt 1 ] 2>/dev/null; then
      preceding_line=$(sed -n "$((line_num - 1))p" "$file" 2>/dev/null || true)
    fi
    if echo "$preceding_line" | grep -q 'sharkrite-lint disable UNGUARDED_READONLY'; then
      continue
    fi

    print_violation "$file" "$line_num" "UNGUARDED_READONLY" \
      "bare 'readonly' declaration without a re-source guard — will crash with 'readonly: is read-only' on second source; add a guard or use VAR=\${VAR:-default}"
  done < <(grep -n '^readonly ' "$file" 2>/dev/null || true)
done

