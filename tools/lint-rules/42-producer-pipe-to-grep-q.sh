# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 42: Single-variable producer piped into grep -q (PRODUCER_PIPE_TO_GREP_Q)
#
# Bug class (same as #1633 and #1639):
#
# Under set -o pipefail, grep -q exits on the first match without consuming
# the rest of its stdin.  The still-writing producer receives SIGPIPE and
# exits non-zero; pipefail propagates that non-zero, so a successful match
# becomes exit 141 — read as "no match".  The failure is macOS-specific,
# contention-dependent, and random (~1-in-7500 reproduction locally under CPU
# load), making it hard to notice until it silently corrupts a merge-gate or
# classification decision.
#
# Pattern this rule catches (single-variable producers only):
#   echo "$VAR" | grep -q ...
#   printf '%s\n' "$VAR" | grep -q ...
#
# Fix: use a here-string — there is no producer process and no SIGPIPE possible:
#   grep -q "pattern" <<< "$VAR"
#
# NOT flagged:
#   - Command producers:  git log | grep -q  (intentional pipeline)
#   - Here-strings:       grep -q "..." <<< "$VAR"  (already fixed)
#   - Comment lines:      # echo "$VAR" | grep -q  (explanatory text)
#
# Scope: SHELL_FILES (lib/ bin/ tools/ *.sh)
#
# Suppression (preceding line):
#   # sharkrite-lint disable PRODUCER_PIPE_TO_GREP_Q - Reason: <text>
#
# Live failures that motivated this rule:
#   #1633 — Rule 36 membership check: `echo "$VAR" | grep -q` false-fired on
#     macOS CI in 5 runs with large $VAR inputs (3 KB+, delivered in multiple
#     pipe chunks). The fix was confirmed by a `pipefail + sleep` reproduction
#     that consistently yields exit 141.
#   #1639 — lib/core sweep (same class).
#   #1640 — lib/utils, lib/providers, bin sweep + this rule (same class).

echo "Rule 42: Checking for single-variable producer pipe into grep -q (PRODUCER_PIPE_TO_GREP_Q)..."

# Regex matches:
#   printf '%s\n' "$VAR"  followed by  | grep -[flags]q[flags]
#   echo "$VAR"           followed by  | grep -[flags]q[flags]
# where VAR is a plain or braced variable reference (may contain digits).
# The | grep -[a-zA-Z]*q[a-zA-Z]* suffix matches q anywhere in the flag string
# (grep -q, grep -qE, grep -iqE, grep -Fxq, etc.).
_r42_pattern="(printf '[%]s[\\\\]n' \"[$][{]?[A-Za-z0-9_:-]+[}]?\"|echo \"[$][{]?[A-Za-z0-9_:-]+[}]?\") [|] grep -[a-zA-Z]*q[a-zA-Z]*"

for _r42_file in "${SHELL_FILES[@]}"; do
  # grep -n to get line numbers; then filter
  _r42_hits=$(grep -nE "$_r42_pattern" "$_r42_file" 2>/dev/null || true)
  [ -z "$_r42_hits" ] && continue

  while IFS=: read -r _r42_lnum _r42_ltext; do
    [ -z "$_r42_lnum" ] && continue

    # Skip full-line comments
    if grep -qE '^[[:space:]]*#' <<< "$_r42_ltext"; then
      continue
    fi

    # Check suppression on the preceding line(s) — look back up to 2 lines
    _r42_suppressed=false
    _r42_lookback=$((_r42_lnum - 1))
    _r42_checked=0
    while [ "$_r42_lookback" -gt 0 ] && [ "$_r42_checked" -lt 2 ]; do
      _r42_prev=$(sed -n "${_r42_lookback}p" "$_r42_file" 2>/dev/null || true)
      if grep -qE '#.*sharkrite-lint.*disable.*PRODUCER_PIPE_TO_GREP_Q' <<< "$_r42_prev"; then
        _r42_suppressed=true
        break
      fi
      _r42_lookback=$((_r42_lookback - 1))
      _r42_checked=$((_r42_checked + 1))
    done
    [ "$_r42_suppressed" = "true" ] && continue

    print_violation "$_r42_file" "$_r42_lnum" "PRODUCER_PIPE_TO_GREP_Q" \
      "echo/printf single-variable producer piped into grep -q: under pipefail, grep exits on first match causing SIGPIPE (exit 141) on the producer — use a here-string instead: grep -q \"pattern\" <<< \"\$VAR\""
  done <<< "$_r42_hits"
done
