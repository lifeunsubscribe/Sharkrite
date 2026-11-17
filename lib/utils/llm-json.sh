#!/bin/bash
# lib/utils/llm-json.sh — pull a JSON object out of a model's free-text answer
#
# Classifier prompts ask for "ONLY compact JSON", and the model still wraps the
# object in a code fence, pretty-prints it, or adds prose around it. Callers
# need the object regardless of that packaging.
#
# The object is found by PARSING, not by a regex over the text (#1824). The
# earlier per-caller regex matched only an object with no brace anywhere in its
# body, so any answer whose string values contained a brace was a parse error —
# a reason quoting JSX (`tabIndex={isPending ? -1 : 0}`) failed every reconcile
# pass for the same pool entry (freshup pool 553, 2026-11-15 to 11-17).
#
# Consumers:
#   - lib/utils/reconcile-followups.sh → _classify_finding
#   - lib/utils/triage-classify.sh     → triage_classify_diff

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f llm_extract_json_object >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# llm_extract_json_object TEXT KEY
#
# Print (compact, one line) the first JSON object in TEXT that has KEY as a
# top-level field. Prints nothing when there is none. Always returns 0 — an
# empty result is the caller's "unparseable" signal.
#
# Every `{` is tried as a start and every later `}` as an end; the first span
# that jq parses as an object carrying KEY wins. Braces inside string values
# are therefore harmless. Candidates are bounded (64 starts × 64 ends) so a
# brace-heavy answer cannot turn the search quadratic.
# ---------------------------------------------------------------------------
llm_extract_json_object() {
  local _text="${1:-}" _key="${2:-}"
  if [ -z "$_text" ] || [ -z "$_key" ]; then
    return 0
  fi
  # explode/implode keep the indexes in codepoints; string indices() is
  # byte-based in jq 1.6 and would misalign after any non-ASCII character.
  jq -Rrsc --arg key "$_key" '
    explode as $c
    | [range(0; $c | length) | select($c[.] == 123)][0:64] as $opens
    | [range(0; $c | length) | select($c[.] == 125)] as $closes
    | first(
        $opens[] as $i
        | ([$closes[] | select(. > $i)][0:64])[] as $j
        | ($c[$i:$j + 1] | implode | try fromjson catch empty)
        | select(type == "object" and has($key))
      ) // empty
  ' <<< "$_text" 2>/dev/null || true
}
