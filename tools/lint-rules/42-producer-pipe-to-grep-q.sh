# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 42: PRODUCER_PIPE_TO_GREP_Q — single-variable echo/printf piped to grep -q
#
# Bug class: Under set -o pipefail, `echo "$VAR" | grep -q` returns exit 141
# when grep exits on its first match before the producer finishes writing.
# The still-writing echo receives SIGPIPE → non-zero exit; pipefail propagates
# that as "no match". The bug is macOS-specific, contention-dependent, and
# random (~1-in-7500 reproduction rate under CPU load) — invisible in CI until
# it silently corrupts a gate or classification result.
#
# Same class as #1633 (tools/ sweep) and #1639 (lib/core/ sweep).
#
# Fix: use a here-string — no producer process, no SIGPIPE possible.
#   BEFORE: echo "$VAR" | grep -q "pattern"
#   AFTER:  grep -q "pattern" <<< "$VAR"
#
#   BEFORE: printf '%s\n' "$VAR" | grep -qE "pattern"
#   AFTER:  grep -qE "pattern" <<< "$VAR"
#
# NOT flagged:
#   - Command producers: `git log | grep -q`, `cmd | grep -q`
#   - Here-strings already: `grep -q "p" <<< "$VAR"`
#   - Full-line comments: lines where the first non-whitespace char is #
#
# Scope: SHELL_FILES (lib/, bin/, tools/ *.sh — lint-rules/ fragments excluded
#        by the driver's find command)
#
# Suppression (preceding line):
#   # sharkrite-lint disable PRODUCER_PIPE_TO_GREP_Q - Reason: ...
#
# Live failures: #1633 (echo "$line" | grep -q exit 141 in Rule 36 membership
# check), #1639 (lib/core/ sweep), #1640 (this sweep: lib/utils/, lib/providers/,
# bin/).

echo "Rule 42: Checking for single-variable echo/printf piped to grep -q (PRODUCER_PIPE_TO_GREP_Q)..."

_r42_check_suppressed() {
  local _file="$1" _line="$2"
  [ "$_line" -le 1 ] && return 1
  local _prev_start=$(( _line > 2 ? _line - 2 : 1 ))
  local _prev_end=$(( _line - 1 ))
  local _prev_text
  _prev_text=$(sed -n "${_prev_start},${_prev_end}p" "$_file" 2>/dev/null || true)
  grep -qE '#.*sharkrite-lint.*disable.*PRODUCER_PIPE_TO_GREP_Q' <<< "$_prev_text"
}

for _r42_file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r _r42_lnum _r42_ltext; do
    # Skip full-line comments
    grep -qE '^[[:space:]]*#' <<< "$_r42_ltext" && continue
    # Skip suppressed lines
    _r42_check_suppressed "$_r42_file" "$_r42_lnum" && continue
    print_violation "$_r42_file" "$_r42_lnum" "PRODUCER_PIPE_TO_GREP_Q" \
      "single-variable echo/printf piped to grep -q: under pipefail, grep exits on first match, producer receives SIGPIPE → exit 141, read as no-match — use: grep -q[flags] 'pattern' <<< \"\$VAR\""
  # sharkrite-lint disable PRODUCER_PIPE_TO_GREP_Q - Reason: the grep below is scanning for the bad pattern in source files; the producer here is a command (grep -nE on a file), not a variable echo
  done < <(grep -nE \
    '(echo[[:space:]]+"[^"]*\$[^"]*"|printf[[:space:]]+'"'"'%s\\n'"'"'[[:space:]]+"[^"]*\$[^"]*")[[:space:]]*\|[[:space:]]*grep[[:space:]]+-q' \
    "$_r42_file" 2>/dev/null || true)
done
