#!/bin/bash
# lib/utils/logging.sh - Verbose-aware output functions
#
# Wraps the print_* functions from colors.sh with verbose gating.
# Output only appears when RITE_VERBOSE=true (set explicitly via --verbose
# or implicitly via --supervised).
#
# Usage:
#   source "$RITE_LIB_DIR/utils/logging.sh"
#   verbose_header "Section Title"
#   verbose_echo "detail line"
#   if is_verbose; then
#     echo "multi-line block"
#   fi

# Ensure colors.sh is loaded (idempotent — already sourced by most callers)
if ! declare -f print_header &>/dev/null; then
  source "${RITE_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}/utils/colors.sh"
fi

# Check if verbose output is enabled
is_verbose() {
  [ "${RITE_VERBOSE:-false}" = "true" ]
}

# Verbose-only output functions (no-op when not verbose)
verbose_header()  { is_verbose && print_header "$1"  || true; }
verbose_echo()    { is_verbose && echo "$@"           || true; }
verbose_info()    { is_verbose && print_info "$1"     || true; }
verbose_status()  { is_verbose && print_status "$1"   || true; }
verbose_success() { is_verbose && print_success "$1"  || true; }
verbose_warning() { is_verbose && print_warning "$1"  || true; }
verbose_step()    { is_verbose && print_step "$1"     || true; }

# =============================================================================
# Diagnostic timing — always logs to stderr (captured in log file)
# =============================================================================

# Format seconds into human-readable elapsed string
_format_elapsed() {
  local elapsed=$1
  if [ $elapsed -ge 3600 ]; then
    printf '%dh %dm %ds' $((elapsed / 3600)) $((elapsed % 3600 / 60)) $((elapsed % 60))
  elif [ $elapsed -ge 60 ]; then
    printf '%dm %ds' $((elapsed / 60)) $((elapsed % 60))
  else
    printf '%ds' $elapsed
  fi
}

# Start a named timer. Usage: _timer_start "claude-dev-session"
_timer_start() {
  local name="$1"
  local now
  now=$(date +%s)
  local ts
  ts=$(date '+%H:%M:%S')
  eval "_timer_${name//[^a-zA-Z0-9_]/_}=$now"

  if is_verbose; then echo "[timing] $ts | START $name" >&2
  elif [ -n "${RITE_LOG_FILE:-}" ]; then echo "[timing] $ts | START $name" >> "$RITE_LOG_FILE"
  fi

  # Start a live timer on the terminal (background process updates in-place).
  # Only runs when stdout is a terminal (not piped/redirected).
  # The timer writes directly to /dev/tty to avoid polluting log captures.
  local pid_var="_timer_pid_${name//[^a-zA-Z0-9_]/_}"
  if [ -t 1 ] || [ -t 2 ]; then
    local display_name
    display_name=$(echo "$name" | tr '_' ' ')
    (
      trap 'exit 0' TERM
      while true; do
        local _elapsed=$(( $(date +%s) - now ))
        printf '\r\033[0;90m  ⏱  %s: %s\033[0m' "$display_name" "$(_format_elapsed $_elapsed)" > /dev/tty 2>/dev/null || exit 0
        sleep 5
      done
    ) &
    eval "$pid_var=$!"
  fi
}

# End a named timer and log elapsed. Usage: _timer_end "claude-dev-session"
_timer_end() {
  local name="$1"
  local now
  now=$(date +%s)
  local ts
  ts=$(date '+%H:%M:%S')
  local var_name="_timer_${name//[^a-zA-Z0-9_]/_}"
  local start_time="${!var_name:-$now}"
  local elapsed=$((now - start_time))
  local elapsed_str
  elapsed_str=$(_format_elapsed $elapsed)

  # Kill the live timer display
  local pid_var="_timer_pid_${name//[^a-zA-Z0-9_]/_}"
  local timer_pid="${!pid_var:-}"
  if [ -n "$timer_pid" ]; then
    kill "$timer_pid" 2>/dev/null || true
    wait "$timer_pid" 2>/dev/null || true
    # Clear the timer line
    printf '\r\033[K' > /dev/tty 2>/dev/null || true
    unset "$pid_var"
  fi

  if is_verbose; then echo "[timing] $ts | END   $name ($elapsed_str)" >&2
  elif [ -n "${RITE_LOG_FILE:-}" ]; then echo "[timing] $ts | END   $name ($elapsed_str)" >> "$RITE_LOG_FILE"
  fi
  unset "$var_name"
}

# =============================================================================
# rtk token optimization diagnostics
# =============================================================================
# Captures rtk gain snapshots at phase boundaries for delta computation.
# Silently skipped if rtk is not installed.

# Internal state for delta computation
_rtk_prev_cmds=0
_rtk_prev_saved=0

# Named snapshot storage for per-phase delta retrieval at completion time.
# Stored as: _rtk_snap_<label>_cmds, _rtk_snap_<label>_saved
# Retrieved via: _rtk_phase_delta "phase1"

# Take an rtk gain snapshot and log it. Usage: _rtk_snapshot "phase1_start"
_rtk_snapshot() {
  command -v rtk &>/dev/null || return 0

  local label="$1"
  local ts
  ts=$(date '+%H:%M:%S')
  local json
  json=$(rtk gain --format json 2>/dev/null) || return 0

  local cmds saved avg
  cmds=$(echo "$json" | jq -r '.summary.total_commands // 0')
  saved=$(echo "$json" | jq -r '.summary.total_saved // 0')
  avg=$(echo "$json" | jq -r '(.summary.avg_savings_pct // 0) * 10 | round / 10')

  local line="[rtk] $ts | SNAP $label cmds=$cmds saved=$saved avg=${avg}%"

  # Compute delta from previous snapshot
  if [ "$_rtk_prev_cmds" -gt 0 ] 2>/dev/null; then
    local delta_cmds=$((cmds - _rtk_prev_cmds))
    local delta_saved=$((saved - _rtk_prev_saved))
    if [ "$delta_cmds" -gt 0 ]; then
      line="$line  delta_cmds=$delta_cmds delta_saved=$delta_saved"
    fi
  fi

  _rtk_prev_cmds=$cmds
  _rtk_prev_saved=$saved

  # Store named snapshot for later retrieval
  local safe_label="${label//[^a-zA-Z0-9_]/_}"
  eval "_rtk_snap_${safe_label}_cmds=$cmds"
  eval "_rtk_snap_${safe_label}_saved=$saved"

  if is_verbose; then echo "$line" >&2
  elif [ -n "${RITE_LOG_FILE:-}" ]; then echo "$line" >> "$RITE_LOG_FILE"
  fi
}

# Get token savings delta between two named snapshots. Usage: _rtk_phase_delta "phase1_start" "phase1_end"
# Outputs the saved-tokens delta (integer). Returns 1 if snapshots don't exist.
_rtk_phase_delta() {
  local start_label="${1//[^a-zA-Z0-9_]/_}"
  local end_label="${2//[^a-zA-Z0-9_]/_}"
  local start_var="_rtk_snap_${start_label}_saved"
  local end_var="_rtk_snap_${end_label}_saved"
  local start_val="${!start_var:-}"
  local end_val="${!end_var:-}"
  if [ -n "$start_val" ] && [ -n "$end_val" ]; then
    echo $((end_val - start_val))
  else
    echo "0"
  fi
}

# Get rtk savings summary for display (returns empty string if rtk not installed)
_rtk_summary() {
  command -v rtk &>/dev/null || return 0

  local json
  json=$(rtk gain --format json 2>/dev/null) || return 0

  local cmds saved avg
  cmds=$(echo "$json" | jq -r '.summary.total_commands // 0')
  saved=$(echo "$json" | jq -r '.summary.total_saved // 0')
  avg=$(echo "$json" | jq -r '(.summary.avg_savings_pct // 0) * 10 | round / 10')

  if [ "$cmds" -gt 0 ] 2>/dev/null; then
    echo "Token optimization (rtk): $cmds commands compressed, $saved tokens saved (${avg}% avg)"
  fi
}

# =============================================================================
# Structured diagnostic logging for health reports
# =============================================================================
# Logs [diag] lines to RITE_LOG_FILE (or stderr if verbose).
# Usage: _diag "ASSESSMENT issue=42 retry=1 now=2 later=3 dismissed=1"

_diag() {
  local msg="$1"
  local ts
  ts=$(date '+%H:%M:%S')
  local line="[diag] $ts | $msg"
  if is_verbose; then echo "$line" >&2
  elif [ -n "${RITE_LOG_FILE:-}" ]; then echo "$line" >> "$RITE_LOG_FILE"
  fi
}

# Export for use in subshells
export RITE_VERBOSE
export -f is_verbose verbose_header verbose_echo verbose_info verbose_status verbose_success verbose_warning verbose_step _format_elapsed _timer_start _timer_end _rtk_snapshot _rtk_phase_delta _rtk_summary _diag 2>/dev/null || true
