#!/usr/bin/env bats
# sharkrite-test-covers: lib/**/*.sh, bin/*, tools/**/*.sh
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

# Collect all shell source files repo-wide so the guard is not limited to the
# 5 files this PR touched. The emoji-ownership convention applies to every
# print_* call site across lib/, bin/, and tools/.
mapfile -t LIB_FILES < <(
  find "${RITE_REPO_ROOT}/lib" -name "*.sh" 2>/dev/null
  find "${RITE_REPO_ROOT}/bin" -maxdepth 1 -type f 2>/dev/null
  find "${RITE_REPO_ROOT}/tools" -name "*.sh" 2>/dev/null
)

# Pattern: print_HELPER "<emoji>..." where the helper would add a prefix emoji.
# Matches any leading Unicode emoji/symbol after the opening quote.
# Unicode ranges covered:
#   \x{1F000}-\x{1FAFF}  — Emoji (emoticons, symbols, pictographs, transport, etc.)
#   \x{2600}-\x{27BF}    — Misc symbols, dingbats (▶ ⚡ ⚠ etc.)
#   \x{FE0F}             — Variation Selector-16 (emoji presentation, rarely leads)
# Using perl instead of grep -P for BSD/macOS portability (grep -P is GNU-only).
DOUBLED_PREFIX_PATTERN='print_(success|warning|info|error|step|critical|high|medium|low)\s+["\x27][\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{FE0F}]'

@test "no print_* call sites pass a leading emoji in the string argument" {
  local violations=()
  for f in "${LIB_FILES[@]}"; do
    [ -f "$f" ] || continue
    # Use perl for BSD/macOS portability; grep -P is GNU-only and exits 2 on BSD,
    # which is swallowed by || true — making the guard a silent no-op on macOS.
    while IFS= read -r match; do
      violations+=("$match")
    done < <(perl -CSD -ne "print \"$f:\$.: \$_\" if /$DOUBLED_PREFIX_PATTERN/u" "$f" 2>/dev/null || true)
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
    # Use perl for BSD/macOS portability (grep -P is GNU-only).
    while IFS= read -r match; do
      violations+=("$match")
    done < <(perl -CSD -ne "print \"$f:\$.: \$_\" if /print_success\s+[\"'][^\"']*\x{2705}\s*[\"']/u" "$f" 2>/dev/null || true)
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
