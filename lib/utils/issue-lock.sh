#!/bin/bash
# lib/utils/issue-lock.sh - Per-issue locking to prevent concurrent rite invocations
#
# Prevents two `rite N` invocations from entering the same worktree simultaneously,
# which would corrupt in-flight work. Uses mkdir-style atomic locking with PID file
# for liveness checking and stale lock reclamation.
#
# Usage:
#   acquire_issue_lock <issue_number>          # Returns 0 on success, 1 if locked by live process
#   release_issue_lock <issue_number>          # Cleanup lock directory
#   acquire_pr_followup_lock <pr_number>       # Returns 0 on success, 1 on timeout
#   release_pr_followup_lock <pr_number>       # Cleanup followup lock directory

set -euo pipefail

# Source config if RITE_LOCK_DIR not already set (defined in config.sh)
if [ -z "${RITE_LOCK_DIR:-}" ]; then
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_SCRIPT_DIR/config.sh"
fi

# Acquire per-issue lock with PID-based liveness checking
# Args: issue_number
# Returns: 0 on success, 1 if locked by another live process
acquire_issue_lock() {
  local issue_number="$1"
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

# backfill_worktree_locks
#
# Walks the current repo's worktree list and creates a lock-dir hint for any
# worktree that is missing an issue-N.lock entry. This backfills worktrees
# that were created before the lock infrastructure landed (PR #67) or that
# bypassed acquire_issue_lock for any other reason.
#
# The backfill lock-dir is intentionally NOT a live lock:
#   - No pid file → acquire_issue_lock reclaims it immediately when rite N runs
#   - Contains a "worktree" metadata file with the worktree path
#   - Contains a "backfilled" marker so callers can distinguish from live locks
#
# Issue number is derived from (in priority order):
#   1. Branch name regex: issue-?([0-9]+)
#   2. Worktree path regex: issue-?([0-9]+)
#   3. gh pr list --head <branch> closingIssuesReferences (API call, last resort)
#
# Args: [--quiet]  Suppress informational output
# Returns: 0 always (best-effort, non-destructive)
backfill_worktree_locks() {
  local quiet="false"
  if [ "${1:-}" = "--quiet" ]; then
    quiet="true"
  fi

  # Ensure lock directory exists
  mkdir -p "${RITE_LOCK_DIR}" 2>/dev/null || return 0

  # Identify the main (primary) checkout so we can skip it.
  # First try to match by branch name (main/master); fall back to position: git
  # always lists the primary worktree first in the porcelain output.
  local main_worktree=""
  main_worktree=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{path=$2} /^bare$/{print path; exit} /^branch refs\/heads\/(main|master)$/{print path; exit}' || true)
  if [ -z "$main_worktree" ]; then
    # Default branch is not main/master — fall back to position (always first)
    main_worktree=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}' || true)
  fi

  # Parse porcelain output into arrays
  local _wt_path="" _wt_branch="" _wt_paths=() _wt_branches=()
  while IFS= read -r _line; do
    if [[ "$_line" =~ ^worktree\ (.+) ]]; then
      _wt_path="${BASH_REMATCH[1]}"
      _wt_branch=""
    elif [[ "$_line" =~ ^branch\ refs/heads/(.+) ]]; then
      _wt_branch="${BASH_REMATCH[1]}"
    elif [ -z "$_line" ] && [ -n "$_wt_path" ]; then
      # End of block — collect if not main and directory exists
      if [ "$_wt_path" != "$main_worktree" ] && [ -d "$_wt_path" ]; then
        _wt_paths+=("$_wt_path")
        _wt_branches+=("${_wt_branch:-}")
      fi
      _wt_path=""
      _wt_branch=""
    fi
  done <<< "$(git worktree list --porcelain 2>/dev/null || true)"
  # Handle last block if porcelain output lacks trailing blank line
  if [ -n "$_wt_path" ] && [ "$_wt_path" != "$main_worktree" ] && [ -d "$_wt_path" ]; then
    _wt_paths+=("$_wt_path")
    _wt_branches+=("${_wt_branch:-}")
  fi

  local _backfilled=0
  local _skipped=0

  for _idx in "${!_wt_paths[@]}"; do
    local _path="${_wt_paths[$_idx]}"
    local _branch="${_wt_branches[$_idx]:-}"

    # --- Derive issue number ---
    local _issue_num=""

    # 1. From branch name: feat/issue-42-..., fix/issue42-..., etc.
    if [[ "$_branch" =~ issue-?([0-9]+) ]]; then
      _issue_num="${BASH_REMATCH[1]}"
    fi

    # 2. From worktree path suffix (e.g. sh-wt/fx-something_b60-91-27-35 contains numbers
    #    but that's the worktree dir name, not the issue number — use a stricter pattern)
    if [ -z "$_issue_num" ] && [[ "$_path" =~ /issue-?([0-9]+)[^/]*$ ]]; then
      _issue_num="${BASH_REMATCH[1]}"
    fi

    # 3. API fallback: look up open PR for this branch and read closingIssuesReferences
    if [ -z "$_issue_num" ] && [ -n "$_branch" ] && command -v gh &>/dev/null; then
      local _pr_json
      _pr_json=$(gh pr list --head "$_branch" --state open --json number,closingIssuesReferences \
        --jq '.[0] // empty' 2>/dev/null || true)
      if [ -n "$_pr_json" ]; then
        # Try closingIssuesReferences first (most reliable)
        _issue_num=$(echo "$_pr_json" | \
          command -p jq -r '(.closingIssuesReferences // [])[0].number // empty' 2>/dev/null || true)
        # Fall back to parsing "Closes #N" from PR body if references not populated
        if [ -z "$_issue_num" ] || [ "$_issue_num" = "null" ]; then
          local _pr_body
          _pr_body=$(gh pr list --head "$_branch" --state open --json body \
            --jq '.[0].body // ""' 2>/dev/null || true)
          _issue_num=$(echo "$_pr_body" | \
            grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | \
            head -1 | grep -oE '[0-9]+' || true)
        fi
      fi
    fi

    if [ -z "$_issue_num" ] || [ "$_issue_num" = "null" ]; then
      _skipped=$((_skipped + 1))
      [ "$quiet" = "false" ] && echo "  backfill: no issue found for branch '${_branch:-unknown}' (${_path})" >&2
      continue
    fi

    local _lock_dir="${RITE_LOCK_DIR}/issue-${_issue_num}.lock"

    # Skip if a live lock already exists (has a pid file with a live PID)
    if [ -d "$_lock_dir" ] && [ -f "$_lock_dir/pid" ]; then
      local _existing_pid
      _existing_pid=$(cat "$_lock_dir/pid" 2>/dev/null || echo "")
      # If PID is numeric and live, skip — a real workflow is running
      if [[ "$_existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$_existing_pid" 2>/dev/null; then
        _skipped=$((_skipped + 1))
        [ "$quiet" = "false" ] && \
          echo "  backfill: issue #${_issue_num} has live lock (PID $_existing_pid), skipping" >&2
        continue
      fi
    fi

    # Skip if already backfilled with the correct worktree path
    if [ -d "$_lock_dir" ] && [ -f "$_lock_dir/backfilled" ]; then
      local _existing_wt
      _existing_wt=$(cat "$_lock_dir/worktree" 2>/dev/null || echo "")
      if [ "$_existing_wt" = "$_path" ]; then
        _skipped=$((_skipped + 1))
        continue
      fi
    fi

    # Create backfill lock dir (may already exist as stale — that's fine)
    mkdir -p "$_lock_dir" 2>/dev/null || {
      [ "$quiet" = "false" ] && \
        echo "  backfill: could not create lock dir for issue #${_issue_num}" >&2
      continue
    }

    # Write metadata files (no pid file — acquire_issue_lock reclaims gracefully)
    echo "$_path"   > "$_lock_dir/worktree"   2>/dev/null || true
    echo "$_branch" > "$_lock_dir/branch"     2>/dev/null || true
    echo "backfill" > "$_lock_dir/backfilled" 2>/dev/null || true

    _backfilled=$((_backfilled + 1))
    [ "$quiet" = "false" ] && \
      echo "  backfill: issue #${_issue_num} → ${_path}" >&2
  done

  [ "$quiet" = "false" ] && [ "$((_backfilled + _skipped))" -gt 0 ] && \
    echo "  backfill: ${_backfilled} lock(s) written, ${_skipped} skipped" >&2

  return 0
}

# lookup_issue_for_worktree WORKTREE_PATH
#
# Reads the backfill metadata from the lock directory to find the issue number
# for a worktree path. Faster than gh API calls — reads local filesystem only.
#
# Sets: BACKFILL_ISSUE_NUMBER (the issue number, or "" if not found)
# Returns: 0 if found, 1 if not found
lookup_issue_for_worktree() {
  local worktree_path="$1"
  BACKFILL_ISSUE_NUMBER=""

  # Scan all issue-N.lock dirs for a matching worktree file
  if [ ! -d "${RITE_LOCK_DIR}" ]; then
    return 1
  fi

  local _lock_dir
  for _lock_dir in "${RITE_LOCK_DIR}"/issue-*.lock; do
    [ -d "$_lock_dir" ] || continue
    local _stored_wt
    _stored_wt=$(cat "$_lock_dir/worktree" 2>/dev/null || echo "")
    if [ "$_stored_wt" = "$worktree_path" ]; then
      # Extract issue number from lock dir name
      local _dir_name="${_lock_dir##*/}"      # issue-N.lock
      local _no_prefix="${_dir_name#issue-}"  # N.lock
      BACKFILL_ISSUE_NUMBER="${_no_prefix%.lock}"  # N
      return 0
    fi
  done

  return 1
}
