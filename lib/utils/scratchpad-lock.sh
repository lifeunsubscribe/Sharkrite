#!/bin/bash
# lib/utils/scratchpad-lock.sh - Portable advisory lock for the shared scratchpad file
#
# All scratchpad writers MUST acquire this lock before modifying SCRATCHPAD_FILE.
# The portable path uses a symlink lock: `ln -s "$$" "$lockfile"` is atomic
# (symlink(2)/POSIX), so the lock carries its owner's PID the instant it exists.
# There is no create→PID-write window that a waiter can exploit.
#
# Features:
#   - Atomic PID-bearing acquire: ln -s creates a symlink whose target IS the PID,
#     so a waiter never sees a window where the lock exists but has no PID.
#   - Stale-lock reclaim: rename first (mv, atomic; exactly one racer wins), then
#     remove the renamed path and retry. Two waiters racing on a dead holder's lock
#     each try mv; only one succeeds, serialising the steal.
#   - Timeout is a soft failure (return 1) — never proceeds without the lock,
#     but never kills the caller either. All scratchpad writes are advisory;
#     callers must skip the write on acquire failure, not abort. (The old
#     `exit 1` here terminated merge-pr.sh straight through `|| true`,
#     converting successfully merged issues into batch failures.)
#   - Trap-based release: _setup_scratchpad_lock_trap installs EXIT/INT/TERM handlers.
#   - flock fast-path on Linux: where flock(1) is available, use it (faster + avoids
#     the symlink-based machinery entirely for the common case).
#   - Re-entrancy guard: nested acquire() calls in the same shell are safe — the
#     depth counter (_SCRATCHPAD_LOCK_DEPTH) tracks nesting; the OS lock is acquired
#     once (0→1) and released once (1→0), so inner callers never drop the outer lock.
#
# Usage (from scripts that write the scratchpad):
#
#   source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
#   acquire_scratchpad_lock || return 0   # returns 1 on timeout — skip the write
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
# _SCRATCHPAD_LOCK_HELD=true. On timeout returns 1 with lock state reset
# (HELD=false, DEPTH=0; flock fd closed) — NEVER proceeds without holding
# the lock, and NEVER exits the caller. Callers must treat acquire failure
# as "skip this advisory write": `exit` from a same-shell function is not
# catchable by `|| true`, and a lost advisory write must never fail the
# workflow that attempted it.
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
  # entirely and use the portable symlink path.  This is used in tests to
  # force a strategy that makes lock state observable as a filesystem
  # symlink (so the RETURN-trap tests can assert [ ! -L "$lockfile" ]).
  # ------------------------------------------------------------------
  if [ "${RITE_SCRATCHPAD_LOCK_STRATEGY:-}" != "mkdir" ] && command -v flock >/dev/null 2>&1; then
    # Clean up any leftover symlink- or directory-style lock from a previous run
    # where flock was not available.  Either would block flock's open(2)/exec.
    if [ -L "$lockfile" ]; then
      # Only reclaim if the symlink has no live holder PID.
      local _stale_pid
      _stale_pid=$(readlink "$lockfile" 2>/dev/null || true)
      if [ -z "$_stale_pid" ] || ! kill -0 "$_stale_pid" 2>/dev/null; then
        echo "scratchpad-lock: removing leftover symlink-style lock before flock acquire" >&2
        rm -f "$lockfile" 2>/dev/null || true
      fi
    elif [ -d "$lockfile" ]; then
      # Legacy directory-style lock from a pre-#1651 run. Only reclaim if the
      # recorded holder PID is dead (or missing) — prevents stealing a live lock.
      local _dir_pid
      _dir_pid=$(cat "$lockfile/pid" 2>/dev/null || true)
      if [ -z "$_dir_pid" ] || ! kill -0 "$_dir_pid" 2>/dev/null; then
        echo "scratchpad-lock: removing leftover directory-style lock before flock acquire" >&2
        rm -rf "$lockfile" 2>/dev/null || true
      fi
    fi
    # Open (or create) the lock file on our chosen fd
    # shellcheck disable=SC1083
    eval "exec ${_SCRATCHPAD_LOCK_FD}>\"$lockfile\""
    if ! flock -w "$max_attempts" "$_SCRATCHPAD_LOCK_FD" 2>/dev/null; then
      echo "WARNING: scratchpad lock busy after ${max_attempts}s — caller will skip this advisory write." >&2
      echo "         If a previous run crashed, remove the lock file: rm -f \"$lockfile\"" >&2
      # Close the fd opened for this failed acquire so it doesn't leak.
      eval "exec ${_SCRATCHPAD_LOCK_FD}>&-" 2>/dev/null || true
      _SCRATCHPAD_LOCK_HELD=false
      _SCRATCHPAD_LOCK_DEPTH=0
      return 1
    fi
    _SCRATCHPAD_LOCK_HELD=true
    _SCRATCHPAD_LOCK_STRATEGY="flock"
    _SCRATCHPAD_LOCK_DEPTH=1
    return 0
  fi

  # ------------------------------------------------------------------
  # Portable path: symlink-based atomic PID-bearing lock
  #
  # ln -s "$$" "$lockfile" is atomic (symlink(2)/POSIX): exactly one of N
  # competing processes wins when multiple call it simultaneously.  The
  # symlink target IS the holder's PID — there is no create→PID-write
  # window, so the grace-reclaim heuristic is not needed and is deleted.
  #
  # Stale reclaim: rename first (mv "$lockfile" "$lockfile.stale.$$"),
  # then remove.  mv is atomic; two waiters that both see a dead PID each
  # try mv but only one succeeds, serialising the steal.  The loser's mv
  # returns non-zero and it falls through to the next sleep+retry cycle.
  # ------------------------------------------------------------------

  # Clean up any leftover flock-style lock file (plain file, not symlink) or
  # a stale directory-style lock from a pre-#1651 run with a dead holder PID.
  # Skipping this would send the while loop into the else-branch on every iteration
  # for the directory case (infinite spin on live holders handled there instead).
  if [ -f "$lockfile" ] && [ ! -L "$lockfile" ]; then
    rm -f "$lockfile"
  elif [ -d "$lockfile" ]; then
    local _pre_dir_pid
    _pre_dir_pid=$(cat "$lockfile/pid" 2>/dev/null || true)
    if [ -z "$_pre_dir_pid" ] || ! kill -0 "$_pre_dir_pid" 2>/dev/null; then
      rm -rf "$lockfile" 2>/dev/null || true
    fi
    # Live directory-style holder: leave it in place; the while loop handles it.
  fi

  local lock_attempts=0

  while ! ln -s "$$" "$lockfile" 2>/dev/null; do
    # Read the holder's PID from the symlink target.
    local lock_pid
    lock_pid=$(readlink "$lockfile" 2>/dev/null || true)

    if [ -n "$lock_pid" ]; then
      # kill -0: same-host assumption — only valid within a single PID namespace.
      # Do not point SCRATCHPAD_FILE (and thus its lockfile) at shared/network
      # storage; kill -0 checks the local process table only and will give false
      # "process is dead" results for PIDs held by processes on other hosts.
      if ! kill -0 "$lock_pid" 2>/dev/null; then
        # Holder is dead — rename first so only one waiter wins the steal,
        # then remove the renamed path and retry ln -s.
        local stale_path="${lockfile}.stale.$$"
        if mv "$lockfile" "$stale_path" 2>/dev/null; then
          # Verify the renamed symlink still carries the dead PID we observed.
          # Between kill -0 and mv, a fresh acquirer could have replaced the
          # stale symlink with a new live-PID one; we'd then hold (and delete)
          # their live lock, admitting two simultaneous holders.
          local _post_mv_pid
          _post_mv_pid=$(readlink "$stale_path" 2>/dev/null || true)
          if [ "$_post_mv_pid" = "$lock_pid" ]; then
            echo "scratchpad-lock: reclaiming stale lock from dead process (PID $lock_pid)" >&2
            rm -f "$stale_path" 2>/dev/null || true
          else
            # PID changed — a new acquirer slipped in between our check and mv.
            # Restore their lock and let them keep it; we retry ln -s normally.
            mv "$stale_path" "$lockfile" 2>/dev/null || true
          fi
        fi
        # Whether mv succeeded or failed, retry ln -s immediately.
        continue
      fi
      # Lock is held by a live process — fall through to wait below.
    else
      # readlink returned empty. Two cases:
      # 1. Lockfile is a directory (legacy pre-#1651 lock): check the PID file.
      #    Dead holder → rename-before-remove and retry; live holder → fall
      #    through to increment + sleep (avoids infinite spin on the directory).
      # 2. No lockfile at all: the holder released between our ln -s failing and
      #    readlink being called — retry immediately without counting the wait.
      if [ -d "$lockfile" ]; then
        local _dir_pid
        _dir_pid=$(cat "$lockfile/pid" 2>/dev/null || true)
        if [ -z "$_dir_pid" ] || ! kill -0 "$_dir_pid" 2>/dev/null; then
          local _stale_dir="${lockfile}.stale.$$"
          if mv "$lockfile" "$_stale_dir" 2>/dev/null; then
            echo "scratchpad-lock: reclaiming stale directory-style lock from dead process (PID ${_dir_pid:-unknown})" >&2
            rm -rf "$_stale_dir" 2>/dev/null || true
          fi
          continue  # retry ln -s immediately
        fi
        # Live directory-style holder: fall through to increment + sleep.
      elif [ ! -e "$lockfile" ] && [ ! -L "$lockfile" ]; then
        # Lockfile vanished — holder just released; retry immediately.
        continue
      fi
      # Unexpected non-symlink obstruction: fall through to increment + sleep.
    fi

    if [ "$lock_attempts" -eq 0 ]; then
      echo "scratchpad-lock: waiting for lock held by another process..." >&2
    fi

    lock_attempts=$((lock_attempts + 1))
    if [ "$lock_attempts" -ge "$max_attempts" ]; then
      # Soft failure — never proceed without holding the lock, but return
      # (not exit) so the caller can skip its advisory write and continue.
      echo "WARNING: scratchpad lock busy after ${max_attempts}s — caller will skip this advisory write." >&2
      echo "         If the lock is stale, remove it: rm -f \"$lockfile\"" >&2
      _SCRATCHPAD_LOCK_HELD=false
      _SCRATCHPAD_LOCK_DEPTH=0
      return 1
    fi
    sleep 1
  done

  # Acquired: the symlink target is already our PID — no separate write needed.

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
    # symlink-style lock: verify this process still owns it before removing
    if [ -L "$lockfile" ]; then
      local lock_pid
      lock_pid=$(readlink "$lockfile" 2>/dev/null || true)
      if [ "$lock_pid" = "$$" ]; then
        rm -f "$lockfile" 2>/dev/null || true
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
