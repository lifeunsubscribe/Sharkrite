# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 16: Missing re-source guard in lib/utils/, lib/providers/, lib/core/ files
#
# Every file in lib/ that is a sourced library (not a standalone executable invoked
# via bash directly) MUST be idempotent on re-source. Without a guard, sourcing a
# file twice under set -euo pipefail can re-execute initialization code and crash
# (e.g., re-assigning readonly vars, re-running program logic, re-printing banners).
#
# Live bugs that resulted from missing or wrong guards:
#   #61: assess-documentation.sh — verbose_info undefined (missing dep source)
#   #69: issue-lock.sh — guard checked wrong variable
#   2267841: stash-manager.sh — readonly crash on re-source
#
# Accepted guard forms (any of these in the first 40 lines is sufficient):
#   - declare -f <fn_name> >/dev/null 2>&1 (canonical — function-based idempotency)
#   - return 0 2>/dev/null               (early-return idiom used with the above)
#   - _RITE_*_LOADED variable guard      (variable-based idempotency for executables)
#   - RITE_SOURCE_FUNCTIONS_ONLY         (test-mode guard for executables with body code)
#
# Files in bin/ and tools/ are excluded — they are run directly, never sourced.
echo "Checking for missing re-source guards in lib/ files..."
mapfile -t LIB_FILES < <(find "$PROJECT_ROOT/lib" -type f -name "*.sh" 2>/dev/null)

for file in "${LIB_FILES[@]}"; do
  # Check only the first 60 lines for the guard (guards must appear near the top;
  # 60 lines accommodates files with longer header comments like issue-lock.sh)
  head40=$(head -60 "$file" 2>/dev/null)

  # Accepted guard patterns:
  #   1. declare -f <name> >/dev/null 2>&1 (canonical function-based guard)
  #   2. return 0 2>/dev/null (idempotent return — used in guard bodies)
  #   3. _RITE_*_LOADED variable guard
  #   4. RITE_SOURCE_FUNCTIONS_ONLY (test-mode early-exit for executables)
  if echo "$head40" | grep -qE \
    'declare -f [a-z_]+ >/dev/null 2>&1|return 0 2>/dev/null|_RITE_[A-Z_]+_LOADED|RITE_SOURCE_FUNCTIONS_ONLY'; then
    continue
  fi

  # No guard found — flag as a violation
  print_violation "$file" "1" "MISSING_RESOURCE_GUARD" \
    "lib file has no re-source guard — add 'if declare -f <fn> >/dev/null 2>&1; then return 0 2>/dev/null || true; fi' near top"
done

