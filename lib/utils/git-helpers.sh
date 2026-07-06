#!/bin/bash
# lib/utils/git-helpers.sh
# Shared git utilities for sharkrite workflows
#
# Provides safe wrappers around git operations that can fail silently
# under set -euo pipefail.

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f git_fetch_safe >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source colors for print_* functions if not already available
if ! declare -f print_error >/dev/null 2>&1; then
  _GH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$_GH_SCRIPT_DIR/colors.sh"
fi

# git_fetch_safe <remote> <ref> [worktree_path]
#
# Fetches a remote ref with 3 retries and exponential backoff.
# Fails loudly (exit 1 + remediation message) if all retries are exhausted.
#
# Unlike bare `git fetch ... 2>/dev/null || true`, this ensures callers
# never silently read stale remote state on network failure.
#
# Arguments:
#   remote        - The remote name (e.g. "origin")
#   ref           - The ref to fetch (e.g. "main" or "$BRANCH_NAME")
#   worktree_path - Optional: working directory for the git command
#                   (defaults to current directory)
#
# Returns:
#   0 on success (fetch succeeded within retry budget)
#   1 on failure (all retries exhausted — caller should abort or handle)
#
# Example:
#   git_fetch_safe origin main || { print_error "Cannot proceed without fresh main ref"; exit 1; }
#   git_fetch_safe origin "$BRANCH_NAME" || true  # best-effort only (explain why in comment)

# rmdir_empty_worktree_container <wt_path> <rite_worktree_dir>
#
# Removes a just-removed worktree directory when it is now empty (residue
# cleanup) AND is a direct child of RITE_WORKTREE_DIR.
#
# Production worktrees are flat: $RITE_WORKTREE_DIR/<branch-slug>.
# After `git worktree remove`, git deletes the .git file but may leave the
# directory if residue files remain (scratchpads, build artifacts). This
# function attempts an rmdir of the worktree dir itself — rmdir is a no-op
# when the directory is non-empty, so it is always safe to call.
#
# The "/*" anchor in the case pattern is critical: without it a bare prefix
# match would fire for sibling directories (e.g. "sh-wt-archive" would match
# a base of "sh-wt"), potentially deleting dirs that belong to other repos.
# The anchor requires a directory separator after the base, so only immediate
# children of RITE_WORKTREE_DIR are candidates.  RITE_WORKTREE_DIR itself is
# also excluded by this anchor, so the caller can safely pass the worktree
# path without risk of accidentally removing the container root.
#
# Arguments:
#   wt_path           - Path of the removed worktree (direct child of
#                       RITE_WORKTREE_DIR, e.g. "$RITE_WORKTREE_DIR/fx-foo")
#   rite_worktree_dir - RITE_WORKTREE_DIR value for this repo (trailing slash
#                       is stripped automatically)
#
# Returns: always 0 (rmdir failure is silently ignored — non-empty or
#          already-gone directories are both fine outcomes)
rmdir_empty_worktree_container() {
  local _wt_path="${1:-}"
  local _rite_wt_dir="${2:-}"
  [ -n "$_wt_path" ] && [ -n "$_rite_wt_dir" ] || return 0
  _rite_wt_dir="${_rite_wt_dir%/}"   # strip trailing slash — prevents ".../base//*" mismatch
  case "$_wt_path" in "$_rite_wt_dir"/*)
    rmdir "$_wt_path" 2>/dev/null || true ;;
  esac
}

git_fetch_safe() {
  local remote="${1:?git_fetch_safe: remote argument required}"
  local ref="${2:?git_fetch_safe: ref argument required}"
  local worktree_path="${3:-}"

  local max_attempts=3
  local attempt=1
  local wait_secs=1

  while [ "$attempt" -le "$max_attempts" ]; do
    if [ -n "$worktree_path" ]; then
      if git -C "$worktree_path" fetch "$remote" "$ref" 2>/dev/null; then
        return 0
      fi
    else
      if git fetch "$remote" "$ref" 2>/dev/null; then
        return 0
      fi
    fi

    if [ "$attempt" -lt "$max_attempts" ]; then
      print_warning "git fetch $remote $ref failed (attempt $attempt/$max_attempts) — retrying in ${wait_secs}s"
      sleep "$wait_secs"
      wait_secs=$((wait_secs * 2))
    fi

    attempt=$((attempt + 1))
  done

  print_error "git fetch $remote $ref failed after $max_attempts attempts"
  print_info "Remediation: check network connectivity, VPN, or SSH key access to the remote"
  return 1
}
