# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 22: function-sentinel re-source guard combined with `export -f` (subprocess-stale trap)
#
# When a lib file `export -f`s any function AND guards its top with
# `if declare -f <fn> >/dev/null 2>&1; then return 0; fi`, a subprocess of a
# parent that already sourced an OLDER version of the file inherits the parent's
# exported function set. The function-sentinel guard sees the inherited stale
# function, short-circuits, and never redefines anything — including functions
# added to the file after the parent started. Functions added mid-batch then
# appear undefined in the subprocess despite existing on disk.
#
# Live failure (2026-06-04): PR #350 added detect_lib_shrinkage to
# blocker-rules.sh and merged mid-batch. Subsequent issues exec'd create-pr.sh
# as subprocesses; create-pr.sh called detect_lib_shrinkage; subprocess inherited
# stale exports from batch-process-issues.sh's earlier source; function-sentinel
# guard fired; "detect_lib_shrinkage: command not found" → whole batch failed in
# PR phase. See: tests/regression/blocker-rules-stale-inherited-functions.bats
# and blocker-rules.sh:18-37 for the canonical fix.
#
# Fix: switch the guard to a variable sentinel that is NOT exported, so true
# subprocesses see it unset and re-source against the current on-disk file:
#
#   if [ "${_RITE_<NAME>_LOADED:-}" = "true" ]; then
#     return 0 2>/dev/null || true
#   fi
#   _RITE_<NAME>_LOADED=true   # NO `export` — that defeats the whole point
echo "Checking for function-sentinel guard + export -f combo (subprocess-stale trap)..."

for file in "${SHELL_FILES[@]}"; do
  # Trigger condition: file `export -f`s at least one function at top level.
  # No need to path-filter to lib/ — bin/ and tools/ scripts don't `export -f`
  # in practice, so the trigger condition is the natural filter, and it lets
  # the rule scan fixtures injected via RITE_LINT_EXTRA_DIRS.
  if ! grep -qE '^[[:space:]]*export -f[[:space:]]+[a-zA-Z_]' "$file"; then
    continue
  fi

  # Look in the first 80 lines (some guards live past env-var defaults) for the
  # dangerous pattern: `if declare -f <fn> >/dev/null 2>&1; then` immediately
  # followed within 2 lines by a `return 0` body. That signature is the
  # re-source guard form, not the `if ! declare -f <fn>; then source <dep>; fi`
  # dependency-check form.
  guard_line=$(head -80 "$file" | awk '
    /^if declare -f [a-zA-Z_]+ >\/dev\/null 2>&1; then$/ {
      hit_line = NR; in_block = 1; body_lines = 0; next
    }
    in_block {
      body_lines++
      if (/return 0/) { print hit_line; exit 0 }
      if (body_lines > 2) in_block = 0
    }
  ' || true)

  if [ -n "$guard_line" ]; then
    print_violation "$file" "$guard_line" "FUNCTION_SENTINEL_GUARD_WITH_EXPORT_F" \
      "function-sentinel re-source guard combined with 'export -f' is unsafe — subprocesses of a batch parent inherit stale exported functions, the guard short-circuits, and functions added to this file after the parent started never get defined. Switch to a non-exported variable guard: see lib/utils/blocker-rules.sh:18-38 for the canonical pattern, tests/regression/blocker-rules-stale-inherited-functions.bats for what it must satisfy."
  fi
done

