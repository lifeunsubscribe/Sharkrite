#!/bin/bash
# lib/utils/issue-lock.sh - Per-issue locking to prevent concurrent rite invocations
#
# Prevents two `rite N` invocations from entering the same worktree simultaneously,
# which would corrupt in-flight work. Uses mkdir-style atomic locking with PID file
# for liveness checking and stale lock reclamation.
#
# SAME-HOST ASSUMPTION
# --------------------
# Stale lock reclamation uses `kill -0 $PID` to test whether the holding process is
# still alive. This signal-based liveness check is only valid within a single host
# and PID namespace. It will NOT work correctly if:
#
#   - RITE_LOCK_DIR is on shared/network storage (NFS, SMB, EFS, etc.) and multiple
#     hosts can acquire locks for the same project — kill -0 checks the PID against
#     the local process table only; a PID that is valid on host A may be recycled
#     (reused by an unrelated process) on host B, causing premature reclamation.
#
#   - RITE_LOCK_DIR is inside a container with a PID namespace isolated from the host
#     that may also run rite — same PID recycling hazard across namespace boundaries.
#
# This is an intentional design constraint, not a bug. Sharkrite is designed for
# single-developer use on a single machine. The default RITE_LOCK_DIR
# ($RITE_PROJECT_ROOT/.rite/locks) is project-local, so the same-host assumption
# holds by default.
#
# DO NOT point RITE_LOCK_DIR at shared storage. If you need cross-host locking,
# replace the kill-0 reclamation with a time-based TTL instead.
#
# Usage:
#   acquire_issue_lock <issue_number>          # Returns 0 on success, 1 if locked by live process
#   release_issue_lock <issue_number>          # Cleanup lock directory
#   acquire_pr_followup_lock <pr_number>       # Returns 0 on success, 1 on timeout
#   release_pr_followup_lock <pr_number>       # Cleanup followup lock directory
#   backfill_worktree_locks                    # Create lock dirs for pre-existing worktrees
#
# Lock directory structure:
#   ${RITE_LOCK_DIR}/issue-N.lock/
#     pid       — PID of the holding process (transient, written by acquire_issue_lock)
#     worktree  — absolute path to the worktree (persistent, written by backfill_worktree_locks)
#
# The lock directory is the source of truth for worktree → issue mapping.
# acquire_issue_lock can write the worktree file when called with an explicit path
# argument, but the primary production caller (setup_issue_lock_if_needed in
# claude-workflow.sh) acquires the lock before WORKTREE_PATH is known — so it omits
# the path argument and the worktree file is NOT written during routine lock acquisition.
# In practice the worktree file is populated by backfill_worktree_locks (called at
# the start of `rite --status`).
# backfill_worktree_locks creates lock dirs for worktrees that predate the lock
# infrastructure (PR #67), or where the worktree path was not supplied at acquire time,
# by walking git worktree list and resolving the issue number from the branch's open PR body.
#
# Note: the pid file is written by the active process and removed by release_issue_lock.
# For active lock dirs (those with a pid file), the worktree file persists until the
# lock dir is released (release_issue_lock removes the whole dir). Backfill lock dirs
# have a worktree file but no pid file — they are metadata-only (no active lock holder)
# and are NOT removed by release_issue_lock, --undo, or merge. See backfill_worktree_locks
# docstring for lifecycle details and manual cleanup instructions.

set -euo pipefail

# Source config if RITE_LOCK_DIR not already set (defined in config.sh)
if [ -z "${RITE_LOCK_DIR:-}" ]; then
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_SCRIPT_DIR/config.sh"
fi

# Acquire per-issue lock with PID-based liveness checking
# Args: issue_number [worktree_path]
# Returns: 0 on success, 1 if locked by another live process
# When worktree_path is provided, writes it to lock_dir/worktree for mapping.
acquire_issue_lock() {
  local issue_number="$1"
  local worktree_path="${2:-}"
  local lock_dir="${RITE_LOCK_DIR}/issue-${issue_number}.lock"

  # Ensure lock directory exists
  mkdir -p "${RITE_LOCK_DIR}"

  local lock_attempts=0
  local max_attempts=30

  while ! mkdir "$lock_dir" 2>/dev/null; do
    # Check if the holding process is still alive
    if [ -f "$lock_dir/pid" ]; then
      local lock_pid
      lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")

      # kill -0: same-host assumption — only valid within a single PID namespace.
      # See file-level comment for details. RITE_LOCK_DIR must not be on shared storage.
      if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        # Holding process is dead — reclaim stale lock
        echo "⚠️  Reclaiming stale lock from dead process (PID $lock_pid)" >&2
        rm -rf "$lock_dir" 2>/dev/null
        continue
      fi

      # Lock is held by a live process
      if [ $lock_attempts -eq 0 ]; then
        echo "❌ Issue #${issue_number} is already being processed by PID ${lock_pid}" >&2
        echo "   Refusing to start. Wait for it to finish, or run 'rite ${issue_number} --undo' if it crashed." >&2
      fi
    else
      # Lock dir exists but no PID file — crashed between mkdir and PID write
      echo "⚠️  Reclaiming stale lock (no PID file)" >&2
      rm -rf "$lock_dir" 2>/dev/null
      continue
    fi

    lock_attempts=$((lock_attempts + 1))
    if [ $lock_attempts -ge $max_attempts ]; then
      echo "❌ Lock timeout after ${max_attempts} seconds" >&2
      return 1
    fi

    sleep 1
  done

  # Write our PID so other processes can check liveness
  echo $$ > "$lock_dir/pid" 2>/dev/null || true

  # Write worktree path for worktree→issue mapping (used by repo-status.sh and backfill)
  if [ -n "$worktree_path" ]; then
    echo "$worktree_path" > "$lock_dir/worktree" 2>/dev/null || true
  fi

  return 0
}

# Release per-issue lock
# Args: issue_number
release_issue_lock() {
  local issue_number="$1"
  local lock_dir="${RITE_LOCK_DIR}/issue-${issue_number}.lock"

  if [ -d "$lock_dir" ]; then
    # Only remove if it's our lock (PID matches)
    if [ -f "$lock_dir/pid" ]; then
      local lock_pid
      lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
      if [ "$lock_pid" = "$$" ]; then
        rm -rf "$lock_dir" 2>/dev/null || true
      fi
    fi
  fi
}

# Acquire per-PR follow-up issue creation lock
#
# Prevents the check-then-create race: concurrent assess-and-resolve invocations
# on the same PR can both pass the dedup check (GitHub API eventual consistency
# means the first creation isn't visible yet) and create duplicate follow-up issues.
# This lock serialises the search-then-create sequence so only one process runs it
# at a time.
#
# Uses the same mkdir-style atomic locking as acquire_issue_lock, with a shorter
# stale timeout (60s) since the critical section completes in seconds.
#
# Args: pr_number
# Returns: 0 on success, 1 on timeout (lock held by live process for too long)
acquire_pr_followup_lock() {
  local pr_number="$1"
  local lock_dir="${RITE_LOCK_DIR}/pr-${pr_number}-followup.lock"

  # Ensure lock directory parent exists
  mkdir -p "${RITE_LOCK_DIR}"

  local lock_attempts=0
  # Allow up to 60 seconds — the critical section (gh issue list + gh issue create)
  # takes ~5-10s in practice; 60s gives ample room while still failing safely.
  local max_attempts=60

  while ! mkdir "$lock_dir" 2>/dev/null; do
    # Check if the holding process is still alive
    if [ -f "$lock_dir/pid" ]; then
      local lock_pid
      lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")

      # kill -0: same-host assumption — only valid within a single PID namespace.
      # See file-level comment for details. RITE_LOCK_DIR must not be on shared storage.
      if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        # Holding process is dead — reclaim stale lock
        echo "⚠️  Reclaiming stale followup lock from dead process (PID $lock_pid)" >&2
        rm -rf "$lock_dir" 2>/dev/null
        continue
      fi
    else
      # Lock dir exists but no PID file — crashed between mkdir and PID write
      echo "⚠️  Reclaiming stale followup lock (no PID file)" >&2
      rm -rf "$lock_dir" 2>/dev/null
      continue
    fi

    lock_attempts=$((lock_attempts + 1))
    if [ $lock_attempts -ge $max_attempts ]; then
      echo "❌ Follow-up lock timeout for PR #${pr_number} after ${max_attempts}s" >&2
      return 1
    fi

    sleep 1
  done

  # Write our PID so other processes can check liveness
  echo $$ > "$lock_dir/pid" 2>/dev/null || true

  return 0
}

# Release per-PR follow-up issue creation lock
# Args: pr_number
release_pr_followup_lock() {
  local pr_number="$1"
  local lock_dir="${RITE_LOCK_DIR}/pr-${pr_number}-followup.lock"

  if [ -d "$lock_dir" ]; then
    # Only remove if it's our lock (PID matches)
    if [ -f "$lock_dir/pid" ]; then
      local lock_pid
      lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
      if [ "$lock_pid" = "$$" ]; then
        rm -rf "$lock_dir" 2>/dev/null || true
      fi
    fi
  fi
}

# Backfill worktree lock files for pre-existing worktrees
#
# Walks git worktree list and creates lock dirs for any non-main worktree that
# does not already have a lock entry. The issue number is resolved from the
# branch's open PR body (Closes/Fixes/Resolves #N).
#
# This fixes worktrees created before the lock infrastructure landed (PR #67),
# which have no lock file and therefore show no issue association in rite --status.
#
# A backfill lock dir contains only a `worktree` metadata file (no `pid` file),
# since no active rite process holds the lock. It persists indefinitely —
# neither `rite N --undo` nor `merge-pr.sh` removes it. `release_issue_lock`
# also does not remove it (it only removes dirs whose `pid` matches the calling
# process, and backfill dirs have no `pid` file). To clean up stale backfill
# dirs, remove them manually:
#   rm -rf "${RITE_LOCK_DIR}/issue-N.lock"
# Running `rite --backfill-locks` after cleanup will recreate any that still
# have an active open PR / live worktree.
#
# Args: none
# Returns: 0 always (errors are non-fatal; missing worktrees are skipped)
# Output: progress lines to stderr when entries are created
backfill_worktree_locks() {
  mkdir -p "${RITE_LOCK_DIR}"

  local worktree_lines
  worktree_lines=$(git worktree list --porcelain 2>/dev/null || echo "")

  local current_path=""
  local current_branch=""
  local main_worktree=""

  # Process porcelain output block by block (blank line terminates each block)
  while IFS= read -r line; do
    if [[ "$line" =~ ^worktree\ (.+) ]]; then
      current_path="${BASH_REMATCH[1]}"
      current_branch=""
      # The first worktree block is always the main repo — capture it so we can
      # pass it down to _backfill_one_worktree without relying on RITE_PROJECT_ROOT,
      # which is git-rev-parse-relative and resolves to the current worktree when
      # run from inside a feature worktree.
      if [ -z "$main_worktree" ]; then
        main_worktree="$current_path"
      fi
    elif [[ "$line" =~ ^branch\ refs/heads/(.+) ]]; then
      current_branch="${BASH_REMATCH[1]}"
    elif [ -z "$line" ] && [ -n "$current_path" ]; then
      # End of a worktree block — process it
      _backfill_one_worktree "$current_path" "$current_branch" "$main_worktree"
      current_path=""
      current_branch=""
    fi
  done <<< "$worktree_lines"

  # Handle last block if file does not end with a blank line
  if [ -n "$current_path" ]; then
    _backfill_one_worktree "$current_path" "$current_branch" "$main_worktree"
  fi
}

# Internal helper: attempt to backfill a single worktree entry.
# Skips the main repo, detached HEADs, already-locked worktrees, and worktrees
# with no resolvable PR.
#
# Args: worktree_path branch_name main_worktree_path
# main_worktree_path is the path from the first porcelain block (always the main
# repo). It is passed explicitly because RITE_PROJECT_ROOT is derived via
# git rev-parse and resolves to the current worktree when run from inside a
# feature worktree — comparing against it would wrongly skip the standing worktree.
_backfill_one_worktree() {
  local wt_path="$1"
  local branch="${2:-}"
  local main_worktree="${3:-}"

  # Skip the main project root (not a feature worktree).
  # Use the explicit main_worktree arg (from porcelain block 1); fall back to
  # RITE_PROJECT_ROOT only when main_worktree is empty (standalone/test invocation).
  local _main_root
  _main_root="${main_worktree:-${RITE_PROJECT_ROOT:-}}"
  if [ -n "$_main_root" ] && [ "$wt_path" = "$_main_root" ]; then
    return 0
  fi

  # Skip detached HEAD worktrees (no branch to look up)
  if [ -z "$branch" ]; then
    return 0
  fi

  # Skip worktrees that are not on disk
  if [ ! -d "$wt_path" ]; then
    return 0
  fi

  local issue_num=""

  # Check if any existing lock dir's worktree file already maps to this path
  # (covers the case where acquire_issue_lock already ran for this worktree)
  local existing_lock
  while IFS= read -r existing_lock; do
    local locked_wt
    locked_wt=$(cat "$existing_lock" 2>/dev/null || echo "")
    if [ "$locked_wt" = "$wt_path" ]; then
      # Already have a lock with worktree metadata — nothing to do
      return 0
    fi
  done < <(ls "${RITE_LOCK_DIR}"/issue-*.lock/worktree 2>/dev/null || true)

  # Resolve issue number from open PR body
  issue_num=$(_resolve_issue_from_branch "$branch")

  if [ -z "$issue_num" ]; then
    # No PR or no Closes/Fixes reference — nothing to backfill for this worktree
    return 0
  fi

  local lock_dir="${RITE_LOCK_DIR}/issue-${issue_num}.lock"

  # Skip if lock dir already exists (active workflow or already backfilled)
  if [ -d "$lock_dir" ]; then
    # Write worktree file if missing (upgrades a pid-only lock dir)
    if [ ! -f "$lock_dir/worktree" ]; then
      echo "$wt_path" > "$lock_dir/worktree" 2>/dev/null || true
    fi
    return 0
  fi

  # Create backfill lock dir with worktree metadata (no pid — metadata only)
  mkdir -p "$lock_dir" 2>/dev/null || return 0
  echo "$wt_path" > "$lock_dir/worktree" 2>/dev/null || true

  echo "  ✓ Backfilled lock for issue #${issue_num} → $(basename "$wt_path")" >&2
}

# Resolve the issue number for a branch by looking up its open PR.
# Parses "Closes/Fixes/Resolves #N" from the PR body.
#
# Args: branch_name
# Stdout: issue number, or empty string if not found
# Returns: 0 always
_resolve_issue_from_branch() {
  local branch="$1"

  # Look up open PR for this branch (--state open only — we're backfilling active worktrees)
  local pr_json
  pr_json=$(gh pr list --head "$branch" --state open \
    --json number,body --limit 1 \
    --jq '.[0] // empty' 2>/dev/null || echo "")

  if [ -z "$pr_json" ]; then
    return 0
  fi

  # Extract Closes/Fixes/Resolves #N from PR body
  local pr_body issue_num
  pr_body=$(echo "$pr_json" | jq -r '.body // ""' 2>/dev/null || echo "")
  issue_num=$(echo "$pr_body" | \
    grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | \
    head -1 | grep -oE '[0-9]+' || true)

  echo "${issue_num:-}"
}
