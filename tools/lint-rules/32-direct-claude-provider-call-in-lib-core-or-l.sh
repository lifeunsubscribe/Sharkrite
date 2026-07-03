# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 32: Direct claude_provider_* call in lib/core or lib/utils (provider agnosticism)
# lib/core and lib/utils must be provider-agnostic: they call the provider_* aliases that
# load_provider wires up, NOT the claude-prefixed implementations directly. A direct
# claude_provider_* call breaks the moment a non-claude provider is loaded. Rule 9 catches
# claude-specific CLI *flags* in lib/core but not claude_provider_* *function* calls, and it
# never scanned lib/utils — this rule closes both gaps. (adr-generator.sh, triage-classify.sh,
# and assess-documentation.sh all leaked this way — the resolver calls were the last ones.)
# Comments and heredoc bodies are exempt (the same skip logic as Rule 9).
echo "Checking for direct claude_provider_* calls in lib/core and lib/utils (DIRECT_PROVIDER_CALL)..."
# Scope: lib/core/*.sh and lib/utils/*.sh (path-filtered from SHELL_FILES so
# RITE_LINT_EXTRA_DIRS fixtures with a lib/core|lib/utils path segment are covered).
mapfile -t AGNOSTIC_SCAN_FILES < <(printf '%s\n' "${SHELL_FILES[@]}" | grep -E '/lib/(core|utils)/[^/]*\.sh$' || true)
_r32_hits=""
if [ "${#AGNOSTIC_SCAN_FILES[@]}" -gt 0 ]; then
  _r32_hits=$(awk '
FNR == 1 { in_heredoc = 0; hd_marker = "" }
{
  if (in_heredoc) {
    _close = $0; sub(/^[[:space:]]*/, "", _close)
    if (_close == hd_marker) in_heredoc = 0
    next
  }
  if (index($0, "<<") > 0) {
    tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)
    gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")
    if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) { hd_marker = _p[1]; in_heredoc = 1 }
  }
  if ($0 ~ /^[[:space:]]*#/) next
  if ($0 ~ /claude_provider_/) print FILENAME "\t" FNR
}' "${AGNOSTIC_SCAN_FILES[@]}" </dev/null 2>/dev/null || true)
fi
if [ -n "$_r32_hits" ]; then
  while IFS= read -r _hit; do
    [ -z "$_hit" ] && continue
    _hit_file=$(echo "$_hit" | cut -f1)
    _hit_line=$(echo "$_hit" | cut -f2)
    _prev_line=$(sed -n "$((_hit_line - 1))p" "$_hit_file" 2>/dev/null || true)
    echo "$_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*DIRECT_PROVIDER_CALL' && continue
    print_violation "$_hit_file" "$_hit_line" "DIRECT_PROVIDER_CALL" \
      "Direct claude_provider_* call in lib/core|lib/utils — use the provider-agnostic alias (drop the 'claude_' prefix, e.g. provider_resolve_model) so a provider swap doesn't break this"
  done <<< "$_r32_hits"
fi


