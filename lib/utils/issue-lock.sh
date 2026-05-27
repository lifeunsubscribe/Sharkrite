#!/bin/bash
# lib/utils/issue-lock.sh - Per-issue locking to prevent concurrent rite invocations
#
# Prevents two `rite N` invocations from entering the same worktree simultaneously,
# which would corrupt in-flight work. Uses mkdir-style atomic locking with PID file
# for liveness checking and stale lock reclamation.
#
# Usage:
#   acquire_issue_lock <issue_number>  # Returns 0 on success, 1 if locked by live process
#   release_issue_lock <issue_number>  # Cleanup lock directory

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
