# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 27: tr with a multibyte UTF-8 replacement/delete char (byte-oriented tr garbles it)
#
# `tr` maps BYTES, not characters. When a tr SET argument contains a multibyte
# UTF-8 character (e.g. '↵', '→', 'é'), tr replaces matched input with only the
# FIRST BYTE of that character — producing mojibake. ASCII-only SETs are fine.
#
# Live bug (fixed): lib/utils/blocker-rules.sh used `tr '\n' '↵'` to visualize
# newlines in a diag log; tr emitted 0xE2 (the first byte of ↵) instead of the
# full glyph. Fix: bash parameter expansion `${var//$'\n'/↵}` (UTF-8-safe).
#
# Detection is QUOTE-AWARE to stay false-positive-free: for each `tr` command
# word on a line, the parser walks forward ONLY through tr's own quoted SET
# operands (stopping at the next unquoted | ; & or )) and flags a non-ASCII byte
# only when it sits inside one of those quoted SETs. This deliberately does NOT
# flag a multibyte byte that appears in:
#   - a trailing comment           (echo $x | tr '\n' ',' # join ≈ x)
#   - an upstream pipeline stage   (echo "café" | tr '[:upper:]' '[:lower:]')
#   - a downstream pipeline stage  (tr '[:upper:]' '[:lower:]' | sed 's/x/→/')
# all three of which are harmless and would otherwise block legitimate code.
#
# Heredoc-aware (mirrors Rules 7/8/9/13): bodies documenting the bug pattern are
# skipped. Runs under LC_ALL=C so awk treats input as raw bytes (required for
# [\200-\377] byte-range matching). BSD-awk compatible: index()/substr()/match()
# only — no \s, no +, no \b, no compound rules.
#
# Suppression: place on the line immediately before the flagged code:
#   # sharkrite-lint disable TR_MULTIBYTE_REPLACEMENT - Reason: <text>
echo "Checking for tr with a multibyte UTF-8 replacement/delete char..."
_r27_awk=$(mktemp)
printf '%s\n' \
  'function check_tr_args(s,   i, c, q, n, mb) {' \
  '  mb = 0; i = 1; n = length(s)' \
  '  while (i <= n) {' \
  '    c = substr(s, i, 1)' \
  '    if (c == "|" || c == ";" || c == "&" || c == ")") break' \
  '    if (c == "\047" || c == "\042") {' \
  '      q = c; i++' \
  '      while (i <= n) { c = substr(s, i, 1); if (c == q) { i++; break }; if (c ~ /[\200-\377]/) mb = 1; i++ }' \
  '      continue' \
  '    }' \
  '    i++' \
  '  }' \
  '  return mb' \
  '}' \
  'FNR == 1 { in_heredoc = 0; hd_marker = "" }' \
  '{' \
  '  if (in_heredoc) {' \
  '    _close = $0; sub(/^[[:space:]]*/, "", _close)' \
  '    if (_close == hd_marker) in_heredoc = 0' \
  '    next' \
  '  }' \
  '  if (index($0, "<<") > 0) {' \
  '    tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)' \
  '    gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")' \
  '    if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) { hd_marker = _p[1]; in_heredoc = 1 }' \
  '  }' \
  '  if ($0 ~ /^[[:space:]]*#/) next' \
  '  if ($0 !~ /(^|[ \t|(;&])tr[ \t]/) next' \
  '  rest = $0; found = 0' \
  '  while (match(rest, /(^|[ \t|(;&])tr[ \t]/)) {' \
  '    after = substr(rest, RSTART + RLENGTH)' \
  '    if (check_tr_args(after)) { found = 1; break }' \
  '    rest = after' \
  '  }' \
  '  if (found) print FILENAME "\t" FNR' \
  '}' \
  > "$_r27_awk"

# LC_ALL=C: treat bytes literally so [\200-\377] reliably matches UTF-8 lead/
# continuation bytes regardless of the ambient locale.
_r26_hits=$(LC_ALL=C awk -f "$_r27_awk" "${SHELL_FILES[@]}" </dev/null 2>/dev/null || true)
rm -f "$_r27_awk"
_r27_awk=""

if [ -n "$_r26_hits" ]; then
  while IFS= read -r _hit; do
    # Tab-separated: file<TAB>linenum — safe for paths containing colons
    _hit_file=$(echo "$_hit" | cut -f1)
    _hit_line=$(echo "$_hit" | cut -f2)
    # Suppression: comment on the immediately preceding line
    _prev_line=$(sed -n "$((_hit_line - 1))p" "$_hit_file" 2>/dev/null || true)
    if echo "$_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*TR_MULTIBYTE_REPLACEMENT'; then
      continue
    fi
    print_violation "$_hit_file" "$_hit_line" "TR_MULTIBYTE_REPLACEMENT" \
      "tr maps bytes, not UTF-8 chars — a multibyte replacement/delete char emits only its first byte (garbage); use bash parameter expansion \${var//search/replace} instead"
  done <<< "$_r26_hits"
fi


