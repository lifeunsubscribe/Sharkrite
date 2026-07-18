# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 25: Bats files must declare ACCURATE test coverage via a
#          sharkrite-test-covers header
#
# Two passes over every .bats file, in one loop:
#
#   PASS 1 — PRESENCE (MISSING_TEST_COVERAGE_HEADER). After #462 (selection
#   logic) and #480 (full backfill), test-gate.sh treats headerless bats files
#   as "no coverage signal" — they're SKIPPED from targeted runs. A new bats
#   file without a header would silently never run from targeted gates.
#
#   PASS 2 — EXISTENCE (STALE_TEST_COVERAGE_ENTRY, #1023). Every non-glob entry
#   must resolve to a real file. A renamed/deleted/typo'd path is a silent
#   coverage hole: the gate can never select the test on that path, so it stops
#   running for the code it guards. (The stronger "header names a real file the
#   test doesn't actually exercise" check was rejected — it flags legitimate
#   indirect coverage, e.g. integration tests driving bin/rite; see #1023.)
#
# Required format in the first 5 lines of every .bats file:
#   # sharkrite-test-covers: <comma-separated paths or globs>
#
# Examples:
#   # sharkrite-test-covers: lib/core/foo.sh
#   # sharkrite-test-covers: lib/utils/*.sh, lib/core/bar.sh
#   # sharkrite-test-covers: lib/**  (intentionally broad, e.g. smoke tests)
#
# Glob entries (containing '*') are exempt from the existence check.
#
# Suppression: place on the line immediately before the covers header:
#   # sharkrite-lint disable MISSING_TEST_COVERAGE_HEADER - Reason: <why>
#   # sharkrite-lint disable STALE_TEST_COVERAGE_ENTRY - Reason: <why>
echo "Checking sharkrite-test-covers headers in .bats files (presence + entry existence)..."

while IFS= read -r bats_file; do
  [ -z "$bats_file" ] && continue
  # Skip support files. Pattern matches both relative (tests/helpers/x) and
  # absolute paths — `find tests` yields relative, so a leading-slash pattern
  # would silently fail to skip them.
  case "$bats_file" in
    *tests/helpers/*|*tests/fixtures/*) continue ;;
  esac

  # --- PASS 1: header presence ---
  _cov_hdr_ln=$(head -5 "$bats_file" 2>/dev/null | grep -nE '^# sharkrite-test-covers:' | head -1 | cut -d: -f1 || true)
  if [ -z "$_cov_hdr_ln" ]; then
    print_violation "$bats_file" "1" "MISSING_TEST_COVERAGE_HEADER" \
      "bats file missing 'sharkrite-test-covers:' header — required so test_gate's targeted selection (#462) can decide when to run this test. Add a comment on line 2: '# sharkrite-test-covers: lib/path/to/source.sh' listing the source files this test exercises."
    continue
  fi

  # --- PASS 2: entry existence ---
  _cov_hdr=$(sed -n "${_cov_hdr_ln}p" "$bats_file" 2>/dev/null || true)
  # Inline suppression on the immediately-preceding line.
  if [ "$_cov_hdr_ln" -gt 1 ]; then
    _cov_prev=$(sed -n "$((_cov_hdr_ln - 1))p" "$bats_file" 2>/dev/null || true)
    case "$_cov_prev" in *"sharkrite-lint disable STALE_TEST_COVERAGE_ENTRY"*) continue ;; esac
  fi
  _cov_entries=${_cov_hdr#*sharkrite-test-covers:}
  while IFS= read -r _cov_entry; do
    _cov_entry=$(echo "$_cov_entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$_cov_entry" ] && continue
    case "$_cov_entry" in *'*'*) continue ;; esac  # glob → exempt
    # Entries resolve relative to CWD, which the driver assumes is the repo root
    # (make lint / the gate both cd to root; the lint-rule tests run from a temp
    # TEST_REPO). Same convention as every path-emitting rule here.
    if [ ! -e "$_cov_entry" ]; then
      print_violation "$bats_file" "$_cov_hdr_ln" "STALE_TEST_COVERAGE_ENTRY" \
        "covers-header lists '$_cov_entry' which does not exist — a renamed/deleted/typo'd path. The gate can never select this test on that path, so it silently stops running for the code it guards. Fix the entry to the file's real path (or remove it), or suppress with '# sharkrite-lint disable STALE_TEST_COVERAGE_ENTRY - Reason: ...' on the line above the header."
    fi
  done < <(printf '%s\n' "$_cov_entries" | tr ',' '\n')
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)

