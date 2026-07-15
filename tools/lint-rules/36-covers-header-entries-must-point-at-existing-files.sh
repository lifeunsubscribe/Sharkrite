# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 36: sharkrite-test-covers header entries must point at existing files
#
# Rule 25 enforces that every .bats file HAS a covers header; it does not check
# the header POINTS AT REAL FILES. A non-glob entry naming a source that no
# longer exists (renamed, deleted, or a typo) is a silent coverage hole:
# test_gate's targeted selection (#462) can NEVER select this test on that path,
# so the test stops running for the code it was written to guard, with no error.
# This is the mechanically-decidable half of covers-accuracy (#1023); the
# "header names a real file the test doesn't actually exercise" half is a
# judgment call a lint rule can't decide without flooding well-designed
# integration tests (which drive bin/rite) and lint tests (which drive
# `make lint`) with false positives, so it is handled by hand, not here.
#
# Contract: every comma-separated NON-GLOB entry in a '# sharkrite-test-covers:'
# header must resolve to an existing path under the repo root. Glob entries
# (containing '*') are intentionally broad and exempt.
#
# Suppression (rare — e.g. a path created by a generator at runtime):
#   # sharkrite-lint disable COVERS_HEADER_ACCURACY - Reason: <why absent on disk>
echo "Checking for sharkrite-test-covers entries that point at nonexistent files..."

# Entries resolve relative to CWD, which the driver already assumes is the repo
# root (Rule 25's `find tests` and every path-emitting rule do the same). This
# keeps the check correct in production (make lint / the gate both cd to root)
# and under test (the lint-rule tests run the driver from a temp TEST_REPO).
while IFS= read -r bats_file; do
  [ -z "$bats_file" ] && continue
  # Match both relative (tests/helpers/x) and absolute (/repo/tests/helpers/x)
  # — `find tests` yields relative paths, so a leading-slash pattern would miss.
  case "$bats_file" in
    *tests/helpers/*|*tests/fixtures/*) continue ;;
  esac

  _c36_hdr_ln=$(head -5 "$bats_file" 2>/dev/null | grep -nE '^# sharkrite-test-covers:' | head -1 | cut -d: -f1 || true)
  [ -z "$_c36_hdr_ln" ] && continue
  _c36_hdr=$(sed -n "${_c36_hdr_ln}p" "$bats_file" 2>/dev/null || true)

  # Inline suppression on the immediately-preceding line.
  if [ "$_c36_hdr_ln" -gt 1 ]; then
    _c36_prev=$(sed -n "$((_c36_hdr_ln - 1))p" "$bats_file" 2>/dev/null || true)
    if echo "$_c36_prev" | grep -qE '#.*sharkrite-lint.*disable.*COVERS_HEADER_ACCURACY'; then
      continue
    fi
  fi

  _c36_entries=${_c36_hdr#*sharkrite-test-covers:}
  while IFS= read -r _c36_entry; do
    _c36_entry=$(echo "$_c36_entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$_c36_entry" ] && continue
    case "$_c36_entry" in *'*'*) continue ;; esac  # glob → exempt

    if [ ! -e "$_c36_entry" ]; then
      print_violation "$bats_file" "$_c36_hdr_ln" "COVERS_HEADER_ACCURACY" \
        "covers-header lists '$_c36_entry' which does not exist under the repo root — a renamed/deleted/typo'd path. The gate can never select this test on that path, so it silently stops running for the code it guards. Fix the entry to the file's real path (or remove it), or suppress with '# sharkrite-lint disable COVERS_HEADER_ACCURACY - Reason: ...' on the line above the header if the path is created at runtime."
    fi
  done < <(printf '%s\n' "$_c36_entries" | tr ',' '\n')
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)
