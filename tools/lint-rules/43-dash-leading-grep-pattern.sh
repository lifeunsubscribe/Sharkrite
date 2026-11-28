# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 43: Dash-leading grep pattern literal (DASH_LEADING_GREP_PATTERN)
#
# Bug class: option-injection through a pattern argument.
#
# A `grep` whose pattern text starts with `-` is parsed as a flag group unless
# `--` or `-e` appears first.  grep exits 2 and prints nothing — a count comes
# back empty, a match test reads as "no match", and nothing in the shell error-
# handles exit 2.
#
# Live (batch 1836-1840, issue #1838, 2026-11-24):
#   grep -c '---NARRATIVE---'   # exits 2; recorded count was empty;
#                               # two tests failed with "[: : integer expected"
#   The gate reported two bats failures with no file or line, and the fix
#   session spent 29 minutes reconstructing the cause.
#   Fixed by PR #1855 (two characters: `--`).
#
# Scope: SHELL_FILES (lib/ bin/ tools/ *.sh) AND tests/**/*.bats.
# Literal patterns only.  Variable patterns ($VAR, ${VAR}) are NOT flagged —
# 65 sites in 26 files; most can never start with a dash.
#
# Fix: add `--` before the pattern, or pass the pattern with `-e`.
#   grep -qE -- '-pattern'       # -- signals end of options
#   grep -qE -e '-pattern'       # -e takes the next arg as the pattern
#
# NOT flagged:
#   - Pattern after `--`                 grep -- '-p'
#   - Pattern given with `-e`            grep -e '-p'
#   - Lone '-' pattern                   grep '-' file  (matches literal dash)
#   - Full-line comments                 # grep -q '-p'
#   - @test title lines in .bats         @test "fires on grep '-p'" { ... }
#   - Single-quoted heredoc bodies       <<'EOF' ... EOF
#   - Files under tests/fixtures/
#
# Suppression (preceding line):
#   # sharkrite-lint disable DASH_LEADING_GREP_PATTERN - Reason: <text>

echo "Rule 43: Checking for dash-leading grep pattern literals (DASH_LEADING_GREP_PATTERN)..."

# _r43_check_file FILE
#
# Outputs line numbers of violations via awk, then checks each one for a
# suppression comment on the preceding line(s).  Shared by the SHELL_FILES
# loop and the bats-file loop.
_r43_check_file() {
  local _r43_f="$1"
  local _r43_hits
  _r43_hits=$(awk '
    BEGIN { in_hd = 0; hd_d = ""; sq_sep = sprintf("%c", 39) }

    # Track single-quoted heredoc bodies (<<'"'"'WORD'"'"' ... WORD).
    # Content between the delimiters is literal data, not executable code.
    !in_hd && /<<-?'"'"'/ {
      l = $0; sub(/.*<<-?'"'"'/, "", l); sub(/'"'"'.*/, "", l)
      if (length(l) > 0) { in_hd = 1; hd_d = l; next }
    }
    in_hd && $0 == hd_d { in_hd = 0; next }
    in_hd { next }

    # Skip full-line comments (applies to both shell and bats files).
    /^[[:space:]]*#/ { next }

    # Skip @test title lines: the test NAME cannot execute, and rule
    # meta-tests legitimately quote the bad form in their titles.
    /^@test[[:space:]]/ { next }

    {
      if ($0 !~ /grep/) next

      found = 0

      # ---- single-quoted dash-leading literals --------------------------------
      # Split by the single-quote character (stored in sq_sep to avoid having
      # a bare single-quote in the awk program body, which would break the
      # surrounding shell single-quote string).
      n = split($0, sq, sq_sep)
      for (i = 2; i <= n && !found; i += 2) {
        content = sq[i]
        # Must be more than just "-" (lone dash is exempt by design).
        if (length(content) < 2 || substr(content, 1, 1) != "-") continue

        # Reconstruct the portion of the line before the opening quote of
        # this token (the first i-1 split fragments, re-joined with sq_sep).
        before = ""
        for (j = 1; j <= i-1; j++) {
          before = before sq[j]
          if (j < i-1) before = before sq_sep
        }

        # Only a violation when grep appears before this quoted pattern.
        if (before !~ /grep/) continue

        # Everything after the last 'grep' and before the pattern.
        ag = before; sub(/.*grep/, "", ag)

        # Exempt: -- signals end of options.
        if (ag ~ /--/) continue

        # Exempt: -e flag passes the next argument as the pattern explicitly.
        # Matches: -e, -Fe, -qe, -Fxe, etc., followed by a non-letter or EOL.
        if (ag ~ /-[A-Za-z]*e([^A-Za-z]|$)/) continue

        found = 1
      }

      # ---- double-quoted dash-leading literals --------------------------------
      if (!found) {
        # Strip single-quoted strings before the double-quote split.
        # Avoids false positives when double-quotes appear inside a
        # single-quoted grep pattern (the double-quotes are content,
        # not argument delimiters).
        line_dq = $0
        gsub(sq_sep "[^" sq_sep "]*" sq_sep, "SQREMOVED", line_dq)
        n = split(line_dq, dq, "\"")
        for (i = 2; i <= n && !found; i += 2) {
          content = dq[i]
          if (length(content) < 2 || substr(content, 1, 1) != "-") continue

          before = ""
          for (j = 1; j <= i-1; j++) {
            before = before dq[j]
            if (j < i-1) before = before "\""
          }

          if (before !~ /grep/) continue

          ag = before; sub(/.*grep/, "", ag)
          if (ag ~ /--/) continue
          if (ag ~ /-[A-Za-z]*e([^A-Za-z]|$)/) continue

          found = 1
        }
      }

      if (found) print FNR
    }
  ' "$_r43_f" </dev/null 2>/dev/null || true)

  [ -z "$_r43_hits" ] && return

  local _r43_line _r43_lookback _r43_checked _r43_prev _r43_suppressed
  while IFS= read -r _r43_line; do
    [ -z "$_r43_line" ] && continue

    _r43_suppressed=false
    _r43_lookback=$((_r43_line - 1))
    _r43_checked=0
    while [ "$_r43_lookback" -gt 0 ] && [ "$_r43_checked" -lt 2 ]; do
      _r43_prev=$(sed -n "${_r43_lookback}p" "$_r43_f" 2>/dev/null || true)
      if grep -qE '#.*sharkrite-lint.*disable.*DASH_LEADING_GREP_PATTERN' <<< "$_r43_prev"; then
        _r43_suppressed=true
        break
      fi
      _r43_lookback=$((_r43_lookback - 1))
      _r43_checked=$((_r43_checked + 1))
    done

    [ "$_r43_suppressed" = "true" ] && continue

    print_violation "$_r43_f" "$_r43_line" "DASH_LEADING_GREP_PATTERN" \
      "grep pattern starts with '-': without '--' or '-e', grep reads it as an option (exits 2, prints nothing); add '--' before the pattern or use '-e'"
  done <<< "$_r43_hits"
}

# --- Shell files (lib/ bin/ tools/ *.sh) ------------------------------------
for _r43_sh_file in "${SHELL_FILES[@]}"; do
  _r43_check_file "$_r43_sh_file"
done

# --- Bats files (tests/**/*.bats, excluding tests/fixtures/) -----------------
while IFS= read -r _r43_bats_file; do
  [ -z "$_r43_bats_file" ] && continue
  case "$_r43_bats_file" in
    */tests/fixtures/*|tests/fixtures/*) continue ;;
  esac
  _r43_check_file "$_r43_bats_file"
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)
