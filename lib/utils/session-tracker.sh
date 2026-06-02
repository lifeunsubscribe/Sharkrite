#!/bin/bash
# lib/utils/session-tracker.sh
# Track session state, time, and token usage
# Usage: source this file and call session tracking functions
#
# Expects config.sh to be already loaded (provides SESSION_STATE_FILE,
# RITE_PROJECT_NAME, RITE_WORKTREE_DIR, RITE_DATA_DIR)

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f init_session >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

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
# UPSERT SEMANTICS: acquires lock, then only writes initial state if the file
# does not already exist. If another process has already initialized the file,
# this call is a no-op (it does NOT reset issues_completed to 0).
#
# This prevents the race where two parallel `rite` invocations both call
# init_session: without the guard, whichever calls last wins and resets the
# counter, losing increments from the other process.
init_session() {
  local mode="${1:-supervised}"  # supervised or unsupervised

  _acquire_session_lock

  # If the state file already exists, another process beat us to init —
  # leave it untouched to preserve its counters and cross-run state.
  if [ -f "$SESSION_STATE_FILE" ]; then
    _release_session_lock
    export SESSION_START_TIME=$(date +%s)
    return 0
  fi

  # Write initial state only if the file is absent (true init, not re-init)
  cat > "$SESSION_STATE_FILE" <<EOF
{
  "start_time": $(date +%s),
  "mode": "$mode",
  "issues_completed": 0,
  "issues_failed": 0,
  "current_issue": null,
  "worktree_path": null,
  "approved_blockers": [],
  "sent_notifications": [],
  "last_update": $(date +%s)
}
EOF

  _release_session_lock
  export SESSION_START_TIME=$(date +%s)
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

# Get elapsed time
get_elapsed_time() {
  local start_time=$(jq -r '.start_time' "$SESSION_STATE_FILE" 2>/dev/null || echo "$(date +%s)")
  local current_time=$(date +%s)
  local elapsed=$((current_time - start_time))

  echo "$elapsed"
}

# Get elapsed hours
get_elapsed_hours() {
  local elapsed=$(get_elapsed_time)
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
should_save_and_exit() {
  local issues_completed=$(jq -r '.issues_completed' "$SESSION_STATE_FILE" 2>/dev/null || echo "0")
  local elapsed_hours=$(get_elapsed_hours)

  # Conservative limits (from blocker-rules.sh)
  if [ "$issues_completed" -ge "${RITE_MAX_ISSUES_PER_SESSION:-8}" ]; then
    echo "token_limit"
    return 0
  fi

  if [ "$elapsed_hours" -ge "${RITE_MAX_SESSION_HOURS:-4}" ]; then
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
# Returns 1 otherwise (including if the file does not exist).
_has_in_approval_file() {
  local key="$1"
  local field="$2"

  local approval_file
  approval_file="$(_get_approval_state_file)"

  if [ ! -f "$approval_file" ]; then
    return 1
  fi

  local found
  found=$(jq -r --arg field "$field" --arg key "$key" '.[$field] // [] | index($key) != null' "$approval_file" 2>/dev/null || echo "false")

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
fi
