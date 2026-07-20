#!/bin/bash
# pr-detection.sh
# Shared utilities for detecting PRs, worktrees, and review state.
# Used by standalone phase commands (--review-latest, --assess-and-fix)
# and the orchestrator (workflow-runner.sh).
#
# All functions set variables in the caller's scope (no subshell).
# Return 0 on success, 1 on failure.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f detect_pr_for_issue >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

source "$RITE_LIB_DIR/utils/date-helpers.sh"
source "$RITE_LIB_DIR/utils/gh-retry.sh"
# Source markers.sh relative to this file's location (lib/utils/) so that
# test environments where RITE_LIB_DIR points to the install copy also work.
_pr_detection_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_pr_detection_dir/markers.sh"

# ---------------------------------------------------------------------------
# Closing-issue regex constants
#
# CLOSING_ISSUE_JQ_REGEX — prefix for jq test() expressions.
#   Usage: test($closing_re + $issue + "\\b")
#   Pass via --arg: jq --arg closing_re "$CLOSING_ISSUE_JQ_REGEX" ...
#
# CLOSING_ISSUE_GREP_REGEX — full pattern for grep -oE extraction.
#   Usage: grep -oE "$CLOSING_ISSUE_GREP_REGEX"
#
# Both cover all GitHub closing-keyword variants (case-insensitive alternation)
# defined at: https://docs.github.com/en/issues/tracking-your-work-with-issues/linking-a-pull-request-to-an-issue
# ---------------------------------------------------------------------------
CLOSING_ISSUE_JQ_REGEX='(Closes|closes|Fixes|fixes|Resolves|resolves) #'
CLOSING_ISSUE_GREP_REGEX='(Closes|closes|Fixes|fixes|Resolves|resolves) #[0-9]+'

# detect_pr_for_issue ISSUE_NUMBER
#
# Finds the open PR linked to a GitHub issue.
# Sets: PR_NUMBER, PR_BRANCH, PR_BASE_BRANCH
# Returns: 0 if found, 1 if not
detect_pr_for_issue() {
  local issue_number="$1"
  PR_NUMBER=""
  PR_BRANCH=""
  PR_BASE_BRANCH=""

  # Method 1: Search by issue link in PR body (Closes #N, Fixes #N, etc.)
  # Use sort_by(.number) | last instead of head -1 so the result is deterministic
  # when multiple open PRs reference the same issue (e.g., after rite undo + retry).
  # Highest PR number = most recently created; all results are already --state open.
  PR_NUMBER=$(gh_safe pr list --state open --json number,body --limit 100 | \
    jq --arg issue "$issue_number" --arg closing_re "$CLOSING_ISSUE_JQ_REGEX" -r \
    '[.[] | select(.body | test($closing_re + $issue + "\\b"))] | sort_by(.number) | last | .number // empty' || true)

  # Method 2: Search by title fallback — match "#N" in PR title only.
  # Previous approach used --search "#N" which is a GitHub full-text search that
  # matches ANY mention of #N in title OR body, causing false positives when
  # unrelated PRs reference the issue (e.g., "Follow-up from #31").
  if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
    PR_NUMBER=$(gh_safe pr list --state open --json number,title --limit 100 | \
      jq --arg issue "$issue_number" -r \
      '[.[] | select(.title | test("#" + $issue + "\\b"))] | sort_by(.number) | last | .number // empty' || true)
  fi

  if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
    return 1
  fi

  # Get the head and base branch names for this PR in a single API call.
  # PR_BASE_BRANCH is used by run_workflow()'s branch-mismatch guard (#1044)
  # to detect when PR.baseRefName != the effective target branch.
  local _pr_json
  _pr_json=$(gh_safe pr view "$PR_NUMBER" --json headRefName,baseRefName)
  PR_BRANCH=$(echo "$_pr_json" | jq -r '.headRefName // ""' || true)
  PR_BASE_BRANCH=$(echo "$_pr_json" | jq -r '.baseRefName // ""' || true)

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

  # `// empty` prevents jq from outputting literal "null" when no PR exists for the branch.
  PR_NUMBER=$(gh_safe pr list --head "$branch_name" --json number --jq '.[0].number // empty')
  [ "$PR_NUMBER" = "null" ] && PR_NUMBER=""

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
  pr_branch=$(gh_safe pr view "$pr_number" --json headRefName --jq '.headRefName')

  if [ -z "$pr_branch" ]; then
    return 1
  fi

  WORKTREE_PATH=$(git worktree list | grep "\[$pr_branch\]" | awk '{print $1}' || true)

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
    LATEST_COMMIT_TIME=$(gh_safe pr view "$pr_number" --json commits --jq '
      [.commits[] | select(
        .messageHeadline | test("^Merge (branch .*(main|master|develop).|pull request .* from .*/main)") | not
      )][-1].committedDate // ""
    ')
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
  local review_json _jq_review_filter
  _jq_review_filter="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | sort_by(.createdAt) | reverse | .[0] // {}"
  # || true: when gh_safe exhausts its retries it returns non-zero, and a bare
  # $() under set -e kills the caller (rite --status / --review-latest /
  # --assess-and-fix die silently mid-command). Degrade to the {} fallback —
  # "no review found" — instead. Every peer call in this file already does this.
  review_json=$(gh_safe pr view "$pr_number" --json comments --jq "$_jq_review_filter" || true)
  review_json="${review_json:-"{}"}"

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
    commit_epoch=$(iso_to_epoch "$latest_commit_time")
    review_epoch=$(iso_to_epoch "$REVIEW_TIME")
    if [ "$review_epoch" -gt "$commit_epoch" ]; then
      REVIEW_IS_CURRENT="true"
    fi
  elif [ -n "$REVIEW_TIME" ] && [ -z "$latest_commit_time" ]; then
    # Review exists but no commits found — treat as current
    REVIEW_IS_CURRENT="true"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# detect_parent_pr_attachment ISSUE_BODY
#
# Single resolver for the parent-PR attachment contract.
# Reads the sharkrite-parent-pr:N marker from ISSUE_BODY and queries GitHub
# for the parent PR's state. Sets caller-scope variables encoding the contract:
#
#   PARENT_PR_NUMBER  — parent PR number (or "" if no marker)
#   PARENT_PR_STATE   — "OPEN", "MERGED", "CLOSED", or "" if no marker
#   PARENT_PR_BRANCH  — head branch of the parent PR (or "")
#   PARENT_ATTACHMENT_MODE — "adopt" | "ignore" | "none"
#     adopt  = parent PR is OPEN → orchestrator must use parent PR/worktree
#     ignore = parent PR is MERGED or CLOSED → run fresh branch from main
#     none   = no parent-pr marker in issue body
#
# Contract arms:
#   adopt:  follow-up's dev session, review, and assessment target the parent
#           PR end-to-end. The orchestrator adopts PR_NUMBER/WORKTREE_PATH from
#           the parent so no phase performs issue-number-derived discovery.
#   ignore: the marker is preserved for traceability but the attachment is
#           skipped; the follow-up runs fresh on a new branch from main.
#
# CRITICAL: The outer guard requires digits — otherwise issue bodies that
# DOCUMENT the marker format (e.g. "sharkrite-parent-pr:N" as a placeholder)
# match and the inner extraction returns empty, killing the script silently
# under set -e + pipefail. Same bug class fixed in commit 206f2be.
# See CLAUDE.md — "Unanchored marker grep (bare-prefix guard)".
#
# Returns: 0 always (sets PARENT_ATTACHMENT_MODE="none" on error/no-match)
# ---------------------------------------------------------------------------
detect_parent_pr_attachment() {
  local issue_body="$1"

  PARENT_PR_NUMBER=""
  PARENT_PR_STATE=""
  PARENT_PR_BRANCH=""
  PARENT_ATTACHMENT_MODE="none"

  # Outer guard requires digits — rejects all placeholder/documentation text.
  if ! echo "$issue_body" | grep -qE "${RITE_MARKER_PARENT_PR}:[0-9]+"; then
    return 0
  fi

  # Extract parent PR number (safe: outer guard already verified digit presence).
  PARENT_PR_NUMBER=$(echo "$issue_body" | grep -oE "${RITE_MARKER_PARENT_PR}:[0-9]+" | cut -d: -f2 || true)
  PARENT_PR_NUMBER="${PARENT_PR_NUMBER:-}"

  if [ -z "$PARENT_PR_NUMBER" ]; then
    return 0
  fi

  # Query parent PR state and head branch in one call.
  local _parent_pr_json
  _parent_pr_json=$(gh_safe pr view "$PARENT_PR_NUMBER" --json state,headRefName 2>/dev/null || true)
  _parent_pr_json="${_parent_pr_json:-}"

  if [ -z "$_parent_pr_json" ] || [ "$_parent_pr_json" = "null" ]; then
    # GitHub API unavailable or PR not found — treat as ignore (safe: run fresh).
    PARENT_ATTACHMENT_MODE="ignore"
    return 0
  fi

  PARENT_PR_STATE=$(echo "$_parent_pr_json" | jq -r '.state // ""' 2>/dev/null || true)
  PARENT_PR_BRANCH=$(echo "$_parent_pr_json" | jq -r '.headRefName // ""' 2>/dev/null || true)
  PARENT_PR_STATE="${PARENT_PR_STATE:-}"
  PARENT_PR_BRANCH="${PARENT_PR_BRANCH:-}"

  if [ "$PARENT_PR_STATE" = "OPEN" ]; then
    PARENT_ATTACHMENT_MODE="adopt"
  else
    # MERGED or CLOSED: ignore attachment, run fresh.
    PARENT_ATTACHMENT_MODE="ignore"
  fi

  return 0
}
