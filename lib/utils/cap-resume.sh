#!/bin/bash
# lib/utils/cap-resume.sh - Opt-in auto-resume after a usage-cap abort.
#
# Provides:
#   attempt_cap_autoresume <manifest_path>
#     Called by batch-process-issues.sh in the exit-5 handler after the manifest
#     is written and the abort message is printed. If RITE_CAP_AUTORESUME=true and
#     the manifest has a valid future reset_epoch, this function waits until the
#     cap resets then exec's rite with the remaining issues — replacing the
#     current process. It does NOT return in that case.
#
#     Returns 0 (without exec) when any gate fails, so the caller proceeds with
#     its normal fallback path (break from the issue loop → batch reporter).
#
#   _cap_autoresume_wait <target_epoch>
#     60-second-tick wait loop. Extracted so tests can override it to a no-op
#     without requiring a test-mode env var.
#
# Design notes:
# - exec does NOT fire EXIT traps (see CLAUDE.md → "exec does NOT fire EXIT traps"),
#   so release_batch_lock is called explicitly before exec.
# - caffeinate is only started on AC power (macOS). On battery or non-macOS it is
#   skipped; the wait loop still fires on the next wake if the machine slept.
# - One-resume guard: the 'resumed' field in the manifest prevents a second cap
#   from rescheduling — the second abort falls through to the normal break path.
# - Word-splitting on the flags string is intentional: flags are controlled operator
#   values (--smart-wait, --branch NAME), never free user input.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f attempt_cap_autoresume >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# 60-second-tick wait loop. Extracted for test overridability.
# Argument: _target_epoch (Unix epoch seconds to wait until)
_cap_autoresume_wait() {
  local _target="${1:-0}"
  while [ "$(date +%s)" -lt "$_target" ]; do
    sleep 60
  done
}

# Opt-in auto-resume after a usage-cap abort.
#
# Arguments:
#   $1 = path to the cap-resume manifest JSON (written by the exit-5 handler)
#
# Side effects on the exec path:
#   - Rewrites the manifest with resumed:true (one-resume guard)
#   - Starts caffeinate in background (macOS + AC power only)
#   - Calls _cap_autoresume_wait to block until the cap resets
#   - Releases the batch lock (release_batch_lock if defined)
#   - exec's rite with the remaining issues and flags from the manifest
#
# Returns 0 without exec when any gate fails:
#   - RITE_CAP_AUTORESUME is not "true"
#   - manifest file does not exist
#   - manifest already has resumed:true (second-cap guard)
#   - reset_epoch is 0 or already in the past
#   - issues array in manifest is empty
attempt_cap_autoresume() {
  local _manifest_path="${1:-}"

  # Gate 1: feature must be opted in (global operator config — off by default)
  [ "${RITE_CAP_AUTORESUME:-false}" = "true" ] || return 0

  # Gate 2: manifest must exist
  [ -f "${_manifest_path:-}" ] || return 0

  # Gate 3: one-resume guard — a second cap in the resumed run aborts normally;
  # no reschedule loops.
  local _already_resumed
  _already_resumed=$(jq -r '.resumed // false' "$_manifest_path" 2>/dev/null || echo "false")
  if [ "$_already_resumed" = "true" ]; then
    print_info "Auto-resume: already resumed once — not rescheduling after second cap."
    return 0
  fi

  # Gate 4: reset_epoch must be in the future (0 means unknown reset time)
  local _reset_epoch _now
  _reset_epoch=$(jq -r '.reset_epoch // 0' "$_manifest_path" 2>/dev/null || echo "0")
  _now=$(date +%s)
  if [ "$_reset_epoch" -le 0 ] || [ "$_reset_epoch" -le "$_now" ]; then
    print_info "Auto-resume: no valid future reset time — not auto-resuming."
    return 0
  fi

  # Gate 5: manifest must have at least one issue to run
  local _issue_count
  _issue_count=$(jq -r '.issues | length' "$_manifest_path" 2>/dev/null || echo "0")
  if [ "$_issue_count" -le 0 ]; then
    print_info "Auto-resume: no remaining issues in manifest."
    return 0
  fi

  # Mark as resumed before waiting — second cap in the resumed run sees this flag
  # and falls through to the normal break path (no infinite reschedule loop).
  local _tmp
  _tmp=$(mktemp)
  if jq '. + {resumed: true}' "$_manifest_path" > "$_tmp" 2>/dev/null; then
    mv "$_tmp" "$_manifest_path" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
  else
    rm -f "$_tmp" 2>/dev/null || true
  fi

  # Target epoch: cap reset time + 30s jitter so the cap is definitely cleared
  local _wait_secs _target_epoch
  _wait_secs=$((_reset_epoch - _now + 30))
  _target_epoch=$((_reset_epoch + 30))

  # Power check: caffeinate only on AC power (macOS).
  # Non-macOS or unknown power state → treat as battery (skip caffeinate).
  local _on_ac=false
  if [ "$(uname 2>/dev/null || echo unknown)" = "Darwin" ]; then
    if pmset -g ps 2>/dev/null | grep -q "AC Power"; then
      _on_ac=true
    fi
  fi

  # Print the plan loudly before blocking
  echo ""
  print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  print_info "Auto-resume enabled (RITE_CAP_AUTORESUME=true)"
  print_info "Waiting $(_format_elapsed "$_wait_secs") until cap resets..."
  if [ "$(uname 2>/dev/null || echo unknown)" = "Darwin" ]; then
    if [ "$_on_ac" = "true" ]; then
      print_info "Power: AC — holding machine awake with caffeinate"
    else
      print_info "Power: battery — not holding machine awake; resume fires on next wake if it sleeps"
    fi
  fi
  print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # caffeinate: prevent idle sleep until cap resets + 120s buffer (AC only).
  # Background process — killed after the wait loop exits.
  local _caffeinate_pid=""
  if [ "$(uname 2>/dev/null || echo unknown)" = "Darwin" ] && [ "$_on_ac" = "true" ]; then
    local _caff_secs
    _caff_secs=$((_wait_secs + 120))
    caffeinate -i -t "$_caff_secs" &
    _caffeinate_pid=$!
  fi

  # Wait until cap resets. The loop fires on next wake if the machine slept —
  # the timer skips forward, the condition triggers, and exec fires late but
  # correct. One long `sleep $_wait_secs` would suspend across system sleep and
  # never fire; 60s ticks ensure the loop resumes after every wake.
  _cap_autoresume_wait "$_target_epoch"

  # Stop caffeinate if still running (may already be gone if AC was unplugged)
  if [ -n "$_caffeinate_pid" ]; then
    kill "$_caffeinate_pid" 2>/dev/null || true
  fi

  # Release the batch lock explicitly — exec does NOT fire EXIT traps, so the
  # trap-registered release_batch_lock would never run otherwise.
  # See: CLAUDE.md → "exec does NOT fire EXIT traps"
  if declare -f release_batch_lock >/dev/null 2>&1; then
    release_batch_lock
  fi

  print_info "Cap reset — re-launching batch..."
  echo ""

  # Build exec args from the manifest (single source of truth for remaining work)
  local _flags_str
  _flags_str=$(jq -r '.flags // ""' "$_manifest_path" 2>/dev/null || echo "")

  local _exec_args=()
  # Read issues one per line to avoid word-splitting concerns on the number list
  while IFS= read -r _issue_num; do
    [ -n "$_issue_num" ] && _exec_args+=("$_issue_num")
  done < <(jq -r '.issues[]' "$_manifest_path" 2>/dev/null || true)

  if [ "${#_exec_args[@]}" -eq 0 ]; then
    # Manifest was valid at Gate 5 but empty now — should not happen; fail open.
    print_warning "Auto-resume: issue list disappeared from manifest — cannot re-launch."
    return 0
  fi

  # Append flags. Values are controlled operator config (--smart-wait, --branch NAME),
  # never free user input — word-splitting is correct here.
  if [ -n "$_flags_str" ]; then
    # shellcheck disable=SC2206
    local _flags_arr=($_flags_str)
    _exec_args+=("${_flags_arr[@]+"${_flags_arr[@]}"}")
  fi

  exec rite "${_exec_args[@]+"${_exec_args[@]}"}"
}
