# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 8: Unsafe pipe inside command substitution (silent death under set -euo pipefail)
# Uses AWK for performance — the bash while+grep approach spawned thousands of
# subprocesses per file: grep -n '=\$(' found 1346 matches across 52 files,
# and each match triggered 3–4 more greps + 1 sed (for next-line lookahead),
# totalling ~6000–7000 subprocess calls and 9+ seconds per lint run.
#
# AWK strategy: buffer each triggering line, then scan FORWARD until the
# command substitution resolves: a guard (|| true / || echo / : $?) clears it;
# a line ending in ")" closes the substitution unguarded → violation; a 40-line
# cap reports runaway constructs. The earlier one-line lookahead false-flagged
# multi-line blocks whose guard sits on the closing line, e.g.
#   _body=$(printf '%s' "$x" | awk '
#     ...10 lines of awk program...
#   ' || true)        <- guard here, invisible to a next-line-only check
# (live false positive: #568's _resolve_ordinal_refs_in_body, 2026-06-12).
#
# Two opener kinds are tracked (pending_kind): kind 1 = the tool keyword is on
# the opener line (classic single- or multi-line awk/grep block); kind 2 = the
# opener is a pipe-continuation `VAR=$(... | \` whose tool keyword lands on a
# later line (e.g. `RESULT=$(git worktree list | \` then `  grep ...)`). Kind 2
# fires ONLY when the CLOSING `)` line's terminal pipeline segment is a tool —
# conservative on purpose so a `... | \` continuation that ends in a safe stage
# (tr, jq) is NOT flagged, and so an `=$(...) ||` error-guard (the `||` contains
# a `|`) never starts a kind-2 lookahead. The kind-2 opener regex requires a
# single `|` then `\` at EOL ([^|]\| ... \\$), which excludes `||`.
# BSD AWK compatible: no \s, no + quantifier, no \b — uses index(), [[:space:]]*,
# and [^a-zA-Z0-9_] for word boundaries.
echo "Checking for unsafe VAR=\$(... | grep/awk/sed/head/tail) patterns..."
_r8_awk=$(mktemp)
# Output uses tab as field separator (file\tlinenum) so paths containing
# colons (e.g. CI matrix job paths like /home/runner/work/my:project/file.sh)
# parse correctly — colon-based splitting breaks on such paths.
printf '%s\n' \
  'FNR == 1 {' \
  '  if (pending_line > 0) { if (pending_tool) print pending_fname "\t" pending_line; pending_line = 0; pending_tool = 0; pending_kind = 0 }' \
  '  in_heredoc = 0; hd_marker = ""; pending_fname = ""' \
  '}' \
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
  '  if (FNR > 1 && pending_line > 0) {' \
  '    if (index($0, "|| true") > 0 || index($0, "|| echo") > 0 || index($0, ": $?") > 0) {' \
  '      pending_line = 0; pending_tool = 0; pending_kind = 0' \
  '    } else if ($0 ~ /\)[[:space:]]*$/) {' \
  '      if (pending_kind == 1) {' \
  '        if (pending_tool) print pending_fname "\t" pending_line' \
  '      } else {' \
  '        if ($0 ~ /\|[^|]*(grep|awk|sed|head|tail)[^a-zA-Z0-9_]*\)[[:space:]]*$/ || $0 ~ /^[[:space:]]*(grep|awk|sed|head|tail)[^a-zA-Z0-9_].*\)[[:space:]]*$/) print pending_fname "\t" pending_line' \
  '      }' \
  '      pending_line = 0; pending_tool = 0; pending_kind = 0' \
  '    } else if (FNR - pending_line > 40) {' \
  '      if (pending_tool) print pending_fname "\t" pending_line' \
  '      pending_line = 0; pending_tool = 0; pending_kind = 0' \
  '    }' \
  '  }' \
  '  if ($0 ~ /^[[:space:]]*#/) next' \
  '  if (index($0, "=$(") > 0 && $0 ~ /\|[^|]*(grep|awk|sed|head|tail)/) {' \
  '    if (index($0, "|| true") > 0 || index($0, "|| echo") > 0 || index($0, ": $?") > 0) next' \
  '    if ($0 ~ /\)[[:space:]]*$/) { print FILENAME "\t" FNR; next }' \
  '    pending_line = FNR; pending_fname = FILENAME; pending_tool = 1; pending_kind = 1' \
  '  }' \
  '  else if (index($0, "=$(") > 0 && $0 ~ /[^|]\|[[:space:]]*\\[[:space:]]*$/) {' \
  '    if (index($0, "|| true") > 0 || index($0, "|| echo") > 0 || index($0, ": $?") > 0) next' \
  '    pending_line = FNR; pending_fname = FILENAME; pending_tool = 0; pending_kind = 2' \
  '  }' \
  '}' \
  'END { if (pending_line > 0 && pending_tool) print pending_fname "\t" pending_line }' \
  > "$_r8_awk"

_r8_hits=$(awk -f "$_r8_awk" "${SHELL_FILES[@]}" </dev/null 2>/dev/null || true)
rm -f "$_r8_awk"
_r8_awk=""

if [ -n "$_r8_hits" ]; then
  while IFS= read -r _hit; do
    # Tab-separated: file<TAB>linenum — safe for paths containing colons
    _hit_file=$(echo "$_hit" | cut -f1)
    _hit_line=$(echo "$_hit" | cut -f2)
    print_violation "$_hit_file" "$_hit_line" "UNSAFE_PIPE_IN_CMDSUB" \
      "VAR=\$(... | grep/awk/sed/head/tail) without || true can silently kill script under set -euo pipefail"
  done <<< "$_r8_hits"
fi

