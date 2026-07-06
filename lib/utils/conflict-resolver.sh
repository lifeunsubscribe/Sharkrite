#!/bin/bash
# lib/utils/conflict-resolver.sh
# Claude-assisted merge conflict resolution.
#
# Entry condition:
#   Caller may invoke from either a merge-conflict state OR a clean tree (e.g. after
#   aborting a rebase/merge). Step 3 re-runs git merge to recreate conflict markers.
#   This file does NOT push, run tests, or print to stdout.
#
# Handoff contract (issues #858, #871): the resolver SESSION only WRITES resolved
# file content — in-session git side effects are policy-blocked for agentic sessions,
# so resolved content may be left unstaged (or even untracked, in the add/add
# materialization path, which also leaves a staged deletion at the same path).
# The SCRIPT side owns staging and committing: after attempt_claude_merge_resolution
# returns 0, callers MUST run commit_resolved_conflicts() (defined below), which
# stages via scoped `git add -- <conflict-paths>` (set from _RITE_RESOLVER_CONFLICT_PATHS,
# populated before the session; falls back to `git add -A` for direct callers),
# detects the live rebase/merge/plain context, and continues/commits accordingly —
# surfacing git's stderr on failure.
#
# Exit codes (public contract — do NOT change without updating all call sites):
#   0 = all conflicts resolved in the working tree (NOT necessarily staged or
#       committed — callers must complete the handoff via commit_resolved_conflicts)
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
# ADD/ADD OVERWRITE-COLLISION DETECTION (issue #783)
# ===================================================================
#
# When two branches independently CREATE different files at the SAME path,
# the stash → rebase → stash-pop flow (stale-branch.sh) fails with ZERO
# unmerged entries: git refuses to overwrite the now-tracked file with the
# stashed/untracked version ("already exists, no checkout" / "would be
# overwritten by merge"). This is NOT a 3-way content conflict, so the
# `--diff-filter=U` signal the resolver keys off is empty. Without explicit
# detection the resolver mistakes this for either "merge succeeded" or the
# generic "unexpected state" bail — surfacing nothing actionable.
#
# Detection has two independent signals (either is sufficient):
#   1. git output matches the overwrite/untracked-collision signatures
#   2. a preserved stash holds an untracked file at a path that the current
#      tree now TRACKS (the realistic stale-branch case: the colliding stash
#      is left un-popped, so the resolver's own `git merge` reports
#      "Already up to date" and there is no git error text to inspect).

# _cr_output_signals_overwrite_collision OUTPUT
# Returns 0 if the captured git output text matches a known overwrite/untracked
# collision signature, 1 otherwise.
_cr_output_signals_overwrite_collision() {
  local _out="${1:-}"
  [ -z "$_out" ] && return 1
  echo "$_out" | grep -qiE 'already exists, no checkout|would be overwritten by (merge|checkout)|untracked working tree files would be overwritten'
}

# _cr_stash_untracked_collision_paths
# Prints (newline-delimited) the paths held as UNTRACKED files in the most
# recent stash that ALSO already exist (tracked or present) in the current
# working tree — i.e. a same-path add/add collision that blocked a stash pop.
# Prints nothing when there is no stash, or no colliding untracked path.
# Conservative: only files git records as untracked-in-stash are considered.
_cr_stash_untracked_collision_paths() {
  git rev-parse --verify --quiet refs/stash >/dev/null 2>&1 || return 0
  local _untracked
  # `stash show --include-untracked --name-only` lists ALL files in the stash
  # (tracked + untracked); we only want the untracked ones, which are the only
  # ones that produce the "already exists, no checkout" pop failure. Diff the
  # untracked-only commit (stash@{0}^3) against its parent to get exactly the
  # untracked set. Falls back to empty when the stash has no untracked part.
  _untracked=$(git show --name-only --pretty=format: 'stash@{0}^3' 2>/dev/null || true)
  while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    # Colliding only if the path now exists in the working tree (it would be
    # clobbered by the pop). A tracked-and-present file is the add/add case.
    if [ -e "$_p" ]; then
      printf '%s\n' "$_p"
    fi
  done <<< "$_untracked"
}

# _cr_materialize_addadd_conflict PATH
# Turns a detected same-path add/add collision into a real in-file 3-way
# conflict so the existing LLM resolution flow (Step 4-6) can content-merge it.
# The current on-disk version (main/HEAD's file) becomes the HEAD side; the
# stashed untracked version becomes the incoming side. The file is left with
# standard conflict markers and recorded as unmerged in the index, exactly as
# `git merge` would for a tracked add/add conflict — so the downstream verify
# checks (Check 1 + Check 2) validate the LLM's resolution identically.
# Returns 0 on success (an unmerged conflict now exists), 1 if it could not
# reconstruct both sides (caller should fall back to surfacing both versions).
_cr_materialize_addadd_conflict() {
  local _path="$1"
  [ -z "$_path" ] && return 1
  # The incoming (branch) version lives in the untracked part of the stash.
  local _incoming
  _incoming=$(git show "stash@{0}^3:$_path" 2>/dev/null || true)
  # The current (main/HEAD) version is on disk now.
  [ -f "$_path" ] || return 1
  local _ours
  _ours=$(cat "$_path" 2>/dev/null || true)
  # Reconstruct standard conflict markers (HEAD = current/main, incoming = branch).
  {
    printf '<<<<<<< HEAD\n'
    printf '%s\n' "$_ours"
    printf '=======\n'
    printf '%s\n' "$_incoming"
    printf '>>>>>>> stash (branch %s)\n' "${_cr_branch_name:-incoming}"
  } > "$_path" || return 1
  # Mark the path unmerged in the index so the standard verify path applies.
  # Best-effort: if the index update fails, the in-file markers still let the
  # LLM resolve, and Check 2 (marker scan) will validate.
  git rm --cached --quiet "$_path" 2>/dev/null || true
  return 0
}

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
#   0 = all conflicts resolved in the working tree (caller must stage + commit
#       via commit_resolved_conflicts — the session cannot run git side effects)
#   1 = failed (merge aborted, working tree clean)
#
# Side effects:
#   - Loads dev provider (caller must reload their provider after if needed)
#   - On success: resolved content is in the working tree; staging state varies
#     (the add/add materialization path leaves resolved content untracked with a
#     staged deletion at the same path). Run commit_resolved_conflicts next.
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
  # Capture merge output (stdout+stderr) so we can distinguish a genuine
  # success from an overwrite/untracked add/add collision (issue #783).
  local _cr_merge_output _cr_merge_exit=0
  _cr_merge_output=$(git merge "$_cr_merge_target" --no-edit 2>&1) || _cr_merge_exit=$?

  if [ "$_cr_merge_exit" -eq 0 ]; then
    # git reports success — but a same-path add/add collision can hide here:
    # in the stale-branch flow the branch is already rebased onto main, so this
    # merge is "Already up to date" while the colliding branch file sits
    # un-popped in the stash. Detect and convert it to a resolvable conflict.
    local _cr_addadd_paths
    _cr_addadd_paths=$(_cr_stash_untracked_collision_paths || true)
    if [ -n "$_cr_addadd_paths" ]; then
      _cr_warning "Same-path add/add collision detected (stashed branch file overwrites a now-tracked path)"
      echo "$_cr_addadd_paths" | sed 's/^/  /' >&2
      local _cr_materialized=false
      while IFS= read -r _cr_ap; do
        [ -z "$_cr_ap" ] && continue
        if _cr_materialize_addadd_conflict "$_cr_ap"; then
          _cr_materialized=true
        fi
      done <<< "$_cr_addadd_paths"
      if [ "$_cr_materialized" = true ]; then
        _cr_conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
        # Materialized files are removed-from-index (git rm --cached); pick them
        # up via the working-tree path list when --diff-filter=U is empty.
        if [ -z "$_cr_conflict_files" ]; then
          _cr_conflict_files="$_cr_addadd_paths"
        fi
        _cr_info "Routing same-path add/add collision to content merge"
      else
        # Could not reconstruct both sides — surface them clearly instead of bailing.
        _cr_error "Same-path add/add collision at: $(echo "$_cr_addadd_paths" | tr '\n' ' ')"
        _cr_error "Two independently-created versions exist at the same path; a content merge is required (run 'git stash show -p' to inspect the branch version)."
        return 1
      fi
    else
      # Genuine success — no conflicts to resolve
      _cr_info "Merge succeeded — no conflict resolution needed"
      return 0
    fi
  else
    # Merge reported failure. Refresh conflict files from the live merge state
    # (covers the case where Step 1 found none because the caller aborted before
    # invoking us).
    _cr_conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ -z "$_cr_conflict_files" ]; then
      # Zero unmerged entries but the merge failed: this is the add/add
      # overwrite collision class (issue #783), NOT a true unexpected state.
      # The authoritative signal is a stash holding an untracked file that now
      # collides with a tracked path; the git output signature corroborates it.
      local _cr_addadd_paths=""
      _cr_addadd_paths=$(_cr_stash_untracked_collision_paths || true)
      if [ -z "$_cr_addadd_paths" ] && _cr_output_signals_overwrite_collision "$_cr_merge_output"; then
        # Output names a collision but no colliding stash was found — surface it.
        _cr_error "Overwrite/untracked collision during merge; could not identify a stashed colliding path. Inspect manually (git status; git stash list)."
        git merge --abort 2>/dev/null || true
        return 1
      fi
      if [ -n "$_cr_addadd_paths" ]; then
        _cr_warning "Same-path add/add collision detected (overwrite blocked, zero unmerged entries)"
        echo "$_cr_addadd_paths" | sed 's/^/  /' >&2
        git merge --abort 2>/dev/null || true
        local _cr_materialized=false
        while IFS= read -r _cr_ap; do
          [ -z "$_cr_ap" ] && continue
          if _cr_materialize_addadd_conflict "$_cr_ap"; then
            _cr_materialized=true
          fi
        done <<< "$_cr_addadd_paths"
        if [ "$_cr_materialized" = true ]; then
          _cr_conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
          if [ -z "$_cr_conflict_files" ]; then
            _cr_conflict_files="$_cr_addadd_paths"
          fi
          _cr_info "Routing same-path add/add collision to content merge"
        else
          _cr_error "Same-path add/add collision at: $(echo "$_cr_addadd_paths" | tr '\n' ' ')"
          _cr_error "Two independently-created versions exist at the same path; a content merge is required (run 'git stash show -p' to inspect the branch version)."
          return 1
        fi
      else
        _cr_error "Merge failed but no unmerged files found — unexpected state"
        git merge --abort 2>/dev/null || true
        return 1
      fi
    fi
  fi

  _cr_status "Conflicts to resolve via Claude:" >&2
  echo "$_cr_conflict_files" | sed 's/^/  /' >&2

  # ── Step 4: Build prompt ──
  local _cr_prompt="You are in a git worktree with merge conflicts that need resolution.

main is the source of truth. It represents accepted, merged work. This branch is the newcomer.
Your job: rebase this branch's INTENT onto main's current reality.

Write the resolved content to each conflicting file. The workflow stages and commits it after
the session — do NOT run git add, git commit, git push, or any gh commands.

RULES:
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
Resolve every conflict by writing the resolved content to each file. The workflow stages and commits
the resolved files after this session ends."

  # ── Step 5: Load dev provider and run agentic session ──
  source "$RITE_LIB_DIR/providers/provider-interface.sh"
  load_provider "${RITE_DEV_PROVIDER:-claude}"

  # Publish the pre-session conflict-path list for commit_resolved_conflicts.
  # The resolver SESSION can only WRITE file content (git side effects are
  # policy-blocked), so staging must happen in the script after the session.
  # Using -A would sweep any operator WIP that was stash-popped back into the
  # tree before this call (the dirty-worktree → stash → abort → pop → resolve
  # flow in stale-branch.sh). Exporting the path list here lets the shared
  # commit helper stage ONLY the conflict paths — not the whole worktree.
  # The variable is cleared by commit_resolved_conflicts after use.
  _RITE_RESOLVER_CONFLICT_PATHS="$_cr_conflict_files"
  export _RITE_RESOLVER_CONFLICT_PATHS

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

  # Resolution verified — complete the handoff with commit_resolved_conflicts
  return 0
}

# ===================================================================
# PUBLIC: commit_resolved_conflicts
# ===================================================================

# commit_resolved_conflicts [WORKTREE_PATH]
#
# Script-side stage+commit handoff after a successful resolver session (#858).
# The resolver session WRITES resolved file content but cannot reliably stage
# or commit it (in-session git side effects are policy-blocked), so the script
# owns the whole sequence:
#
#   1. Stage the conflict paths captured before the resolver session (#871).
#      Staged set is scoped to _RITE_RESOLVER_CONFLICT_PATHS (set by
#      attempt_claude_merge_resolution before the agentic session) to avoid
#      sweeping operator WIP that was stash-popped back into the tree before
#      the resolver ran (dirty-worktree → stash → abort → pop → resolve flow).
#      Falls back to `git add -A` when the variable is unset (backward compat
#      for callers that bypass attempt_claude_merge_resolution).
#      Load-bearing BEFORE any staged-changes check: the add/add
#      materialization path leaves the index holding a staged deletion while
#      the resolved content sits UNTRACKED at the same path — committing
#      without this add would commit a bare deletion (live: issue #821, 2026-07-03).
#   2. Context detection from OBSERVABLE git state, not the documented flow:
#        rebase in progress ($git_dir/rebase-merge or rebase-apply) →
#          GIT_EDITOR=true git rebase --continue (or `git rebase --skip` when
#          the resolution left nothing to commit — the patch is already
#          upstream and --continue would refuse with "No changes")
#        merge in progress ($git_dir/MERGE_HEAD) → git commit --no-edit
#          (MERGE_MSG exists for --no-edit to reuse)
#        plain → commit staged changes with an explicit -m: no MERGE_MSG
#          exists, so a bare `git commit --no-edit` dies with "Aborting commit
#          due to empty commit message" (the exact failure 2>/dev/null
#          swallowed in issue #821); a clean index is a no-op success (the
#          resolver's internal merge auto-committed).
#   3. On failure: PRINT git's captured output (no 2>/dev/null swallowing) and
#      abort context-correctly — rebase --abort mid-rebase, merge --abort
#      mid-merge. The old inline call-site blocks ran `git merge --abort`
#      unconditionally, which no-ops mid-rebase and strands the worktree.
#
# Returns:
#   0 = resolution committed (or nothing needed committing)
#   1 = failure (context aborted, git output printed to stderr)
commit_resolved_conflicts() {
  local _crc_wt="${1:-.}"

  # Resolve the worktree's private git dir (worktree-aware: in a linked
  # worktree, rebase-merge/MERGE_HEAD live under .git/worktrees/<name>).
  local _crc_gitdir
  _crc_gitdir=$(git -C "$_crc_wt" rev-parse --git-dir 2>/dev/null || true)
  case "$_crc_gitdir" in
    ""|/*) : ;;
    # rev-parse --git-dir output is relative to the worktree when not absolute
    *) _crc_gitdir="$_crc_wt/$_crc_gitdir" ;;
  esac

  local _crc_context="plain"
  if [ -n "$_crc_gitdir" ] && { [ -d "$_crc_gitdir/rebase-merge" ] || [ -d "$_crc_gitdir/rebase-apply" ]; }; then
    _crc_context="rebase"
  elif [ -n "$_crc_gitdir" ] && [ -f "$_crc_gitdir/MERGE_HEAD" ]; then
    _crc_context="merge"
  fi

  # Stage the conflict paths captured before the resolver session, not the
  # whole worktree (-A). Using -A would sweep operator WIP that was stash-popped
  # back into the tree before attempt_claude_merge_resolution was called
  # (the dirty-worktree → stash → abort → pop → resolve flow in stale-branch.sh).
  #
  # _RITE_RESOLVER_CONFLICT_PATHS is set by attempt_claude_merge_resolution
  # immediately before the agentic session; it contains only the unmerged file
  # paths from `git diff --name-only --diff-filter=U`. We clear it here after
  # reading so it doesn't leak to subsequent calls. Falls back to -A when the
  # variable is unset (e.g. when commit_resolved_conflicts is called by a caller
  # that did not go through attempt_claude_merge_resolution, preserving backward
  # compatibility with direct callers).
  local _crc_conflict_paths="${_RITE_RESOLVER_CONFLICT_PATHS:-}"
  unset _RITE_RESOLVER_CONFLICT_PATHS

  local _crc_out=""
  local _crc_failed=false

  if [ -n "$_crc_conflict_paths" ]; then
    # Scoped staging: stage only the pre-session conflict paths (plus any newly
    # materialized versions at those paths). Reads the list line-by-line so each
    # path is passed as a distinct, properly-quoted argument to git add.
    local _crc_add_args=()
    while IFS= read -r _crc_p; do
      [ -n "$_crc_p" ] && _crc_add_args+=("$_crc_p")
    done <<< "$_crc_conflict_paths"
    if [ "${#_crc_add_args[@]}" -gt 0 ]; then
      if ! _crc_out=$(git -C "$_crc_wt" add -- "${_crc_add_args[@]}" 2>&1); then
        _crc_failed=true
      fi
    fi
  else
    # Fallback: no path list available — stage everything (backward compat).
    if ! _crc_out=$(git -C "$_crc_wt" add -A 2>&1); then
      _crc_failed=true
    fi
  fi

  if [ "$_crc_failed" = false ]; then
    case "$_crc_context" in
      rebase)
        if git -C "$_crc_wt" diff --cached --quiet 2>/dev/null; then
          # Resolution left nothing to commit (the stopped commit's change is
          # already upstream). --continue refuses with "No changes"; --skip is
          # git's documented continuation for this state.
          _crc_out=$(git -C "$_crc_wt" rebase --skip 2>&1) || _crc_failed=true
        else
          # GIT_EDITOR=true keeps --continue non-interactive (it re-opens the
          # replayed commit's message in an editor otherwise).
          _crc_out=$(GIT_EDITOR=true git -C "$_crc_wt" rebase --continue 2>&1) || _crc_failed=true
        fi
        ;;
      merge)
        # MERGE_MSG exists for --no-edit to reuse. Always commit: even an
        # index identical to HEAD needs the merge commit for ancestry.
        _crc_out=$(git -C "$_crc_wt" commit --no-edit 2>&1) || _crc_failed=true
        ;;
      *)
        # Plain context: either the resolver's internal merge auto-committed
        # (index clean — nothing to do) or the add above staged resolved
        # content with no merge/rebase in progress (add/add materialization).
        if ! git -C "$_crc_wt" diff --cached --quiet 2>/dev/null; then
          _crc_out=$(git -C "$_crc_wt" commit --no-edit -m "Resolve conflicts (Claude-assisted resolution)" 2>&1) || _crc_failed=true
        fi
        ;;
    esac
  fi

  if [ "$_crc_failed" = true ]; then
    _cr_error "Failed to commit resolved conflicts (context: $_crc_context)"
    if [ -n "$_crc_out" ]; then
      printf '%s\n' "$_crc_out" >&2
    fi
    case "$_crc_context" in
      rebase) git -C "$_crc_wt" rebase --abort 2>/dev/null || true ;;
      merge)  git -C "$_crc_wt" merge --abort 2>/dev/null || true ;;
    esac
    return 1
  fi
  return 0
}
