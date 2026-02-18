#!/bin/bash
# divergence-handler.sh
# Branch divergence detection, classification, and resolution.
# Handles two scenarios:
#   1. Push rejection: remote branch has foreign commits local doesn't have
#   2. Pre-merge verification: PR head changed since assessment
#
# Exit codes from handle_push_divergence():
#   0 = resolved (push succeeded, continue workflow)
#   1 = blocked (stop workflow, manual intervention needed)
#   2 = resolved but needs re-review (foreign commits pulled, re-enter Phase 2→3)

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

# Source notifications for Slack/email alerts
if [ -f "$RITE_LIB_DIR/utils/notifications.sh" ]; then
  source "$RITE_LIB_DIR/utils/notifications.sh"
fi

# ===================================================================
# OUTPUT HELPERS (stderr only — stdout reserved for pipe data)
# ===================================================================

_div_info()    { echo "ℹ️  $1" >&2; }
_div_success() { echo "✅ $1" >&2; }
_div_warning() { echo "⚠️  $1" >&2; }
_div_error()   { echo "❌ $1" >&2; }
_div_status()  { echo "$1" >&2; }

# ===================================================================
# DETECTION
# ===================================================================

# detect_divergence <branch_name>
#
# Checks if the remote branch has commits that the local branch doesn't.
# On success (divergence found), exports:
#   DIVERGENCE_COMMIT_COUNT  — number of foreign commits
#   DIVERGENCE_COMMITS       — oneline list (hash + message)
#   DIVERGENCE_LOCAL_HEAD    — local HEAD sha
#   DIVERGENCE_REMOTE_HEAD   — remote HEAD sha
#   DIVERGENCE_DIFF_STAT     — diffstat of foreign changes
#
# Returns: 0 if diverged, 1 if no divergence
detect_divergence() {
  local branch_name="$1"

  # Fetch latest remote state
  if ! git fetch origin "$branch_name" 2>/dev/null; then
    _div_error "Could not fetch origin/$branch_name (network issue?)"
    return 1
  fi

  local local_head
  local_head=$(git rev-parse HEAD 2>/dev/null || echo "")
  local remote_head
  remote_head=$(git rev-parse "origin/$branch_name" 2>/dev/null || echo "")

  if [ -z "$remote_head" ] || [ -z "$local_head" ]; then
    return 1  # Can't determine state
  fi

  if [ "$local_head" = "$remote_head" ]; then
    return 1  # No divergence
  fi

  # Check if remote has commits local doesn't
  local foreign_commits
  foreign_commits=$(git log --oneline "${local_head}..${remote_head}" 2>/dev/null)

  if [ -z "$foreign_commits" ]; then
    return 1  # Local is ahead (no foreign commits)
  fi

  export DIVERGENCE_COMMIT_COUNT
  DIVERGENCE_COMMIT_COUNT=$(echo "$foreign_commits" | wc -l | tr -d ' ')
  export DIVERGENCE_COMMITS="$foreign_commits"
  export DIVERGENCE_LOCAL_HEAD="$local_head"
  export DIVERGENCE_REMOTE_HEAD="$remote_head"
  export DIVERGENCE_DIFF_STAT
  DIVERGENCE_DIFF_STAT=$(git diff --stat "${local_head}..${remote_head}" 2>/dev/null || echo "")

  return 0
}

# ===================================================================
# CLASSIFICATION
# ===================================================================

# classify_foreign_commits <branch_name> <local_head> <remote_head> [issue_number]
#
# Categorizes foreign commits. Exports DIVERGENCE_CLASS:
#   TRIVIAL   — non-functional (mainline sync, docs, formatting)
#   RELATED   — related to the issue (fix-review remnants, same scope)
#   UNRELATED — different issue or unknown origin
classify_foreign_commits() {
  local branch_name="$1"
  local local_head="$2"
  local remote_head="$3"
  local issue_number="${4:-}"

  local commit_messages
  commit_messages=$(git log --format="%s" "${local_head}..${remote_head}" 2>/dev/null || echo "")

  # ── Fast path: heuristic classification (no Claude needed) ──

  local total_commits
  total_commits=$(echo "$commit_messages" | grep -c '.' || true)

  # Check 1: Separate foreign commits into "already on main" and "feature-branch only".
  # The GitHub "Update branch" button creates a merge commit ON the feature branch
  # that merges main into it. This merge commit is NOT reachable from origin/main
  # (it's unique to the feature branch), but the commits it brings in ARE on main.
  local non_main_commits
  non_main_commits=$(git log --oneline "${local_head}..${remote_head}" --not origin/main 2>/dev/null || echo "")

  if [ -z "$non_main_commits" ] && [ "$total_commits" -gt 0 ]; then
    # All foreign commits already exist on main — pure branch sync
    export DIVERGENCE_CLASS="TRIVIAL"
    _div_info "Fast classification: all foreign commits already exist on main (branch sync)" >&2
    return 0
  fi

  # Check if the only non-main commits are mainline sync merge commits.
  # These are the "Merge branch 'main' into feature-branch" commits created by
  # GitHub's "Update branch" button — they live on the feature branch but only
  # bring in changes that are already on main.
  if [ -n "$non_main_commits" ]; then
    local non_main_count
    non_main_count=$(echo "$non_main_commits" | grep -c '.' || true)
    local non_main_merge_count
    non_main_merge_count=$(echo "$non_main_commits" | grep -ciE "Merge branch '(main|master|develop)' into|Merge pull request .* from .*/main" || true)

    if [ "$non_main_merge_count" -eq "$non_main_count" ] && [ "$non_main_count" -gt 0 ]; then
      export DIVERGENCE_CLASS="TRIVIAL"
      _div_info "Fast classification: mainline sync ($non_main_count merge commit(s) + ${total_commits} total from main)" >&2
      return 0
    fi
  fi

  # Check 3: Commits look like rite automation (fix-review patterns)
  local rite_pattern_count
  rite_pattern_count=$(echo "$commit_messages" | grep -ciE "^(fix|chore): (address|fix|resolve) review (findings|issues|feedback)|sharkrite|rite.*fix-review|wip:.*auto-commit" || true)

  if [ "$rite_pattern_count" -eq "$total_commits" ] && [ "$total_commits" -gt 0 ]; then
    export DIVERGENCE_CLASS="RELATED"
    _div_info "Fast classification: all $total_commits commit(s) match rite automation patterns" >&2
    return 0
  fi

  # ── Slow path: Claude classification ──
  _div_status "Classifying foreign commits via Claude..." >&2

  local issue_context=""
  if [ -n "$issue_number" ]; then
    issue_context=$(gh issue view "$issue_number" --json title,body --jq '"Issue #" + (.number|tostring) + ": " + .title + "\n" + .body' 2>/dev/null || echo "Issue #$issue_number")
  fi

  local diff_stat
  diff_stat=$(git diff --stat "${local_head}..${remote_head}" 2>/dev/null | tail -20 || echo "")

  local prompt_file
  prompt_file=$(mktemp)
  cat > "$prompt_file" <<CLASSIFY_EOF
You are classifying foreign commits found on a PR branch.

Issue context:
${issue_context:-No issue context available}

PR branch: $branch_name

Foreign commits found on remote but not on local working copy:
$(git log --format="%h %s" "${local_head}..${remote_head}" 2>/dev/null)

Diff summary:
$diff_stat

Classify ALL foreign commits together as ONE of these categories:
- TRIVIAL: Non-functional changes only (docs, comments, formatting, renames, dependency bumps, mainline sync, GitHub "Update branch" merge). No logic changes.
- RELATED: Changes that implement, fix, or extend the same issue described above (review fixes, continuation of same work, test additions for same feature).
- UNRELATED: Changes for a different issue, feature, or unknown origin.

Answer with ONLY ONE WORD: TRIVIAL, RELATED, or UNRELATED
CLASSIFY_EOF

  local classification=""
  if command -v claude &>/dev/null; then
    classification=$(claude --print < "$prompt_file" 2>/dev/null | grep -oiE "(TRIVIAL|RELATED|UNRELATED)" | head -1 | tr '[:lower:]' '[:upper:]')
  fi
  rm -f "$prompt_file"

  if [ -z "$classification" ]; then
    _div_warning "Claude classification failed — using safe default" >&2
    # Safe default: RELATED in supervised (user can decide), UNRELATED in auto (blocks)
    export DIVERGENCE_CLASS="${_DIV_FALLBACK_CLASS:-UNRELATED}"
    return 0
  fi

  export DIVERGENCE_CLASS="$classification"
  _div_info "Classification: $DIVERGENCE_CLASS" >&2
  return 0
}

# ===================================================================
# RESOLUTION
# ===================================================================

# handle_push_divergence <branch_name> <issue_number> <pr_number> <auto_mode>
#
# Full handler for push rejection due to remote divergence.
# auto_mode: "true" for unsupervised, "false" for supervised.
#
# Exit codes:
#   0 = resolved (push succeeded)
#   1 = blocked (manual intervention needed)
#   2 = resolved but needs re-review (re-enter Phase 2→3)
handle_push_divergence() {
  local branch_name="$1"
  local issue_number="${2:-}"
  local pr_number="${3:-}"
  local auto_mode="${4:-false}"

  # Detect
  if ! detect_divergence "$branch_name"; then
    _div_error "handle_push_divergence called but no divergence detected"
    return 1
  fi

  _div_warning "Remote branch has $DIVERGENCE_COMMIT_COUNT foreign commit(s):" >&2
  echo "$DIVERGENCE_COMMITS" | sed 's/^/  /' >&2
  echo "" >&2

  # Set fallback class based on mode (used if Claude fails)
  if [ "$auto_mode" = "true" ]; then
    _DIV_FALLBACK_CLASS="UNRELATED"
  else
    _DIV_FALLBACK_CLASS="RELATED"
  fi

  # Classify
  classify_foreign_commits "$branch_name" "$DIVERGENCE_LOCAL_HEAD" "$DIVERGENCE_REMOTE_HEAD" "$issue_number"

  # ── Route through decision matrix ──

  case "$DIVERGENCE_CLASS" in
    TRIVIAL)
      _div_info "Auto-rebasing (TRIVIAL classification)..." >&2
      _do_rebase_and_push "$branch_name" "$auto_mode"
      return $?
      ;;

    RELATED)
      _handle_related "$branch_name" "$issue_number" "$pr_number" "$auto_mode"
      return $?
      ;;

    UNRELATED)
      _handle_unrelated "$branch_name" "$issue_number" "$pr_number" "$auto_mode"
      return $?
      ;;

    *)
      _div_error "Unknown classification: $DIVERGENCE_CLASS"
      return 1
      ;;
  esac
}

# ── Internal: handle RELATED classification ──
_handle_related() {
  local branch_name="$1"
  local issue_number="$2"
  local pr_number="$3"
  local auto_mode="$4"

  # Check if the foreign commits were already reviewed
  local reviewed=false
  if [ -n "$pr_number" ]; then
    local assess_time
    assess_time=$(gh pr view "$pr_number" --json comments \
      --jq '[.comments[] | select(.body | contains("<!-- sharkrite-assessment"))] | sort_by(.createdAt) | reverse | .[0].createdAt // ""' \
      2>/dev/null || echo "")

    local foreign_commit_time
    foreign_commit_time=$(git log -1 --format="%aI" "$DIVERGENCE_REMOTE_HEAD" 2>/dev/null || echo "")

    if [ -n "$assess_time" ] && [ "$assess_time" != "" ] && [ -n "$foreign_commit_time" ]; then
      if [[ "$assess_time" > "$foreign_commit_time" ]]; then
        reviewed=true
      fi
    fi
  fi

  if [ "$reviewed" = true ]; then
    _div_info "RELATED + already reviewed — auto-rebasing" >&2
    _do_rebase_and_push "$branch_name" "$auto_mode"
    return $?
  fi

  # RELATED + unreviewed
  if [ "$auto_mode" = "true" ]; then
    _div_warning "RELATED but UNREVIEWED — blocking in auto mode" >&2
    _send_divergence_notification "$issue_number" "$pr_number" "RELATED_UNREVIEWED" "$DIVERGENCE_COMMITS"
    return 1
  fi

  # Supervised: interactive menu
  _div_warning "RELATED but UNREVIEWED — requires your decision" >&2
  echo "" >&2
  echo "These commits appear related to issue #$issue_number but haven't been reviewed." >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  a) Pull and re-enter review cycle (generates new review for combined changes)" >&2
  echo "  b) Pull without review (you take responsibility for these commits)" >&2
  echo "  c) Overwrite remote with local work (force-push, discards foreign commits)" >&2
  echo "  d) Abort workflow" >&2
  echo "" >&2
  read -p "Choose [a/b/c/d]: " -n 1 -r >&2
  echo >&2

  case "$REPLY" in
    a|A)
      _div_info "Pulling foreign commits and re-entering review cycle..." >&2
      if ! _do_rebase "$branch_name"; then return 1; fi
      if ! git push origin "$branch_name"; then
        _div_error "Push failed after rebase"
        return 1
      fi
      return 2  # Signal: re-enter review loop
      ;;
    b|B)
      _div_info "Pulling foreign commits without review..." >&2
      _do_rebase_and_push "$branch_name" "$auto_mode"
      return $?
      ;;
    c|C)
      _div_warning "Force-pushing local work (discarding foreign commits)..." >&2
      if ! git push --force-with-lease origin "$branch_name"; then
        _div_error "Force-push failed"
        return 1
      fi
      _div_success "Force-push succeeded"
      return 0
      ;;
    d|D)
      _div_info "Workflow aborted by user"
      return 1
      ;;
    *)
      _div_error "Invalid choice: $REPLY"
      return 1
      ;;
  esac
}

# ── Internal: handle UNRELATED classification ──
_handle_unrelated() {
  local branch_name="$1"
  local issue_number="$2"
  local pr_number="$3"
  local auto_mode="$4"

  _div_error "UNRELATED foreign commits detected — blocking merge" >&2
  echo "" >&2
  echo "Foreign commits from a different scope:" >&2
  echo "$DIVERGENCE_COMMITS" | sed 's/^/  /' >&2
  echo "" >&2
  echo "Diff summary:" >&2
  echo "$DIVERGENCE_DIFF_STAT" | sed 's/^/  /' >&2
  echo "" >&2

  # Notify in all modes
  _send_divergence_notification "$issue_number" "$pr_number" "UNRELATED" "$DIVERGENCE_COMMITS"

  if [ "$auto_mode" = "true" ]; then
    _div_error "Auto mode: cannot proceed with unrelated foreign commits"
    return 1
  fi

  # Supervised: limited options (no pull — these are unrelated)
  echo "Options:" >&2
  echo "  c) Overwrite remote with local work (force-push, discards foreign commits)" >&2
  echo "  d) Abort workflow" >&2
  echo "" >&2
  read -p "Choose [c/d]: " -n 1 -r >&2
  echo >&2

  case "$REPLY" in
    c|C)
      _div_warning "Force-pushing local work (discarding unrelated commits)..." >&2
      if ! git push --force-with-lease origin "$branch_name"; then
        _div_error "Force-push failed"
        return 1
      fi
      _div_success "Force-push succeeded"
      return 0
      ;;
    *)
      _div_info "Workflow aborted by user"
      return 1
      ;;
  esac
}

# ── Internal: rebase onto remote and push ──
_do_rebase_and_push() {
  local branch_name="$1"
  local auto_mode="$2"

  if ! _do_rebase "$branch_name"; then
    # Rebase failed (conflicts)
    if [ "$auto_mode" = "true" ]; then
      _div_error "Rebase failed with conflicts — blocking in auto mode"
      _send_divergence_notification "${issue_number:-}" "${pr_number:-}" "REBASE_CONFLICT" "Rebase conflicts on $branch_name"
      return 1
    fi

    # Supervised: offer recovery
    echo "" >&2
    echo "Options:" >&2
    echo "  c) Force-push local work (discard foreign commits)" >&2
    echo "  d) Abort" >&2
    read -p "Choose [c/d]: " -n 1 -r >&2
    echo >&2

    case "$REPLY" in
      c|C)
        if ! git push --force-with-lease origin "$branch_name"; then
          _div_error "Force-push failed"
          return 1
        fi
        _div_success "Force-push succeeded"
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  fi

  # Rebase succeeded — push
  if ! git push origin "$branch_name"; then
    _div_error "Push failed after rebase"
    return 1
  fi

  _div_success "Rebased and pushed successfully"
  return 0
}

# ── Internal: perform rebase with conflict handling ──
_do_rebase() {
  local branch_name="$1"

  # Check for dirty worktree first — git rebase refuses to run with uncommitted changes
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    _div_info "Stashing uncommitted changes before rebase..." >&2
    git stash push -m "divergence-handler: auto-stash before rebase" 2>/dev/null || true
    local _stashed=true
  fi

  local _rebase_output
  _rebase_output=$(git rebase "origin/$branch_name" 2>&1) || {
    _div_error "Rebase failed — conflicts detected" >&2
    echo "" >&2

    # Show conflicting files (only present if rebase actually started)
    local _conflict_files
    _conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ -n "$_conflict_files" ]; then
      echo "Conflicting files:" >&2
      echo "$_conflict_files" | sed 's/^/  /' >&2
    else
      echo "Rebase output:" >&2
      echo "$_rebase_output" | sed 's/^/  /' >&2
    fi
    echo "" >&2

    # Abort the failed rebase
    git rebase --abort 2>/dev/null || true

    # Restore stash if we stashed
    if [ "${_stashed:-false}" = true ]; then
      git stash pop 2>/dev/null || true
    fi
    return 1
  }

  # Restore stash if we stashed
  if [ "${_stashed:-false}" = true ]; then
    git stash pop 2>/dev/null || {
      _div_warning "Stash pop had conflicts — stash preserved (run 'git stash pop' manually)" >&2
    }
  fi

  return 0
}

# ===================================================================
# PRE-MERGE VERIFICATION
# ===================================================================

# verify_pr_head <pr_number> <expected_sha>
#
# Checks that the PR's current head commit matches what we expect.
# Used before merge to catch foreign commits pushed after assessment.
#
# Exports PR_CURRENT_HEAD.
# Returns: 0 if head matches, 1 if changed or error
verify_pr_head() {
  local pr_number="$1"
  local expected_sha="$2"

  export PR_CURRENT_HEAD
  PR_CURRENT_HEAD=$(gh pr view "$pr_number" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")

  if [ -z "$PR_CURRENT_HEAD" ]; then
    _div_warning "Could not fetch PR head SHA — skipping verification" >&2
    return 0  # Don't block on API failure
  fi

  if [ "$PR_CURRENT_HEAD" != "$expected_sha" ]; then
    _div_warning "PR head has changed since assessment" >&2
    _div_info "Expected: ${expected_sha:0:12}" >&2
    _div_info "Current:  ${PR_CURRENT_HEAD:0:12}" >&2
    return 1
  fi

  return 0
}

# ===================================================================
# NOTIFICATIONS
# ===================================================================

# _send_divergence_notification <issue_number> <pr_number> <classification> <commits>
_send_divergence_notification() {
  local issue_number="$1"
  local pr_number="$2"
  local classification="$3"
  local commits="$4"

  # Only send if notification system is available
  if ! type send_notification_all &>/dev/null; then
    _div_info "Notification system not available — skipping Slack/email alert" >&2
    return 0
  fi

  local repo_url
  repo_url=$(gh repo view --json url --jq '.url' 2>/dev/null || echo "")

  local issue_link="#${issue_number}"
  local pr_link="#${pr_number}"
  if [ -n "$repo_url" ]; then
    [ -n "$issue_number" ] && issue_link="<${repo_url}/issues/${issue_number}|#${issue_number}>"
    [ -n "$pr_number" ] && pr_link="<${repo_url}/pull/${pr_number}|#${pr_number}>"
  fi

  local message=":warning: *Branch Divergence Detected*

*Classification:* ${classification}
*Issue:* ${issue_link}
*PR:* ${pr_link}

*Foreign commits on remote:*
\`\`\`
${commits}
\`\`\`

*Action required:* Manual review needed before workflow can continue.
*To resume:* \`rite ${issue_number}\`"

  send_notification_all "$message" "urgent"
}
