# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 42: PRODUCER_PIPE_TO_GREP_Q — single-variable producer piped into grep -q
#
# Bug class: Under set -o pipefail, `grep -q` exits on the first match without
# consuming all stdin. The still-writing producer receives SIGPIPE and exits
# non-zero; pipefail propagates that non-zero exit, so a successful match
# becomes exit 141 — read as "no match". The fix is to use a here-string
# (<<< "$VAR") which has no producer process and therefore cannot receive SIGPIPE.
#
# This rule flags ONLY single-variable producers:
#   echo "$VAR" | grep -q ...
#   printf '%s\n' "$VAR" | grep -q ...
#
# It does NOT flag command producers (cmd | grep -q) — those are intentional
# pipelines and the SIGPIPE risk is accepted.
#
# Scope: SHELL_FILES (lib/ bin/ tools/ *.sh)
#
# Fix: replace with a here-string
#   grep -q "PATTERN" <<< "$VAR"
#   grep -qXX "PATTERN" <<< "$VAR"
#
# Suppression (preceding line):
#   # sharkrite-lint disable PRODUCER_PIPE_TO_GREP_Q - Reason: ...
#
# Live failures: #1633 (tools/ sweep), #1639 (lib/core sweep),
#   #1640 (lib/utils, lib/providers, bin sweep — this rule).
#
# Reference: CLAUDE.md → "Shell Conventions" →
#   "producer | grep -q under pipefail (CRITICAL)"

echo "Rule 42: Checking for single-variable producer piped into grep -q (PRODUCER_PIPE_TO_GREP_Q)..."

_r42_check_suppressed() {
  local _file="$1" _lnum="$2"
  [ "$_lnum" -le 1 ] && return 1
  local _start=$(( _lnum > 2 ? _lnum - 2 : 1 ))
  local _end=$(( _lnum - 1 ))
  local _prev
  _prev=$(sed -n "${_start},${_end}p" "$_file" 2>/dev/null || true)
  grep -qE '#.*sharkrite-lint.*disable.*PRODUCER_PIPE_TO_GREP_Q' <<< "$_prev"
}

for _r42_file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r _r42_lnum _r42_ltext; do
    # Skip full-line comments
    grep -qE '^[[:space:]]*#' <<< "$_r42_ltext" && continue
    _r42_check_suppressed "$_r42_file" "$_r42_lnum" && continue
    print_violation "$_r42_file" "$_r42_lnum" "PRODUCER_PIPE_TO_GREP_Q" \
      "single-variable producer piped into grep -q: under pipefail, grep exits early and SIGPIPE kills the producer (exit 141 = false 'no match') — replace with a here-string: grep -q ... <<< \"\$VAR\""
  # sharkrite-lint disable BSD_LENIENT_REGEX - Reason: scan trigger that searches FOR the producer-pipe-to-grep-q pattern in source files; \\\\n is the target pattern (literal \n in the file), not a BSD-lenient \s or \` regex usage
  done < <(grep -nE "(printf '%s\\\\n' \"\\\$\{?[A-Za-z0-9_:-]+\}?\"|echo \"\\\$\{?[A-Za-z0-9_:-]+\}?\") \| grep -q" "$_r42_file" 2>/dev/null || true)
done
