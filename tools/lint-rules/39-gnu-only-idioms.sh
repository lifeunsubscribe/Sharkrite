# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 39: GNU-only shell idioms that silently misbehave on BSD/macOS
#
# Catches the idiom classes that shipped as silent regressions in #884/#893
# because the macOS+Linux matrix CI only catches executed paths, not authoring
# patterns. The rule fires at authoring time so these never reach CI.
#
# Sub-checks (all suppressed with the same marker):
#   A. sed BRE alternation/quantifiers (\|/\+/\?) — GNU BRE extensions; BSD treats as literals
#      (sed Q / \w / \W are out of scope — not yet tracked)
#   B. sed case-conversion (\u \l \U \L) — GNU replacement extension; BSD: garbage
#   C. date -d without BSD fallback (|| date -v or date -j, or date --version guard)
#   D. grep -P / --perl-regexp — PCRE mode; absent on stock macOS grep
#   E. stat -c without stat --version guard — GNU stat format; BSD uses stat -f
#   F. bare timeout invocation without command -v timeout / gtimeout guard
#   G. mktemp template where XXXXXX is not terminal — BSD creates literal suffix
#
# Suppression (preceding line, applies to all sub-checks):
#   # sharkrite-lint disable GNU_ONLY_IDIOM - Reason: <text>
#
# Live regressions that motivated each check:
#   A: assess-review-issues.sh / plan-issues.sh (BRE \| — BSD ran to EOF or matched nothing)
#   B: create-pr.sh (sed \u title-case — BSD emitted "uix uogin" literal-u garbage)
#   F: batch-process-issues.sh (bare timeout — exit 127 misread as timed-out on macOS)
#   G: bin/rite-full-suite (mktemp .XXXXXX.txt — BSD created literal ".txt" filename)

_gnu_check_suppressed() {
  local _gc_file="$1" _gc_line="$2"
  # Line 1 has no preceding lines; suppression impossible
  [ "$_gc_line" -le 1 ] && return 1
  local _gc_start=$(( _gc_line > 2 ? _gc_line - 2 : 1 ))
  local _gc_end=$(( _gc_line - 1 ))
  local _gc_prev_text
  # Look back 2 lines: handles both single-line (comment on line N-1) and
  # multi-line pipeline continuations (comment on line N-2, assignment on N-1,
  # flagged command on N — the \| is inside the pipeline continuation).
  _gc_prev_text=$(sed -n "${_gc_start},${_gc_end}p" "$_gc_file" 2>/dev/null || echo "")
  echo "$_gc_prev_text" | grep -qE '#.*sharkrite-lint.*disable.*GNU_ONLY_IDIOM'
}

# Shared helper: blank the contents of string literals ('...' and "...") on a
# single source line so that keywords inside human-readable message strings do
# not trigger command-position checks.  Single-quotes are processed first
# because they can contain unescaped double-quotes.  Does not handle $()
# inside "..." — a bare command inside "$(cmd)" would not be detected, but
# that pattern is rare; the goal is false-positive reduction, not a complete
# shell tokenizer (#1504).
_r39_strip_quoted() {
  local _sq_line
  _sq_line=$(printf '%s' "$1" | sed "s/'[^']*'/''/g" || true)
  _sq_line=$(printf '%s' "$_sq_line" | sed 's/"[^"]*"/""/g' || true)
  printf '%s\n' "$_sq_line"
}

# ---------------------------------------------------------------------------
# A. sed BRE alternation/quantifiers (\|/\+/\?)
# ---------------------------------------------------------------------------
# GNU BRE extensions: \| is alternation, \+ is one-or-more, \? is zero-or-one.
# BSD sed treats all three as literal characters (backslash then |/+/?), so
# patterns silently match the wrong text or nothing.
# Fix: use sed -E (ERE) with unescaped |/+/? for alternation/quantifiers.
# NOT flagged: sed -E / sed -nE (ERE mode)
# NOT flagged: \| that appears only in a s/// replacement (e.g. sed 's/|/\\|/g'
#              escapes | in output — the \\| in the replacement is not BRE alternation)
echo "Rule 39A: Checking for sed BRE extensions (\\|/\\+/\\?) — GNU-only..."
for _r39_file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r _r39_lnum _r39_ltext; do
    # Skip full-line comments
    echo "$_r39_ltext" | grep -qE '^[[:space:]]*#' && continue
    # Only flag if sed appears in command position — strip quoted string contents
    # first so that 'sed' inside a message string (e.g. print_info "use sed …")
    # does not satisfy this guard (#1504 shared fix).
    _r39_a_stripped=$(_r39_strip_quoted "$_r39_ltext")
    echo "$_r39_a_stripped" | grep -qE '\bsed\b' || continue
    # Skip if sed is in ERE mode (-E or any flag cluster containing E)
    echo "$_r39_ltext" | grep -qE '\bsed\b[^|&;#]*-[a-zA-Z]*E' && continue
    # Scope to the sed-expression portion of the line: strip everything before
    # the first word-boundary 'sed ' so that \|/\+/\? in preceding grep/awk
    # arguments are not mistaken for BRE extensions (false-positive guard).
    _r39_sed_part=$(echo "$_r39_ltext" | awk '{
      n = length($0)
      for (i = 1; i <= n-3; i++) {
        if (substr($0, i, 4) == "sed ") {
          c = (i > 1) ? substr($0, i-1, 1) : " "
          if (c == " " || c == "\t" || c == "|" || c == ";" || c == "&" || c == "(" || i == 1) {
            print substr($0, i); exit
          }
        }
      }
      print $0
    }' || true)
    # For \|: skip if \| only appears as \\| — escaped pipe in s/// replacement
    # (not BRE alternation). Strip all \\| occurrences from the sed portion; if
    # no BRE extension remains after stripping, skip. Checking all three escapes
    # here prevents a line with both \\| in replacement and \+/\? in pattern
    # from being silently skipped.
    if echo "$_r39_sed_part" | grep -qF '\|'; then
      _r39_stripped=$(echo "$_r39_sed_part" | sed 's/\\\\|//g' || true)
      echo "$_r39_stripped" | grep -qE '\\[|+?]' || continue
    fi
    # Skip if no BRE extension is present in the sed portion at all
    echo "$_r39_sed_part" | grep -qE '\\[|+?]' || continue
    _gnu_check_suppressed "$_r39_file" "$_r39_lnum" && continue
    print_violation "$_r39_file" "$_r39_lnum" "GNU_ONLY_IDIOM" \
      "sed BRE extension (\\|/\\+/\\?) is GNU-only — BSD treats as literals (silent wrong match); use sed -E with unescaped |/+/? for ERE alternation/quantifiers"
  done < <(grep -nE '\\[|+?]' "$_r39_file" 2>/dev/null || true)
done

# ---------------------------------------------------------------------------
# B. sed case-conversion escapes (\u \l \U \L)
# ---------------------------------------------------------------------------
# GNU sed replacement extension: \u (uppercase next), \l (lowercase next),
# \U (uppercase all to \E), \L (lowercase all to \E). BSD sed does not support
# these — it emits literal characters like "u", "l", or corrupts the output.
# Fix: replace with awk's toupper()/tolower() or tr.
echo "Rule 39B: Checking for sed case-conversion escapes (\\u \\l \\U \\L) — GNU-only..."
for _r39_file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r _r39_lnum _r39_ltext; do
    echo "$_r39_ltext" | grep -qE '^[[:space:]]*#' && continue
    echo "$_r39_ltext" | grep -qE '\bsed\b' || continue
    _gnu_check_suppressed "$_r39_file" "$_r39_lnum" && continue
    print_violation "$_r39_file" "$_r39_lnum" "GNU_ONLY_IDIOM" \
      "sed case-conversion escape (\\u/\\l/\\U/\\L) is a GNU-only replacement extension; BSD sed emits garbage — use awk toupper()/tolower() or tr instead"
  done < <(grep -nE 'sed.*\\[uUlL]' "$_r39_file" 2>/dev/null || true)
done

# ---------------------------------------------------------------------------
# C. date -d without BSD fallback
# ---------------------------------------------------------------------------
# GNU date: date -d "30 days ago" parses relative/absolute expressions.
# BSD date (macOS): -d is the day-of-month flag, not a date parser.
# Fix: add a same-line BSD fallback (|| date -v-30d) or wrap in a
# date --version guard (GNU) with a date -v / date -j (BSD) else branch.
# NOT flagged: lines that already carry a || date -v or || date -j fallback
# NOT flagged: lines inside a date --version guard (preceding 3 lines)
echo "Rule 39C: Checking for date -d without BSD fallback — GNU-only..."
for _r39_file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r _r39_lnum _r39_ltext; do
    echo "$_r39_ltext" | grep -qE '^[[:space:]]*#' && continue
    # Same-line BSD fallback: || date -v (offset) or || date -j (custom format)
    echo "$_r39_ltext" | grep -qE '\|\|[[:space:]]*date[[:space:]]+-[vj]' && continue
    # BSD or GNU date guard in the preceding 3 lines:
    #   date --version (GNU check — if branch uses date -d, else uses date -v/-j)
    #   date -v / date -j (BSD-first guard — if branch uses BSD form, else uses date -d)
    _r39_start=$(( _r39_lnum > 3 ? _r39_lnum - 3 : 1 ))
    _r39_prev3=""
    [ "$_r39_lnum" -gt 1 ] && _r39_prev3=$(sed -n "${_r39_start},$((  _r39_lnum - 1 ))p" "$_r39_file" 2>/dev/null || echo "")
    echo "$_r39_prev3" | grep -qE 'date (--version|-[vj])' && continue
    _gnu_check_suppressed "$_r39_file" "$_r39_lnum" && continue
    print_violation "$_r39_file" "$_r39_lnum" "GNU_ONLY_IDIOM" \
      "'date -d' is a GNU date extension for parsing date expressions; BSD date interprets -d as day-of-month — add a same-line '|| date -v' fallback or wrap in a 'date --version' guard"
  done < <(grep -nE '\bdate -d\b' "$_r39_file" 2>/dev/null || true)
done

# ---------------------------------------------------------------------------
# D. grep -P / --perl-regexp
# ---------------------------------------------------------------------------
# PCRE (Perl-compatible regex) mode is a GNU grep extension; stock macOS grep
# does not support -P at all (exits with "invalid option -- P" and returns 0 or
# fails, depending on version). Use -E (ERE) instead for portable patterns.
echo "Rule 39D: Checking for grep -P / --perl-regexp — GNU-only..."
for _r39_file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r _r39_lnum _r39_ltext; do
    echo "$_r39_ltext" | grep -qE '^[[:space:]]*#' && continue
    _gnu_check_suppressed "$_r39_file" "$_r39_lnum" && continue
    print_violation "$_r39_file" "$_r39_lnum" "GNU_ONLY_IDIOM" \
      "'grep -P' (PCRE mode) is not available on stock macOS grep — use grep -E (ERE) with a POSIX-compatible pattern instead"
  done < <(grep -nE '\bgrep\b[^|&;#]*(-[a-zA-Z]*P\b|--perl-regexp)' "$_r39_file" 2>/dev/null || true)
done

# ---------------------------------------------------------------------------
# E. stat -c without stat --version guard
# ---------------------------------------------------------------------------
# GNU stat: stat -c "%Y" FILE prints the format specified by the -c string.
# BSD stat (macOS): stat -c is unsupported (exits non-zero with "illegal option").
# The portable wrapper is portable_stat_mtime() in lib/utils/portable-cmds.sh
# (which wraps both forms behind a stat --version guard).
# NOT flagged: inside a stat --version guard (preceding 3 lines)
echo "Rule 39E: Checking for stat -c without stat --version guard — GNU-only..."
for _r39_file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r _r39_lnum _r39_ltext; do
    echo "$_r39_ltext" | grep -qE '^[[:space:]]*#' && continue
    _r39_start=$(( _r39_lnum > 3 ? _r39_lnum - 3 : 1 ))
    _r39_prev3=""
    [ "$_r39_lnum" -gt 1 ] && _r39_prev3=$(sed -n "${_r39_start},$((  _r39_lnum - 1 ))p" "$_r39_file" 2>/dev/null || echo "")
    echo "$_r39_prev3" | grep -qE 'stat --version' && continue
    _gnu_check_suppressed "$_r39_file" "$_r39_lnum" && continue
    print_violation "$_r39_file" "$_r39_lnum" "GNU_ONLY_IDIOM" \
      "'stat -c' is a GNU stat format option; BSD stat uses 'stat -f' — wrap in a 'stat --version' guard or use portable_stat_mtime() from lib/utils/portable-cmds.sh"
  done < <(grep -nE '\bstat -c\b' "$_r39_file" 2>/dev/null || true)
done

# ---------------------------------------------------------------------------
# F. Bare timeout invocation without command -v timeout / gtimeout guard
# ---------------------------------------------------------------------------
# The timeout(1) binary is provided by GNU coreutils and is absent on stock
# macOS (/bin/bash) — on macOS it's only available as gtimeout via coreutils.
# A bare `timeout N cmd` without a command -v guard exits 127, which callers
# may misinterpret as a timed-out process.
# Fix: use run_with_timeout (lib/utils/timeout.sh) — it degrades gracefully.
# NOT flagged: run_with_timeout (the portable wrapper)
# NOT flagged: lines inside a `command -v timeout` or `command -v gtimeout`
#              guard (preceding 3 lines)
echo "Rule 39F: Checking for bare timeout invocation without command -v guard — GNU-only..."
for _r39_file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r _r39_lnum _r39_ltext; do
    echo "$_r39_ltext" | grep -qE '^[[:space:]]*#' && continue
    # run_with_timeout is the portable wrapper — skip
    echo "$_r39_ltext" | grep -qF 'run_with_timeout' && continue
    # Re-verify the match is in command position after stripping quoted string
    # literals.  printf/echo/variable-assignment message strings that mention
    # "timeout Ns" in human-readable text fired as false positives (#1504).
    _r39_f_stripped=$(_r39_strip_quoted "$_r39_ltext")
    echo "$_r39_f_stripped" | grep -qE '(^|[[:space:];|&(])(timeout)[[:space:]]+[-0-9$]' || continue
    # command -v timeout / gtimeout guard on this line
    echo "$_r39_ltext" | grep -qE 'command -v (timeout|gtimeout)' && continue
    _r39_start=$(( _r39_lnum > 3 ? _r39_lnum - 3 : 1 ))
    _r39_prev3=""
    [ "$_r39_lnum" -gt 1 ] && _r39_prev3=$(sed -n "${_r39_start},$((  _r39_lnum - 1 ))p" "$_r39_file" 2>/dev/null || echo "")
    echo "$_r39_prev3" | grep -qE 'command -v (timeout|gtimeout)' && continue
    _gnu_check_suppressed "$_r39_file" "$_r39_lnum" && continue
    print_violation "$_r39_file" "$_r39_lnum" "GNU_ONLY_IDIOM" \
      "bare 'timeout' command is absent on stock macOS (coreutils not installed); use run_with_timeout from lib/utils/timeout.sh or guard with 'command -v timeout'"
  done < <(grep -nE '(^|[[:space:];|&(])(timeout)[[:space:]]+[-0-9$]' "$_r39_file" 2>/dev/null || true)
done

# ---------------------------------------------------------------------------
# G. mktemp template where XXXXXX is not the terminal segment
# ---------------------------------------------------------------------------
# BSD mktemp requires the XXXXXX placeholder to be at the very end of the
# template (no suffix). When a suffix follows (e.g. mktemp /tmp/foo_XXXXXX.txt),
# BSD mktemp uses the template literally — it creates a file named exactly
# "/tmp/foo_XXXXXX.txt" without replacing XXXXXX, which breaks uniqueness.
# GNU mktemp accepts suffixes via --suffix but not positionally.
# Fix: remove the suffix (BSD already uses PID+timestamp for uniqueness), or
# use mktemp "${TMPDIR:-/tmp}/prefix_$$_XXXXXX" (terminal XXXXXX).
echo "Rule 39G: Checking for mktemp templates with non-terminal XXXXXX — BSD-broken..."
for _r39_file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r _r39_lnum _r39_ltext; do
    echo "$_r39_ltext" | grep -qE '^[[:space:]]*#' && continue
    _gnu_check_suppressed "$_r39_file" "$_r39_lnum" && continue
    print_violation "$_r39_file" "$_r39_lnum" "GNU_ONLY_IDIOM" \
      "mktemp template has XXXXXX followed by a suffix — BSD mktemp requires XXXXXX at the end; the template is used literally on BSD, breaking file uniqueness"
  done < <(grep -nE 'mktemp[^|&;]*XXXXXX[^[:space:]"'"'"']' "$_r39_file" 2>/dev/null || true)
done
