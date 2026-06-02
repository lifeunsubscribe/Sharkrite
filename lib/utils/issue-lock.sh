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
#   release_pr_followup_lock <pr_number> [source_issue]      # Cleanup followup lock directory
#   write_followup_evidence <pr_number> <issue_number> [source_issue]  # Persist durable local evidence
#   read_followup_evidence <pr_number> [source_issue]                  # Read back evidence (returns issue number or empty)
#   clear_followup_evidence <pr_number> [source_issue]                 # Remove stale evidence file
#
# The optional source_issue argument to the pr_followup_lock functions keys the lock by
# PR + source issue rather than PR alone.  Use it whenever ISSUE_NUMBER is known so that
# two concurrent invocations for different source issues on the same PR get independent
# locks (and independent dedup search scopes).

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
      # Lock dir exists but no PID file.  With atomic PID writes (mktemp + mv)
      # this window is effectively eliminated for holders using this module, but
      # a crashed holder or a very old holder using the pre-atomic code path
      # could still leave this state.  Reclaim immediately.
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

  # Write our PID atomically via temp+rename so a concurrent waiter never sees
  # the lock dir exist with no PID file (the TOCTOU window the old direct echo
  # could create between mkdir and PID write).
  local _pid_tmp
  _pid_tmp=$(mktemp "${lock_dir}/pid.XXXXXX")
  echo $$ > "$_pid_tmp"
  mv "$_pid_tmp" "${lock_dir}/pid"

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
      # Lock dir exists but no PID file.  With atomic PID writes (mktemp + mv)
      # this window is effectively eliminated for holders using this module, but
      # a crashed holder or a very old holder using the pre-atomic code path
      # could still leave this state.  Reclaim immediately.
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

  # Write our PID atomically via temp+rename so a concurrent waiter never sees
  # the lock dir exist with no PID file (the TOCTOU window the old direct echo
  # could create between mkdir and PID write).
  local _pid_tmp
  _pid_tmp=$(mktemp "${lock_dir}/pid.XXXXXX")
  echo $$ > "$_pid_tmp"
  mv "$_pid_tmp" "${lock_dir}/pid"

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
