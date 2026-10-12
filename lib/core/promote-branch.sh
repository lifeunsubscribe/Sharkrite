#!/bin/bash
# lib/core/promote-branch.sh
# Promote orchestrator: opens a promotion PR for an integration branch (base=main,
# head=<branch>), reviews it with local-review.sh, runs the full unfiltered suite,
# enforces the CRITICAL hard gate, squash-merges via SHA-verified REST, marks
# ledger entries promoted, deletes the integration branch, and posts a
# "Promoted to main in PR #N" comment on each constituent issue.
#
# Entry point: run_promote <branch>
# Exit 0 = promoted; exit 1 = any preflight/gate/merge failure.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if [ "${_RITE_PROMOTE_BRANCH_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_PROMOTE_BRANCH_LOADED=true

if [ -z "${RITE_LIB_DIR:-}" ]; then
  _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  source "$_self_dir/../utils/config.sh"
fi

# shellcheck source=/dev/null
source "$RITE_LIB_DIR/utils/colors.sh"
# shellcheck source=/dev/null
source "$RITE_LIB_DIR/utils/logging.sh"
# shellcheck source=/dev/null
source "$RITE_LIB_DIR/utils/gh-retry.sh"
# shellcheck source=/dev/null
source "$RITE_LIB_DIR/utils/git-helpers.sh"
# shellcheck source=/dev/null
source "$RITE_LIB_DIR/utils/blocker-rules.sh"
# shellcheck source=/dev/null
source "$RITE_LIB_DIR/utils/integration-ledger.sh"
# shellcheck source=/dev/null
source "$RITE_LIB_DIR/providers/provider-interface.sh"
# shellcheck source=/dev/null
source "$RITE_LIB_DIR/utils/promotion-composer.sh"

# ---------------------------------------------------------------------------
# _promote_field <ledger_line> <field_name>
# Extracts a tab-separated key=value field from a ledger line.
# Returns empty string (never fails) when the field is absent.
# ---------------------------------------------------------------------------
_promote_field() {
  local _pf_line="$1"
  local _pf_field="$2"
  printf '%s' "$_pf_line" | tr '\t' '\n' | grep "^${_pf_field}=" | cut -d= -f2- || true
}

# ---------------------------------------------------------------------------
# run_promote <branch>
# ---------------------------------------------------------------------------
run_promote() {
  local BRANCH="${1:?run_promote: branch argument required}"

  print_header "Promoting '$BRANCH' to main"
  echo ""

  # ── Phase 1: Preflight ───────────────────────────────────────────────────
  #
  # All preflight checks must be zero-side-effect: nothing pushed, no PR
  # created, no ledger written.  Any failure → exit 1 with a clear
  # remediation command the operator can copy-paste.

  print_step "Fetching latest state from origin..."
  git_fetch_safe origin main
  git_fetch_safe origin "$BRANCH" || {
    print_error "Branch '$BRANCH' not found on origin — nothing to promote"
    echo "  Create it first:  rite --branch $BRANCH <issue>" >&2
    exit 1
  }

  # Ledger must exist with >= 1 promoted=false entry.
  local _ledger_entries=""
  _ledger_entries=$(integration_ledger_entries "$BRANCH" 2>/dev/null || true)

  local _unpromoted_count=0
  if [ -n "$_ledger_entries" ]; then
    while IFS= read -r _entry_line; do
      [ -n "$_entry_line" ] || continue
      local _ep
      _ep=$(_promote_field "$_entry_line" "promoted" || true)
      if [ "${_ep:-}" = "false" ]; then
        _unpromoted_count=$(( _unpromoted_count + 1 ))
      fi
    done <<< "$_ledger_entries"
  fi

  if [ "$_unpromoted_count" -eq 0 ]; then
    print_error "Nothing to promote on '$BRANCH' — ledger has no unpromoted entries"
    echo "  If the branch has in-flight work, merge it first:" >&2
    echo "    rite --branch $BRANCH <issue>" >&2
    exit 1
  fi

  # Currency check: integration branch must not be behind main.
  # NEVER auto-sync in auto mode — sync is explicit by cluster design.
  local _behind=0
  _behind=$(git rev-list --count "origin/${BRANCH}..origin/main" 2>/dev/null || true)
  _behind="${_behind:-0}"

  if [ "$_behind" -gt 0 ]; then
    if [ "${RITE_SUPERVISED:-false}" = "true" ]; then
      print_warning "Branch '$BRANCH' is $_behind commit(s) behind main."
      echo "" >&2
      local _sync_answer="n"
      read -r -p "  Run 'rite --sync $BRANCH' now to sync? (y/n) " _sync_answer 2>&1 || true
      if [ "${_sync_answer:-n}" = "y" ] || [ "${_sync_answer:-n}" = "Y" ]; then
        # shellcheck source=/dev/null
        source "$RITE_LIB_DIR/utils/integration-sync.sh"
        sync_integration_branch "$BRANCH" || true
        # Re-fetch and re-check after sync
        git_fetch_safe origin "$BRANCH" || true
        _behind=$(git rev-list --count "origin/${BRANCH}..origin/main" 2>/dev/null || true)
        _behind="${_behind:-0}"
        if [ "$_behind" -gt 0 ]; then
          print_error "Branch '$BRANCH' is still $_behind commit(s) behind main after sync."
          echo "  Manually run: rite --sync $BRANCH" >&2
          exit 1
        fi
        print_success "Branch synced — proceeding with promotion"
      else
        print_error "Branch '$BRANCH' is $_behind commit(s) behind main."
        echo "  Sync it first: rite --sync $BRANCH" >&2
        exit 1
      fi
    else
      print_error "Branch '$BRANCH' is $_behind commit(s) behind main."
      echo "  Sync it first: rite --sync $BRANCH" >&2
      exit 1
    fi
  fi

  print_success "Preflight passed — $_unpromoted_count unpromoted ledger entry(ies)"
  echo ""

  # ── Phase 2: Promotion PR ────────────────────────────────────────────────

  print_step "Composing promotion PR body..."
  local _ctx_file=""
  _ctx_file=$(mktemp)
  gather_promotion_context "$BRANCH" "$_ctx_file" 2>/dev/null || true

  local _pr_body=""
  _pr_body=$(compose_promotion_pr_body "$BRANCH" "$_ctx_file" 2>/dev/null || true)
  rm -f "$_ctx_file"

  if [ -z "${_pr_body:-}" ]; then
    _pr_body="Promotion of integration branch '${BRANCH}' to main."
  fi

  # Check for an existing open promotion PR (re-run after aborted gate).
  # Reuse it rather than creating a duplicate.
  local PROMO_PR=""
  PROMO_PR=$(gh_safe pr list --base main --head "$BRANCH" --state open \
    --json number --jq '.[0].number // ""' 2>/dev/null || true)
  PROMO_PR="${PROMO_PR:-}"

  if [ -n "$PROMO_PR" ]; then
    print_info "Reusing existing promotion PR #$PROMO_PR — refreshing body"
    gh_safe pr edit "$PROMO_PR" --body "$_pr_body" 2>/dev/null || true
  else
    print_step "Creating promotion PR..."
    local _pr_title="Promote '$BRANCH' to main"
    PROMO_PR=$(gh_safe pr create \
      --base main \
      --head "$BRANCH" \
      --title "$_pr_title" \
      --body "$_pr_body" \
      --json number \
      --jq '.number' 2>/dev/null || true)
    PROMO_PR="${PROMO_PR:-}"
    if [ -z "$PROMO_PR" ]; then
      print_error "Failed to create promotion PR for branch '$BRANCH'"
      exit 1
    fi
    print_success "Created promotion PR #$PROMO_PR"
  fi
  echo ""

  # ── Phase 3: Review ──────────────────────────────────────────────────────

  print_step "Generating code review for promotion PR #$PROMO_PR..."
  "$RITE_LIB_DIR/core/local-review.sh" "$PROMO_PR" --post --auto
  echo ""

  # ── Phase 4: Full suite (unfiltered, in a temp worktree) ─────────────────
  #
  # The currency preflight guarantees origin/$BRANCH already contains main,
  # so testing the branch tip tests the effective merge result.
  #
  # The full suite runs inside a subshell ( cd "$_wt" && ... ) so the parent
  # shell never sits in a directory that later gets removed, avoiding the
  # CWD-after-worktree-removal hazard.

  print_step "Running full unfiltered test suite on branch '$BRANCH'..."
  local _wt="${RITE_WORKTREE_DIR}/promote-${BRANCH}"
  mkdir -p "$(dirname "$_wt")"

  # Remove a stale worktree from a prior aborted run
  if [ -d "$_wt" ]; then
    git worktree remove "$_wt" --force 2>/dev/null || rm -rf "$_wt"
  fi

  git worktree add "$_wt" "origin/$BRANCH"

  local _fs_exit=0
  ( cd "$_wt" && RITE_PROJECT_ROOT="$_wt" "$RITE_INSTALL_DIR/bin/rite-full-suite" ) \
    || _fs_exit=$?

  # Remove worktree regardless of suite outcome (before aborting on failure)
  git worktree remove "$_wt" --force 2>/dev/null || true

  if [ "$_fs_exit" -ne 0 ]; then
    print_error "Full suite failed on branch '$BRANCH'"
    echo "  Fix failing tests or lint on the integration branch, then re-run:" >&2
    echo "    rite --branch $BRANCH <issue>" >&2
    echo "    rite --promote $BRANCH" >&2
    exit 1
  fi
  print_success "Full suite passed"
  echo ""

  # ── Phase 5: CRITICAL hard gate ──────────────────────────────────────────

  print_step "Checking for CRITICAL review findings in PR #$PROMO_PR..."
  local _gate_exit=0
  detect_critical_issues "$PROMO_PR" || _gate_exit=$?
  if [ "$_gate_exit" -ne 0 ]; then
    print_error "Promotion blocked: CRITICAL findings in review of PR #$PROMO_PR"
    echo "  Fix as an issue on the integration branch:" >&2
    echo "    rite --branch $BRANCH <issue>" >&2
    echo "  Then re-promote:" >&2
    echo "    rite --promote $BRANCH" >&2
    exit 1
  fi
  print_success "No CRITICAL findings — hard gate passed"
  echo ""

  # ── Phase 6: SHA-verified squash merge (own path — never merge-pr.sh) ────
  #
  # This is a direct REST merge, not routed through merge-pr.sh.
  # merge-pr.sh's single-issue Closes extraction at :1062 would misfire on the
  # multi-Closes promotion PR body.  Own path is the behavioural contract.
  #
  # A 409/SHA-mismatch means someone pushed to the integration branch
  # mid-promote — abort with a re-run instruction, do NOT auto-resolve.

  print_step "Merging promotion PR #$PROMO_PR (squash, SHA-verified)..."
  local _expected_head=""
  _expected_head=$(gh_safe pr view "$PROMO_PR" --json headRefOid --jq '.headRefOid')
  local _repo_name=""
  _repo_name=$(gh_safe repo view --json nameWithOwner --jq '.nameWithOwner')

  local _merge_output="" _merge_exit=0
  _merge_output=$(gh_safe api "repos/$_repo_name/pulls/$PROMO_PR/merge" \
    -X PUT \
    -f merge_method=squash \
    -f sha="$_expected_head" 2>&1) || _merge_exit=$?

  if [ "$_merge_exit" -ne 0 ]; then
    if printf '%s' "${_merge_output:-}" | grep -qiE "Head branch was modified|409"; then
      print_error "Merge aborted: '$BRANCH' was pushed to during promotion (SHA mismatch)"
      echo "  Re-run: rite --promote $BRANCH" >&2
    else
      print_error "Merge failed (exit $_merge_exit)"
      if [ -n "${_merge_output:-}" ]; then
        echo "  $( printf '%s' "$_merge_output" | head -3)" >&2
      fi
    fi
    exit 1
  fi
  print_success "Promotion PR #$PROMO_PR squash-merged to main"
  echo ""

  # ── Phase 7: Post-merge ──────────────────────────────────────────────────
  #
  # Order matters:
  #   1. Mark ledger entries promoted=true FIRST (before branch deletion).
  #      Rationale: a crash after branch deletion but before ledger marking
  #      leaves promoted=false entries pointing at a deleted branch, wedging
  #      re-runs (preflight requires the branch).  With marking first, a crash
  #      after marking leaves only a benign orphaned branch — the re-run cleanly
  #      reports "nothing to promote".
  #   2. Remove temp worktree (already done above after full suite).
  #   3. Delete integration branch remote + local.
  #   4. Post per-issue "Promoted to main in PR #N" comments (best-effort).

  # Capture constituent issue list BEFORE marking (for the comments loop)
  local _constituent_issues=""
  if [ -n "$_ledger_entries" ]; then
    while IFS= read -r _entry_line; do
      [ -n "$_entry_line" ] || continue
      local _ep2
      _ep2=$(_promote_field "$_entry_line" "promoted" || true)
      [ "${_ep2:-}" = "false" ] || continue
      local _inum
      _inum=$(_promote_field "$_entry_line" "issue" || true)
      [ -n "${_inum:-}" ] || continue
      if [ -n "$_constituent_issues" ]; then
        _constituent_issues="${_constituent_issues} ${_inum}"
      else
        _constituent_issues="${_inum}"
      fi
    done <<< "$_ledger_entries"
  fi

  # Step 1: Mark all promoted=false ledger entries as promoted=true
  print_step "Marking ledger entries as promoted..."
  for _pn in ${_constituent_issues:-}; do
    integration_ledger_mark_promoted "$BRANCH" "$_pn" 2>/dev/null || true
  done

  # Step 2: Temp worktree already removed above (after full suite).

  # Step 3: Delete the integration branch (remote, then local)
  print_step "Deleting integration branch '$BRANCH'..."
  if git ls-remote --heads origin "$BRANCH" 2>/dev/null | grep -q "refs/heads/$BRANCH"; then
    if git push origin --delete "$BRANCH" 2>/dev/null; then
      print_info "Deleted remote branch origin/$BRANCH"
    else
      print_warning "Could not delete remote branch origin/$BRANCH"
    fi
  else
    print_info "Remote branch origin/$BRANCH already gone"
  fi
  git branch -D "$BRANCH" 2>/dev/null || true

  # Step 4: Best-effort per-issue promotion comments
  for _pn in ${_constituent_issues:-}; do
    gh_safe issue comment "$_pn" \
      --body "Promoted to main in PR #$PROMO_PR" 2>/dev/null || true
  done

  # Summary
  echo ""
  print_success "Branch '$BRANCH' promoted to main via PR #$PROMO_PR"
  if [ -n "$_constituent_issues" ]; then
    local _issue_display=""
    for _pn in $_constituent_issues; do
      _issue_display="${_issue_display} #${_pn}"
    done
    print_info "Issues promoted:${_issue_display}"
  fi

  return 0
}
