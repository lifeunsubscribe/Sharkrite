#!/bin/bash
# lib/utils/mid-run-rebase.sh
# Mid-run drift detection and proactive rebase for wide-surface refactor PRs.
#
# Problem: wide-surface PRs (touching many files) take 1-2 hours through phases 1-3.
# By the time phase 4 (merge) fires, main has often moved N commits ahead.  For narrow
# PRs the pre-merge auto-merge usually succeeds; for wide PRs it fails on content
# conflicts and the run dies after all the Claude time has been spent.
#
# Fix: check drift at the START of phase 3 (assess) and between fix iterations.  If
# behind <= threshold (default 5), rebase silently.  If above threshold or conflicts,
# print a clear abort message BEFORE generating a review — saving the full phase-3 time.
#
# Threshold: RITE_MID_RUN_REBASE_THRESHOLD (default: 5 commits).
# Setting it to 0 disables automatic rebase (always aborts on any drift).
#
# Related: lib/utils/stale-branch.sh handles the RESUME path (same problem, different
# entry point).  This file handles the ACTIVE-RUN path.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f check_and_rebase_against_main >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_self_dir/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"

# Source gh retry wrapper if not already loaded
if ! declare -f gh_safe >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/gh-retry.sh"
fi

# Source logging for _diag structured diagnostic lines (no-op if already loaded)
if ! declare -f _diag >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/logging.sh"
fi

# Source conflict resolver if available (provided by issue #21).
# Guarded: mid-run-rebase works without it — resolver is an enhancement,
# not a hard dependency. When present, attempt_claude_merge_resolution()
# is called on rebase conflict bail paths.
if [ -f "$RITE_LIB_DIR/utils/conflict-resolver.sh" ]; then
  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"
fi

# ===================================================================
# PUBLIC: Main entry point
# ===================================================================

# check_and_rebase_against_main WORKTREE_PATH BRANCH_NAME ISSUE_NUMBER PR_NUMBER [WORKFLOW_MODE]
#
# Call this at the start of phase 3 (assess-and-resolve) and between fix iterations.
# The function fetches origin/main, counts drift, and acts:
#
#   drift == 0            : return 0 silently (no drift)
#   drift <= threshold    : rebase onto origin/main + force-with-lease push, return 0
#   drift >  threshold    : print clear abort message, return 1
#   rebase has conflicts  : print clear abort message, return 1
#
# Exit codes:
#   0 = no drift, or rebase succeeded (workflow continues normally)
#   1 = drift exceeds threshold, or rebase failed — abort BEFORE generating review
#
# The NO-rebase path (return 1) intentionally fires BEFORE the Claude review
# session so no Claude time is wasted.  Caller should surface the message and
# stop the workflow, directing the user to `rite N --supervised` for manual
# resolution.
check_and_rebase_against_main() {
  local worktree_path="$1"
  local branch_name="$2"
  local issue_number="${3:-}"
  local pr_number="${4:-}"
  local workflow_mode="${5:-unsupervised}"

  # Sanity: must be on a feature branch, not main itself
  if [ -z "$branch_name" ] || [ "$branch_name" = "main" ] || [ "$branch_name" = "master" ]; then
    return 0
  fi

  if [ ! -d "$worktree_path" ]; then
    # Worktree gone — nothing to check
    return 0
  fi

  # Fetch origin/main to get the latest remote state.
  # Fetch failure is non-fatal — we warn and skip rather than blocking the workflow.
  if ! git -C "$worktree_path" fetch origin main 2>/dev/null; then
    print_warning "mid-run-rebase: Could not fetch origin/main — skipping drift check"
    return 0
  fi

  # Count commits by which the feature branch is behind origin/main.
  # Use merge-base so that commits the branch already has don't inflate the count.
  local merge_base
  merge_base=$(git -C "$worktree_path" merge-base HEAD origin/main 2>/dev/null || echo "")

  if [ -z "$merge_base" ]; then
    # Unrelated histories — can't count drift; skip silently
    return 0
  fi

  local behind
  behind=$(git -C "$worktree_path" rev-list --count "${merge_base}..origin/main" 2>/dev/null || echo "0")

  if [ "${behind:-0}" -eq 0 ]; then
    # Branch is up to date — no action needed
    return 0
  fi

  local threshold="${RITE_MID_RUN_REBASE_THRESHOLD:-5}"

  if [ "$behind" -le "$threshold" ]; then
    # Within threshold: rebase silently onto main and force-push
    print_info "mid-run rebase: main advanced by ${behind} commit(s) — rebasing before review"
    _mid_run_rebase_onto_main "$worktree_path" "$branch_name" "$issue_number" "$pr_number" "$workflow_mode"
    return $?
  else
    # Above threshold: abort early, before any Claude review time is spent
    echo "" >&2
    print_warning "⚠️  Mid-run drift detected: main advanced by ${behind} commit(s) (threshold: ${threshold})"
    echo "" >&2
    echo "  Branch:    $branch_name" >&2
    echo "  PR:        #${pr_number:-?}" >&2
    echo "  Issue:     #${issue_number:-?}" >&2
    echo "  Behind:    ${behind} commits (threshold for auto-rebase: ${threshold})" >&2
    echo "" >&2
    echo "  This PR is too far behind main for automatic rebase." >&2
    echo "  Manual rebase is required before the review can proceed." >&2
    echo "" >&2
    echo "  To resolve:" >&2
    echo "    cd $worktree_path" >&2
    echo "    git fetch origin main" >&2
    echo "    git rebase origin/main" >&2
    echo "    # Resolve any conflicts, then:" >&2
    echo "    git push --force-with-lease origin $branch_name" >&2
    echo "    # Then resume:" >&2
    echo "    rite ${issue_number:-<issue>}" >&2
    echo "" >&2
    echo "  Or run in supervised mode for interactive conflict resolution:" >&2
    echo "    rite ${issue_number:-<issue>} --supervised" >&2
    echo "" >&2
    return 1
  fi
}

# ===================================================================
# INTERNAL: Rebase onto main and force-push
# ===================================================================

# _mid_run_rebase_onto_main WORKTREE_PATH BRANCH_NAME ISSUE_NUMBER PR_NUMBER WORKFLOW_MODE
#
# Performs the actual rebase + force-push.  Unlike the resume-path rebase in
# stale-branch.sh (_stale_rebase_onto_main), this one is lightweight:
#   - No post-merge test verification (that would burn the Claude time we're saving)
#   - No conflict-resolver integration (conflicts abort immediately)
#   - No stash handling (mid-run worktrees should be clean after a commit push)
#
# Exit codes:
#   0 = rebase + push succeeded
#   1 = rebase failed (conflicts), or push failed after rebase
_mid_run_rebase_onto_main() {
  local worktree_path="$1"
  local branch_name="$2"
  local issue_number="${3:-}"
  local pr_number="${4:-}"
  local workflow_mode="${5:-unsupervised}"

  cd "$worktree_path" || return 1

  # Verify origin/main exists
  if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
    print_error "mid-run-rebase: origin/main does not exist after fetch — cannot rebase"
    return 1
  fi

  # Count commits being replayed so the log message is informative
  local commits_ahead
  commits_ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "0")

  # Save pre-rebase HEAD so we can produce a useful backup ref if the rebase rewrites history.
  # The DO NOT bullet says "do NOT rebase published commits without preserving the original SHAs
  # in a backup ref".  We create refs/rite-rebase-backup/<branch>/<timestamp> before rewriting.
  local pre_rebase_head
  pre_rebase_head=$(git rev-parse HEAD 2>/dev/null || echo "")

  # Create backup ref before rewriting history
  if [ -n "$pre_rebase_head" ]; then
    local backup_ref="refs/rite-rebase-backup/${branch_name}/$(date +%s)"
    git update-ref "$backup_ref" "$pre_rebase_head" 2>/dev/null || true
  fi

  local rebase_output
  if rebase_output=$(git rebase origin/main 2>&1); then
    # Rebase succeeded — push with --force-with-lease (history was rewritten)
    if git push --force-with-lease origin "$branch_name" 2>/dev/null; then
      print_info "mid-run rebase: rebased ${commits_ahead} commit(s) onto origin/main, pushed"
      return 0
    else
      # Push rejected — another concurrent push happened.  This is rare mid-run (the
      # branch should only have our commits), but it can happen with parallel batch runs.
      # Don't try to classify: just abort cleanly and let the caller handle it.
      git rebase --abort 2>/dev/null || true
      print_warning "mid-run-rebase: push rejected after rebase (concurrent push?) — reverting to pre-rebase state"
      if [ -n "$pre_rebase_head" ]; then
        git reset --hard "$pre_rebase_head" 2>/dev/null || true
      fi
      print_info "Branch restored to pre-rebase HEAD. Run 'rite ${issue_number:-<issue>} --supervised' to resolve."
      return 1
    fi
  else
    # Rebase has conflicts — abort and attempt Claude-assisted resolution in auto mode.
    git rebase --abort 2>/dev/null || true

    # In auto mode, attempt Claude-assisted conflict resolution before bailing.
    # attempt_claude_merge_resolution is provided by conflict-resolver.sh (issue #21).
    # Exit codes: 0=resolved, 1=failure, 5=usage-cap (batch-blocking — propagate up).
    if [ "$workflow_mode" != "supervised" ] && declare -f attempt_claude_merge_resolution >/dev/null 2>&1; then
      print_status "mid-run-rebase: attempting Claude-assisted conflict resolution..."
      local _resolver_result=0 _cr_start _cr_duration
      _cr_start=$(date +%s)
      _diag "CONFLICT_RESOLVER_START context=mid_run_rebase issue=${issue_number:-} pr=${pr_number:-} branch=${branch_name}"
      attempt_claude_merge_resolution "$branch_name" "${issue_number:-}" "${pr_number:-}" || _resolver_result=$?
      _cr_duration=$(( $(date +%s) - _cr_start ))
      if [ "$_resolver_result" -eq 0 ]; then
        _diag "CONFLICT_RESOLVER context=mid_run_rebase outcome=resolved issue=${issue_number:-} pr=${pr_number:-} duration_s=${_cr_duration}"
        print_success "mid-run-rebase: conflicts resolved by Claude"
        # Resolver stages files but does NOT commit (see conflict-resolver.sh contract line 10).
        # Commit the resolution before pushing.
        if ! git commit --no-edit 2>/dev/null; then
          print_error "mid-run-rebase: failed to commit resolved conflicts"
          git merge --abort 2>/dev/null || true
          return 1
        fi
        # Resolution committed — force-with-lease push (history was rewritten by resolver).
        if git push --force-with-lease origin "$branch_name" 2>/dev/null; then
          print_info "mid-run rebase: conflict resolved, committed, and pushed"
          return 0
        else
          print_error "mid-run-rebase: push failed after conflict resolution (force-with-lease rejected)"
          return 1
        fi
      elif [ "$_resolver_result" -eq 5 ]; then
        _diag "CONFLICT_RESOLVER context=mid_run_rebase outcome=cap_hit issue=${issue_number:-} pr=${pr_number:-} duration_s=${_cr_duration}"
        print_error "mid-run-rebase: Claude usage cap reached during conflict resolution — aborting batch"
        return 5
      else
        _diag "CONFLICT_RESOLVER context=mid_run_rebase outcome=failed issue=${issue_number:-} pr=${pr_number:-} duration_s=${_cr_duration}"
        print_warning "mid-run-rebase: Claude could not resolve conflicts"
      fi
    elif [ "$workflow_mode" != "supervised" ]; then
      # Canary: resolver function not available but we're in auto mode — emit a diagnostic
      # so wiring drift is visible in health reports.
      _diag "CONFLICT_RESOLVER context=mid_run_rebase outcome=skipped_no_resolver issue=${issue_number:-} pr=${pr_number:-}"
    fi

    echo "" >&2
    print_warning "⚠️  Mid-run rebase conflict: cannot auto-rebase ${branch_name} onto origin/main"
    echo "" >&2
    echo "  Conflicting files need manual resolution before the review can proceed." >&2
    echo "" >&2
    echo "  To resolve:" >&2
    echo "    cd $worktree_path" >&2
    echo "    git fetch origin main" >&2
    echo "    git rebase origin/main" >&2
    echo "    # Resolve each conflict, then:" >&2
    echo "    git add <resolved-file>" >&2
    echo "    git rebase --continue" >&2
    echo "    git push --force-with-lease origin $branch_name" >&2
    echo "    rite ${issue_number:-<issue>}" >&2
    echo "" >&2
    echo "  Or run in supervised mode for interactive assistance:" >&2
    echo "    rite ${issue_number:-<issue>} --supervised" >&2
    echo "" >&2
    return 1
  fi
}
