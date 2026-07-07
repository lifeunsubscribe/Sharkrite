#!/bin/bash
# lib/utils/pr-refusal.sh
# Shared PR-number refusal logic — single source of truth for exit-15 guard.
#
# Three entrypoints previously hand-maintained identical copies of this logic:
#   - bin/rite::_reject_if_pr_number()
#   - lib/core/undo-workflow.sh (inline top-level block)
#   - lib/core/workflow-runner.sh::handle_pr_number_refused()
#
# This file provides the canonical implementation. Each caller delegates here
# and then decides exit-vs-return 15 to fit its own context:
#   - bin/rite and undo-workflow.sh: call + `exit 15`  (process exit)
#   - handle_pr_number_refused():    call + `return 15` (function return)
#
# See: docs/architecture/exit-codes.md — exit code 15

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f refuse_if_pr_number >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# refuse_if_pr_number ISSUE_NUMBER [ISSUE_DATA_JSON] [CALLER_VERB]
#
# Checks whether ISSUE_NUMBER resolves to a Pull Request. If it does, prints
# a named-PR error and returns 15. If it does not, returns 0 (caller proceeds
# normally).
#
# Arguments:
#   ISSUE_NUMBER     — the bare number the user supplied
#   ISSUE_DATA_JSON  — (optional) already-fetched JSON from `gh issue view
#                      --json url,title`. When provided, no extra API call is
#                      made. When absent or empty, a fresh fetch is performed.
#   CALLER_VERB      — (optional) verb inserted into the "accepts issue numbers
#                      only" line to match the calling context's phrasing.
#                      Defaults to "rite" → "rite accepts issue numbers only."
#                      Pass e.g. "rite --undo" for the undo entrypoint.
#
# Return values:
#   0  — number is a real issue; caller should continue normally
#   15 — number is a PR; caller should propagate exit/return 15
#
# The caller decides exit vs return:
#   refuse_if_pr_number "$N" "$DATA" || exit 15    # bin/rite, undo-workflow.sh
#   refuse_if_pr_number "$N" "$DATA" || return 15  # handle_pr_number_refused()
# ---------------------------------------------------------------------------
refuse_if_pr_number() {
  local _rpn_number="${1:-}"
  local _rpn_data="${2:-}"
  local _rpn_verb="${3:-rite}"

  # Fetch issue data if not provided by the caller (saves an API round-trip
  # when the caller already has the data from a prior gh issue view call).
  if [ -z "$_rpn_data" ]; then
    _rpn_data=$(gh_safe issue view "$_rpn_number" --json url,title 2>/dev/null || true)
  fi

  local _rpn_url
  _rpn_url=$(echo "$_rpn_data" | jq -r '.url // ""' 2>/dev/null || true)

  # Not a PR — return 0 so the caller continues normally.
  if ! echo "$_rpn_url" | grep -qF '/pull/'; then
    return 0
  fi

  # It is a PR — print the refusal message, then signal via return 15.
  local _rpn_title
  _rpn_title=$(echo "$_rpn_data" | jq -r '.title // "unknown"' 2>/dev/null || true)

  print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  print_error "#${_rpn_number} is a Pull Request, not an issue"
  print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  print_error "  PR title: ${_rpn_title}"
  [ -n "$_rpn_url" ] && print_error "  PR url:   ${_rpn_url}"
  print_error ""
  print_error "${_rpn_verb} accepts issue numbers only. Pass the linked issue number instead."

  # Best-effort: look up the issue this PR closes (non-fatal if the call fails).
  local _rpn_linked=""
  local _rpn_body
  _rpn_body=$(gh_safe pr view "$_rpn_number" --json body --jq '.body' 2>/dev/null || true)
  if [ -n "$_rpn_body" ]; then
    _rpn_linked=$(echo "$_rpn_body" | grep -ioE '(closes|fixes|resolves)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
  fi

  if [ -n "$_rpn_linked" ]; then
    print_error ""
    print_error "  Linked issue: #${_rpn_linked}"
    print_error "  Try: rite ${_rpn_linked}"
  fi

  print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  return 15
}
