# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 31: Empty "" model arg to a provider run function (silent fall-through to review)
# provider_run_prompt / provider_run_prompt_with_timeout / provider_run_streaming_prompt
# all map an empty model arg to claude_provider_resolve_model "review" (opus). Passing ""
# silently couples the caller to the review model — the exact defect that put `rite plan`
# (and doc classification) on opus via the review default. Every caller must pass an
# explicit role, e.g. "$(provider_resolve_model plan)". The "" is the 2nd positional
# (model) in all three functions.
#
# The first arg is tokenized rather than regex-matched: a regex like "[^"]*"
# cannot see past nested quotes, so `provider_run_prompt "$(cat "$f")" ""`
# slipped through — six bootstrap-docs.sh calls and normalize-issue.sh ran on
# the review model (fable in that config) until 2026-10-21.
echo "Checking for empty \"\" model args to provider run functions (PROVIDER_MODEL_FALLTHROUGH)..."
# Print "lineno:content" for every call whose 2nd shell word is exactly "".
# Word 1 is walked char by char: double quotes toggle, $( ... ) nests with its
# own quote context, backslash escapes the next char.
_r31_awk='
{
  line = $0
  if (!match(line, /provider_run_(streaming_)?prompt(_with_timeout)?[[:space:]]+/)) next
  i = RSTART + RLENGTH; n = length(line); inq = 0; depth = 0
  while (i <= n) {
    c = substr(line, i, 1)
    if (c == "\\") { i += 2; continue }
    if (c == "$" && substr(line, i + 1, 1) == "(") { saved[++depth] = inq; inq = 0; i += 2; continue }
    if (c == ")" && depth > 0 && !inq) { inq = saved[depth--]; i++; continue }
    if (c == "\"") { inq = !inq; i++; continue }
    if (!inq && depth == 0 && (c == " " || c == "\t")) break
    i++
  }
  while (i <= n && (substr(line, i, 1) == " " || substr(line, i, 1) == "\t")) i++
  if (substr(line, i, 2) == "\"\"") {
    nx = substr(line, i + 2, 1)
    if (nx == "" || nx == " " || nx == "\t" || nx == ")" || nx == ";") print NR ":" line
  }
}'
for file in "${SHELL_FILES[@]}"; do
  _r31_hits=$(awk "$_r31_awk" "$file" 2>/dev/null || true)
  [ -z "$_r31_hits" ] && continue
  while IFS= read -r _hit; do
    [ -z "$_hit" ] && continue
    # Single-file awk output is "lineno:content" — no filename field, so
    # colon-cut cannot mangle paths (only multi-file AWK output needs tab cuts).
    # sharkrite-lint-safe: single-file
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

