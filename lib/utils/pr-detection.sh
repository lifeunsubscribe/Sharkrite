#!/bin/bash
# pr-detection.sh
# Shared utilities for detecting PRs, worktrees, and review state.
# Used by standalone phase commands (--review-latest, --assess-and-fix)
# and the orchestrator (workflow-runner.sh).
#
# All functions set variables in the caller's scope (no subshell).
# Return 0 on success, 1 on failure.

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

# detect_pr_for_issue ISSUE_NUMBER
#
# Finds the open PR linked to a GitHub issue.
# Sets: PR_NUMBER, PR_BRANCH
# Returns: 0 if found, 1 if not
detect_pr_for_issue() {
  local issue_number="$1"
  PR_NUMBER=""
  PR_BRANCH=""

  # Method 1: Search by issue link in PR body (Closes #N, Fixes #N, etc.)
  PR_NUMBER=$(gh pr list --state open --json number,body --limit 100 2>/dev/null | \
    jq --arg issue "$issue_number" -r \
    '.[] | select(.body | test("(Closes|closes|Fixes|fixes|Resolves|resolves) #" + $issue + "\\b")) | .number' | \
    head -1)

  # Method 2: Search by title fallback (issue number in PR title)
  if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
    PR_NUMBER=$(gh pr list --state open --search "#${issue_number}" --json number --jq '.[0].number' 2>/dev/null || echo "")
  fi

  if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
    return 1
  fi

  # Get the branch name for this PR
  PR_BRANCH=$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")

  return 0
}

# detect_pr_for_current_branch
#
# Finds the open PR for the current git branch.
# Sets: PR_NUMBER
# Returns: 0 if found, 1 if not
detect_pr_for_current_branch() {
  PR_NUMBER=""

  local branch_name
  branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  if [ -z "$branch_name" ] || [ "$branch_name" = "HEAD" ]; then
    return 1
  fi

  PR_NUMBER=$(gh pr list --head "$branch_name" --json number --jq '.[0].number' 2>/dev/null || echo "")

  if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
    return 1
  fi

  return 0
}

# detect_worktree_for_pr PR_NUMBER
#
# Finds the local worktree for a PR's branch.
# Sets: WORKTREE_PATH
# Returns: 0 if found, 1 if not
detect_worktree_for_pr() {
  local pr_number="$1"
  WORKTREE_PATH=""

  local pr_branch
  pr_branch=$(gh pr view "$pr_number" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")

  if [ -z "$pr_branch" ]; then
    return 1
  fi

  WORKTREE_PATH=$(git worktree list | grep "\[$pr_branch\]" | awk '{print $1}')

  if [ -z "$WORKTREE_PATH" ] || [ ! -d "$WORKTREE_PATH" ]; then
    WORKTREE_PATH=""
    return 1
  fi

  return 0
}

# get_latest_work_commit_time [WORKTREE_PATH] [PR_NUMBER]
#
# Gets the latest non-merge work commit time in UTC ISO 8601 format.
# Prefers local git (always up-to-date after push, no eventual consistency).
# Falls back to GitHub API when no worktree available.
# Filters out mainline sync merge commits (e.g., GitHub "Update branch" button).
#
# CRITICAL: Uses --date=format-local: (NOT --date=format:) with TZ=UTC.
# --date=format: ignores TZ and outputs local time with a fake Z suffix.
# --date=format-local: respects TZ=UTC and outputs true UTC.
#
# Sets: LATEST_COMMIT_TIME (e.g., "2026-02-18T02:45:23Z", or "" if none found)
# Returns: 0 always
get_latest_work_commit_time() {
  local worktree_path="${1:-.}"
  local pr_number="${2:-}"

  LATEST_COMMIT_TIME=""

  # Try local git first (always up-to-date, no GitHub API eventual consistency)
  if [ -n "$worktree_path" ] && [ -d "$worktree_path" ] && \
     git -C "$worktree_path" rev-parse --git-dir >/dev/null 2>&1; then
    LATEST_COMMIT_TIME=$(TZ=UTC git -C "$worktree_path" log -1 \
      --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format='%cd' \
      --grep="^Merge branch.*\(main\|master\|develop\)" \
      --grep="^Merge pull request.*from.*/main" \
      --invert-grep HEAD 2>/dev/null || echo "")
  fi

  # Fall back to GitHub API if local git unavailable or returned empty
  if [ -z "$LATEST_COMMIT_TIME" ] && [ -n "$pr_number" ]; then
    LATEST_COMMIT_TIME=$(gh pr view "$pr_number" --json commits --jq '
      [.commits[] | select(
        .messageHeadline | test("^Merge (branch .*(main|master|develop).|pull request .* from .*/main)") | not
      )][-1].committedDate // ""
    ' 2>/dev/null || echo "")
  fi

  return 0
}

# detect_review_state PR_NUMBER [WORKTREE_PATH]
#
# Checks the review state for a PR: whether a review exists and if it's current.
# Uses local git commit timestamps when WORKTREE_PATH is provided (avoids
# GitHub API eventual consistency issues — see workflow-runner.sh comments).
# Falls back to GitHub API timestamps otherwise.
#
# Sets:
#   HAS_REVIEW        - "true" or "false"
#   REVIEW_IS_CURRENT - "true" or "false"
#   REVIEW_BODY       - full review body text (empty if no review)
#   REVIEW_TIME       - ISO timestamp of latest review
# Returns: 0 always
detect_review_state() {
  local pr_number="$1"
  local worktree_path="${2:-}"

  HAS_REVIEW="false"
  REVIEW_IS_CURRENT="false"
  REVIEW_BODY=""
  REVIEW_TIME=""

  # Fetch latest review comment (sharkrite-local-review marker only)
  local review_json
  review_json=$(gh pr view "$pr_number" --json comments --jq '
    [.comments[] | select(
      .body | contains("<!-- sharkrite-local-review")
    )] | sort_by(.createdAt) | reverse | .[0] // {}
  ' 2>/dev/null || echo "{}")

  REVIEW_BODY=$(echo "$review_json" | jq -r '.body // ""' 2>/dev/null)
  REVIEW_TIME=$(echo "$review_json" | jq -r '.createdAt // ""' 2>/dev/null)

  if [ -z "$REVIEW_BODY" ] || [ "$REVIEW_BODY" = "null" ]; then
    REVIEW_BODY=""
    return 0
  fi

  HAS_REVIEW="true"

  # Determine latest work commit time
  local latest_commit_time=""

  if [ -n "$worktree_path" ] && [ -d "$worktree_path" ]; then
    # Use LOCAL git timestamps (avoids GitHub API eventual consistency).
    # Check for unpushed commits first — if local differs from remote,
    # the review can't be current.
    local local_head remote_head branch_name
    branch_name=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    local_head=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null || echo "")
    remote_head=$(git -C "$worktree_path" rev-parse "origin/$branch_name" 2>/dev/null || echo "")

    if [ "$local_head" != "$remote_head" ]; then
      # Unpushed commits — review is stale
      REVIEW_IS_CURRENT="false"
      return 0
    fi

    # Get latest non-merge commit time (shared function handles local vs API)
    get_latest_work_commit_time "$worktree_path" "$pr_number"
    latest_commit_time="$LATEST_COMMIT_TIME"
  else
    # No worktree — shared function falls back to GitHub API
    get_latest_work_commit_time "" "$pr_number"
    latest_commit_time="$LATEST_COMMIT_TIME"
  fi

  # Compare timestamps using epoch seconds (handles mixed timezone formats)
  if [ -n "$REVIEW_TIME" ] && [ -n "$latest_commit_time" ]; then
    local commit_epoch review_epoch
    if date --version >/dev/null 2>&1; then
      # GNU date (Linux)
      commit_epoch=$(date -d "$latest_commit_time" "+%s" 2>/dev/null || echo "0")
      review_epoch=$(date -d "$REVIEW_TIME" "+%s" 2>/dev/null || echo "0")
    else
      # BSD date (macOS) — timestamps are UTC format (ending in Z)
      commit_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$latest_commit_time" "+%s" 2>/dev/null || echo "0")
      review_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$REVIEW_TIME" "+%s" 2>/dev/null || echo "0")
    fi
    if [ "$review_epoch" -gt "$commit_epoch" ]; then
      REVIEW_IS_CURRENT="true"
    fi
  elif [ -n "$REVIEW_TIME" ] && [ -z "$latest_commit_time" ]; then
    # Review exists but no commits found — treat as current
    REVIEW_IS_CURRENT="true"
  fi

  return 0
}
