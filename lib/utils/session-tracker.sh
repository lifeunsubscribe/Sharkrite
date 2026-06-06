#!/bin/bash
# lib/utils/session-tracker.sh
# Track session state, time, and token usage
# Usage: source this file and call session tracking functions
#
# Expects config.sh to be already loaded (provides SESSION_STATE_FILE,
# RITE_PROJECT_NAME, RITE_WORKTREE_DIR, RITE_DATA_DIR)

set -euo pipefail

# Re-source guard — variable-based (not function-sentinel) because this file
# `export -f`s its functions; see blocker-rules.sh for the full rationale and
# tests/regression/blocker-rules-stale-inherited-functions.bats for the trap.
# Do NOT export _RITE_SESSION_TRACKER_LOADED — subprocesses must re-source.
if [ "${_RITE_SESSION_TRACKER_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_SESSION_TRACKER_LOADED=true

# ---------------------------------------------------------------------------
# Session-state lock
#
# All functions that read-modify-write SESSION_STATE_FILE must hold this lock.
# The lock is derived from SESSION_STATE_FILE (same path + ".lock") and uses
# the same dual-path strategy as scratchpad-lock.sh:
#   - Fast path: flock(1) when available (Linux / Homebrew util-linux on macOS)
#   - Portable path: mkdir-based advisory lock with atomic PID write via mv
#
# Internal state (set by _acquire_session_lock, read by _release_session_lock)
# ---------------------------------------------------------------------------
_SESSION_LOCK_FD=201          # File descriptor used for flock fast-path
_SESSION_LOCK_HELD=false      # True once lock is successfully acquired
_SESSION_LOCKFILE=""          # Set to actual lock path on acquire
# Strategy used at acquire time: "flock" or "mkdir".
# Persisted so that release always uses the same path type as acquire, regardless
# of whether PATH changes between the two calls or whether another process on a
# shared filesystem chose a different strategy for the same lock path.
_SESSION_LOCK_STRATEGY=""     # "flock" or "mkdir" — set by acquire, read by release

# _acquire_session_lock
#
# Acquires the session-state lock. On success returns 0. On timeout exits 1.
# Timeout configurable via RITE_SESSION_LOCK_TIMEOUT (default: 30s).
_acquire_session_lock() {
  local state_file="${SESSION_STATE_FILE:-}"
  if [ -z "$state_file" ]; then
    echo "ERROR: _acquire_session_lock: SESSION_STATE_FILE is not set" >&2
    exit 1
  fi

  local lockfile="${state_file}.lock"
  _SESSION_LOCKFILE="$lockfile"

  local max_attempts="${RITE_SESSION_LOCK_TIMEOUT:-30}"

  # Fast path: flock is available
  if command -v flock >/dev/null 2>&1; then
    # Clean up any leftover mkdir-style lock directory from a previous run where
    # flock was not available.  The directory would block flock from creating its
    # plain-file lock at the same path (open(2) fails if a directory is in the way).
    if [ -d "$lockfile" ]; then
      local _stale_pid
      _stale_pid=$(cat "$lockfile/pid" 2>/dev/null || true)
      if [ -z "$_stale_pid" ] || ! kill -0 "$_stale_pid" 2>/dev/null; then
        echo "session-lock: removing leftover mkdir-style lock dir before flock acquire" >&2
        rm -rf "$lockfile" 2>/dev/null || true
      fi
    fi
    # shellcheck disable=SC1083
    eval "exec ${_SESSION_LOCK_FD}>\"$lockfile\""
    if ! flock -w "$max_attempts" "$_SESSION_LOCK_FD" 2>/dev/null; then
      echo "ERROR: Could not acquire session-state lock within ${max_attempts}s." >&2
      echo "       If a previous run crashed, remove: rm -f \"$lockfile\"" >&2
      exit 1
    fi
    _SESSION_LOCK_HELD=true
    _SESSION_LOCK_STRATEGY="flock"
    return 0
  fi

  # Portable path: mkdir-based lock with atomic PID write
  # Clean up any leftover plain-file lock from a previous flock run
  if [ -f "$lockfile" ] && [ ! -d "$lockfile" ]; then
    rm -f "$lockfile"
  fi

  local lock_attempts=0
  local pid_tmp

  while ! mkdir "$lockfile" 2>/dev/null; do
    if [ -f "$lockfile/pid" ]; then
      local lock_pid
      lock_pid=$(cat "$lockfile/pid" 2>/dev/null || true)
      # kill -0: same-host assumption — only valid within a single PID namespace.
      # SESSION_STATE_FILE (and its lockfile) must not be on shared/network storage;
      # kill -0 checks the local process table only and will give false "dead process"
      # results for PIDs held by processes on other hosts or in isolated PID namespaces.
      if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        echo "session-lock: reclaiming stale lock from dead process (PID $lock_pid)" >&2
        rm -rf "$lockfile" 2>/dev/null || true
        continue
      fi
    else
      # Lock dir exists but no PID file — give it a grace period before reclaiming
      sleep 1
      if [ ! -f "$lockfile/pid" ]; then
        echo "session-lock: reclaiming lock dir with no PID after grace period" >&2
        rm -rf "$lockfile" 2>/dev/null || true
        continue
      fi
    fi

    lock_attempts=$((lock_attempts + 1))
    if [ "$lock_attempts" -ge "$max_attempts" ]; then
      echo "ERROR: Session-state lock timeout after ${max_attempts}s." >&2
      echo "       To recover, remove: rm -rf \"$lockfile\"" >&2
      exit 1
    fi
    sleep 1
  done

  # Write PID atomically via temp+rename so waiters never see an empty lock dir
  pid_tmp=$(mktemp "${lockfile}/pid.XXXXXX")
  echo $$ > "$pid_tmp"
  mv "$pid_tmp" "${lockfile}/pid"

  _SESSION_LOCK_HELD=true
  _SESSION_LOCK_STRATEGY="mkdir"
  return 0
}

# _release_session_lock
#
# Releases the session-state lock. Idempotent — safe to call multiple times.
_release_session_lock() {
  if [ "$_SESSION_LOCK_HELD" != "true" ]; then
    return 0
  fi

  local lockfile="${_SESSION_LOCKFILE:-${SESSION_STATE_FILE:-}.lock}"

  # Use the strategy recorded at acquire time, not a fresh command -v check.
  # Re-checking command -v flock here would cause a mismatch if PATH changed
  # between acquire and release, or if two processes on a shared filesystem
  # chose different strategies for the same lock path.
  if [ "${_SESSION_LOCK_STRATEGY:-}" = "flock" ]; then
    # Release flock by closing the fd (do NOT rm — see scratchpad-lock.sh comment)
    flock -u "$_SESSION_LOCK_FD" 2>/dev/null || true
    eval "exec ${_SESSION_LOCK_FD}>&-" 2>/dev/null || true
  else
    # mkdir-style: verify PID before removing
    if [ -d "$lockfile" ] && [ -f "$lockfile/pid" ]; then
      local lock_pid
      lock_pid=$(cat "$lockfile/pid" 2>/dev/null || true)
      if [ "$lock_pid" = "$$" ]; then
        rm -rf "$lockfile" 2>/dev/null || true
      fi
    fi
  fi

  _SESSION_LOCK_HELD=false
  _SESSION_LOCK_STRATEGY=""
}

# Initialize session tracking
#
# INVOCATION SEMANTICS (new — replaces old UPSERT semantics):
#
#   Fresh invocation (default): reset start_time to now; preserve
#   approved_blockers and sent_notifications (legitimately durable cross-run
#   state); clear current_issue, worktree_path (per-invocation fields).
#   Also resets per-issue timing fields: current_issue_started_at = null,
#   cumulative_work_seconds = 0.
#
#   Resume mode (RITE_RESUMING=true in env): keep the file completely
#   untouched — inherit start_time, cumulative_work_seconds, and all other
#   fields from the prior run. Used by crash-recovery resume and supervised
#   reload paths.
#
#   Parallel batch invocations: each batch creates its own SESSION_STATE_FILE
#   (via RITE_BATCH_ID), so concurrent init_session calls never race on the
#   same file. Within a single batch, the orchestrator (batch-process-issues.sh)
#   calls init_session once; per-issue workers call start_issue_tracking /
#   end_issue_tracking instead.
#
# WHY start_time IS RESET (Option 2 fix, issue #283):
#   The old upsert-never-overwrite logic caused a "zombie file" bug: a stale
#   state file from a prior invocation (e.g., a batch that crashed 40h ago)
#   caused get_elapsed_hours() to return 40, which immediately triggered the
#   session_limit blocker on every fresh single-issue invocation until the
#   file was manually deleted. start_time measures THIS invocation's clock,
#   not the age of the JSON file.
# shellcheck disable=SC2120  # CI's older shellcheck misses cross-file callers; local 0.11.0 doesn't flag this. Callers DO pass mode: workflow-runner.sh:2290, batch-process-issues.sh:175.
init_session() {
  local mode="${1:-supervised}"  # supervised or unsupervised

  _acquire_session_lock

  local _now
  _now=$(date +%s)

  # Resume mode: keep the existing file untouched — caller owns all fields.
  if [ "${RITE_RESUMING:-false}" = "true" ] && [ -f "$SESSION_STATE_FILE" ]; then
    _release_session_lock
    export SESSION_START_TIME=$(jq -r '.start_time' "$SESSION_STATE_FILE" 2>/dev/null || echo "$_now")
    return 0
  fi

  if [ -f "$SESSION_STATE_FILE" ]; then
    # Fresh invocation found an existing state file (e.g. zombie from prior run
    # or a parallel batch's file from a previous batch ID collision).
    # Reset the clock and per-invocation fields; preserve cross-run state.
    local _tmp
    _tmp=$(mktemp)
    jq \
      --argjson now "$_now" \
      '.start_time = $now
       | .last_update = $now
       | .current_issue = null
       | .worktree_path = null
       | .current_issue_started_at = null
       | .cumulative_work_seconds = (.cumulative_work_seconds // 0 | 0)
       | .mode = "'"$mode"'"' \
      "$SESSION_STATE_FILE" > "$_tmp"
    mv "$_tmp" "$SESSION_STATE_FILE"
    _release_session_lock
    export SESSION_START_TIME="$_now"
    return 0
  fi

  # True fresh init (file doesn't exist) — write initial state.
  cat > "$SESSION_STATE_FILE" <<EOF
{
  "start_time": ${_now},
  "mode": "$mode",
  "issues_completed": 0,
  "issues_failed": 0,
  "current_issue": null,
  "worktree_path": null,
  "current_issue_started_at": null,
  "cumulative_work_seconds": 0,
  "approved_blockers": [],
  "sent_notifications": [],
  "last_update": ${_now}
}
EOF

  _release_session_lock
  export SESSION_START_TIME="$_now"
}

# Update session state
update_session() {
  local key="$1"
  local value="$2"

  if [ ! -f "$SESSION_STATE_FILE" ]; then
    init_session
  fi

  # Hold the lock across the entire read-modify-write cycle so concurrent
  # callers don't clobber each other's updates.
  _acquire_session_lock

  local temp
  temp=$(mktemp)
  jq ".${key} = ${value} | .last_update = $(date +%s)" "$SESSION_STATE_FILE" > "$temp"
  mv "$temp" "$SESSION_STATE_FILE"

  _release_session_lock
}

# Get session info
get_session_info() {
  if [ ! -f "$SESSION_STATE_FILE" ]; then
    echo "{}"
    return
  fi

  cat "$SESSION_STATE_FILE"
}

# start_issue_tracking ISSUE_NUM
#
# Records the start time of per-issue work in the session state file.
# Must be called just before kicking off the per-issue workflow (Phase 1).
# Paired with end_issue_tracking — call that when the issue finishes (any
# outcome: completed, failed, blocked).
#
# Writes: current_issue_started_at = now (epoch seconds)
start_issue_tracking() {
  local issue_number="${1:-}"

  if [ ! -f "$SESSION_STATE_FILE" ]; then
    init_session
  fi

  _acquire_session_lock

  local _now
  _now=$(date +%s)
  local _tmp
  _tmp=$(mktemp)
  jq \
    --argjson now "$_now" \
    --arg issue "${issue_number}" \
    '.current_issue_started_at = $now
     | .current_issue = $issue
     | .last_update = $now' \
    "$SESSION_STATE_FILE" > "$_tmp"
  mv "$_tmp" "$SESSION_STATE_FILE"

  _release_session_lock
}

# end_issue_tracking ISSUE_NUM
#
# Records the end of per-issue work: adds the elapsed per-issue seconds to
# cumulative_work_seconds and clears current_issue_started_at.
# Must be called after every per-issue workflow exit (success, failure, blocker).
#
# Writes: cumulative_work_seconds += (now - current_issue_started_at)
#         current_issue_started_at = null
end_issue_tracking() {
  local issue_number="${1:-}"

  if [ ! -f "$SESSION_STATE_FILE" ]; then
    return 0  # Nothing to end — no state file; safe no-op
  fi

  _acquire_session_lock

  local _now
  _now=$(date +%s)
  local _tmp
  _tmp=$(mktemp)

  # Read current_issue_started_at; if null/missing, treat as 0 elapsed
  jq \
    --argjson now "$_now" \
    '
    (.current_issue_started_at // null) as $started |
    (if $started != null then ($now - $started) else 0 end) as $delta |
    .cumulative_work_seconds = ((.cumulative_work_seconds // 0) + $delta)
    | .current_issue_started_at = null
    | .last_update = $now
    ' \
    "$SESSION_STATE_FILE" > "$_tmp"
  mv "$_tmp" "$SESSION_STATE_FILE"

  _release_session_lock
}

# get_cumulative_work_seconds
#
# Returns the total seconds of active per-issue work accumulated in this session.
# This is what detect_session_limit uses — not wall-clock elapsed since start_time.
get_cumulative_work_seconds() {
  if [ ! -f "$SESSION_STATE_FILE" ]; then
    echo "0"
    return
  fi

  local _cumulative
  _cumulative=$(jq -r '.cumulative_work_seconds // 0' "$SESSION_STATE_FILE" 2>/dev/null || echo "0")

  # If an issue is currently running, add the in-progress time
  local _started
  _started=$(jq -r '.current_issue_started_at // empty' "$SESSION_STATE_FILE" 2>/dev/null || true)
  if [ -n "$_started" ]; then
    local _now
    _now=$(date +%s)
    _cumulative=$(( _cumulative + _now - _started ))
  fi

  echo "$_cumulative"
}

# get_current_issue_elapsed_seconds
#
# Returns how many seconds the currently-tracked issue has been running.
# Returns 0 if no issue is currently being tracked.
get_current_issue_elapsed_seconds() {
  if [ ! -f "$SESSION_STATE_FILE" ]; then
    echo "0"
    return
  fi

  local _started
  _started=$(jq -r '.current_issue_started_at // empty' "$SESSION_STATE_FILE" 2>/dev/null || true)

  if [ -z "$_started" ]; then
    echo "0"
    return
  fi

  local _now
  _now=$(date +%s)
  echo $(( _now - _started ))
}

# Get elapsed time (wall-clock since this invocation's start_time)
#
# NOTE: This is now informational only — session limit enforcement reads
# cumulative_work_seconds (via get_cumulative_work_seconds), not this value.
get_elapsed_time() {
  local start_time
  start_time=$(jq -r '.start_time' "$SESSION_STATE_FILE" 2>/dev/null || echo "$(date +%s)")
  local current_time
  current_time=$(date +%s)
  local elapsed=$((current_time - start_time))

  echo "$elapsed"
}

# Get elapsed hours (wall-clock since this invocation's start_time)
#
# NOTE: This is now informational only — use get_cumulative_work_seconds for
# session limit enforcement. See issue #283 for why wall-clock is wrong metric.
get_elapsed_hours() {
  local elapsed
  elapsed=$(get_elapsed_time)
  echo $((elapsed / 3600))
}

# Format elapsed time for display
format_elapsed_time() {
  local elapsed=$(get_elapsed_time)
  local hours=$((elapsed / 3600))
  local minutes=$(( (elapsed % 3600) / 60 ))
  local seconds=$((elapsed % 60))

  if [ $hours -gt 0 ]; then
    echo "${hours}h ${minutes}m ${seconds}s"
  elif [ $minutes -gt 0 ]; then
    echo "${minutes}m ${seconds}s"
  else
    echo "${seconds}s"
  fi
}

# Increment completed issues
#
# Reads and writes under the same lock so concurrent calls from parallel
# rite invocations don't lose increments (read-outside-lock TOCTOU).
increment_completed() {
  if [ ! -f "$SESSION_STATE_FILE" ]; then
    init_session
  fi

  _acquire_session_lock

  local current
  current=$(jq -r '.issues_completed' "$SESSION_STATE_FILE" 2>/dev/null || echo "0")
  local temp
  temp=$(mktemp)
  jq ".issues_completed = $((current + 1)) | .last_update = $(date +%s)" "$SESSION_STATE_FILE" > "$temp"
  mv "$temp" "$SESSION_STATE_FILE"

  _release_session_lock
}

# Increment failed issues
#
# Reads and writes under the same lock (same TOCTOU fix as increment_completed).
increment_failed() {
  if [ ! -f "$SESSION_STATE_FILE" ]; then
    init_session
  fi

  _acquire_session_lock

  local current
  current=$(jq -r '.issues_failed' "$SESSION_STATE_FILE" 2>/dev/null || echo "0")
  local temp
  temp=$(mktemp)
  jq ".issues_failed = $((current + 1)) | .last_update = $(date +%s)" "$SESSION_STATE_FILE" > "$temp"
  mv "$temp" "$SESSION_STATE_FILE"

  _release_session_lock
}

# Set current issue
set_current_issue() {
  local issue_number="$1"
  update_session "current_issue" "\"$issue_number\""
}

# Set current worktree
set_current_worktree() {
  local worktree_path="$1"
  update_session "worktree_path" "\"$worktree_path\""
}

# Check if should continue or save state
#
# Uses cumulative_work_seconds (not wall-clock elapsed) for the time check.
# See detect_session_limit in blocker-rules.sh for enforcement details.
should_save_and_exit() {
  local issues_completed
  issues_completed=$(jq -r '.issues_completed' "$SESSION_STATE_FILE" 2>/dev/null || echo "0")

  local cumulative_secs
  cumulative_secs=$(get_cumulative_work_seconds)
  local cumulative_hours=$(( cumulative_secs / 3600 ))

  # Conservative limits (from blocker-rules.sh)
  if [ "$issues_completed" -ge "${RITE_MAX_ISSUES_PER_SESSION:-8}" ]; then
    echo "token_limit"
    return 0
  fi

  if [ "$cumulative_hours" -ge "${RITE_MAX_SESSION_HOURS:-12}" ]; then
    echo "time_limit"
    return 0
  fi

  echo "continue"
  return 1
}

# Save session state for resume
save_session_state() {
  local issue_number="$1"
  local reason="$2"
  local worktree_path="$3"

  local data_dir="${RITE_DATA_DIR:-.rite}"
  local state_file="${RITE_PROJECT_ROOT:-.}/${data_dir}/session-state-${issue_number}.json"

  cat > "$state_file" <<EOF
{
  "saved_at": $(date +%s),
  "saved_at_human": "$(date '+%Y-%m-%d %H:%M:%S')",
  "reason": "$reason",
  "issue_number": "$issue_number",
  "worktree_path": "$worktree_path",
  "session_info": $(cat "$SESSION_STATE_FILE"),
  "git_status": "$(cd "$worktree_path" 2>/dev/null && git status --short | base64)",
  "last_commit": "$(cd "$worktree_path" 2>/dev/null && git log -1 --oneline)"
}
EOF

  echo "💾 Session state saved to: $state_file"
}

# Create resume script
create_resume_script() {
  local issue_number="$1"
  local blocker_type="$2"
  local blocker_details="$3"
  local worktree_path="$4"
  local pr_number="${5:-}"

  local timestamp=$(date +%Y%m%d-%H%M%S)
  local data_dir="${RITE_DATA_DIR:-.rite}"
  local resume_script="${RITE_PROJECT_ROOT:-.}/${data_dir}/resume-${issue_number}-${timestamp}.sh"

  cat > "$resume_script" <<EOF
#!/bin/bash
# Auto-generated resume script
# Created: $(date '+%Y-%m-%d %H:%M:%S')
# Issue: #${issue_number}
# Blocker: ${blocker_type}

# ===================================================================
# STATE SNAPSHOT
# ===================================================================

ISSUE_NUMBER=${issue_number}
WORKTREE_PATH="${worktree_path}"
PR_NUMBER="${pr_number}"
BLOCKER_TYPE="${blocker_type}"

# ===================================================================
# BLOCKER DETAILS
# ===================================================================

cat <<'BLOCKER_EOF'
${blocker_details}
BLOCKER_EOF

echo ""
echo "=========================================="
echo "🔄 Resume Workflow for Issue #${issue_number}"
echo "=========================================="
echo ""

# Show current state
if [ -f "${data_dir}/session-state-${issue_number}.json" ]; then
  echo "📊 Saved Session State:"
  cat "${data_dir}/session-state-${issue_number}.json" | jq .
  echo ""
fi

# Show git status if worktree exists
if [ -d "\$WORKTREE_PATH" ]; then
  echo "📂 Worktree Status:"
  cd "\$WORKTREE_PATH"
  git status --short
  echo ""
  echo "📝 Last Commit:"
  git log -1 --oneline
  echo ""
else
  echo "⚠️  Worktree not found at: \$WORKTREE_PATH"
  echo ""
fi

# ===================================================================
# BLOCKER-SPECIFIC INSTRUCTIONS
# ===================================================================

case "\$BLOCKER_TYPE" in
  infrastructure|database_migration)
    echo "⚠️  Manual Review Required"
    echo ""
    echo "This blocker requires you to review and approve changes:"
    echo "1. Review the changes above"
    echo "2. Test locally if needed"
    echo "3. Confirm it's safe to proceed"
    echo ""
    ;;

  session_limit|token_limit)
    echo "ℹ️  Session Limit Reached"
    echo ""
    echo "Work was saved automatically. Ready to continue in fresh session."
    echo ""
    ;;

  credentials_expired)
    echo "🔑 AWS Credentials Expired"
    echo ""
    echo "Run: aws sso login --profile \${RITE_AWS_PROFILE:-default}"
    echo "Then continue with this script."
    echo ""
    ;;
esac

# ===================================================================
# RESUME PROMPT
# ===================================================================

read -p "Ready to continue workflow? (y/n) " -n 1 -r
echo
echo

if [[ ! \$REPLY =~ ^[Yy]$ ]]; then
  echo "❌ Cancelled."
  echo ""
  echo "To manually work on this issue:"
  echo "  cd \$WORKTREE_PATH"
  echo "  claude-code"
  exit 0
fi

# ===================================================================
# RESUME WORKFLOW
# ===================================================================

echo "✅ Resuming workflow..."
echo ""

# Navigate to worktree
cd "\$WORKTREE_PATH" || exit 1

# Re-export environment
export WORKFLOW_MODE="\${WORKFLOW_MODE:-supervised}"
export RITE_NOTIFICATIONS="${RITE_NOTIFICATIONS:-false}"
export EMAIL_NOTIFICATION_ADDRESS="${EMAIL_NOTIFICATION_ADDRESS:-}"
export SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
export ISSUE_NUMBER=\$ISSUE_NUMBER

# Call rite to continue
rite \$ISSUE_NUMBER --resume

EOF

  chmod +x "$resume_script"

  echo "📄 Resume script created: $resume_script"
  echo ""
  echo "To resume later, run:"
  echo "  $resume_script"
}

# Get session summary
get_session_summary() {
  local session_info=$(get_session_info)

  local completed=$(echo "$session_info" | jq -r '.issues_completed')
  local failed=$(echo "$session_info" | jq -r '.issues_failed')
  local elapsed=$(format_elapsed_time)
  local mode=$(echo "$session_info" | jq -r '.mode')

  echo "📊 Session Summary"
  echo "=================="
  echo "Mode: $mode"
  echo "Duration: $elapsed"
  echo "Issues Completed: $completed"
  if [ "$failed" -gt 0 ] 2>/dev/null; then
    echo "Issues Failed: $failed"
  fi
  echo "Total Processed: $((completed + failed))"
}

# ---------------------------------------------------------------------------
# Cross-run persistence for approved_blockers and sent_notifications
#
# The in-process session file (SESSION_STATE_FILE) lives in /tmp and can be
# cleared between runs (reboot, OS tmp cleanup).  To survive across separate
# `rite` invocations, approvals and notifications are ALSO written to a durable
# file in the project's .rite/state/ directory.
#
# File: ${RITE_STATE_DIR}/approval-state.json  (gitignored, per-developer)
# Format:
#   {
#     "approved_blockers": ["42:critical_issues", ...],
#     "sent_notifications": ["42:blocker:credentials_expired", ...]
#   }
#
# Reads check the durable file when the in-memory session file is absent.
# Writes update both the in-memory session AND the durable file.
# The in-memory session file is protected by the per-session lock (_acquire_session_lock).
# The durable approval-state file is protected by its own dedicated approval lock
# (_acquire_approval_lock) so that concurrent `rite` invocations on different issues
# — each with a separate SESSION_STATE_FILE and per-session lock — cannot race on the
# shared approval-state.json.
# ---------------------------------------------------------------------------

# Path to the durable cross-run approval state file.
# Derived from RITE_STATE_DIR (set by config.sh to .rite/state/).
# Falls back to /tmp if RITE_STATE_DIR is unset (e.g., in unit tests that
# don't source config.sh).
_get_approval_state_file() {
  local state_dir="${RITE_STATE_DIR:-}"
  if [ -n "$state_dir" ]; then
    echo "${state_dir}/approval-state.json"
  else
    # Fallback: derive from SESSION_STATE_FILE's directory or /tmp
    echo "/tmp/rite-approval-state-${RITE_PROJECT_NAME:-unknown}.json"
  fi
}

# _ensure_approval_state_file
#
# Creates the durable approval state file if it does not yet exist.
# Must be called while holding the session lock.
_ensure_approval_state_file() {
  local approval_file
  approval_file="$(_get_approval_state_file)"

  # Ensure parent directory exists (RITE_STATE_DIR may not be created yet in
  # tests or when config.sh's mkdir block was skipped).
  local parent_dir
  parent_dir="$(dirname "$approval_file")"
  mkdir -p "$parent_dir" 2>/dev/null || true

  if [ ! -f "$approval_file" ]; then
    cat > "$approval_file" <<'EOF'
{
  "approved_blockers": [],
  "sent_notifications": []
}
EOF
  fi
}

# _acquire_approval_lock
#
# Acquires a dedicated mkdir-based lock for the durable approval-state file.
# This lock is SEPARATE from the per-session lock so that concurrent `rite`
# invocations operating on different issues (each with their own SESSION_STATE_FILE
# and per-session lock path) don't race on the shared approval-state.json.
#
# Uses mkdir atomic semantics (same portable pattern as the session lock).
# Timeout controlled by RITE_APPROVAL_LOCK_TIMEOUT (default: 30s).
_acquire_approval_lock() {
  local approval_file
  approval_file="$(_get_approval_state_file)"
  local lockdir="${approval_file}.lock"
  local max_attempts="${RITE_APPROVAL_LOCK_TIMEOUT:-30}"
  local attempts=0
  local pid_tmp

  while ! mkdir "$lockdir" 2>/dev/null; do
    if [ -f "$lockdir/pid" ]; then
      local lock_pid
      lock_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
      if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        echo "approval-lock: reclaiming stale lock from dead process (PID $lock_pid)" >&2
        rm -rf "$lockdir" 2>/dev/null || true
        continue
      fi
    else
      attempts=$((attempts + 1))
      if [ "$attempts" -ge "$max_attempts" ]; then
        echo "ERROR: approval-state lock timeout after ${max_attempts}s." >&2
        echo "       To recover, remove: rm -rf \"$lockdir\"" >&2
        exit 1
      fi
      sleep 1
      if [ ! -f "$lockdir/pid" ]; then
        echo "approval-lock: reclaiming lock dir with no PID after grace period" >&2
        rm -rf "$lockdir" 2>/dev/null || true
        continue
      fi
    fi

    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$max_attempts" ]; then
      echo "ERROR: approval-state lock timeout after ${max_attempts}s." >&2
      echo "       To recover, remove: rm -rf \"$lockdir\"" >&2
      exit 1
    fi
    sleep 1
  done

  # Write PID atomically so waiters never see an empty lock dir
  pid_tmp=$(mktemp "${lockdir}/pid.XXXXXX")
  echo $$ > "$pid_tmp"
  mv "$pid_tmp" "${lockdir}/pid"
}

# _release_approval_lock
#
# Releases the dedicated approval-state lock. Idempotent.
_release_approval_lock() {
  local approval_file
  approval_file="$(_get_approval_state_file)"
  local lockdir="${approval_file}.lock"

  if [ -d "$lockdir" ] && [ -f "$lockdir/pid" ]; then
    local lock_pid
    lock_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
    if [ "$lock_pid" = "$$" ]; then
      rm -rf "$lockdir" 2>/dev/null || true
    fi
  fi
}

# _add_to_approval_file KEY FIELD
#
# Appends KEY to the named array FIELD in the durable approval state file.
# Acquires and releases its own dedicated approval-state lock so that concurrent
# `rite` invocations on different issues (each with a distinct SESSION_STATE_FILE
# and per-session lock) cannot race on the shared approval-state.json.
_add_to_approval_file() {
  local key="$1"
  local field="$2"

  local approval_file
  approval_file="$(_get_approval_state_file)"

  _acquire_approval_lock

  # Ensure the lock is always released, even if jq or mv fails.
  trap '_release_approval_lock' EXIT

  # File creation moved inside the lock to eliminate TOCTOU race: two concurrent
  # processes could previously both pass the pre-lock existence check and race to
  # create the file before either acquired the lock.
  _ensure_approval_state_file

  local temp
  temp=$(mktemp)
  jq --arg field "$field" --arg key "$key" '.[$field] = ((.[$field] // []) + [$key] | unique)' "$approval_file" > "$temp"
  mv "$temp" "$approval_file"

  trap - EXIT
  _release_approval_lock
}

# _has_in_approval_file KEY FIELD
#
# Returns 0 (true) if KEY is present in FIELD in the durable approval state file.
# Returns 1 otherwise (including if the file does not exist or is malformed).
#
# Malformed file handling: jq parse failures return "false" (safe false-negative)
# and emit a warning to stderr so operators can investigate.  The lock-free read
# is an intentional design trade-off — atomic mv makes concurrent writes safe, but
# a pre-existing malformed file produces silent false negatives without this warning.
_has_in_approval_file() {
  local key="$1"
  local field="$2"

  local approval_file
  approval_file="$(_get_approval_state_file)"

  if [ ! -f "$approval_file" ]; then
    return 1
  fi

  local found
  found=$(jq -r --arg field "$field" --arg key "$key" \
    '.[$field] // [] | index($key) != null' "$approval_file" 2>/dev/null || true)

  # Warn when jq returns empty (parse failure = malformed file).
  # A well-formed file always produces "true" or "false" — never empty.
  if [ -z "$found" ]; then
    echo "⚠️  approval-state.json may be malformed: jq returned empty for field '$field'" >&2
    echo "    File: $approval_file" >&2
    echo "    To recover, remove or repair the file and re-run the workflow." >&2
    return 1
  fi

  [ "$found" = "true" ]
}

# Track an approved blocker to avoid re-prompting
add_approved_blocker() {
  local issue_number="$1"
  local blocker_type="$2"

  if [ ! -f "$SESSION_STATE_FILE" ]; then
    init_session
  fi

  # Hold lock across read-modify-write to prevent concurrent callers from
  # clobbering each other's approved_blockers entries.
  _acquire_session_lock

  local key="${issue_number}:${blocker_type}"

  # Write to the in-memory session file (fast, per-session dedup)
  local temp
  temp=$(mktemp)
  jq --arg key "$key" --argjson ts "$(date +%s)" \
    '.approved_blockers = ((.approved_blockers // []) + [$key] | unique) | .last_update = $ts' \
    "$SESSION_STATE_FILE" > "$temp"
  mv "$temp" "$SESSION_STATE_FILE"

  # Also write to the durable cross-run state file so approvals survive
  # /tmp cleanup, reboots, or a cleanup_session → init_session sequence.
  _add_to_approval_file "$key" "approved_blockers"

  _release_session_lock
}

# Check if a blocker was already approved for this issue
#
# Checks both:
#   1. The in-memory session file (SESSION_STATE_FILE, /tmp — fast path)
#   2. The durable cross-run file (.rite/state/approval-state.json — survives reboots)
has_approved_blocker() {
  local issue_number="$1"
  local blocker_type="$2"

  local key="${issue_number}:${blocker_type}"

  # Fast path: check in-memory session file
  if [ -f "$SESSION_STATE_FILE" ]; then
    local found
    found=$(jq -r ".approved_blockers // [] | index(\"$key\") != null" "$SESSION_STATE_FILE" 2>/dev/null || echo "false")
    if [ "$found" = "true" ]; then
      return 0  # Already approved in this session
    fi
  fi

  # Durable path: check cross-run approval state file
  # This catches approvals from a previous run that survived after /tmp was cleared.
  if _has_in_approval_file "$key" "approved_blockers"; then
    return 0
  fi

  return 1  # Not approved
}

# Track a sent notification to avoid duplicates
add_sent_notification() {
  local issue_number="$1"
  local notification_type="$2"  # e.g., "blocker:auth_changes"

  if [ ! -f "$SESSION_STATE_FILE" ]; then
    init_session
  fi

  # Hold lock across read-modify-write to prevent concurrent callers from
  # clobbering each other's sent_notifications entries.
  _acquire_session_lock

  local key="${issue_number}:${notification_type}"

  # Write to the in-memory session file (fast, per-session dedup)
  local temp
  temp=$(mktemp)
  jq --arg key "$key" --argjson ts "$(date +%s)" \
    '.sent_notifications = ((.sent_notifications // []) + [$key] | unique) | .last_update = $ts' \
    "$SESSION_STATE_FILE" > "$temp"
  mv "$temp" "$SESSION_STATE_FILE"

  # Also write to the durable cross-run state file so notifications survive
  # /tmp cleanup, reboots, or a cleanup_session → init_session sequence.
  _add_to_approval_file "$key" "sent_notifications"

  _release_session_lock
}

# Check if a notification was already sent for this issue
#
# Checks both:
#   1. The in-memory session file (SESSION_STATE_FILE, /tmp — fast path)
#   2. The durable cross-run file (.rite/state/approval-state.json — survives reboots)
has_sent_notification() {
  local issue_number="$1"
  local notification_type="$2"

  local key="${issue_number}:${notification_type}"

  # Fast path: check in-memory session file
  if [ -f "$SESSION_STATE_FILE" ]; then
    local found
    found=$(jq -r ".sent_notifications // [] | index(\"$key\") != null" "$SESSION_STATE_FILE" 2>/dev/null || echo "false")
    if [ "$found" = "true" ]; then
      return 0  # Already sent in this session
    fi
  fi

  # Durable path: check cross-run approval state file
  # This catches notifications from a previous run that survived after /tmp was cleared.
  if _has_in_approval_file "$key" "sent_notifications"; then
    return 0
  fi

  return 1  # Not sent
}

# Clean up session state
cleanup_session() {
  rm -f "$SESSION_STATE_FILE"
  rm -rf "${SESSION_STATE_FILE}.lock"
  echo "✅ Session cleaned up"
}

# ---------------------------------------------------------------------------
# Approval reset functions
#
# These provide the supported recovery path when an approval was recorded in
# error. Without these, users resort to undocumented manual file deletion of
# .rite/state/approval-state.json (issue #255).
#
# All three functions clear both the in-memory session file AND the durable
# approval-state.json so the reset takes effect in the current session as
# well as future runs.
# ---------------------------------------------------------------------------

# _remove_from_approval_file KEY FIELD
#
# Removes KEY from the named array FIELD in the durable approval state file.
# Acquires and releases the dedicated approval-state lock (same as
# _add_to_approval_file) so concurrent `rite` invocations cannot race.
# No-op if the file does not exist or KEY is not present.
_remove_from_approval_file() {
  local key="$1"
  local field="$2"

  local approval_file
  approval_file="$(_get_approval_state_file)"

  if [ ! -f "$approval_file" ]; then
    return 0  # Nothing to remove
  fi

  _acquire_approval_lock

  # Ensure the lock is always released, even if jq or mv fails.
  trap '_release_approval_lock' EXIT

  local temp
  temp=$(mktemp)
  jq --arg field "$field" --arg key "$key" \
    '.[$field] = ((.[$field] // []) | map(select(. != $key)))' \
    "$approval_file" > "$temp"
  mv "$temp" "$approval_file"

  trap - EXIT
  _release_approval_lock
}

# _remove_prefix_from_approval_file PREFIX FIELD
#
# Removes all entries in FIELD whose key starts with PREFIX from the durable
# approval state file.  Used to clear all blockers for a given issue number.
# Acquires the dedicated approval-state lock.
# No-op if the file does not exist.
_remove_prefix_from_approval_file() {
  local prefix="$1"
  local field="$2"

  local approval_file
  approval_file="$(_get_approval_state_file)"

  if [ ! -f "$approval_file" ]; then
    return 0  # Nothing to remove
  fi

  _acquire_approval_lock

  trap '_release_approval_lock' EXIT

  local temp
  temp=$(mktemp)
  jq --arg field "$field" --arg prefix "$prefix" \
    '.[$field] = ((.[$field] // []) | map(select(startswith($prefix) | not)))' \
    "$approval_file" > "$temp"
  mv "$temp" "$approval_file"

  trap - EXIT
  _release_approval_lock
}

# reset_approved_blocker ISSUE_NUMBER BLOCKER_TYPE
#
# Removes a specific blocker approval for an issue from both the in-memory
# session file and the durable approval-state.json.
#
# Use case: a user approved a blocker by mistake and wants to re-prompt next
# time the workflow encounters it.
reset_approved_blocker() {
  local issue_number="$1"
  local blocker_type="$2"

  local key="${issue_number}:${blocker_type}"

  # Clear from in-memory session file (if present)
  if [ -f "${SESSION_STATE_FILE:-}" ]; then
    _acquire_session_lock
    local temp
    temp=$(mktemp)
    jq --arg key "$key" \
      '.approved_blockers = ((.approved_blockers // []) | map(select(. != $key)))' \
      "$SESSION_STATE_FILE" > "$temp"
    mv "$temp" "$SESSION_STATE_FILE"
    _release_session_lock
  fi

  # Clear from durable approval-state.json
  _remove_from_approval_file "$key" "approved_blockers"
}

# reset_approved_blockers_for_issue ISSUE_NUMBER
#
# Removes ALL blocker approvals for a given issue from both stores.
# Clears entries with keys of the form "${issue_number}:*".
#
# Use case: the user wants a completely fresh blocker evaluation when re-running
# an issue that had blockers approved in a previous run.
reset_approved_blockers_for_issue() {
  local issue_number="$1"

  local prefix="${issue_number}:"

  # Clear from in-memory session file (if present)
  if [ -f "${SESSION_STATE_FILE:-}" ]; then
    _acquire_session_lock
    local temp
    temp=$(mktemp)
    jq --arg prefix "$prefix" \
      '.approved_blockers = ((.approved_blockers // []) | map(select(startswith($prefix) | not)))' \
      "$SESSION_STATE_FILE" > "$temp"
    mv "$temp" "$SESSION_STATE_FILE"
    _release_session_lock
  fi

  # Clear from durable approval-state.json
  _remove_prefix_from_approval_file "$prefix" "approved_blockers"
}

# reset_all_approved_blockers
#
# Clears the entire approved_blockers array from both the in-memory session
# file and the durable approval-state.json.
#
# Use case: global fresh start — wipe all persisted approvals across all issues.
reset_all_approved_blockers() {
  # Clear from in-memory session file (if present)
  if [ -f "${SESSION_STATE_FILE:-}" ]; then
    _acquire_session_lock
    local temp
    temp=$(mktemp)
    jq '.approved_blockers = []' "$SESSION_STATE_FILE" > "$temp"
    mv "$temp" "$SESSION_STATE_FILE"
    _release_session_lock
  fi

  # Clear from durable approval-state.json
  local approval_file
  approval_file="$(_get_approval_state_file)"

  if [ ! -f "$approval_file" ]; then
    return 0  # Nothing to clear
  fi

  _acquire_approval_lock
  trap '_release_approval_lock' EXIT

  local temp
  temp=$(mktemp)
  jq '.approved_blockers = []' "$approval_file" > "$temp"
  mv "$temp" "$approval_file"

  trap - EXIT
  _release_approval_lock
}

# Export functions if sourced
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  export -f _acquire_session_lock
  export -f _release_session_lock
  export -f _acquire_approval_lock
  export -f _release_approval_lock
  export -f init_session
  export -f update_session
  export -f get_session_info
  export -f get_elapsed_time
  export -f get_elapsed_hours
  export -f get_cumulative_work_seconds
  export -f get_current_issue_elapsed_seconds
  export -f start_issue_tracking
  export -f end_issue_tracking
  export -f format_elapsed_time
  export -f increment_completed
  export -f increment_failed
  export -f set_current_issue
  export -f set_current_worktree
  export -f should_save_and_exit
  export -f save_session_state
  export -f create_resume_script
  export -f get_session_summary
  export -f add_approved_blocker
  export -f has_approved_blocker
  export -f add_sent_notification
  export -f has_sent_notification
  export -f cleanup_session
  export -f reset_approved_blocker
  export -f reset_approved_blockers_for_issue
  export -f reset_all_approved_blockers
fi
