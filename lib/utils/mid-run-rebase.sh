#!/bin/bash
# lib/utils/mid-run-rebase.sh
# Mid-run drift detection and proactive rebase for wide-surface refactor PRs.
#
# Problem: wide-surface PRs (touching many files) take 1-2 hours through phases 1-3.
# By the time phase 4 (merge) fires, main has often moved N commits ahead.  For narrow
# PRs the pre-merge auto-merge usually succeeds; for wide PRs it fails on content
# conflicts and the run dies after all the Claude time has been spent.
#
# Fix: at the START of phase 3 (assess) — and between fix iterations — ask the only
# question that matters: does the branch actually CONFLICT with main?  Compute it with
# `git merge-tree` (a pure in-memory merge; no working-tree, commit, push, or gate).
#   - No conflict → do nothing.  A behind-but-clean branch merges fine in phase 4; a
#     needless rebase would only churn history and re-trigger the post-commit test gate.
#   - Conflict    → try Claude-assisted resolution, else print a clear abort message
#                   BEFORE the review — saving the full phase-3 time.
# Commit distance is deliberately NOT a gate: it is not a reliable proxy for conflict
# risk and previously produced false aborts on clean far-behind PRs (#433/#439 incident).
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
# The function fetches origin/main, then decides on CONFLICT, not on distance:
#
#   drift == 0            : return 0 silently (no drift)
#   behind but no conflict: return 0 silently (phase 4 merges it as-is; no rebase)
#   conflicts with main   : try Claude-assisted resolution; if unresolved, abort, return 1
#
# Exit codes:
#   0 = no drift, or branch merges cleanly, or conflict resolved (workflow continues)
#   1 = unresolved conflict with main — abort BEFORE generating review
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

  # Drift alone is harmless.  Commit distance does NOT determine anything here: a
  # branch 50 commits behind that touches isolated files merges instantly, while a
  # branch 2 commits behind editing the same lines conflicts hard.  The only thing
  # that would make the eventual merge fail is a real CONTENT CONFLICT with main.
  #
  # Compute that directly with `git merge-tree` — a pure in-memory merge that writes
  # NOTHING: no working-tree change, no commit, no force-push, no test-gate re-run.
  # GitHub merges PRs with merge (not rebase) semantics, so a clean merge-tree means
  # phase 4 will merge the PR as-is, however far behind it is (merge-pr.sh also
  # updates the branch itself if GitHub ever reports it unmergeable).
  #
  #   merge-tree clean    → do NOTHING.  No rebase, no churn — let phase 4 merge it.
  #   merge-tree conflict → surface early (try Claude resolution, else abort) BEFORE
  #                         spending Claude review time on a PR that cannot merge.
  #   merge-tree error    → fail open (skip), consistent with the fetch-failure path.
  local _mt_rc=0
  git -C "$worktree_path" merge-tree --write-tree --no-messages origin/main HEAD \
    >/dev/null 2>&1 || _mt_rc=$?

  if [ "$_mt_rc" -eq 0 ]; then
    print_info "mid-run: branch is ${behind} commit(s) behind main but merges cleanly — no rebase needed"
    return 0
  elif [ "$_mt_rc" -ge 2 ]; then
    # merge-tree unavailable / unexpected error — don't block the workflow on tooling.
    print_warning "mid-run: merge-tree check unavailable (rc=${_mt_rc}) — skipping conflict check"
    return 0
  fi

  # _mt_rc == 1: real conflict with main.  Resolve it now (or abort) before the review.
  print_warning "mid-run: branch conflicts with main (${behind} commit(s) behind) — resolving before review"
  _mid_run_rebase_onto_main "$worktree_path" "$branch_name" "$issue_number" "$pr_number" "$workflow_mode"
  return $?
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
      # Push rejected — another concurrent push happened while we were rebasing.
      # The remote branch has foreign commits we don't have. Apply preserve-or-halt:
      # re-fetch and inspect the foreign commits. If they are content-empty vs our
      # rebased HEAD (pure mainline-sync merge commits), discard and retry. Otherwise
      # halt loudly — we must not silently drop code commits.
      print_warning "mid-run-rebase: push rejected after rebase — checking for foreign commits"
      if git fetch origin "$branch_name" 2>/dev/null; then
        local _mid_remote_head
        _mid_remote_head=$(git rev-parse "origin/$branch_name" 2>/dev/null || true)
        local _mid_local_head
        _mid_local_head=$(git rev-parse HEAD 2>/dev/null || true)

        if [ -n "$_mid_remote_head" ] && [ -n "$_mid_local_head" ] && [ "$_mid_remote_head" != "$_mid_local_head" ]; then
          # Anchor the emptiness check to merge-base(local,remote) so that
          # base-branch drift (commits on main that the remote merge brought in)
          # does not inflate the diff and falsely classify real code changes as
          # content-empty. git diff merge-base..remote_head is the effective patch
          # introduced by the foreign commits beyond the common ancestor.
          local _mid_merge_base
          _mid_merge_base=$(git merge-base "${_mid_local_head}" "${_mid_remote_head}" 2>/dev/null || true)
          local _mid_foreign_diff
          _mid_foreign_diff=$(git diff "${_mid_merge_base:-${_mid_local_head}}..${_mid_remote_head}" 2>/dev/null || true)
          if [ -z "$_mid_foreign_diff" ]; then
            # Content-empty vs merge-base (pure mainline-sync merge). Safe to
            # discard by re-fetching the lease ref and retrying the push.
            print_info "mid-run-rebase: foreign commits are content-empty — retrying push after lease refresh"
            if git push --force-with-lease origin "$branch_name" 2>/dev/null; then
              print_info "mid-run rebase: push succeeded after lease refresh (content-empty foreign commits discarded)"
              return 0
            fi
          fi
          # Non-empty foreign commits (code changes). Halt loudly — do NOT push.
          # Preserve-or-halt contract: a push here would clobber foreign code commits.
          print_error "mid-run-rebase: push rejected — remote has foreign code commits that would be lost by force-push"
          print_error "Foreign commits contain code changes — halting to prevent data loss"
          print_info "Foreign commits on remote:"
          git log --oneline "${_mid_local_head}..${_mid_remote_head}" 2>/dev/null | sed 's/^/  /' >&2
          print_info "Run 'rite ${issue_number:-<issue>} --supervised' to integrate and resolve manually"
          if [ -n "$pre_rebase_head" ]; then
            git reset --hard "$pre_rebase_head" 2>/dev/null || true
            print_info "Branch restored to pre-rebase HEAD"
          fi
          return 1
        fi
      fi
      # Could not fetch or determine remote state — revert to pre-rebase and fail safely
      print_warning "mid-run-rebase: push rejected — could not inspect remote state, reverting to pre-rebase"
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
        # Script-side stage+commit handoff (issue #858): the resolver session
        # WRITES resolutions but cannot stage or commit them. The shared helper
        # (conflict-resolver.sh::commit_resolved_conflicts) stages via
        # `git add -A`, detects the live rebase/merge/plain context,
        # continues/commits accordingly, and aborts context-correctly with
        # git's stderr surfaced on failure.
        if ! commit_resolved_conflicts "$worktree_path"; then
          print_error "mid-run-rebase: failed to commit resolved conflicts"
          return 1
        fi
        # Resolution committed (or already committed inside resolver) — force-with-lease push.
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
    print_warning "Mid-run rebase conflict: cannot auto-rebase ${branch_name} onto origin/main"
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
