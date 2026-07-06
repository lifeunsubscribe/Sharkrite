# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 25: Bats files must declare test coverage via sharkrite-test-covers header
#
# After #462 (selection logic) and #480 (full backfill), test-gate.sh treats
# headerless bats files as "no coverage signal" — they're SKIPPED from
# targeted runs. Without this lint rule, a new bats file without a header
# would silently never run from targeted gates, defeating its purpose.
#
# Required format in the first 5 lines of every .bats file:
#   # sharkrite-test-covers: <comma-separated paths or globs>
#
# Examples:
#   # sharkrite-test-covers: lib/core/foo.sh
#   # sharkrite-test-covers: lib/utils/*.sh, lib/core/bar.sh
#   # sharkrite-test-covers: lib/**  (intentionally broad, e.g. smoke tests)
#
# Suppression: place on the line immediately before the bats file's shebang
# (rare — typically used for fixture/scaffolding files that aren't tested by gates):
#   # sharkrite-lint disable MISSING_TEST_COVERAGE_HEADER - Reason: <why>
echo "Checking for missing sharkrite-test-covers headers in .bats files..."

while IFS= read -r bats_file; do
  [ -z "$bats_file" ] && continue
  # Allow tests/helpers/ and tests/fixtures/ to skip — they're support files
  case "$bats_file" in
    */tests/helpers/*|*/tests/fixtures/*) continue ;;
  esac
  # Check for header in first 5 lines
  if ! head -5 "$bats_file" 2>/dev/null | grep -qE '^# sharkrite-test-covers:'; then
    print_violation "$bats_file" "1" "MISSING_TEST_COVERAGE_HEADER" \
      "bats file missing 'sharkrite-test-covers:' header — required so test_gate's targeted selection (#462) can decide when to run this test. Add a comment on line 2: '# sharkrite-test-covers: lib/path/to/source.sh' listing the source files this test exercises."
  fi
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)

