# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 39H: BSD-lenient regex idioms that silently misbehave on GNU/Linux
#
# The portability problem runs BOTH ways.  Rules 39A-39G guard the
# "GNU-only on macOS" direction; this rule guards the opposite: patterns
# BSD tools accept and GNU tools read differently.  That blind spot caused
# four of the six CI failures fixed in #1593.
#
# Sub-checks (all suppressed with the same marker):
#   A. \s inside a grep/awk/sed regex argument:
#      - BSD grep/awk/sed: reads \s as a literal 's' (no POSIX definition)
#      - GNU grep/awk/sed: reads \s as whitespace shorthand
#      - Consequence: a test using \s passes on macOS (dev box) while
#        testing nothing, or strips only lines starting with literal 's'.
#      - Fix: use [[:space:]] (POSIX character class, both platforms).
#
#   B. \` inside a single-quoted grep argument:
#      - GNU grep: \` is the beginning-of-buffer anchor (Perl extension),
#        so a pattern like '^\`\`\`bash$' cannot match a line in the middle
#        of a file even when the content is exactly ```bash.
#      - BSD grep: reads \` as a plain backtick, so the pattern matches.
#      - Consequence: assertions pass on macOS (BSD, literal backtick) but
#        fail on Linux CI (GNU, \` = zero-width buffer anchor, no match).
#      - Fix: remove the backslash — write '```bash' not '\`\`\`bash'.
#
# Scope: SHELL_FILES (lib/ bin/ tools/ *.sh) + tests/**/*.bats
#   Three of the four #1593 instances were in .bats test files, which
#   Rules 39A-39G do not scan.
#
# Suppression (preceding line, applies to both sub-checks):
#   # sharkrite-lint disable BSD_LENIENT_REGEX - Reason: <text>
#
# Live regressions:
#   A: \s in grep in four test files — BSD treated \s as literal 's' so
#      comment-stripping greps left indented comments in the data, making
#      assertions pass against the wrong (comment-contaminated) content.
#   B: grep '^\`\`\`bash$' — GNU anchor caused "no match" on Linux CI even
#      when the line content was exactly ```bash (issue #1593, 2026-10-27).

# ---------------------------------------------------------------------------
# Local helpers (must not rely on 39-gnu-only-idioms.sh being loaded —
# the SHARKRITE_LINT_ONLY=39H fast path sources only this fragment)
# ---------------------------------------------------------------------------

_r39h_check_suppressed() {
  local _gc_file="$1" _gc_line="$2"
  [ "$_gc_line" -le 1 ] && return 1
  local _gc_start=$(( _gc_line > 2 ? _gc_line - 2 : 1 ))
  local _gc_end=$(( _gc_line - 1 ))
  local _gc_prev_text
  _gc_prev_text=$(sed -n "${_gc_start},${_gc_end}p" "$_gc_file" 2>/dev/null || echo "")
  echo "$_gc_prev_text" | grep -qE '#.*sharkrite-lint.*disable.*BSD_LENIENT_REGEX'
}

# Strip single-quoted and double-quoted string contents from a line so that
# keywords inside human-readable message strings do not trigger command-position
# checks.  Single-quotes are processed first; "$(...)" command substitutions are
# unwrapped before double-quote stripping so that real commands inside
# VAR="$(cmd)" remain visible.
# BSD AWK compatible: no \s, no gensub; uses index() and [[:space:]].
_r39h_strip_quoted() {
  local _sq_line
  _sq_line=$(printf '%s' "$1" | sed "s/'[^']*'/''/g" || true)
  _sq_line=$(printf '%s' "$_sq_line" | sed 's/"[$](\([^)]*\))"/$(\1)/g' || true)
  _sq_line=$(printf '%s' "$_sq_line" | sed 's/"[^"]*"/""/g' || true)
  printf '%s\n' "$_sq_line"
}

# ---------------------------------------------------------------------------
# A. \s inside a grep/awk/sed regex argument
# ---------------------------------------------------------------------------
# BSD reads \s as a literal 's'; GNU reads it as whitespace.  An assertion
# grep like `grep -v '^\s*#'` strips nothing on BSD (no lines start with 's*#'),
# leaving comment lines in the data and causing tests to pass against the wrong
# input.  Fix: use [[:space:]] (POSIX character class).
#
# NOT flagged: full-line comments
# NOT flagged: lines where grep/awk/sed is not in command position
echo "Rule 39H-A: Checking for \\s in grep/awk/sed regex arguments (BSD-lenient)..."

# Scan SHELL_FILES (lib/ bin/ tools/ *.sh)
for _r39h_file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r _r39h_lnum _r39h_ltext; do
    # Skip full-line comments
    echo "$_r39h_ltext" | grep -qE '^[[:space:]]*#' && continue
    # Verify grep/awk/sed is in command position (strip quoted string contents first)
    _r39h_stripped=$(_r39h_strip_quoted "$_r39h_ltext")
    echo "$_r39h_stripped" | grep -qE '\b(grep|awk|sed)\b' || continue
    _r39h_check_suppressed "$_r39h_file" "$_r39h_lnum" && continue
    print_violation "$_r39h_file" "$_r39h_lnum" "BSD_LENIENT_REGEX" \
      "\\s in a grep/awk/sed regex is BSD-lenient: BSD reads it as literal 's', GNU as whitespace — replace \\s with [[:space:]] for POSIX portability"
  # sharkrite-lint disable BSD_LENIENT_REGEX - Reason: scan trigger that searches FOR \s occurrences in source files; \\s is the target pattern, not a grep regex using \s
  done < <(grep -nE '\\s' "$_r39h_file" 2>/dev/null || true)
done

# Scan tests/**/*.bats (not in SHELL_FILES) — awk skips heredoc bodies so that
# fixture strings inside <<'EOF'...EOF blocks are not incorrectly flagged.
while IFS= read -r _r39h_bats_file; do
  [ -z "$_r39h_bats_file" ] && continue
  case "$_r39h_bats_file" in
    */tests/fixtures/*|tests/fixtures/*) continue ;;
  esac
  _r39h_a_hits=$(awk '
    BEGIN { in_hd = 0; hd_d = "" }
    !in_hd && /<<-?'"'"'/ {
      _l = $0; sub(/.*<<-?'"'"'/, "", _l); sub(/'"'"'.*/, "", _l)
      if (length(_l) > 0) { in_hd = 1; hd_d = _l; next }
    }
    in_hd && $0 == hd_d { in_hd = 0; next }
    in_hd { next }
    index($0, "\\s") > 0 { print NR ":" $0 }
  ' "$_r39h_bats_file" </dev/null 2>/dev/null || true)
  [ -z "$_r39h_a_hits" ] && continue
  while IFS=: read -r _r39h_lnum _r39h_ltext; do
    [ -z "$_r39h_lnum" ] && continue
    echo "$_r39h_ltext" | grep -qE '^[[:space:]]*#' && continue
    _r39h_stripped=$(_r39h_strip_quoted "$_r39h_ltext")
    echo "$_r39h_stripped" | grep -qE '\b(grep|awk|sed)\b' || continue
    _r39h_check_suppressed "$_r39h_bats_file" "$_r39h_lnum" && continue
    print_violation "$_r39h_bats_file" "$_r39h_lnum" "BSD_LENIENT_REGEX" \
      "\\s in a grep/awk/sed regex is BSD-lenient: BSD reads it as literal 's', GNU as whitespace — replace \\s with [[:space:]] for POSIX portability"
  done <<< "$_r39h_a_hits"
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)

# ---------------------------------------------------------------------------
# B. \` inside a single-quoted grep argument
# ---------------------------------------------------------------------------
# GNU grep treats \` as the beginning-of-buffer anchor (PCRE/GNU extension),
# so a pattern like '^\`\`\`bash$' fails to match a line in the middle of a
# file even when the content is exactly ```bash.  BSD grep reads \` as a plain
# backtick, so the same pattern matches correctly on macOS (the dev box).
# Consequence: CI on Linux fails while macOS passes.
# Fix: remove the backslash — write '```bash' not '\`\`\`bash'.
#
# Only flagged inside single-quoted grep arguments to avoid false positives
# from \` in double-quoted strings, command substitutions, and heredocs.
echo 'Rule 39H-B: Checking for \` in single-quoted grep patterns (BSD-lenient)...'

_r39h_check_backtick_grep() {
  local _file="$1" _r39h_bq_hits
  case "$_file" in
    */tests/fixtures/*|tests/fixtures/*) return ;;
  esac
  # awk: (1) skips heredoc bodies (single-quoted delimiters, <<'x' / <<-'x') so
  # that markdown prose and fixture strings inside heredocs are not flagged;
  # (2) only flags \` inside single-quoted grep arguments — NOT double-quoted
  # "\`...\`" (bash converts \` → backtick before passing to grep, so grep never
  # sees the backslash; not a portability issue) or bare markdown backtick spans.
  # split() by single-quote isolates content inside single-quoted strings;
  # only even-numbered parts (indices 2, 4, ...) are inside single quotes.
  _r39h_bq_hits=$(awk '
    BEGIN { in_hd = 0; hd_d = "" }
    !in_hd && /<<-?'"'"'/ {
      _l = $0; sub(/.*<<-?'"'"'/, "", _l); sub(/'"'"'.*/, "", _l)
      if (length(_l) > 0) { in_hd = 1; hd_d = _l; next }
    }
    in_hd && $0 == hd_d { in_hd = 0; next }
    in_hd { next }
    /^[[:space:]]*#/ { next }
    /grep/ {
      _bs = "\\"
      n = split($0, _parts, "'"'"'")
      for (_i = 2; _i <= n - 1; _i += 2) {
        if (index(_parts[_i], _bs "`") > 0) { print NR ":" $0; break }
      }
    }
  ' "$_file" </dev/null 2>/dev/null || true)
  [ -z "$_r39h_bq_hits" ] && return
  while IFS=: read -r _r39h_lnum _r39h_ltext; do
    [ -z "$_r39h_lnum" ] && continue
    _r39h_stripped=$(_r39h_strip_quoted "$_r39h_ltext")
    echo "$_r39h_stripped" | grep -qE '\bgrep\b' || continue
    _r39h_check_suppressed "$_file" "$_r39h_lnum" && continue
    print_violation "$_file" "$_r39h_lnum" "BSD_LENIENT_REGEX" \
      '\` inside a single-quoted grep pattern is BSD-lenient: GNU grep treats \` as a beginning-of-buffer anchor so the pattern cannot match mid-file, while BSD grep reads a plain backtick — remove the backslash'
  done <<< "$_r39h_bq_hits"
}

for _r39h_file in "${SHELL_FILES[@]}"; do
  _r39h_check_backtick_grep "$_r39h_file"
done

while IFS= read -r _r39h_bats_file; do
  [ -z "$_r39h_bats_file" ] && continue
  _r39h_check_backtick_grep "$_r39h_bats_file"
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)
