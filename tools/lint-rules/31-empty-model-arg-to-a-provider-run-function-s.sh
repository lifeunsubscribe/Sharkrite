# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 31: Empty "" model arg to a provider run function (silent fall-through to review)
# provider_run_prompt / provider_run_prompt_with_timeout / provider_run_streaming_prompt
# all map an empty model arg to claude_provider_resolve_model "review" (opus). Passing ""
# silently couples the caller to the review model — the exact defect that put `rite plan`
# (and doc classification) on opus via the review default. Every caller must pass an
# explicit role, e.g. "$(provider_resolve_model plan)". The "" is the 2nd positional
# (model) in all three functions.
echo "Checking for empty \"\" model args to provider run functions (PROVIDER_MODEL_FALLTHROUGH)..."
for file in "${SHELL_FILES[@]}"; do
  _r31_hits=$(grep -nE 'provider_run_(streaming_)?prompt(_with_timeout)?[[:space:]]+"[^"]*"[[:space:]]+""' "$file" 2>/dev/null || true)
  [ -z "$_r31_hits" ] && continue
  while IFS= read -r _hit; do
    [ -z "$_hit" ] && continue
    _hit_line=$(echo "$_hit" | cut -d: -f1)
    _hit_content=$(echo "$_hit" | cut -d: -f2-)
    # Skip comment lines (the pattern could appear in documentation examples)
    echo "$_hit_content" | grep -qE '^[[:space:]]*#' && continue
    # Inline suppression on the preceding line
    _prev_line=$(sed -n "$((_hit_line - 1))p" "$file" 2>/dev/null || true)
    echo "$_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*PROVIDER_MODEL_FALLTHROUGH' && continue
    print_violation "$file" "$_hit_line" "PROVIDER_MODEL_FALLTHROUGH" \
      "Empty \"\" model arg falls through to the review model (opus) — pass an explicit role, e.g. \"\$(provider_resolve_model <role>)\""
  done <<< "$_r31_hits"
done

