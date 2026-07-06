# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 20: Test stub committed to production path (CRITICAL)
#
# Live incident: PR #260 (2026-06-02) replaced the real 1,018-line
# lib/core/assess-review-issues.sh with a 9-line test stub. The stub
# header read "# Stub assess-review-issues.sh: outputs MOCK_ASSESSMENT_FILE
# content to stdout." and the file referenced MOCK_ASSESSMENT_FILE as the
# data source. The whole production assessment phase was silently broken
# for days — the workflow gracefully fell back to "raw review count" and
# kept merging PRs without proper ACTIONABLE_NOW/LATER classification.
#
# Why it slipped past existing checks:
#   - Shellcheck doesn't know "this file is supposed to be 1000+ lines"
#   - Integration tests INJECT their own stub into a temp dir; the real
#     production file is independent and was never directly tested
#   - PR review was auto-generated (--fix-review mode) and didn't flag
#     the wholesale replacement
#
# The signal: production files (lib/core/, lib/utils/, lib/providers/)
# should never contain stub markers. A "stub" file in production paths
# means someone accidentally committed a test fixture.
#
# Detection patterns:
#   - File header comment starting with "# Stub " in the first 5 lines
#   - References to MOCK_*_FILE environment variables (test-only convention)
#   - "STUB ERROR" string literal (test-stub error message)
echo "Checking for test stubs committed to production paths (lib/)..."

for file in "${SHELL_FILES[@]}"; do
  # Only check production paths
  if [[ "$file" != */lib/core/* ]] && [[ "$file" != */lib/utils/* ]] && [[ "$file" != */lib/providers/* ]]; then
    continue
  fi
  # Skip this lint file itself (we mention the patterns in comments)
  if [[ "$file" == */tools/sharkrite-lint.sh ]]; then
    continue
  fi

  # Signal 1: "# Stub " header comment in first 5 lines
  if head -5 "$file" 2>/dev/null | grep -qE '^#[[:space:]]+Stub[[:space:]]'; then
    print_violation "$file" "1" "TEST_STUB_IN_LIB" \
      "file header starts with '# Stub' — test stubs must not live in lib/. Real implementation may have been overwritten (see Rule 20 in tools/sharkrite-lint.sh for incident context)"
    continue   # one violation per file is enough
  fi

  # Signal 2: MOCK_*_FILE reference in production code
  while IFS=: read -r line_num _; do
    print_violation "$file" "$line_num" "TEST_STUB_IN_LIB" \
      "production file references MOCK_*_FILE (test-only convention) — likely a test stub committed in error"
    break  # one per file
  done < <(grep -nE 'MOCK_[A-Z_]+_FILE' "$file" 2>/dev/null || true)

  # Signal 3: "STUB ERROR" string literal in production code
  while IFS=: read -r line_num _; do
    print_violation "$file" "$line_num" "TEST_STUB_IN_LIB" \
      "production file emits 'STUB ERROR' — likely a test stub committed in error"
    break
  done < <(grep -n 'STUB ERROR' "$file" 2>/dev/null || true)
done

