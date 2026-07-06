# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 13: Raw gh CLI calls not wrapped in gh_safe
# Catches: gh pr ..., gh issue ..., gh api ..., gh repo ..., gh label ..., gh diff ...
# Skips:   gh_safe calls, comment lines, heredoc body lines, gh-retry.sh itself
#
# Heredoc-aware: uses a single-pass AWK program per file to track heredoc open/close
# markers and skip all body lines inside them.  Lines inside a heredoc are not shell
# commands (they may be example scripts, instructional text, or prompt strings passed
# to AI tools) and must not be flagged.
# AWK is used instead of a bash while+grep loop for performance: spawning one grep
# subprocess per line is prohibitively slow on large files (e.g. claude-workflow.sh
# at ~2800 lines would launch ~8000 subprocesses).
echo "Checking for raw 'gh' CLI calls not wrapped in gh_safe..."
_r13_awk=$(mktemp)
# The AWK program is written to a temp file to:
# 1. Avoid shell quoting issues (single-quote literals in AWK regex)
# 2. Ensure BSD AWK (macOS) compatibility: no \< \> word boundaries, no + quantifier,
#    no PATTERN && PATTERN { } compound rules, no !~ operator.
#    All logic uses a single { } action block with if/else and index()/match().
printf '%s\n' \
  '{' \
  '  # Heredoc close: strip leading whitespace before comparing to support' \
  '  # <<-MARKER (tab-indented terminators) — bare terminator exits heredoc mode.' \
  '  if (in_heredoc) {' \
  '    _close = $0; sub(/^[[:space:]]*/, "", _close)' \
  '    if (_close == hd_marker) in_heredoc = 0' \
  '    next' \
  '  }' \
  '  # Heredoc open: detect <<MARKER, <<-MARKER, <<'"'"'MARKER'"'"', <<"MARKER" on this line.' \
  '  # sub strips everything up to << and an optional - (for <<-) so that <<-MARKER' \
  '  # leaves only MARKER in tok (without the leading dash that caused the heredoc' \
  '  # state to be skipped entirely in the old pattern).' \
  '  # Fall through after opening: the line itself is a command, not heredoc body.' \
  '  if (index($0, "<<") > 0) {' \
  '    tok = $0' \
  '    sub(/.*<<-?[[:space:]]*/, "", tok)' \
  '    gsub(/['"'"'"]/, "", tok)' \
  '    split(tok, _p, " ")' \
  '    if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) {' \
  '      hd_marker = _p[1]; in_heredoc = 1' \
  '    }' \
  '  }' \
  '  # Skip full-line comments' \
  '  if ($0 ~ /^[[:space:]]*#/) next' \
  '  # Skip output/print lines (gh in echo/printf is always quoted text, not a call)' \
  '  if ($0 ~ /^[[:space:]]*(echo|printf|print_info|print_status|print_warning|print_error|cat)[[:space:]]/) next' \
  '  # Skip instructional/prose text lines (multi-line prompt bodies, etc.)' \
  '  if ($0 ~ /^[[:space:]]*(Do NOT|Run:|use:|Check if|Example:|example:)/) next' \
  '  # Skip lines with inline (use: ...) markup — these are prompt text, not shell commands' \
  '  if (index($0, "(use:") > 0) next' \
  '  # Flag: gh call for known subcommands not wrapped in gh_safe.' \
  '  # Pattern requires "gh" to be preceded by a command-context character (any whitespace,' \
  '  # (, |, ;, $) or appear at start-of-line after whitespace.  [[:space:]] covers both' \
  '  # spaces and tabs, preventing false negatives for tab-indented gh calls.' \
  '  # Output uses tab as field separator (file\tlinenum) so paths containing colons' \
  '  # (e.g. CI matrix job paths like /home/runner/work/my:project/file.sh) parse correctly.' \
  '  if (index($0, "gh_safe") == 0) {' \
  '    if ($0 ~ /^[[:space:]]*gh[[:space:]][[:space:]]*(pr|issue|api|repo|label|diff)/ ||' \
  '        $0 ~ /[[:space:](|;$]gh[[:space:]][[:space:]]*(pr|issue|api|repo|label|diff)/) {' \
  '      print FILENAME "\t" NR' \
  '    }' \
  '  }' \
  '}' \
  > "$_r13_awk"

for file in "${SHELL_FILES[@]}"; do
  # gh-retry.sh defines gh_safe and intentionally calls raw gh — skip it
  if [[ "$file" == */gh-retry.sh ]]; then
    continue
  fi

  _r13_hits=$(awk -f "$_r13_awk" "$file" 2>/dev/null || true)

  if [ -n "$_r13_hits" ]; then
    while IFS= read -r _hit; do
      # Tab-separated: file<TAB>linenum — safe for paths containing colons
      _hit_file=$(echo "$_hit" | cut -f1)
      _hit_line=$(echo "$_hit" | cut -f2)
      print_violation "$_hit_file" "$_hit_line" "GH_UNSAFE_CALL" \
        "Raw 'gh' call — wrap with gh_safe to get retry/resilience (lib/utils/gh-retry.sh)"
    done <<< "$_r13_hits"
  fi
done
rm -f "$_r13_awk"
_r13_awk=""

