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
    else
      # Supervised mode — prompt
      echo "" >&2
      echo -e "${YELLOW:-}⚠️  timeout command not found${NC:-}" >&2
      echo "  Sharkrite uses timeout to prevent Claude sessions from hanging." >&2
      echo "  Without it, a stalled Claude call will block the workflow indefinitely." >&2
      echo "" >&2
      read -p "  Install coreutils via Homebrew? (Y/n): " -n 1 -r REPLY >&2
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
