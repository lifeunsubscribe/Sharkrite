#!/bin/bash
# lib/utils/cap-resume.sh - Opt-in auto-resume of batch after a usage-cap reset
#
# Exports one public function: attempt_cap_autoresume <manifest_path>
#
# Called from batch-process-issues.sh after the cap abort and post-loop cleanup,
# before the final exit.  If eligible (RITE_CAP_AUTORESUME=true, future
# reset_epoch, no prior resume of this manifest), the function:
#   1. Marks the manifest resumed=true (one-resume guard — prevents a second
#      cap in the resumed run from re-scheduling endlessly)
#   2. On macOS with AC power: starts caffeinate -i -t <secs+120> in the
#      background to hold the machine awake (operator ruling 2026-10-11).
#      On battery or non-macOS: skip the hold, print a note, still wait.
#   3. Waits in a 60-second-tick loop until reset_epoch passes — one long sleep
#      would pause across system sleep; the tick loop fires on next wake, late
#      but correct.
#   4. Releases the batch mutex explicitly (exec won't fire EXIT traps).
#   5. exec's rite with the remaining issues and flags from the manifest, so
#      the fresh process picks up any merges that landed while we waited.
#
# Returns 1 (does NOT exec) when not eligible — caller falls through to its
# normal exit path.

set -euo pipefail

# Re-source guard
if declare -f attempt_cap_autoresume >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# _cap_resume_is_on_ac
# Returns 0 when running on AC power, 1 on battery or when detection is
# unavailable (non-macOS, pmset absent, unrecognized output).
# Safe default is battery: skip the caffeinate hold rather than lock a
# machine awake when we can't confirm it's plugged in.
_cap_resume_is_on_ac() {
  command -v pmset >/dev/null 2>&1 || return 1
  pmset -g ps 2>/dev/null | grep -q "AC Power" || return 1
}

# attempt_cap_autoresume <manifest_path>
#
# See module header for full contract.
attempt_cap_autoresume() {
  local _manifest_path="${1:-}"

  # Feature gate
  [ "${RITE_CAP_AUTORESUME:-false}" = "true" ] || return 1

  # Manifest must exist
  [ -f "$_manifest_path" ] || return 1

  # One-resume guard: a second cap in the resumed run must not re-schedule
  local _already_resumed
  _already_resumed=$(jq -r '.resumed // false' "$_manifest_path" 2>/dev/null || echo "false")
  if [ "$_already_resumed" = "true" ]; then
    if declare -f print_info >/dev/null 2>&1; then
      print_info "Cap auto-resume skipped — this manifest was already used for one resume"
    fi
    return 1
  fi

  # Parse reset epoch and verify it is in the future
  local _reset_epoch
  _reset_epoch=$(jq -r '.reset_epoch // 0' "$_manifest_path" 2>/dev/null || echo "0")
  local _now
  _now=$(date +%s)
  [ "$_reset_epoch" -gt "$_now" ] || return 1

  # Parse remaining issues (jq array → one per line) and flags
  local -a _resume_args=()
  while IFS= read -r _ri; do
    [ -n "$_ri" ] && _resume_args+=("$_ri")
  done < <(jq -r '.issues[]' "$_manifest_path" 2>/dev/null || true)
  [ "${#_resume_args[@]}" -gt 0 ] || return 1

  local _resume_flags
  _resume_flags=$(jq -r '.flags // ""' "$_manifest_path" 2>/dev/null || echo "")
  if [ -n "$_resume_flags" ]; then
    local -a _flag_parts=()
    IFS=' ' read -r -a _flag_parts <<< "$_resume_flags"
    _resume_args+=("${_flag_parts[@]+"${_flag_parts[@]}"}")
  fi

  # Mark resumed BEFORE the wait so that if the process is interrupted during
  # the wait the guard is already in place.
  local _tmp_manifest
  _tmp_manifest=$(mktemp "${_manifest_path}.XXXXXX")
  if jq '.resumed = true' "$_manifest_path" > "$_tmp_manifest" 2>/dev/null; then
    mv "$_tmp_manifest" "$_manifest_path"
  else
    rm -f "$_tmp_manifest" 2>/dev/null || true
    return 1
  fi

  local _wait_secs=$(( _reset_epoch - _now ))

  # Print the plan so the operator knows what is about to happen
  if declare -f print_info >/dev/null 2>&1; then
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_info "Cap auto-resume: waiting ${_wait_secs}s for cap reset"
    print_info "Will re-run: rite ${_resume_args[*]}"
  fi

  # Power-aware hold: caffeinate only on AC power.
  # Holding a battery-powered machine awake burns charge for a deferred run
  # the user may not have intended; skip the hold and print a note instead.
  local _caffeinate_pid=""
  if _cap_resume_is_on_ac && command -v caffeinate >/dev/null 2>&1; then
    if declare -f print_info >/dev/null 2>&1; then
      print_info "On AC power — holding machine awake with caffeinate"
    fi
    caffeinate -i -t $(( _wait_secs + 120 )) &
    _caffeinate_pid=$!
  else
    if declare -f print_info >/dev/null 2>&1; then
      print_info "On battery (or caffeinate unavailable) — not holding the machine awake; resume fires on next wake if it sleeps"
    fi
  fi

  # Wait loop: 60-second ticks so the loop fires on next wake after a system
  # sleep rather than waiting for a single long sleep to un-pause.
  while [ "$(date +%s)" -lt "$_reset_epoch" ]; do
    sleep 60
  done

  # Terminate caffeinate if we started it (it may still have time remaining)
  if [ -n "$_caffeinate_pid" ]; then
    kill "$_caffeinate_pid" 2>/dev/null || true
  fi

  if declare -f print_info >/dev/null 2>&1; then
    print_info "Cap has reset — re-invoking: rite ${_resume_args[*]}"
  fi

  # Release the batch mutex explicitly: exec replaces the process image so the
  # EXIT trap (_cleanup_batch_session → release_batch_lock) never fires.
  # See: docs/architecture/behavioral-design.md → "Lock Release Before exec"
  if declare -f release_batch_lock >/dev/null 2>&1; then
    release_batch_lock
  fi

  # Locate the rite binary and exec the resumed batch.
  local _rite_bin
  _rite_bin=$(command -v rite 2>/dev/null || echo "rite")
  exec "$_rite_bin" "${_resume_args[@]+"${_resume_args[@]}"}"
}
