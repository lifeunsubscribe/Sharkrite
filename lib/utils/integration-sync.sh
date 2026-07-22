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
# Sentinel: sync_integration_branch is the first stable function defined here.
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

# Source stale-branch.sh for resolve_target_branch, get_commits_behind_main.
# Guards prevent double-sourcing.
if ! declare -f resolve_target_branch >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
fi

# Source pr-detection.sh for detect_pr_for_issue, detect_worktree_for_pr.
if ! declare -f detect_pr_for_issue >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/pr-detection.sh"
fi

# Source issue-lock.sh for get_locked_issue_numbers, backfill_worktree_locks.
if ! declare -f get_locked_issue_numbers >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/issue-lock.sh"
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

# =============================================================================
# sync_issue_branch <issue-number>
#
# Rebases the in-flight feature branch for an issue onto its resolver-determined
# base (via resolve_target_branch), then force-pushes with --force-with-lease.
#
# Design invariants:
#   - NEVER merges: feature branches are personal/short-lived; rebase keeps history clean.
#   - ALWAYS uses git -C "$WORKTREE_PATH" or a (cd ...) subshell — never cd's the caller.
#   - NEVER stashes, commits, or touches WIP (dirty rail skips with a note).
#   - NEVER calls the workflow, dev session, review, assess, or merge paths.
#   - NEVER acquires an issue lock (lock checks are read-only).
#   - Exit 0 for all "clean" outcomes: synced, already current, or any rail skip.
#     Exit 1 only on operational failures (fetch, push infrastructure errors).
#
# Known cost: rebase rewrites SHAs, so any existing review goes stale per the
# SHA-based staleness contract (behavioral-design.md "Stale Review Loop").
# The next `rite N` entry regenerates it. Use sync when main moved meaningfully,
# not as a reflexive ritual.
#
# Safety rails (checked in order; each skip prints its reason + next step):
#   1. Live lock    — issue held by a running process → skip (never push under active session)
#   2. Dirty tree   — uncommitted tracked changes → skip (never stash WIP)
#   3. Threshold    — branch is ≥ RITE_STALE_BRANCH_THRESHOLD commits behind → skip (close-and-restart)
#   4. Current      — 0 commits behind → no-op (report "current")
#   5. Rebase conflict → git rebase --abort, skip (no resolver, no stash, no verify)
#   6. Push rejected (force-with-lease) → skip with note (leave for workflow machinery)
#
# Diagnostic: one SYNC_ISSUE line per call via _diag (logging.sh):
#   SYNC_ISSUE issue=N outcome=synced|current|skipped-lock|skipped-dirty|skipped-threshold|conflict|not-found
#
# Arguments:
#   issue_number — the GitHub issue number (digits only)
# Returns:
#   0 — synced, current, or any rail skip (all informational; composable with &&)
#   1 — operational failure (fetch/push infrastructure error)
# =============================================================================
sync_issue_branch() {
  local _issue_number="${1:?sync_issue_branch: issue number required}"

  print_header "Sync Issue Branch: #$_issue_number"

  # ── Rail 1: Live lock ──────────────────────────────────────────────────────
  # Never force-push while a session is actively running on this issue.
  # get_locked_issue_numbers outputs only live-pid locks (backfill locks have
  # no pid file and never appear — CLAUDE.md "issue-lock.sh :672").
  local _live_lock_check
  _live_lock_check=$(get_locked_issue_numbers 2>/dev/null || true)
  if echo "$_live_lock_check" | grep -qx "$_issue_number" 2>/dev/null; then
    print_warning "Issue #$_issue_number is held by a live session — skipping to avoid racing a push"
    print_info "Next step: wait for the run to finish; check 'rite $_issue_number --status'"
    _diag "SYNC_ISSUE issue=$_issue_number outcome=skipped-lock"
    return 0
  fi

  # ── Discover worktree and PR ───────────────────────────────────────────────
  # Tier 1: detect_pr_for_issue + detect_worktree_for_pr (uses gh API).
  # Tier 2: lock-dir cwd mapping (network-free fallback).
  local _pr_number=""
  local _worktree_path=""

  # Attempt to detect open PR first (gives us the PR number for resolver and
  # worktree discovery).
  local _pr_detect_rc=0
  detect_pr_for_issue "$_issue_number" || _pr_detect_rc=$?
  if [ "$_pr_detect_rc" -eq 0 ]; then
    _pr_number="${PR_NUMBER:-}"
  fi

  # Try worktree detection via PR number.
  if [ -n "$_pr_number" ]; then
    local _wt_detect_rc=0
    detect_worktree_for_pr "$_pr_number" || _wt_detect_rc=$?
    if [ "$_wt_detect_rc" -eq 0 ]; then
      _worktree_path="${WORKTREE_PATH:-}"
    fi
  fi

  # Fallback: lock-dir cwd file (network-free, works even without an open PR).
  if [ -z "$_worktree_path" ] && [ -n "${RITE_LOCK_DIR:-}" ]; then
    local _lock_cwd="${RITE_LOCK_DIR}/issue-${_issue_number}.lock/cwd"
    if [ -f "$_lock_cwd" ]; then
      local _cwd_val
      _cwd_val=$(cat "$_lock_cwd" 2>/dev/null || true)
      if [ -n "${_cwd_val:-}" ] && [ -d "$_cwd_val" ]; then
        _worktree_path="$_cwd_val"
      fi
    fi
  fi

  # Nothing to sync: no worktree and no PR branch found.
  if [ -z "$_worktree_path" ]; then
    print_info "Issue #$_issue_number: no in-flight worktree or open PR found — nothing to sync"
    _diag "SYNC_ISSUE issue=$_issue_number outcome=not-found"
    return 0
  fi

  # Derive branch name from the worktree if not already known.
  local _branch_name=""
  _branch_name=$(git -C "$_worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ -z "$_branch_name" ] || [ "$_branch_name" = "HEAD" ]; then
    print_warning "Issue #$_issue_number: worktree at '$_worktree_path' is in detached HEAD — skipping"
    _diag "SYNC_ISSUE issue=$_issue_number outcome=not-found"
    return 0
  fi

  # ── Rail 2: Dirty worktree ─────────────────────────────────────────────────
  # Predicate mirrors stale-branch.sh:916 but deliberately omits auto-stash
  # (stale-branch.sh:918). Sync never stashes or touches WIP.
  if ! git -C "$_worktree_path" diff --quiet 2>/dev/null \
     || ! git -C "$_worktree_path" diff --cached --quiet 2>/dev/null; then
    print_warning "Issue #$_issue_number: worktree has uncommitted changes — skipping to preserve WIP"
    print_info "Next step: commit or stash manually, then re-run 'rite --sync $_issue_number'"
    _diag "SYNC_ISSUE issue=$_issue_number outcome=skipped-dirty"
    return 0
  fi

  # ── Resolve base branch ───────────────────────────────────────────────────
  # resolve_target_branch (#1033): passes PR number when available (tier-1 API
  # ground truth from baseRefName), falls back to state file / env / default.
  local _base_branch
  _base_branch=$(resolve_target_branch "$_issue_number" "${_pr_number:-}" 2>/dev/null || echo "main")
  _base_branch="${_base_branch:-main}"

  # ── Fetch base branch ─────────────────────────────────────────────────────
  # Must succeed before we can count commits behind.
  if ! git_fetch_safe origin "$_base_branch" 2>/dev/null; then
    print_error "Issue #$_issue_number: failed to fetch origin/$_base_branch — cannot sync"
    _diag "SYNC_ISSUE issue=$_issue_number outcome=conflict"
    return 1
  fi

  # ── Rail 3: Staleness threshold ───────────────────────────────────────────
  # Reuses get_commits_behind_main (stale-branch.sh:280) which sets COMMITS_BEHIND_MAIN.
  # Does NOT fetch — the fetch above has already refreshed origin/<base>.
  get_commits_behind_main "$_worktree_path" "$_base_branch"
  local _behind=${COMMITS_BEHIND_MAIN:-0}
  local _threshold="${RITE_STALE_BRANCH_THRESHOLD:-10}"

  if [ "$_behind" -ge "$_threshold" ]; then
    print_warning "Issue #$_issue_number: branch is $_behind commits behind origin/$_base_branch (threshold: $_threshold) — needs close-and-restart"
    print_info "Next step: run 'rite $_issue_number' — the stale-branch path handles close-and-restart automatically"
    _diag "SYNC_ISSUE issue=$_issue_number outcome=skipped-threshold"
    return 0
  fi

  # ── Rail 4: Already current ───────────────────────────────────────────────
  if [ "$_behind" -eq 0 ]; then
    print_info "Issue #$_issue_number: branch '$_branch_name' is already current with origin/$_base_branch — nothing to do"
    _diag "SYNC_ISSUE issue=$_issue_number outcome=current"
    return 0
  fi

  # ── Verify origin/<base> ref exists before rebasing ──────────────────────
  # Mirrors stale-branch.sh:900 pre-rebase guard.
  if ! git -C "$_worktree_path" rev-parse --verify "origin/$_base_branch" >/dev/null 2>&1; then
    print_error "Issue #$_issue_number: origin/$_base_branch does not exist — cannot rebase"
    _diag "SYNC_ISSUE issue=$_issue_number outcome=conflict"
    return 1
  fi

  print_status "Issue #$_issue_number: rebasing '$_branch_name' onto origin/$_base_branch ($_behind commits behind)..."

  # ── Rebase (in subshell to keep caller cwd unchanged) ────────────────────
  # Deliberately does NOT:
  #   - stash (rail 2 already refused dirty state)
  #   - invoke the Claude conflict resolver (no resolver in sync; let workflow handle conflicts)
  #   - run post-merge verification (no test-suite run in sync)
  # Matches the conventions of _stale_rebase_onto_main but omits those paths.
  local _rebase_rc=0
  (
    cd "$_worktree_path" || exit 1
    git rebase "origin/$_base_branch" >/dev/null 2>&1
  ) || _rebase_rc=$?

  if [ "$_rebase_rc" -ne 0 ]; then
    # Rebase conflicted — abort and report; let the next `rite N` workflow handle it.
    git -C "$_worktree_path" rebase --abort 2>/dev/null || true
    print_warning "Issue #$_issue_number: rebase onto origin/$_base_branch had conflicts — aborted"
    print_info "Next step: run 'rite $_issue_number' — the workflow handles conflict resolution"
    print_info "Or resolve manually:"
    print_info "  git -C '$_worktree_path' fetch origin $_base_branch"
    print_info "  git -C '$_worktree_path' rebase origin/$_base_branch"
    print_info "  # resolve conflicts, then: git -C '$_worktree_path' rebase --continue"
    _diag "SYNC_ISSUE issue=$_issue_number outcome=conflict"
    return 0  # Skip is informational — composable
  fi

  # ── Push with force-with-lease ────────────────────────────────────────────
  # --force-with-lease is the correct post-rebase push: rebase rewrites history
  # so a plain push would be rejected. The lease ensures we only push if the
  # remote hasn't changed since our last fetch, preventing accidental overwrite
  # of concurrent commits. Matches stale-branch.sh:959.
  local _push_rc=0
  git -C "$_worktree_path" push --force-with-lease origin "$_branch_name" 2>/dev/null || _push_rc=$?

  if [ "$_push_rc" -ne 0 ]; then
    # force-with-lease rejected: another client pushed between our fetch and push.
    # This is a skip, not a blocking error — the next `rite N` will handle it
    # via the stale-branch / divergence-handler machinery.
    print_warning "Issue #$_issue_number: push rejected (foreign commits on remote since fetch)"
    print_info "Next step: run 'rite $_issue_number' — the workflow reconciles divergence automatically"
    _diag "SYNC_ISSUE issue=$_issue_number outcome=conflict"
    return 0  # Skip is informational — composable
  fi

  print_success "Issue #$_issue_number: branch '$_branch_name' synced onto origin/$_base_branch"
  _diag "SYNC_ISSUE issue=$_issue_number outcome=synced"
  return 0
}

# =============================================================================
# sync_all_repos
#
# All-repo bare form: `rite --sync` (zero args).
#
# Phase A — Sync all ledger integration branches:
#   Enumerates *.log files under ${RITE_STATE_DIR}/integration-branches/ (the
#   ledger written by the staging-merge slice, #1043). Absent/empty ledger is a
#   zero-item phase, not an error (guarded by [ -d ] check). Branch name is
#   recovered from the ledger-relative path minus ".log" via parameter expansion
#   (NOT basename — that would truncate slash-containing names like "release/1.2").
#   Each branch is synced via sync_integration_branch.
#
# Phase B — Sync all in-flight worktrees:
#   Calls backfill_worktree_locks (best-effort, as in repo-status.sh:409) to
#   establish worktree→issue mapping. Then walks ${RITE_LOCK_DIR}/issue-*.lock/cwd
#   files to find existing worktrees and calls sync_issue_branch for each.
#   Live-pid locks pass through to sync_issue_branch's Rail 1 (which skips them).
#
# Integration branches go first so feature rebases in Phase B target already-
# current bases within the same sweep.
#
# Exit: 0 when all items are synced/current/skipped-by-rail.
#       1 only on operational failures (fetch/push infrastructure errors).
# =============================================================================
sync_all_repos() {
  local _overall_rc=0

  print_header "Sync All — Integration Branches + In-Flight Worktrees"

  # ── Phase A: Ledger integration branches ──────────────────────────────────
  echo "" >&2
  print_status "Phase A: syncing ledger integration branches..."
  local _ledger_dir="${RITE_STATE_DIR:-}/integration-branches"
  local _phase_a_count=0

  if [ -d "$_ledger_dir" ]; then
    # bash-3.2-portable discovery via while-read loop (no mapfile/readarray).
    # Branch name = ledger-relative path (relative to _ledger_dir) minus ".log"
    # suffix. NOT basename — that would truncate slash-containing branch names
    # like "release/1.2" to "1.2". Parameter expansion preserves the full path.
    while IFS= read -r _ledger_file; do
      [ -f "$_ledger_file" ] || continue
      # Strip the ledger dir prefix + trailing slash to get the relative path
      local _rel="${_ledger_file#"${_ledger_dir}/"}"
      # Strip the .log suffix to get the branch name
      local _branch="${_rel%.log}"
      if [ -z "$_branch" ]; then
        continue
      fi
      _phase_a_count=$(( _phase_a_count + 1 ))
      local _a_rc=0
      sync_integration_branch "$_branch" || _a_rc=$?
      if [ "$_a_rc" -ne 0 ]; then
        _overall_rc=1
      fi
    done < <(find "$_ledger_dir" -type f -name '*.log' 2>/dev/null || true)
  fi

  if [ "$_phase_a_count" -eq 0 ]; then
    print_info "Phase A: no integration branches in ledger (ledger absent or empty) — skipped"
  fi

  # ── Phase B: In-flight worktrees ──────────────────────────────────────────
  echo "" >&2
  print_status "Phase B: syncing in-flight worktrees..."

  # best-effort backfill so lock-dir has current cwd entries (mirrors repo-status.sh:409)
  backfill_worktree_locks 2>/dev/null || true

  local _phase_b_count=0
  if [ -n "${RITE_LOCK_DIR:-}" ] && [ -d "${RITE_LOCK_DIR:-}" ]; then
    for _lock_dir in "${RITE_LOCK_DIR}"/issue-*.lock; do
      [ -d "$_lock_dir" ] || continue
      local _cwd_file="${_lock_dir}/cwd"
      [ -f "$_cwd_file" ] || continue
      local _wt_path
      _wt_path=$(cat "$_cwd_file" 2>/dev/null || true)
      [ -n "${_wt_path:-}" ] || continue
      [ -d "$_wt_path" ] || continue

      # Derive issue number from lock dir name (issue-N.lock → N)
      local _ld_base="${_lock_dir##*/}"   # issue-N.lock
      local _issue_num="${_ld_base#issue-}"  # N.lock
      _issue_num="${_issue_num%.lock}"        # N
      [[ "$_issue_num" =~ ^[0-9]+$ ]] || continue

      _phase_b_count=$(( _phase_b_count + 1 ))
      local _b_rc=0
      sync_issue_branch "$_issue_num" || _b_rc=$?
      if [ "$_b_rc" -ne 0 ]; then
        _overall_rc=1
      fi
    done
  fi

  if [ "$_phase_b_count" -eq 0 ]; then
    print_info "Phase B: no in-flight worktrees found — skipped"
  fi

  echo "" >&2
  if [ "$_overall_rc" -eq 0 ]; then
    print_success "All-repo sync complete (Phase A: $_phase_a_count branch(es), Phase B: $_phase_b_count worktree(s))"
  else
    print_warning "All-repo sync finished with errors (Phase A: $_phase_a_count, Phase B: $_phase_b_count) — check output above"
  fi

  return $_overall_rc
}
