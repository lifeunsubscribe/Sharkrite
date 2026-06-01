#!/bin/bash
# lib/utils/stash-manager.sh
# Manages sharkrite-created git stashes with automatic cleanup.
#
# All sharkrite-created stashes are tagged with [sharkrite-managed-stash]
# in the message. Cleanup removes only tagged stashes older than a
# configurable age (default: 7 days), never touching user-created stashes.

set -euo pipefail

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

if ! source "$RITE_LIB_DIR/utils/colors.sh"; then
  echo "ERROR: Failed to load colors.sh" >&2
  exit 1
fi

# Marker tag for sharkrite-created stashes.
# Guard the readonly declaration: when this file is sourced multiple times in
# the same shell (which happens when several lib files independently include
# it), bash raises "readonly variable" on the second source. Only declare if
# not already set.
if [ -z "${SHARKRITE_STASH_MARKER:-}" ]; then
  readonly SHARKRITE_STASH_MARKER="[sharkrite-managed-stash]"
fi

# ===================================================================
# PUBLIC: Create a marked stash
# ===================================================================

# create_sharkrite_stash MESSAGE [INCLUDE_UNTRACKED]
#
# Creates a git stash with the sharkrite marker tag.
# Returns: 0 if stash created, 1 if nothing to stash or error
#
# Usage:
#   create_sharkrite_stash "auto-stash before rebase"
#   create_sharkrite_stash "auto-stash before worktree cleanup" true
create_sharkrite_stash() {
  local message="$1"
  local include_untracked="${2:-false}"

  # Build stash command
  local stash_cmd="git stash push"
  if [ "$include_untracked" = "true" ]; then
    stash_cmd="$stash_cmd -u"
  fi

  # Add marker to message
  local marked_message="${SHARKRITE_STASH_MARKER} ${message}"

  # Get current stash count before attempting to create a new one
  local stash_count_before
  stash_count_before=$(git stash list 2>/dev/null | wc -l | tr -d ' ')

  # Create stash
  if ! $stash_cmd -m "$marked_message" 2>/dev/null; then
    return 1
  fi

  # Verify a stash was actually created
  local stash_count_after
  stash_count_after=$(git stash list 2>/dev/null | wc -l | tr -d ' ')

  if [ "$stash_count_after" -gt "$stash_count_before" ]; then
    return 0  # Stash was successfully created
  else
    return 1  # No stash was created (nothing to stash)
  fi
}

# ===================================================================
# PUBLIC: Cleanup old sharkrite stashes
# ===================================================================

# cleanup_sharkrite_stashes [REPO_PATH]
#
# Removes sharkrite-managed stashes older than RITE_STASH_CLEANUP_AGE_DAYS.
# Only removes stashes with the sharkrite marker — user stashes are never touched.
# Skips cleanup entirely if RITE_AUTO_STASH_CLEANUP=false.
#
# Returns: 0 on success or skip, 1 on error
cleanup_sharkrite_stashes() {
  local repo_path="${1:-.}"

  # Check opt-out flag
  if [ "${RITE_AUTO_STASH_CLEANUP:-true}" = "false" ]; then
    return 0
  fi

  # Get age threshold (default: 7 days)
  local age_days="${RITE_STASH_CLEANUP_AGE_DAYS:-7}"

  # Validate age_days is a positive integer
  if ! [[ "$age_days" =~ ^[0-9]+$ ]] || [ "$age_days" -le 0 ]; then
    print_warning "Invalid RITE_STASH_CLEANUP_AGE_DAYS='$age_days', using default 7"
    age_days=7
  fi

  local age_seconds=$((age_days * 86400))
  local current_epoch
  current_epoch=$(date +%s)
  local cutoff_epoch=$((current_epoch - age_seconds))

  # Get list of all stashes with the marker
  local stash_list
  stash_list=$(git -C "$repo_path" stash list 2>/dev/null | grep -F "$SHARKRITE_STASH_MARKER" || true)

  if [ -z "$stash_list" ]; then
    return 0  # No sharkrite stashes to clean
  fi

  local cleaned_count=0
  local kept_count=0

  # Process each marked stash in REVERSE order to avoid index shifting
  # When git stash drop removes an entry, all higher indices shift down.
  # Processing from highest to lowest index ensures refs remain valid.
  while IFS= read -r stash_line; do
    # Extract stash ref (e.g., "stash@{0}")
    local stash_ref
    stash_ref=$(echo "$stash_line" | cut -d':' -f1)

    # Get stash creation timestamp
    local stash_epoch
    stash_epoch=$(git -C "$repo_path" log -1 --format=%ct "$stash_ref" 2>/dev/null || echo "0")

    if [ "$stash_epoch" = "0" ]; then
      continue  # Skip if we can't get timestamp
    fi

    # Check age
    if [ "$stash_epoch" -lt "$cutoff_epoch" ]; then
      # Old stash — drop it
      if git -C "$repo_path" stash drop "$stash_ref" 2>/dev/null; then
        cleaned_count=$((cleaned_count + 1))
      fi
    else
      # Fresh stash — keep it
      kept_count=$((kept_count + 1))
    fi
  done <<< "$(echo "$stash_list" | tac)"

  # Report cleanup if verbose or if we cleaned anything
  if [ "$cleaned_count" -gt 0 ]; then
    if [ "${RITE_VERBOSE:-false}" = "true" ] || [ "$cleaned_count" -gt 5 ]; then
      print_info "Cleaned up $cleaned_count old sharkrite stash(es) (kept $kept_count recent)"
    fi
  fi

  return 0
}

# ===================================================================
# PUBLIC: Count sharkrite stashes
# ===================================================================

# count_sharkrite_stashes [REPO_PATH]
#
# Returns count of sharkrite-managed stashes (for diagnostics/testing).
# Outputs count to stdout.
count_sharkrite_stashes() {
  local repo_path="${1:-.}"

  local count
  count=$(git -C "$repo_path" stash list 2>/dev/null | grep -c -F "$SHARKRITE_STASH_MARKER" || true)

  echo "$count"
}
