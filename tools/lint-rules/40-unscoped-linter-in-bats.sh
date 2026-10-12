# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 40: Unscoped linter invocation in .bats file (UNSCOPED_LINTER_IN_BATS)
#
# When a .bats test invokes sharkrite-lint.sh (directly or via a $*LINT_SCRIPT
# variable) without SHARKRITE_LINT_ONLY, the full 40+-rule scan runs per
# @test.  Under the gate's `bats --jobs 8` these concurrent scans starve the
# CPU and can blow the 120s BATS_TEST_TIMEOUT — dragging gates to the 1800s
# watchdog (live incidents: batch 155134 2026-07-18, slot #1021 2026-10-11).
#
# The SHARKRITE_LINT_ONLY knob was designed for exactly this: a rule's own test
# runs JUST that rule (~1s instead of ~85s). See CLAUDE.md → Linting →
# "Single-rule mode (SHARKRITE_LINT_ONLY)" for the full contract.
#
# The rule flags: any non-comment line in a .bats file (outside tests/fixtures/)
# that:
#   1. Matches the invocation pattern:
#      (a) contains `bash` (not `bash -c`) AND (`sharkrite-lint.sh` OR a
#          variable name ending in `LINT_SCRIPT`), OR
#      (b) a line starting with `run` where the first argument is `"?$LINT_SCRIPT`
#          (i.e. the lint script is the command, not an argument to grep/awk/etc.)
#   2. Is NOT a `bash -c` invocation (excludes grep-of-file patterns like
#      `bash -c "grep ... \"$LINT_SCRIPT\""`)
#   3. Has no `SHARKRITE_LINT_ONLY=[0-9]` (assignment form) on the same line
#      or any of the 3 preceding lines (blank lines count toward the 3)
#
# Heuristic limitations (documented):
#   - Does NOT detect SHARKRITE_LINT_ONLY exported in setup() and used by a
#     helper function: the export appears in setup(), not in the 3 lines before
#     the helper's `run bash "$LINT_SCRIPT"`. Suppress those with the comment.
#   - Tracks single-quoted heredoc boundaries (<<'WORD' and <<-'WORD') to skip
#     fixture content written to temp files; skips @test declaration lines
#     (test names can mention linter invocations as documentation).
#   - Single-line @test bodies (e.g. `@test "x" { run bash "$LINT_SCRIPT"; }`)
#     are skipped entirely because the @test line guard fires; these are rare
#     in practice. Suppress if a real invocation lives on an @test line.
#   - Does NOT track unquoted/double-quoted heredocs; use suppression for those.
#
# Suppression: place on the line immediately before the flagged invocation:
#   # sharkrite-lint disable UNSCOPED_LINTER_IN_BATS - Reason: <text>
# Genuine all-rules sweeps MUST state why (e.g. "stdin-safety test; scoping
# would defeat the test purpose") and should be serial-marked (if not already).
echo "Checking for unscoped linter invocations in .bats files..."

while IFS= read -r _r40_bats_file; do
  [ -z "$_r40_bats_file" ] && continue
  case "$_r40_bats_file" in
    */tests/fixtures/*|tests/fixtures/*) continue ;;
  esac

  # Pass 1: collect line numbers of invocation-pattern lines
  # Detection condition:
  #   - non-comment line, not inside a single-quoted heredoc (<<'WORD' or <<-'WORD')
  #   - contains 'bash' (execution context, not bash -c) with sharkrite-lint.sh
  #     or a *LINT_SCRIPT variable; OR bare 'run' with a *LINT_SCRIPT variable
  _r40_hits=$(awk '
    BEGIN { in_hd = 0; hd_d = "" }
    !in_hd && /<<-?'"'"'/ {
      _l = $0; sub(/.*<<-?'"'"'/, "", _l); sub(/'"'"'.*/, "", _l)
      if (length(_l) > 0) { in_hd = 1; hd_d = _l; next }
    }
    in_hd && $0 == hd_d { in_hd = 0; next }
    in_hd { next }
    /^[[:space:]]*#/ { next }
    /^@test[[:space:]]/ { next }
    (/bash[[:space:]]/ && !/bash[[:space:]]+-c[[:space:]]/ &&
     (/sharkrite-lint\.sh/ || /[A-Z_]*LINT_SCRIPT/)) ||
    /^[[:space:]]*run[[:space:]]+"?\$\{?[A-Z_]*LINT_SCRIPT/ {
      print FNR
    }
  ' "$_r40_bats_file" </dev/null 2>/dev/null || true)

  [ -z "$_r40_hits" ] && continue

  while IFS= read -r _r40_line; do
    [ -z "$_r40_line" ] && continue

    # Check the invocation line itself for SHARKRITE_LINT_ONLY=[0-9] (assignment form)
    _r40_inv=$(sed -n "${_r40_line}p" "$_r40_bats_file" 2>/dev/null || true)
    if echo "$_r40_inv" | grep -qE "SHARKRITE_LINT_ONLY=[0-9]"; then
      continue
    fi

    # Check the preceding 3 lines for SHARKRITE_LINT_ONLY=[0-9] or suppression
    # Blank lines count toward the 3-line lookback.
    _r40_scoped=false
    _r40_suppressed=false
    _r40_lookback=$((_r40_line - 1))
    _r40_checked=0
    while [ "$_r40_lookback" -gt 0 ] && [ "$_r40_checked" -lt 3 ]; do
      _r40_prev=$(sed -n "${_r40_lookback}p" "$_r40_bats_file" 2>/dev/null || true)
      if echo "$_r40_prev" | grep -qE "SHARKRITE_LINT_ONLY=[0-9]"; then
        _r40_scoped=true
        break
      fi
      if echo "$_r40_prev" | grep -qE "#.*sharkrite-lint.*disable.*UNSCOPED_LINTER_IN_BATS"; then
        _r40_suppressed=true
        break
      fi
      _r40_lookback=$((_r40_lookback - 1))
      _r40_checked=$((_r40_checked + 1))
    done

    [ "$_r40_scoped" = "true" ] && continue
    [ "$_r40_suppressed" = "true" ] && continue

    print_violation "$_r40_bats_file" "$_r40_line" "UNSCOPED_LINTER_IN_BATS" \
      "linter invoked without SHARKRITE_LINT_ONLY; a full $( ls "${SCRIPT_DIR}/lint-rules/"*.sh 2>/dev/null | wc -l | tr -d ' ')-rule scan per @test starves CPU under --jobs 8 and drags gates to the 1800s watchdog — scope to the rule(s) under test with 'SHARKRITE_LINT_ONLY=NN run bash \"\$LINT_SCRIPT\"' (see CLAUDE.md → Single-rule mode)"
  done <<< "$_r40_hits"
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)
