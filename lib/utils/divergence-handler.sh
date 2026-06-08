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
#   5 = Claude usage cap reached during conflict resolution (propagated from conflict-resolver; batch should abort)

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f handle_push_divergence >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

# Source gh retry wrapper if not already loaded
# divergence-handler.sh may be sourced standalone or via stale-branch.sh,
# neither of which chains through pr-detection.sh.
if ! declare -f gh_safe >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/gh-retry.sh"
fi

# Source git helpers for git_fetch_safe (retry-aware fetch with backoff)
if ! declare -f git_fetch_safe >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/git-helpers.sh"
fi

# Source notifications for Slack/email alerts
if [ -f "$RITE_LIB_DIR/utils/notifications.sh" ]; then
  source "$RITE_LIB_DIR/utils/notifications.sh"
fi

# Source post-merge verification
source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

# Source stash manager
source "$RITE_LIB_DIR/utils/stash-manager.sh"

# Source marker constants relative to this file's location (lib/utils/) so that
# test environments where RITE_LIB_DIR points to the install copy also work.
_divergence_handler_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_divergence_handler_dir/markers.sh"

# Source logging for _diag structured diagnostic lines (no-op if already loaded)
if ! declare -f _diag >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/logging.sh"
fi

# Source conflict resolver if available (provided by issue #21).
# Guarded: divergence-handler works without it — resolver is an enhancement,
# not a hard dependency. When present, attempt_claude_merge_resolution()
# becomes available and is called on rebase conflict bail paths.
if [ -f "$RITE_LIB_DIR/utils/conflict-resolver.sh" ]; then
  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"
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

  # Fetch latest remote state with retry budget.
  # git_fetch_safe retries 3 times with exponential backoff before returning 1.
  # A transient fetch failure with bare `git fetch ... || true` would silently
  # return stale (or absent) remote state; with a hard failure here we avoid
  # a false "no divergence" determination on transient network errors.
  if ! git_fetch_safe origin "$branch_name"; then
    _div_error "Could not fetch origin/$branch_name after retries — cannot determine divergence"
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
    issue_context=$(gh_safe issue view "$issue_number" --json title,body --jq '"Issue #" + (.number|tostring) + ": " + .title + "\n" + .body' || true)
    issue_context="${issue_context:-Issue #$issue_number}"
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
  # Load utility provider for classification
  source "$RITE_LIB_DIR/providers/provider-interface.sh"
  load_provider "${RITE_UTILITY_PROVIDER:-claude}"
  if provider_detect_cli 2>/dev/null; then
    classification=$(provider_run_classify "$(cat "$prompt_file")" | grep -oiE "(TRIVIAL|RELATED|UNRELATED)" | head -1 | tr '[:lower:]' '[:upper:]' || true)
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
#   5 = Claude usage cap reached during conflict resolution (propagated from conflict-resolver; batch should abort)
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
      _do_rebase_and_push "$branch_name" "$auto_mode" "$issue_number" "$pr_number"
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
    local _jq_assess_time_f
    _jq_assess_time_f="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_ASSESSMENT}\"))] | sort_by(.createdAt) | reverse | .[0].createdAt // \"\""
    assess_time=$(gh_safe pr view "$pr_number" --json comments \
      --jq "$_jq_assess_time_f" \
      || true)
    assess_time="${assess_time:-}"

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
    _do_rebase_and_push "$branch_name" "$auto_mode" "$issue_number" "$pr_number"
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
      _do_rebase_and_push "$branch_name" "$auto_mode" "$issue_number" "$pr_number"
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
# _do_rebase_and_push BRANCH_NAME AUTO_MODE [ISSUE_NUMBER] [PR_NUMBER]
_do_rebase_and_push() {
  local branch_name="$1"
  local auto_mode="$2"
  local _issue_number="${3:-}"
  local _pr_number="${4:-}"

  # Snapshot HEAD before any rebase or resolver commits are applied.
  # This is the authoritative rollback target for verify_post_merge failures.
  # We can't rely on DIVERGENCE_LOCAL_HEAD here because:
  #   1. On the direct-call path (not via handle_push_divergence), it may be unset.
  #   2. After a resolver succeeds, it may point to a pre-resolver commit that no
  #      longer reflects the true "last known good" state if the resolver rewrote history.
  local _pre_rebase_head
  _pre_rebase_head=$(git rev-parse HEAD 2>/dev/null || true)

  # Track whether the final push must be a force push.
  # Set to true when the conflict resolver runs — the resolver may commit on
  # top of un-rebased HEAD rather than producing a fast-forward history, so
  # a plain push would be rejected. --force-with-lease is safe here: we still
  # verify that no third party has pushed since we last fetched.
  local _resolver_rewrote_history=false

  if ! _do_rebase "$branch_name"; then
    # Rebase failed (conflicts) — rebase has already been aborted and stash restored by _do_rebase().
    # In auto mode, attempt Claude-assisted conflict resolution before bailing.
    # attempt_claude_merge_resolution is provided by conflict-resolver.sh (issue #21).
    # Exit codes: 0=resolved, 1=failure, 5=usage-cap (batch-blocking — propagate up).
    if [ "$auto_mode" = "true" ] && declare -f attempt_claude_merge_resolution >/dev/null 2>&1; then
      _div_status "Attempting Claude-assisted conflict resolution..."
      local _resolver_result=0 _cr_start _cr_duration
      _cr_start=$(date +%s)
      _diag "CONFLICT_RESOLVER_START context=divergence issue=${_issue_number:-} pr=${_pr_number:-} branch=${branch_name}"
      # Pass --merge-target so the resolver resolves conflicts against origin/$branch_name
      # (the same ref that _do_rebase rebased against), not the default origin/main.
      # Without this, the resolver merges the wrong base and then force-pushes — clobbering
      # the foreign commits the divergence handler exists to preserve.
      attempt_claude_merge_resolution \
        --branch-name "$branch_name" \
        --issue-number "${_issue_number:-}" \
        --pr-number "${_pr_number:-}" \
        --merge-target "origin/$branch_name" || _resolver_result=$?
      _cr_duration=$(( $(date +%s) - _cr_start ))
      if [ "$_resolver_result" -eq 0 ]; then
        _diag "CONFLICT_RESOLVER context=divergence outcome=resolved issue=${_issue_number:-} pr=${_pr_number:-} duration_s=${_cr_duration}"
        _div_success "Conflicts resolved by Claude"
        # Resolver stages files but does NOT commit (see conflict-resolver.sh contract line 10).
        # However, the resolver's internal `git merge --no-edit` auto-commits when there are no
        # conflicting files (rebase auto-resolved or Claude accepted one side wholesale). In that
        # case the working tree is already clean and `git commit --no-edit` would exit non-zero
        # with "nothing to commit". Only commit if the tree is actually dirty.
        if [ -n "$(git status --porcelain)" ]; then
          if ! git commit --no-edit 2>/dev/null; then
            _div_error "Failed to commit resolved conflicts"
            git merge --abort 2>/dev/null || true
            return 1
          fi
        fi
        # Resolver committed on top of un-rebased HEAD (not a fast-forward from origin).
        # Mark that the final push must use --force-with-lease to avoid rejection.
        _resolver_rewrote_history=true
        # Fall through to verify + push below (rebase state is clean after resolution)
      elif [ "$_resolver_result" -eq 5 ]; then
        _diag "CONFLICT_RESOLVER context=divergence outcome=cap_hit issue=${_issue_number:-} pr=${_pr_number:-} duration_s=${_cr_duration}"
        # Usage cap reached — propagate so batch can abort cleanly (do NOT fall back to supervised)
        _div_error "Claude usage cap reached during conflict resolution — aborting batch"
        return 5
      else
        _diag "CONFLICT_RESOLVER context=divergence outcome=failed issue=${_issue_number:-} pr=${_pr_number:-} duration_s=${_cr_duration}"
        # Resolver could not resolve (exit 1) — fall through to auto bail below
        _div_warning "Claude could not resolve conflicts — manual intervention required"
        _div_error "Rebase failed with conflicts — blocking in auto mode"
        _send_divergence_notification "${_issue_number:-}" "${_pr_number:-}" "REBASE_CONFLICT" "Rebase conflicts on $branch_name"
        return 1
      fi
    elif [ "$auto_mode" = "true" ]; then
      # Canary: resolver function not available but we're in auto mode — emit a diagnostic
      # so wiring drift is visible in health reports.
      _diag "CONFLICT_RESOLVER context=divergence outcome=skipped_no_resolver issue=${_issue_number:-} pr=${_pr_number:-}"
      _div_error "Rebase failed with conflicts — blocking in auto mode"
      _send_divergence_notification "${_issue_number:-}" "${_pr_number:-}" "REBASE_CONFLICT" "Rebase conflicts on $branch_name"
      return 1
    else
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
  fi

  # Verify rebase didn't introduce silent semantic conflicts (tests pass)
  if ! verify_post_merge "."; then
    _div_warning "Rebase succeeded at git level but tests fail — possible semantic conflict"
    # Roll back to the pre-rebase HEAD snapshot captured at function entry.
    # Prefer _pre_rebase_head (always fresh, set from git rev-parse at entry) over
    # DIVERGENCE_LOCAL_HEAD (may be unset on direct-call path, or stale after resolver commits).
    local _rollback_target="${_pre_rebase_head:-${DIVERGENCE_LOCAL_HEAD:-}}"
    local _rollback_succeeded=false
    if [ -n "$_rollback_target" ]; then
      if git reset --hard "$_rollback_target"; then
        _rollback_succeeded=true
      else
        _div_warning "git reset --hard to $_rollback_target failed — working tree is still in post-rebase state"
      fi
    else
      _div_warning "No rollback target available — working tree left in post-rebase state"
    fi

    if [ "$auto_mode" = "true" ]; then
      _div_error "Post-rebase verification failed — blocking in auto mode"
      _send_divergence_notification "${_issue_number:-}" "${_pr_number:-}" "SEMANTIC_CONFLICT" \
        "Rebase succeeded but tests fail — silent semantic conflict"
      return 1
    fi

    # Supervised path.
    # If rollback failed, the working tree is still in post-rebase state (with test failures).
    # Offering "force-push local work" in that state would push the broken post-rebase result —
    # the opposite of what the user expects. Abort with a diagnostic instead of presenting
    # misleading options.
    if [ "$_rollback_succeeded" = "false" ]; then
      echo "" >&2
      echo "❌  Cannot recover automatically:" >&2
      echo "    Rebase introduced test failures AND rolling back to pre-rebase state failed." >&2
      echo "    Working tree is still in post-rebase state." >&2
      echo "" >&2
      echo "Manual recovery:" >&2
      echo "  1. Inspect:  git log --oneline -10" >&2
      echo "  2. Hard-reset to your original commit:" >&2
      echo "     git reset --hard ${_rollback_target:-<pre-rebase-sha>}" >&2
      echo "  3. Then: rite ${_issue_number:-<issue>} --dev-and-pr to retry" >&2
      return 1
    fi

    echo "" >&2
    echo "The rebase introduced test failures (silent semantic conflict)." >&2
    echo "Rolled back to pre-rebase state." >&2
    echo "Options:" >&2
    echo "  c) Force-push local (pre-rebase) work — discards the foreign commits that caused conflicts" >&2
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

  # Push the resolved branch.
  # Normal rebase path: plain push is safe (rebase onto origin always produces fast-forward).
  # Resolver path: the resolver commits on top of un-rebased HEAD, producing a diverged
  # history. --force-with-lease is required to overwrite the remote, but safe: it verifies
  # that no third party has pushed since we fetched (won't clobber unrelated commits).
  if [ "$_resolver_rewrote_history" = "true" ]; then
    _div_info "Resolver path: using --force-with-lease push (resolver may have diverged from origin)"
    if ! git push --force-with-lease origin "$branch_name"; then
      _div_error "Force-push failed after resolver — possible concurrent push; retry with: rite $branch_name"
      return 1
    fi
  else
    if ! git push origin "$branch_name"; then
      _div_error "Push failed after rebase"
      return 1
    fi
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
    if create_sharkrite_stash "divergence-handler: auto-stash before rebase"; then
      local _stashed=true
    fi
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
  PR_CURRENT_HEAD=$(gh_safe pr view "$pr_number" --json headRefOid --jq '.headRefOid' || true)
  PR_CURRENT_HEAD="${PR_CURRENT_HEAD:-}"

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
  repo_url=$(gh_safe repo view --json url --jq '.url' || true)
  repo_url="${repo_url:-}"

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
