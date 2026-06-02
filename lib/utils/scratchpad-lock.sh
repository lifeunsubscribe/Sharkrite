#!/bin/bash
# lib/utils/scratchpad-lock.sh - Portable advisory lock for the shared scratchpad file
#
# All scratchpad writers MUST acquire this lock before modifying SCRATCHPAD_FILE.
# The lock is a directory (mkdir is atomic) containing a PID file written atomically
# via a temp-file rename (no TOCTOU between mkdir and PID write).
#
# Features:
#   - Atomic PID write: temp file + mv, so a waiting process never sees a window
#     where the lock dir exists but has no PID file (the old TOCTOU).
#   - Stale-lock reclaim: dead holder's lock is removed and the waiter retries.
#   - Timeout is a hard failure (exit 1) — never proceeds without the lock.
#   - Trap-based release: _setup_scratchpad_lock_trap installs EXIT/INT/TERM handlers.
#   - flock fast-path on Linux: where flock(1) is available, use it (faster + avoids
#     the directory-based machinery entirely for the common case).
#   - Re-entrancy guard: nested acquire() calls in the same shell are safe — the
#     depth counter (_SCRATCHPAD_LOCK_DEPTH) tracks nesting; the OS lock is acquired
#     once (0→1) and released once (1→0), so inner callers never drop the outer lock.
#
# Usage (from scripts that write the scratchpad):
#
#   source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
#   acquire_scratchpad_lock        # exits 1 on timeout
#   _setup_scratchpad_lock_trap    # release lock on EXIT/INT/TERM
#   ... modify SCRATCHPAD_FILE ...
#   release_scratchpad_lock        # explicit release (trap also fires on exit)
#
# Requires: SCRATCHPAD_FILE set (by config.sh or caller)
# LOCKFILE is derived from SCRATCHPAD_FILE and set by acquire_scratchpad_lock.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing).
# ORDERING CRITICAL: this guard must appear before ALL variable initializations,
# including _SCRATCHPAD_LOCK_DEPTH=0 below.  If the guard fires after that line,
# a re-source mid-lock would reset the re-entrancy counter to 0 and corrupt the
# nesting invariant this PR introduces.
if declare -f acquire_scratchpad_lock >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Internal state — set by acquire_scratchpad_lock, read by release_scratchpad_lock
# (All lines below are guarded by the re-source check above.)
# ---------------------------------------------------------------------------
_SCRATCHPAD_LOCK_FD=200          # File descriptor used for flock fast-path
_SCRATCHPAD_LOCK_HELD=false      # True once lock is successfully acquired
_SCRATCHPAD_LOCKFILE=""          # Set to actual lockfile path on acquire
# Strategy used at acquire time: "flock" or "mkdir".
# Persisted so that release always uses the same path type as acquire, regardless
# of whether PATH changes between the two calls or whether another process on a
# shared filesystem chose a different strategy for the same lock path.
_SCRATCHPAD_LOCK_STRATEGY=""     # "flock" or "mkdir" — set by acquire, read by release
# Re-entrancy depth counter: incremented on each nested acquire, decremented on
# each release. The actual OS-level lock is only acquired when depth goes 0→1
# and only released when depth goes 1→0. This prevents a nested acquire from
# re-opening FD 200 (which would break the outer caller's lock association) and
# prevents an inner release from dropping the lock while the outer caller still
# needs it.
_SCRATCHPAD_LOCK_DEPTH=0         # 0 = not held; >0 = held (value = nesting depth)

# ---------------------------------------------------------------------------
# acquire_scratchpad_lock
#
# Acquires the scratchpad lock. On success returns 0 and sets
# _SCRATCHPAD_LOCK_HELD=true. On timeout exits the calling process with
# code 1 and an actionable message — NEVER proceeds without holding the lock.
#
# Re-entrant: safe to call while already holding the lock (same shell/process).
# Nested calls increment _SCRATCHPAD_LOCK_DEPTH and return 0 immediately;
# the OS-level lock is not re-acquired. Each acquire must be paired with a
# matching release_scratchpad_lock() call.
#
# Timeout: 30 seconds (configurable via RITE_SCRATCHPAD_LOCK_TIMEOUT)
# ---------------------------------------------------------------------------
acquire_scratchpad_lock() {
  local scratchpad_file="${SCRATCHPAD_FILE:-}"
  if [ -z "$scratchpad_file" ]; then
    echo "ERROR: acquire_scratchpad_lock: SCRATCHPAD_FILE is not set" >&2
    exit 1
  fi

  # Re-entrancy guard: if the lock is already held by this process (same shell),
  # increment the depth counter and return immediately.  This prevents the flock
  # fast-path from re-opening FD 200 (which would discard the outer caller's
  # open-file-description and break mutual exclusion) and prevents the mkdir path
  # from incorrectly reclaiming its own lock (same PID → dead-process check fails
  # in an unexpected direction).  The matching release_scratchpad_lock() call
  # decrements the counter and only actually releases the OS lock at depth 0→1.
  if [ "${_SCRATCHPAD_LOCK_HELD:-false}" = "true" ]; then
    _SCRATCHPAD_LOCK_DEPTH=$(( _SCRATCHPAD_LOCK_DEPTH + 1 ))
    return 0
  fi

  local lockfile="${scratchpad_file}.lock"
  _SCRATCHPAD_LOCKFILE="$lockfile"

  local max_attempts="${RITE_SCRATCHPAD_LOCK_TIMEOUT:-30}"

  # ------------------------------------------------------------------
  # Fast path: flock(1) is available (Linux, Homebrew util-linux on mac)
  # flock on a regular file is simpler, atomic, and kernel-maintained.
  #
  # Override: if RITE_SCRATCHPAD_LOCK_STRATEGY=mkdir is set, skip flock
  # entirely and use the portable mkdir path.  This is used in tests to
  # force a strategy that makes lock state observable as a filesystem
  # directory (so the RETURN-trap tests can assert [ ! -d "$lockfile" ]).
  # ------------------------------------------------------------------
  if [ "${RITE_SCRATCHPAD_LOCK_STRATEGY:-}" != "mkdir" ] && command -v flock >/dev/null 2>&1; then
    # Clean up any leftover mkdir-style lock directory from a previous run where
    # flock was not available.  The directory would block flock from creating its
    # plain-file lock at the same path (open(2) fails if a directory is in the way).
    if [ -d "$lockfile" ]; then
      # Only reclaim if the directory has no live holder PID.
      local _stale_pid
      _stale_pid=$(cat "$lockfile/pid" 2>/dev/null || true)
      if [ -z "$_stale_pid" ] || ! kill -0 "$_stale_pid" 2>/dev/null; then
        echo "scratchpad-lock: removing leftover mkdir-style lock dir before flock acquire" >&2
        rm -rf "$lockfile" 2>/dev/null || true
      fi
    fi
    # Open (or create) the lock file on our chosen fd
    # shellcheck disable=SC1083
    eval "exec ${_SCRATCHPAD_LOCK_FD}>\"$lockfile\""
    if ! flock -w "$max_attempts" "$_SCRATCHPAD_LOCK_FD" 2>/dev/null; then
      echo "ERROR: Could not acquire scratchpad lock within ${max_attempts}s." >&2
      echo "       If a previous run crashed, remove the lock file:" >&2
      echo "       rm -f \"$lockfile\"" >&2
      _SCRATCHPAD_LOCK_HELD=false
      _SCRATCHPAD_LOCK_DEPTH=0
      exit 1
    fi
    _SCRATCHPAD_LOCK_HELD=true
    _SCRATCHPAD_LOCK_STRATEGY="flock"
    _SCRATCHPAD_LOCK_DEPTH=1
    return 0
  fi

  # ------------------------------------------------------------------
  # Portable path: mkdir-based lock with atomic PID write via mv
  #
  # Problem with the previous implementation:
  #   mkdir "$LOCKFILE" && echo $$ > "$LOCKFILE/pid"
  # Between those two operations another waiter could see:
  #   - lock dir exists
  #   - no pid file
  #   - and conclude "stale lock" → rm -rf → reclaim race
  #
  # Fix: write PID to a temp file first, then rename into the lock dir.
  # Because rename(2) is atomic within the same filesystem, a waiter
  # either sees the pid file or it doesn't — no half-written state.
  # ------------------------------------------------------------------

  # Clean up any leftover flock-style lock file (plain file, not dir).
  # This handles the case where flock was previously available but isn't now.
  if [ -f "$lockfile" ] && [ ! -d "$lockfile" ]; then
    rm -f "$lockfile"
  fi

  local lock_attempts=0
  local pid_tmp

  while ! mkdir "$lockfile" 2>/dev/null; do
    # Check if the holding process is still alive
    if [ -f "$lockfile/pid" ]; then
      local lock_pid
      lock_pid=$(cat "$lockfile/pid" 2>/dev/null || true)
      # kill -0: same-host assumption — only valid within a single PID namespace.
      # Do not point SCRATCHPAD_FILE (and thus its lockfile) at shared/network
      # storage; kill -0 checks the local process table only and will give false
      # "process is dead" results for PIDs held by processes on other hosts.
      if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        # Holding process is dead — reclaim the stale lock
        echo "scratchpad-lock: reclaiming stale lock from dead process (PID $lock_pid)" >&2
        rm -rf "$lockfile" 2>/dev/null || true
        continue  # retry mkdir immediately
      fi
      # Lock is held by a live process — wait
    else
      # Lock dir exists but no PID file yet.
      # With the old code this was "crashed between mkdir and PID write" and
      # was treated as stale. With the new atomic mv approach, this window
      # is eliminated for holders using this module. However, a holder still
      # using the old code (or a very brief race during startup) could still
      # produce this state. Give it one second grace before reclaiming.
      sleep 1
      if [ ! -f "$lockfile/pid" ]; then
        echo "scratchpad-lock: reclaiming lock dir with no PID after grace period" >&2
        rm -rf "$lockfile" 2>/dev/null || true
        continue
      fi
    fi

    if [ "$lock_attempts" -eq 0 ]; then
      echo "scratchpad-lock: waiting for lock held by another process..." >&2
    fi

    lock_attempts=$((lock_attempts + 1))
    if [ "$lock_attempts" -ge "$max_attempts" ]; then
      # Hard failure — never proceed without holding the lock
      echo "ERROR: Scratchpad lock timeout after ${max_attempts}s." >&2
      echo "       Another process may be stuck, or the lock may be stale." >&2
      echo "       To recover, remove the lock directory:" >&2
      echo "       rm -rf \"$lockfile\"" >&2
      _SCRATCHPAD_LOCK_HELD=false
      _SCRATCHPAD_LOCK_DEPTH=0
      exit 1
    fi
    sleep 1
  done

  # We now own the lock directory. Write our PID atomically via temp+rename.
  # Any waiter that checks after this point will see a valid PID file.
  pid_tmp=$(mktemp "${lockfile}/pid.XXXXXX")
  echo $$ > "$pid_tmp"
  mv "$pid_tmp" "${lockfile}/pid"

  _SCRATCHPAD_LOCK_HELD=true
  _SCRATCHPAD_LOCK_STRATEGY="mkdir"
  _SCRATCHPAD_LOCK_DEPTH=1
  return 0
}

# ---------------------------------------------------------------------------
# release_scratchpad_lock
#
# Releases the scratchpad lock. Only releases if this process currently holds
# it (PID check for mkdir path; fd close for flock path). Safe to call
# multiple times (idempotent).
# ---------------------------------------------------------------------------
release_scratchpad_lock() {
  if [ "${_SCRATCHPAD_LOCK_HELD:-false}" != "true" ]; then
    return 0
  fi

  # Re-entrancy guard: if there are nested acquires still active, decrement the
  # depth counter and return without releasing the OS-level lock.  The outermost
  # caller (depth 1→0) performs the actual release.
  if [ "${_SCRATCHPAD_LOCK_DEPTH:-1}" -gt 1 ]; then
    _SCRATCHPAD_LOCK_DEPTH=$(( _SCRATCHPAD_LOCK_DEPTH - 1 ))
    return 0
  fi

  local lockfile="${_SCRATCHPAD_LOCKFILE:-${SCRATCHPAD_FILE:-}.lock}"

  # Use the strategy recorded at acquire time, not a fresh command -v check.
  # Re-checking command -v flock here would cause a mismatch if PATH changed
  # between acquire and release (e.g., a subprocess altered PATH), or if two
  # processes on a shared filesystem chose different strategies for the same path.
  if [ "${_SCRATCHPAD_LOCK_STRATEGY:-}" = "flock" ]; then
    # Release flock by closing the file descriptor.
    # Do NOT rm the lockfile here: flock keys on the inode behind the open fd.
    # Removing the file lets a new acquirer open a fresh inode and take the lock
    # concurrently while a previously-blocked waiter still holds the old unlinked
    # inode, breaking mutual exclusion.  The kernel releases the lock automatically
    # when the fd is closed.
    flock -u "$_SCRATCHPAD_LOCK_FD" 2>/dev/null || true
    eval "exec ${_SCRATCHPAD_LOCK_FD}>&-" 2>/dev/null || true
  else
    # mkdir-style lock: verify PID before removing
    if [ -d "$lockfile" ] && [ -f "$lockfile/pid" ]; then
      local lock_pid
      lock_pid=$(cat "$lockfile/pid" 2>/dev/null || true)
      if [ "$lock_pid" = "$$" ]; then
        rm -rf "$lockfile" 2>/dev/null || true
      fi
    fi
  fi

  _SCRATCHPAD_LOCK_HELD=false
  _SCRATCHPAD_LOCK_STRATEGY=""
  _SCRATCHPAD_LOCK_DEPTH=0
}

# ---------------------------------------------------------------------------
# _setup_scratchpad_lock_trap
#
# Installs a trap that releases the scratchpad lock on EXIT, INT, and TERM.
# Call this immediately after acquire_scratchpad_lock in scripts that do not
# have their own EXIT trap, or merge it into an existing trap.
#
# Note: This overwrites any existing EXIT/INT/TERM traps. If the caller already
# has traps, merge manually:
#   trap '_scratchpad_lock_trap_release; <existing-cleanup>' EXIT INT TERM
#
# Re-entrancy depth on abnormal exit: if the lock was acquired at depth > 1
# (nested callers), the depth counter reflects the nesting level at the point
# the process dies.  A plain release_scratchpad_lock() call would only
# decrement the counter by 1, leaving depth > 0 and skipping the OS-level
# release.  The trap handler must reset the depth to 1 first so that
# release_scratchpad_lock() performs the actual OS-level release.
# ---------------------------------------------------------------------------
_scratchpad_lock_trap_release() {
  # Force depth to 1 so release_scratchpad_lock performs the actual OS-level
  # release regardless of how many nested acquires were in flight when the
  # process exited abnormally.  On a normal (non-nested) exit this is a no-op
  # since depth is already 1 at that point.
  if [ "${_SCRATCHPAD_LOCK_HELD:-false}" = "true" ]; then
    _SCRATCHPAD_LOCK_DEPTH=1
  fi
  release_scratchpad_lock
}

_setup_scratchpad_lock_trap() {
  trap '_scratchpad_lock_trap_release' EXIT INT TERM
}
