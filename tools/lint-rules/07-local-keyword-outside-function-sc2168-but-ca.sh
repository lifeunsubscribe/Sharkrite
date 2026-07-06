# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 7: local keyword outside function (SC2168 - but catch our own)
# Uses AWK for performance — the bash while+grep approach spawned thousands
# of subprocesses per file (one grep per line × 3-5 checks × N lines).
echo "Checking for 'local' outside function scope..."
_r7_hits=$(awk '
FNR == 1 { depth = 0; in_heredoc = 0; hd_marker = "" }
{
  # Heredoc close: when inside heredoc, skip until terminator line.
  # Strip leading whitespace before comparing to support <<-MARKER (tab-indented terminators).
  if (in_heredoc) {
    _close = $0; sub(/^[[:space:]]*/, "", _close)
    if (_close == hd_marker) in_heredoc = 0
    next
  }
  # Heredoc open: detect <<MARKER and <<-MARKER on this line.
  # sub strips everything up to and including <<  and an optional - (for <<-).
  # Intentional fall-through after setting in_heredoc=1: the opener line itself
  # is a shell command (e.g. "cat <<EOF"), not heredoc body, so it must still
  # be checked for local usage and brace depth.
  if (index($0, "<<") > 0) {
    tok = $0
    sub(/.*<<-?[[:space:]]*/, "", tok)
    gsub(/['"'"'"]/, "", tok)
    split(tok, _p, " ")
    if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) {
      hd_marker = _p[1]; in_heredoc = 1
    }
  }
  # Skip comments
  if ($0 ~ /^[[:space:]]*#/) next
  # Count { and } on this line to track nesting depth.
  # gsub returns the replacement count, allowing us to count characters without
  # a per-char loop (fast, BSD AWK compatible, heredoc-safe).
  # Strip string literals before counting so braces inside strings, ${param}
  # expansions, and {a,b} brace-expansions in quoted arguments do not skew depth.
  # Single-quoted strings have no escape sequences in bash, so the regex is exact.
  # Double-quoted strings use a heuristic that misses backslash-escaped quotes --
  # accepted for a lint heuristic; a full parser is out of scope.
  # ${...} parameter expansions are also stripped: their braces always net to zero
  # but stripping them avoids false depth drift on complex default expansions.
  _stripped = $0
  gsub(/'"'"'[^'"'"']*'"'"'/, "", _stripped)
  gsub(/"[^"]*"/, "", _stripped)
  gsub(/\$\{[^}]*\}/, "", _stripped)
  # Use _stripped copies so $0 is not modified (detection check still uses $0).
  _tmp = _stripped; _ob = gsub(/{/, "", _tmp)
  _tmp = _stripped; _cb = gsub(/}/, "", _tmp)
  depth += _ob - _cb
  if (depth < 0) depth = 0
  # Flag: "local" keyword used at depth 0 (outside any function)
  # Use tab as field separator so paths containing colons (e.g. CI matrix job
  # paths like /home/runner/work/my:project/file.sh) parse correctly.
  if (depth == 0 && $0 ~ /^[[:space:]]*local[[:space:]]/) {
    print FILENAME "\t" FNR
  }
}' "${SHELL_FILES[@]}" </dev/null 2>/dev/null || true)

if [ -n "$_r7_hits" ]; then
  while IFS= read -r _hit; do
    # Tab-separated: file<TAB>linenum — safe for paths containing colons
    _hit_file=$(echo "$_hit" | cut -f1)
    _hit_line=$(echo "$_hit" | cut -f2)
    print_violation "$_hit_file" "$_hit_line" "LOCAL_OUTSIDE_FUNCTION" \
      "'local' keyword used outside function (only works inside functions)"
  done <<< "$_r7_hits"
fi

