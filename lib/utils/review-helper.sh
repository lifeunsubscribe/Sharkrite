#!/bin/bash
# lib/utils/review-helper.sh
# Shared review helper functions for consistent behavior across workflow scripts
#
# Usage:
#   source "$RITE_LIB_DIR/utils/review-helper.sh"
#   get_review_for_pr <pr_number> [--auto]
#   trigger_local_review <pr_number> [--auto]
#   handle_stale_review <pr_number> [--auto]

set -euo pipefail

# Re-source guard — variable-based (not function-sentinel) because this file
# `export -f`s its functions; see blocker-rules.sh for the full rationale and
# tests/regression/blocker-rules-stale-inherited-functions.bats for the trap.
# Do NOT export _RITE_REVIEW_HELPER_LOADED — subprocesses must re-source.
if [ "${_RITE_REVIEW_HELPER_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_REVIEW_HELPER_LOADED=true

# Ensure config is loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  echo "ERROR: review-helper.sh must be sourced after config.sh" >&2
  return 1 2>/dev/null || exit 1
fi

# Source dependencies needed by the shared helpers defined below.
# colors.sh:  print_warning (used by resolve_pr_head_sha fallback warnings)
# markers.sh: RITE_MARKER_REVIEW constant (used by extract_review_sha)
# gh-retry.sh: gh_safe wrapper (used by resolve_pr_head_sha)
_review_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_review_helper_dir/colors.sh"
source "$_review_helper_dir/markers.sh"
source "$_review_helper_dir/gh-retry.sh"

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

# =============================================================================
# extract_review_sha — parse the HEAD SHA embedded in a review marker
#
# Reviews generated after issue #354 embed the HEAD SHA at generation time:
#   <!-- sharkrite-local-review model:X timestamp:Y commit:<sha> -->
# This function extracts that SHA so callers can perform a deterministic
# staleness check (SHA comparison) rather than the racy timestamp comparison.
#
# Usage: extract_review_sha <review_body>
# Output: SHA string on stdout, or empty string if the review predates SHA
#         embedding (reviews before issue #354 won't have the commit: attribute).
# =============================================================================
extract_review_sha() {
  local review_body="$1"
  # Match "commit:" followed by a hex SHA (7-40 chars) inside the marker comment.
  # The outer grep anchors to the marker prefix so commit: references inside the
  # review body text are not mistakenly captured as the embedded SHA.
  echo "$review_body" | grep -oE "${RITE_MARKER_REVIEW}[^>]*commit:[a-f0-9]{7,40}" | \
    grep -oE "commit:[a-f0-9]{7,40}" | sed 's/commit://' | head -1 || true
}

# =============================================================================
# resolve_pr_head_sha — authoritative-remote-first HEAD SHA resolution
#
# Returns the current HEAD SHA for a PR by preferring the GitHub API
# (headRefOid) over local git. Local git rev-parse is unreliable when cwd is
# the main checkout rather than the PR worktree — it would return main's HEAD,
# which compares unequal to the review SHA and produces a false stale verdict.
#
# Strategy:
#   1. Fetch headRefOid from the GitHub API (authoritative — matches what was
#      actually pushed to the remote PR branch, regardless of cwd).
#   2. Fall back to local git only when:
#      a. WORKTREE_PATH is set and the directory exists, AND
#      b. The local branch on that worktree matches the PR's headRefName
#         (guards against cwd being on main or another branch).
#   3. If WORKTREE_PATH is absent, fall back to cwd-relative git only when
#      the current branch matches the PR's headRefName.
#   4. If headRefName is unknown (partial API failure), fall back with a warning.
#      Worst case: a false-positive stale verdict, not a false-negative.
#
# Usage: resolve_pr_head_sha <pr_number> [worktree_path]
# Output: SHA string on stdout (may be empty when all fallbacks fail)
# Relies on: gh_safe (from gh-retry.sh), print_warning (from colors.sh/logging.sh)
# =============================================================================
resolve_pr_head_sha() {
  local pr_number="$1"
  local worktree_path="${2:-}"

  local _rph_head_sha=""
  local _rph_pr_head_ref _rph_remote_sha _rph_branch_name

  # Step 1: try GitHub API (always authoritative regardless of cwd)
  _rph_pr_head_ref=$(gh_safe pr view "$pr_number" --json headRefName,headRefOid \
    --jq '{name: .headRefName, sha: .headRefOid}' 2>/dev/null || true)
  _rph_remote_sha=$(echo "$_rph_pr_head_ref" | jq -r '.sha // ""' 2>/dev/null || true)
  _rph_branch_name=$(echo "$_rph_pr_head_ref" | jq -r '.name // ""' 2>/dev/null || true)

  if [ -n "${_rph_remote_sha:-}" ]; then
    # Remote API is authoritative — use it regardless of cwd.
    echo "$_rph_remote_sha"
    return 0
  fi

  # Step 2: API call failed — fall back to local git with branch-name guard.
  local _rph_local_branch=""

  if [ -n "$worktree_path" ] && [ -d "$worktree_path" ]; then
    # Worktree path provided — use it for the git context (safest)
    _rph_local_branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ -n "$_rph_branch_name" ] && [ "${_rph_local_branch:-}" = "$_rph_branch_name" ]; then
      _rph_head_sha=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null || true)
    elif [ -z "$_rph_branch_name" ]; then
      # Branch name unknown (partial API failure) — fall back with a warning.
      # Redirect to stderr: this function outputs the SHA on stdout, so all
      # diagnostic messages must go to stderr to keep the output pipe-clean.
      print_warning "Could not verify PR branch name — falling back to local git HEAD (worktree: $worktree_path)" >&2
      _rph_head_sha=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null || true)
    fi
  else
    # No worktree path — fall back to cwd-relative git with branch-name guard.
    _rph_local_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ -n "$_rph_branch_name" ] && [ "${_rph_local_branch:-}" = "$_rph_branch_name" ]; then
      _rph_head_sha=$(git rev-parse HEAD 2>/dev/null || true)
    elif git rev-parse --git-dir >/dev/null 2>&1 && [ -z "$_rph_branch_name" ]; then
      # Branch name unknown (partial API failure) — fall back with a warning.
      print_warning "Could not verify PR branch name — falling back to local git HEAD" >&2
      _rph_head_sha=$(git rev-parse HEAD 2>/dev/null || true)
    fi
  fi

  echo "${_rph_head_sha:-}"
}

# Export functions
export -f trigger_local_review
export -f get_review_for_pr
export -f handle_stale_review
export -f extract_review_sha
export -f resolve_pr_head_sha
