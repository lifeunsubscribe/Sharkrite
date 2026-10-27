#!/bin/bash
# lib/core/promote-branch.sh
# Promote orchestrator: opens a promotion PR for an integration branch (base=main,
# head=<branch>), reviews it with local-review.sh, runs the targeted verification
# gate (never a full suite — CLAUDE.md standing rule), enforces the CRITICAL hard
# gate, assesses the remaining findings NOW/LATER/DISMISSED and files only what
# survives, squash-merges via SHA-verified REST, marks ledger entries promoted,
# deletes the integration branch, and posts a "Promoted to main in PR #N"
# comment on each constituent issue.
#
# Classify-only by design: there is no fix loop at promote. Fixing on the
# integration branch would land code on main that skipped the per-issue review
# cycle, so findings are tracked as issues instead.
#
# Entry points:
#   run_promote <branch>         — full-branch promote (#1050)
#   run_promote <branch> <issue> — single-issue cherry-pick promote (#1273)
#   promote_single_issue <branch> <issue> — called internally by run_promote
# Exit 0 = promoted; exit 1 = any preflight/gate/merge failure.

set -euo pipefail

# Bash 4+ re-exec guard (issue #1361 fallout).
#
# This script carries a #!/bin/bash shebang, which on macOS is system bash
# 3.2. It sources lib/utils/test-gate.sh, which sources lib/utils/gate-runners.sh,
# and that file is not 3.2-parseable: it nests `case` statements (with their
# `;;` terminators) inside process substitutions, which 3.2's parser rejects
# outright. gate-runners.sh therefore refuses to load under 3.2 and every
# invocation of this script dies with "requires bash 4+" before doing any work.
#
# Re-exec under a bash 4+ interpreter when one is available. The guard matches
# the established pattern in batch-process-issues.sh, with one addition: it
# fires ONLY when this file is being EXECUTED, never when it is sourced.
# `exec "$_newer_bash" "$0" "$@"` in a sourced context would re-exec the
# CALLER with the wrong argument vector (see CLAUDE.md -> "macOS bash 3.2
# compatibility", the plan-issues.sh/docs-command.sh note).
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  for _newer_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$_newer_bash" ] && [ "$_newer_bash" != "${BASH:-}" ]; then
      exec "$_newer_bash" "$0" "$@"
    fi
  done
  echo "Error: requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi

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
# shellcheck source=/dev/null
source "$RITE_LIB_DIR/utils/markers.sh"
source "$RITE_LIB_DIR/utils/format-review.sh"

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
# _promote_title_matches_open_issue <finding_title> <issue_list>
#
# <issue_list> is "number:title" lines. Echoes the matching issue number, or
# nothing. Non-zero return means no match.
#
# This is deliberately the SAME Stage-1 heuristic assess-review-issues.sh uses
# for its ACTIONABLE_LATER dedup: lowercase, split on non-alphanumerics, and
# count tokens longer than 3 characters that appear as whole words in an
# existing title; 2 or more means the same finding. Reused rather than
# reinvented — a second, differently-tuned matcher would make the two paths
# disagree about what a duplicate is, which is worse than either rule alone.
# ---------------------------------------------------------------------------
_promote_title_matches_open_issue() {
  local _ft="$1"
  local _issue_list="$2"
  [ -n "${_ft:-}" ] || return 1
  [ -n "${_issue_list:-}" ] || return 1

  local _ft_words
  _ft_words=$(printf '%s' "$_ft" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ' || true)
  [ -n "${_ft_words// /}" ] || return 1

  local _ei_num _ei_title _ei_words _mc _w
  while IFS=: read -r _ei_num _ei_title; do
    [ -n "${_ei_num:-}" ] || continue
    [ -n "${_ei_title:-}" ] || continue
    _ei_words=$(printf '%s' "$_ei_title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ' || true)
    _mc=0
    for _w in $_ft_words; do
      if [ "${#_w}" -gt 3 ] && printf '%s' "$_ei_words" | grep -qw "$_w" 2>/dev/null; then
        _mc=$((_mc + 1))
      fi
    done
    if [ "$_mc" -ge 2 ]; then
      printf '%s' "$_ei_num"
      return 0
    fi
  done <<< "$_issue_list"
  return 1
}

# ---------------------------------------------------------------------------
# _promote_strip_tracked_now_blocks <assessment_text> <titles_file>
#
# Echoes the assessment with every "### <title> - ACTIONABLE_NOW" block whose
# title appears in <titles_file> removed. Blocks for other states are kept
# verbatim, so the aggregate issue still reads as a complete assessment minus
# the findings that are already on file.
# ---------------------------------------------------------------------------
_promote_strip_tracked_now_blocks() {
  local _txt="$1"
  local _titles_file="$2"
  printf '%s' "$_txt" | awk -v dupf="$_titles_file" '
    BEGIN { skip = 0; while ((getline l < dupf) > 0) if (length(l)) dup[l] = 1 }
    /^### / {
      t = $0; sub(/^### /, "", t)
      state = t; sub(/^.* - /, "", state)
      base = t;  sub(/ - [A-Z_]+$/, "", base)
      skip = (state == "ACTIONABLE_NOW" && (base in dup)) ? 1 : 0
      if (!skip) print
      next
    }
    !skip { print }
  ' || true
}

# ---------------------------------------------------------------------------
# promote_single_issue <branch> <issue>
#
# Cherry-picks ONE staged ledger SHA onto a temp branch off origin/main and
# merges it through its own gated PR.
#
# Design: a cherry-pick conflict is the deterministic signal that the issue is
# entangled with unpromoted work — abort verbosely, never force-resolve.
# ---------------------------------------------------------------------------
promote_single_issue() {
  local _si_branch="${1:?promote_single_issue: branch argument required}"
  local _si_issue="${2:?promote_single_issue: issue argument required}"

  print_header "Single-issue promote: #${_si_issue} from '${_si_branch}' to main"
  echo ""

  # ── Ledger lookup ─────────────────────────────────────────────────────────

  print_step "Looking up issue #${_si_issue} in ledger for '${_si_branch}'..."
  local _si_entries=""
  _si_entries=$(integration_ledger_entries "$_si_branch" 2>/dev/null || true)

  if [ -z "${_si_entries:-}" ]; then
    print_error "No ledger found for branch '${_si_branch}'"
    echo "  Staged issues for this branch: (none)" >&2
    exit 1
  fi

  # Walk entries to find the target issue
  local _si_sha="" _si_pr="" _si_promoted=""
  local _si_staged_nums=""
  while IFS= read -r _si_line; do
    [ -n "${_si_line:-}" ] || continue
    local _si_fissue
    _si_fissue=$(_promote_field "$_si_line" "issue" || true)
    local _si_fpromoted
    _si_fpromoted=$(_promote_field "$_si_line" "promoted" || true)
    if [ "${_si_fissue:-}" = "$_si_issue" ]; then
      _si_sha=$(_promote_field "$_si_line" "sha" || true)
      _si_pr=$(_promote_field "$_si_line" "pr" || true)
      _si_promoted="${_si_fpromoted:-false}"
    fi
    if [ "${_si_fpromoted:-}" = "false" ]; then
      _si_staged_nums="${_si_staged_nums:+${_si_staged_nums} }${_si_fissue}"
    fi
  done <<< "$_si_entries"

  if [ -z "${_si_sha:-}" ]; then
    print_error "Issue #${_si_issue} not found in the ledger for '${_si_branch}'"
    echo "  Staged issues on this branch: ${_si_staged_nums:-none}" >&2
    exit 1
  fi

  # Idempotent: already promoted → exit 0 with info
  if [ "${_si_promoted:-}" = "true" ]; then
    print_info "Issue #${_si_issue} was already promoted from '${_si_branch}' — nothing to do"
    return 0
  fi

  print_success "Found ledger entry: issue=#${_si_issue} pr=#${_si_pr} sha=${_si_sha}"
  echo ""

  # ── Fetch ──────────────────────────────────────────────────────────────────

  print_step "Fetching latest state from origin..."
  git_fetch_safe origin main
  git_fetch_safe origin "$_si_branch" || {
    print_error "Failed to fetch '$_si_branch' from origin — SHA ${_si_sha} may not exist locally"
    echo "  Re-run after checking network: rite --promote ${_si_branch} ${_si_issue}" >&2
    exit 1
  }
  # Guard: the ledger SHA must exist locally after fetching the integration branch.
  if ! git cat-file -e "$_si_sha" 2>/dev/null; then
    print_error "Ledger SHA ${_si_sha} not found after fetching '${_si_branch}' — ledger may be stale"
    echo "  Re-run: rite --promote ${_si_branch} ${_si_issue}" >&2
    exit 1
  fi

  # ── Temp worktree off main ─────────────────────────────────────────────────

  local _si_wt_name="promote-${_si_branch}-i${_si_issue}"
  local _si_wt="${RITE_WORKTREE_DIR}/${_si_wt_name}"

  # Clean up any leftover temp worktree from a prior aborted run
  if [ -d "$_si_wt" ]; then
    git worktree remove "$_si_wt" --force 2>/dev/null || rm -rf "$_si_wt"
    git branch -D "$_si_wt_name" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
  fi
  mkdir -p "$(dirname "$_si_wt")"

  print_step "Creating temp worktree '${_si_wt_name}' off origin/main..."
  git worktree add -b "$_si_wt_name" "$_si_wt" origin/main

  # ── Cherry-pick ────────────────────────────────────────────────────────────

  print_step "Cherry-picking ${_si_sha} (issue #${_si_issue})..."
  local _si_cp_exit=0
  local _si_cp_stderr=""
  _si_cp_stderr=$( cd "$_si_wt" && git cherry-pick "$_si_sha" 2>&1 ) || _si_cp_exit=$?

  if [ "$_si_cp_exit" -ne 0 ]; then
    # Distinguish conflict (entanglement) from other failures.
    # CHERRY_PICK_HEAD exists when a conflict left cherry-pick in progress.
    # In a linked worktree .git is a file pointer, so CHERRY_PICK_HEAD lives at
    # the path git itself reports — use rev-parse --git-path to find it.
    local _si_is_conflict=false
    local _si_cp_head_path=""
    _si_cp_head_path=$( cd "$_si_wt" && git rev-parse --git-path CHERRY_PICK_HEAD 2>/dev/null || true )
    if [ -n "${_si_cp_head_path:-}" ] && [ -f "${_si_cp_head_path}" ]; then
      _si_is_conflict=true
    fi
    ( cd "$_si_wt" && git cherry-pick --abort 2>/dev/null || true )
    git worktree remove "$_si_wt" --force 2>/dev/null || rm -rf "$_si_wt"
    git branch -D "$_si_wt_name" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
    if [ "$_si_is_conflict" = "true" ]; then
      print_error "Issue #${_si_issue} is entangled with unpromoted issues on '${_si_branch}' — its squash commit does not apply cleanly to main. Promote the full branch (rite --promote ${_si_branch}) or resolve manually."
    else
      print_error "Cherry-pick of ${_si_sha} failed (exit ${_si_cp_exit}) — not a merge conflict"
      if [ -n "${_si_cp_stderr:-}" ]; then
        echo "  $(printf '%s' "$_si_cp_stderr" | head -3)" >&2
      fi
      echo "  Check that the SHA exists and re-run: rite --promote ${_si_branch} ${_si_issue}" >&2
    fi
    exit 1
  fi

  print_success "Cherry-pick applied cleanly"
  echo ""

  # ── Targeted gate ─────────────────────────────────────────────────────────

  print_step "Running targeted verification gate on cherry-picked commit..."
  if ! declare -f run_test_gate >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$RITE_LIB_DIR/utils/test-gate.sh"
    if ! declare -f run_test_gate >/dev/null 2>&1; then
      print_error "run_test_gate not defined after sourcing test-gate.sh — gate cannot run"
      exit 1
    fi
  fi
  local _si_gate_exit=0
  local _si_gate_json="${_si_wt}/.rite-si-promote-gate.json"
  ( cd "$_si_wt" \
      && RITE_PROJECT_ROOT="$_si_wt" \
         RITE_TEST_GATE_DIFF_BASE=origin/main \
         PR_NUMBER="" \
         run_test_gate "$_si_gate_json" "$_si_wt" ) \
    || _si_gate_exit=$?

  if [ "$_si_gate_exit" -ne 0 ]; then
    if [ -s "$_si_gate_json" ]; then
      mkdir -p "${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}"
      cp "$_si_gate_json" \
        "${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}/si-promote-gate-${_si_branch//\//-}-i${_si_issue}.json" 2>/dev/null || true
    fi
    git worktree remove "$_si_wt" --force 2>/dev/null || rm -rf "$_si_wt"
    git branch -D "$_si_wt_name" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
    print_error "Targeted gate failed for issue #${_si_issue} — no PR created"
    echo "  Fix the failing tests on '${_si_branch}' first:" >&2
    echo "    rite --branch ${_si_branch} ${_si_issue}" >&2
    exit 1
  fi
  print_success "Targeted verification gate passed"
  echo ""

  # ── Push temp branch + create PR ──────────────────────────────────────────

  print_step "Pushing temp branch '${_si_wt_name}'..."
  ( cd "$_si_wt" && git push origin "${_si_wt_name}" )

  local _si_pr_body
  _si_pr_body="Cherry-picked from integration branch '${_si_branch}' (original PR #${_si_pr}, ledger SHA ${_si_sha}).

Closes #${_si_issue}"

  local _si_promo_pr_url=""
  _si_promo_pr_url=$(gh_safe pr create \
    --base main \
    --head "$_si_wt_name" \
    --title "Single-issue promote: #${_si_issue} from '${_si_branch}'" \
    --body "$_si_pr_body" 2>/dev/null || true)
  local _si_promo_pr=""
  _si_promo_pr=$(printf '%s' "${_si_promo_pr_url:-}" | grep -oE '[0-9]+$' || true)
  if [ -z "${_si_promo_pr:-}" ]; then
    git worktree remove "$_si_wt" --force 2>/dev/null || rm -rf "$_si_wt"
    git branch -D "$_si_wt_name" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
    print_error "Failed to create promotion PR for issue #${_si_issue}"
    exit 1
  fi
  print_success "Created promotion PR #${_si_promo_pr}"
  echo ""

  # ── Merge through normal path ──────────────────────────────────────────────
  #
  # Route through merge-pr.sh (hard gates apply). The single-issue PR carries
  # exactly one Closes #N, so merge-pr.sh's head -1 extraction is correct here.

  local _MERGE_PR="${RITE_LIB_DIR}/core/merge-pr.sh"
  local _si_merge_exit=0
  # --allow-main-base: the single-issue promotion PR always targets main;
  # without this flag, merge-pr.sh's integration-branch guard refuses the merge
  # because the session's resolved target branch is the integration branch.
  bash "$_MERGE_PR" "$_si_promo_pr" --auto --allow-main-base || _si_merge_exit=$?

  # CWD-after-worktree-removal contract: merge-pr.sh removes the worktree;
  # cd back to project root before any subsequent gh/git call.
  cd "$RITE_PROJECT_ROOT" || cd /

  if [ "$_si_merge_exit" -ne 0 ]; then
    print_error "Merge failed for promotion PR #${_si_promo_pr} (exit ${_si_merge_exit})"
    echo "  The temp branch '${_si_wt_name}' and PR #${_si_promo_pr} remain for inspection." >&2
    exit 1
  fi

  # ── Post-merge bookkeeping ─────────────────────────────────────────────────

  # Mark the ledger entry promoted=true in place.
  # A failure here leaves the ledger at promoted=false for a commit already on
  # main — rite --status would show the issue still awaiting promotion and a
  # retry would hit the empty-cherry-pick path. Surface the failure explicitly.
  if ! integration_ledger_mark_promoted "$_si_branch" "$_si_issue"; then
    local _ledger_path="${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}/integration-branches/${_si_branch}.log"
    print_error "Ledger mark-promoted failed for issue #${_si_issue} on '${_si_branch}' — PR #${_si_promo_pr} was merged but the ledger was NOT updated"
    echo "  Manual fix: edit ${_ledger_path} and set promoted=true on the issue=${_si_issue} line" >&2
  fi

  # Post per-issue promotion comment (already-closed is a no-op on GitHub)
  gh_safe issue comment "$_si_issue" \
    --body "Promoted to main in PR #${_si_promo_pr}" 2>/dev/null || true

  # Clean up temp worktree and branch (merge-pr.sh may have already done this)
  git worktree remove "$_si_wt" --force 2>/dev/null || true
  git branch -D "$_si_wt_name" 2>/dev/null || true
  git worktree prune 2>/dev/null || true

  echo ""
  print_success "Issue #${_si_issue} promoted to main via PR #${_si_promo_pr}"
  return 0
}

# ---------------------------------------------------------------------------
# run_promote <branch> [issue]
#
# With no issue arg: full-branch promote (#1050 path, byte-identical).
# With an issue arg: routes to promote_single_issue.
# ---------------------------------------------------------------------------
run_promote() {
  local BRANCH="${1:?run_promote: branch argument required}"
  local _si_issue_arg="${2:-}"

  # Single-issue path: explicit issue number → cherry-pick promote
  if [ -n "${_si_issue_arg:-}" ]; then
    promote_single_issue "$BRANCH" "$_si_issue_arg"
    return $?
  fi

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
    local _lsremote_exit=0
    local _lsremote_out=""
    _lsremote_out=$(git ls-remote --heads origin "$BRANCH" 2>/dev/null) || _lsremote_exit=$?
    if [ "$_lsremote_exit" -ne 0 ] || printf '%s' "${_lsremote_out:-}" | grep -q "refs/heads/${BRANCH}$"; then
      print_error "Failed to fetch '$BRANCH' from origin — network error?"
      echo "  Re-run after checking network:  rite --promote $BRANCH" >&2
    else
      print_error "Branch '$BRANCH' not found on origin — nothing to promote"
      echo "  Create it first:  rite --branch $BRANCH <issue>" >&2
    fi
    exit 1
  }

  # Capture branch HEAD SHA at preflight; passed to the merge API in Phase 6 so any
  # push during review/suite triggers a 409 abort rather than merging unreviewed code.
  local _branch_sha=""
  _branch_sha=$(git rev-parse --verify --quiet "origin/$BRANCH" 2>/dev/null || true)

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
        # Re-fetch and re-check after sync; also re-capture SHA so Phase 6 sees the post-sync tip
        git_fetch_safe origin "$BRANCH" || true
        _branch_sha=$(git rev-parse --verify --quiet "origin/$BRANCH" 2>/dev/null || true)
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
    print_warning "Promotion PR body composer failed — using placeholder body (re-run after fixing composer)"
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
    local _pr_url=""
    _pr_url=$(gh_safe pr create \
      --base main \
      --head "$BRANCH" \
      --title "$_pr_title" \
      --body "$_pr_body" 2>/dev/null || true)
    PROMO_PR=$(printf '%s' "${_pr_url:-}" | grep -oE '[0-9]+$' || true)
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

  print_step "Running targeted verification gate on branch '$BRANCH'..."
  local _wt="${RITE_WORKTREE_DIR}/promote-${BRANCH}"
  mkdir -p "$(dirname "$_wt")"

  # Remove a stale worktree from a prior aborted run
  if [ -d "$_wt" ]; then
    git worktree remove "$_wt" --force 2>/dev/null || rm -rf "$_wt"
  fi
  git worktree prune 2>/dev/null || true

  git worktree add "$_wt" "origin/$BRANCH"

  # Targeted, not full. A full unfiltered suite never runs inside a workflow
  # (CLAUDE.md standing rule) — the overnight pipeline owns that. Here the
  # correct scope is everything the branch changed relative to main, which is
  # exactly what the gate's targeted selection computes from that diff base.
  # It also avoids the 20+ min cost that made a promote indistinguishable from
  # a hang, and the parallel load that produced phantom failures.
  # Lazy, guarded load: a top-level source would hard-fail in environments that
  # stub RITE_LIB_DIR (the promote tests build a minimal fake lib), and the gate
  # is only needed on this path.
  if ! declare -f run_test_gate >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$RITE_LIB_DIR/utils/test-gate.sh"
    if ! declare -f run_test_gate >/dev/null 2>&1; then
      print_error "run_test_gate not defined after sourcing test-gate.sh — gate cannot run"
      exit 1
    fi
  fi
  local _fs_exit=0
  local _fs_gate_json="${_wt}/.rite-promote-gate.json"
  ( cd "$_wt" \
      && RITE_PROJECT_ROOT="$_wt" \
         RITE_TEST_GATE_DIFF_BASE="origin/main" \
         PR_NUMBER="${PROMO_PR:-}" \
         run_test_gate "$_fs_gate_json" "$_wt" ) \
    || _fs_exit=$?

  # Salvage the verdict before the worktree is removed (#1210) — otherwise the
  # only record of what failed dies with the directory.
  if [ "$_fs_exit" -ne 0 ] && [ -s "$_fs_gate_json" ]; then
    mkdir -p "${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}"
    cp "$_fs_gate_json" \
      "${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}/promote-gate-${BRANCH//\//-}.json" 2>/dev/null || true
    print_error "Failing items (verdict saved to .rite/state/promote-gate-${BRANCH//\//-}.json):"
    jq -r '((.tests // [])[:20][] | "  - test: " + (.test_name // "unknown")),
           ((.lint  // [])[:20][] | "  - lint: " + (.file // "?") + ":" + ((.line // 0)|tostring) + " " + (.rule // ""))' \
      "$_fs_gate_json" >&2 2>/dev/null || true
  fi

  # Remove worktree regardless of suite outcome (before aborting on failure)
  git worktree remove "$_wt" --force 2>/dev/null || true

  if [ "$_fs_exit" -ne 0 ]; then
    print_error "Verification gate failed on branch '$BRANCH'"
    echo "  Fix failing tests or lint on the integration branch, then re-run:" >&2
    echo "    rite --branch $BRANCH <issue>" >&2
    echo "    rite --promote $BRANCH" >&2
    exit 1
  fi
  print_success "Targeted verification gate passed"
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

  # ── Phase 5b: Assess the promotion review (#1278) ────────────────────────
  #
  # The promotion review is a FRESH audit. The promotion PR has no prior
  # review, so local-review.sh emits no fix-loop verification context and the
  # reviewer re-raises findings each constituent issue's own review loop
  # already judged — DISMISSED ones especially, since "dismissed" is not
  # "fixed" and the code still reads the same way. Running the standard
  # assessor here applies that judgment once more and, critically, its Stage-2
  # cross-PR dedup search matches the per-issue follow-ups already on file
  # instead of filing them a second time. That search is deliberately
  # unqualified here (see RITE_ISSUE_NUMBER below).
  #
  # Division of labour:
  #   ACTIONABLE_LATER → per-item issues filed by the assessor (deduped)
  #   ACTIONABLE_NOW   → one aggregated issue filed below. Still no fix loop:
  #                      fixing on the integration branch would land code on
  #                      main that skipped the per-issue review cycle.
  #   DISMISSED        → dropped
  #
  # Best-effort: promotion has already passed its gates, so nothing here may
  # block, retry, or fail the merge. Every failure path falls through to the
  # deterministic raw-review capture below — the pre-assessment behaviour —
  # so a broken assessor degrades to "captures more than needed", never to
  # "loses findings".
  local _promo_review
  _promo_review=$(gh_safe pr view "$PROMO_PR" --json comments \
    --jq "[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | sort_by(.createdAt) | reverse | .[0].body" 2>/dev/null || true)

  local _promo_assessed=false
  local _promo_assess_out=""
  local _promo_later_count=0
  if [ -n "${_promo_review:-}" ] && [ -f "$RITE_LIB_DIR/core/assess-review-issues.sh" ]; then
    print_step "Assessing promotion review findings (NOW/LATER/DISMISSED)..."
    local _promo_review_file
    _promo_review_file=$(mktemp)
    printf '%s' "$_promo_review" > "$_promo_review_file"
    local _promo_items_file
    _promo_items_file=$(mktemp)
    local _promo_assess_exit=0
    # RITE_ISSUE_NUMBER is deliberately empty. A promotion has no single source
    # issue, and the empty value is exactly what widens the assessor's Stage-2
    # dedup search from "same source issue" to "any open follow-up" — the scope
    # a promotion needs, since the duplicates it must avoid were filed under
    # the constituent issues, not under this PR.
    # RITE_RETRY_COUNT=0 keeps first-pass rules (the retry-pass convergence
    # rules do not apply to a PR whose first review this is).
    # The timeout must be at least 600s: a promotion review spans every
    # constituent issue and so carries several times the findings. Never let a
    # per-issue RITE_ASSESSMENT_TIMEOUT=300 set by the outer env shrink it.
    local _promo_assess_timeout=600
    if [ "${RITE_ASSESSMENT_TIMEOUT:-0}" -gt 600 ] 2>/dev/null; then
      _promo_assess_timeout="${RITE_ASSESSMENT_TIMEOUT}"
    fi
    _promo_assess_out=$(
      RITE_ISSUE_NUMBER="" \
      RITE_RETRY_COUNT=0 \
      RITE_REVIEW_JUST_POSTED=true \
      RITE_PER_ITEM_ISSUES_FILE="$_promo_items_file" \
      RITE_ASSESSMENT_TIMEOUT="${_promo_assess_timeout}" \
      "$RITE_LIB_DIR/core/assess-review-issues.sh" "$PROMO_PR" "$_promo_review_file" --auto
    ) || _promo_assess_exit=$?
    rm -f "$_promo_review_file"

    _promo_later_count=$(grep -c . "$_promo_items_file" 2>/dev/null || true)
    _promo_later_count="${_promo_later_count:-0}"
    rm -f "$_promo_items_file"

    if [ "$_promo_assess_exit" -ne 0 ] \
      || [ -z "${_promo_assess_out:-}" ] \
      || [ "${_promo_assess_out}" = "ALL_ITEMS" ]; then
      # Assessor errored, timed out, or declined to classify ("ALL_ITEMS").
      print_warning "Promotion review assessment unavailable — capturing raw findings instead"
      _diag "PROMOTE_ASSESS_FALLBACK branch=${BRANCH:-} pr=${PROMO_PR:-} exit=${_promo_assess_exit} out_bytes=${#_promo_assess_out}"
    else
      _promo_assessed=true
      local _promo_now_count=0
      _promo_now_count=$(printf '%s' "$_promo_assess_out" \
        | grep -c "^### .* - ACTIONABLE_NOW" || true)
      _promo_now_count="${_promo_now_count:-0}"
      print_success "Assessment complete: ${_promo_now_count} ACTIONABLE_NOW, ${_promo_later_count} issue(s) filed for ACTIONABLE_LATER"
      _diag "PROMOTE_ASSESS_COMPLETE branch=${BRANCH:-} pr=${PROMO_PR:-} now=${_promo_now_count} later_issues=${_promo_later_count}"

      if [ "${_promo_now_count}" -gt 0 ]; then
        # Dedup the NOW items against issues already on file.
        #
        # The assessor's own dedup runs only inside its ACTIONABLE_LATER loop,
        # so NOW items reached this aggregate unchecked — and the first live
        # run proved it: promoting plan-quality re-filed a finding that was
        # already tracked as #1253. The duplicates a promotion must avoid were
        # filed under the CONSTITUENT issues, so the comparison set is every
        # open review/tech-debt issue, not just this PR's.
        #
        # Best-effort like the rest of Phase 5b: if the issue list cannot be
        # fetched, nothing is filtered and the aggregate is filed whole — the
        # pre-dedup behaviour, which over-reports rather than losing a finding.
        local _promo_open_issues="" _promo_open_fr="" _promo_open_td=""
        _promo_open_fr=$(gh_safe issue list --state open --label "from-review" \
          --limit 200 --json number,title --jq '.[] | "\(.number):\(.title)"' 2>/dev/null || true)
        _promo_open_td=$(gh_safe issue list --state open --label "tech-debt" \
          --limit 200 --json number,title --jq '.[] | "\(.number):\(.title)"' 2>/dev/null || true)
        _promo_open_issues=$(printf '%s\n%s' "${_promo_open_fr:-}" "${_promo_open_td:-}" \
          | grep -v '^$' | sort -u || true)

        local _promo_now_titles
        _promo_now_titles=$(printf '%s' "$_promo_assess_out" \
          | sed -n 's/^### \(.*\) - ACTIONABLE_NOW$/\1/p' || true)

        local _promo_dup_file _promo_dup_note="" _promo_kept=0 _promo_dups=0
        _promo_dup_file=$(mktemp)
        local _pnt _pdup
        while IFS= read -r _pnt; do
          [ -n "${_pnt:-}" ] || continue
          _pdup=$(_promote_title_matches_open_issue "$_pnt" "${_promo_open_issues:-}" || true)
          if [ -n "${_pdup:-}" ]; then
            printf '%s\n' "$_pnt" >> "$_promo_dup_file"
            _promo_dup_note="${_promo_dup_note}- \`${_pnt}\` — already tracked as #${_pdup}
"
            _promo_dups=$((_promo_dups + 1))
          else
            _promo_kept=$((_promo_kept + 1))
          fi
        done <<< "$_promo_now_titles"

        if [ "${_promo_dups}" -gt 0 ]; then
          print_info "${_promo_dups} of ${_promo_now_count} ACTIONABLE_NOW finding(s) already tracked — not re-filing those"
          _diag "PROMOTE_ASSESSED_DEDUP branch=${BRANCH} pr=${PROMO_PR} now=${_promo_now_count} duplicate=${_promo_dups} new=${_promo_kept}"
          _promo_assess_out=$(_promote_strip_tracked_now_blocks "$_promo_assess_out" "$_promo_dup_file")
        fi
        rm -f "$_promo_dup_file"

        if [ "${_promo_kept}" -eq 0 ]; then
          print_success "All ${_promo_now_count} ACTIONABLE_NOW finding(s) are already tracked — nothing new to file"
          _diag "PROMOTE_ASSESSED_ALL_TRACKED branch=${BRANCH} pr=${PROMO_PR} now=${_promo_now_count}"
        else

        print_info "Capturing ${_promo_kept} new ACTIONABLE_NOW promotion finding(s) as a follow-up issue"

        # Truncate to stay inside GitHub's 65536-char issue body limit. Backing
        # off to the last newline cannot split a comment block here (assessment
        # output carries no multi-KB sharkrite-review-data block), but the
        # guard is kept symmetric with the raw-capture path below.
        local _promo_now_items="${_promo_assess_out}"
        if [ "${#_promo_assess_out}" -gt 55000 ]; then
          print_info "Assessment exceeds 55000 chars — truncated in follow-up issue body (full assessment on PR #${PROMO_PR})"
          local _promo_now_cut="${_promo_assess_out:0:55000}"
          _promo_now_cut="${_promo_now_cut%$'\n'*}"
          _promo_now_items="${_promo_now_cut}

... (assessment truncated — see PR #${PROMO_PR} for the full assessment)"
        fi

        local _promo_now_body
        _promo_now_body="Findings from the promotion review of \`${BRANCH}\` (PR #${PROMO_PR}) that the
assessment classified **ACTIONABLE_NOW** and that are not already tracked by
an open issue — they survived both the NOW/LATER/DISMISSED judgment each
constituent issue's review loop applies, and a dedup check against every open
review/tech-debt issue.

The promotion review is the only review that sees these issues integrated
together, so cross-issue findings appear nowhere else. Promotion proceeded (the
CRITICAL hard gate passed) and these are tracked here rather than fixed on the
integration branch, which would land code on main that skipped the per-issue
review cycle.

ACTIONABLE_LATER findings from the same review were filed as their own issues
(${_promo_later_count} this run). DISMISSED findings were dropped.
${_promo_dup_note:+
Already tracked, so not re-filed here:
${_promo_dup_note}}

## Time Estimate
2hr

## Claude Context
Files to Read:
- Changed files on PR #${PROMO_PR} (\`gh pr diff ${PROMO_PR} --name-only\`)

Files to Modify:
- _Determine from each finding below_

## Acceptance Criteria
- [ ] Every ACTIONABLE_NOW finding below has a fix commit or a written dismissal — verify: \`gh issue view <this issue> --json comments\`
- [ ] \`make check\` exits 0 — verify: \`make check >/dev/null 2>&1; echo \$?\`

## Verification Commands
\`\`\`bash
make check >/dev/null 2>&1; echo \$?
\`\`\`

## Done Definition
Every ACTIONABLE_NOW finding listed below has either a fix commit or a recorded reason for dismissal.

## Scope Boundary
- DO: Address the findings listed below
- DO NOT: Refactor surrounding code, add features, or modify files no finding names

## Documentation Impact
Read-only accuracy check of \`docs/architecture/behavioral-design.md\` against any behavioural change a fix introduces.

**Dependencies**: None

---

${_promo_now_items}"

        # Lazy, guarded load: a top-level source would hard-fail in the promote
        # tests, which build a minimal fake lib dir. Same reason as test-gate.sh
        # above.
        if ! declare -f ensure_labels_exist >/dev/null 2>&1; then
          # shellcheck source=/dev/null
          source "$RITE_LIB_DIR/utils/labels.sh" 2>/dev/null || true
        fi
        if declare -f ensure_labels_exist >/dev/null 2>&1; then
          ensure_labels_exist "from-review,tech-debt" 2>/dev/null || true
        fi

        local _promo_now_url
        if _promo_now_url=$(gh_safe issue create \
              --title "Promotion review ACTIONABLE_NOW findings: ${BRANCH}" \
              --label "from-review" \
              --label "tech-debt" \
              --body "$_promo_now_body" 2>/dev/null); then
          print_success "ACTIONABLE_NOW findings tracked: ${_promo_now_url}"
          _diag "PROMOTE_ASSESSED_FOLLOWUP_CREATED branch=${BRANCH} pr=${PROMO_PR} now=${_promo_kept} duplicate=${_promo_dups} url=${_promo_now_url}"
        else
          # Never block the merge on bookkeeping — surface the loss loudly.
          print_warning "Could not create the ACTIONABLE_NOW follow-up issue — findings remain on PR #${PROMO_PR} (review + assessment comments)"
          _diag "PROMOTE_ASSESSED_FOLLOWUP_FAILED branch=${BRANCH} pr=${PROMO_PR} now=${_promo_kept}"
        fi
        fi
      fi
    fi
  fi
  echo ""

  # ── Fallback: deterministic capture of non-CRITICAL findings (#1209) ─────
  #
  # Runs ONLY when Phase 5b could not assess (assessor missing, errored, timed
  # out, or returned ALL_ITEMS). The promotion review is the ONLY review that
  # sees every constituent issue integrated together, so cross-issue findings
  # appear nowhere else. Before #1209, everything below CRITICAL was posted and
  # then evaporated: promoting supervised-ux surfaced 4 HIGH / 3 MEDIUM / 5 LOW
  # and none were tracked.
  #
  # Deterministic by design — the review embeds a sharkrite-review-data JSON
  # block (or a Findings line) with machine-readable counts; no LLM classifier
  # runs on this path, which is why it is the safe fallback for an assessor
  # that just failed. One aggregated issue, never a fix loop, for the same
  # reason Phase 5b files one. Best-effort throughout: promotion has already
  # passed its gates, so nothing in this block may block, retry, or fail the
  # merge.

  # Parse severity counts via the shared 3-tier helper (JSON → Findings → item markers).
  local _promo_h=0 _promo_m=0 _promo_l=0 _promo_noncrit=0
  if [ -n "${_promo_review:-}" ] && [ "${_promo_assessed:-false}" != "true" ]; then
    parse_review_severity_counts "${_promo_review:-}"
    _promo_h=$_PRC_HIGH; _promo_m=$_PRC_MEDIUM; _promo_l=$_PRC_LOW
    _promo_noncrit=$(( _promo_h + _promo_m + _promo_l ))
    if [ "${_PRC_TIER:-0}" -eq 3 ]; then
      _diag "PROMOTE_FOLLOWUP_PARSE_FALLBACK branch=${BRANCH:-} pr=${PROMO_PR:-} tier=3 review_bytes=${#_promo_review}"
    fi
    if [ "${_promo_noncrit}" -eq 0 ]; then
      _diag "PROMOTE_FOLLOWUP_PARSE_ZERO branch=${BRANCH:-} pr=${PROMO_PR:-} review_bytes=${#_promo_review}"
    fi
  fi

  if [ "${_promo_noncrit:-0}" -gt 0 ]; then
    print_info "Capturing ${_promo_noncrit} non-CRITICAL promotion finding(s) as a follow-up issue"

    # Truncate review to stay within GitHub's 65536-char issue body limit.
    # Back off to the last newline so we do not split inside a <!-- --> comment block
    # (promotion reviews end with a multi-KB sharkrite-review-data block); emit -->
    # before the pointer to close any unclosed comment.
    local _promo_review_body="${_promo_review}"
    if [ "${#_promo_review}" -gt 55000 ]; then
      print_info "Review body exceeds 55000 chars — review truncated in follow-up issue body (full review on PR #${PROMO_PR})"
      local _promo_cut="${_promo_review:0:55000}"
      _promo_cut="${_promo_cut%$'\n'*}"
      _promo_review_body="${_promo_cut}
-->
... (review truncated — see PR #${PROMO_PR} for the full review)"
    fi

    local _promo_body
    _promo_body="Findings from the promotion review of \`${BRANCH}\` (PR #${PROMO_PR}).

The promotion review is the only review that sees these issues integrated
together, so these findings appear nowhere else. Promotion proceeded — the
CRITICAL hard gate passed — and these are captured here rather than lost.

**Severity mix:** ${_promo_h} HIGH, ${_promo_m} MEDIUM, ${_promo_l} LOW

**Triage needed:** each item below is unreviewed by a human and was not
assessed NOW/LATER/DISMISSED. Close the ones that do not warrant work.

---

${_promo_review_body}"

    local _promo_issue_url
    if _promo_issue_url=$(gh_safe issue create \
          --title "Promotion review follow-ups: ${BRANCH}" \
          --label "from-review,needs-re-triage" \
          --body "$_promo_body" 2>/dev/null); then
      print_success "Promotion findings tracked: ${_promo_issue_url}"
      _diag "PROMOTE_FOLLOWUP_CREATED branch=${BRANCH} pr=${PROMO_PR} high=${_promo_h} medium=${_promo_m} low=${_promo_l} url=${_promo_issue_url}"
    else
      # Never block the merge on bookkeeping — surface the loss loudly instead.
      print_warning "Could not create the promotion follow-up issue — findings remain only on PR #${PROMO_PR}"
      _diag "PROMOTE_FOLLOWUP_FAILED branch=${BRANCH} pr=${PROMO_PR} count=${_promo_noncrit}"
    fi
    echo ""
  fi
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
  if [ -z "${_branch_sha:-}" ]; then
    print_error "Branch HEAD SHA could not be resolved — re-run: rite --promote $BRANCH"
    exit 1
  fi
  local _expected_head="${_branch_sha}"
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
  if git ls-remote --heads origin "$BRANCH" 2>/dev/null | grep -q "refs/heads/${BRANCH}$"; then
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

  # ── Phase 8: Post-merge doc pass (best-effort, #1435) ─────────────────────
  #
  # The code has already merged. Doc rejection never blocks anything. Every
  # failure path warns and falls through — promote's exit code is unchanged
  # (the #1278 no-bare-exit property). No bare `exit` in this block.
  if ! declare -f docs_run_promote_doc_pass >/dev/null 2>&1; then
    if [ -f "$RITE_LIB_DIR/core/docs-command.sh" ]; then
      source "$RITE_LIB_DIR/core/docs-command.sh" 2>/dev/null || true
    fi
  fi
  if declare -f docs_run_promote_doc_pass >/dev/null 2>&1; then
    echo ""
    docs_run_promote_doc_pass "$BRANCH" "${PROMO_PR:-}" || true
  else
    print_warning "Phase 8: docs_run_promote_doc_pass unavailable — skipping post-merge doc pass for '${BRANCH}'" >&2
  fi

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
