#!/bin/bash
# lib/utils/triage-classify.sh — shared diff triage classifier
#
# Two-layer triage of a diff:
#   Layer 1 — deterministic guards (size, deletion, test-weakening, config,
#             security, sensitive paths). Any hit → "substantive", classifier
#             skipped. Catches every dangerous category from the diff alone.
#   Layer 2 — a cheap triage-model classifier on the cleared remainder. Low
#             confidence escalates to "substantive". Fail-safe: anything
#             uncertain or unparseable → "substantive".
#
# So a wrong classifier can only ever cause a (cheap) false-escalate, never a
# (dangerous) false-skip on a guarded category.
#
# Consumers:
#   - lib/core/local-review.sh  → _triage_emit_shadow (calibration logging, #651)
#   - lib/utils/trivial-fix-fastpath.sh → merge gate (#531)
#
# Runtime deps the CALLER must have sourced + initialized before calling:
#   claude_provider_resolve_model, provider_run_prompt (provider-interface +
#   load_provider) for Layer 2; detect_sensitivity_areas (blocker-rules) is
#   optional — guarded by `declare -f`, skipped if absent.

set -euo pipefail

# Re-source guard (function-sentinel; not exported).
if declare -f triage_classify_diff >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# triage_classify_diff <PR_NUMBER> <DIFF> <FILES>
#
# Echoes ONE pipe-delimited line:
#   "<verdict>|<confidence>|<guard>|<reason>|<size_lines>|<category>"
#   verdict ∈ {trivial, substantive}; guard = "none" or the guard that fired.
# PR_NUMBER may be empty (used only by the optional sensitivity guard).
# ---------------------------------------------------------------------------
triage_classify_diff() {
  # `local` declarations hoisted above the brace-heavy classifier prompt/regex so
  # the LOCAL_OUTSIDE_FUNCTION lint rule's brace counter is not unbalanced.
  local _pr="$1" _diff="$2" _files="$3"
  local _added _removed _size _paths _category="logic" _guard="" _sens
  local _verdict="substantive" _conf="1.0" _reason=""
  local _diff_head _tmodel _tprompt _tresp _tjson

  # --- size + category (deterministic, from the diff) ---
  _added=$(echo "$_diff" | grep -cE '^\+[^+]' || true)
  _removed=$(echo "$_diff" | grep -cE '^-[^-]' || true)
  _size=$(( ${_added:-0} + ${_removed:-0} ))

  _paths=$(echo "$_diff" | grep '^diff --git' | sed -E 's|^diff --git a/(.*) b/.*|\1|' || true)
  if [ -n "$_paths" ]; then
    if ! echo "$_paths" | grep -qvE '\.md$|^docs/' ; then _category="docs"
    elif ! echo "$_paths" | grep -qvE '(^|/)tests?/|_test\.|\.test\.|\.bats$' ; then _category="test"
    elif ! echo "$_paths" | grep -qvE '\.(conf|toml|ya?ml|json)$|(^|/)Makefile$|^\.github/|^\.rite/|lock$' ; then _category="config"
    fi
  fi

  # --- Layer 1: deterministic guards (any hit → substantive, classifier skipped) ---
  if [ "${_files:-0}" -ge "${RITE_TRIAGE_MAX_FILES:-3}" ] 2>/dev/null; then _guard="size_files"; fi
  if [ -z "$_guard" ] && [ "${_size:-0}" -ge "${RITE_TRIAGE_MAX_LINES:-30}" ] 2>/dev/null; then _guard="size_lines"; fi
  if [ -z "$_guard" ] && echo "$_diff" | grep -q '^deleted file mode'; then _guard="deletion"; fi
  if [ -z "$_guard" ] && echo "$_diff" | grep -qE '^\+.*(@pytest\.mark\.(skip|xfail)|\bskip\b|\bxfail\b|\.only\(|\bfit\(|\bfdescribe\()'; then _guard="test_weakening"; fi
  if [ -z "$_guard" ] && echo "$_paths" | grep -qE '(^|/)(Makefile|\.shellcheckrc)$|package\.json$|requirements.*\.txt$|lock$|^\.github/|^\.rite/config'; then _guard="config"; fi
  if [ -z "$_guard" ] && echo "$_diff" | grep -qE '^\+.*(\beval\b|\bcurl\b|\bwget\b|subprocess|os\.system|\bexec\b|password|secret|token=|api[_-]?key)'; then _guard="security"; fi
  if [ -z "$_guard" ] && declare -f detect_sensitivity_areas >/dev/null 2>&1; then
    _sens=$(detect_sensitivity_areas "$_pr" 2>/dev/null || true)
    if [ -n "$_sens" ]; then _guard="sensitive"; fi
  fi

  # --- Layer 2: classifier on the cleared remainder ---
  if [ -n "$_guard" ]; then
    _verdict="substantive"; _reason="guard:$_guard"; _conf="1.0"
  else
    # Truncate the diff to keep the triage call cheap/fast.
    _diff_head=$(echo "$_diff" | head -c 6000 || true)
    _tmodel=$(claude_provider_resolve_model "triage")
    _tprompt="You are a code-review TRIAGE classifier. Decide if this diff is TRIVIAL (pure comment/docstring/whitespace edits, version-string bumps, log-message wording, mechanical rename with no logic change, or a purely additive test of existing behavior) or SUBSTANTIVE (any logic, control-flow, error-handling, or behavior change — anything you can't confidently call trivial). When unsure, answer substantive. Output ONLY compact JSON: {\"verdict\":\"trivial|substantive\",\"confidence\":0.0-1.0,\"reason\":\"<=8 words\"}.

DIFF:
$_diff_head"
    _tresp=$(provider_run_prompt "$_tprompt" "$_tmodel" "true" 2>/dev/null || true)
    _tjson=$(echo "$_tresp" | grep -oE '\{[^{}]*"verdict"[^{}]*\}' | head -1 || true)
    if [ -n "$_tjson" ] && echo "$_tjson" | jq -e . >/dev/null 2>&1; then
      _verdict=$(echo "$_tjson" | jq -r '.verdict // "substantive"' 2>/dev/null || echo "substantive")
      _conf=$(echo "$_tjson" | jq -r '.confidence // 0' 2>/dev/null || echo "0")
      _reason=$(echo "$_tjson" | jq -r '.reason // "?"' 2>/dev/null | tr ' |' '__' | head -c 40 || echo "?")
    else
      # Unparseable classifier output → escalate (fail safe toward substantive).
      _verdict="substantive"; _conf="0"; _reason="unparseable"
    fi
    # Confidence gate: low confidence escalates to substantive.
    if [ "$_verdict" = "trivial" ] && awk "BEGIN{exit !(${_conf:-0} < 0.8)}" 2>/dev/null; then
      _verdict="substantive"; _reason="lowconf_${_conf}"
    fi
  fi

  printf '%s|%s|%s|%s|%s|%s\n' "$_verdict" "$_conf" "${_guard:-none}" "${_reason:-}" "${_size:-0}" "$_category"
}
