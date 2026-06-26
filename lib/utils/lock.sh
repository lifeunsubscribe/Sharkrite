#!/bin/bash
# lib/utils/lock.sh — single shared atomic lock primitive (issue #706).
#
# One correct lock used by issue-lock.sh, session-tracker.sh, and
# scratchpad-lock.sh — replacing three near-identical mkdir+PID implementations
# that shared one race class.
#
# Primitive: an `ln(1)` hard-link lock whose file content is a unique TOKEN
# "<pid>.<nonce>". The token is written into a private temp file BEFORE the
# link, so the lock carries its identity atomically the instant it exists — there
# is NO "lock exists but has no content yet" window (the create→write gap that,
# under heavy load, let a waiter reclaim a still-live lock: lost session
# increments / JSON corruption, #706; same class as the issue-lock rm-then-mkdir
# double-hold fixed in #707).
#
# link(2) is atomic and fails if the target exists, so exactly one of N racing
# acquirers wins. Three properties make reclamation of a DEAD holder's lock safe:
#   1. The PID gives liveness (kill -0).
#   2. The NONCE makes every acquisition's token unique, so a reclaim that
#      verifies the moved token still equals the dead token it observed cannot be
#      fooled by PID reuse (a recycled PID re-acquiring gets a *different* token).
#   3. Reclaim is a move-aside-then-verify: if the moved lock no longer matches
#      the observed dead token (a concurrent re-acquire slipped in), it is
#      restored untouched and the caller waits — never a blind steal of a live
#      lock.
# An empty read means the file VANISHED (a holder released) — not "stealable";
# the caller just retries the link.
#
# Why not flock(1): macOS ships no flock(1), so the portable path must be correct
# on its own. `ln` is uniform on macOS + Linux and needs no per-lock fd
# bookkeeping. kill -0 liveness reclaim replaces flock's kernel auto-release on
# crash — a same-host assumption, so the lock path must NOT be on shared/network
# storage (a PID from another host would read as a false "dead process").
#
# Platform seam (for a future Windows port): this file is the ONE place the OS
# concurrency model lives. A non-POSIX backend replaces exactly three public
# functions — lock_acquire, lock_release, lock_held_pid — over the platform's
# equivalents of three primitives:
#   - atomic create-exclusive   (POSIX: ln/link;   Windows: CreateFile CREATE_NEW)
#   - process liveness          (POSIX: kill -0;    Windows: OpenProcess / tasklist)
#   - atomic rename for reclaim  (POSIX: mv/rename;  Windows: MoveFileEx)
# Behavioural contract callers depend on: lock_acquire blocks until it holds the
# lock exclusively or times out (returns 1); lock_release frees only a lock THIS
# process holds; a dead holder's lock is reclaimable. Nothing outside lock.sh
# encodes these OS assumptions, so the port is a single-file swap.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f lock_acquire >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi


# _lock_read_token <lockpath> — full token, whether the lock is the ln file
# (content = token) or a legacy mkdir-style dir (token/PID in <dir>/pid). Empty
# if the lock is absent.
_lock_read_token() {
  local lp="$1"
  if [ -d "$lp" ]; then
    cat "$lp/pid" 2>/dev/null || true
  else
    cat "$lp" 2>/dev/null || true
  fi
}

# _lock_steal <lockpath> <expected_token> — reclaim a stale lock ONLY IF it still
# holds <expected_token> (the dead identity the caller observed). Move the path
# aside (atomic rename), then verify; this closes the reclaim TOCTOU. Because the
# token is unique per acquisition, a match proves it is the very lock observed
# dead (not a PID-reuse look-alike), so reclaiming is safe. A non-match means a
# concurrent re-acquire took the path — restore it and report "not stolen" so the
# caller waits. Returns 0 only when the expected stale lock was reclaimed.
_lock_steal() {
  local lp="$1" expected="$2"
  # Re-verify the lock STILL holds the observed dead identity, immediately before
  # the destructive move. A holder that merely RELEASED cleanly (the common
  # "looks dead" case: we read its token, then it rm'd the lock and exited) leaves
  # the path gone or re-taken — token != expected — so we must NOT move it (that
  # would disturb whoever holds it now). Only a genuine crash leaves the dead
  # token in place. This is what keeps a clean release→re-acquire from being
  # mistaken for a stale lock and stolen.
  local now
  now=$(_lock_read_token "$lp")
  [ "$now" = "$expected" ] || return 1
  local dst="${lp}.stale.$$.${RANDOM}"
  mv "$lp" "$dst" 2>/dev/null || return 1      # lost the race / already gone
  local got
  if [ -d "$dst" ]; then
    got=$(cat "$dst/pid" 2>/dev/null || true)
  else
    got=$(cat "$dst" 2>/dev/null || true)
  fi
  if [ "$got" = "$expected" ]; then
    rm -rf "$dst" 2>/dev/null || true           # confirmed the observed dead lock
    return 0
  fi
  # Moved a different lock than observed (a concurrent re-acquire). Restore it so
  # its holder is unaffected; we did NOT steal. (If the path was retaken again
  # before we could restore — a vanishingly rare multi-reacquire window on one
  # host — drop our moved copy; the holder's PID-checked release then no-ops.)
  mv "$dst" "$lp" 2>/dev/null || rm -rf "$dst" 2>/dev/null || true
  return 1
}

# lock_acquire <lockpath> [timeout_s]
# Returns 0 on acquire, 1 on timeout (held by a live process past timeout).
# Default timeout 30s; one wait-iteration per second. Reclaiming a dead lock does
# NOT consume the timeout budget (it retries immediately).
lock_acquire() {
  local lockfile="$1"
  local timeout="${2:-30}"
  mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true

  # One-time: clear a legacy/foreign EMPTY lock file. A valid lock always carries
  # a token (size>0); an empty regular file is leftover cruft (e.g. an old flock
  # lock) that would otherwise block `ln`. `ln` cannot create a real lock at this
  # path while the empty file sits there, so removing it races nothing.
  if [ -f "$lockfile" ] && [ ! -s "$lockfile" ]; then
    rm -f "$lockfile" 2>/dev/null || true
  fi

  # Unique identity for THIS acquisition: PID (for liveness) + nonce (so a reused
  # PID re-acquiring is never mistaken for the dead holder we observed).
  local token="$$.${RANDOM}.${RANDOM}"

  # Prepare the token-bearing temp on the same filesystem, then hard-link it into
  # place. The link is the atomic gate; the token is present at creation.
  local tmp="${lockfile}.tmp.$$.${RANDOM}"
  if ! echo "$token" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi

  local attempts=0
  local cur hpid
  while true; do
    if [ -d "$lockfile" ]; then
      # Legacy mkdir-style dir at this path (pre-#706 holder or leftover). Never
      # `ln` into it — `ln file dir` nests the temp inside and falsely succeeds.
      cur=$(cat "$lockfile/pid" 2>/dev/null || true)
      hpid="${cur%%.*}"
      if [ -z "$cur" ] || [ "$hpid" = "$$" ] || ! kill -0 "$hpid" 2>/dev/null; then
        _lock_steal "$lockfile" "$cur" || true
        continue
      fi
    elif ln "$tmp" "$lockfile" 2>/dev/null; then
      break   # acquired — exactly one linker wins
    else
      # Held. Read the token. An ln lock always carries its token at creation, so
      # an EMPTY read means the file VANISHED between our `ln` and this `cat` (a
      # holder released; the release→re-acquire window). Stealing there races the
      # re-acquirer and double-holds — so empty+gone just retries.
      cur=$(cat "$lockfile" 2>/dev/null || true)
      hpid="${cur%%.*}"
      if [ -z "$cur" ]; then
        # Empty read ALWAYS means the file vanished between our `ln` and this
        # `cat` (a holder released). Even if it exists again now, that is a NEW
        # live holder that re-linked it — stealing here moves a live lock. So
        # never steal on empty: just retry. Legacy 0-byte cruft is cleared once by
        # the pre-loop check above, before contention.
        continue          # gone → retry; next `ln` wins or reads a live token
      elif [ "$hpid" = "$$" ]; then
        _lock_steal "$lockfile" "$cur" || true
        continue
      elif ! kill -0 "$hpid" 2>/dev/null; then
        _lock_steal "$lockfile" "$cur" || true
        continue
      fi
    fi

    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$timeout" ]; then
      rm -f "$tmp" 2>/dev/null || true
      return 1
    fi
    sleep 1
  done

  rm -f "$tmp" 2>/dev/null || true   # linked; lockfile is the durable name now
  return 0
}

# lock_release <lockpath> — remove only if we hold it (token's PID matches $$).
# Idempotent.
lock_release() {
  local lockfile="$1"
  [ -e "$lockfile" ] || return 0
  local cur
  cur=$(_lock_read_token "$lockfile")
  if [ "${cur%%.*}" = "$$" ]; then
    rm -rf "$lockfile" 2>/dev/null || true
  fi
  return 0
}

# lock_held_pid <lockpath> — print the LIVE holder PID, or nothing if the lock is
# free / held by a dead process. For status/mapping callers.
lock_held_pid() {
  local lockfile="$1"
  [ -e "$lockfile" ] || return 0
  local cur hpid
  cur=$(_lock_read_token "$lockfile")
  hpid="${cur%%.*}"
  if [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; then
    echo "$hpid"
  fi
}
