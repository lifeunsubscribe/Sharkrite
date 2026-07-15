#!/bin/bash
# lib/utils/integration-sync.sh
# Sync an integration branch by merging origin/main into it.
#
# Integration branches are shared, long-lived staging branches that drift behind
# main during active work. This verb merges origin/main into the branch in a
# temporary detached worktree, then pushes.
#
# Design invariants:
#   - NEVER rebases: the integration branch is shared and long-lived; live
#     worktrees fork from it; rebasing would rewrite SHAs recorded in the
#     integration ledger and under in-flight worktrees.
#   - NEVER force-pushes: a merge adds commits without rewriting history, so
#     plain `git push` is correct; forced variants are explicitly prohibited.
#   - NEVER called automatically: only explicit `rite --sync <branch>` triggers
#     this. No workflow phase, batch slot, or other verb may call it.
#
# Conflict path (matches stale-branch.sh pattern):
#   - Guarded source of conflict-resolver.sh.
#   - If attempt_claude_merge_resolution is available: resolve, then
#     commit_resolved_conflicts, verify_post_merge, push.
#   - If resolver unavailable or fails: git merge --abort, remove temp worktree,
#     print manual instructions, exit 1.
#
# Diagnostic:
#   Emits one structured diag line via _diag (logging.sh):
#   INTEGRATION_SYNC branch=<b> outcome=current|merged|resolved|conflict|push_failed

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f sync_integration_branch >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _IS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_IS_SCRIPT_DIR/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"

# Source logging for _diag structured diagnostic lines (no-op if already loaded)
if ! declare -f _diag >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/logging.sh"
fi

# Source git-helpers for git_fetch_safe (retrying fetch wrapper)
if ! declare -f git_fetch_safe >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/git-helpers.sh"
fi

# Source post-merge verification (needed for conflict resolution path)
if ! declare -f verify_post_merge >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"
fi

# Source conflict resolver if available (enhancement, not a hard dependency).
# When present, attempt_claude_merge_resolution() becomes available for the
# conflict path. Guarded exactly as stale-branch.sh sources it.
if [ -f "$RITE_LIB_DIR/utils/conflict-resolver.sh" ] && ! declare -f attempt_claude_merge_resolution >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"
fi

# =============================================================================
# sync_integration_branch <branch>
#
# Fetches origin/main and origin/<branch>, checks currency, and if behind:
# merges origin/main into <branch> in a temporary detached worktree, then
# pushes.
#
# Arguments:
#   branch — the integration branch name (must not be "main")
#
# Returns:
#   0 — clean: already current (no-op) or merge+push succeeded
#   1 — error: fetch failed, remote branch not found, merge conflicted and
#              could not be resolved, or push failed
# =============================================================================
sync_integration_branch() {
  local SYNC_BRANCH="${1:?sync_integration_branch: branch argument required}"

  # Refuse to sync main into itself — meaningless and potentially destructive.
  if [ "$SYNC_BRANCH" = "main" ]; then
    print_error "rite --sync main is not allowed: syncing main into itself is meaningless"
    print_info "Usage: rite --sync <integration-branch>"
    return 1
  fi

  print_header "Sync Integration Branch: $SYNC_BRANCH"

  # ── Step 1: Fetch origin/main and origin/<branch> ──────────────────────────

  print_status "Fetching origin/main..."
  if ! git_fetch_safe origin main; then
    print_error "Cannot proceed — failed to fetch origin/main"
    return 1
  fi

  print_status "Fetching origin/$SYNC_BRANCH..."
  # Best-effort: capture whether the fetch succeeded so we can give a clear
  # error if the remote branch does not exist.
  local _fetch_rc=0
  git_fetch_safe origin "$SYNC_BRANCH" || _fetch_rc=$?
  if [ "$_fetch_rc" -ne 0 ]; then
    print_error "Remote branch 'origin/$SYNC_BRANCH' not found or not reachable"
    print_info "Auto-creation of integration branches belongs to the --branch flow"
    print_info "Create the branch on origin first, then re-run: rite --sync $SYNC_BRANCH"
    return 1
  fi

  # ── Step 2: Currency check — no-op when already current ────────────────────

  # "Already current" means origin/main is an ancestor of origin/<branch>,
  # i.e. the branch already contains all commits from main.
  if git merge-base --is-ancestor origin/main "origin/$SYNC_BRANCH" 2>/dev/null; then
    print_info "Branch '$SYNC_BRANCH' is already current with origin/main — nothing to do"
    _diag "INTEGRATION_SYNC branch=$SYNC_BRANCH outcome=current"
    return 0
  fi

  # ── Step 3: Create a temporary detached worktree for the merge ─────────────
  # We use a temporary worktree because the integration branch has no permanent
  # checkout and we must not disturb main's checkout. The worktree is detached
  # so we can control exactly which branch/ref is checked out.

  local _sync_wt=""
  _sync_wt=$(mktemp -d)

  # Trap: always remove the temp worktree on exit, scoped to the specific path
  # variable — never a glob (CLAUDE.md temp-file-glob convention).
  # shellcheck disable=SC2064
  trap "git worktree remove --force '${_sync_wt}' 2>/dev/null; rm -rf '${_sync_wt}' 2>/dev/null || true" EXIT

  print_status "Creating temporary worktree at $_sync_wt..."
  if ! git worktree add --detach "$_sync_wt" "origin/$SYNC_BRANCH" 2>/dev/null; then
    print_error "Failed to create temporary worktree for '$SYNC_BRANCH'"
    rm -rf "$_sync_wt" 2>/dev/null || true
    trap - EXIT
    return 1
  fi

  # ── Step 4: Merge origin/main into the branch ──────────────────────────────
  # Plain merge — never rebase (see file-level comment for why).

  print_status "Merging origin/main into $SYNC_BRANCH..."
  local _merge_rc=0
  local _merge_output=""
  _merge_output=$(git -C "$_sync_wt" merge origin/main --no-edit 2>&1) || _merge_rc=$?

  if [ "$_merge_rc" -eq 0 ]; then
    # Clean merge — push and finish.
    print_success "Merge succeeded — pushing to origin/$SYNC_BRANCH"
    if ! git -C "$_sync_wt" push origin "HEAD:refs/heads/$SYNC_BRANCH"; then
      print_error "Push failed after successful merge"
      _diag "INTEGRATION_SYNC branch=$SYNC_BRANCH outcome=push_failed"
      return 1
    fi
    print_success "Branch '$SYNC_BRANCH' synced successfully"
    _diag "INTEGRATION_SYNC branch=$SYNC_BRANCH outcome=merged"
    # Remove the trap before returning so cleanup doesn't double-fire
    trap - EXIT
    git worktree remove --force "$_sync_wt" 2>/dev/null || true
    return 0
  fi

  # ── Step 5: Conflict path ──────────────────────────────────────────────────

  print_warning "Merge conflict detected in branch '$SYNC_BRANCH'"

  # Attempt Claude-assisted resolution if the resolver is available.
  # This exactly mirrors the stale-branch.sh pattern:
  #   - guarded declare -f check before calling
  #   - commit_resolved_conflicts for the script-side stage+commit handoff
  #   - verify_post_merge for semantic-conflict detection
  if declare -f attempt_claude_merge_resolution >/dev/null 2>&1; then
    print_status "Attempting Claude-assisted conflict resolution..."
    local _resolver_rc=0
    # Use named-flag form so the merge target is explicit.
    # --merge-target already defaults to origin/main inside conflict-resolver.sh,
    # but specifying it here makes the intent clear and resilient to future
    # default changes.
    #
    # cd into the sync worktree before calling the resolver: conflict-resolver.sh
    # uses bare `git` calls (rev-parse, diff, merge, etc.) that act on cwd.
    # stale-branch.sh:717 does the same cd before calling the resolver — we
    # must match that pattern exactly (see Scope Boundary DO).
    # Run in a subshell so the cd does not escape to the caller.
    ( cd "$_sync_wt" && attempt_claude_merge_resolution \
      --branch-name "$SYNC_BRANCH" \
      --merge-target "origin/main" ) || _resolver_rc=$?

    if [ "$_resolver_rc" -eq 0 ]; then
      print_success "Conflicts resolved by Claude"
      if ! commit_resolved_conflicts "$_sync_wt"; then
        print_error "Failed to commit resolved conflicts"
        git -C "$_sync_wt" merge --abort 2>/dev/null || true
        _diag "INTEGRATION_SYNC branch=$SYNC_BRANCH outcome=conflict"
        trap - EXIT
        git worktree remove --force "$_sync_wt" 2>/dev/null || true
        return 1
      fi
      if ! verify_post_merge "$_sync_wt" "origin/main"; then
        print_warning "Conflict resolution succeeded at git level but tests fail"
        print_error "Post-resolution verification failed — cannot push"
        _diag "INTEGRATION_SYNC branch=$SYNC_BRANCH outcome=conflict"
        trap - EXIT
        git worktree remove --force "$_sync_wt" 2>/dev/null || true
        return 1
      fi
      # Resolution committed and verified — push (plain push, not force: merge
      # adds commits without rewriting history).
      if ! git -C "$_sync_wt" push origin "HEAD:refs/heads/$SYNC_BRANCH"; then
        print_error "Push failed after conflict resolution"
        _diag "INTEGRATION_SYNC branch=$SYNC_BRANCH outcome=push_failed"
        trap - EXIT
        git worktree remove --force "$_sync_wt" 2>/dev/null || true
        return 1
      fi
      print_success "Branch '$SYNC_BRANCH' synced (with conflict resolution)"
      _diag "INTEGRATION_SYNC branch=$SYNC_BRANCH outcome=resolved"
      trap - EXIT
      git worktree remove --force "$_sync_wt" 2>/dev/null || true
      return 0
    fi
    # Resolver failed (exit 1) or usage-cap (exit 5) — fall through to manual.
    print_warning "Claude could not resolve conflicts — manual resolution required"
  fi

  # Resolver unavailable or failed: abort the merge and emit manual instructions.
  git -C "$_sync_wt" merge --abort 2>/dev/null || true
  _diag "INTEGRATION_SYNC branch=$SYNC_BRANCH outcome=conflict"
  trap - EXIT
  git worktree remove --force "$_sync_wt" 2>/dev/null || true

  print_error "Merge conflict in '$SYNC_BRANCH' — manual resolution required"
  echo "" >&2
  echo "To resolve manually:" >&2
  echo "  git fetch origin" >&2
  echo "  git checkout $SYNC_BRANCH" >&2
  echo "  git merge origin/main" >&2
  echo "  # resolve conflicts, then:" >&2
  echo "  git add <resolved-files>" >&2
  echo "  git commit" >&2
  echo "  git push origin $SYNC_BRANCH" >&2
  echo "" >&2
  return 1
}
