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

# Source issue-lock for get_locked_issue_numbers (live-lock rail) and
# backfill_worktree_locks (bare-form sweep).
if ! declare -f get_locked_issue_numbers >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/issue-lock.sh"
fi

# Source pr-detection for detect_pr_for_issue / detect_worktree_for_pr
# (issue-form worktree discovery).
if ! declare -f detect_pr_for_issue >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/pr-detection.sh"
fi

# Source stale-branch for resolve_target_branch (base resolver) and
# get_commits_behind_main (staleness count). stale-branch.sh also provides
# the RITE_STALE_BRANCH_THRESHOLD reference used by the threshold rail.
if ! declare -f resolve_target_branch >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
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
      trap - EXIT
      git worktree remove --force "$_sync_wt" 2>/dev/null || true
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

# =============================================================================
# sync_issue_branch <issue_number>
#
# Rebases the feature branch for the given issue onto its resolver-determined
# base and force-pushes with --force-with-lease.
#
# Design rails (checked in order):
#   1. Live lock         → SKIP (never push under an active session)
#   2. Dirty worktree    → SKIP (never stash or touch WIP — composability)
#   3. Staleness threshold → SKIP (defer to the workflow's stale-branch path)
#   4. Already current   → SKIP cleanly (no-op)
#
# On rebase conflict: abort, report "conflict", exit 0 (skip = composable).
# On push rejection:  report "push_failed", exit 1 (operational failure).
# On not found:       report "not-found", exit 0.
#
# Sets _SYNC_ISSUE_OUTCOME to the outcome string for callers that need it.
#
# Returns:
#   0 — synced, current, or skipped-by-rail (composable; skips are informational)
#   1 — operational failure (fetch/push infrastructure error)
#
# Known cost: rebase rewrites SHAs, so any existing review goes stale per the
# SHA-based staleness contract (behavioral-design.md — "Stale Review Loop").
# Sync when main moved meaningfully, not as a reflexive ritual.
# =============================================================================
sync_issue_branch() {
  local _issue_n="${1:?sync_issue_branch: issue number required}"
  _SYNC_ISSUE_OUTCOME=""

  # ── Rail 1: live lock ────────────────────────────────────────────────────────
  # Cheapest check first — before any network calls. Never push under a live session.
  # get_locked_issue_numbers uses kill -0 liveness (backfill locks have no pid and
  # are never returned), so false positives from stale locks are impossible.
  if get_locked_issue_numbers 2>/dev/null | grep -qx "$_issue_n" 2>/dev/null; then
    print_warning "Issue #${_issue_n}: SKIP — active workflow session is running"
    print_info "  Next step: wait for the run to finish; check 'rite ${_issue_n} --status'"
    _SYNC_ISSUE_OUTCOME="skipped-lock"
    _diag "SYNC_ISSUE issue=${_issue_n} outcome=skipped-lock"
    return 0
  fi

  # ── Discovery: PR and worktree ───────────────────────────────────────────────
  local _pr_num="" _wt_path=""
  if detect_pr_for_issue "$_issue_n" 2>/dev/null; then
    _pr_num="${PR_NUMBER:-}"
    if [ -n "$_pr_num" ] && detect_worktree_for_pr "$_pr_num" 2>/dev/null; then
      _wt_path="${WORKTREE_PATH:-}"
    fi
  fi

  # Fallback: lock-dir cwd mapping (covers worktrees without an open PR)
  if [ -z "$_wt_path" ]; then
    local _lock_cwd="${RITE_LOCK_DIR}/issue-${_issue_n}.lock/cwd"
    if [ -f "$_lock_cwd" ]; then
      local _candidate
      _candidate=$(cat "$_lock_cwd" 2>/dev/null || true)
      [ -n "$_candidate" ] && [ -d "$_candidate" ] && _wt_path="$_candidate"
    fi
  fi

  # Nothing found → informational note, not an error
  if [ -z "$_wt_path" ]; then
    print_info "Issue #${_issue_n}: nothing to sync (no open PR or known worktree)"
    _SYNC_ISSUE_OUTCOME="not-found"
    _diag "SYNC_ISSUE issue=${_issue_n} outcome=not-found"
    return 0
  fi

  # ── Rail 2: dirty worktree ───────────────────────────────────────────────────
  # Never stash or touch WIP — only the owner should manage uncommitted work.
  local _wt_dirty=false
  git -C "$_wt_path" diff --quiet 2>/dev/null || _wt_dirty=true
  if [ "$_wt_dirty" = false ]; then
    git -C "$_wt_path" diff --cached --quiet 2>/dev/null || _wt_dirty=true
  fi
  if [ "$_wt_dirty" = true ]; then
    print_warning "Issue #${_issue_n}: SKIP — worktree has uncommitted changes"
    print_info "  Next step: commit or stash manually, then re-run 'rite --sync ${_issue_n}'"
    _SYNC_ISSUE_OUTCOME="skipped-dirty"
    _diag "SYNC_ISSUE issue=${_issue_n} outcome=skipped-dirty"
    return 0
  fi

  # ── Resolve base branch ──────────────────────────────────────────────────────
  local _base
  _base=$(resolve_target_branch "$_issue_n" "${_pr_num:-}" 2>/dev/null || echo "main")
  _base="${_base:-main}"

  # Fetch the base so the behind count is accurate
  if ! git_fetch_safe origin "$_base" 2>/dev/null; then
    print_error "Issue #${_issue_n}: failed to fetch origin/$_base"
    _SYNC_ISSUE_OUTCOME="fetch_failed"
    _diag "SYNC_ISSUE issue=${_issue_n} outcome=fetch_failed"
    return 1
  fi

  # ── Rail 3: staleness threshold ──────────────────────────────────────────────
  # Branches at/above the threshold need a close-and-restart, not a rebase.
  # Defer to the workflow's own stale-branch path (check_stale_branch).
  get_commits_behind_main "$_wt_path" "$_base"
  local _behind="$COMMITS_BEHIND_MAIN"
  local _threshold="${RITE_STALE_BRANCH_THRESHOLD:-10}"
  if [ "$_behind" -ge "$_threshold" ]; then
    print_warning "Issue #${_issue_n}: SKIP — ${_behind} commits behind origin/${_base} (threshold: ${_threshold})"
    print_info "  Next step: needs close-and-restart — the next 'rite ${_issue_n}' handles this via the stale-branch path"
    _SYNC_ISSUE_OUTCOME="skipped-threshold"
    _diag "SYNC_ISSUE issue=${_issue_n} outcome=skipped-threshold"
    return 0
  fi

  # ── Rail 4: already current ──────────────────────────────────────────────────
  if [ "$_behind" -eq 0 ]; then
    print_info "Issue #${_issue_n}: already current with origin/${_base}"
    _SYNC_ISSUE_OUTCOME="current"
    _diag "SYNC_ISSUE issue=${_issue_n} outcome=current"
    return 0
  fi

  local _branch_name
  _branch_name=$(git -C "$_wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

  # ── merge-tree precheck ───────────────────────────────────────────────────────
  # Mirrors mid-run-rebase.sh:128-148: a clean in-memory merge means the PR will
  # merge as-is in Phase 4 regardless of distance; no rebase needed, no stale-review.
  # Exit codes: 0=clean, 1=conflict, ≥2=unavailable/error.
  local _mt_rc=0
  git -C "$_wt_path" merge-tree --write-tree --no-messages "origin/$_base" HEAD \
    >/dev/null 2>&1 || _mt_rc=$?

  if [ "$_mt_rc" -eq 0 ]; then
    print_info "Issue #${_issue_n}: ${_behind} commit(s) behind origin/${_base} but merges cleanly — no rebase needed"
    _SYNC_ISSUE_OUTCOME="current"
    _diag "SYNC_ISSUE issue=${_issue_n} outcome=current"
    return 0
  elif [ "$_mt_rc" -ge 2 ]; then
    # merge-tree unavailable or unexpected error — fail open and proceed with rebase.
    print_warning "Issue #${_issue_n}: merge-tree check unavailable (rc=${_mt_rc}) — attempting rebase"
  fi

  # _mt_rc == 1 (or unavailable): proceed with rebase attempt.

  # ── Rebase onto origin/<base> ─────────────────────────────────────────────────
  print_status "Issue #${_issue_n}: rebasing ${_branch_name:-<unknown>} onto origin/${_base} (${_behind} commit(s) behind)..."

  local _rebase_rc=0
  ( cd "$_wt_path" && git rebase "origin/$_base" ) || _rebase_rc=$?

  if [ "$_rebase_rc" -ne 0 ]; then
    git -C "$_wt_path" rebase --abort 2>/dev/null || true

    # Attempt Claude-assisted resolution before bailing to manual.
    # Guard: declare -f only — matches integration-sync.sh:198 (--sync <branch> path).
    local _conflict_resolved=false
    if declare -f attempt_claude_merge_resolution >/dev/null 2>&1; then
      print_status "Issue #${_issue_n}: attempting Claude-assisted conflict resolution..."
      local _resolver_rc=0
      # cd into the worktree: resolver uses bare git calls that act on cwd.
      # Mirrors integration-sync.sh:206-211 (--sync <branch> conflict path cd pattern).
      ( cd "$_wt_path" && attempt_claude_merge_resolution \
        --branch-name "${_branch_name:-}" \
        --issue-number "$_issue_n" \
        --merge-target "origin/$_base" ) || _resolver_rc=$?

      if [ "$_resolver_rc" -eq 0 ]; then
        if ! commit_resolved_conflicts "$_wt_path"; then
          print_error "Issue #${_issue_n}: failed to commit resolved conflicts"
          _SYNC_ISSUE_OUTCOME="conflict"
          _diag "SYNC_ISSUE issue=${_issue_n} outcome=conflict"
          return 0
        fi
        _conflict_resolved=true
      fi
    fi

    if [ "$_conflict_resolved" = false ]; then
      print_error "Issue #${_issue_n}: rebase conflict — aborted"
      print_info "  Next step: resolve manually: cd '${_wt_path}' && git rebase origin/${_base}; then re-run 'rite --sync ${_issue_n}'"
      _SYNC_ISSUE_OUTCOME="conflict"
      _diag "SYNC_ISSUE issue=${_issue_n} outcome=conflict"
      return 0  # skip — composability requires exit 0 for non-operational outcomes
    fi
  fi

  # ── Push with --force-with-lease ─────────────────────────────────────────────
  # Force-with-lease refuses if a foreign client pushed since our fetch — safe.
  # A push_failed here means foreign commits appeared; the workflow handles it next run.
  local _push_rc=0
  git -C "$_wt_path" push --force-with-lease origin "${_branch_name:-HEAD}" || _push_rc=$?
  if [ "$_push_rc" -ne 0 ]; then
    print_error "Issue #${_issue_n}: push --force-with-lease rejected (foreign commits on remote?)"
    print_info "  Next step: the next 'rite ${_issue_n}' run handles this via the workflow's own machinery"
    _SYNC_ISSUE_OUTCOME="push_failed"
    _diag "SYNC_ISSUE issue=${_issue_n} outcome=push_failed"
    return 1  # operational failure — not composable
  fi

  print_success "Issue #${_issue_n}: synced — rebased ${_branch_name:-HEAD} onto origin/${_base}"
  _SYNC_ISSUE_OUTCOME="synced"
  _diag "SYNC_ISSUE issue=${_issue_n} outcome=synced"
  return 0
}

# =============================================================================
# sync_all_repos
#
# Bare-form sweep: syncs ALL integration branches and ALL in-flight worktrees.
#
# Phase A — integration branches: enumerate the ledger directory for *.log
#   files; branch name = ledger-relative path minus .log (NOT basename, to
#   preserve slash-containing names like "release/1.2").  Uses
#   sync_integration_branch for each.  The ledger dir may not exist yet
#   (written by the staging-merge path, #1043) — absent-safe via [ -d ] guard.
#
# Phase B — in-flight worktrees: calls backfill_worktree_locks (best-effort)
#   then walks ${RITE_LOCK_DIR}/issue-*.lock/cwd entries.  Each entry goes
#   through sync_issue_branch with all four rails applied.
#
# Integration branches are synced first so that when feature branches are
# rebased they target already-current bases within the same sweep.
#
# Returns:
#   0 — all items synced/current/skipped-by-rail (skips are informational)
#   1 — one or more operational failures (fetch/push errors)
# =============================================================================
sync_all_repos() {
  print_header "Sync All: Integration Branches + In-flight Worktrees"

  local _overall_rc=0
  local _report=()

  # === Phase A: sync every ledger integration branch ==========================
  local _ledger_dir="${RITE_STATE_DIR}/integration-branches"
  local _branch_count=0

  if [ -d "$_ledger_dir" ]; then
    while IFS= read -r _f; do
      [ -f "$_f" ] || continue
      local _rel="${_f#"$_ledger_dir/"}"
      # Derive branch name via parameter expansion — NOT basename, which would
      # truncate slash-containing names ("release/1.2" → "1.2").
      local _branch="${_rel%.log}"
      _branch_count=$((_branch_count + 1))

      # Detect a promoted-and-deleted remote branch before calling
      # sync_integration_branch.  Ledger files are never pruned; a gone remote
      # is a completed lifecycle, not an operational failure.
      # git ls-remote --exit-code exits 2 when the pattern matches nothing
      # (branch gone) and non-zero/non-2 on transport failures.  Treat only
      # exit 2 as a completed lifecycle; any other failure is operational.
      local _remote_check_rc=0
      git ls-remote --exit-code --heads origin "$_branch" >/dev/null 2>&1 || _remote_check_rc=$?
      if [ "$_remote_check_rc" -eq 2 ]; then
        print_info "Phase A — branch '${_branch}': skipped (remote branch gone — promoted and deleted)"
        _report+=("  branch '${_branch}': skipped-gone")
        continue
      elif [ "$_remote_check_rc" -ne 0 ]; then
        print_warning "Phase A — branch '${_branch}': FAILED (ls-remote exit ${_remote_check_rc} — transport error?)"
        _overall_rc=1
        _report+=("  branch '${_branch}': FAILED (ls-remote exit ${_remote_check_rc})")
        continue
      fi

      print_status "Phase A — integration branch: ${_branch}"
      local _branch_rc=0
      # Redirect stdin to /dev/null so the conflict resolver (which reads from
      # stdin) cannot consume the find-pipe stream and cause the loop to skip
      # subsequent ledger entries.
      sync_integration_branch "$_branch" </dev/null || _branch_rc=$?
      if [ "$_branch_rc" -ne 0 ]; then
        _overall_rc=1
        _report+=("  branch '${_branch}': FAILED (exit ${_branch_rc})")
      else
        _report+=("  branch '${_branch}': ok")
      fi
    done < <(find "$_ledger_dir" -type f -name '*.log' 2>/dev/null || true)
  fi

  if [ "$_branch_count" -eq 0 ]; then
    print_info "Phase A: no integration branch ledger files found (ledger written by staging-merge path)"
  fi

  # === Phase B: sync in-flight worktrees ======================================
  # Backfill locks first to establish the worktree→issue mapping.
  backfill_worktree_locks 2>/dev/null || true

  local _wt_count=0
  if [ -d "${RITE_LOCK_DIR:-}" ]; then
    local _cwd_file
    for _cwd_file in "${RITE_LOCK_DIR}"/issue-*.lock/cwd; do
      [ -f "$_cwd_file" ] || continue
      local _wt_from_cwd
      _wt_from_cwd=$(cat "$_cwd_file" 2>/dev/null || true)
      [ -n "$_wt_from_cwd" ] && [ -d "$_wt_from_cwd" ] || continue

      # Extract issue number from the lock dir name
      local _lock_dir_b="${_cwd_file%/cwd}"
      local _lock_base="${_lock_dir_b##*/}"
      local _issue_from_lock="${_lock_base#issue-}"
      _issue_from_lock="${_issue_from_lock%.lock}"
      [[ "$_issue_from_lock" =~ ^[0-9]+$ ]] || continue

      _wt_count=$((_wt_count + 1))
      print_status "Phase B — issue #${_issue_from_lock} worktree: ${_wt_from_cwd}"
      local _wt_rc=0
      sync_issue_branch "$_issue_from_lock" || _wt_rc=$?
      if [ "$_wt_rc" -ne 0 ]; then
        _overall_rc=1
      fi
      _report+=("  issue #${_issue_from_lock}: ${_SYNC_ISSUE_OUTCOME:-?}")
    done
  fi

  if [ "$_wt_count" -eq 0 ]; then
    print_info "Phase B: no in-flight worktrees found"
  fi

  # === Per-item report =========================================================
  if [ "${#_report[@]}" -gt 0 ]; then
    echo ""
    print_header "Sync Report"
    local _r
    for _r in "${_report[@]+"${_report[@]}"}"; do
      echo "$_r"
    done
  fi

  return "$_overall_rc"
}
