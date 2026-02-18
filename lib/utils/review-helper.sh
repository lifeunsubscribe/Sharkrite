#!/bin/bash
# lib/utils/review-helper.sh
# Shared review helper functions for consistent behavior across workflow scripts
#
# Usage:
#   source "$RITE_LIB_DIR/utils/review-helper.sh"
#   get_review_for_pr <pr_number> [--auto]
#   trigger_local_review <pr_number> [--auto]
#   handle_stale_review <pr_number> [--auto]

# Ensure config is loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  echo "ERROR: review-helper.sh must be sourced after config.sh" >&2
  return 1 2>/dev/null || exit 1
fi

# Colors for output (if not already defined)
: "${YELLOW:=\033[1;33m}"
: "${NC:=\033[0m}"

# =============================================================================
# Trigger a local Sharkrite review
# Usage: trigger_local_review <pr_number> [--auto]
# Returns: 0 = success, 1 = failure
# =============================================================================
trigger_local_review() {
  local pr_number="$1"
  local auto_mode=false

  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto) auto_mode=true ;;
    esac
    shift
  done

  local local_review_script="$RITE_LIB_DIR/core/local-review.sh"

  if [ ! -f "$local_review_script" ]; then
    echo -e "${YELLOW}⚠️  local-review.sh not found at $local_review_script${NC}" >&2
    return 1
  fi

  if [ "$auto_mode" = true ]; then
    "$local_review_script" "$pr_number" --post --auto 2>&1
  else
    "$local_review_script" "$pr_number" --post 2>&1
  fi

  return $?
}

# =============================================================================
# Get a review for a PR
# Usage: get_review_for_pr <pr_number> [--auto]
# Returns: 0 = review obtained, 1 = no review
# =============================================================================
get_review_for_pr() {
  local pr_number="$1"
  local auto_mode=false

  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto) auto_mode=true ;;
    esac
    shift
  done

  if [ "$auto_mode" = true ]; then
    trigger_local_review "$pr_number" --auto
  else
    trigger_local_review "$pr_number"
  fi

  return $?
}

# =============================================================================
# Handle stale review (trigger fresh local review)
# Usage: handle_stale_review <pr_number> [--auto]
# Returns: 0 = fresh review obtained, 1 = failed
# =============================================================================
handle_stale_review() {
  local pr_number="$1"
  local auto_mode=false

  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto) auto_mode=true ;;
    esac
    shift
  done

  # Note: Caller (assess-and-resolve.sh) already printed stale warning, don't duplicate

  if [ "$auto_mode" = true ]; then
    trigger_local_review "$pr_number" --auto
  else
    trigger_local_review "$pr_number"
  fi

  return $?
}

# Export functions
export -f trigger_local_review
export -f get_review_for_pr
export -f handle_stale_review
