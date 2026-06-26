#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/core/workflow-runner.sh, lib/core/batch-process-issues.sh, lib/core/claude-workflow.sh, lib/utils/mid-run-rebase.sh
# tests/regression/no-doubled-emoji-prefix.bats
#
# Regression test for issue #724: Fix doubled emoji/prefix in print helper output
#
# Problem: callers were passing emoji-prefixed strings to print_* helpers that
# already prepend their own emoji, producing doubled output like:
#   ⚠️  ⚠️  Scope boundary violation detected
#   ✅   ✅ Created #70
#
# Rule: the print_* helpers own the emoji; callers pass plain text.
#
# Helpers and their prefixes (from lib/utils/colors.sh):
#   print_success  → ✅
#   print_warning  → ⚠️
#   print_info     → ℹ️
#   print_error    → ❌
#   print_step     → ▶
# Local redefinitions in assess-and-resolve.sh add:
#   print_critical → 🚨
#   print_high     → ⚡
#   print_medium   → 📋
#   print_low      → 💡
#
# Tests:
#   1. No call site passes a matching leading emoji to its helper
#   2. No call site passes ANY leading emoji that would create a visual double
#      (e.g. print_info "✅ ..." → ℹ️  ✅ ..., two icons)
#   3. No print_success call has a trailing ✅ (e.g. "Venv ready ✅")

load '../helpers/setup.bash'

LIB_FILES=(
  "${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
  "${RITE_REPO_ROOT}/lib/core/workflow-runner.sh"
  "${RITE_REPO_ROOT}/lib/core/batch-process-issues.sh"
  "${RITE_REPO_ROOT}/lib/core/claude-workflow.sh"
  "${RITE_REPO_ROOT}/lib/utils/mid-run-rebase.sh"
)

# Pattern: print_HELPER "<emoji>..." where the helper would add a prefix emoji.
# Matches any leading emoji after the opening quote.
DOUBLED_PREFIX_PATTERN='print_(success|warning|info|error|step|critical|high|medium|low)[[:space:]]+["\x27][✅⚠️❌ℹ️▶⏸️⏱️📱📋🚨⚡💡]'

@test "no print_* call sites pass a leading emoji in the string argument" {
  local violations=()
  for f in "${LIB_FILES[@]}"; do
    [ -f "$f" ] || continue
    # Use grep -n to capture file+line for useful failure messages.
    # grep -P handles multi-byte emoji characters correctly.
    while IFS= read -r match; do
      violations+=("$match")
    done < <(grep -nP "$DOUBLED_PREFIX_PATTERN" "$f" 2>/dev/null || true)
  done

  if [ "${#violations[@]}" -gt 0 ]; then
    echo ""
    echo "DOUBLED EMOJI PREFIX detected in print_* call sites:"
    echo "(Helpers already add an emoji — callers must pass plain text)"
    echo ""
    for v in "${violations[@]}"; do
      echo "  $v"
    done
    echo ""
    return 1
  fi
}

@test "print_success calls do not have a trailing checkmark in the argument" {
  # e.g. print_success "Venv ready ✅" → ✅ Venv ready ✅
  local violations=()
  for f in "${LIB_FILES[@]}"; do
    [ -f "$f" ] || continue
    while IFS= read -r match; do
      violations+=("$match")
    done < <(grep -nP 'print_success\s+["\x27].*✅\s*["\x27]' "$f" 2>/dev/null || true)
  done

  if [ "${#violations[@]}" -gt 0 ]; then
    echo ""
    echo "TRAILING ✅ in print_success argument:"
    echo "(print_success already prepends ✅ — remove the trailing one)"
    echo ""
    for v in "${violations[@]}"; do
      echo "  $v"
    done
    echo ""
    return 1
  fi
}
