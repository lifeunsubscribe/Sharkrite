#!/bin/bash
# lib/utils/git-helpers.sh
# Shared git utilities for sharkrite workflows
#
# Provides safe wrappers around git operations that can fail silently
# under set -euo pipefail.

# Re-source guard: skip if already loaded (git_fetch_safe is the canonical indicator)
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
