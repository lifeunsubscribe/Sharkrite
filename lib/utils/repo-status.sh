#!/bin/bash
# lib/utils/repo-status.sh - Repo-wide status display
# Shows worktrees, open issues with workflow phases, and recently closed issues.
# No bash 4+ requirement — uses indexed arrays only.
#
# Usage: source this file, then call repo_wide_status [--by-label]

# Source config and dependencies if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_SCRIPT_DIR/config.sh"
fi
source "$RITE_LIB_DIR/utils/colors.sh"
source "$RITE_LIB_DIR/utils/pr-detection.sh"

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
        local behind_main=0
        local _mb
        _mb=$(git -C "$current_path" merge-base HEAD origin/main 2>/dev/null || echo "")
        [ -n "$_mb" ] && behind_main=$(git -C "$current_path" rev-list --count "${_mb}..origin/main" 2>/dev/null || echo "0")

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
    local behind_main=0
    local _mb
    _mb=$(git -C "$current_path" merge-base HEAD origin/main 2>/dev/null || echo "")
    [ -n "$_mb" ] && behind_main=$(git -C "$current_path" rev-list --count "${_mb}..origin/main" 2>/dev/null || echo "0")

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
    review_body=$(echo "$pr_comments_json" | jq -r '
      [.[] | select(.body | contains("<!-- sharkrite-local-review"))]
      | sort_by(.createdAt) | reverse | .[0].body // ""
    ' 2>/dev/null || echo "")
    review_time=$(echo "$pr_comments_json" | jq -r '
      [.[] | select(.body | contains("<!-- sharkrite-local-review"))]
      | sort_by(.createdAt) | reverse | .[0].createdAt // ""
    ' 2>/dev/null || echo "")
  fi

  if [ -z "$review_body" ] || [ "$review_body" = "null" ]; then
    ISSUE_PHASE="Needs review"
    return 0
  fi

  # Count review iterations
  local review_count=1
  if [ -n "$pr_comments_json" ]; then
    review_count=$(echo "$pr_comments_json" | jq '
      [.[] | select(.body | contains("<!-- sharkrite-local-review"))] | length
    ' 2>/dev/null || echo "1")
    [ -z "$review_count" ] || [ "$review_count" = "0" ] && review_count=1
  fi

  # Check if review is current by comparing to latest commit
  # Use the PR branch to find worktree (if any) for local timestamps
  local pr_branch
  pr_branch=$(echo "$pr_json" | jq -r '.headRefName // ""')
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
    if date --version >/dev/null 2>&1; then
      commit_epoch=$(date -d "$latest_commit_time" "+%s" 2>/dev/null || echo "0")
      review_epoch=$(date -d "$review_time" "+%s" 2>/dev/null || echo "0")
    else
      commit_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$latest_commit_time" "+%s" 2>/dev/null || echo "0")
      review_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$review_time" "+%s" 2>/dev/null || echo "0")
    fi
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
    assess_body=$(echo "$pr_comments_json" | jq -r '
      [.[] | select(.body | contains("<!-- sharkrite-assessment"))]
      | sort_by(.createdAt) | reverse | .[0].body // ""
    ' 2>/dev/null || echo "")
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

# Right-pad string to fixed width (character-aware, not byte-aware).
# macOS bash 3.2's printf counts bytes for %-Ns padding, which breaks
# alignment when multibyte characters like … (3 bytes, 1 column) are present.
# Using ${#str} (character count) avoids this.
pad_str() {
  local str="$1" width="$2"
  local len=${#str}
  if [ "$len" -ge "$width" ]; then
    printf '%s' "$str"
  else
    printf '%s%*s' "$str" $((width - len)) ""
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
# Usage: _pr_link PR_NUMBER REPO_URL
_pr_link() {
  local num="$1" url="$2"
  if [ -n "$url" ]; then
    printf '%s' "\\033[2m\\033]8;;${url}/pull/${num}\\aPR#${num}\\033]8;;\\a\\033[0m"
  else
    printf '%s' "\\033[2mPR#${num}\\033[0m"
  fi
}

# =============================================================================
# Main display
# =============================================================================

repo_wide_status() {
  local group_by_label="${1:-}"

  local repo_name
  repo_name=$(basename "$RITE_PROJECT_ROOT")

  # Repo URL for terminal hyperlinks (OSC 8)
  local repo_url
  repo_url=$(gh repo view --json url -q '.url' 2>/dev/null || echo "")

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
  open_issues_json=$(gh issue list --state open --json number,title,labels,createdAt --limit 200 2>/dev/null || echo "[]")

  local open_count
  open_count=$(echo "$open_issues_json" | jq 'length' 2>/dev/null || echo "0")

  # --- Batch-fetch all open PRs (avoid N+1 API calls) ---
  local open_prs_json
  open_prs_json=$(gh pr list --state open --json number,body,headRefName --limit 200 2>/dev/null || echo "[]")

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
      matched_pr=$(echo "$open_prs_json" | jq --arg issue "$num" '
        [.[] | select(.body | test("(Closes|closes|Fixes|fixes|Resolves|resolves) #" + $issue + "\\b"))] | .[0] // empty
      ' 2>/dev/null || echo "")

      # Fetch comments for this PR if it exists
      local pr_comments=""
      if [ -n "$matched_pr" ] && [ "$matched_pr" != "null" ]; then
        local pr_num
        pr_num=$(echo "$matched_pr" | jq -r '.number')
        pr_comments=$(gh pr view "$pr_num" --json comments --jq '.comments' 2>/dev/null || echo "[]")
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
      for labels_str in "${issue_labels_list[@]}"; do
        IFS=', ' read -ra label_arr <<< "$labels_str"
        for lbl in "${label_arr[@]}"; do
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
            local trunc_title
            trunc_title=$(truncate_str "${issue_titles[$i]}" 38)
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
          local trunc_title
          trunc_title=$(truncate_str "${issue_titles[$i]}" 38)
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
          local trunc_title
          trunc_title=$(truncate_str "${issue_titles[$i]}" 38)
          local padded_title
          padded_title=$(pad_str "$trunc_title" 40)
          local padded_phase
          padded_phase=$(pad_str "${issue_phases[$i]}" 18)
          local pr_display=""
          if [ -n "${issue_pr_numbers[$i]}" ]; then
            pr_display="$(_pr_link "${issue_pr_numbers[$i]}" "$repo_url")  "
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
          local trunc_title
          trunc_title=$(truncate_str "${issue_titles[$i]}" 60)
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
  closed_issues_json=$(gh issue list --state closed --json number,title,labels,closedAt --limit 10 2>/dev/null || echo "[]")

  local closed_count
  closed_count=$(echo "$closed_issues_json" | jq 'length' 2>/dev/null || echo "0")

  # Batch-fetch merged PRs to match against closed issues
  local merged_prs_json
  merged_prs_json=$(gh pr list --state merged --json number,body --limit 20 2>/dev/null || echo "[]")

  echo -e "  ${CYAN}Recently Closed (${closed_count}):${NC}"
  echo -e "  ${BLUE}─────────────────────────────────────────────────────${NC}"

  if [ "$closed_count" -eq 0 ]; then
    echo "  No recently closed issues"
  else
    while IFS= read -r issue_json; do
      local num title closed_at labels_str
      num=$(echo "$issue_json" | jq -r '.number')
      title=$(echo "$issue_json" | jq -r '.title')
      closed_at=$(echo "$issue_json" | jq -r '.closedAt // ""')
      labels_str=$(echo "$issue_json" | jq -r '[.labels[].name] | join(", ")')

      # Format close date
      local close_date=""
      if [ -n "$closed_at" ] && [ "$closed_at" != "null" ]; then
        close_date="${closed_at:0:10}"  # YYYY-MM-DD
      fi

      # Find matching merged PR
      local closed_pr_num=""
      local matched_closed_pr
      matched_closed_pr=$(echo "$merged_prs_json" | jq -r --arg issue "$num" '
        [.[] | select(.body | test("(Closes|closes|Fixes|fixes|Resolves|resolves) #" + $issue + "\\b"))] | .[0].number // ""
      ' 2>/dev/null || echo "")
      if [ -n "$matched_closed_pr" ] && [ "$matched_closed_pr" != "null" ]; then
        closed_pr_num="$matched_closed_pr"
      fi

      local trunc_title
      trunc_title=$(truncate_str "$title" 40)
      local padded_title
      padded_title=$(pad_str "$trunc_title" 42)
      local padded_date
      padded_date=$(pad_str "$close_date" 12)
      local pr_display=""
      if [ -n "$closed_pr_num" ]; then
        pr_display="$(_pr_link "$closed_pr_num" "$repo_url")  "
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
    for i in "${!WT_BRANCHES[@]}"; do
      local padded_branch
      padded_branch=$(pad_str "$(truncate_str "${WT_BRANCHES[$i]}" 30)" 32)
      local padded_status
      padded_status=$(pad_str "${WT_STATUSES[$i]}" 16)
      local behind="${WT_BEHIND_MAIN[$i]:-0}"
      if [ "$behind" -gt 0 ]; then
        local behind_color="${YELLOW}"
        [ "$behind" -ge "${RITE_STALE_BRANCH_THRESHOLD:-10}" ] && behind_color="${RED}"
        echo -e "  ${padded_branch}${padded_status}  ${WT_AGES[$i]}  ${behind_color}${behind} behind${NC}"
      else
        echo -e "  ${padded_branch}${padded_status}  ${WT_AGES[$i]}"
      fi
    done
    echo ""
  fi

  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}
