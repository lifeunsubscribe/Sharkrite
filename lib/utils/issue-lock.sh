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
#   acquire_issue_lock <issue_number>                        # Returns 0 on success, 1 if locked by live process
#   release_issue_lock <issue_number>                        # Cleanup lock directory
#   acquire_pr_followup_lock <pr_number> [source_issue]      # Returns 0 on success, 1 on timeout
#     Optional: RITE_FOLLOWUP_LOCK_CONTENDED_FILE env var — if set, writes "contended" to
#     this path when the lock was acquired after blocking (i.e., another process held it).
#     Callers use this to broaden retry conditions in the dedup check.
#   release_pr_followup_lock <pr_number> [source_issue]      # Cleanup followup lock directory
#   write_followup_evidence <pr_number> <issue_number> [source_issue]  # Persist durable local evidence
#   read_followup_evidence <pr_number> [source_issue]                  # Read back evidence (returns issue number or empty)
#   clear_followup_evidence <pr_number> [source_issue]                 # Remove stale evidence file
#   derive_followup_finding_key <source_issue> <title> <finding_index> # Canonical per-finding dedup key
#
# The optional source_issue argument to the pr_followup_lock functions keys the lock by
# PR + source issue rather than PR alone.  Use it whenever ISSUE_NUMBER is known so that
# two concurrent invocations for different source issues on the same PR get independent
# locks (and independent dedup search scopes).
#
# derive_followup_finding_key is used by both assess-and-resolve.sh and
# assess-review-issues.sh to produce a per-finding evidence key that is stable
# across runs and across paths — the key written by one path is readable by the
# other's _followup_dedup_check Source 1 check.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f acquire_issue_lock >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if RITE_LOCK_DIR not already set (defined in config.sh)
if [ -z "${RITE_LOCK_DIR:-}" ]; then
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_SCRIPT_DIR/config.sh"
fi

# Atomically claim ownership of a stale lock directory before removing it.
#
# WHY: the previous reclaim path was `rm -rf "$lock_dir"; continue` followed by a
# loop-back to `mkdir "$lock_dir"`. That is two non-atomic steps. Under
# concurrent reclamation of the SAME stale lock, two processes could each read
# the dead PID, then process A reclaims (rm + mkdir + writes its live PID) while
# process B — having already decided to reclaim based on its now-stale dead-PID
# read — runs `rm -rf "$lock_dir"`, DELETING A's freshly-acquired live lock, then
# `mkdir`s its own. Result: A and B both believe they hold the lock (live
# double-hold, reproduced ~6% of concurrent-reclaim trials).
#
# FIX: rename (mv) is atomic on POSIX and serialises the steal. Only the process
# whose `mv "$lock_dir" "$unique"` succeeds owns the steal; concurrent callers'
# mv fails because the source no longer exists. The winner removes the renamed
# dir; the next `mkdir "$lock_dir"` (the existing atomic gate) then admits exactly
# one acquirer. A caller whose mv fails simply re-loops and re-evaluates the lock,
# which by then is either free (mkdir wins) or held by the steal winner.
#
# Args: lock_dir
# Returns: 0 if this process won the steal (dir removed), 1 if it lost the race.
_atomic_steal_stale_lock() {
  local lock_dir="$1"
  # Unique per-process, per-call destination so concurrent steals never collide.
  local steal_dst="${lock_dir}.stale.$$.${RANDOM}"
  if mv "$lock_dir" "$steal_dst" 2>/dev/null; then
    rm -rf "$steal_dst" 2>/dev/null || true
    return 0
  fi
  # Lost the rename race (another reclaimer already moved/removed it, or a fresh
  # holder mkdir'd a new dir at this path). Nothing to remove.
  return 1
}

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
  local _grace_period_consumed=false

  while ! mkdir "$lock_dir" 2>/dev/null; do
    # Check if the holding process is still alive
    if [ -f "$lock_dir/pid" ]; then
      local lock_pid
      lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")

      # kill -0: same-host assumption — only valid within a single PID namespace.
      # See file-level comment for details. RITE_LOCK_DIR must not be on shared storage.
      if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        # Holding process is dead — atomically steal the stale lock, then re-loop.
        # Whether the steal won or lost the race, re-evaluate the lock on the next
        # iteration: it is now either free (our mkdir wins) or freshly held by the
        # steal winner (its live PID blocks us). Never blindly mkdir after a steal.
        echo "⚠️  Reclaiming stale lock from dead process (PID $lock_pid)" >&2
        _atomic_steal_stale_lock "$lock_dir"
        continue
      fi

      # Defense-in-depth: if WE are the lock holder (same PID), reclaim our own lock.
      # This happens when a script execs itself to restart (exec replaces the process
      # image without firing EXIT traps, so the "release_issue_lock" EXIT trap from the
      # previous incarnation never ran). The re-exec'd process has the same $$ and finds
      # its own live lock. Reclaim it silently and retry the mkdir.
      # Live failure: issue #343 batch run 2026-06-06.
      if [ -n "$lock_pid" ] && [ "$lock_pid" = "$$" ]; then
        echo "⚠️  Reclaiming self-held lock (post-exec restart) for issue #${issue_number}" >&2
        _atomic_steal_stale_lock "$lock_dir"
        continue
      fi

      # Lock is held by a live process
      if [ $lock_attempts -eq 0 ]; then
        echo "❌ Issue #${issue_number} is already being processed by PID ${lock_pid}" >&2
        echo "   Refusing to start. Wait for it to finish, or run 'rite ${issue_number} --undo' if it crashed." >&2
      fi
    else
      # Lock dir exists but no PID file.  With atomic PID writes (mktemp + mv)
      # this window is effectively eliminated for holders using this module, but
      # a crashed holder or a very old holder using the pre-atomic code path
      # could still leave this state.  Give it a grace period before reclaiming
      # — consistent with scratchpad-lock.sh and session-tracker.sh.
      # Default: 1s; override via _RITE_LOCK_GRACE_PERIOD_S for tests.
      # Only consume the grace period once per acquisition attempt: repeated
      # no-PID encounters within the same retry loop must not each add a full
      # sleep (that would compound latency beyond the 1-second-per-retry budget).
      if [ "$_grace_period_consumed" = "false" ]; then
        sleep "${_RITE_LOCK_GRACE_PERIOD_S:-1}"
        _grace_period_consumed=true
      fi
      if [ ! -f "$lock_dir/pid" ]; then
        echo "⚠️  Reclaiming stale lock (no PID file after grace period)" >&2
        _atomic_steal_stale_lock "$lock_dir"
        continue
      fi
    fi

    lock_attempts=$((lock_attempts + 1))
    if [ $lock_attempts -ge $max_attempts ]; then
      echo "❌ Lock timeout after ${max_attempts} seconds" >&2
      return 1
    fi

    sleep 1
  done

  # Write our PID atomically via temp+rename so a concurrent waiter never sees
  # the lock dir exist with no PID file (the TOCTOU window the old direct echo
  # could create between mkdir and PID write).
  local _pid_tmp
  _pid_tmp=$(mktemp "${lock_dir}/pid.XXXXXX")
  echo $$ > "$_pid_tmp"
  mv "$_pid_tmp" "${lock_dir}/pid"

  # Write cwd file so repo-status.sh can map lock → worktree without lsof/procfs.
  # Written after the PID file so readers that check cwd existence always have a
  # valid PID to cross-reference.  Best-effort: failure does not block acquisition.
  local _cwd_tmp
  _cwd_tmp=$(mktemp "${lock_dir}/cwd.XXXXXX")
  pwd > "$_cwd_tmp" 2>/dev/null && mv "$_cwd_tmp" "${lock_dir}/cwd" || rm -f "$_cwd_tmp" 2>/dev/null || true

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
# TIMING BUDGET — waiter timeout vs holder critical-section duration
# -----------------------------------------------------------------
# The waiter polls every second and times out after ~60s (60 × 1s sleeps plus
# per-iteration overhead — actual wall-clock slightly exceeds 60s).
# The holder's critical section in assess-and-resolve.sh can take significantly
# longer than the ~5-10s typical case under slow-GitHub conditions:
#
#   Holder worst-case timing:
#     • evidence validation:  1 gh_safe call (up to 20s backoff-sleep only; gh
#                             round-trip latency is additional and not included here)
#     • dedup search loop:    up to 4 gh_safe calls per iteration (up to 20s backoff-
#                             sleep each, plus gh round-trip latency per call):
#         - Source 2a: gh issue list  (body-marker search)
#         - Source 2b: gh issue view  (marker verification; only if 2a found a candidate)
#         - Source 3:  gh issue list  (title search; only if still no match)
#         - Source 4:  gh pr view     (PR comment check; only if no match and not last retry)
#     • dedup index backoff:  _dedup_max_retries × _dedup_backoff (default: 3×5s = 15s)
#     ─────────────────────────────────────────────────────────────────────────────
#     Plausible worst case:  20s + 80s + 15s = 115s backoff-sleep (exceeds the ~60s
#                            waiter budget); actual wall-clock is higher once gh
#                            request latency is included for each call
#     Theoretical worst case: more calls per iteration if loop retries multiple times;
#                             per-call cost is bounded at 20s (5s+15s backoff, no trailing
#                             sleep) — growth comes from call count, not per-call duration
#
#   What happens on waiter timeout:
#     The waiter returns 1 to the caller (acquire_pr_followup_lock only returns 1).
#     The caller (assess-and-resolve.sh) sets _skip_followup_creation=true in the
#     else branch.  This prevents creation of a follow-up issue rather than creating
#     a duplicate.  However, it means the follow-up may not be created at all,
#     requiring a manual re-run of --assess-and-fix.
#
#   Tuning:
#     - Reduce RITE_DEDUP_BACKOFF (default: 5s) to shorten holder dedup wait time.
#     - Reduce RITE_GH_MAX_RETRIES (default: 3) to shorten gh backoff windows.
#     - Increase this lock's max_attempts if operating in a high-rate-limit environment.
#     - See RITE_DEDUP_BACKOFF in config.sh for the configurable knob.
#
# Lock key scoping:
#   - When source_issue is provided: keyed by PR + source issue
#       pr-${pr_number}-src-${source_issue}-followup.lock
#     This ensures that two concurrent invocations for DIFFERENT source issues on
#     the same PR do not block each other and do not share a dedup search scope.
#     A 1-PR→multiple-source-issues scenario (e.g., a PR that closes #10 and #11)
#     requires independent locks so each source-issue follow-up is created separately.
#   - When source_issue is omitted: keyed by PR only (backward-compatible path)
#       pr-${pr_number}-followup.lock
#
# Args: pr_number [source_issue]
# Returns: 0 on success, 1 on timeout (lock held by live process for too long)
acquire_pr_followup_lock() {
  local pr_number="$1"
  local source_issue="${2:-}"
  local lock_key
  if [ -n "$source_issue" ]; then
    lock_key="pr-${pr_number}-src-${source_issue}-followup.lock"
  else
    lock_key="pr-${pr_number}-followup.lock"
  fi
  local lock_dir="${RITE_LOCK_DIR}/${lock_key}"

  # Ensure lock directory parent exists
  mkdir -p "${RITE_LOCK_DIR}"

  local lock_attempts=0
  # Allow up to 60 seconds — the critical section (gh issue list + gh issue create)
  # takes ~5-10s in practice; 60s gives ample room while still failing safely.
  #
  # The lock holder may also sleep for RITE_FOLLOWUP_LOCK_DWELL_S (default 5s)
  # after create before releasing (see assess-and-resolve.sh post-create dwell).
  # This dwell extends the holder's critical section but not the effective wait
  # for most waiters: a waiter that was queued during the dwell will find the
  # source-marker sentinel file fresh and short-circuit BEFORE acquiring the lock,
  # so it never actually spends its budget waiting out the dwell.  In the rare
  # case where the sentinel is unavailable, the worst-case hold time is
  # ~10s (critical section) + 5s (dwell) = ~15s, well inside the 60s budget.
  local max_attempts=60
  local _grace_period_consumed=false

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
      # Lock dir exists but no PID file.  With atomic PID writes (mktemp + mv)
      # this window is effectively eliminated for holders using this module, but
      # a crashed holder or a very old holder using the pre-atomic code path
      # could still leave this state.  Give it a grace period before reclaiming
      # — consistent with scratchpad-lock.sh and session-tracker.sh.
      # Default: 1s; override via _RITE_LOCK_GRACE_PERIOD_S for tests.
      # Only consume the grace period once per acquisition attempt: repeated
      # no-PID encounters within the same retry loop must not each add a full
      # sleep (that would compound latency beyond the 1-second-per-retry budget).
      if [ "$_grace_period_consumed" = "false" ]; then
        sleep "${_RITE_LOCK_GRACE_PERIOD_S:-1}"
        _grace_period_consumed=true
      fi
      if [ ! -f "$lock_dir/pid" ]; then
        echo "⚠️  Reclaiming stale followup lock (no PID file after grace period)" >&2
        rm -rf "$lock_dir" 2>/dev/null || true
        continue
      fi
    fi

    lock_attempts=$((lock_attempts + 1))
    if [ $lock_attempts -ge $max_attempts ]; then
      if [ -n "$source_issue" ]; then
        # source_issue is treated as an opaque token (may be a numeric issue number
        # or a slug like "42-my-finding-slug-1") — omit the '#' prefix that implies
        # a numeric GitHub issue reference.
        echo "❌ Follow-up lock timeout for PR #${pr_number} / key ${source_issue} after ${max_attempts}s" >&2
      else
        echo "❌ Follow-up lock timeout for PR #${pr_number} after ${max_attempts}s" >&2
      fi
      return 1
    fi

    sleep 1
  done

  # Write our PID atomically via temp+rename so a concurrent waiter never sees
  # the lock dir exist with no PID file (the TOCTOU window the old direct echo
  # could create between mkdir and PID write).
  local _pid_tmp
  _pid_tmp=$(mktemp "${lock_dir}/pid.XXXXXX")
  echo $$ > "$_pid_tmp"
  mv "$_pid_tmp" "${lock_dir}/pid"

  # Contention signal: when RITE_FOLLOWUP_LOCK_CONTENDED_FILE is set and the
  # lock was acquired after blocking (lock_attempts > 0), write "contended" to
  # the file.  Callers read this to broaden dedup retry conditions — a contended
  # acquire implies another process just finished the dedup-then-create sequence,
  # which is precisely when GitHub index lag is most likely to affect the next
  # search and return empty even though the issue was just created.
  if [ "$lock_attempts" -gt 0 ] && [ -n "${RITE_FOLLOWUP_LOCK_CONTENDED_FILE:-}" ]; then
    printf 'contended\n' > "${RITE_FOLLOWUP_LOCK_CONTENDED_FILE}" 2>/dev/null || true
  fi

  return 0
}

# Release per-PR follow-up issue creation lock
# Args: pr_number [source_issue]
# Must be called with the same arguments used in the matching acquire_pr_followup_lock call.
release_pr_followup_lock() {
  local pr_number="$1"
  local source_issue="${2:-}"
  local lock_key
  if [ -n "$source_issue" ]; then
    lock_key="pr-${pr_number}-src-${source_issue}-followup.lock"
  else
    lock_key="pr-${pr_number}-followup.lock"
  fi
  local lock_dir="${RITE_LOCK_DIR}/${lock_key}"

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

# Derive the per-finding dedup key used for evidence files, sentinels, and locks.
#
# This is the single canonical key-derivation function shared by both
# assess-and-resolve.sh (per-finding loop) and assess-review-issues.sh
# (ACTIONABLE_LATER per-item path).  Both paths write and read evidence files
# under this same key, so a file seeded from one path is found by the other.
#
# Key format: "<source_issue>-<40-char-title-slug>-<finding_index>"
#   source_issue  — the issue number that triggered the workflow (0 if unknown)
#   title-slug    — title lowercased, non-alnum chars replaced with '-',
#                   consecutive dashes collapsed, leading/trailing dashes stripped,
#                   truncated to 40 chars
#   finding_index — 1-based counter within the per-finding loop for this run;
#                   disambiguates two findings whose 40-char slugs collide
#
# Args:
#   $1 source_issue   — issue number string (may be "0" or empty → treated as "0")
#   $2 title          — raw finding title (LLM-derived; may contain any chars)
#   $3 finding_index  — 1-based integer counter from the caller's per-finding loop
#
# Output: key string on stdout
# Returns: 0 always
#
# Used by:
#   lib/core/assess-and-resolve.sh     — per-finding loop (_FOLLOWUP_FINDING_KEY)
#   lib/core/assess-review-issues.sh   — ACTIONABLE_LATER per-item path
derive_followup_finding_key() {
  local _src="${1:-0}"
  local _title="${2:-}"
  local _idx="${3:-0}"

  local _slug
  _slug=$(printf '%s' "$_title" | tr '[:upper:]' '[:lower:]' | \
    sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//; s/-$//' | \
    cut -c1-40 || true)
  _slug="${_slug:-finding-${_idx}}"

  printf '%s' "${_src:=0}-${_slug}-${_idx}"
}

# Write durable local evidence that a follow-up issue was created for a given PR.
#
# This is the fallback dedup mechanism for the case where gh pr comment fails
# (||true silences it) and the GitHub search index hasn't caught up yet.  The
# evidence file lives in RITE_LOCK_DIR, independent of the lock directory
# lifecycle (which is deleted on release), so it persists after the lock is gone.
#
# The file contains a single line: the follow-up issue number.  Waiters read it
# with read_followup_evidence before the dedup search-then-create sequence.
#
# MUST be called while the pr_followup_lock is held, so the write is serialised
# against concurrent processes attempting the same check-then-create.
#
# Evidence file naming mirrors the lock key:
#   With source_issue:  pr-${pr}-src-${src}-followup-created.txt
#   Without:            pr-${pr}-followup-created.txt
#
# Args: pr_number issue_number [source_issue]
# Returns: 0 on success, 1 if write failed
write_followup_evidence() {
  local pr_number="$1"
  local issue_number="$2"
  local source_issue="${3:-}"

  # Guard: an empty or non-numeric issue_number would write a poison file that
  # read_followup_evidence silently ignores (grep -E '^[0-9]+$' finds nothing),
  # but the file's presence would still defeat the evidence-existence check.
  if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  local evidence_key
  if [ -n "$source_issue" ]; then
    evidence_key="pr-${pr_number}-src-${source_issue}-followup-created.txt"
  else
    evidence_key="pr-${pr_number}-followup-created.txt"
  fi
  local evidence_file="${RITE_LOCK_DIR}/${evidence_key}"

  mkdir -p "${RITE_LOCK_DIR}"
  # Write atomically: write to tmp then mv so readers never see a partial file
  local tmp_file
  tmp_file=$(mktemp "${RITE_LOCK_DIR}/.evidence-XXXXXX")
  printf '%s\n' "$issue_number" > "$tmp_file" && mv "$tmp_file" "$evidence_file" || {
    rm -f "$tmp_file" 2>/dev/null || true
    return 1
  }
  return 0
}

# Read durable local evidence for a follow-up issue creation.
#
# Returns the issue number on stdout if evidence exists, or empty string if not.
# Called by the dedup check loop as the fastest (local FS) evidence source,
# before any GitHub API calls.
#
# Args: pr_number [source_issue]
read_followup_evidence() {
  local pr_number="$1"
  local source_issue="${2:-}"

  local evidence_key
  if [ -n "$source_issue" ]; then
    evidence_key="pr-${pr_number}-src-${source_issue}-followup-created.txt"
  else
    evidence_key="pr-${pr_number}-followup-created.txt"
  fi
  local evidence_file="${RITE_LOCK_DIR}/${evidence_key}"

  if [ -f "$evidence_file" ]; then
    # Read first non-empty line; guard against empty/malformed file
    local issue_num
    issue_num=$(grep -m1 -E '^[0-9]+$' "$evidence_file" 2>/dev/null || true)
    printf '%s' "$issue_num"
  fi
}

# List issue numbers that currently hold an active (live-process) issue lock.
#
# Returns issue numbers one per line, sorted NUMERICALLY — not lexically.
# Lexical sort (the default `ls` and glob expansion order) would place
# issue-10.lock before issue-9.lock, so a stale lock for issue 10 could shadow
# issue 9 when callers take the first match.  Numeric sort is deterministic and
# independent of lock-dir filesystem order.
#
# Only includes locks whose PID file references a still-running process.
# Stale locks (dead PID or missing PID file) are silently skipped — callers
# that need to display "in-progress" markers should not show stale artifacts.
#
# Output: one issue number per line (may be empty if no live locks)
# Returns: 0 always
get_locked_issue_numbers() {
  local lock_dir_base="${RITE_LOCK_DIR:-}"
  if [ -z "$lock_dir_base" ] || [ ! -d "$lock_dir_base" ]; then
    return 0
  fi

  # Collect numeric issue numbers from issue-N.lock directory names.
  # Use a temp array and sort numerically to avoid lexical ordering:
  #   ls issue-*.lock  → issue-10.lock, issue-9.lock  (lexical, wrong)
  #   sort -n          → 9, 10                          (numeric, correct)
  local _nums=()
  local _lock_entry
  for _lock_entry in "$lock_dir_base"/issue-*.lock; do
    # Skip if glob found no matches (bash expands unexpanded glob literally)
    [ -d "$_lock_entry" ] || continue

    # Extract the numeric issue number from the directory name
    local _basename
    _basename="${_lock_entry##*/}"        # issue-N.lock
    local _num="${_basename#issue-}"      # N.lock
    _num="${_num%.lock}"                  # N

    # Only digits — reject any entry with unexpected characters
    [[ "$_num" =~ ^[0-9]+$ ]] || continue

    # Only include if the lock is held by a live process
    if [ -f "$_lock_entry/pid" ]; then
      local _pid
      _pid=$(cat "$_lock_entry/pid" 2>/dev/null || true)
      if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
        _nums+=("$_num")
      fi
      # Dead PID or empty PID file → stale lock, skip silently
    fi
    # Missing PID file → lock in grace period or stale, skip silently
  done

  # Print in numeric order.  Use printf + sort -n so the output order is
  # independent of filesystem directory entry order and shell glob expansion
  # order (both of which are lexical on most POSIX filesystems).
  if [ "${#_nums[@]}" -gt 0 ]; then
    printf '%s\n' "${_nums[@]}" | sort -n
  fi

  return 0
}

# Backfill lock files for legacy worktrees that predate the lock infrastructure.
#
# Worktrees created before PR #67 (commit eb714e6) have no lock file, so
# repo-status.sh cannot map them to an issue number.  This function walks
# `git worktree list`, derives the issue number from the branch's open PR
# (via `gh pr list --head <branch>`), and writes a minimal lock directory
# containing only a `cwd` file — enough for the status display to resolve the
# worktree → issue mapping without interfering with the live-lock mechanism
# (which requires a `pid` file written by the running process).
#
# The created lock directory is marked with a `backfill` sentinel file so that:
#   1. `get_locked_issue_numbers()` (which checks for live PIDs) skips it safely.
#   2. `repo-status.sh`'s backfill-lock lookup path can distinguish it from a
#      live lock (no `pid` = no PID liveness check needed).
#   3. `acquire_issue_lock` will delete and recreate the directory when rite
#      later runs the same issue (mkdir atomically fails → stale-lock reclaim
#      triggers because there is no live PID).
#
# Idempotent: silently skips worktrees that already have a lock directory,
# and overwrites stale backfill locks when the issue number changes.
#
# Requires: RITE_LOCK_DIR (set by config.sh), `git worktree list`, `gh`
# Args: none
# Returns: 0 always (best-effort; individual failures are logged to stderr)
backfill_worktree_locks() {
  # Load gh_safe if not already available (e.g., when called standalone from
  # bin/rite --backfill-locks without repo-status.sh's pr-detection.sh chain).
  if ! declare -f gh_safe >/dev/null 2>&1; then
    source "$RITE_LIB_DIR/utils/gh-retry.sh" 2>/dev/null || true
  fi

  # Ensure lock directory parent exists
  mkdir -p "${RITE_LOCK_DIR}"

  local _main_worktree
  _main_worktree=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print $2; exit}' || true)

  # Read all worktree entries from porcelain output
  local _current_path=""
  local _current_branch=""

  while IFS= read -r _line; do
    if [[ "$_line" =~ ^worktree\ (.+) ]]; then
      _current_path="${BASH_REMATCH[1]}"
      _current_branch=""
    elif [[ "$_line" =~ ^branch\ refs/heads/(.+) ]]; then
      _current_branch="${BASH_REMATCH[1]}"
    elif [ -z "$_line" ] && [ -n "$_current_path" ]; then
      # End of block — process non-main worktrees only
      _backfill_single_worktree "$_current_path" "$_current_branch" "$_main_worktree"
      _current_path=""
      _current_branch=""
    fi
  done <<< "$(git worktree list --porcelain 2>/dev/null || echo "")"

  # Handle last entry if output doesn't end with blank line
  if [ -n "$_current_path" ]; then
    _backfill_single_worktree "$_current_path" "$_current_branch" "$_main_worktree"
  fi

  return 0
}

# Internal helper: attempt to backfill a single worktree.
# Args: worktree_path branch_name main_worktree_path
# Returns: 0 always
_backfill_single_worktree() {
  local _wt_path="$1"
  local _branch="${2:-}"
  local _main_wt="${3:-}"

  # Skip main worktree
  [ "$_wt_path" = "$_main_wt" ] && return 0
  # Skip non-existent paths
  [ -d "$_wt_path" ] || return 0
  # Skip detached HEAD (no branch) or unknown branch
  [ -n "$_branch" ] || return 0

  # Derive issue number: try branch name first (fast, no API call)
  local _issue_num=""
  if [[ "$_branch" =~ (^|[-_/])([0-9]+)($|[-_/]) ]]; then
    # Heuristic: look for a number in the branch that plausibly is an issue
    # number.  We still verify via PR below, but this avoids an API call when
    # the branch already encodes the issue number (e.g. feat/add-stuff-_b34-91).
    # Use the last numeric group to match Sharkrite branch naming: <desc>_b<pr>-<issue>
    _issue_num=$(echo "$_branch" | grep -oE '[0-9]+' | tail -1 || true)
    # Verify that a lock for this number already exists and is not a stale backfill
    local _existing_lock="${RITE_LOCK_DIR}/issue-${_issue_num}.lock"
    if [ -d "$_existing_lock" ] && [ ! -f "$_existing_lock/backfill" ]; then
      # Live lock exists (written by acquire_issue_lock) — do not overwrite
      return 0
    fi
    # Reset: we'll confirm via PR lookup below
    _issue_num=""
  fi

  # Look up open PR for this branch and extract closing issue reference.
  # Use gh_safe for retry/resilience (loaded at top of backfill_worktree_locks).
  local _pr_json
  _pr_json=$(gh_safe pr list --head "$_branch" --state open --json number,body --limit 1 \
    --jq '.[0] // empty' 2>/dev/null || true)
  _pr_json="${_pr_json:-}"

  if [ -z "$_pr_json" ]; then
    # Also check all-state PRs (not just open) so closed-but-unmerged branches are handled
    _pr_json=$(gh_safe pr list --head "$_branch" --state all --json number,body --limit 1 \
      --jq '.[0] // empty' 2>/dev/null || true)
    _pr_json="${_pr_json:-}"
  fi

  [ -z "$_pr_json" ] && return 0

  local _pr_body
  _pr_body=$(echo "$_pr_json" | jq -r '.body // ""' 2>/dev/null || true)

  # Extract issue number from "Closes #N" / "Fixes #N" / "Resolves #N"
  _issue_num=$(echo "$_pr_body" | \
    grep -oiE '(closes?|fixes?|resolves?) #[0-9]+' | \
    head -1 | grep -oE '[0-9]+' || true)

  [ -z "$_issue_num" ] && return 0
  [[ "$_issue_num" =~ ^[0-9]+$ ]] || return 0

  local _lock_dir="${RITE_LOCK_DIR}/issue-${_issue_num}.lock"

  # Skip if a live lock (with pid file) already exists — don't clobber it
  if [ -d "$_lock_dir" ] && [ -f "$_lock_dir/pid" ]; then
    local _existing_pid
    _existing_pid=$(cat "$_lock_dir/pid" 2>/dev/null || true)
    if [ -n "$_existing_pid" ] && kill -0 "$_existing_pid" 2>/dev/null; then
      return 0  # Live process holds this lock — do not overwrite
    fi
  fi

  # Write (or refresh) the backfill lock directory
  # Use mkdir to atomically create (will fail if live acquire_issue_lock raced us,
  # but that's fine — the live lock supersedes the backfill).
  mkdir -p "$_lock_dir" 2>/dev/null || true

  # Write cwd file (the key artifact repo-status.sh uses for mapping)
  local _cwd_tmp
  _cwd_tmp=$(mktemp "${_lock_dir}/cwd.XXXXXX" 2>/dev/null) || return 0
  printf '%s\n' "$_wt_path" > "$_cwd_tmp" && mv "$_cwd_tmp" "${_lock_dir}/cwd" || {
    rm -f "$_cwd_tmp" 2>/dev/null || true
    return 0
  }

  # Write backfill sentinel (distinguishes from live lock; acquire_issue_lock
  # will delete the whole dir atomically, so the sentinel disappears on first run)
  printf 'backfill\n' > "${_lock_dir}/backfill" 2>/dev/null || true

  return 0
}

# Remove durable local evidence for a follow-up issue creation.
#
# Called when the locally-evidenced issue is found to be stale (closed/deleted),
# so subsequent runs don't re-read and re-validate a file that will never match.
#
# Args: pr_number [source_issue]
# Returns: 0 always (best-effort removal)
clear_followup_evidence() {
  local pr_number="$1"
  local source_issue="${2:-}"

  local evidence_key
  if [ -n "$source_issue" ]; then
    evidence_key="pr-${pr_number}-src-${source_issue}-followup-created.txt"
  else
    evidence_key="pr-${pr_number}-followup-created.txt"
  fi
  local evidence_file="${RITE_LOCK_DIR}/${evidence_key}"

  rm -f "$evidence_file" 2>/dev/null || true
}
