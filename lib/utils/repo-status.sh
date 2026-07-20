#!/bin/bash
# lib/utils/repo-status.sh - Repo-wide status display
# Shows worktrees, open issues with workflow phases, and recently closed issues.
# No bash 4+ requirement — uses indexed arrays only.
#
# Usage: source this file, then call repo_wide_status [--by-label]

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f repo_wide_status >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config and dependencies if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_SCRIPT_DIR/config.sh"
fi
source "$RITE_LIB_DIR/utils/colors.sh"
source "$RITE_LIB_DIR/utils/date-helpers.sh"
source "$RITE_LIB_DIR/utils/pr-detection.sh"
source "$RITE_LIB_DIR/utils/issue-lock.sh"
# Source markers.sh relative to this file's location (lib/utils/) so that
# test environments where RITE_LIB_DIR points to the install copy also work.
_repo_status_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_repo_status_dir/markers.sh"
# Source integration-ledger.sh if available (provides integration_ledger_entries).
# Guard with declare -f so repeated sources are a no-op (the file has its own guard too).
if ! declare -f integration_ledger_entries >/dev/null 2>&1; then
  if [ -f "$_repo_status_dir/integration-ledger.sh" ]; then
    source "$_repo_status_dir/integration-ledger.sh"
  fi
fi

# =============================================================================
# Shared helpers
# =============================================================================

# behind_main_count <git_C_path> <local_ref>
#
# Returns (via stdout) the number of commits origin/main is ahead of <local_ref>
# via common ancestor computation.  Uses local refs only — no fetch.
# Outputs "0" when the common ancestor cannot be computed (detached HEAD, no origin/main).
#
# Single authoritative copy of the behind-main math; replaces the two former
# inline copies in scan_worktrees() — exactly one git ancestor-check call in this file.
behind_main_count() {
  local git_path="$1"
  local ref="$2"
  local _mb
  _mb=$(git -C "$git_path" merge-base "$ref" origin/main 2>/dev/null || echo "")
  if [ -n "$_mb" ]; then
    git -C "$git_path" rev-list --count "${_mb}..origin/main" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# =============================================================================
# Worktree scanning
# =============================================================================

# Scan worktrees under RITE_WORKTREE_DIR.
# Sets: WORKTREE_COUNT, STALE_WORKTREE_COUNT
# Populates: WT_BRANCHES[], WT_STATUSES[], WT_AGES[], WT_PATHS[], WT_BEHIND_MAIN[]
WT_BRANCHES=()
WT_STATUSES=()
WT_AGES=()
WT_PATHS=()
WT_BEHIND_MAIN=()
WORKTREE_COUNT=0
STALE_WORKTREE_COUNT=0

scan_worktrees() {
  local worktree_lines
  worktree_lines=$(git worktree list --porcelain 2>/dev/null || echo "")

  local current_path=""
  local current_branch=""

  while IFS= read -r line; do
    if [[ "$line" =~ ^worktree\ (.+) ]]; then
      current_path="${BASH_REMATCH[1]}"
      current_branch=""
    elif [[ "$line" =~ ^branch\ refs/heads/(.+) ]]; then
      current_branch="${BASH_REMATCH[1]}"
    elif [ -z "$line" ] && [ -n "$current_path" ]; then
      # End of worktree block — process any worktree except the main repo
      if [ "$current_path" != "$RITE_PROJECT_ROOT" ] && [ -d "$current_path" ]; then
        WORKTREE_COUNT=$((WORKTREE_COUNT + 1))

        local branch="${current_branch:-unknown}"

        # Uncommitted changes (exclude untracked)
        local uncommitted
        uncommitted=$(git -C "$current_path" status --porcelain 2>/dev/null | grep -cvE "^\?\?" || true)

        # Unpushed commits
        local unpushed=0
        local remote_exists
        remote_exists=$(git -C "$current_path" rev-parse "origin/$branch" 2>/dev/null || echo "")
        if [ -n "$remote_exists" ]; then
          unpushed=$(git -C "$current_path" log --oneline "origin/$branch..HEAD" 2>/dev/null | wc -l | tr -d ' ' || true)
        fi

        # Staleness: last commit age
        local last_commit_epoch
        last_commit_epoch=$(git -C "$current_path" log -1 --format='%ct' 2>/dev/null || echo "0")
        local now_epoch
        now_epoch=$(date +%s)
        local age_hours=$(( (now_epoch - last_commit_epoch) / 3600 ))
        local age_display
        if [ "$age_hours" -ge 48 ]; then
          age_display="$((age_hours / 24))d old"
        elif [ "$age_hours" -ge 1 ]; then
          age_display="${age_hours}h old"
        else
          age_display="<1h old"
        fi

        # 7 days = stale
        if [ "$age_hours" -gt 168 ]; then
          STALE_WORKTREE_COUNT=$((STALE_WORKTREE_COUNT + 1))
          age_display="${age_display} (stale)"
        fi

        # Build status string
        local status_parts=""
        if [ "$uncommitted" -gt 0 ]; then
          status_parts="${uncommitted} uncommitted"
        fi
        if [ "$unpushed" -gt 0 ]; then
          [ -n "$status_parts" ] && status_parts="${status_parts}, "
          status_parts="${status_parts}${unpushed} unpushed"
        fi
        if [ -z "$status_parts" ]; then
          status_parts="clean"
        fi

        # Commits behind main (uses local origin/main ref, no fetch)
        local behind_main
        behind_main=$(behind_main_count "$current_path" HEAD)

        WT_BRANCHES+=("$branch")
        WT_STATUSES+=("$status_parts")
        WT_AGES+=("$age_display")
        WT_PATHS+=("$current_path")
        WT_BEHIND_MAIN+=("$behind_main")
      fi
      current_path=""
      current_branch=""
    fi
  done <<< "$worktree_lines"

  # Handle last entry if file doesn't end with blank line
  if [ -n "$current_path" ] && [ "$current_path" != "$RITE_PROJECT_ROOT" ] && [ -d "$current_path" ]; then
    WORKTREE_COUNT=$((WORKTREE_COUNT + 1))
    local branch="${current_branch:-unknown}"
    local uncommitted
    uncommitted=$(git -C "$current_path" status --porcelain 2>/dev/null | grep -cvE "^\?\?" || true)
    local unpushed=0
    local remote_exists
    remote_exists=$(git -C "$current_path" rev-parse "origin/$branch" 2>/dev/null || echo "")
    if [ -n "$remote_exists" ]; then
      unpushed=$(git -C "$current_path" log --oneline "origin/$branch..HEAD" 2>/dev/null | wc -l | tr -d ' ' || true)
    fi
    local last_commit_epoch
    last_commit_epoch=$(git -C "$current_path" log -1 --format='%ct' 2>/dev/null || echo "0")
    local now_epoch
    now_epoch=$(date +%s)
    local age_hours=$(( (now_epoch - last_commit_epoch) / 3600 ))
    local age_display
    if [ "$age_hours" -ge 48 ]; then
      age_display="$((age_hours / 24))d old"
    elif [ "$age_hours" -ge 1 ]; then
      age_display="${age_hours}h old"
    else
      age_display="<1h old"
    fi
    if [ "$age_hours" -gt 168 ]; then
      STALE_WORKTREE_COUNT=$((STALE_WORKTREE_COUNT + 1))
      age_display="${age_display} (stale)"
    fi
    local status_parts=""
    if [ "$uncommitted" -gt 0 ]; then
      status_parts="${uncommitted} uncommitted"
    fi
    if [ "$unpushed" -gt 0 ]; then
      [ -n "$status_parts" ] && status_parts="${status_parts}, "
      status_parts="${status_parts}${unpushed} unpushed"
    fi
    if [ -z "$status_parts" ]; then
      status_parts="clean"
    fi
    local behind_main
    behind_main=$(behind_main_count "$current_path" HEAD)

    WT_BRANCHES+=("$branch")
    WT_STATUSES+=("$status_parts")
    WT_AGES+=("$age_display")
    WT_PATHS+=("$current_path")
    WT_BEHIND_MAIN+=("$behind_main")
  fi
}

# =============================================================================
# Phase detection
# =============================================================================

# get_issue_phase ISSUE_NUMBER PR_JSON ALL_PR_COMMENTS_JSON
# Determines the workflow phase for an open issue.
# PR_JSON is the matched PR's JSON (number, body, headRefName) or empty.
# ALL_PR_COMMENTS_JSON is pre-fetched comments for the PR (or empty).
#
# Sets: ISSUE_PHASE (short label for display), ISSUE_PR_NUMBER (or empty)
get_issue_phase() {
  local issue_num="$1"
  local pr_json="$2"
  local pr_comments_json="$3"

  ISSUE_PHASE="Not started"
  ISSUE_PR_NUMBER=""

  if [ -z "$pr_json" ]; then
    return 0
  fi

  local pr_number
  pr_number=$(echo "$pr_json" | jq -r '.number')

  if [ -z "$pr_number" ] || [ "$pr_number" = "null" ]; then
    return 0
  fi

  ISSUE_PR_NUMBER="$pr_number"

  # Has a PR — at least Dev/PR phase
  ISSUE_PHASE="Dev/PR"

  # Check review state from pre-fetched comments
  local review_body=""
  local review_time=""
  if [ -n "$pr_comments_json" ]; then
    local _jq_review_body_f _jq_review_time_f
    _jq_review_body_f="[.[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | sort_by(.createdAt) | reverse | .[0].body // \"\""
    _jq_review_time_f="[.[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | sort_by(.createdAt) | reverse | .[0].createdAt // \"\""
    review_body=$(echo "$pr_comments_json" | jq -r "$_jq_review_body_f" 2>/dev/null || echo "")
    review_time=$(echo "$pr_comments_json" | jq -r "$_jq_review_time_f" 2>/dev/null || echo "")
  fi

  if [ -z "$review_body" ] || [ "$review_body" = "null" ]; then
    ISSUE_PHASE="Needs review"
    return 0
  fi

  # Count review iterations
  local review_count=1
  if [ -n "$pr_comments_json" ]; then
    local _jq_review_count_f
    _jq_review_count_f="[.[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | length"
    review_count=$(echo "$pr_comments_json" | jq "$_jq_review_count_f" 2>/dev/null || echo "1")
    [ -z "$review_count" ] || [ "$review_count" = "0" ] && review_count=1
  fi

  # Check if review is current by comparing to latest commit
  # Use the PR branch to find worktree (if any) for local timestamps
  local pr_branch
  pr_branch=$(echo "$pr_json" | jq -r '.headRefName // ""' || true)
  local wt_path=""
  if [ -n "$pr_branch" ]; then
    wt_path=$(git worktree list 2>/dev/null | grep "\[$pr_branch\]" | awk '{print $1}' || echo "")
  fi

  # Get latest commit time
  get_latest_work_commit_time "${wt_path:-}" "$pr_number"
  local latest_commit_time="$LATEST_COMMIT_TIME"

  # Compare timestamps
  local review_is_current="false"
  if [ -n "$review_time" ] && [ "$review_time" != "null" ] && [ -n "$latest_commit_time" ]; then
    local commit_epoch review_epoch
    commit_epoch=$(iso_to_epoch "$latest_commit_time")
    review_epoch=$(iso_to_epoch "$review_time")
    if [ "$review_epoch" -gt "$commit_epoch" ]; then
      review_is_current="true"
    fi
  elif [ -n "$review_time" ] && [ "$review_time" != "null" ] && [ -z "$latest_commit_time" ]; then
    review_is_current="true"
  fi

  if [ "$review_is_current" != "true" ]; then
    ISSUE_PHASE="Review stale"
    return 0
  fi

  # Check assessment from comments
  local assess_body=""
  if [ -n "$pr_comments_json" ]; then
    local _jq_assess_body_f
    _jq_assess_body_f="[.[] | select(.body | contains(\"<!-- ${RITE_MARKER_ASSESSMENT}\"))] | sort_by(.createdAt) | reverse | .[0].body // \"\""
    assess_body=$(echo "$pr_comments_json" | jq -r "$_jq_assess_body_f" 2>/dev/null || echo "")
  fi

  if [ -z "$assess_body" ] || [ "$assess_body" = "null" ]; then
    ISSUE_PHASE="Needs assessment"
    return 0
  fi

  local now_ct
  now_ct=$(echo "$assess_body" | grep -c "^### .* - ACTIONABLE_NOW" || true)

  if [ "$now_ct" -gt 0 ]; then
    ISSUE_PHASE="Needs fixes(${now_ct}) r${review_count}"
  else
    ISSUE_PHASE="Ready to merge"
  fi
}

# =============================================================================
# Formatting helpers
# =============================================================================

# Truncate string to max length, append ellipsis if needed
truncate_str() {
  local str="$1"
  local max="$2"
  if [ ${#str} -gt "$max" ]; then
    echo "${str:0:$((max - 1))}…"
  else
    echo "$str"
  fi
}

# Right-pad string to fixed width.
# With LC_CTYPE=C (common on macOS), ${#str} and printf both count bytes.
# The ellipsis character … is 3 bytes but 1 display column, so strings
# containing it come up 2 columns short. Detect and compensate.
pad_str() {
  local str="$1" width="$2"
  local len=${#str}
  local correction=0
  case "$str" in *"…"*) correction=2 ;; esac
  local pad=$(( width - len + correction ))
  if [ "$pad" -le 0 ]; then
    printf '%s' "$str"
  else
    printf '%s%*s' "$str" "$pad" ""
  fi
}

# Format issue number as OSC 8 terminal hyperlink, right-padded.
# Returns escape sequences for echo -e. Falls back to plain text if no URL.
# Usage: _issue_link ISSUE_NUMBER PAD_WIDTH REPO_URL
_issue_link() {
  local num="$1" width="$2" url="$3"
  local text="#${num}"
  local pad_len=$((width - ${#text}))
  local padding=""
  [ "$pad_len" -gt 0 ] && padding=$(printf "%${pad_len}s" "")
  if [ -n "$url" ]; then
    printf '%s' "\\033]8;;${url}/issues/${num}\\a${text}\\033]8;;\\a${padding}"
  else
    printf '%s' "${text}${padding}"
  fi
}

# Format PR number as dim OSC 8 terminal hyperlink.
# Usage: _pr_link PR_NUMBER REPO_URL [MIN_WIDTH]
# When MIN_WIDTH is set, right-pads with trailing spaces so the labels column
# starts at a predictable position regardless of PR-number digit count.
_pr_link() {
  local num="$1" url="$2" min_width="${3:-0}"
  local text="PR#${num}"
  local pad_len=$((min_width - ${#text}))
  local padding=""
  [ "$pad_len" -gt 0 ] && padding=$(printf "%${pad_len}s" "")
  if [ -n "$url" ]; then
    printf '%s' "\\033[2m\\033]8;;${url}/pull/${num}\\a${text}\\033]8;;\\a\\033[0m${padding}"
  else
    printf '%s' "\\033[2m${text}\\033[0m${padding}"
  fi
}

# Strip a "[label] " prefix from an issue title when the bracket content
# matches one of the issue's labels — otherwise the labels column
# duplicates info already visible in the title.
#
# Matching is case-insensitive and only triggers when the title starts
# with "[<word>] " (one bracketed token followed by whitespace + body).
# Bare prefixes that don't match a label are left alone.
#
# Usage: strip_label_prefix_from_title TITLE LABELS_CSV
#   TITLE       — raw GitHub issue title
#   LABELS_CSV  — comma-separated label list (the same string used in display)
strip_label_prefix_from_title() {
  local title="$1"
  local labels_csv="$2"
  if ! [[ "$title" =~ ^\[([^]]+)\][[:space:]]+(.+)$ ]]; then
    printf '%s' "$title"
    return 0
  fi
  local prefix="${BASH_REMATCH[1]}"
  local rest="${BASH_REMATCH[2]}"
  local prefix_lc
  prefix_lc=$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')

  local IFS=','
  local lbl
  for lbl in $labels_csv; do
    # Trim leading/trailing spaces from each comma-separated entry
    lbl="${lbl# }"
    lbl="${lbl% }"
    local lbl_lc
    lbl_lc=$(printf '%s' "$lbl" | tr '[:upper:]' '[:lower:]')
    if [ "$prefix_lc" = "$lbl_lc" ]; then
      printf '%s' "$rest"
      return 0
    fi
  done
  printf '%s' "$title"
}

# =============================================================================
# Integration branches display
# =============================================================================

# render_integration_branches <open_prs_json> <repo_url>
#
# Renders the "Integration branches" section of repo-wide --status.
# Reads ledger files from $RITE_STATE_DIR/integration-branches/*.log (including
# nested subdirs for branch names containing '/').
#
# Silent when no ledger files exist (or the dir is absent) so repos that only
# use main see byte-identical output.
#
# Per-branch block:
#   - header with branch name
#   - in-flight worktrees: open PRs whose baseRefName == this branch
#   - merged-awaiting-promotion: ledger lines where promoted=false
#   - behind-main drift count (local refs only, no fetch)
#   - suggested next command: --sync (behind > 0) or --promote (== 0, unpromoted)
#
# Fully-retired ledgers (all entries promoted, no matching worktrees, no
# origin/<branch> ref) are silently skipped.
#
# Bash 3.2 portable: indexed arrays only, no declare -A / mapfile.
render_integration_branches() {
  local prs_json="${1:-[]}"
  local repo_url="${2:-}"

  # Silent when the ledger directory doesn't exist yet
  [ -d "$RITE_STATE_DIR/integration-branches" ] || return 0

  # Collect ledger files via find (branch names may contain '/', so nested dirs exist)
  local ledger_files=()
  local _f
  while IFS= read -r _f; do
    ledger_files+=("$_f")
  done < <(find "$RITE_STATE_DIR/integration-branches" -type f -name '*.log' 2>/dev/null | sort)

  # Silent when no ledger files found
  [ "${#ledger_files[@]}" -gt 0 ] || return 0

  local _rendered_any="false"

  for _ledger_f in "${ledger_files[@]+"${ledger_files[@]}"}"; do
    # Recover the branch name: strip ledger dir prefix and .log suffix.
    # NOT basename — branch names like release/1.2 would be truncated.
    local _rel="${_ledger_f#"$RITE_STATE_DIR/integration-branches/"}"
    local _branch="${_rel%.log}"

    # --- Count unpromoted ledger entries ---
    local _unpromoted_count=0
    _unpromoted_count=$(grep -c 'promoted=false' "$_ledger_f" 2>/dev/null || true)
    _unpromoted_count="${_unpromoted_count:-0}"

    # --- Count in-flight worktrees (open PRs targeting this branch) ---
    local _inflight_count=0
    if [ -n "$prs_json" ] && [ "$prs_json" != "[]" ]; then
      _inflight_count=$(echo "$prs_json" | jq --arg b "$_branch" \
        '[.[] | select(.baseRefName == $b)] | length' 2>/dev/null || echo "0")
      _inflight_count="${_inflight_count:-0}"
    fi

    # --- Check whether origin/<branch> ref exists locally ---
    local _origin_sha
    _origin_sha=$(git rev-parse "origin/$_branch" 2>/dev/null || echo "")

    # Skip fully-retired ledgers: all entries promoted, no in-flight worktrees,
    # and no local origin/<branch> ref (branch was deleted after promotion).
    if [ "$_unpromoted_count" -eq 0 ] && [ "$_inflight_count" -eq 0 ] && [ -z "$_origin_sha" ]; then
      continue
    fi

    # --- We have something to render — emit the section header once ---
    if [ "$_rendered_any" = "false" ]; then
      echo -e "  ${CYAN}Integration Branches:${NC}"
      echo -e "  ${BLUE}─────────────────────────────────────────────────────${NC}"
      _rendered_any="true"
    fi

    # --- Behind-main count ---
    local _behind="?"
    if [ -n "$_origin_sha" ]; then
      _behind=$(behind_main_count "$RITE_PROJECT_ROOT" "origin/$_branch")
    fi

    # --- Branch header line ---
    local _behind_display=""
    if [ "$_behind" = "?" ]; then
      _behind_display="  ${DIM}behind: ?${NC}"
    elif [ "$_behind" -gt 0 ]; then
      local _bc="${YELLOW}"
      [ "$_behind" -ge "${RITE_STALE_BRANCH_THRESHOLD:-10}" ] && _bc="${RED}"
      _behind_display="  ${_bc}${_behind} behind main${NC}"
    fi
    echo -e "  ${CYAN}${_branch}${NC}${_behind_display}"

    # --- In-flight worktrees ---
    if [ "$_inflight_count" -gt 0 ]; then
      while IFS= read -r _pr_entry; do
        [ -n "$_pr_entry" ] || continue
        local _pr_num _pr_head _pr_body _pr_issue
        _pr_num=$(echo "$_pr_entry" | jq -r '.number // ""' 2>/dev/null || echo "")
        _pr_head=$(echo "$_pr_entry" | jq -r '.headRefName // ""' 2>/dev/null || echo "")
        _pr_body=$(echo "$_pr_entry" | jq -r '.body // ""' 2>/dev/null || echo "")
        _pr_issue=$(echo "$_pr_body" | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' \
          | head -1 | grep -oE '[0-9]+' || true)
        if [ -n "$_pr_issue" ]; then
          local _iref
          _iref=$(_issue_link "$_pr_issue" 6 "$repo_url")
          echo -e "    ${_iref}  ${_pr_head}  $(_pr_link "$_pr_num" "$repo_url")  ${DIM}in flight${NC}"
        else
          echo -e "    $(_pr_link "$_pr_num" "$repo_url")  ${_pr_head}  ${DIM}in flight${NC}"
        fi
      done < <(echo "$prs_json" | jq -c --arg b "$_branch" \
        '[.[] | select(.baseRefName == $b)] | .[]' 2>/dev/null)
    fi

    # --- Merged-awaiting-promotion entries ---
    if [ "$_unpromoted_count" -gt 0 ]; then
      while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        # Skip promoted entries
        case "$_line" in *"promoted=true"*) continue ;; esac
        # Parse tab-separated key=value fields
        local _iss="" _pr="" _sha=""
        local _field
        # Use a subshell-free loop over tab-delimited fields via IFS
        local _old_ifs="$IFS"
        IFS=$'\t'
        # shellcheck disable=SC2086
        set -- $_line
        IFS="$_old_ifs"
        for _field in "$@"; do
          case "$_field" in
            issue=*) _iss="${_field#issue=}" ;;
            pr=*)    _pr="${_field#pr=}"     ;;
            sha=*)   _sha="${_field#sha=}"   ;;
          esac
        done
        local _short_sha="${_sha:0:7}"
        if [ -n "$_iss" ]; then
          local _iref
          _iref=$(_issue_link "$_iss" 6 "$repo_url")
          if [ -n "$_pr" ]; then
            echo -e "    ${_iref}  $(_pr_link "$_pr" "$repo_url")  ${DIM}${_short_sha} awaiting promotion${NC}"
          else
            echo -e "    ${_iref}  ${DIM}${_short_sha} awaiting promotion${NC}"
          fi
        fi
      done < "$_ledger_f"
    fi

    # --- Suggested next command ---
    if [ "$_behind" = "?" ]; then
      : # No suggestion when we can't measure drift
    elif [ "$_behind" -gt 0 ]; then
      echo -e "    ${DIM}→ rite --sync ${_branch}${NC}"
    elif [ "$_unpromoted_count" -gt 0 ]; then
      echo -e "    ${DIM}→ rite --promote ${_branch}${NC}"
    fi

    echo ""
  done
}

# =============================================================================
# Main display
# =============================================================================

repo_wide_status() {
  local group_by_label="${1:-}"

  # Backfill lock files for legacy worktrees that predate the lock infrastructure
  # (PR #67).  This is a best-effort, fast operation: it walks git worktree list
  # and writes a minimal `cwd`-only lock dir for any worktree whose branch maps
  # to an open PR with a "Closes #N" reference.  Done here (before the worktree
  # details rendering) so the backfill-lock lookup below can find the results.
  backfill_worktree_locks 2>/dev/null || true

  local repo_name
  repo_name=$(basename "$RITE_PROJECT_ROOT")

  # Repo URL for terminal hyperlinks (OSC 8)
  local repo_url
  repo_url=$(gh_safe repo view --json url -q '.url' || true)
  repo_url="${repo_url:-}"

  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE} Sharkrite Status: ${repo_name}${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  # --- Worktrees ---
  scan_worktrees

  local wt_summary="${WORKTREE_COUNT} worktree"
  [ "$WORKTREE_COUNT" -ne 1 ] && wt_summary="${wt_summary}s"
  if [ "$STALE_WORKTREE_COUNT" -gt 0 ]; then
    wt_summary="${wt_summary} (${STALE_WORKTREE_COUNT} stale)"
  fi
  echo -e "  ${CYAN}Worktrees:${NC} ${wt_summary}"
  echo ""

  # --- Fetch open issues ---
  echo "  Fetching issues..." >&2
  local open_issues_json
  open_issues_json=$(gh_safe issue list --state open --json number,title,labels,createdAt --limit 200)
  open_issues_json="${open_issues_json:-[]}"

  local open_count
  open_count=$(echo "$open_issues_json" | jq 'length' 2>/dev/null || echo "0")

  # --- Batch-fetch all open PRs (avoid N+1 API calls) ---
  local open_prs_json
  open_prs_json=$(gh_safe pr list --state open --json number,body,headRefName,baseRefName --limit 200)
  open_prs_json="${open_prs_json:-[]}"

  # --- For PRs that exist, batch-fetch comments ---
  # Build a map of issue_number -> PR json
  # We'll fetch comments per-PR only for issues that have one

  # --- Display open issues ---
  echo -e "  ${CYAN}Open Issues (${open_count}):${NC}"
  echo -e "  ${BLUE}─────────────────────────────────────────────────────${NC}"

  if [ "$open_count" -eq 0 ]; then
    echo "  No open issues"
    echo ""
  else
    # Build parallel arrays for open issues
    local issue_numbers=()
    local issue_titles=()
    local issue_labels_list=()
    local issue_phases=()
    local issue_pr_numbers=()

    # Process each issue
    while IFS= read -r issue_json; do
      local num title labels_str
      num=$(echo "$issue_json" | jq -r '.number')
      title=$(echo "$issue_json" | jq -r '.title')
      labels_str=$(echo "$issue_json" | jq -r '[.labels[].name] | join(", ")')

      # Find matching PR (body contains "Closes #N" or "Fixes #N")
      local matched_pr
      matched_pr=$(echo "$open_prs_json" | jq --arg issue "$num" --arg closing_re "$CLOSING_ISSUE_JQ_REGEX" '
        [.[] | select(.body | test($closing_re + $issue + "\\b"))] | .[0] // empty
      ' 2>/dev/null || echo "")

      # Fetch comments for this PR if it exists
      local pr_comments=""
      if [ -n "$matched_pr" ] && [ "$matched_pr" != "null" ]; then
        local pr_num
        pr_num=$(echo "$matched_pr" | jq -r '.number')
        pr_comments=$(gh_safe pr view "$pr_num" --json comments --jq '.comments')
        pr_comments="${pr_comments:-[]}"
      fi

      get_issue_phase "$num" "$matched_pr" "$pr_comments"

      issue_numbers+=("$num")
      issue_titles+=("$title")
      issue_labels_list+=("$labels_str")
      issue_phases+=("$ISSUE_PHASE")
      issue_pr_numbers+=("$ISSUE_PR_NUMBER")
    done < <(echo "$open_issues_json" | jq -c '.[] | {number, title, labels, createdAt}' 2>/dev/null)

    # Display
    if [ "$group_by_label" = "--by-label" ]; then
      # Collect unique labels
      local all_labels=()
      # +idiom on both loops: zero open issues leaves issue_labels_list empty,
      # and an unlabeled issue yields an empty label_arr — bare [@] expansion
      # of an empty array crashes under set -u on bash 3.2 (PR #266 pattern).
      for labels_str in "${issue_labels_list[@]+"${issue_labels_list[@]}"}"; do
        IFS=', ' read -ra label_arr <<< "$labels_str"
        for lbl in "${label_arr[@]+"${label_arr[@]}"}"; do
          lbl=$(echo "$lbl" | xargs)  # trim
          [ -z "$lbl" ] && continue
          # Check if already in all_labels
          local found=false
          for existing in "${all_labels[@]+"${all_labels[@]}"}"; do
            if [ "$existing" = "$lbl" ]; then found=true; break; fi
          done
          if [ "$found" = false ]; then
            all_labels+=("$lbl")
          fi
        done
      done

      # Sort labels
      local sorted_labels
      sorted_labels=$(printf '%s\n' "${all_labels[@]+"${all_labels[@]}"}" | sort)

      # Track which issues have been displayed (to catch unlabeled)
      local displayed=()

      while IFS= read -r label; do
        [ -z "$label" ] && continue
        local label_issues=""
        local label_count=0

        for i in "${!issue_numbers[@]}"; do
          if echo ", ${issue_labels_list[$i]}, " | grep -q ", ${label}, \|, ${label}$\|^${label}, "; then
            label_count=$((label_count + 1))
            local _display_title
            _display_title=$(strip_label_prefix_from_title "${issue_titles[$i]}" "${issue_labels_list[$i]}")
            local trunc_title
            trunc_title=$(truncate_str "$_display_title" 38)
            local padded_title
            padded_title=$(pad_str "$trunc_title" 40)
            local padded_phase
            padded_phase=$(pad_str "${issue_phases[$i]}" 22)
            local pr_ref=""
            if [ -n "${issue_pr_numbers[$i]}" ]; then
              pr_ref="$(_pr_link "${issue_pr_numbers[$i]}" "$repo_url")"
            fi
            local issue_ref
            issue_ref=$(_issue_link "${issue_numbers[$i]}" 6 "$repo_url")
            label_issues="${label_issues}    ${issue_ref}${padded_title}  ${padded_phase}${pr_ref}
"
            displayed+=("${issue_numbers[$i]}")
          fi
        done

        if [ "$label_count" -gt 0 ]; then
          echo -e "  ${YELLOW}${label}${NC} (${label_count}):"
          echo -ne "$label_issues"
          echo ""
        fi
      done <<< "$sorted_labels"

      # Show unlabeled issues
      local unlabeled_issues=""
      local unlabeled_count=0
      for i in "${!issue_numbers[@]}"; do
        if [ -z "${issue_labels_list[$i]}" ]; then
          unlabeled_count=$((unlabeled_count + 1))
          local _display_title
          _display_title=$(strip_label_prefix_from_title "${issue_titles[$i]}" "${issue_labels_list[$i]}")
          local trunc_title
          trunc_title=$(truncate_str "$_display_title" 38)
          local padded_title
          padded_title=$(pad_str "$trunc_title" 40)
          local padded_phase
          padded_phase=$(pad_str "${issue_phases[$i]}" 22)
          local pr_ref=""
          if [ -n "${issue_pr_numbers[$i]}" ]; then
            pr_ref="$(_pr_link "${issue_pr_numbers[$i]}" "$repo_url")"
          fi
          local issue_ref
          issue_ref=$(_issue_link "${issue_numbers[$i]}" 6 "$repo_url")
          unlabeled_issues="${unlabeled_issues}    ${issue_ref}${padded_title}  ${padded_phase}${pr_ref}
"
        fi
      done
      if [ "$unlabeled_count" -gt 0 ]; then
        echo -e "  ${YELLOW}unlabeled${NC} (${unlabeled_count}):"
        echo -ne "$unlabeled_issues"
        echo ""
      fi

    else
      # Flat mode — split into in-progress and not-started groups
      local started_count=0
      local not_started_count=0
      for i in "${!issue_numbers[@]}"; do
        if [ "${issue_phases[$i]}" = "Not started" ]; then
          not_started_count=$((not_started_count + 1))
        else
          started_count=$((started_count + 1))
        fi
      done

      # In-progress issues (with phase column)
      if [ "$started_count" -gt 0 ]; then
        echo -e "  ${DIM}In Progress (${started_count}):${NC}"
        for i in "${!issue_numbers[@]}"; do
          [ "${issue_phases[$i]}" = "Not started" ] && continue
          local _display_title
          _display_title=$(strip_label_prefix_from_title "${issue_titles[$i]}" "${issue_labels_list[$i]}")
          local trunc_title
          trunc_title=$(truncate_str "$_display_title" 38)
          local padded_title
          padded_title=$(pad_str "$trunc_title" 40)
          local padded_phase
          padded_phase=$(pad_str "${issue_phases[$i]}" 18)
          # Fixed-width PR column (10 chars) so the labels column starts at a
          # predictable position regardless of whether a PR exists.
          local pr_display="          "
          if [ -n "${issue_pr_numbers[$i]}" ]; then
            pr_display="$(_pr_link "${issue_pr_numbers[$i]}" "$repo_url" 10)"
          fi
          local labels_display=""
          if [ -n "${issue_labels_list[$i]}" ]; then
            labels_display="${issue_labels_list[$i]}"
          fi
          local issue_ref
          issue_ref=$(_issue_link "${issue_numbers[$i]}" 6 "$repo_url")
          echo -e "  ${issue_ref}${padded_title}  ${padded_phase}${pr_display}${YELLOW}${labels_display}${NC}"
        done
        echo ""
      fi

      # Not-started issues (no phase column, wider titles)
      if [ "$not_started_count" -gt 0 ]; then
        echo -e "  ${DIM}Not Started (${not_started_count}):${NC}"
        for i in "${!issue_numbers[@]}"; do
          [ "${issue_phases[$i]}" != "Not started" ] && continue
          local _display_title
          _display_title=$(strip_label_prefix_from_title "${issue_titles[$i]}" "${issue_labels_list[$i]}")
          local trunc_title
          trunc_title=$(truncate_str "$_display_title" 60)
          local padded_title
          padded_title=$(pad_str "$trunc_title" 62)
          local labels_display=""
          if [ -n "${issue_labels_list[$i]}" ]; then
            labels_display="${issue_labels_list[$i]}"
          fi
          local issue_ref
          issue_ref=$(_issue_link "${issue_numbers[$i]}" 6 "$repo_url")
          echo -e "  ${issue_ref}${padded_title}  ${YELLOW}${labels_display}${NC}"
        done
        echo ""
      fi
    fi
  fi

  # --- Recently closed ---
  local closed_issues_json
  closed_issues_json=$(gh_safe issue list --state closed --json number,title,labels,closedAt --limit 5)
  closed_issues_json="${closed_issues_json:-[]}"

  local closed_count
  closed_count=$(echo "$closed_issues_json" | jq 'length' 2>/dev/null || echo "0")

  # Batch-fetch merged PRs to match against closed issues
  local merged_prs_json
  merged_prs_json=$(gh_safe pr list --state merged --json number,body --limit 20)
  merged_prs_json="${merged_prs_json:-[]}"

  echo -e "  ${CYAN}Recently Closed (${closed_count}):${NC}"
  echo -e "  ${BLUE}─────────────────────────────────────────────────────${NC}"

  if [ "$closed_count" -eq 0 ]; then
    echo "  No recently closed issues"
  else
    while IFS= read -r issue_json; do
      local num title closed_at labels_str
      num=$(echo "$issue_json" | jq -r '.number')
      title=$(echo "$issue_json" | jq -r '.title')
      closed_at=$(echo "$issue_json" | jq -r '.closedAt // ""' || true)
      labels_str=$(echo "$issue_json" | jq -r '[.labels[].name] | join(", ")')

      # Format close date
      local close_date=""
      if [ -n "$closed_at" ] && [ "$closed_at" != "null" ]; then
        close_date="${closed_at:0:10}"  # YYYY-MM-DD
      fi

      # Find matching merged PR
      local closed_pr_num=""
      local matched_closed_pr
      matched_closed_pr=$(echo "$merged_prs_json" | jq -r --arg issue "$num" --arg closing_re "$CLOSING_ISSUE_JQ_REGEX" '
        [.[] | select(.body | test($closing_re + $issue + "\\b"))] | .[0].number // ""
      ' 2>/dev/null || echo "")
      if [ -n "$matched_closed_pr" ] && [ "$matched_closed_pr" != "null" ]; then
        closed_pr_num="$matched_closed_pr"
      fi

      local _display_title
      _display_title=$(strip_label_prefix_from_title "$title" "$labels_str")
      local trunc_title
      trunc_title=$(truncate_str "$_display_title" 40)
      local padded_title
      padded_title=$(pad_str "$trunc_title" 42)
      local padded_date
      padded_date=$(pad_str "$close_date" 12)
      # Fixed-width PR column (10 chars) so labels start at a predictable column.
      local pr_display="          "
      if [ -n "$closed_pr_num" ]; then
        pr_display="$(_pr_link "$closed_pr_num" "$repo_url" 10)"
      fi
      local labels_display=""
      if [ -n "$labels_str" ]; then
        labels_display="${labels_str}"
      fi
      local issue_ref
      issue_ref=$(_issue_link "$num" 6 "$repo_url")
      echo -e "  ${issue_ref}${padded_title}  ${padded_date}${pr_display}${YELLOW}${labels_display}${NC}"
    done < <(echo "$closed_issues_json" | jq -c '.[]' 2>/dev/null)
  fi
  echo ""

  # --- Worktree details ---
  if [ "$WORKTREE_COUNT" -gt 0 ]; then
    echo -e "  ${CYAN}Worktree Details:${NC}"
    echo -e "  ${BLUE}─────────────────────────────────────────────────────${NC}"
    # Hoist lsof availability check outside the per-worktree loop (O(1) not O(N))
    local _lsof_available=""
    command -v lsof >/dev/null 2>&1 && _lsof_available="1" || true
    for i in "${!WT_BRANCHES[@]}"; do
      local branch="${WT_BRANCHES[$i]}"

      # Extract issue number: try branch name, worktree path, open PR body,
      # lock-file lookup (numeric order), then gh API fallback.
      local wt_issue_num=""
      if [[ "$branch" =~ issue-?([0-9]+) ]]; then
        wt_issue_num="${BASH_REMATCH[1]}"
      fi
      if [ -z "$wt_issue_num" ] && [[ "${WT_PATHS[$i]}" =~ issue-?([0-9]+) ]]; then
        wt_issue_num="${BASH_REMATCH[1]}"
      fi
      if [ -z "$wt_issue_num" ] && [ -n "${open_prs_json:-}" ]; then
        local _pr_body
        _pr_body=$(echo "$open_prs_json" | jq -r --arg b "$branch" \
          '[.[] | select(.headRefName == $b)] | .[0].body // ""' 2>/dev/null || echo "")
        wt_issue_num=$(echo "$_pr_body" | grep -oE "$CLOSING_ISSUE_GREP_REGEX" | head -1 | grep -oE '[0-9]+' || true)
      fi
      # Lock-file fallback: check which issue lock corresponds to this worktree path.
      # get_locked_issue_numbers() returns numbers in NUMERIC order (not lexical),
      # preventing issue-10 from shadowing issue-9 when both lock dirs exist.
      # Primary: read the cwd file written by acquire_issue_lock at acquire time
      # (O(N) file reads, no per-process syscalls).
      # Fallback: /proc/PID/cwd (Linux) or lsof (macOS) — lsof availability is
      # checked once outside the loop to avoid O(N×M) command -v calls.
      if [ -z "$wt_issue_num" ]; then
        local _locked_nums
        _locked_nums=$(get_locked_issue_numbers 2>/dev/null || true)
        if [ -n "$_locked_nums" ]; then
          local _wt_path="${WT_PATHS[$i]}"
          local _candidate
          while IFS= read -r _candidate; do
            [ -n "$_candidate" ] || continue
            local _lock_dir="${RITE_LOCK_DIR:-}/issue-${_candidate}.lock"
            local _lock_pid_file="${_lock_dir}/pid"
            if [ -f "$_lock_pid_file" ]; then
              local _lock_pid
              _lock_pid=$(cat "$_lock_pid_file" 2>/dev/null || true)
              if [ -n "$_lock_pid" ] && kill -0 "$_lock_pid" 2>/dev/null; then
                # Primary: read cwd file written by acquire_issue_lock (no lsof/procfs)
                local _proc_cwd=""
                local _lock_cwd_file="${_lock_dir}/cwd"
                if [ -f "$_lock_cwd_file" ]; then
                  _proc_cwd=$(cat "$_lock_cwd_file" 2>/dev/null || true)
                elif [ -d "/proc/${_lock_pid}/cwd" ]; then
                  # Linux fallback: procfs symlink
                  _proc_cwd=$(readlink -f "/proc/${_lock_pid}/cwd" 2>/dev/null || true)
                elif [ -n "$_lsof_available" ]; then
                  # macOS fallback: lsof (already checked availability above)
                  _proc_cwd=$(lsof -a -p "$_lock_pid" -d cwd -Fn 2>/dev/null \
                    | grep '^n' | head -1 | cut -c2- || true)
                fi
                if [ -n "$_proc_cwd" ] && [[ "$_proc_cwd" == "$_wt_path"* ]]; then
                  wt_issue_num="$_candidate"
                  break
                fi
              fi
            fi
          done <<< "$_locked_nums"
        fi
      fi
      # Backfill-lock fallback: check for lock dirs written by backfill_worktree_locks().
      # These have a `cwd` file and a `backfill` sentinel but no live `pid`.
      # This path is reached only when the branch name, worktree path, open PR body,
      # and live-lock lookup all failed to identify the issue — i.e., exactly the
      # legacy-worktree case this backfill was designed to handle.
      if [ -z "$wt_issue_num" ] && [ -n "${RITE_LOCK_DIR:-}" ] && [ -d "${RITE_LOCK_DIR}" ]; then
        local _bf_entry
        for _bf_entry in "${RITE_LOCK_DIR}"/issue-*.lock; do
          [ -d "$_bf_entry" ] || continue
          # Must have the backfill sentinel (skip live locks without sentinel)
          [ -f "$_bf_entry/backfill" ] || continue
          # Must have a cwd file
          [ -f "$_bf_entry/cwd" ] || continue
          local _bf_cwd
          _bf_cwd=$(cat "$_bf_entry/cwd" 2>/dev/null || true)
          if [ -n "$_bf_cwd" ] && [ "$_bf_cwd" = "${WT_PATHS[$i]}" ]; then
            # Extract issue number from directory name
            local _bf_basename="${_bf_entry##*/}"  # issue-N.lock
            local _bf_num="${_bf_basename#issue-}"  # N.lock
            _bf_num="${_bf_num%.lock}"              # N
            [[ "$_bf_num" =~ ^[0-9]+$ ]] && wt_issue_num="$_bf_num"
            break
          fi
        done
      fi
      local wt_pr_num=""
      if [ -z "$wt_issue_num" ]; then
        local _fallback_pr
        _fallback_pr=$(gh_safe pr list --head "$branch" --state all --json number,body --limit 1 \
          --jq '.[0] // empty')
        _fallback_pr="${_fallback_pr:-}"
        if [ -n "$_fallback_pr" ]; then
          wt_pr_num=$(echo "$_fallback_pr" | jq -r '.number // ""' 2>/dev/null || true)
          wt_issue_num=$(echo "$_fallback_pr" | jq -r '.body // ""' | \
            grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
        fi
      fi

      local issue_prefix
      if [ -n "$wt_issue_num" ]; then
        issue_prefix="$(_issue_link "$wt_issue_num" 6 "$repo_url")  "
      elif [ -n "$wt_pr_num" ]; then
        issue_prefix="$(_pr_link "$wt_pr_num" "$repo_url")  "
      else
        issue_prefix="        "
      fi

      local padded_branch
      padded_branch=$(pad_str "$(truncate_str "$branch" 22)" 24)
      local padded_status
      padded_status=$(pad_str "${WT_STATUSES[$i]}" 16)
      local behind="${WT_BEHIND_MAIN[$i]:-0}"
      if [ "$behind" -gt 0 ]; then
        local behind_color="${YELLOW}"
        [ "$behind" -ge "${RITE_STALE_BRANCH_THRESHOLD:-10}" ] && behind_color="${RED}"
        echo -e "  ${issue_prefix}${padded_branch}${padded_status}  ${WT_AGES[$i]}  ${behind_color}${behind} behind${NC}"
      else
        echo -e "  ${issue_prefix}${padded_branch}${padded_status}  ${WT_AGES[$i]}"
      fi
    done
    echo ""
  fi

  # --- Integration branches ---
  render_integration_branches "$open_prs_json" "$repo_url"

  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}
