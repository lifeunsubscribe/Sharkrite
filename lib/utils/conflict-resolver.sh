#!/bin/bash
# lib/utils/conflict-resolver.sh
# Claude-assisted merge conflict resolution.
#
# Entry condition:
#   Caller may invoke from either a merge-conflict state OR a clean tree (e.g. after
#   aborting a rebase/merge). Step 3 re-runs git merge to recreate conflict markers.
#   This file does NOT commit, push, run tests, or print to stdout.
#
# Exit codes (public contract — do NOT change without updating all call sites):
#   0 = all conflicts resolved and staged (ready for git commit --no-edit)
#   1 = failed (merge aborted, working tree returned to clean state)
#   5 = provider usage cap reached (propagate to batch abort — do NOT fall back)
#
# Output: stderr only — stdout is reserved for pipe data per project convention.
#
# Invocation styles (both accepted):
#   Positional: attempt_claude_merge_resolution BRANCH ISSUE_NUMBER PR_NUMBER
#   Named:      attempt_claude_merge_resolution --branch-name B --issue-number N --pr-number P

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f attempt_claude_merge_resolution >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

# Source gh retry wrapper for resilient GitHub API calls
if ! declare -f gh_safe >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/gh-retry.sh"
fi

# Source timeout wrapper (needed by provider agentic sessions).
# config.sh may skip this when RITE_LIB_DIR is pre-set.
if [ -f "$RITE_LIB_DIR/utils/timeout.sh" ] && ! declare -f run_with_timeout >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/timeout.sh"
fi

# ===================================================================
# OUTPUT HELPERS (stderr only — stdout reserved for pipe data)
# ===================================================================

_cr_info()    { echo "ℹ️  $1" >&2; }
_cr_warning() { echo "⚠️  $1" >&2; }
_cr_error()   { echo "❌ $1" >&2; }
_cr_status()  { echo "$1" >&2; }

# ===================================================================
# PUBLIC: attempt_claude_merge_resolution
# ===================================================================

# attempt_claude_merge_resolution [OPTIONS]
#
# Attempts to resolve merge conflicts using an agentic Claude session.
# May be called from a clean tree (e.g. after a caller aborts rebase/merge) or
# from an active conflict state. Step 3 re-runs git merge to recreate conflict
# markers regardless of entry state.
#
# Options (all optional):
#   --issue-number NUM    GitHub issue number
#   --issue-desc TEXT     Issue title/description
#   --pr-number NUM       GitHub PR number
#   --branch-name NAME    Branch name (derived from HEAD if omitted)
#   --merge-target REF    What we're merging (default: origin/main)
#   --timeout SECONDS     Agentic session timeout (default: RITE_FIX_TIMEOUT or 1800)
#
# Returns:
#   0 = all conflicts resolved and staged (not committed)
#   1 = failed (merge aborted, working tree clean)
#
# Side effects:
#   - Loads dev provider (caller must reload their provider after if needed)
#   - On success: merge is resolved and staged, ready for git commit --no-edit
#   - On failure: merge is aborted, working tree is clean
attempt_claude_merge_resolution() {
  local _cr_issue_number=""
  local _cr_issue_desc=""
  local _cr_pr_number=""
  local _cr_branch_name=""
  local _cr_merge_target="origin/main"
  local _cr_timeout="${RITE_FIX_TIMEOUT:-1800}"
  local _cr_diff_lines="${RITE_CONFLICT_DIFF_LINES:-200}"

  # Parse arguments — accept both named flags and positional form:
  #   Positional: attempt_claude_merge_resolution BRANCH ISSUE_NUMBER PR_NUMBER
  #   Named:      --branch-name B --issue-number N --pr-number P
  # Positional detection: first arg doesn't start with '--'
  if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then
    # Positional form
    _cr_branch_name="${1:-}"
    _cr_issue_number="${2:-}"
    _cr_pr_number="${3:-}"
  else
    # Named flags
    while [ $# -gt 0 ]; do
      case "$1" in
        --issue-number) _cr_issue_number="$2"; shift 2 ;;
        --issue-desc)   _cr_issue_desc="$2"; shift 2 ;;
        --pr-number)    _cr_pr_number="$2"; shift 2 ;;
        --branch-name)  _cr_branch_name="$2"; shift 2 ;;
        --merge-target) _cr_merge_target="$2"; shift 2 ;;
        --timeout)      _cr_timeout="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
  fi

  # Derive branch name if not provided
  if [ -z "$_cr_branch_name" ]; then
    _cr_branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  fi

  # ── Step 1: Check for any active conflict state ──
  # Callers may invoke us from a clean tree (they aborted the rebase/merge before
  # calling, which is the common pattern in stale-branch.sh and divergence-handler.sh).
  # We record files here if we're mid-merge — Step 2 aborts it and gathers context,
  # then Step 3 re-runs the merge to recreate conflict markers for Claude.
  # After Step 3 re-creates the conflict, we refresh _cr_conflict_files from the live state.
  local _cr_conflict_files
  _cr_conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)

  # ── Step 2: Abort any in-progress merge and gather context ──
  # No-op when called from a clean tree (the common caller pattern).
  git merge --abort 2>/dev/null || true

  # Convert the newline-delimited conflict-file list to an array so that each
  # file path is passed as a distinct, properly-quoted argument to git commands.
  # Using a while-read loop (not mapfile) for bash 3.2 compatibility.
  # When _cr_conflict_files is empty the loop body never runs, leaving the array empty.
  local _cr_conflict_files_arr=()
  while IFS= read -r _cr_f; do
    [ -n "$_cr_f" ] && _cr_conflict_files_arr+=("$_cr_f")
  done <<< "$_cr_conflict_files"

  # Gather context diffs before Step 3 re-runs the merge.
  # If _cr_conflict_files is empty (clean-tree entry), these diffs will be based
  # on all files changed between HEAD and merge target — still useful context for Claude.
  # When the array is non-empty, pass "-- file1 file2 ..." with each path quoted.
  local _cr_branch_diff=""
  if [ "${#_cr_conflict_files_arr[@]}" -gt 0 ]; then
    _cr_branch_diff=$(git diff "${_cr_merge_target}...HEAD" -- "${_cr_conflict_files_arr[@]}" 2>/dev/null | head -"$_cr_diff_lines" || echo "")
  else
    _cr_branch_diff=$(git diff "${_cr_merge_target}...HEAD" 2>/dev/null | head -"$_cr_diff_lines" || echo "")
  fi

  # Main's commits and diff to conflicting files since branch diverged
  local _cr_merge_base
  _cr_merge_base=$(git merge-base HEAD "$_cr_merge_target" 2>/dev/null || echo "")
  local _cr_main_log=""
  local _cr_main_diff=""
  if [ -n "$_cr_merge_base" ]; then
    if [ "${#_cr_conflict_files_arr[@]}" -gt 0 ]; then
      _cr_main_log=$(git log --oneline "${_cr_merge_base}..${_cr_merge_target}" -- "${_cr_conflict_files_arr[@]}" 2>/dev/null | head -20 || echo "")
      _cr_main_diff=$(git diff "${_cr_merge_base}..${_cr_merge_target}" -- "${_cr_conflict_files_arr[@]}" 2>/dev/null | head -"$_cr_diff_lines" || echo "")
    else
      _cr_main_log=$(git log --oneline "${_cr_merge_base}..${_cr_merge_target}" 2>/dev/null | head -20 || echo "")
      _cr_main_diff=$(git diff "${_cr_merge_base}..${_cr_merge_target}" 2>/dev/null | head -"$_cr_diff_lines" || echo "")
    fi
  fi

  # PR context (if available)
  local _cr_pr_title="" _cr_pr_body=""
  if [ -n "$_cr_pr_number" ]; then
    _cr_pr_title=$(gh_safe pr view "$_cr_pr_number" --json title --jq '.title' 2>/dev/null || echo "")
    _cr_pr_body=$(gh_safe pr view "$_cr_pr_number" --json body --jq '.body' 2>/dev/null || echo "")
  fi

  # Issue context (if available and no PR)
  local _cr_issue_title=""
  if [ -n "$_cr_issue_number" ] && [ -z "$_cr_pr_number" ]; then
    _cr_issue_title=$(gh_safe issue view "$_cr_issue_number" --json title --jq '.title' 2>/dev/null || echo "${_cr_issue_desc:-}")
  fi

  # ── Step 3: Re-start merge so Claude sees conflict markers ──
  if git merge "$_cr_merge_target" --no-edit 2>/dev/null; then
    # Merge succeeded — no conflicts to resolve
    _cr_info "Merge succeeded — no conflict resolution needed"
    return 0
  fi

  # Refresh conflict files from the live merge state (covers the case where Step 1
  # found none because the caller had already aborted before invoking us).
  _cr_conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
  if [ -z "$_cr_conflict_files" ]; then
    _cr_error "Merge failed but no unmerged files found — unexpected state"
    git merge --abort 2>/dev/null || true
    return 1
  fi

  _cr_status "Conflicts to resolve via Claude:" >&2
  echo "$_cr_conflict_files" | sed 's/^/  /' >&2

  # ── Step 4: Build prompt ──
  local _cr_prompt="You are in a git worktree with merge conflicts that need resolution.

main is the source of truth. It represents accepted, merged work. This branch is the newcomer.
Your job: rebase this branch's INTENT onto main's current reality.

After resolving each file, stage it with 'git add <file>'.

RULES:
- Do NOT run git commit, git push, or any gh commands.
- main wins on structure: if main changed an API contract, function signature, config schema,
  database model, or interface — adopt main's version. Then adapt this branch's changes to work
  with main's structure.
- Preserve this branch's intent, not its exact code. If main restructured code that this branch
  also modified, re-implement the branch's purpose on top of main's new structure.
- NEVER create dual code paths, compatibility shims, or 'detect and route' patterns to avoid
  choosing between the two sides. Pick main's structure, apply the branch's feature to it.
- If both sides added genuinely independent, non-overlapping features (different functions,
  different endpoints, different config keys), include both.
- When unsure which side should win for a specific conflict, prefer main's version — it is
  safer to under-apply the branch than to break accepted work."

  # Append context sections based on what's available
  if [ -n "$_cr_pr_number" ] && [ -n "$_cr_pr_title" ]; then
    _cr_prompt+="

## This PR (#${_cr_pr_number}): ${_cr_pr_title}
${_cr_pr_body:-}"
  elif [ -n "$_cr_issue_number" ]; then
    _cr_prompt+="

## Issue #${_cr_issue_number}: ${_cr_issue_title:-${_cr_issue_desc:-}}"
  fi

  _cr_prompt+="

## This branch's changes to the conflicting files:
\`\`\`
${_cr_branch_diff:-No diff available}
\`\`\`

## Commits on ${_cr_merge_target} that touched these files since branch diverged:
${_cr_main_log:-No commits found}

## ${_cr_merge_target}'s diff to conflicting files:
\`\`\`
${_cr_main_diff:-No diff available}
\`\`\`

## Conflicting files to resolve:
${_cr_conflict_files}

Read each conflicting file now. The files contain conflict markers (<<<<<<< HEAD, =======, >>>>>>>).
Resolve every conflict, then stage each file with git add."

  # ── Step 5: Load dev provider and run agentic session ──
  source "$RITE_LIB_DIR/providers/provider-interface.sh"
  load_provider "${RITE_DEV_PROVIDER:-claude}"

  _cr_status "Running Claude conflict resolution session..." >&2

  # Use a temp file for stderr so we can diagnose failures
  local _cr_stderr_file
  _cr_stderr_file=$(mktemp)

  local _cr_session_exit=0
  provider_run_agentic_session "$_cr_prompt" "$_cr_timeout" true "$_cr_stderr_file" || _cr_session_exit=$?

  # Check for usage cap — provider_run_agentic_session sets exit 5 for usage cap
  # (see claude.sh:156-160). provider_detect_error never returns "USAGE_CAP" (only
  # PROVIDER_BUG|RATE_LIMITED|AUTH_EXPIRED|NETWORK_ERROR|UNKNOWN), so the real signal
  # is the exit code itself. Check exit code first; also check stderr for belt-and-suspenders.
  if [ "$_cr_session_exit" -eq 5 ]; then
    rm -f "$_cr_stderr_file"
    _cr_error "Provider usage cap reached during conflict resolution"
    return 5
  fi

  if [ "$_cr_session_exit" -ne 0 ]; then
    _cr_warning "Conflict resolution session exited with code $_cr_session_exit"
    if [ -s "$_cr_stderr_file" ]; then
      _cr_info "Session stderr:" >&2
      head -5 "$_cr_stderr_file" >&2
    fi
  fi
  if [ "$_cr_session_exit" -eq 124 ]; then
    _cr_warning "Conflict resolution session timed out"
  fi
  rm -f "$_cr_stderr_file"

  # ── Step 6: Verify resolution ──

  # Check 1: No remaining unmerged files
  local _cr_remaining
  _cr_remaining=$(git diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')
  if [ "${_cr_remaining:-0}" -ne 0 ]; then
    _cr_error "Unresolved files remain after Claude session"
    git merge --abort 2>/dev/null || true
    return 1
  fi

  # Check 2: No literal conflict markers in resolved files (belt-and-suspenders)
  #
  # Regex anchors each marker precisely to avoid false positives:
  #   <<<<<<<[[:space:]] — conflict open-marker always followed by a space + branch name
  #   =======$           — conflict separator is exactly 7 '=' alone on the line;
  #                        avoids false-positives from markdown setext underlines
  #                        (e.g. "========") or doc separators (e.g. "=======foo")
  #   >>>>>>>[[:space:]] — conflict close-marker always followed by a space + branch name
  #   |||||||[[:space:]] — diff3/zdiff3 base-version marker always followed by a space;
  #                        produced by merge.conflictstyle=diff3 or zdiff3
  #
  # CR-strip (tr -d '\r') before matching: a CRLF-line-ending file ends the
  # separator line with "=======\r", which the anchored "=======$" misses, so a
  # Windows-line-ending conflict file would slip the check and a bad resolution
  # would be accepted (#533). Stripping CR keeps the regex exactly as documented
  # (no relaxed anchor → no trailing-space false positives) and is portable —
  # unlike '\r?', which GNU grep -E treats as a literal 'r'.
  local _cr_marker_found=false
  while IFS= read -r _cr_f; do
    [ -z "$_cr_f" ] && continue
    if tr -d '\r' < "$_cr_f" 2>/dev/null | grep -qE '^(<<<<<<<[[:space:]]|=======$|>>>>>>>[[:space:]]|\|\|\|\|\|\|\|[[:space:]])'; then
      _cr_error "Conflict markers remain in: $_cr_f"
      _cr_marker_found=true
    fi
  done <<< "$_cr_conflict_files"

  if [ "$_cr_marker_found" = true ]; then
    _cr_error "Claude staged files with unresolved conflict markers"
    git merge --abort 2>/dev/null || true
    return 1
  fi

  # Resolution verified — files are staged, ready for commit
  return 0
}
