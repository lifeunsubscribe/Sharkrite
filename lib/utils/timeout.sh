#!/bin/bash
# lib/utils/timeout.sh - Shared timeout command detection and auto-install
#
# Usage:
#   source "$RITE_LIB_DIR/utils/timeout.sh"
#   ensure_timeout_cmd          # Detects or installs; sets RITE_TIMEOUT_CMD
#   $RITE_TIMEOUT_CMD 120 cmd   # Use it (empty string = no timeout, safe to expand)
#
# RITE_TIMEOUT_CMD is set to one of:
#   "gtimeout"  — macOS with coreutils installed
#   "timeout"   — Linux or macOS with coreutils in PATH as timeout
#   ""          — user declined install; callers run without timeout
#
# The install prompt runs at most once per session (guarded by _RITE_TIMEOUT_CHECKED).

set -euo pipefail

# Skip if already resolved this session AND functions are defined.
# The env var survives across subprocesses but function definitions don't,
# so we must re-source if the functions are missing even when the var is set.
if [ "${_RITE_TIMEOUT_CHECKED:-false}" = true ] && declare -f run_with_timeout >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

ensure_timeout_cmd() {
  # Already resolved
  if [ "${_RITE_TIMEOUT_CHECKED:-false}" = true ]; then
    return 0
  fi

  # Check gtimeout first (macOS coreutils)
  if command -v gtimeout >/dev/null 2>&1; then
    RITE_TIMEOUT_CMD="gtimeout"
    export RITE_TIMEOUT_CMD
    _RITE_TIMEOUT_CHECKED=true
    export _RITE_TIMEOUT_CHECKED
    return 0
  fi

  # Check native timeout (Linux, or macOS with coreutils symlinked)
  if command -v timeout >/dev/null 2>&1; then
    RITE_TIMEOUT_CMD="timeout"
    export RITE_TIMEOUT_CMD
    _RITE_TIMEOUT_CHECKED=true
    export _RITE_TIMEOUT_CHECKED
    return 0
  fi

  # Not found — offer to install
  _RITE_TIMEOUT_CHECKED=true
  export _RITE_TIMEOUT_CHECKED

  # Check if we can install (macOS with brew)
  if [[ "$(uname)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    # In auto/unsupervised mode, install without prompting
    if [ "${WORKFLOW_MODE:-}" = "unsupervised" ] || [ "${BATCH_MODE:-false}" = true ]; then
      echo -e "${YELLOW:-}⚠️  timeout command not found — installing coreutils automatically${NC:-}" >&2
      if brew install coreutils >/dev/null 2>&1; then
        RITE_TIMEOUT_CMD="gtimeout"
        export RITE_TIMEOUT_CMD
        echo -e "${GREEN:-}✅ Installed coreutils (gtimeout now available)${NC:-}" >&2
        return 0
      else
        echo -e "${RED:-}❌ Failed to install coreutils${NC:-}" >&2
      fi
    elif [ ! -t 0 ]; then
      # Supervised mode WITHOUT a terminal (CI, cron/launchd, piped stdin).
      # Nobody can answer a prompt here, and `read -p` at EOF returns non-zero
      # — under set -e that kills the ENTIRE source chain, because config.sh
      # calls ensure_timeout_cmd at source time (STEP 6b). Live failure:
      # macOS CI without coreutils — `load_lib utils/pr-detection.sh` died
      # inside this function (full-phase.bats). Fall through to the graceful
      # no-timeout fallback below instead of crashing.
      echo -e "${YELLOW:-}⚠️  timeout command not found — continuing without timeout protection${NC:-}" >&2
      echo "  Install with: brew install coreutils" >&2
    else
      # Supervised mode — prompt
      echo "" >&2
      echo -e "${YELLOW:-}⚠️  timeout command not found${NC:-}" >&2
      echo "  Sharkrite uses timeout to prevent Claude sessions from hanging." >&2
      echo "  Without it, a stalled Claude call will block the workflow indefinitely." >&2
      echo "" >&2
      # `|| REPLY=n` — a TTY read can still fail (Ctrl-D); treat as decline
      # rather than letting set -e kill the source chain.
      read -p "  Install coreutils via Homebrew? (Y/n): " -n 1 -r REPLY >&2 || REPLY="n"
      echo >&2
      if [[ -z "$REPLY" || "$REPLY" =~ ^[Yy]$ ]]; then
        echo "  Installing coreutils..." >&2
        if brew install coreutils >/dev/null 2>&1; then
          RITE_TIMEOUT_CMD="gtimeout"
          export RITE_TIMEOUT_CMD
          echo -e "${GREEN:-}✅ Installed coreutils (gtimeout now available)${NC:-}" >&2
          return 0
        else
          echo -e "${RED:-}❌ Failed to install coreutils — continuing without timeout${NC:-}" >&2
        fi
      else
        echo "  Skipping — workflows will run without timeout protection" >&2
      fi
    fi
  elif [[ "$(uname)" == "Darwin" ]]; then
    echo -e "${YELLOW:-}⚠️  timeout command not found and Homebrew is not installed${NC:-}" >&2
    echo "  Install Homebrew (https://brew.sh) then run: brew install coreutils" >&2
  fi

  # Fallback: no timeout
  RITE_TIMEOUT_CMD=""
  export RITE_TIMEOUT_CMD
}

# Run a command with timeout if available, without if not.
# Usage: run_with_timeout SECONDS command [args...]
run_with_timeout() {
  local timeout_secs="$1"
  shift

  if [ -n "${RITE_TIMEOUT_CMD:-}" ]; then
    "$RITE_TIMEOUT_CMD" "$timeout_secs" "$@"
  else
    "$@"
  fi
}

# Recursively terminate a process and ALL its descendants, children first.
# Portable: uses `pgrep -P` (present on macOS and Linux) — no setsid/`pkill -g`
# dependency, no reliance on the target being a process-group leader.
# Note: a descendant that already re-parented to init (orphan) is no longer
# reachable via pgrep -P and will survive — that's acceptable here, because the
# point is to free the WAITER (kill the gate + its still-attached tee/bats so
# the orchestrator stops waiting); a stray orphan no longer blocks anything.
# Usage: kill_process_tree PID [SIGNAL]   (SIGNAL default: TERM)
kill_process_tree() {
  local _pid="${1:-}"
  local _sig="${2:-TERM}"
  [ -n "$_pid" ] || return 0
  local _child
  for _child in $(pgrep -P "$_pid" 2>/dev/null || true); do
    kill_process_tree "$_child" "$_sig"
  done
  kill "-${_sig}" "$_pid" 2>/dev/null || true
}

# Wait for a background PID up to TIMEOUT_SECS. If it exits in time, reap it and
# return its real exit code. If it does not, return 124 (the caller decides how
# to kill it — typically kill_process_tree). Poll-based because we are waiting on
# a PID we backgrounded ourselves, where `gtimeout` (a command wrapper) does not
# apply. Exists to bound the post-commit gate wait: a leaked test subprocess can
# hold the gate's stdout pipe so `tee` never sees EOF and the gate PID never
# exits — without this bound that hangs the whole workflow for hours (issue #654).
# Usage: wait_pid_with_timeout PID TIMEOUT_SECS
wait_pid_with_timeout() {
  local _pid="${1:-}"
  local _timeout="${2:-1800}"
  [ -n "$_pid" ] || return 0
  local _waited=0
  while kill -0 "$_pid" 2>/dev/null; do
    if [ "$_waited" -ge "$_timeout" ]; then
      return 124
    fi
    sleep 1
    _waited=$((_waited + 1))
  done
  # Process is gone — reap it (it's our direct child) and surface its exit code.
  local _rc=0
  wait "$_pid" 2>/dev/null || _rc=$?
  return "$_rc"
}
