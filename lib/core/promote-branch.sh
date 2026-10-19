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
# shellcheck source=/dev/null
source "$RITE_LIB_DIR/utils/markers.sh"

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
  _branch_sha=$(git rev-parse "origin/$BRANCH" 2>/dev/null || true)

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
        _branch_sha=$(git rev-parse "origin/$BRANCH" 2>/dev/null || true)
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
    source "$RITE_LIB_DIR/utils/test-gate.sh" 2>/dev/null || true
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
    # The timeout defaults above the per-issue 300s: a promotion review spans
    # every constituent issue and so carries several times the findings.
    _promo_assess_out=$(
      RITE_ISSUE_NUMBER="" \
      RITE_RETRY_COUNT=0 \
      RITE_REVIEW_JUST_POSTED=true \
      RITE_PER_ITEM_ISSUES_FILE="$_promo_items_file" \
      RITE_ASSESSMENT_TIMEOUT="${RITE_ASSESSMENT_TIMEOUT:-600}" \
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

  # Parse severity counts from the review's embedded JSON block (priority 1) or
  # the human Findings line (priority 2) — same dual-parse path as local-review.sh.
  # Both are deterministic: no LLM call, no timeout risk.
  local _promo_h=0 _promo_m=0 _promo_l=0 _promo_noncrit=0
  if [ -n "${_promo_review:-}" ] && [ "${_promo_assessed:-false}" != "true" ]; then
    local _promo_json _promo_findings_line
    _promo_json=$(printf '%s' "$_promo_review" \
      | sed -n "/<!-- ${RITE_MARKER_REVIEW_DATA}/,/-->/p" | sed '1d;$d' 2>/dev/null || true)
    if [ -n "${_promo_json:-}" ] && printf '%s' "$_promo_json" | jq -e '.summary' >/dev/null 2>&1; then
      _promo_h=$(printf '%s' "$_promo_json" | jq -r '.summary.high // 0' || true)
      _promo_m=$(printf '%s' "$_promo_json" | jq -r '.summary.medium // 0' || true)
      _promo_l=$(printf '%s' "$_promo_json" | jq -r '.summary.low // 0' || true)
    else
      _promo_findings_line=$(printf '%s' "$_promo_review" \
        | grep -E "CRITICAL: *[0-9]+.*HIGH: *[0-9]+.*MEDIUM: *[0-9]+.*LOW: *[0-9]+" | head -1 || true)
      if [ -n "${_promo_findings_line:-}" ]; then
        _promo_h=$(printf '%s' "$_promo_findings_line" | grep -oE "HIGH: *[0-9]+" | grep -oE "[0-9]+" | head -1 || true)
        _promo_m=$(printf '%s' "$_promo_findings_line" | grep -oE "MEDIUM: *[0-9]+" | grep -oE "[0-9]+" | head -1 || true)
        _promo_l=$(printf '%s' "$_promo_findings_line" | grep -oE "LOW: *[0-9]+" | grep -oE "[0-9]+" | head -1 || true)
      else
        # priority 3: item markers (<!-- item:N severity:HIGH|MEDIUM|LOW -->)
        # A review with markers but no JSON block or Findings line still has findings.
        local _promo_item_count
        _promo_item_count=$(printf '%s' "$_promo_review" \
          | grep -cE "<!-- item:[0-9]+ severity:(HIGH|MEDIUM|LOW)" || true)
        if [ "${_promo_item_count:-0}" -gt 0 ]; then
          _promo_h=$(printf '%s' "$_promo_review" | grep -cE "<!-- item:[0-9]+ severity:HIGH" || true)
          _promo_m=$(printf '%s' "$_promo_review" | grep -cE "<!-- item:[0-9]+ severity:MEDIUM" || true)
          _promo_l=$(printf '%s' "$_promo_review" | grep -cE "<!-- item:[0-9]+ severity:LOW" || true)
          _diag "PROMOTE_FOLLOWUP_PARSE_FALLBACK branch=${BRANCH:-} pr=${PROMO_PR:-} marker_count=${_promo_item_count}"
        fi
      fi
    fi
    _promo_h="${_promo_h:-0}"; _promo_m="${_promo_m:-0}"; _promo_l="${_promo_l:-0}"
    # Strip fractional part that jq may emit (e.g. "2.0" → "2") before arithmetic.
    _promo_h="${_promo_h%%[^0-9]*}"; _promo_h="${_promo_h:-0}"
    _promo_m="${_promo_m%%[^0-9]*}"; _promo_m="${_promo_m:-0}"
    _promo_l="${_promo_l%%[^0-9]*}"; _promo_l="${_promo_l:-0}"
    _promo_noncrit=$(( _promo_h + _promo_m + _promo_l ))
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
