# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: VIOLATIONS, print_violation, colors.

# Rule 41: BSD-only `sed -i ''` in a .bats file (BARE_BSD_SED_I_IN_BATS)
#
# Rule 10 catches this in bin/, lib/ and tools/, but its file list (SHELL_FILES)
# only covers *.sh in those three directories — .bats files are never scanned.
# So a test could use the BSD form freely and pass every local check on the
# macOS dev box while failing the Linux half of the CI matrix.
#
# `sed -i '' 's/a/b/' f` on GNU sed reads the empty string as the SCRIPT and
# 's/a/b/' as a FILENAME, so it dies with:
#   sed: can't read s/a/b/: No such file or directory
#
# Live: tests/regression/gate-function-scoped-selection.bats used the BSD form
# in its fixture helper. All 14 tests passed on macOS and all 14 failed on
# ubuntu-latest, and main's CI stayed red for days with the cause buried in a
# ~40-failure log (2026-10-14).
#
# Fix: source lib/utils/portable-cmds.sh and call portable_sed_i, which
# branches on `sed --version` and passes the right form for each platform.
#
# Suppression: place on the line immediately before the flagged line:
#   # sharkrite-lint disable BARE_BSD_SED_I_IN_BATS - Reason: <text>
# Legitimate uses are meta-tests: a fixture STRING containing the bad form in
# order to assert that Rule 10 fires on it. State that the occurrence is a
# fixture string and is never executed.
echo "Checking for bare 'sed -i \"\"' in .bats files..."

while IFS= read -r _r41_bats_file; do
  [ -z "$_r41_bats_file" ] && continue
  case "$_r41_bats_file" in
    */tests/fixtures/*|tests/fixtures/*) continue ;;
  esac

  # Two exemptions, both the same carve-outs Rule 40 makes:
  #   - @test title lines: a test NAME cannot execute sed, and rule meta-tests
  #     legitimately quote the bad form in their titles.
  #   - single-quoted heredoc bodies (<<'WORD'): that content belongs to the
  #     fixture FILE being written, not to this .bats file. If the fixture is
  #     itself a .bats under tests/ it gets scanned on its own; a rule's own
  #     "should fire" fixtures would otherwise flag the rule's test file.
  _r41_hits=$(awk '
    BEGIN { in_hd = 0; hd_d = "" }
    !in_hd && /<<-?'"'"'/ {
      _l = $0; sub(/.*<<-?'"'"'/, "", _l); sub(/'"'"'.*/, "", _l)
      if (length(_l) > 0) { in_hd = 1; hd_d = _l; next }
    }
    in_hd && $0 == hd_d { in_hd = 0; next }
    in_hd { next }
    /^[[:space:]]*#/ { next }
    /^@test[[:space:]]/ { next }
    /sed[[:space:]]+-i[[:space:]]+'"'"''"'"'/ { print FNR }
  ' "$_r41_bats_file" </dev/null 2>/dev/null || true)

  [ -z "$_r41_hits" ] && continue

  while IFS= read -r _r41_line; do
    [ -z "$_r41_line" ] && continue

    # Preceding 2 lines may carry a suppression. Blank lines count toward the 2.
    _r41_suppressed=false
    _r41_lookback=$((_r41_line - 1))
    _r41_checked=0
    while [ "$_r41_lookback" -gt 0 ] && [ "$_r41_checked" -lt 2 ]; do
      _r41_prev=$(sed -n "${_r41_lookback}p" "$_r41_bats_file" 2>/dev/null || true)
      if echo "$_r41_prev" | grep -qE "#.*sharkrite-lint.*disable.*BARE_BSD_SED_I_IN_BATS"; then
        _r41_suppressed=true
        break
      fi
      _r41_lookback=$((_r41_lookback - 1))
      _r41_checked=$((_r41_checked + 1))
    done

    [ "$_r41_suppressed" = "true" ] && continue

    print_violation "$_r41_bats_file" "$_r41_line" "BARE_BSD_SED_I_IN_BATS" \
      "bare 'sed -i \"\"' is BSD-only — GNU sed reads the empty string as the script and the expression as a filename, so this passes on macOS and fails on Linux CI; source lib/utils/portable-cmds.sh and use portable_sed_i instead"
  done <<< "$_r41_hits"
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)
