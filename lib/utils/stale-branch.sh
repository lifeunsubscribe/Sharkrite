#!/bin/bash
# lib/utils/stale-branch.sh
# Stale branch detection and handling.
# Checks how far a feature branch is behind origin/main and responds:
#   - Below threshold: rebase branch onto origin/main (replays commits on fresh main)
#   - At/above threshold: close PR, cleanup, signal fresh restart
#
# Threshold controlled by RITE_STALE_BRANCH_THRESHOLD (default: 10 commits).
# Rebase avoids false conflicts from merge when main has added files since branch creation.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f handle_stale_branch >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"
source "$RITE_LIB_DIR/utils/stash-manager.sh"

# Source logging for _diag structured diagnostic lines (no-op if already loaded)
if ! declare -f _diag >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/logging.sh"
fi

# Source gh retry wrapper if not already loaded (stash-manager.sh does not chain to it)
if ! declare -f gh_safe >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/gh-retry.sh"
fi

# Source post-merge verification utilities
if ! source "$RITE_LIB_DIR/utils/post-merge-verify.sh"; then
  echo "ERROR: Failed to source post-merge-verify.sh" >&2
  exit 1
fi

# Verify verify_post_merge function is available
if ! declare -f verify_post_merge >/dev/null 2>&1; then
  echo "ERROR: verify_post_merge function not available after sourcing post-merge-verify.sh" >&2
  exit 1
fi

# Source conflict resolver if available (provided by issue #21).
# Guarded: stale-branch works without it — resolver is an enhancement,
# not a hard dependency. When present, attempt_claude_merge_resolution()
# becomes available and is called on rebase/merge conflict bail paths.
if [ -f "$RITE_LIB_DIR/utils/conflict-resolver.sh" ]; then
  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"
fi

# ===================================================================
# INTERNAL: Base branch resolution
# ===================================================================

# _stale_resolve_base_branch PR_NUMBER
#
# Resolves the PR's actual base branch from the GitHub API.
# Falls back to "main" when the API is unreachable or the PR is not found.
# Validates the returned name against a safe character set to prevent
# path-traversal or injection attacks (same pattern as blocker-rules.sh).
# Sets: _STALE_BASE_BRANCH (callers should copy to a local var)
_stale_resolve_base_branch() {
  local pr_number="$1"
  _STALE_BASE_BRANCH="main"

  if [ -z "${pr_number:-}" ] || [ "$pr_number" = "null" ]; then
    return 0
  fi

  local _raw_base
  _raw_base=$(gh_safe pr view "$pr_number" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)
  _raw_base="${_raw_base:-main}"

  # Validate: only alphanumeric, '-', '_', '.', '/' are safe git ref characters.
  # Reject '..' sequences (path traversal) and any shell meta-characters.
  if ! echo "$_raw_base" | grep -qE '^[a-zA-Z0-9_./-]+$' || echo "$_raw_base" | grep -qF '..'; then
    _diag "STALE_BASE_BRANCH_INVALID pr=${pr_number} base_branch_raw=${_raw_base} fallback=main"
    _STALE_BASE_BRANCH="main"
    return 0
  fi

  _STALE_BASE_BRANCH="$_raw_base"
}

# ===================================================================
# PUBLIC: Detection
# ===================================================================

# get_commits_behind_main WORKTREE_PATH BASE_BRANCH
#
# Sets: COMMITS_BEHIND_MAIN (integer)
# Does NOT fetch — caller must ensure the remote base branch ref is up to date.
# BASE_BRANCH defaults to "main" when omitted.
get_commits_behind_main() {
  local worktree_path="$1"
  local base_branch="${2:-main}"
  COMMITS_BEHIND_MAIN=0

  local merge_base
  merge_base=$(git -C "$worktree_path" merge-base HEAD "origin/$base_branch" 2>/dev/null || echo "")

  if [ -z "$merge_base" ]; then
    return 0
  fi

  COMMITS_BEHIND_MAIN=$(git -C "$worktree_path" rev-list --count "${merge_base}..origin/$base_branch" 2>/dev/null || echo "0")
  return 0
}

# ===================================================================
# PUBLIC: Main entry point
# ===================================================================

# check_stale_branch WORKTREE_PATH PR_NUMBER ISSUE_NUMBER WORKFLOW_MODE
#
# Exit codes (see docs/architecture/exit-codes.md for the canonical table):
#   0  = continue workflow (branch is current, or was merged with main)
#   1  = abort (user chose abort, or unrecoverable error)
#   2  = foreign commits detected after push rejection — caller must re-enter Phase 2→3
#        (consistent with divergence-handler.sh exit 2 = "needs re-review")
#   5  = usage cap reached during conflict resolution (caller must abort batch)
#   11 = restarted fresh (PR closed, artifacts cleaned — caller must reset variables)
#        NOTE: 11, not 10. Exit 10 is reserved for batch-level "blocker detected".
check_stale_branch() {
  local worktree_path="$1"
  local pr_number="$2"
  local issue_number="$3"
  local workflow_mode="$4"

  local branch_name
  branch_name=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  if [ -z "$branch_name" ] || [ "$branch_name" = "main" ] || [ "$branch_name" = "master" ]; then
    return 0  # Not on a feature branch
  fi

  # Resolve the PR's actual base branch so stale-branch comparisons use the
  # correct upstream ref rather than hardcoding "main" (fixes #365/#420 anti-pattern).
  # Falls back to "main" when PR number is absent or the API call fails.
  _stale_resolve_base_branch "$pr_number"
  local base_branch="$_STALE_BASE_BRANCH"

  # Fetch the resolved base branch to ensure up-to-date count
  print_status "Checking branch freshness against $base_branch..."
  if ! git -C "$worktree_path" fetch origin "$base_branch" 2>/dev/null; then
    print_warning "Could not fetch origin/$base_branch — skipping stale branch check"
    return 0
  fi

  get_commits_behind_main "$worktree_path" "$base_branch"
  local behind="$COMMITS_BEHIND_MAIN"

  if [ "$behind" -eq 0 ]; then
    print_info "Branch is up to date with $base_branch"
    return 0
  fi

  local threshold="${RITE_STALE_BRANCH_THRESHOLD:-10}"

  if [ "$behind" -lt "$threshold" ]; then
    # Below threshold: rebase branch onto base (replays branch commits on top of current base)
    # This avoids false conflicts from merge when base has added new files since branch creation
    print_info "Branch is $behind commit(s) behind $base_branch (threshold: $threshold) — rebasing onto $base_branch"
    _stale_rebase_onto_main "$worktree_path" "$branch_name" "$workflow_mode" "$issue_number" "$pr_number" "$base_branch"
    return $?
  fi

  # At or above threshold
  print_warning "Branch is $behind commit(s) behind $base_branch (threshold: $threshold)"

  if [ "$workflow_mode" = "supervised" ]; then
    _stale_supervised_prompt "$worktree_path" "$pr_number" "$issue_number" "$branch_name" "$behind" "$base_branch"
    return $?
  else
    # Auto mode: close and restart
    print_status "Closing stale PR and restarting fresh..."
    _stale_close_and_cleanup "$pr_number" "$issue_number" "$worktree_path" "$branch_name" "$behind" "$base_branch"
    # Exit code 11: stale-branch restarted fresh — caller must reset all resume state
    # and fall through to phase 1 (distinct from exit 10 = blocker-detected in batch).
    # See docs/architecture/exit-codes.md for the canonical exit-code table.
    return 11
  fi
}

# ===================================================================
# PUBLIC: Close comment formatting
# ===================================================================

# format_stale_close_comment WORKTREE_PATH COMMITS_BEHIND [BASE_BRANCH]
# Outputs the PR close comment body to stdout.
# BASE_BRANCH defaults to "main" when omitted (backward compatible).
format_stale_close_comment() {
  local worktree_path="$1"
  local behind="$2"
  local base_branch="${3:-main}"

  local commit_messages
  commit_messages=$(git -C "$worktree_path" log --oneline "origin/$base_branch..HEAD" 2>/dev/null || echo "(none)")

  local changed_files
  changed_files=$(git -C "$worktree_path" diff --name-only "origin/$base_branch...HEAD" 2>/dev/null || echo "(none)")

  cat <<EOF
:arrows_counterclockwise: Closing: Branch is ${behind} commits behind ${base_branch}.

**Work summary:**
\`\`\`
${commit_messages}
\`\`\`

**Files modified:**
\`\`\`
${changed_files}
\`\`\`

This branch has diverged too far from ${base_branch} for safe integration.
A fresh implementation will be started from current ${base_branch}.
EOF
}

# ===================================================================
# INTERNAL: Classify foreign commits after push rejection
# ===================================================================

# _stale_rebase_and_push_foreign_commits BRANCH_NAME RETURN_CODE_ON_SUCCESS SUCCESS_MSG
#
# Shared helper used by supervised mode cases 'a' and 'b' in
# _stale_classify_after_push_rejection(). Both cases do an identical
# rebase-onto-remote + force-push sequence; they differ only in the return
# code and success message emitted on success.
#
# Arguments:
#   BRANCH_NAME          — branch to rebase and push
#   RETURN_CODE_ON_SUCCESS — exit code to return when push succeeds (0 or 2)
#   SUCCESS_MSG          — message passed to print_success on push success
#
# Exit codes:
#   RETURN_CODE_ON_SUCCESS — rebase and push both succeeded
#   1                      — rebase failed or push was rejected (another race)
_stale_rebase_and_push_foreign_commits() {
  local branch_name="$1"
  local return_code_on_success="$2"
  local success_msg="$3"

  if git rebase "origin/$branch_name" >/dev/null 2>&1; then
    if git push --force-with-lease origin "$branch_name" 2>/dev/null; then
      print_success "$success_msg"
      return "$return_code_on_success"
    else
      print_error "Push rejected after integrating foreign commits (another race?) — blocking"
      return 1
    fi
  else
    git rebase --abort 2>/dev/null || true
    print_error "Rebase onto origin/$branch_name failed — cannot integrate foreign commits"
    return 1
  fi
}

# _stale_classify_after_push_rejection WORKTREE_PATH BRANCH_NAME [ISSUE_NUMBER] [PR_NUMBER] [WORKFLOW_MODE] [BASE_BRANCH]
#
# Called when git push --force-with-lease is rejected after a successful rebase.
# A rejection means another client pushed to the remote branch between our rebase
# and our push attempt. We re-fetch and classify those commits before deciding
# whether to discard them (TRIVIAL) or trigger a re-review (FOREIGN).
#
# WORKTREE_PATH is required for verify_post_merge (test verification after TRIVIAL discard).
# BASE_BRANCH defaults to "main" when omitted.
#
# Exit codes:
#   0 = no foreign commits after re-fetch (remote was fast-forwarded to ours by another process)
#   1 = blocked (classification failed, rebase conflict, or second-race push rejection)
#   2 = foreign commits integrated and pushed — caller must re-enter Phase 2→3 review cycle
#       (consistent with divergence-handler.sh exit 2 = "needs re-review")
_stale_classify_after_push_rejection() {
  local worktree_path="$1"
  local branch_name="$2"
  local issue_number="${3:-}"
  local pr_number="${4:-}"
  local workflow_mode="${5:-auto}"
  local base_branch="${6:-main}"

  # Re-fetch to get the current remote state
  if ! git fetch origin "$branch_name" 2>/dev/null; then
    print_error "Could not fetch origin/$branch_name after push rejection"
    return 1
  fi

  local local_head
  local_head=$(git rev-parse HEAD 2>/dev/null || echo "")
  local remote_head
  remote_head=$(git rev-parse "origin/$branch_name" 2>/dev/null || echo "")

  if [ -z "$local_head" ] || [ -z "$remote_head" ]; then
    print_error "Cannot determine HEAD state after push rejection"
    return 1
  fi

  # Check if local is now ahead-of or equal to remote (e.g., another process already
  # resolved the same race and the remote is now pointing at our commit or a descendant).
  if [ "$local_head" = "$remote_head" ]; then
    print_success "Remote is now at our commit — no foreign commits to classify"
    return 0
  fi

  # Count commits on remote that local doesn't have
  local foreign_commits
  foreign_commits=$(git log --oneline "${local_head}..${remote_head}" 2>/dev/null || true)

  if [ -z "$foreign_commits" ]; then
    # Local is ahead of remote (no foreign commits) — safe to retry push
    print_info "No foreign commits found after re-fetch — remote may be behind ours"
    return 0
  fi

  local foreign_count
  foreign_count=$(echo "$foreign_commits" | grep -c '.' || true)
  print_warning "Found $foreign_count foreign commit(s) on remote after push rejection:"
  echo "$foreign_commits" | sed 's/^/  /' >&2

  # Use divergence-handler classification if available.
  # Guards against it being absent (e.g., in unit tests or stripped installs).
  if [ -f "$RITE_LIB_DIR/utils/divergence-handler.sh" ]; then
    # Source only if classify_foreign_commits is not already loaded
    if ! declare -f classify_foreign_commits >/dev/null 2>&1; then
      # shellcheck source=lib/utils/divergence-handler.sh
      source "$RITE_LIB_DIR/utils/divergence-handler.sh"
    fi
  fi

  if declare -f classify_foreign_commits >/dev/null 2>&1; then
    # Set fallback class: UNRELATED in auto mode (blocks), RELATED in supervised (user decides)
    if [ "$workflow_mode" = "supervised" ]; then
      _DIV_FALLBACK_CLASS="RELATED"
    else
      _DIV_FALLBACK_CLASS="UNRELATED"
    fi

    classify_foreign_commits "$branch_name" "$local_head" "$remote_head" "${issue_number:-}"
    local classification="${DIVERGENCE_CLASS:-UNRELATED}"

    case "$classification" in
      TRIVIAL)
        # Mainline sync or doc-only changes: safe to discard without re-review.
        # Rebase onto origin/$base_branch (not origin/$branch_name) to ensure the branch
        # remains up-to-date with the PR's base. Because the rebase base is origin/$base_branch —
        # not origin/$branch_name — the foreign commits on origin/$branch_name are
        # NOT replayed; they are discarded. The branch history is rewritten on top
        # of the base branch, so the final force-push drops the foreign commits from the remote.
        print_info "Foreign commits classified as TRIVIAL — discarding and rebasing onto origin/$base_branch"
        local _trivial_pre_rebase_head
        _trivial_pre_rebase_head=$(git rev-parse HEAD 2>/dev/null || true)
        if git rebase "origin/$base_branch" 2>/dev/null; then
          # Verify the rebase didn't introduce silent semantic conflicts (tests pass)
          if ! verify_post_merge "$worktree_path" "$_trivial_pre_rebase_head"; then
            git rebase --abort 2>/dev/null || true
            print_error "Post-rebase verification failed after discarding TRIVIAL commits — cannot proceed"
            return 1
          fi
          if git push --force-with-lease origin "$branch_name" 2>/dev/null; then
            print_success "Branch rebased onto origin/$base_branch (TRIVIAL foreign commits discarded)"
            return 0
          else
            print_error "Push still rejected after discarding TRIVIAL commits — another race occurred"
            return 1
          fi
        else
          git rebase --abort 2>/dev/null || true
          print_error "Rebase failed when discarding TRIVIAL foreign commits — cannot proceed"
          return 1
        fi
        ;;

      RELATED|UNRELATED)
        # FOREIGN commits: these need to go through the review cycle.
        # Before returning exit 2 we MUST integrate the foreign commits into local
        # HEAD so that the Phase 2 push (create-pr.sh:161-163) can succeed.
        # Without this, local HEAD remains behind origin/$branch_name, Phase 2
        # re-pushes, gets rejected again, and handle_push_divergence returns 1
        # (block) in auto mode — the re-review never happens.
        #
        # Strategy: rebase local onto origin/$branch_name to absorb the foreign
        # commits, then force-push so remote matches the combined history.
        # After that return 2 so the caller re-enters Phase 2→3 for review.
        print_warning "Foreign commits classified as $classification — integrating and requesting re-review"

        # Supervised mode: offer interactive options consistent with divergence-handler.sh
        # (_handle_related / _handle_unrelated menus). Auto mode proceeds automatically.
        if [ "$workflow_mode" = "supervised" ]; then
          echo "" >&2
          echo "$foreign_commits" | sed 's/^/  /' >&2
          echo "" >&2
          if [ "$classification" = "RELATED" ]; then
            # RELATED supervised: mirror divergence-handler.sh:_handle_related() options
            echo "These commits appear related to this issue." >&2
            echo "" >&2
            echo "Options:" >&2
            echo "  a) Pull and re-enter review cycle (generates new review for combined changes)" >&2
            echo "  b) Pull without review (you take responsibility for these commits)" >&2
            echo "  c) Overwrite remote with local work (force-push, discards foreign commits)" >&2
            echo "  d) Abort workflow" >&2
          else
            # UNRELATED supervised: mirror divergence-handler.sh:_handle_unrelated() options
            echo "These commits appear unrelated to this issue." >&2
            echo "" >&2
            echo "Options:" >&2
            echo "  c) Overwrite remote with local work (force-push, discards foreign commits)" >&2
            echo "  d) Abort workflow" >&2
          fi
          echo "" >&2
          local _prompt_opts
          _prompt_opts="[$([ "$classification" = "RELATED" ] && echo "a/b/c/d" || echo "c/d")]"
          printf "Choose %s: " "$_prompt_opts" >&2
          local _choice
          # Read the choice from stdin — consistent with every other supervised
          # prompt in this file (the `read -p ... -n 1 -r` blocks below). Reading
          # from /dev/tty is incorrect here: it diverges from the rest of the
          # codebase and fails ("Device not configured") in non-interactive
          # contexts (bats harness, piped stdin) where stdin is the input source.
          read -n 1 -r _choice
          echo >&2

          case "$_choice" in
            a|A)
              # Pull and re-enter review cycle (RELATED only — 'a' is not offered for UNRELATED)
              if [ "$classification" = "UNRELATED" ]; then
                print_error "Invalid choice for UNRELATED commits — aborting"
                return 1
              fi
              _stale_rebase_and_push_foreign_commits \
                "$branch_name" 2 \
                "Integrated $classification foreign commits and pushed — re-entering Phase 2→3 for review"
              return $?
              ;;
            b|B)
              # Pull without review (RELATED only — 'b' is not offered for UNRELATED)
              if [ "$classification" = "UNRELATED" ]; then
                print_error "Invalid choice for UNRELATED commits — aborting"
                return 1
              fi
              _stale_rebase_and_push_foreign_commits \
                "$branch_name" 0 \
                "Integrated $classification foreign commits and pushed (no re-review)"
              return $?
              ;;
            c|C)
              # Overwrite remote with local work (available for both RELATED and UNRELATED).
              # Re-fetch before --force-with-lease to refresh the remote-tracking ref;
              # without this, the lease is stale from the original push rejection and
              # the push will be rejected again in the exact push-race scenario this
              # option is designed to handle.
              print_warning "Force-pushing local work (discarding $classification foreign commits)..."
              if ! git fetch origin "$branch_name" 2>/dev/null; then
                print_warning "Could not fetch origin/$branch_name before force-push — lease may be stale"
              fi
              if git push --force-with-lease origin "$branch_name" 2>/dev/null; then
                print_success "Force-push succeeded — foreign commits discarded"
                return 0
              else
                print_error "Force-push failed"
                return 1
              fi
              ;;
            d|D|*)
              print_info "Workflow aborted by user"
              return 1
              ;;
          esac
        fi

        # Auto mode: integrate and re-enter review cycle automatically
        local _rebase_onto_remote_output
        if _rebase_onto_remote_output=$(git rebase "origin/$branch_name" 2>&1); then
          # Rebase succeeded — push the integrated history
          if git push --force-with-lease origin "$branch_name" 2>/dev/null; then
            print_success "Integrated $classification foreign commits and pushed — re-entering Phase 2→3 for review"
            return 2
          else
            # Another race: a third push happened while we were rebasing.
            # Bail — caller will see exit 1 and stop workflow.
            git rebase --abort 2>/dev/null || true
            print_error "Push still rejected after integrating $classification commits (another race?) — blocking"
            return 1
          fi
        else
          git rebase --abort 2>/dev/null || true
          print_error "Rebase onto origin/$branch_name failed when integrating $classification foreign commits"
          print_info "Run 'rite ${issue_number:-<issue>} --supervised' to resolve manually"
          return 1
        fi
        ;;

      *)
        print_error "Unknown classification '$classification' — blocking to be safe"
        return 1
        ;;
    esac
  else
    # divergence-handler not available: can't classify safely.
    # Block in both modes — better to require manual intervention than to silently
    # absorb unreviewed commits.
    print_error "divergence-handler.sh not available — cannot classify foreign commits after push rejection"
    print_info "Run 'rite ${issue_number:-<issue>} --supervised' to resolve manually"
    return 1
  fi
}

# ===================================================================
# INTERNAL: Rebase branch onto main
# ===================================================================

# _stale_rebase_onto_main WORKTREE_PATH BRANCH_NAME WORKFLOW_MODE [ISSUE_NUMBER] [PR_NUMBER] [BASE_BRANCH]
#
# Rebases the feature branch onto the PR's base branch (defaults to "main").
# Replays branch commits on top of the current base. Requires force-push with
# --force-with-lease after successful rebase (history is rewritten).
#
# ISSUE_NUMBER and PR_NUMBER are optional — used to invoke the conflict resolver on conflict.
# BASE_BRANCH defaults to "main" when omitted.
_stale_rebase_onto_main() {
  local worktree_path="$1"
  local branch_name="$2"
  local workflow_mode="$3"
  local issue_number="${4:-}"
  local pr_number="${5:-}"
  local base_branch="${6:-main}"

  cd "$worktree_path" || return 1

  # Verify the base branch ref exists before attempting rebase
  if ! git rev-parse --verify "origin/$base_branch" >/dev/null 2>&1; then
    print_error "origin/$base_branch does not exist — cannot rebase"
    print_info "Run 'git fetch origin $base_branch' or check remote configuration"
    return 1
  fi

  # Count commits to report progress - how many commits will be replayed
  local commits_ahead
  commits_ahead=$(git rev-list --count "origin/$base_branch..HEAD" 2>/dev/null || echo "0")

  # Save current HEAD before rebase in case we need to roll back after test failures
  local pre_rebase_head
  pre_rebase_head=$(git rev-parse HEAD)

  # Stash dirty worktree if needed
  local _stashed=false
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    print_status "Stashing uncommitted changes before rebase..."
    if create_sharkrite_stash "stale-branch: auto-stash before rebase $base_branch"; then
      _stashed=true
    fi
  fi

  print_status "Rebasing branch onto origin/$base_branch ($commits_ahead commits ahead, replaying onto fresh $base_branch)..."

  local rebase_output
  if rebase_output=$(git rebase "origin/$base_branch" 2>&1); then
    # Rebase succeeded — restore stash
    if [ "$_stashed" = true ]; then
      git stash pop 2>/dev/null || {
        print_warning "Stash pop had conflicts — stash preserved (run 'git stash pop' manually)"
      }
    fi

    # Verify rebase didn't introduce silent semantic conflicts (tests pass)
    if ! verify_post_merge "$worktree_path" "$pre_rebase_head"; then
      print_warning "Rebase succeeded at git level but tests fail — possible semantic conflict"
      git reset --hard "$pre_rebase_head" 2>/dev/null || true
      if [ "$workflow_mode" = "supervised" ]; then
        echo "" >&2
        echo "The rebase onto $base_branch introduced test failures." >&2
        echo "Options:" >&2
        echo "  c) Continue without rebasing onto $base_branch (keep working on stale branch)" >&2
        echo "  d) Abort workflow" >&2
        read -p "Choose [c/d]: " -n 1 -r >&2
        echo >&2
        case "$REPLY" in
          c|C) return 0 ;;
          *)   return 1 ;;
        esac
      else
        print_error "Post-rebase verification failed — cannot proceed in auto mode"
        print_info "Run 'rite \$issue_number --supervised' to resolve manually"
        return 1
      fi
    fi

    # Push with force-with-lease (history was rewritten by rebase)
    # --force-with-lease is safer than --force: only succeeds if remote hasn't changed
    if git push --force-with-lease origin "$branch_name" 2>/dev/null; then
      print_success "Branch rebased onto origin/$base_branch"
      return 0
    else
      # Push rejected: another client pushed to the remote branch between our
      # rebase and this push. Re-fetch and classify the new commits before
      # deciding what to do — silently absorbing unreviewed foreign commits
      # would bypass the review cycle.
      print_warning "Push rejected after rebase (force-with-lease) — re-fetching to classify foreign commits"
      _stale_classify_after_push_rejection "$worktree_path" "$branch_name" "${issue_number:-}" "${pr_number:-}" "$workflow_mode" "$base_branch"
      return $?
    fi
  else
    # Rebase had conflicts — abort it
    print_warning "Rebase onto $base_branch had conflicts"
    git rebase --abort 2>/dev/null || true

    # Restore stash
    if [ "$_stashed" = true ]; then
      git stash pop 2>/dev/null || true
    fi

    # In auto mode, attempt Claude-assisted conflict resolution before bailing.
    # attempt_claude_merge_resolution is provided by conflict-resolver.sh (issue #21).
    # Exit codes: 0=resolved, 1=failure, 5=usage-cap (batch-blocking — propagate up).
    if [ "$workflow_mode" != "supervised" ] && declare -f attempt_claude_merge_resolution >/dev/null 2>&1; then
      print_status "Attempting Claude-assisted conflict resolution..."
      local _resolver_result=0 _cr_start _cr_duration
      _cr_start=$(date +%s)
      _diag "CONFLICT_RESOLVER_START context=stale_rebase issue=${issue_number:-} pr=${pr_number:-} branch=${branch_name}"
      attempt_claude_merge_resolution "$branch_name" "${issue_number:-}" "${pr_number:-}" || _resolver_result=$?
      _cr_duration=$(( $(date +%s) - _cr_start ))
      if [ "$_resolver_result" -eq 0 ]; then
        _diag "CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=${issue_number:-} pr=${pr_number:-} duration_s=${_cr_duration}"
        print_success "Conflicts resolved by Claude"
        # Resolver stages files but does NOT commit (see conflict-resolver.sh contract line 10).
        # However, the resolver's internal `git merge --no-edit` auto-commits when there are no
        # conflicting files (rebase auto-resolved or Claude accepted one side wholesale). In that
        # case the index is already clean and `git commit --no-edit` would exit non-zero
        # with "nothing to commit". Only commit if the index has staged changes.
        #
        # Use `git diff --cached --quiet` (exits 1 = staged changes present, 0 = index clean)
        # rather than `git status --porcelain` which is overly broad: it also returns output
        # for untracked files (??) and unstaged changes — neither of which `git commit` would
        # include. Checking only the index avoids a spurious commit failure on those states.
        if ! git diff --cached --quiet 2>/dev/null; then
          if ! git commit --no-edit 2>/dev/null; then
            print_error "Failed to commit resolved conflicts"
            git merge --abort 2>/dev/null || true
            return 1
          fi
        fi
        # Verify resolution didn't introduce silent semantic conflicts (tests pass)
        if ! verify_post_merge "$worktree_path" "$pre_rebase_head"; then
          print_warning "Conflict resolution succeeded at git level but tests fail — possible semantic conflict"
          print_error "Post-resolution verification failed — cannot proceed in auto mode"
          return 1
        fi
        # Resolution committed (or already committed inside resolver) and verified — push with force-with-lease
        if git push --force-with-lease origin "$branch_name" 2>/dev/null; then
          print_success "Branch rebased onto origin/$base_branch (with conflict resolution)"
          return 0
        else
          print_error "Push failed after conflict resolution (force-with-lease rejected)"
          return 1
        fi
      elif [ "$_resolver_result" -eq 5 ]; then
        _diag "CONFLICT_RESOLVER context=stale_rebase outcome=cap_hit issue=${issue_number:-} pr=${pr_number:-} duration_s=${_cr_duration}"
        # Usage cap reached — propagate so batch can abort cleanly (do NOT fall back to supervised)
        print_error "Claude usage cap reached during conflict resolution — aborting batch"
        return 5
      else
        _diag "CONFLICT_RESOLVER context=stale_rebase outcome=failed issue=${issue_number:-} pr=${pr_number:-} duration_s=${_cr_duration}"
        # Resolver could not resolve (exit 1) — fall through to supervised/auto bail
        print_warning "Claude could not resolve conflicts — supervised mode required"
      fi
    elif [ "$workflow_mode" != "supervised" ]; then
      # Canary: resolver function not available but we're in auto mode — emit a diagnostic
      # so wiring drift is visible in health reports. If this appears, conflict-resolver.sh
      # was removed or uninstalled unexpectedly.
      _diag "CONFLICT_RESOLVER context=stale_rebase outcome=skipped_no_resolver issue=${issue_number:-} pr=${pr_number:-}"
    fi

    if [ "$workflow_mode" = "supervised" ]; then
      echo "" >&2
      echo "Conflicting with $base_branch. Options:" >&2
      echo "  c) Continue without rebasing onto $base_branch (not recommended)" >&2
      echo "  d) Abort workflow" >&2
      read -p "Choose [c/d]: " -n 1 -r >&2
      echo >&2
      case "$REPLY" in
        c|C) return 0 ;;
        *)   return 1 ;;
      esac
    else
      print_error "Rebase onto $base_branch failed (conflicts) — cannot proceed in auto mode"
      print_info "Run 'rite ${issue_number:-<issue>} --supervised' to resolve manually"
      return 1
    fi
  fi
}

# _stale_merge_main_legacy WORKTREE_PATH BRANCH_NAME WORKFLOW_MODE [ISSUE_NUMBER] [PR_NUMBER] [BASE_BRANCH]
#
# Legacy merge-based update (opt-in via supervised mode).
# Merges the PR's base branch into the feature branch. Same as GitHub "Update branch".
# No force-push needed — history isn't rewritten, regular git push works.
#
# ISSUE_NUMBER and PR_NUMBER are optional — used to invoke the conflict resolver on conflict.
# BASE_BRANCH defaults to "main" when omitted.
_stale_merge_main_legacy() {
  local worktree_path="$1"
  local branch_name="$2"
  local workflow_mode="$3"
  local issue_number="${4:-}"
  local pr_number="${5:-}"
  local base_branch="${6:-main}"

  cd "$worktree_path" || return 1

  # Stash dirty worktree if needed
  local _stashed=false
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    print_status "Stashing uncommitted changes before merge..."
    if create_sharkrite_stash "stale-branch: auto-stash before merge $base_branch"; then
      _stashed=true
    fi
  fi

  local merge_output
  if merge_output=$(git merge "origin/$base_branch" --no-edit 2>&1); then
    # Merge succeeded — restore stash
    if [ "$_stashed" = true ]; then
      git stash pop 2>/dev/null || {
        print_warning "Stash pop had conflicts — stash preserved (run 'git stash pop' manually)"
      }
    fi

    # Verify merge didn't introduce silent semantic conflicts (tests pass)
    if ! verify_post_merge "$worktree_path"; then
      print_warning "Merge succeeded at git level but tests fail — possible semantic conflict"
      git reset --hard HEAD~1 2>/dev/null || true
      if [ "$workflow_mode" = "supervised" ]; then
        echo "" >&2
        echo "The merge with $base_branch introduced test failures." >&2
        echo "Options:" >&2
        echo "  c) Continue without merging $base_branch (keep working on stale branch)" >&2
        echo "  d) Abort workflow" >&2
        read -p "Choose [c/d]: " -n 1 -r >&2
        echo >&2
        case "$REPLY" in
          c|C) return 0 ;;
          *)   return 1 ;;
        esac
      else
        print_error "Post-merge verification failed — cannot proceed in auto mode"
        print_info "Run 'rite \$issue_number --supervised' to resolve manually"
        return 1
      fi
    fi

    # Push the merge commit
    if git push origin "$branch_name" 2>/dev/null; then
      print_success "Merged $base_branch into branch and pushed"
      return 0
    else
      print_error "Push failed after merge"
      return 1
    fi
  else
    # Merge had conflicts — abort it
    print_warning "Merge with $base_branch had conflicts"
    git merge --abort 2>/dev/null || true

    # Restore stash
    if [ "$_stashed" = true ]; then
      git stash pop 2>/dev/null || true
    fi

    # In auto mode, attempt Claude-assisted conflict resolution before bailing.
    # attempt_claude_merge_resolution is provided by conflict-resolver.sh (issue #21).
    # Exit codes: 0=resolved, 1=failure, 5=usage-cap (batch-blocking — propagate up).
    if [ "$workflow_mode" != "supervised" ] && declare -f attempt_claude_merge_resolution >/dev/null 2>&1; then
      print_status "Attempting Claude-assisted conflict resolution..."
      local _resolver_result=0 _cr_start _cr_duration
      _cr_start=$(date +%s)
      _diag "CONFLICT_RESOLVER_START context=stale_merge issue=${issue_number:-} pr=${pr_number:-} branch=${branch_name}"
      attempt_claude_merge_resolution "$branch_name" "${issue_number:-}" "${pr_number:-}" || _resolver_result=$?
      _cr_duration=$(( $(date +%s) - _cr_start ))
      if [ "$_resolver_result" -eq 0 ]; then
        _diag "CONFLICT_RESOLVER context=stale_merge outcome=resolved issue=${issue_number:-} pr=${pr_number:-} duration_s=${_cr_duration}"
        print_success "Conflicts resolved by Claude"
        # Resolver stages files but does NOT commit (see conflict-resolver.sh contract line 10).
        # However, the resolver's internal `git merge --no-edit` auto-commits when there are no
        # conflicting files (rebase auto-resolved or Claude accepted one side wholesale). In that
        # case the index is already clean and `git commit --no-edit` would exit non-zero
        # with "nothing to commit". Only commit if the index has staged changes.
        #
        # Use `git diff --cached --quiet` (exits 1 = staged changes present, 0 = index clean)
        # rather than `git status --porcelain` which is overly broad: it also returns output
        # for untracked files (??) and unstaged changes — neither of which `git commit` would
        # include. Checking only the index avoids a spurious commit failure on those states.
        if ! git diff --cached --quiet 2>/dev/null; then
          if ! git commit --no-edit 2>/dev/null; then
            print_error "Failed to commit resolved conflicts"
            git merge --abort 2>/dev/null || true
            return 1
          fi
        fi
        # Verify resolution didn't introduce silent semantic conflicts (tests pass)
        if ! verify_post_merge "$worktree_path"; then
          print_warning "Conflict resolution succeeded at git level but tests fail — possible semantic conflict"
          print_error "Post-resolution verification failed — cannot proceed in auto mode"
          return 1
        fi
        # Resolution committed (or already committed inside resolver) and verified — regular push (merge doesn't rewrite history)
        if git push origin "$branch_name" 2>/dev/null; then
          print_success "Branch updated with $base_branch (conflict resolved)"
          return 0
        else
          print_error "Push failed after conflict resolution"
          return 1
        fi
      elif [ "$_resolver_result" -eq 5 ]; then
        _diag "CONFLICT_RESOLVER context=stale_merge outcome=cap_hit issue=${issue_number:-} pr=${pr_number:-} duration_s=${_cr_duration}"
        # Usage cap reached — propagate so batch can abort cleanly (do NOT fall back to supervised)
        print_error "Claude usage cap reached during conflict resolution — aborting batch"
        return 5
      else
        _diag "CONFLICT_RESOLVER context=stale_merge outcome=failed issue=${issue_number:-} pr=${pr_number:-} duration_s=${_cr_duration}"
        # Resolver could not resolve (exit 1) — fall through to supervised/auto bail
        print_warning "Claude could not resolve conflicts — supervised mode required"
      fi
    elif [ "$workflow_mode" != "supervised" ]; then
      # Canary: resolver function not available but we're in auto mode — emit a diagnostic
      # so wiring drift is visible in health reports.
      _diag "CONFLICT_RESOLVER context=stale_merge outcome=skipped_no_resolver issue=${issue_number:-} pr=${pr_number:-}"
    fi

    if [ "$workflow_mode" = "supervised" ]; then
      echo "" >&2
      echo "Conflicting with $base_branch. Options:" >&2
      echo "  c) Continue without merging $base_branch (not recommended)" >&2
      echo "  d) Abort workflow" >&2
      read -p "Choose [c/d]: " -n 1 -r >&2
      echo >&2
      case "$REPLY" in
        c|C) return 0 ;;
        *)   return 1 ;;
      esac
    else
      print_error "Merge with $base_branch failed (conflicts) — cannot proceed in auto mode"
      print_info "Run 'rite ${issue_number:-<issue>} --supervised' to resolve manually"
      return 1
    fi
  fi
}

# ===================================================================
# INTERNAL: Close PR and cleanup
# ===================================================================

# _stale_close_and_cleanup PR_NUMBER ISSUE_NUMBER WORKTREE_PATH BRANCH_NAME COMMITS_BEHIND [BASE_BRANCH]
#
# Inline cleanup (does NOT call undo-workflow.sh).
# Race condition safety: PR close and branch deletion are ordered deliberately.
# If PR close fails, remote branch deletion is skipped to avoid the inconsistent
# state where the branch is gone but the PR still appears open on GitHub.
# If PR close succeeds (or PR is already closed/merged), remote branch deletion proceeds.
# BASE_BRANCH defaults to "main" when omitted.
_stale_close_and_cleanup() {
  local pr_number="$1"
  local issue_number="$2"
  local worktree_path="$3"
  local branch_name="$4"
  local behind="$5"
  local base_branch="${6:-main}"

  # 1. Generate and post close comment
  local comment_body
  comment_body=$(format_stale_close_comment "$worktree_path" "$behind" "$base_branch")

  # Use temp file to avoid shell metacharacter issues in body
  local comment_file
  comment_file=$(mktemp)
  printf '%s' "$comment_body" > "$comment_file"
  if ! gh_safe pr comment "$pr_number" --body-file "$comment_file"; then
    if [ -n "${issue_number:-}" ]; then
      print_warning "Failed to post close comment for issue #$issue_number"
    else
      print_warning "Failed to post close comment on PR #$pr_number"
    fi
  fi
  rm -f "$comment_file"

  # 2. Close PR — track success to guard branch deletion below.
  # PR may already be closed/merged; treat those as success (idempotent).
  local _pr_close_ok=false
  local _pr_close_output
  local _pr_close_exit=0
  _pr_close_output=$(gh_safe pr close "$pr_number" 2>&1) || _pr_close_exit=$?
  if [ "${_pr_close_exit:-1}" -eq 0 ]; then
    _pr_close_ok=true
    if [ -n "${issue_number:-}" ]; then
      print_info "Closed PR for issue #$issue_number"
    else
      print_info "Closed PR #$pr_number"
    fi
  elif echo "$_pr_close_output" | grep -qiE "already closed|already merged|no open pull request|Pull request .* is already closed"; then
    # PR is not open — treat as already resolved, safe to proceed with branch delete.
    # NOTE: "not found" is intentionally excluded — it can match genuine API errors
    # (e.g. wrong PR number, network issue) and would falsely permit branch deletion
    # while the PR is still OPEN, re-introducing the race condition this code guards against.
    _pr_close_ok=true
    if [ -n "${issue_number:-}" ]; then
      print_info "Issue #$issue_number's PR is already closed/merged — continuing cleanup"
    else
      print_info "PR #$pr_number is already closed/merged — continuing cleanup"
    fi
  else
    if [ -n "${issue_number:-}" ]; then
      print_warning "Failed to close PR for issue #$issue_number — skipping remote branch deletion to avoid inconsistent state"
    else
      print_warning "Failed to close PR #$pr_number — skipping remote branch deletion to avoid inconsistent state"
    fi
    print_warning "  gh output: $(echo "$_pr_close_output" | head -1)"
  fi

  # 3. Exit worktree before removing it
  cd "$RITE_PROJECT_ROOT" 2>/dev/null || cd "$HOME"

  # 4. Remove worktree (local filesystem — safe regardless of PR close result)
  if git worktree remove "$worktree_path" --force 2>/dev/null; then
    print_info "Removed worktree: $(basename "$worktree_path")"
  else
    print_warning "Failed to remove worktree: $worktree_path"
  fi

  # 5. Delete local branch (local — safe regardless of PR close result)
  if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
    git branch -D "$branch_name" 2>/dev/null || true
    print_info "Deleted local branch: $branch_name"
  fi

  # 6. Delete remote branch — ONLY if PR was successfully closed (or already was closed).
  # Skipping when PR close failed prevents the race: closed PR + deleted branch leaves
  # GitHub in an inconsistent state where the PR page shows the branch as missing.
  if [ "$_pr_close_ok" = true ]; then
    if git push origin --delete "$branch_name" 2>/dev/null; then
      print_info "Deleted remote branch: $branch_name"
    else
      print_warning "Failed to delete remote branch: $branch_name (may already be deleted)"
    fi
  fi

  # 7. Remove session state file
  local state_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR:-.rite}/session-state-${issue_number}.json"
  if [ -f "$state_file" ]; then
    rm -f "$state_file"
    print_info "Removed session state"
  fi

  print_success "Stale branch cleanup complete — restarting fresh"
  return 0
}

# ===================================================================
# INTERNAL: Supervised mode prompt
# ===================================================================

# _stale_supervised_prompt WORKTREE_PATH PR_NUMBER ISSUE_NUMBER BRANCH_NAME COMMITS_BEHIND [BASE_BRANCH]
# BASE_BRANCH defaults to "main" when omitted.
_stale_supervised_prompt() {
  local worktree_path="$1"
  local pr_number="$2"
  local issue_number="$3"
  local branch_name="$4"
  local behind="$5"
  local base_branch="${6:-main}"

  # Gather info for report
  local last_commit_date
  last_commit_date=$(git -C "$worktree_path" log -1 --format='%ci' HEAD 2>/dev/null | cut -d' ' -f1)
  local commit_count
  commit_count=$(git -C "$worktree_path" log --oneline "origin/$base_branch..HEAD" 2>/dev/null | wc -l | tr -d ' ')

  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}Branch Staleness Report${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo "  Branch:        $branch_name"
  echo "  PR:            #$pr_number"
  echo "  Behind $base_branch:   $behind commits"
  echo "  Last activity: $last_commit_date"
  echo "  Branch work:   $commit_count commit(s)"
  echo ""
  print_warning "This branch is significantly behind $base_branch."
  echo ""
  echo "  Recommended: Close PR and restart fresh."
  echo "  The final merge is a squash, so merge commits don't pollute history."
  echo ""
  echo "Options:"
  echo "  1) Close PR and restart fresh (recommended)"
  echo "  2) Rebase branch onto $base_branch (recommended update method)"
  echo "  3) Merge $base_branch into branch (legacy, may cause false conflicts)"
  echo "  4) Continue without updating (not recommended)"
  echo "  5) Abort"
  echo ""
  read -p "Choose [1/2/3/4/5]: " -n 1 -r
  echo

  case "$REPLY" in
    1)
      print_status "Closing PR and cleaning up for fresh start..."
      _stale_close_and_cleanup "$pr_number" "$issue_number" "$worktree_path" "$branch_name" "$behind" "$base_branch"
      # Exit code 11: stale-branch restarted fresh (supervised path).
      # See docs/architecture/exit-codes.md for the canonical exit-code table.
      return 11
      ;;
    2)
      print_status "Rebasing branch onto $base_branch..."
      _stale_rebase_onto_main "$worktree_path" "$branch_name" "supervised" "$issue_number" "$pr_number" "$base_branch"
      return $?
      ;;
    3)
      print_status "Merging $base_branch into branch (legacy mode)..."
      _stale_merge_main_legacy "$worktree_path" "$branch_name" "supervised" "$issue_number" "$pr_number" "$base_branch"
      return $?
      ;;
    4)
      print_warning "Continuing without updating — code may be based on stale $base_branch"
      return 0
      ;;
    5|*)
      print_info "Workflow aborted by user"
      return 1
      ;;
  esac
}
