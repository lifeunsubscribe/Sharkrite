# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 9: Claude-specific tokens in lib/core/ (Provider Agnosticism)
echo "Checking for Claude-specific tokens in lib/core/ (provider agnosticism)..."
mapfile -t CORE_FILES < <(find "$PROJECT_ROOT/lib/core" -type f -name "*.sh" 2>/dev/null)

# Convert per-file bash while+grep loops to a single AWK pass over all core files.
# AWK processes all files in one invocation, reporting violations as FILE\tLINE\tMSG.
# MSG is a short tag; the outer bash loop maps tags to human messages.
# Tab separator keeps file/line/tag extraction safe for paths containing colons
# (e.g. CI matrix job paths like /home/runner/work/my:project/file.sh).
_r9_hits=$(awk '
FNR == 1 { in_heredoc = 0; hd_marker = "" }
{
  if (in_heredoc) {
    _close = $0; sub(/^[[:space:]]*/, "", _close)
    if (_close == hd_marker) in_heredoc = 0
    next
  }
  # Intentional fall-through after setting in_heredoc=1: the opener line itself
  # is a shell command (e.g. "cmd <<EOF"), not heredoc body, so it must still
  # be checked for provider-specific tokens.
  if (index($0, "<<") > 0) {
    tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)
    gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")
    if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) {
      hd_marker = _p[1]; in_heredoc = 1
    }
  }
  if ($0 ~ /^[[:space:]]*#/) next
  if (index($0, "/exit") > 0) print FILENAME "\t" FNR "\tSLASH_EXIT"
  if (index($0, "--print") > 0) print FILENAME "\t" FNR "\tPRINT_FLAG"
  if (index($0, "--dangerously-skip-permissions") > 0) print FILENAME "\t" FNR "\tDANG_SKIP"
  if (index($0, "--disallowedTools") > 0) print FILENAME "\t" FNR "\tDISALLOWED"
  if (index($0, "tool_use") > 0) print FILENAME "\t" FNR "\tTOOL_USE"
  if ($0 ~ /print_(status|info|error|warning)/ && index($0, "Claude CLI") > 0) print FILENAME "\t" FNR "\tHCPROVIDER"
  if ($0 ~ /print_(status|info|error|warning)/ && index($0, "Claude session") > 0) print FILENAME "\t" FNR "\tHCPROVIDER"
}' "${CORE_FILES[@]}" </dev/null 2>/dev/null || true)

if [ -n "$_r9_hits" ]; then
  while IFS= read -r _hit; do
    # Tab-separated: file<TAB>linenum<TAB>tag — safe for paths containing colons
    _hit_file=$(echo "$_hit" | cut -f1)
    _hit_line=$(echo "$_hit" | cut -f2)
    _hit_tag=$(echo "$_hit" | cut -f3)
    case "$_hit_tag" in
      SLASH_EXIT)  print_violation "$_hit_file" "$_hit_line" "CLAUDE_SPECIFIC_TOKEN" \
        "Provider-specific token '/exit' found in lib/core/ - use provider_exit_instructions() instead" ;;
      PRINT_FLAG)  print_violation "$_hit_file" "$_hit_line" "CLAUDE_SPECIFIC_TOKEN" \
        "Provider-specific flag '--print' found in lib/core/ - this should be in lib/providers/claude.sh" ;;
      DANG_SKIP)   print_violation "$_hit_file" "$_hit_line" "CLAUDE_SPECIFIC_TOKEN" \
        "Provider-specific flag '--dangerously-skip-permissions' found in lib/core/" ;;
      DISALLOWED)  print_violation "$_hit_file" "$_hit_line" "CLAUDE_SPECIFIC_TOKEN" \
        "Provider-specific flag '--disallowedTools' found in lib/core/ - use provider_build_tool_restrictions() instead" ;;
      TOOL_USE)    print_violation "$_hit_file" "$_hit_line" "CLAUDE_SPECIFIC_TOKEN" \
        "Provider-specific term 'tool_use' found in lib/core/" ;;
      HCPROVIDER)  print_violation "$_hit_file" "$_hit_line" "HARDCODED_PROVIDER_NAME" \
        "Hardcoded 'Claude CLI/session' in user-facing output - use \$(provider_name) instead" ;;
    esac
  done <<< "$_r9_hits"
fi

