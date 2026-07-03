#!/bin/bash
# scripts/assess-and-resolve.sh
# Comprehensive PR review assessment with automatic issue categorization
# Usage:
#   ./scripts/assess-and-resolve.sh PR_NUMBER [ISSUE_NUMBER] [--auto]
#
# Exit codes:
#   0 - All issues resolved or tracked
#   1 - Manual intervention required (supervisor decision needed)
#   2 - Critical issues require fixes (restart PR cycle, outputs filtered review to stdout)
#   3 - Review is stale (commits newer than review — route back to Phase 2 for fresh review)
#
# Data flow (auto mode):
#   - Calls assess-review-issues.sh to filter ACTIONABLE items
#   - Outputs filtered review content to stdout on exit 2
#   - workflow-runner.sh captures stdout and pipes to claude-workflow.sh (no temp files!)

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if [ "${_RITE_ASSESS_AND_RESOLVE_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_ASSESS_AND_RESOLVE_LOADED=true

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/../utils/config.sh"
fi

# Source review helper for consistent review method handling
source "$RITE_LIB_DIR/utils/review-helper.sh"
source "$RITE_LIB_DIR/utils/labels.sh"
source "$RITE_LIB_DIR/utils/date-helpers.sh"
source "$RITE_LIB_DIR/utils/issue-lock.sh"
source "$RITE_LIB_DIR/utils/markers.sh"
source "$RITE_LIB_DIR/utils/portable-cmds.sh"

# Source PR detection for shared commit timestamp utility
source "$RITE_LIB_DIR/utils/pr-detection.sh"

# ---------------------------------------------------------------------------
# _followup_dedup_check — four-source dedup check for follow-up issue creation
#
# Checks whether a follow-up issue already exists using four evidence sources
# in order of reliability and cost:
#
#   1. Local evidence file (fastest, no network, survives PR comment failures)
#   2. Body-marker search scoped to source issue (reliable when indexed)
#   3. Title search (catches cases where body marker not yet indexed)
#   4. PR marker comment OR lock-contention signal (guards against index lag)
#
# After this function returns, EXISTING_ISSUE is set to the number of the
# existing issue if one was found, or empty if creation should proceed.
#
# Globals read:
#   PR_NUMBER, ISSUE_NUMBER, ISSUE_SEARCH
#   RITE_MARKER_SOURCE_ISSUE, RITE_MARKER_FOLLOWUP
#   RITE_DEDUP_BACKOFF (default 5s)
#   _FOLLOWUP_FINDING_KEY — per-finding evidence/lock key (source_issue-slug-index);
#                           set by caller before invoking this function.  Falls back
#                           to ISSUE_NUMBER when not set.  Key must match the value
#                           written by write_followup_evidence (either from
#                           assess-and-resolve.sh or assess-review-issues.sh).
#   _clean_title — the current finding's display title; used by Source 4 to
#                  scope the PR-comment scan to the current finding.
# Globals written:
#   EXISTING_ISSUE — set to existing issue number if found, empty otherwise
# Globals in/out:
#   _lock_was_contended — consumed on first contention retry (set to false)
#
# Tests source this file with RITE_SOURCE_FUNCTIONS_ONLY=1 and stub gh_safe
# to exercise this function in isolation without network calls.
# ---------------------------------------------------------------------------
_followup_dedup_check() {
  # Check if issue already exists.  Four evidence sources checked in order of
  # reliability and cost:
  #
  #   1. Local evidence file (fastest, no network, survives PR comment failures)
  #   2. Body-marker search scoped to source issue (reliable when indexed)
  #   3. Title search (catches cases where body marker not yet indexed)
  #   4. PR marker comment (guards against index lag after another process created)
  #
  # Source 1 (local evidence) is the fix for the edge case where the GitHub PR
  # comment write fails (||true silences it) and both the issue body and title
  # searches miss due to index lag.  The evidence file is written to disk while
  # the lock is held, so it is guaranteed to be present if any prior holder of
  # this lock successfully created an issue — even if the comment write failed.
  EXISTING_ISSUE=""
  local _dedup_retries=0
  local _dedup_max_retries=3
  # _dedup_backoff: seconds to wait between dedup retry iterations.
  #
  # TIMING BUDGET NOTE — this directly affects how long the lock is held.
  # The holder (this process) holds acquire_pr_followup_lock while running the
  # dedup search loop.  The waiter times out after ~60s (max_attempts in
  # issue-lock.sh).  Under slow-GitHub conditions the holder can consume:
  #
  #   evidence validation gh call  : up to 20s backoff-sleep (gh_safe 3×: 5s+15s);
  #                                   gh round-trip latency is additional and not included
  #   dedup search loop (up to 4 gh calls per iteration): up to 80s backoff-sleep
  #                                   (20s each); gh round-trip latency adds to each call
  #     - Source 2a: gh issue list  (body-marker search)
  #     - Source 2b: gh issue view  (marker verification; only if 2a found a candidate)
  #     - Source 3:  gh issue list  (title search; only if still no match)
  #     - Source 4:  gh pr view     (PR comment check; only if still no match and not last retry)
  #   this backoff loop (3 retries × _dedup_backoff): _dedup_max_retries × _dedup_backoff
  #
  # With defaults (3 retries, 5s backoff): 20 + 80 + 15 = 115s backoff-sleep worst-case,
  # which exceeds the ~60s waiter budget; actual wall-clock is higher once gh request
  # latency is included.  In practice the evidence validation short-circuits the loop,
  # keeping typical holder time under 10s.  But under concurrent slow-GitHub conditions
  # the waiter may time out and proceed lock-less.
  #
  # To reduce worst-case holder time, lower RITE_DEDUP_BACKOFF or RITE_GH_MAX_RETRIES.
  # See acquire_pr_followup_lock comment in lib/utils/issue-lock.sh for the full analysis.
  local _dedup_backoff="${RITE_DEDUP_BACKOFF:-5}"  # configurable via env; default 5s

  # Source 1: local evidence file — no API call, survives comment-write failures.
  # Read and validate once, before the retry loop.  The evidence file is FS-backed
  # and lock-serialized; it cannot change mid-loop unless this process clears it,
  # so reading it inside the loop would only give transient gh failures more chances
  # to wrongly clear it on each backoff iteration.
  # Use per-finding key (_FOLLOWUP_FINDING_KEY) when available so evidence files
  # are scoped per finding, not per source-issue.  Falling back to ISSUE_NUMBER
  # preserves backward-compat for callers that don't set the per-finding key.
  local _dedup_evidence_key="${_FOLLOWUP_FINDING_KEY:-${ISSUE_NUMBER:-}}"
  local _evidence_candidate
  _evidence_candidate=$(read_followup_evidence "$PR_NUMBER" "$_dedup_evidence_key" || true)
  if [ -n "$_evidence_candidate" ]; then
    # Validate that the locally-evidenced issue is still open.  The evidence file
    # persists indefinitely; if the referenced issue was closed or deleted since it
    # was written, trusting it would permanently suppress recreation of the follow-up.
    # IMPORTANT: distinguish three outcomes from `gh issue view`:
    #   - "OPEN"             → confirmed open; trust the evidence
    #   - "CLOSED"/"MERGED"  → confirmed closed/deleted; clear stale evidence
    #   - "" (empty/error)   → transient API failure; do NOT clear — preserve the
    #                          dedup guarantee under the same flakiness conditions
    #                          this PR is designed to handle
    local _evidence_issue_state
    _evidence_issue_state=$(gh_safe issue view "$_evidence_candidate" --json state --jq '.state' || true)
    if [ "${_evidence_issue_state}" = "OPEN" ]; then
      # Confirmed open — trust local evidence immediately; no need to enter loop
      EXISTING_ISSUE="$_evidence_candidate"
    elif [ -n "$_evidence_issue_state" ]; then
      # Confirmed non-OPEN (e.g. CLOSED) — stale evidence, safe to clear
      print_info "Local evidence points to issue #$_evidence_candidate (state: ${_evidence_issue_state}) — removing stale evidence file and continuing dedup check"
      clear_followup_evidence "$PR_NUMBER" "$_dedup_evidence_key"
    else
      # Empty result — gh call failed (transient API error or network issue).
      # Do NOT clear the evidence file; preserve the dedup guarantee.
      print_info "Could not determine state of evidenced issue #$_evidence_candidate (gh API unavailable) — retaining local evidence to preserve dedup guarantee"
      EXISTING_ISSUE="$_evidence_candidate"
    fi
  fi

  while [ "$_dedup_retries" -le "$_dedup_max_retries" ]; do

    # Source 2: body-marker search scoped to source issue (most reliable when indexed)
    #
    # The search term is quoted ("sharkrite-source-issue:N") to force GitHub's
    # full-text search to treat it as a literal phrase rather than a structured
    # qualifier.  Without quotes, GitHub may tokenize around the colon and fail
    # to match the marker embedded inside an HTML comment.
    #
    # IMPORTANT: the source-issue marker is shared by ALL findings from the same
    # source issue.  A body-marker search returns the FIRST indexed issue, which
    # may be finding #1's issue when we are looking for finding #2..N.  We
    # therefore require a title match before accepting a Source 2 candidate.
    # This prevents finding #2..N from being collapsed into finding #1's issue.
    if [ -z "$EXISTING_ISSUE" ] && [ -n "${ISSUE_NUMBER:-}" ]; then
      # Search returns multiple candidates (up to 10); we check each title.
      local _src2_candidates
      _src2_candidates=$(gh_safe issue list \
        --state open \
        --search "\"${RITE_MARKER_SOURCE_ISSUE}:${ISSUE_NUMBER}\" in:body" \
        --json number,title \
        --limit 10 \
        --jq '.[] | "\(.number) \(.title)"' | grep -E '^[0-9]+' || true)
      _src2_candidates="${_src2_candidates:-}"
      if [ -n "$_src2_candidates" ]; then
        local _s2_num _s2_title
        while IFS= read -r _s2_line; do
          [ -z "$_s2_line" ] && continue
          _s2_num=$(echo "$_s2_line" | awk '{print $1}' || true)
          _s2_title=$(echo "$_s2_line" | cut -d' ' -f2- || true)
          # Must match the current finding's title.  Compare against the BARE
          # _clean_title (the discriminating prefix), NOT the suffixed ISSUE_TITLE
          # ("${_clean_title} for issue #N").  Two emit paths file follow-ups for
          # the same deferred finding with DIFFERENT title formats:
          #   - assess-and-resolve.sh (this NEW path): titled "${_clean_title} for issue #N"
          #   - assess-review-issues.sh (the OLD per-item path): titled bare "${_clean_title}"
          # Matching on the suffixed ISSUE_TITLE silently fails against an
          # OLD-path issue (bare title), so the source-issue-scoped dedup misses
          # its own twin and BOTH issues get filed (live: LeadFlow #369/#371,
          # #381/#383 — issue #790).  The bare _clean_title is the part that
          # distinguishes finding #1 from #2..N (the suffix is identical for all
          # findings of one source issue and adds no discrimination), and it is a
          # substring of both title formats — so grep -qF on it matches OLD and
          # NEW issues alike while preserving finding-level specificity.  This
          # mirrors Source 4 (line ~249), which already keys on _clean_title.
          if [ -n "$_s2_num" ] && [ -n "${_clean_title:-}" ] && \
             echo "$_s2_title" | grep -qF "$_clean_title"; then
            # Verify the marker is actually in the body — GitHub search can return
            # approximate matches; direct body inspection is the ground truth.
            local _candidate_body
            _candidate_body=$(gh_safe issue view "$_s2_num" --json body --jq '.body' || true)
            _candidate_body="${_candidate_body:-}"
            if echo "$_candidate_body" | grep -qE "${RITE_MARKER_SOURCE_ISSUE}:${ISSUE_NUMBER}([^[:alnum:]_-]|$)"; then
              EXISTING_ISSUE="$_s2_num"
              break
            fi
          fi
        done <<< "$_src2_candidates"
      fi
      EXISTING_ISSUE="${EXISTING_ISSUE:-}"
    fi

    # Source 3: title search (catches cases where body marker not yet indexed)
    if [ -z "$EXISTING_ISSUE" ]; then
      EXISTING_ISSUE=$(gh_safe issue list --search "in:title $ISSUE_SEARCH" --json number,title,state --limit 1 | \
        jq -r '.[] | select(.state == "OPEN") | .number' || true)
      EXISTING_ISSUE="${EXISTING_ISSUE:-}"
    fi

    # If found by any source, no need to retry
    [ -n "$EXISTING_ISSUE" ] && break

    # Source 4: PR marker comment OR lock-contention signal.
    #
    # Two independent signals indicate that another process may have just created
    # a follow-up issue that the GitHub search index hasn't yet caught up with:
    #
    #   (a) PR comment with a sharkrite-followup-issue marker — the original
    #       guard from PR #127; works when the creating process posted a comment.
    #
    #   (b) _lock_was_contended=true — the lock was blocked when we acquired it,
    #       meaning another process just held and released the lock (i.e., just
    #       completed the dedup-then-create sequence).  This is the fix for Gap 1
    #       from issue #478: for follow-up *issue* creation there may be no PR
    #       comment to act as the lag signal, so contention alone is sufficient
    #       evidence that we should retry rather than proceed to create.
    #
    # Either signal triggers a retry.  Lock contention is only used on the first
    # retry iteration (it's a one-time signal from the previous lock holder).
    if [ "$_dedup_retries" -lt "$_dedup_max_retries" ]; then
      # Scope the PR-comment check to the current finding's title so that a
      # marker comment posted for finding #1 (earlier in this loop) does not
      # trigger spurious retries for findings #2..N.  The PR comment body
      # includes the clean title (see comment construction below), so filtering
      # by title gives finding-level specificity without requiring a separate
      # per-finding marker.
      #
      # Two-stage approach: jq extracts all followup comment bodies, then grep
      # filters for the current finding's title.  This avoids jq string-injection
      # issues with arbitrary LLM-derived title text.
      local _jq_followup_bodies
      _jq_followup_bodies='.comments[].body | select(contains("<!-- '"${RITE_MARKER_FOLLOWUP}"':"))'
      local _recent_followup_comment
      _recent_followup_comment=$(gh_safe pr view "$PR_NUMBER" \
        --json comments \
        --jq "$_jq_followup_bodies" 2>/dev/null | \
        grep -cF "${_clean_title}" || true)
      _recent_followup_comment="${_recent_followup_comment:-0}"
      local _retry_reason=""
      if [ "${_recent_followup_comment:-0}" -gt 0 ]; then
        _retry_reason="follow-up comment found on PR but issue not yet indexed"
      elif [ "${_lock_was_contended:-false}" = "true" ] && [ "$_dedup_retries" -eq 0 ]; then
        # Lock was contended: another process just completed the critical section.
        # Fire one retry to let the GitHub index catch up before proceeding to create.
        _retry_reason="lock was contended (another process just finished) — index may lag"
        _lock_was_contended=false  # consume signal; only retry once for contention alone
      fi
      if [ -n "$_retry_reason" ]; then
        _dedup_retries=$((_dedup_retries + 1))
        print_info "Dedup retry: ${_retry_reason} (attempt $_dedup_retries/$_dedup_max_retries) — retrying in ${_dedup_backoff}s..."
        sleep "$_dedup_backoff"
        continue
      fi
    fi

    # No evidence of prior creation — break and proceed to create
    break
  done
}

# ---------------------------------------------------------------------------
# _resolve_priority_label — map a normalized severity token to a priority label
#
# Args: $1 = severity token (CRITICAL, HIGH, MEDIUM, LOW — already normalized)
# Output: priority-high | priority-medium | priority-low (echoed to stdout)
#
# Extracted from the per-finding loop so tests can source this file with
# RITE_SOURCE_FUNCTIONS_ONLY=1 and call this function directly, ensuring
# any change to the case arms is caught by the regression tests.
# ---------------------------------------------------------------------------
_resolve_priority_label() {
  local _sev="${1:-MEDIUM}"
  local _label="priority-medium"
  case "${_sev}" in
    CRITICAL|HIGH) _label="priority-high" ;;
    MEDIUM)        _label="priority-medium" ;;
    LOW)           _label="priority-low" ;;
  esac
  echo "$_label"
}

# ---------------------------------------------------------------------------
# _resolve_done_def — map a normalized severity token to a done definition
#
# Args: $1 = severity token (CRITICAL, HIGH, MEDIUM, LOW — already normalized)
# Output: done-definition string (echoed to stdout)
#
# Extracted from the per-finding loop for the same reason as
# _resolve_priority_label above: tests can call the real function instead of
# inlining a copy of the case arms.
# ---------------------------------------------------------------------------
_resolve_done_def() {
  local _sev="${1:-MEDIUM}"
  local _def=""
  case "${_sev}" in
    CRITICAL) _def="Done when the CRITICAL finding is resolved, verified, and confirmed by tests." ;;
    HIGH)     _def="Done when the HIGH finding is resolved and verified with a targeted test or manual check." ;;
    *)        _def="Done when the finding is addressed or explicitly deferred with justification." ;;
  esac
  echo "$_def"
}

# ---------------------------------------------------------------------------
# _post_gate_fallback_assessment_comment PR_NUMBER GATE_ITEMS GATE_NOW_COUNT
#
# Posts a minimal assessment PR comment (RITE_MARKER_ASSESSMENT marker)
# containing the [GATE] ACTIONABLE_NOW items, for the fallback branch where
# the LLM assessment failed but the post-commit gate has blocking findings.
#
# WHY (issue #821; LeadFlow #435/#431 same night): claude-workflow.sh
# FIX_REVIEW_MODE reads the assessment EXCLUSIVELY from the PR comment when a
# PR number is passed — the stdin fallback only exists when no PR number is
# given. The normal comment-posting step lives in assess-review-issues.sh
# (~line 796) and is only reached on the successful-LLM path, so this
# fallback must post its own comment before exiting 2 or fix mode dies with
# "No assessment found".
#
# Body format mirrors assess-review-issues.sh's ASSESSMENT_COMMENT: marker
# line, header, Summary block, `---` separator, then the items. The `---`
# separator is load-bearing: fix mode strips everything before it, then its
# awk extraction parses the `### ... - ACTIONABLE_NOW` headers from the rest.
#
# Returns 0 when posted; 1 when the post failed (after printing a loud
# warning). Caller must still exit 2 either way — objective gate failures
# force the fix loop regardless of whether the comment landed.
# ---------------------------------------------------------------------------
_post_gate_fallback_assessment_comment() {
  local _pr_number="$1"
  local _gate_items="$2"
  local _gate_count="$3"
  local _ts _comment _body_file

  _ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  _comment="<!-- ${RITE_MARKER_ASSESSMENT} pr:${_pr_number} iteration:1 timestamp:${_ts} -->

## 🔍 Sharkrite Assessment

**PR:** #${_pr_number}
**Assessed:** ${_ts}
**Model:** none (LLM assessment failed — gate findings only)

### Summary
- **ACTIONABLE_NOW:** ${_gate_count} items (fix in this PR)
- **ACTIONABLE_LATER:** 0 items (tech-debt)
- **DISMISSED:** 0 items (not actionable)

---

${_gate_items}"

  print_status "Posting gate-findings assessment comment to PR #${_pr_number}..."
  _body_file=$(mktemp)
  printf '%s' "$_comment" > "$_body_file"
  if gh_safe pr comment "$_pr_number" --body-file "$_body_file" >/dev/null 2>&1; then
    print_success "Gate-findings assessment posted to PR #${_pr_number}"
    rm -f "$_body_file"
    return 0
  fi
  rm -f "$_body_file"
  print_warning "FAILED to post gate-findings assessment comment to PR #${_pr_number}"
  print_warning "Fix mode reads the assessment from the PR comment — without it, fix mode will fail with 'No assessment found'"
  print_warning "After resolving gh connectivity, re-run: rite ${ISSUE_NUMBER:-$_pr_number} --assess-and-fix"
  return 1
}

# ---------------------------------------------------------------------------
# Guard: when sourced with RITE_SOURCE_FUNCTIONS_ONLY=1, stop here so tests
# can load only the function definitions above (_followup_dedup_check,
# _resolve_priority_label, _resolve_done_def) without executing the script body
# (which parses args, sets up exec redirects, installs traps, and makes live
# gh/claude calls).
# ---------------------------------------------------------------------------
if [ "${RITE_SOURCE_FUNCTIONS_ONLY:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi

# Redirect all display output to stderr (stdout reserved for filtered content on exit 2)
exec 3>&1  # Save original stdout for filtered content output
exec 1>&2  # Redirect stdout to stderr for all print functions

# Log unexpected exits for diagnostics (log-only, not visible in terminal)
trap '_diag "ASSESS_RESOLVE_ERR exit=$? line=$LINENO"' ERR

# Temp file cleanup trap handler (minimal - only for initial review fetch)
cleanup() {
  local exit_code=$?
  # Clean up ONLY the file this invocation owns — never a glob.
  # A glob (/tmp/pr_review_*.txt) would wipe peer invocations' review files
  # under concurrent runs (e.g. a retry from workflow-runner overlapping with
  # a manual --assess-and-fix against the same or a different PR).
  # Live failure: issue #345 batch run 2026-06-06 — format-review.sh received
  # "Error: Review file not found" because a peer cleanup trap fired the glob
  # between the write at line ~411 and the read at line ~705.
  # ${REVIEW_FILE:-} guard: variable is unset until line ~411; the :- expansion
  # satisfies set -u without crashing if EXIT fires before REVIEW_FILE is set.
  rm -f "${REVIEW_FILE:-}" 2>/dev/null || true
  # Clean up the contention-signal temp file owned by this invocation.
  # This is the safety net for crashes between mktemp and the explicit rm at
  # line ~1461; normal exits clean it up before reaching here.
  rm -f "${_lock_contended_file:-}" 2>/dev/null || true
  # Release follow-up lock on signal (SIGINT/SIGTERM) to avoid leaving it
  # held for the full 60s acquire-loop timeout on the next run.
  # Use _FOLLOWUP_FINDING_KEY (the per-finding lock key) when set; fall back to
  # ISSUE_NUMBER for any legacy code paths that don't have a finding key in scope.
  if [ "${_followup_lock_held:-false}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
    release_pr_followup_lock "$PR_NUMBER" "${_FOLLOWUP_FINDING_KEY:-${ISSUE_NUMBER:-}}" 2>/dev/null || true
    _followup_lock_held=false
  fi
  exit $exit_code
}
trap cleanup EXIT INT TERM

# Parse arguments
PR_NUMBER="$1"
ISSUE_NUMBER="${2:-}"
RETRY_COUNT="${3:-0}"  # Default to 0 if not provided
AUTO_MODE=false

# Validate PR number is positive integer
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || [ "$PR_NUMBER" -le 0 ] 2>/dev/null; then
  echo "❌ Invalid PR number: $PR_NUMBER (must be positive integer)"
  exit 1
fi

# Safety check: Prevent unbounded recursion
# Can be overridden via environment variable
MAX_RETRIES="${RITE_MAX_RETRIES:-3}"
if [ "$RETRY_COUNT" -gt "$MAX_RETRIES" ]; then
  echo "❌ Maximum retry limit exceeded ($RETRY_COUNT > $MAX_RETRIES)"
  echo "Preventing unbounded recursion - manual intervention required"
  exit 1
fi

# Handle --auto flag (can be 2nd, 3rd, or 4th argument)
if [ "${2:-}" = "--auto" ] || [ "${3:-}" = "--auto" ] || [ "${4:-}" = "--auto" ]; then
  AUTO_MODE=true
fi

# If 2nd argument is --auto, clear ISSUE_NUMBER
if [ "$ISSUE_NUMBER" = "--auto" ]; then
  ISSUE_NUMBER=""
  RETRY_COUNT="${3:-0}"
fi

# If 3rd argument is --auto, RETRY_COUNT is 4th
if [ "${3:-}" = "--auto" ]; then
  RETRY_COUNT="${4:-0}"
fi

# Validate ISSUE_NUMBER if provided (similar to PR_NUMBER validation)
if [ -n "$ISSUE_NUMBER" ]; then
  if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]] || [ "$ISSUE_NUMBER" -le 0 ] 2>/dev/null; then
    echo "❌ Invalid issue number: $ISSUE_NUMBER (must be positive integer)"
    exit 1
  fi
fi

# Backfill ISSUE_NUMBER from PR body (Closes #N) for status messages that
# refer to the workflow by its issue rather than its PR. Best-effort — when
# no linked issue exists, messages fall back to "PR #N".
if [ -z "$ISSUE_NUMBER" ]; then
  ISSUE_NUMBER=$(gh_safe pr view "$PR_NUMBER" --json body --jq '.body' 2>/dev/null \
    | grep -oiE '(close[ds]?|fix(es|ed)?|resolve[ds]?) #[0-9]+' \
    | head -1 | grep -oE '[0-9]+' || true)
  ISSUE_NUMBER="${ISSUE_NUMBER:-}"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_header() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
  echo -e "${BLUE}$1${NC}" >&2
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n" >&2
}

print_success() { echo -e "${GREEN}✅ $1${NC}" >&2; }
print_error() { echo -e "${RED}❌ $1${NC}" >&2; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}" >&2; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}" >&2; }
print_status() { echo -e "${BLUE}$1${NC}" >&2; }
print_critical() { echo -e "${RED}🚨 CRITICAL: $1${NC}" >&2; }
print_high() { echo -e "${MAGENTA}⚡ HIGH: $1${NC}" >&2; }
print_medium() { echo -e "${YELLOW}📋 MEDIUM: $1${NC}" >&2; }
print_low() { echo -e "${BLUE}💡 LOW: $1${NC}" >&2; }

# Print detailed assessment breakdown showing each item and reasoning
print_assessment_details() {
  local assessment_content="$1"

  # Disable errexit for this function to prevent grep failures from causing script exit
  set +e

  # Parse items from assessment (format: ### Title - STATE)
  # Extract sections between ### markers

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📋 Assessment Details:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Extract and display ACTIONABLE_NOW items
  local now_items=$(echo "$assessment_content" | grep -A 20 "ACTIONABLE_NOW" 2>/dev/null | grep -B 1 "ACTIONABLE_NOW" 2>/dev/null || true)
  if [ -n "$now_items" ]; then
    echo "🔧 ACTIONABLE_NOW (fix in this PR):" >&2
    echo "" >&2

    # Parse each item (pure awk — no system() calls to avoid shell injection
    # from backticks/quotes in Claude's reasoning text)
    echo "$assessment_content" | awk '
      function wrap(prefix, text, width,    words, n, line, i, indent) {
        indent = "            "
        n = split(text, words, " ")
        line = prefix
        for (i = 1; i <= n; i++) {
          if (length(line) + length(words[i]) + 1 > width && line != prefix) {
            print line
            line = indent words[i]
          } else if (line == prefix) {
            line = line words[i]
          } else {
            line = line " " words[i]
          }
        }
        if (line != "") print line
      }
      /^### .* - ACTIONABLE_NOW/ {
        in_item = 1
        title = $0
        gsub(/^### /, "", title)
        gsub(/ - ACTIONABLE_NOW.*$/, "", title)
        printf "  • %s\n", title
        next
      }
      in_item && /^\*\*Severity:\*\*/ {
        severity = $0
        gsub(/^\*\*Severity:\*\* /, "", severity)
        printf "    Severity: %s\n", severity
        next
      }
      in_item && /^\*\*Reasoning:\*\*/ {
        reasoning = $0
        gsub(/^\*\*Reasoning:\*\* /, "", reasoning)
        wrap("    Reason: ", reasoning, 76)
        next
      }
      in_item && /^\*\*Location:\*\*/ {
        location = $0
        gsub(/^\*\*Location:\*\* /, "", location)
        printf "    Location: %s\n", location
        next
      }
      in_item && /^\*\*Fix Effort:\*\*/ {
        effort = $0
        gsub(/^\*\*Fix Effort:\*\* /, "", effort)
        printf "    Effort: %s\n", effort
        printf "\n"
        in_item = 0
        next
      }
      in_item && /^### / {
        # New item started, reset
        in_item = 0
        printf "\n"
      }
    '
  fi

  # Extract and display ACTIONABLE_LATER items
  # Use structured header match (not grep -A N) to avoid spanning item boundaries.
  local later_items=$(echo "$assessment_content" | grep -c "^### .* - ACTIONABLE_LATER" || true)
  if [ "${later_items:-0}" -gt 0 ]; then
    echo "📝 ACTIONABLE_LATER (defer to follow-up):"
    echo ""

    echo "$assessment_content" | awk '
      function wrap(prefix, text, width,    words, n, line, i, indent) {
        indent = "            "
        n = split(text, words, " ")
        line = prefix
        for (i = 1; i <= n; i++) {
          if (length(line) + length(words[i]) + 1 > width && line != prefix) {
            print line
            line = indent words[i]
          } else if (line == prefix) {
            line = line words[i]
          } else {
            line = line " " words[i]
          }
        }
        if (line != "") print line
      }
      /^### .* - ACTIONABLE_LATER/ {
        in_item = 1
        title = $0
        gsub(/^### /, "", title)
        gsub(/ - ACTIONABLE_LATER.*$/, "", title)
        printf "  • %s\n", title
        next
      }
      in_item && /^\*\*Severity:\*\*/ {
        severity = $0
        gsub(/^\*\*Severity:\*\* /, "", severity)
        printf "    Severity: %s\n", severity
        next
      }
      in_item && /^\*\*Reasoning:\*\*/ {
        reasoning = $0
        gsub(/^\*\*Reasoning:\*\* /, "", reasoning)
        wrap("    Reason: ", reasoning, 76)
        next
      }
      in_item && /^\*\*Defer Reason:\*\*/ {
        defer = $0
        gsub(/^\*\*Defer Reason:\*\* /, "", defer)
        wrap("    Defer: ", defer, 76)
        printf "\n"
        in_item = 0
        next
      }
      in_item && /^### / {
        in_item = 0
        printf "\n"
      }
    '
  fi

  # Extract and display DISMISSED items
  # Use structured header match (not grep -A N) to avoid spanning item boundaries.
  local dismissed_items=$(echo "$assessment_content" | grep -c "^### .* - DISMISSED" || true)
  if [ "${dismissed_items:-0}" -gt 0 ]; then
    echo "🗑️  DISMISSED (not worth tracking):"
    echo ""

    echo "$assessment_content" | awk '
      function wrap(prefix, text, width,    words, n, line, i, indent) {
        indent = "            "
        n = split(text, words, " ")
        line = prefix
        for (i = 1; i <= n; i++) {
          if (length(line) + length(words[i]) + 1 > width && line != prefix) {
            print line
            line = indent words[i]
          } else if (line == prefix) {
            line = line words[i]
          } else {
            line = line " " words[i]
          }
        }
        if (line != "") print line
      }
      /^### .* - DISMISSED/ {
        in_item = 1
        title = $0
        gsub(/^### /, "", title)
        gsub(/ - DISMISSED.*$/, "", title)
        printf "  • %s\n", title
        next
      }
      in_item && /^\*\*Reasoning:\*\*/ {
        reasoning = $0
        gsub(/^\*\*Reasoning:\*\* /, "", reasoning)
        wrap("    Reason: ", reasoning, 76)
        printf "\n"
        in_item = 0
        next
      }
      in_item && /^### / {
        in_item = 0
        printf "\n"
      }
    '
  fi

  # Re-enable errexit
  set -e

  echo ""
  return 0
}

# Format ISO timestamp to human-readable format
# Input: 2025-10-28T20:42:18Z (ISO 8601 UTC)
# Output: Oct 28, 2025 - 2:42 PM MT
format_review_timestamp() {
  local iso_timestamp="$1"
  iso_to_local_display "$iso_timestamp"
}

# Check dependencies
if ! command -v gh &> /dev/null; then
  print_error "GitHub CLI required: brew install gh"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  print_error "jq required: brew install jq"
  exit 1
fi

# Fetch PR review (local sharkrite review comment)
# (header already printed by workflow-runner.sh with PR + issue context)
_JQ_REVIEW_FETCH="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | sort_by(.createdAt) | reverse | .[0]"
REVIEW_JSON=$(gh_safe pr view "$PR_NUMBER" --json comments --jq "$_JQ_REVIEW_FETCH") || {
  if [ -n "$ISSUE_NUMBER" ]; then
    print_error "Failed to fetch review for issue #$ISSUE_NUMBER"
  else
    print_error "Failed to fetch PR #$PR_NUMBER"
  fi
  exit 1
}

if [ "$REVIEW_JSON" = "{}" ] || [ -z "$REVIEW_JSON" ] || [ "$REVIEW_JSON" = "null" ]; then
  # No review found - auto-generate one
  print_status "No review found - generating local review..."
  echo ""

  # Run local review with --post --auto
  LOCAL_REVIEW_SCRIPT="$RITE_LIB_DIR/core/local-review.sh"
  if [ -f "$LOCAL_REVIEW_SCRIPT" ]; then
    if "$LOCAL_REVIEW_SCRIPT" "$PR_NUMBER" --post --auto; then
      print_success "Local review posted"
      echo ""

      # Re-fetch the review we just posted
      sleep 2  # Give GitHub a moment to index
      _JQ_REVIEW_REFETCH="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | .[-1]"
      REVIEW_JSON=$(gh_safe pr view "$PR_NUMBER" --json comments --jq "$_JQ_REVIEW_REFETCH") || true

      if [ "$REVIEW_JSON" = "{}" ] || [ -z "$REVIEW_JSON" ] || [ "$REVIEW_JSON" = "null" ]; then
        print_error "Failed to fetch newly posted review"
        exit 1
      fi
    else
      print_error "Local review generation failed"
      exit 1
    fi
  else
    print_error "Local review script not found: $LOCAL_REVIEW_SCRIPT"
    exit 1
  fi
fi

REVIEW_BODY=$(echo "$REVIEW_JSON" | jq -r '.body' 2>/dev/null || echo "")

if [ -z "$REVIEW_BODY" ] || [ "$REVIEW_BODY" = "null" ]; then
  print_error "Review body is empty"
  exit 1
fi

# Save review to temp file for parsing.
# PID-scoped ($$ is stable within this script and inherited by subprocesses)
# so concurrent invocations — same or different PR — get isolated files.
# Fix for issue #345 (2026-06-06): original path /tmp/pr_review_${PR_NUMBER}.txt
# was per-PR only; concurrent runs against the same PR overwrote each other,
# and the glob in cleanup() could wipe a different PR's file mid-run.
REVIEW_FILE="/tmp/pr_review_${PR_NUMBER}_$$.txt"
echo "$REVIEW_BODY" > "$REVIEW_FILE"

if [ -n "$ISSUE_NUMBER" ]; then
  print_success "Review fetched for issue #$ISSUE_NUMBER"
else
  print_success "Review fetched from PR #$PR_NUMBER"
fi
echo ""

# =============================================================================
# Extract model from review metadata for assessment consistency
# =============================================================================

extract_review_model() {
  local review_body="$1"
  local model=$(echo "$review_body" | grep -oE "${RITE_MARKER_REVIEW} model:[a-z0-9-]+" | sed 's/.*model://' | head -1 || true)
  if [ -n "$model" ]; then
    echo "$model"
  else
    echo "$RITE_REVIEW_MODEL"
  fi
}

# extract_review_sha and resolve_pr_head_sha are shared helpers defined in
# lib/utils/review-helper.sh (sourced above). They are NOT defined inline here —
# see review-helper.sh for the canonical implementations.

REVIEW_MODEL=$(extract_review_model "$REVIEW_BODY")
print_info "Review model: $REVIEW_MODEL"
export RITE_ASSESSMENT_MODEL="$REVIEW_MODEL"

# =============================================================================
# Extract structured JSON from review (new format with sharkrite-review-data)
# Falls back to markdown parsing for older reviews
# =============================================================================

extract_review_json() {
  local review_body="$1"
  # Extract JSON from <!-- sharkrite-review-data ... --> block
  local json_block=$(echo "$review_body" | sed -n "/<!-- ${RITE_MARKER_REVIEW_DATA}/,/-->/p" | sed '1d;$d' || true)
  if [ -n "$json_block" ] && echo "$json_block" | jq empty 2>/dev/null; then
    echo "$json_block"
  else
    echo ""
  fi
}

REVIEW_JSON_DATA=$(extract_review_json "$REVIEW_BODY")

if [ -n "$REVIEW_JSON_DATA" ]; then
  print_info "Found structured review data (JSON format)"
  # Parse counts from JSON
  JSON_CRITICAL=$(echo "$REVIEW_JSON_DATA" | jq -r '.summary.critical // 0' 2>/dev/null || echo "0")
  JSON_HIGH=$(echo "$REVIEW_JSON_DATA" | jq -r '.summary.high // 0' 2>/dev/null || echo "0")
  JSON_MEDIUM=$(echo "$REVIEW_JSON_DATA" | jq -r '.summary.medium // 0' 2>/dev/null || echo "0")
  JSON_LOW=$(echo "$REVIEW_JSON_DATA" | jq -r '.summary.low // 0' 2>/dev/null || echo "0")
  JSON_VERDICT=$(echo "$REVIEW_JSON_DATA" | jq -r '.summary.verdict // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
  JSON_ITEMS_COUNT=$(echo "$REVIEW_JSON_DATA" | jq -r '.items | length // 0' 2>/dev/null || echo "0")

  print_info "JSON summary: CRITICAL=$JSON_CRITICAL HIGH=$JSON_HIGH MEDIUM=$JSON_MEDIUM LOW=$JSON_LOW"
  print_info "JSON verdict: $JSON_VERDICT (${JSON_ITEMS_COUNT} items)"

  # Export for use by downstream tools
  export RITE_REVIEW_JSON="$REVIEW_JSON_DATA"
  export RITE_REVIEW_FORMAT="json"
else
  print_info "No structured JSON found - will use markdown parsing"
  export RITE_REVIEW_FORMAT="markdown"
fi

# Check if review is stale (review does not cover the current HEAD commit).
# Runs on every invocation, including retries.
#
# PRIMARY CHECK: SHA-based (deterministic, race-free).
#   Reviews generated after issue #354 embed the HEAD SHA at generation time
#   in the marker: <!-- sharkrite-local-review ... commit:<sha> -->
#   We compare that SHA to the PR's current HEAD:
#     - SHA match      → review is current, proceed to assessment
#     - SHA is ancestor → review is genuinely stale (fix commits pushed after review)
#     - SHA not found  → force-push or SHA absent, treat as stale (log warning)
#
# FALLBACK: Timestamp-based (for older reviews without the commit: attribute).
#   Uses epoch seconds comparison, not string comparison, to avoid format races.
#   This path is preserved for backward compatibility but should rarely be reached
#   once all active reviews are regenerated with the new marker format.
#
# Why SHA is superior to timestamps (issue #354):
#   Timestamps are racy — the review's createdAt from the GitHub API can lag
#   behind the local git commit timestamp by seconds to minutes (eventual
#   consistency). A fix commit pushed at T+1 and a new review generated at T+2
#   can still appear "stale" if the API returns the old review's timestamp.
#   SHAs are deterministic: the review either covers this commit or it doesn't.
if [ "$RETRY_COUNT" -gt 0 ]; then
  print_status "Retry $RETRY_COUNT: Checking review currency..."
else
  print_status "Checking if review is current..."
fi
echo ""

# Always read review timestamp (used for display and fallback comparison)
REVIEW_TIME="${REVIEW_TIME:-$(echo "$REVIEW_JSON" | jq -r '.createdAt' 2>/dev/null)}"

# Extract SHA embedded in the review marker (empty if review predates issue #354)
REVIEW_SHA=$(extract_review_sha "$REVIEW_BODY")

# Get current HEAD SHA for the PR using the authoritative-remote-first strategy.
# resolve_pr_head_sha (from lib/utils/review-helper.sh) prefers the GitHub API
# over local git to avoid false-positive stale verdicts when cwd is the main
# checkout rather than the PR worktree. No WORKTREE_PATH is passed here because
# assess-and-resolve.sh is always invoked with cwd set to the worktree by the
# caller (rite N --assess-and-fix) — the cwd-relative git fallback is correct.
CURRENT_HEAD_SHA=$(resolve_pr_head_sha "$PR_NUMBER")
CURRENT_HEAD_SHA="${CURRENT_HEAD_SHA:-}"

# ---- SHA-based staleness check (primary) ----
_review_is_stale=false
_staleness_method=""

if [ -n "$REVIEW_SHA" ] && [ -n "$CURRENT_HEAD_SHA" ]; then
  _staleness_method="sha"

  if [ "$REVIEW_SHA" = "$CURRENT_HEAD_SHA" ]; then
    # SHA match: review was generated against the exact current HEAD
    print_success "Review is current (SHA match: ${REVIEW_SHA:0:8})"
    echo ""
    _review_is_stale=false

  elif git merge-base --is-ancestor "$REVIEW_SHA" "$CURRENT_HEAD_SHA" 2>/dev/null; then
    # Review SHA is an ancestor of HEAD: fix commits have been pushed since review
    _review_is_stale=true
    print_warning "Review is stale — review covers ${REVIEW_SHA:0:8}, HEAD is ${CURRENT_HEAD_SHA:0:8}"
    echo "  Fix commits were pushed after the review was generated."
    echo ""

  else
    # SHA not found in ancestry chain — force-push during workflow or git object
    # not locally available. Treat as stale but log a warning.
    _review_is_stale=true
    print_warning "Review SHA (${REVIEW_SHA:0:8}) is not an ancestor of HEAD (${CURRENT_HEAD_SHA:0:8})"
    print_info  "This may indicate a force-push occurred during the workflow. Treating as stale."
    echo ""
  fi

else
  # ---- Timestamp-based fallback (for reviews predating issue #354) ----
  _staleness_method="timestamp"

  if [ -z "$REVIEW_SHA" ]; then
    print_info "Review predates SHA embedding — using timestamp comparison (fallback)"
  else
    print_info "HEAD SHA unavailable — using timestamp comparison (fallback)"
  fi

  # Get latest commit timestamp (local git preferred, API fallback)
  get_latest_work_commit_time "." "$PR_NUMBER"

  if [ -n "$LATEST_COMMIT_TIME" ] && [ -n "$REVIEW_TIME" ]; then
    COMMIT_EPOCH=$(iso_to_epoch "$LATEST_COMMIT_TIME")
    REVIEW_EPOCH=$(iso_to_epoch "$REVIEW_TIME")

    if [ "$COMMIT_EPOCH" -gt "$REVIEW_EPOCH" ]; then
      _review_is_stale=true
      print_warning "Review is stale — commits pushed after review (timestamp comparison)"
      echo "  Review created: $REVIEW_TIME"
      echo "  Latest commit:  $LATEST_COMMIT_TIME"
      echo ""
    fi
  fi
fi

# ---- Handle stale review ----
if [ "$_review_is_stale" = "true" ]; then
  # Before routing back, check if there is already a newer review posted
  # (can happen if a concurrent run already regenerated it).
  _JQ_ALL_REVIEWS="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | sort_by(.createdAt) | reverse"
  ALL_REVIEWS=$(gh_safe pr view "$PR_NUMBER" --json comments --jq "$_JQ_ALL_REVIEWS")
  ALL_REVIEWS="${ALL_REVIEWS:-[]}"

  # Try to find a review that covers the current HEAD (SHA-based when available,
  # timestamp fallback for older reviews)
  _found_current_review=false
  if [ -n "$CURRENT_HEAD_SHA" ]; then
    # SHA-based: check if any existing review's commit: attribute matches current HEAD
    _all_review_bodies=$(echo "$ALL_REVIEWS" | jq -r '.[].body' 2>/dev/null || true)
    if echo "$_all_review_bodies" | grep -qE "${RITE_MARKER_REVIEW}[^>]*commit:${CURRENT_HEAD_SHA}"; then
      _found_current_review=true
      # Load the review whose SHA matches HEAD
      REVIEW_JSON=$(echo "$ALL_REVIEWS" | \
        jq --arg sha "$CURRENT_HEAD_SHA" \
          '[.[] | select(.body | test("'"${RITE_MARKER_REVIEW}"'[^>]*commit:" + $sha))] | .[0]' \
          2>/dev/null || echo "")
      if [ -n "$REVIEW_JSON" ] && [ "$REVIEW_JSON" != "null" ] && [ "$REVIEW_JSON" != "" ]; then
        REVIEW_BODY=$(echo "$REVIEW_JSON" | jq -r '.body' 2>/dev/null || true)
        if [ -n "$REVIEW_BODY" ]; then
          echo "$REVIEW_BODY" > "$REVIEW_FILE"
          print_success "Found existing review for current HEAD (${CURRENT_HEAD_SHA:0:8}) — using it"
          echo ""
          _review_is_stale=false
        else
          _found_current_review=false
        fi
      else
        _found_current_review=false
      fi
    fi
  fi

  if [ "$_found_current_review" = "false" ] && [ "$_staleness_method" = "timestamp" ]; then
    # Timestamp fallback: look for a review created after the latest commit
    get_latest_work_commit_time "." "$PR_NUMBER"
    if [ -n "${LATEST_COMMIT_TIME:-}" ]; then
      COMMIT_EPOCH=$(iso_to_epoch "$LATEST_COMMIT_TIME")
      # Compare using epoch seconds (not jq string comparison) for reliable cross-format matching
      NEWER_REVIEW_COUNT=$(echo "$ALL_REVIEWS" | jq '[.[] | .createdAt] | map(sub("Z$";"") | split("T") | .[0] + "T" + .[1]) | map(. > "'"$LATEST_COMMIT_TIME"'" | if . then 1 else 0 end) | add // 0' 2>/dev/null || echo "0")
      if [ "$NEWER_REVIEW_COUNT" -eq 0 ] && [ -n "$ALL_REVIEWS" ]; then
        _newest_review_time=$(echo "$ALL_REVIEWS" | jq -r '.[0].createdAt // ""' 2>/dev/null)
        if [ -n "$_newest_review_time" ]; then
          _newest_epoch=$(iso_to_epoch "$_newest_review_time")
          if [ "$_newest_epoch" -gt "$COMMIT_EPOCH" ]; then
            NEWER_REVIEW_COUNT=1
          fi
        fi
      fi
      if [ "$NEWER_REVIEW_COUNT" -gt 0 ]; then
        _found_current_review=true
        REVIEW_JSON=$(echo "$ALL_REVIEWS" | jq '.[0]' 2>/dev/null)
        REVIEW_BODY=$(echo "$REVIEW_JSON" | jq -r '.body' 2>/dev/null)
        echo "$REVIEW_BODY" > "$REVIEW_FILE"
        print_success "Found newer review after latest commit — using that instead"
        echo ""
        _review_is_stale=false
      fi
    fi
  fi

  # If still stale after checking all existing reviews, route back to Phase 2
  if [ "$_review_is_stale" = "true" ]; then
    # No current review exists. Route back to Phase 2 for proper
    # push + review generation via the standard pipeline (create-pr.sh
    # → local-review.sh). Phase 3 should only assess, not generate.
    print_info "No current review found — routing back to review phase"
    exit 3
  fi
fi

# ============================================================================
# RAW REVIEW DISPLAY: Show what Claude will see (compact format for debugging)
# ============================================================================

# Format timestamp for display
FORMATTED_TIME=$(format_review_timestamp "$REVIEW_TIME")

print_header "📄 Code Review: $FORMATTED_TIME"

# Compact display: format review using dedicated formatter
if [ -f "$RITE_LIB_DIR/utils/format-review.sh" ]; then
  "$RITE_LIB_DIR/utils/format-review.sh" "$REVIEW_FILE"
else
  # Fallback: simple compact display
  cat "$REVIEW_FILE" | sed '/^$/N;/^\n$/d'
  print_warning "format-review.sh not found - using fallback display"
fi
echo ""

# ============================================================================
# GATE FINDINGS: Load post-commit gate results (make check + bats -r tests/)
# Gate findings skip LLM categorization — they are objective failures that
# are unconditionally ACTIONABLE_NOW. Prepended to the review assessment output.
# Source: RITE_GATE_FINDINGS env var (set by workflow-runner.sh) or fallback path.
# ============================================================================

# Detect gate findings file (env var from workflow-runner, or fallback path)
_GATE_FINDINGS_FILE="${RITE_GATE_FINDINGS:-}"
if [ -z "$_GATE_FINDINGS_FILE" ] && [ -n "$PR_NUMBER" ]; then
  _GATE_FINDINGS_FILE="${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}/gate-findings-${PR_NUMBER}.json"
fi

GATE_PREPEND_ITEMS=""
GATE_NOW_COUNT=0

if [ -n "${_GATE_FINDINGS_FILE:-}" ] && [ -f "$_GATE_FINDINGS_FILE" ] && command -v jq >/dev/null 2>&1; then
  _gate_skipped=$(jq -r '.skipped // false' "$_GATE_FINDINGS_FILE" 2>/dev/null || echo "false")
  _gate_exit_code=$(jq -r '.exit_code // 0' "$_GATE_FINDINGS_FILE" 2>/dev/null || echo "0")
  # Guard: jq can return "null" or empty if the field is missing/malformed, which would
  # crash the integer test below with "integer expression expected" under set -e.
  # Treat any non-numeric value as 0 (safe: means "passed", gate is not blocked).
  case "$_gate_exit_code" in
    ''|*[!0-9]*) _gate_exit_code=0 ;;
  esac

  if [ "$_gate_skipped" != "true" ] && [ "$_gate_exit_code" -ne 0 ]; then
    # Build [GATE] ACTIONABLE_NOW items from lint failures
    while IFS= read -r _lint_item; do
      _lint_file=$(echo "$_lint_item" | jq -r '.file // ""' 2>/dev/null || true)
      _lint_line=$(echo "$_lint_item" | jq -r '.line // ""' 2>/dev/null || true)
      _lint_rule=$(echo "$_lint_item" | jq -r '.rule // "lint"' 2>/dev/null || true)
      _lint_msg=$(echo "$_lint_item" | jq -r '.message // ""' 2>/dev/null || true)
      if [ -n "$_lint_msg" ]; then
        GATE_PREPEND_ITEMS+="### [GATE] make check: ${_lint_rule} — ${_lint_file}:${_lint_line} - ACTIONABLE_NOW
**Severity:** HIGH
**Category:** Lint failure (objective — no LLM categorization needed)
**Location:** ${_lint_file}:${_lint_line}
**Fix Effort:** Quick (lint rule violation)
**Reasoning:** \`make check\` (post-commit gate) reported this violation. Fix: address the lint rule violation at the indicated location.
**Message:** ${_lint_msg}

"
        GATE_NOW_COUNT=$(( GATE_NOW_COUNT + 1 ))
      fi
    done < <(jq -c '.lint[]' "$_GATE_FINDINGS_FILE" 2>/dev/null || true)

    # Build [GATE] ACTIONABLE_NOW items from test failures
    while IFS= read -r _test_item; do
      _test_file=$(echo "$_test_item" | jq -r '.file // "bats"' 2>/dev/null || true)
      _test_name=$(echo "$_test_item" | jq -r '.test_name // "unknown test"' 2>/dev/null || true)
      _test_reason=$(echo "$_test_item" | jq -r '.reason // "assertion failed"' 2>/dev/null || true)
      if [ -n "$_test_name" ]; then
        GATE_PREPEND_ITEMS+="### [GATE] bats failure: ${_test_file} - ACTIONABLE_NOW
**Severity:** HIGH
**Category:** Test failure (objective — no LLM categorization needed)
**Location:** ${_test_file}
**Fix Effort:** Medium (failing test needs investigation)
**Reasoning:** \`bats -r tests/\` (post-commit gate) reported this failure. Fix: identify root cause and address the failing test assertion.
**Test:** ${_test_name}
**Reason:** ${_test_reason}

"
        GATE_NOW_COUNT=$(( GATE_NOW_COUNT + 1 ))
      fi
    done < <(jq -c '.tests[]' "$_GATE_FINDINGS_FILE" 2>/dev/null || true)

    # --- Synthetic block for empty-findings gate failures ---
    # When the gate exit code is non-zero but both loops above produced zero
    # items (e.g. the test runner was unavailable — exit 127 — so no TAP
    # "not ok" lines were emitted, and no lint output was parseable), the
    # non-zero exit_code is authoritative proof that verification failed.
    # Without this synthesis the failure is silently swallowed: GATE_NOW_COUNT
    # stays 0, the assessment sees no [GATE] items, and the PR merges unverified.
    #
    # This was the live failure mode for LeadFlow PR #400 (issue #331,
    # 2026-06-30): jest 127 × 3 retries → empty arrays → "ready to merge".
    # The same hole opens for any non-bats runner (pytest/cargo/go) on a plain
    # non-TAP exit-1. (Issue #799)
    if [ "$GATE_NOW_COUNT" -eq 0 ]; then
      # Read the reason field from the gate JSON if present (e.g. "runner_unavailable").
      # Falls back to a generic description naming the raw exit code.
      _gate_reason_field=$(jq -r '.reason // ""' "$_GATE_FINDINGS_FILE" 2>/dev/null || true)
      if [ -n "$_gate_reason_field" ]; then
        _gate_failure_desc="gate failure: ${_gate_reason_field} (exit_code=${_gate_exit_code})"
      else
        _gate_failure_desc="gate failure: non-zero exit (exit_code=${_gate_exit_code}) with no parseable findings"
      fi
      GATE_PREPEND_ITEMS+="### [GATE] ${_gate_failure_desc} - ACTIONABLE_NOW
**Severity:** HIGH
**Category:** Gate failure (objective — no LLM categorization needed)
**Fix Effort:** Medium (investigate why the test runner produced no parseable output)
**Reasoning:** The post-commit gate exited non-zero (exit_code=${_gate_exit_code}) but produced zero parseable lint or test findings. This means verification did not complete — the gate CANNOT confirm the suite passed. A non-zero exit with no findings is still a blocking failure; merging unverified code is not acceptable. Investigate the runner (check for missing dependencies, bootstrap failures, or non-TAP output) and resolve the underlying issue before merging.

"
      GATE_NOW_COUNT=$(( GATE_NOW_COUNT + 1 ))
    fi

    if [ "$GATE_NOW_COUNT" -gt 0 ]; then
      print_status "Post-commit gate found $GATE_NOW_COUNT failure(s) — prepending as [GATE] ACTIONABLE_NOW items"
    fi
  fi

  # Delete after consumption so stale findings cannot leak into a later resume or
  # standalone --assess-and-fix run.  The env-var path (RITE_GATE_FINDINGS) is
  # always preferred; the fallback file (gate-findings-N.json) is the one that
  # persists across process boundaries, so it is the one that must be cleaned up.
  rm -f "${_GATE_FINDINGS_FILE:-}" 2>/dev/null || true
fi

# ============================================================================
# SMART ASSESSMENT: Use Claude CLI to filter ACTIONABLE items
# This runs BEFORE displaying summary so counts are accurate
# ============================================================================

# Early exit: if the review has zero findings AND gate found no failures,
# skip assessment entirely and go straight to merge.
# Guard: when gate found failures, we MUST run the fix loop regardless of review verdict.
REVIEW_FINDINGS_LINE=$(grep -oE "Findings: CRITICAL: [0-9]+ [|] HIGH: [0-9]+ [|] MEDIUM: [0-9]+ [|] LOW: [0-9]+" "$REVIEW_FILE" 2>/dev/null | head -1 || true)
if [ -n "$REVIEW_FINDINGS_LINE" ]; then
  REVIEW_TOTAL_FINDINGS=$(echo "$REVIEW_FINDINGS_LINE" | grep -oE "[0-9]+" | awk '{sum += $1} END {print sum}' || true)
  if [ "${REVIEW_TOTAL_FINDINGS:-0}" -eq 0 ] && [ "${GATE_NOW_COUNT:-0}" -eq 0 ]; then
    print_header "🦈 Smart Assessment (Sharkrite)"
    print_success "Review has zero findings and gate passed — skipping assessment, proceeding to merge"
    echo ""
    exit 0
  fi
fi

print_header "🦈 Smart Assessment (Sharkrite)"

ACTIONABLE_COUNT=0

if [ -f "$RITE_LIB_DIR/core/assess-review-issues.sh" ]; then
  # Only show retry count if actually retrying (count > 0)
  if [ "$RETRY_COUNT" -gt 0 ]; then
    print_status "Running review assessment (retry $RETRY_COUNT/3)..."
  else
    print_status "Running review assessment on all review issues..."
  fi

  # Run smart assessment - pass --auto flag if in auto mode
  # assess-review-issues.sh performs HOLISTIC analysis of entire PR comment
  # and categorizes ALL contents, outputting filtered ACTIONABLE items to stdout
  # Use process substitution to show stderr in real-time (Claude output streams to terminal)
  ASSESSMENT_STDERR=$(mktemp)
  ASSESSMENT_EXIT_CODE=0
  # Export source issue number so assess-review-issues.sh can scope dedup searches
  export RITE_ISSUE_NUMBER="${ISSUE_NUMBER:-}"
  # Per-item issue passback: assess-review-issues.sh writes created issue numbers
  # (one per line) to this temp file so we can skip the consolidated rollup when
  # per-item issues already cover the ACTIONABLE_LATER findings.
  _per_item_issues_file=$(mktemp)
  export RITE_PER_ITEM_ISSUES_FILE="$_per_item_issues_file"
  if [ "$AUTO_MODE" = true ]; then
    ASSESSMENT_RESULT=$("$RITE_LIB_DIR/core/assess-review-issues.sh" "$PR_NUMBER" "$REVIEW_FILE" --auto 2> >(tee "$ASSESSMENT_STDERR" >&2)) || ASSESSMENT_EXIT_CODE=$?
  else
    ASSESSMENT_RESULT=$("$RITE_LIB_DIR/core/assess-review-issues.sh" "$PR_NUMBER" "$REVIEW_FILE" 2> >(tee "$ASSESSMENT_STDERR" >&2)) || ASSESSMENT_EXIT_CODE=$?
  fi
  # Wait for tee subprocess to finish writing
  wait
  ASSESSMENT_ERROR=$(cat "$ASSESSMENT_STDERR")
  rm -f "$ASSESSMENT_STDERR"

  # Read per-item issue numbers written by assess-review-issues.sh.
  # Format: one issue number per line (e.g. "459\n460\n").
  # Non-empty → assess-review-issues.sh already filed per-item issues for
  # ACTIONABLE_LATER findings; we skip the consolidated rollup and post a
  # PR comment summary instead (defect #2 fix).
  PER_ITEM_ISSUES=""
  if [ -n "${_per_item_issues_file:-}" ] && [ -f "$_per_item_issues_file" ]; then
    PER_ITEM_ISSUES=$(cat "$_per_item_issues_file" 2>/dev/null || true)
    rm -f "$_per_item_issues_file"
    unset RITE_PER_ITEM_ISSUES_FILE
  fi
  unset _per_item_issues_file

  if [ $ASSESSMENT_EXIT_CODE -eq 0 ] && [ -n "$ASSESSMENT_RESULT" ] && [ "$ASSESSMENT_RESULT" != "ALL_ITEMS" ]; then
    print_success "Smart assessment complete - three-state categorization applied"

    # Prepend [GATE] ACTIONABLE_NOW items from the post-commit gate (make check + bats).
    # Gate findings skip LLM categorization — they are objective failures.
    # Prepending (not appending) ensures they appear at the top of the fix-mode findings
    # list and are visible to Claude before the review items.
    if [ -n "${GATE_PREPEND_ITEMS:-}" ]; then
      ASSESSMENT_RESULT="${GATE_PREPEND_ITEMS}${ASSESSMENT_RESULT}"
    fi

    # Parse three-state actionability (keep in variable, no temp file!)
    # IMPORTANT: Match structured headers only (^### Title - STATE) to avoid
    # counting mentions of state names in reasoning text
    ACTIONABLE_NOW_COUNT=$(echo "$ASSESSMENT_RESULT" | grep -c "^### .* - ACTIONABLE_NOW" || true)
    ACTIONABLE_LATER_COUNT=$(echo "$ASSESSMENT_RESULT" | grep -c "^### .* - ACTIONABLE_LATER" || true)
    DISMISSED_COUNT=$(echo "$ASSESSMENT_RESULT" | grep -c "^### .* - DISMISSED" || true)

    # Print detailed assessment breakdown FIRST (shows reasoning for each item)
    print_assessment_details "$ASSESSMENT_RESULT" || {
      print_warning "Could not parse assessment details (format may be unexpected)"
      echo ""
    }

    # Print decision summary AFTER details (acts as summary/TL;DR).
    # This is the single authoritative summary — three-state (NOW/LATER/
    # DISMISSED) is the axis the workflow actually decides on. Loud per-line
    # emoji + Total mirror the old severity rollup that used to print below.
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 Assessment Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔧 ACTIONABLE_NOW: $ACTIONABLE_NOW_COUNT items - fix now"
    echo "📝 ACTIONABLE_LATER: $ACTIONABLE_LATER_COUNT items - defer to tech-debt"
    echo "🗑️  DISMISSED: $DISMISSED_COUNT items - not worth tracking"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Total actionable: $((ACTIONABLE_NOW_COUNT + ACTIONABLE_LATER_COUNT)) items"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Diagnostic logging for health reports
    _diag "ASSESSMENT issue=${ISSUE_NUMBER} retry=${RETRY_COUNT} now=${ACTIONABLE_NOW_COUNT} later=${ACTIONABLE_LATER_COUNT} dismissed=${DISMISSED_COUNT}"

    # Decision tree based on three-state counts
    if [ "$ACTIONABLE_NOW_COUNT" -eq 0 ] && [ "$ACTIONABLE_LATER_COUNT" -eq 0 ]; then
      # Guard: gate findings unconditionally force a fix loop even when the LLM
      # dismissed all review items. This mirrors the protection in the else-branch
      # (line ~982) where assessment fails. GATE_NOW_COUNT is the authoritative
      # count — it is set from structured JSON, not from header-string matching,
      # so it cannot be lost by a header-format mismatch.
      if [ "${GATE_NOW_COUNT:-0}" -gt 0 ]; then
        print_status "Post-commit gate found $GATE_NOW_COUNT failure(s) — forcing fix loop despite all-dismissed review"
        echo "$ASSESSMENT_RESULT" >&3
        exit 2
      fi
      print_success "All items dismissed — ready to merge!"

      exit 0

    elif [ "$ACTIONABLE_NOW_COUNT" -eq 0 ] && [ "$ACTIONABLE_LATER_COUNT" -gt 0 ]; then
      # Guard: gate findings unconditionally force a fix loop even when the LLM
      # found only ACTIONABLE_LATER items in the review. Same rationale as above.
      if [ "${GATE_NOW_COUNT:-0}" -gt 0 ]; then
        print_status "Post-commit gate found $GATE_NOW_COUNT failure(s) — forcing fix loop despite no NOW review items"
        echo "$ASSESSMENT_RESULT" >&3
        exit 2
      fi
      # Only ACTIONABLE_LATER items.
      print_success "No immediate fixes needed"

      # Dual-filing fix (defect #2): assess-review-issues.sh already created per-item
      # issues for each ACTIONABLE_LATER finding. Skip the consolidated rollup and post
      # a PR comment listing those issues instead.
      if [ -n "${PER_ITEM_ISSUES:-}" ]; then
        _per_item_count=$(echo "$PER_ITEM_ISSUES" | grep -c "^[0-9]" || true)
        print_success "Per-item issues already filed by assess-review-issues.sh: $_per_item_count issue(s)"
        print_info "Skipping consolidated rollup — per-item issues are the canonical record"
        # Post a summary PR comment so the PR has a visible record
        SKIP_ROLLUP_DUE_TO_PER_ITEM=true
        FILTERED_ASSESSMENT="$ASSESSMENT_RESULT"
      else
        print_status "Creating tech-debt issue for $ACTIONABLE_LATER_COUNT deferred items..."
        # Set flag to create tech-debt issue, then exit 0 to allow merge
        CREATE_SECURITY_DEBT=true
        FILTERED_ASSESSMENT="$ASSESSMENT_RESULT"
      fi
      # Will post comment or create issue below, then exit 0

    elif [ "$ACTIONABLE_NOW_COUNT" -gt 0 ]; then
      # ACTIONABLE_NOW items exist — always service them in the fix loop.
      # NOW is a scope judgment (in-scope + completable in this PR), not a
      # severity filter. An item classified NOW is fixed before merge; anything
      # deferrable must be classified ACTIONABLE_LATER or DISMISSED instead.
      # See: docs/architecture/behavioral-design.md →
      # "Fix-loop policy: NOW means fixed, LATER means deferred".
      #
      # Severity breakdown — computed once, reused below.
      CRITICAL_NOW_COUNT=$(echo "$ASSESSMENT_RESULT" | grep -A 2 "^### .* - ACTIONABLE_NOW" | grep -ci "Severity:.*CRITICAL" || true)
      HIGH_NOW_COUNT=$(echo "$ASSESSMENT_RESULT" | grep -A 2 "^### .* - ACTIONABLE_NOW" | grep -ci "Severity:.*HIGH" || true)

      # Check retry limit for ACTIONABLE_NOW items
      if [ "$RETRY_COUNT" -ge 3 ]; then
        print_warning "At retry limit ($RETRY_COUNT/3) with $ACTIONABLE_NOW_COUNT ACTIONABLE_NOW items remaining"

        if [ "$CRITICAL_NOW_COUNT" -gt 0 ]; then
          print_critical "$CRITICAL_NOW_COUNT CRITICAL items remain at retry limit"
          print_error "Cannot merge - blocking issues require manual intervention"
          print_info "Will create follow-up issue and exit with code 1"
          # Set flag to create CRITICAL follow-up issue, then exit 1
          CREATE_CRITICAL_FOLLOWUP=true
          FILTERED_ASSESSMENT="$ASSESSMENT_RESULT"
        else
          # Gate-origin findings are non-deferrable: a known-red test must never
          # reach main, even at the retry cap.  Distinguish [GATE] items (objective
          # test/lint failures) from LLM-severity HIGH review findings so that only
          # the former block the merge.  Non-gate HIGH review findings continue to
          # follow the defer+tech-debt path below.
          # "### [GATE]" is the structured header prefix injected at lines 1004/1023.
          GATE_NOW_COUNT_REMAINING=$(echo "$ASSESSMENT_RESULT" | grep -c "^### \[GATE\].*- ACTIONABLE_NOW" || true)

          if [ "${GATE_NOW_COUNT_REMAINING:-0}" -gt 0 ]; then
            # [GATE] items are objective failures — block the merge, same as CRITICAL.
            print_critical "$GATE_NOW_COUNT_REMAINING [GATE] item(s) remain at retry limit (objective test/lint failure)"
            print_error "Cannot merge — gate-origin failures are non-deferrable (known-red test must not reach main)"
            print_info "Will create follow-up issue and exit with code 1"
            CREATE_CRITICAL_FOLLOWUP=true
            FILTERED_ASSESSMENT="$ASSESSMENT_RESULT"
          else
            # Final-retry shoe-horn fix (defect #5): only HIGH findings are worth
            # filing at retry limit. MEDIUM/LOW findings that the fix loop couldn't
            # address in 3 cycles are nice-to-haves — filing them clutters the backlog
            # without adding triage value (they were already low-priority and couldn't
            # be auto-fixed). Drop them with a log message.
            if [ "$HIGH_NOW_COUNT" -gt 0 ]; then
              print_success "No CRITICAL/[GATE] items remain ($HIGH_NOW_COUNT HIGH item(s) — filing tech-debt for HIGH only)"
              print_status "Creating tech-debt issue for HIGH items (dropping MEDIUM/LOW)..."
            else
              print_success "No CRITICAL/HIGH/[GATE] items remain at retry limit — all remaining are MEDIUM/LOW"
              print_info "Dropping MEDIUM/LOW findings (not worth follow-up backlog space at retry limit)"
            fi
            # Treat remaining ACTIONABLE_NOW as ACTIONABLE_LATER at retry limit.
            # MEDIUM/LOW will be filtered out by the extraction step (DROP_RETRY_MEDIUM_LOW=true).
            CREATE_SECURITY_DEBT=true
            FILTERED_ASSESSMENT="$ASSESSMENT_RESULT"
            DROP_RETRY_MEDIUM_LOW=true
          fi
        fi

        # Also handle ACTIONABLE_LATER items if they exist
        if [ "$ACTIONABLE_LATER_COUNT" -gt 0 ]; then
          print_info "Note: $ACTIONABLE_LATER_COUNT ACTIONABLE_LATER items will also be included in tech-debt"
        fi

        # Extract counts from FILTERED_ASSESSMENT for Issue Summary display
        # This ensures counts are populated before the summary is shown
        # Match structured headers (^### Title - STATE) then check severity on next lines
        if [ -n "${FILTERED_ASSESSMENT:-}" ]; then
          _ACTIONABLE_ITEMS=$(echo "$FILTERED_ASSESSMENT" | grep -c "^### .* - ACTIONABLE_\(NOW\|LATER\)" || true)
          if [ "$_ACTIONABLE_ITEMS" -gt 0 ]; then
            CRITICAL_COUNT=$(echo "$FILTERED_ASSESSMENT" | grep -A 5 "^### .* - ACTIONABLE_\(NOW\|LATER\)" | grep -c "Severity:.*CRITICAL" || true)
            HIGH_COUNT=$(echo "$FILTERED_ASSESSMENT" | grep -A 5 "^### .* - ACTIONABLE_\(NOW\|LATER\)" | grep -c "Severity:.*HIGH" || true)
            MEDIUM_COUNT=$(echo "$FILTERED_ASSESSMENT" | grep -A 5 "^### .* - ACTIONABLE_\(NOW\|LATER\)" | grep -c "Severity:.*MEDIUM" || true)
            LOW_COUNT=$(echo "$FILTERED_ASSESSMENT" | grep -A 5 "^### .* - ACTIONABLE_\(NOW\|LATER\)" | grep -c "Severity:.*LOW" || true)
          fi
          CRITICAL_COUNT=${CRITICAL_COUNT:-0}
          HIGH_COUNT=${HIGH_COUNT:-0}
          MEDIUM_COUNT=${MEDIUM_COUNT:-0}
          LOW_COUNT=${LOW_COUNT:-0}
        fi

      else
        # Normal loop: ACTIONABLE_NOW items exist, retry count < 3
        print_info "$ACTIONABLE_NOW_COUNT ACTIONABLE_NOW items found - will loop to fix" >&2

        if [ "$ACTIONABLE_LATER_COUNT" -gt 0 ]; then
          print_info "Note: $ACTIONABLE_LATER_COUNT ACTIONABLE_LATER items will be deferred until fixes complete" >&2
        fi

        print_info "Outputting holistic assessment to stdout (pipe-friendly)" >&2

        # Echo the assessment result directly to original stdout (fd 3)
        # This includes both ACTIONABLE_NOW and ACTIONABLE_LATER items
        # claude-workflow.sh will focus on ACTIONABLE_NOW
        echo "$ASSESSMENT_RESULT" >&3

        print_info "Exiting with code 2 to restart PR cycle and fix ACTIONABLE_NOW issues" >&2
        exit 2
      fi
    fi

  else
    print_warning "Smart assessment failed or returned unexpected result"
    if [ -n "$ASSESSMENT_ERROR" ]; then
      echo ""
      echo "Assessment error output:"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "$ASSESSMENT_ERROR"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
    fi
    if [ -n "$ASSESSMENT_RESULT" ]; then
      echo "Assessment result (first 500 chars):"
      echo "${ASSESSMENT_RESULT:0:500}"
      echo ""
    fi
    print_info "Falling back to raw review count for decision"
    # Parse counts from raw review
    CRITICAL_COUNT=$(sed -n '/^## .*[Cc]ritical/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
    CRITICAL_COUNT=${CRITICAL_COUNT:-0}
    HIGH_COUNT=$(sed -n '/^## .*[Hh]igh/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
    HIGH_COUNT=${HIGH_COUNT:-0}
    MEDIUM_COUNT=$(sed -n '/^## .*[Mm]edium/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
    MEDIUM_COUNT=${MEDIUM_COUNT:-0}
    LOW_COUNT=$(sed -n '/^## .*[Ll]ow/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
    LOW_COUNT=${LOW_COUNT:-0}
    ACTIONABLE_COUNT=$((CRITICAL_COUNT + HIGH_COUNT + MEDIUM_COUNT + LOW_COUNT))

    # Even if LLM assessment failed, gate findings must still be surfaced.
    # If gate found failures, override ACTIONABLE_COUNT to force the fix loop.
    if [ "${GATE_NOW_COUNT:-0}" -gt 0 ]; then
      print_status "Post-commit gate found $GATE_NOW_COUNT failure(s) — forcing fix loop"
      ASSESSMENT_RESULT="${GATE_PREPEND_ITEMS}"
      ACTIONABLE_NOW_COUNT="$GATE_NOW_COUNT"
      ACTIONABLE_LATER_COUNT=0
      DISMISSED_COUNT=0
      # Contract (#821): fix mode fetches the assessment from the PR comment
      # when invoked with a PR number — the fd-3 echo below alone is invisible
      # to it. Post the minimal assessment comment before exiting 2; on post
      # failure still exit 2 (the helper prints the loud warning).
      _post_gate_fallback_assessment_comment "$PR_NUMBER" "$GATE_PREPEND_ITEMS" "$GATE_NOW_COUNT" || true
      echo "$ASSESSMENT_RESULT" >&3
      exit 2
    fi
  fi

else
  print_warning "assess-review-issues.sh not found - treating all issues as actionable"
  # Parse counts from raw review
  CRITICAL_COUNT=$(sed -n '/^## .*[Cc]ritical/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
  CRITICAL_COUNT=${CRITICAL_COUNT:-0}
  HIGH_COUNT=$(sed -n '/^## .*[Hh]igh/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
  HIGH_COUNT=${HIGH_COUNT:-0}
  MEDIUM_COUNT=$(sed -n '/^## .*[Mm]edium/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
  MEDIUM_COUNT=${MEDIUM_COUNT:-0}
  LOW_COUNT=$(sed -n '/^## .*[Ll]ow/,/^##[^#]/p' "$REVIEW_FILE" 2>/dev/null | grep '^### [0-9]' 2>/dev/null | wc -l | tr -d ' ' || true)
  LOW_COUNT=${LOW_COUNT:-0}
  ACTIONABLE_COUNT=$((CRITICAL_COUNT + HIGH_COUNT + MEDIUM_COUNT + LOW_COUNT))
fi

echo ""

# Defensive: ensure severity counts are numeric before the follow-up block
# reads them. The three-state Assessment Summary printed above is the single
# user-facing breakdown; these severity counts feed only the tech-debt issue
# body and are normally recomputed from FILTERED_CONTENT at follow-up creation.
# (The old severity "Issue Summary" display that lived here misreported 0/0/0/0
# on the defer/later paths — it predated the three-state system. Removed.)
CRITICAL_COUNT=${CRITICAL_COUNT:-0}
HIGH_COUNT=${HIGH_COUNT:-0}
MEDIUM_COUNT=${MEDIUM_COUNT:-0}
LOW_COUNT=${LOW_COUNT:-0}

# ============================================================================
# FOLLOW-UP ISSUE CREATION
# Reached when ACTIONABLE_LATER items need tech-debt issues, or
# when retry limit is hit with remaining ACTIONABLE_NOW/CRITICAL items.
# ============================================================================

# Skip old decision tree if we already handled it above
if [ "${CREATE_CRITICAL_FOLLOWUP:-false}" = "false" ] && [ "${CREATE_SECURITY_DEBT:-false}" = "false" ]; then
  print_info "No follow-up issues needed - assessment handled everything"
  exit 0
fi

# Determine the merge decision NOW, before follow-up issue creation.
# The merge decision is based solely on assessment results (CRITICAL items at retry
# limit = block merge; otherwise = allow merge). If follow-up issue creation fails,
# _followup_creation_failed=true is set and the final summary exits 1 — follow-up
# creation failure is NOT silent.
MERGE_EXIT_CODE=0
# Tracks whether gh issue create failed inside set +e block; checked at final summary.
_followup_creation_failed=false
if [ "${CREATE_CRITICAL_FOLLOWUP:-false}" = "true" ]; then
  # CRITICAL items at retry limit — genuinely cannot merge
  MERGE_EXIT_CODE=1
fi

# Handle tech-debt case (retry limit reached, no CRITICAL items)
if [ "${CREATE_SECURITY_DEBT:-false}" = "true" ]; then
  print_status "Creating tech-debt issue with remaining HIGH/MEDIUM/LOW items..."

  # Use filtered review for tech-debt issue
  FOLLOWUP_LABEL="tech-debt"
  FOLLOWUP_TITLE="Tech Debt: Review feedback from PR #$PR_NUMBER"
  CREATE_FOLLOWUP_ISSUES=true
  CREATE_LOW_BATCH=false  # Items already grouped in filtered review
fi

# Handle critical follow-up case (retry limit reached, CRITICAL items remain)
if [ "${CREATE_CRITICAL_FOLLOWUP:-false}" = "true" ]; then
  print_status "Creating CRITICAL follow-up issue for manual intervention..."

  # Use filtered review for critical follow-up
  FOLLOWUP_LABEL="review-follow-up"
  FOLLOWUP_TITLE="CRITICAL: Review feedback from PR #$PR_NUMBER"
  CREATE_FOLLOWUP_ISSUES=true
  CREATE_LOW_BATCH=false
fi

# When per-item issues already cover all ACTIONABLE_LATER findings, post a PR
# comment that lists those issues so the PR has a machine-readable summary record.
# This replaces the consolidated rollup (defect #2 fix).
if [ "${SKIP_ROLLUP_DUE_TO_PER_ITEM:-false}" = "true" ] && [ -n "${PER_ITEM_ISSUES:-}" ]; then
  print_header "📝 Follow-up Issues Summary (per-item — no rollup)"
  _per_item_refs=""
  while IFS= read -r _num; do
    [ -z "$_num" ] && continue
    _per_item_refs="${_per_item_refs}#${_num} "
  done <<< "$PER_ITEM_ISSUES"
  _per_item_refs=$(echo "$_per_item_refs" | sed 's/[[:space:]]*$//' || true)
  # Emit one machine-readable marker per issue number so undo/audit/merge consumers
  # (which grep for ${RITE_MARKER_FOLLOWUP}:[0-9]+) can find each filed issue.
  _per_item_markers=""
  while IFS= read -r _mnum; do
    [ -z "$_mnum" ] && continue
    _per_item_markers="${_per_item_markers}<!-- ${RITE_MARKER_FOLLOWUP}:${_mnum} -->
"
  done <<< "$PER_ITEM_ISSUES"
  _summary_comment="${_per_item_markers}📋 **Follow-up issues filed (per-item):** ${_per_item_refs}

Each deferred finding has its own prioritized issue — no consolidated rollup needed."
  _summary_file=$(mktemp)
  printf '%s' "$_summary_comment" > "$_summary_file"
  _summary_stderr_file=$(mktemp)
  if gh_safe pr comment "$PR_NUMBER" --body-file "$_summary_file" 2>"$_summary_stderr_file"; then
    print_success "Posted per-item follow-up summary to PR #$PR_NUMBER"
  else
    # Comment failed — per-item issues are still filed on GitHub, but the PR
    # has no machine-readable summary marker linking to them.  Save the comment
    # body as a recovery artifact so it can be re-posted manually after the
    # network/API issue is resolved.
    _summary_stderr=$(cat "$_summary_stderr_file" 2>/dev/null || true)
    print_warning "Could not post per-item summary comment to PR #$PR_NUMBER (per-item issues are still filed)"
    [ -n "$_summary_stderr" ] && print_warning "gh error: $_summary_stderr"
    # Intentionally NOT PID-scoped (deviation from #345 convention).
    # This is a persistent recovery artifact in .rite/, not a /tmp/ temp file.
    # Per-PR naming (no $$) is correct: content is idempotent per PR (safe to
    # overwrite), and a single well-known path makes manual recovery straightforward
    # — multiple PID-suffixed files would make the recovery file hard to discover.
    _orphaned_summary="${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}/orphaned-summary-comment-${PR_NUMBER}.md"
    mkdir -p "${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}" 2>/dev/null || true
    {
      echo "# Orphaned Per-Item Summary Comment"
      echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "# PR: #${PR_NUMBER}"
      echo "# Source issue: #${ISSUE_NUMBER:-unknown}"
      echo "# Re-post: gh pr comment ${PR_NUMBER} --body-file <this-file>"
      echo "# (Re-run 'rite ${ISSUE_NUMBER:-N} --assess-and-fix' to regenerate automatically)"
      echo ""
      cat "$_summary_file" 2>/dev/null || echo "(comment body unavailable)"
    } > "$_orphaned_summary" || true
    print_warning "Comment body saved to: $_orphaned_summary"
    _diag "PER_ITEM_SUMMARY_COMMENT_FAILED pr=${PR_NUMBER} issue=${ISSUE_NUMBER:-} orphaned=${_orphaned_summary}"
  fi
  rm -f "$_summary_file" "$_summary_stderr_file"
  unset _per_item_refs _per_item_markers _summary_comment _summary_file _num _mnum \
        _summary_stderr_file _summary_stderr _orphaned_summary
fi

# Create consolidated follow-up issue if needed
# Disable errexit: follow-up issue creation uses _followup_creation_failed flag
# to surface failures instead of letting set -e kill the script mid-creation.
set +e
if [ "${CREATE_FOLLOWUP_ISSUES:-false}" = true ]; then
  print_header "📝 Creating Consolidated Follow-up Issue"

  # Check if we already have filtered assessment from earlier smart assessment
  if [ -n "${FILTERED_ASSESSMENT:-}" ]; then
    print_info "Reusing holistic assessment from earlier (no duplicate analysis)"
    FILTERED_CONTENT="$FILTERED_ASSESSMENT"
    USE_FILTERED=true
  else
    USE_FILTERED=false
  fi

  # Extract issues from holistic assessment
  if [ "$USE_FILTERED" = true ] && [ -n "$FILTERED_CONTENT" ]; then
    # Determine which items to include based on issue type.
    # DISMISSED leak fix (defect #3): use awk to extract complete per-item blocks
    # rather than grep -A 20 | grep -B 2. The grep approach spans item boundaries:
    # a 20-line look-ahead on item N can include item N+1's header (even if DISMISSED),
    # and grep -B 2 then pulls that header into the severity bucket.
    # The awk extractor accumulates each item until the next ### header and only
    # includes blocks whose content matches the target severity pattern.
    _extract_items_by_state() {
      local _state_pattern="$1"
      local _severity_pattern="$2"
      # sharkrite-lint disable UNSAFE_PIPE_IN_CMDSUB - Reason: || true at end of pipeline
      # Use length(block) > 0 instead of block != "" to avoid BSD awk locale bug
      # where != is misinterpreted when LANG is not C (macOS awk 20200816 issue).
      echo "$FILTERED_CONTENT" | awk -v states="$_state_pattern" -v sev="$_severity_pattern" '
        /^### .* - ACTIONABLE_/ {
          if (length(block) > 0 && block ~ sev) { print block; print "" }
          in_block = ($0 ~ states)
          block = in_block ? $0 : ""
          next
        }
        /^### / {
          if (length(block) > 0 && block ~ sev) { print block; print "" }
          in_block = 0; block = ""; next
        }
        in_block { block = block "\n" $0 }
        END { if (length(block) > 0 && block ~ sev) { print block; print "" } }
      ' || true
    }

    if [ "${CREATE_SECURITY_DEBT:-false}" = "true" ]; then
      print_status "Extracting ACTIONABLE_LATER items for tech-debt issue..."
      CRITICAL_ISSUES=$(_extract_items_by_state "ACTIONABLE_LATER" "Severity:.*CRITICAL")
      HIGH_ISSUES=$(_extract_items_by_state "ACTIONABLE_LATER" "Severity:.*HIGH")
      MEDIUM_ISSUES=$(_extract_items_by_state "ACTIONABLE_LATER" "Severity:.*MEDIUM")
      LOW_ISSUES=$(_extract_items_by_state "ACTIONABLE_LATER" "Severity:.*LOW")

      # Include ACTIONABLE_NOW items in the tech-debt follow-up when the
      # retry limit was reached — these are items the fix loop could not
      # resolve within 3 cycles.
      if [ "$RETRY_COUNT" -ge 3 ]; then
        print_status "Also including unresolved ACTIONABLE_NOW items..."
        CRITICAL_ISSUES="$CRITICAL_ISSUES
$(_extract_items_by_state "ACTIONABLE_NOW" "Severity:.*CRITICAL")"
        HIGH_ISSUES="$HIGH_ISSUES
$(_extract_items_by_state "ACTIONABLE_NOW" "Severity:.*HIGH")"
        MEDIUM_ISSUES="$MEDIUM_ISSUES
$(_extract_items_by_state "ACTIONABLE_NOW" "Severity:.*MEDIUM")"
        LOW_ISSUES="$LOW_ISSUES
$(_extract_items_by_state "ACTIONABLE_NOW" "Severity:.*LOW")"
      fi
    else
      CRITICAL_ISSUES=$(_extract_items_by_state "ACTIONABLE_(NOW|LATER)" "Severity:.*CRITICAL")
      HIGH_ISSUES=$(_extract_items_by_state "ACTIONABLE_(NOW|LATER)" "Severity:.*HIGH")
      MEDIUM_ISSUES=$(_extract_items_by_state "ACTIONABLE_(NOW|LATER)" "Severity:.*MEDIUM")
      LOW_ISSUES=$(_extract_items_by_state "ACTIONABLE_(NOW|LATER)" "Severity:.*LOW")
    fi

    # Recount after filtering - count structured headers (^### Title - STATE)
    # not bare keywords that could match reasoning text
    CRITICAL_COUNT=$(echo "$CRITICAL_ISSUES" | grep -c "^### .* - ACTIONABLE_\(NOW\|LATER\)" || true)
    HIGH_COUNT=$(echo "$HIGH_ISSUES" | grep -c "^### .* - ACTIONABLE_\(NOW\|LATER\)" || true)
    MEDIUM_COUNT=$(echo "$MEDIUM_ISSUES" | grep -c "^### .* - ACTIONABLE_\(NOW\|LATER\)" || true)
    LOW_COUNT=$(echo "$LOW_ISSUES" | grep -c "^### .* - ACTIONABLE_\(NOW\|LATER\)" || true)
    # Ensure numeric defaults
    CRITICAL_COUNT=${CRITICAL_COUNT:-0}
    HIGH_COUNT=${HIGH_COUNT:-0}
    MEDIUM_COUNT=${MEDIUM_COUNT:-0}
    LOW_COUNT=${LOW_COUNT:-0}

    print_info "Issue counts: CRITICAL=$CRITICAL_COUNT, HIGH=$HIGH_COUNT, MEDIUM=$MEDIUM_COUNT, LOW=$LOW_COUNT"

    # Drop LOW items — they accumulate noise without justifying issue overhead.
    # Log them for visibility but exclude from the follow-up issue.
    if [ "$LOW_COUNT" -gt 0 ]; then
      print_info "Excluding $LOW_COUNT LOW-severity item(s) from follow-up issue (not worth tracking)"
    fi
    LOW_ISSUES=""
    LOW_COUNT=0

    # Final-retry MEDIUM drop (defect #5): when retry limit was reached with no
    # CRITICAL items, MEDIUM findings are also dropped. They were already medium-priority
    # and the fix loop couldn't address them — filing them clutters the backlog.
    # Only HIGH/CRITICAL findings get a follow-up issue at retry limit.
    if [ "${DROP_RETRY_MEDIUM_LOW:-false}" = "true" ] && [ "$MEDIUM_COUNT" -gt 0 ]; then
      print_info "Final-retry: dropping $MEDIUM_COUNT MEDIUM-severity item(s) (not worth follow-up backlog space at retry limit)"
      MEDIUM_ISSUES=""
      MEDIUM_COUNT=0
    fi
  else
    # Fallback: Extract all issues from review using sed (when Claude unavailable)
    CRITICAL_ISSUES=$(sed -n '/^## .*[Cc]ritical/,/^##[^#]/p' "$REVIEW_FILE" || echo "")
    HIGH_ISSUES=$(sed -n '/^## .*[Hh]igh/,/^##[^#]/p' "$REVIEW_FILE" || echo "")
    MEDIUM_ISSUES=$(sed -n '/^## .*[Mm]edium/,/^##[^#]/p' "$REVIEW_FILE" || echo "")
    LOW_ISSUES=""
    LOW_COUNT=0
  fi

  # If only LOWs existed and we just filtered them all out, skip issue creation
  if [ "$CRITICAL_COUNT" -eq 0 ] && [ "$HIGH_COUNT" -eq 0 ] && [ "$MEDIUM_COUNT" -eq 0 ]; then
    print_info "All remaining items are LOW severity — skipping follow-up issue creation"
    CREATE_FOLLOWUP_ISSUES=false
  fi
fi

# Gate: only proceed if we still have items worth tracking after LOW filtering
if [ "${CREATE_FOLLOWUP_ISSUES:-false}" = true ]; then
  print_header "📝 Creating Per-Finding Follow-up Issues"

  # Gather PR metadata once — reused across per-finding issue bodies.
  CHANGED_FILES=$(gh_safe pr view "$PR_NUMBER" --json files --jq '.files[].path' || true)
  CHANGED_FILES="${CHANGED_FILES:-}"
  CLAUDE_CONTEXT=""
  if [ -n "$CHANGED_FILES" ]; then
    CLAUDE_CONTEXT=$(echo "$CHANGED_FILES" | sed 's/^/- `/' | sed 's/$/`/' || true)
  fi

  # Scope Boundary DO bullets: one per parent-PR file so scope-checker has
  # path-shaped patterns to match against. Falls back to prose when the PR
  # has no detectable files (the scope-checker then treats this as
  # non-enforceable and skips with a diag line — see lib/utils/scope-checker.sh).
  if [ -n "$CHANGED_FILES" ]; then
    SCOPE_DO_BULLETS=$(echo "$CHANGED_FILES" | sed 's/^/- DO: /' || true)
  else
    SCOPE_DO_BULLETS="- DO: Address the specific review finding described above"
  fi

  PR_BRANCH_NAME=$(gh_safe pr view "$PR_NUMBER" --json headRefName --jq '.headRefName' || true)
  PR_BRANCH_NAME="${PR_BRANCH_NAME:-unknown}"

  # Determine label for all findings in this rollup.
  # tech-debt for retry-limit deferrals; review-follow-up for CRITICAL findings.
  if [ "${CREATE_SECURITY_DEBT:-false}" = "true" ]; then
    _rollup_base_label="tech-debt"
  else
    _rollup_base_label="review-follow-up"
  fi

  # Tracking variables for the per-finding loop.
  FOLLOWUP_NUMBERS=""
  _rollup_any_created=false
  _followup_creation_failed=false   # reset; will be set true on first gh failure
  _findings_skipped_by_cap=0        # count of findings skipped after cap was hit

  # Parse each ACTIONABLE_(NOW|LATER) item from FILTERED_CONTENT and create one
  # issue per finding. Uses the same awk-based extraction already used by
  # _extract_items_by_state(), but iterates over headers and then extracts the
  # full block for each one individually.
  #
  # For each finding we:
  #   1. Build a clean title (strip list markers, no [tag] prefix, no truncation)
  #   2. Build a per-finding body with Description/Claude Context/Acceptance
  #      Criteria/Verification/Done Definition/Scope Boundary/Dependencies
  #   3. Derive priority label from per-finding severity
  #   4. Run the existing dedup/lock/sentinel machinery (lock keyed by
  #      PR + source-issue; the per-finding ISSUE_SEARCH provides unique
  #      dedup scope within that key)
  #   5. Post the PR marker comment after each successful create

  _finding_index=0

  # Validate RITE_MAX_FINDINGS_PER_RUN is a non-negative integer before the loop.
  # A non-numeric value (typo, trailing whitespace) makes the arithmetic test
  # inside the loop silently error and short-circuit to false, reverting to
  # unbounded behavior — the exact failure mode this cap exists to prevent.
  # Validate once here and fall back to default 20 with a warning.
  _findings_cap_raw="${RITE_MAX_FINDINGS_PER_RUN:-20}"
  if ! printf '%s' "$_findings_cap_raw" | grep -qE '^[0-9]+$'; then
    print_warning "RITE_MAX_FINDINGS_PER_RUN='${_findings_cap_raw}' is not a non-negative integer — falling back to default 20."
    _findings_cap_validated=20
  else
    _findings_cap_validated="$_findings_cap_raw"
  fi

  while IFS= read -r _fh_line; do
    [ -z "$_fh_line" ] && continue

    # --- Extract per-finding fields from FILTERED_CONTENT ---

    # Raw title from the header (e.g. "1. Foo bar" or "Fix the thing")
    _raw_title=$(echo "$_fh_line" | sed 's/^### //; s/ - ACTIONABLE_.*//' || true)
    # Strip leading list markers: "1. ", "2. ", "- ", "* "
    _clean_title=$(echo "$_raw_title" | sed 's/^[0-9][0-9]*\.[[:space:]]*//' | sed 's/^[-*][[:space:]]*//' || true)
    # Trim leading/trailing whitespace
    _clean_title=$(echo "$_clean_title" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)

    # Extract the finding's full block (stop at the next ### header)
    # sharkrite-lint disable UNSAFE_PIPE_IN_CMDSUB - Reason: || true at end of pipeline
    _finding_block=$(echo "$FILTERED_CONTENT" | awk -v header="$_fh_line" '
      $0 == header { in_block=1; print; next }
      in_block && /^### / { exit }
      in_block { print }
    ' || true)

    # Extract individual fields from the block.
    # Single-line fields (Severity, Category, Location, Fix Effort, Defer Reason):
    # use grep -oE to capture the rest of the header line, then strip the label.
    # Multi-line fields (Reasoning, Context): use awk to capture from the label line
    # through the next **Field:** header or end of block, preserving all content.
    _f_severity=$(echo "$_finding_block" | grep -oE '\*\*Severity:\*\*.*' | head -1 | sed 's/\*\*Severity:\*\*[[:space:]]*//' | sed 's/\*//g' || true)
    _f_severity="${_f_severity:-MEDIUM}"
    # Normalize to the leading severity token so trailing LLM annotations like
    # "HIGH (word-split risk)" or "CRITICAL: confirmed" don't fall through the
    # exact-match case arms below.  awk '{print $1}' takes the first whitespace-
    # delimited word; tr converts to uppercase for uniform matching.
    _f_severity=$(echo "$_f_severity" | awk '{print $1}' | tr '[:lower:]' '[:upper:]' || true)
    _f_severity="${_f_severity:-MEDIUM}"
    _f_category=$(echo "$_finding_block" | grep -oE '\*\*Category:\*\*.*' | head -1 | sed 's/\*\*Category:\*\*[[:space:]]*//' | sed 's/\*//g' || true)
    _f_category="${_f_category:-}"
    # Reasoning and Context may span multiple lines — use awk to capture the full
    # content from the field header through the next **Label:** line or end of block.
    _f_reasoning=$(echo "$_finding_block" | awk '
      /^\*\*Reasoning:\*\*/ { in_field=1; sub(/^\*\*Reasoning:\*\*[[:space:]]*/, ""); print; next }
      in_field && /^\*\*[A-Za-z].*:\*\*/ { exit }
      in_field { print }
    ' | sed 's/[[:space:]]*$//' | awk 'NF || in_content { in_content=1; print }' || true)
    _f_reasoning="${_f_reasoning:-}"
    _f_location=$(echo "$_finding_block" | grep -oE '\*\*Location:\*\*.*' | head -1 | sed 's/\*\*Location:\*\*[[:space:]]*//' | sed 's/\*//g' || true)
    _f_location="${_f_location:-}"
    _f_fix_effort=$(echo "$_finding_block" | grep -oE '\*\*Fix Effort:\*\*.*' | head -1 | sed 's/\*\*Fix Effort:\*\*[[:space:]]*//' | sed 's/\*//g' || true)
    _f_fix_effort="${_f_fix_effort:-}"
    _f_defer=$(echo "$_finding_block" | grep -oE '\*\*Defer Reason:\*\*.*' | head -1 | sed 's/\*\*Defer Reason:\*\*[[:space:]]*//' | sed 's/\*//g' || true)
    _f_defer="${_f_defer:-}"
    _f_context=$(echo "$_finding_block" | awk '
      /^\*\*Context:\*\*/ { in_field=1; sub(/^\*\*Context:\*\*[[:space:]]*/, ""); print; next }
      in_field && /^\*\*[A-Za-z].*:\*\*/ { exit }
      in_field { print }
    ' | sed 's/[[:space:]]*$//' | awk 'NF || in_content { in_content=1; print }' || true)
    _f_context="${_f_context:-}"

    # Skip LOW severity items — excluded from follow-up issues (same as per-item path).
    # This check runs before the cap guard so LOW findings do not consume API budget.
    if echo "$_f_severity" | grep -qi "LOW"; then
      print_info "  Skipped (LOW severity): $_clean_title"
      continue
    fi

    _finding_index=$((_finding_index + 1))

    # --- Per-finding cap guard ---
    # RITE_MAX_FINDINGS_PER_RUN (default 20) limits GitHub API calls per assess run.
    # The dedup machinery runs N× (issue list + issue view + pr view + backoff sleeps),
    # so an unbounded loop on a scan-heavy PR can exhaust GitHub secondary rate limits.
    # Placed after the LOW-severity skip so LOW findings (which make zero API calls)
    # do not count against the cap — only API-eligible findings are counted.
    # Set to 0 to disable the cap (original unbounded behavior).
    # _findings_cap_validated is set before the loop (numeric-validated, never empty).
    if [ "$_findings_cap_validated" -gt 0 ] && [ "$_finding_index" -gt "$_findings_cap_validated" ]; then
      _findings_skipped_by_cap=$((_findings_skipped_by_cap + 1))
      # Persist the capped finding to the orphaned-followup file so no finding is
      # silently lost — mirrors the creation-failure path at the bottom of the loop.
      # (_finding_slug and _FOLLOWUP_FINDING_KEY are not yet computed at this point,
      # so use _finding_index as the unique identifier here.)
      _orphaned_file="${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}/orphaned-followup-items.md"
      mkdir -p "${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}" 2>/dev/null || true
      {
        echo "---"
        echo "# Orphaned Follow-up Item (capped — finding #${_finding_index})"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# PR: #${PR_NUMBER}"
        echo "# Source issue: #${ISSUE_NUMBER:-unknown}"
        echo "# Intended title: ${_clean_title:-}"
        echo "# Reason: per-finding cap (RITE_MAX_FINDINGS_PER_RUN=${_findings_cap_validated}) was reached"
        echo "# Re-run:  rite ${ISSUE_NUMBER:-N} --assess-and-fix  (after raising or disabling the cap)"
        echo ""
        echo "Finding block:"
        echo "$_finding_block"
      } >> "$_orphaned_file" || true
      print_info "  Capped (API budget): $_clean_title — saved to orphaned-followup-items.md"
      continue
    fi

    # --- Build issue title ---
    # No [tech-debt] or [review-follow-up] prefix — the label classifies.
    # Source-issue suffix preserves unique dedup scope per PR+source-issue pair.
    _src_issue_suffix=""
    [ -n "${ISSUE_NUMBER:-}" ] && _src_issue_suffix=" for issue #${ISSUE_NUMBER}"

    # Fallback title when block parsing yields nothing
    if [ -z "$_clean_title" ]; then
      _clean_title="Review finding from PR #${PR_NUMBER}"
    fi

    ISSUE_TITLE="${_clean_title}${_src_issue_suffix}"

    # ISSUE_SEARCH: used by _followup_dedup_check() Source 3 (title search).
    # Include PR number and source-issue so it's unique per finding origin.
    ISSUE_SEARCH="${_clean_title}${_src_issue_suffix}"

    # Per-finding dedup key: combines source-issue with a title slug so that
    # evidence files, sentinels, and _followup_dedup_check are scoped per
    # finding, not per source-issue.  Without this, the sentinel/evidence from
    # finding #1 suppresses all subsequent findings in the same loop iteration.
    #
    # derive_followup_finding_key is the shared canonical function (issue-lock.sh)
    # — assess-review-issues.sh uses the same function, but the two loops iterate
    # different populations (this loop: ACTIONABLE_NOW + ACTIONABLE_LATER; that
    # loop: ACTIONABLE_LATER only) and this loop has a per-finding cap that
    # consumes _finding_index slots without emitting issues.  Evidence-file keys
    # can therefore diverge across paths; Source 1 dedup is best-effort.
    # Sources 2 (sentinel) and 3 (title search) are the reliable dedup gates.
    # _FOLLOWUP_FINDING_KEY is read by _followup_dedup_check and the
    # sentinel/evidence calls below.
    _FOLLOWUP_FINDING_KEY=$(derive_followup_finding_key "${ISSUE_NUMBER:-0}" "$_clean_title" "$_finding_index")

    # --- Derive priority label from per-finding severity ---
    _priority_label=$(_resolve_priority_label "${_f_severity}")
    _finding_labels="${_rollup_base_label},${_priority_label}"

    # --- Build per-finding acceptance criterion and verification command ---
    # Seed from Location (file:line) when available; fall back to the clean title.
    _acceptance_criterion="- [ ] [${_f_severity}] ${_clean_title}"
    if [ -n "$_f_location" ]; then
      # Parse file:line format (e.g. "lib/core/foo.sh:142 — description text").
      # Strip any trailing description after whitespace; then split on the last colon
      # that is followed only by digits so we handle paths like lib/core/foo.sh:142
      # but not bare paths without a line number.
      _loc_path=$(echo "$_f_location" | awk '{print $1}' | sed 's/:[0-9]*$//' || true)
      _loc_line=$(echo "$_f_location" | awk '{print $1}' | grep -oE ':[0-9]+$' | tr -d ':' || true)
      # Sanitize _loc_path: it is LLM-derived.  A single-quote in the path would
      # break the surrounding single-quoted sed/grep command strings and inject
      # arbitrary shell text into the generated verification command.
      # Only allow the safe subset [A-Za-z0-9/._-]; anything else falls back to prose.
      _loc_path_safe=""
      if echo "${_loc_path:-}" | grep -qE '^[A-Za-z0-9/._-]+$'; then
        _loc_path_safe="$_loc_path"
      fi
      if [ -n "$_loc_line" ] && [ -n "$_loc_path_safe" ]; then
        # file:line format — emit a valid sed command pointing at that exact line
        _verification_cmd="sed -n '${_loc_line}p' '${_loc_path_safe}'"
      elif [ -n "$_loc_path_safe" ]; then
        # Looks like a plain file path (no line number) — use grep to inspect it
        _verification_cmd="grep -n '' '${_loc_path_safe}'"
      elif echo "$_f_location" | grep -qE '^[a-zA-Z/._-]'; then
        # Location present but path did not pass sanitization — emit as prose to
        # avoid injecting unsanitized content into shell command syntax.
        _verification_cmd="# TODO: add verification command for: ${_f_location}"
      else
        # Location field present but doesn't look like a path — fall back
        _verification_cmd="# TODO: add verification command for: ${_f_location}"
      fi
    else
      # Generic fallback — reviewer must fill in the concrete command
      _verification_cmd="# TODO: add verification command for this finding"
    fi

    # Done Definition: severity-appropriate
    _done_def=$(_resolve_done_def "${_f_severity}")

    # Time Estimate from Fix Effort metadata
    _time_estimate=""
    case "${_f_fix_effort:-}" in
      *\>1hr*) _time_estimate="2hr" ;;
      *\<1hr*) _time_estimate="1hr" ;;
      *\<10min*) _time_estimate="30min" ;;
    esac

    # --- Build issue body ---
    SOURCE_ISSUE_MARKER=""
    [ -n "${ISSUE_NUMBER:-}" ] && SOURCE_ISSUE_MARKER="<!-- ${RITE_MARKER_SOURCE_ISSUE}:${ISSUE_NUMBER} -->"

    FOLLOWUP_BODY="${SOURCE_ISSUE_MARKER}<!-- ${RITE_MARKER_PARENT_PR}:${PR_NUMBER} -->
## Description

${_f_reasoning:-${_clean_title}}

**Severity:** ${_f_severity}
**Category:** ${_f_category:-unspecified}
**Source PR:** #${PR_NUMBER}
**Branch:** ${PR_BRANCH_NAME}
**Review Date:** $(date +%Y-%m-%d)
$([ -n "$_f_location" ] && echo "**Location:** ${_f_location}")
$([ -n "$_f_defer" ] && echo "
**Defer Reason:** ${_f_defer}")
$([ -n "$_f_context" ] && echo "
**Context:** ${_f_context}")

## Claude Context
Files to read before starting:
${CLAUDE_CONTEXT:-_See changed files in PR #${PR_NUMBER}_}

## Acceptance Criteria
${_acceptance_criterion}: see Description above for details

## Verification Commands
\`\`\`bash
${_verification_cmd}
\`\`\`

## Done Definition
${_done_def}

## Scope Boundary
${SCOPE_DO_BULLETS}
- DO NOT: Refactor surrounding code, add new features, or modify unrelated files

## Dependencies
After: #${ISSUE_NUMBER:-${PR_NUMBER}}
$([ -n "${_time_estimate}" ] && echo "
## Time Estimate
${_time_estimate}" || echo "")

---

_Auto-generated follow-up from PR #${PR_NUMBER} review (finding ${_finding_index})_"

    # --- Dedup / lock / create --- (mirrors the consolidated path; keyed per-finding)
    #
    # Lock key uses _FOLLOWUP_FINDING_KEY (PR + source-issue + title slug), so
    # concurrent processes racing on the same finding are serialised at the
    # finding level.  This closes the cross-process duplicate window for findings
    # 2..N: previously the lock was keyed on PR+source-issue only, so it was
    # released between findings, allowing a concurrent same-source-issue process
    # to race through the dedup check before the GitHub index caught up.

    # Sentinel pre-check (TTL-gated local dedup oracle before touching the lock)
    # Keyed by _FOLLOWUP_FINDING_KEY (source-issue + title slug) so each finding
    # gets its own sentinel.  A key scoped only to source-issue suppresses all
    # findings after the first one in the same loop iteration.
    _sentinel_skipped=false
    if [ -n "${_FOLLOWUP_FINDING_KEY:-}" ]; then
      _sentinel_dir="${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}/followup-sentinels"
      _sentinel_file="${_sentinel_dir}/finding-${_FOLLOWUP_FINDING_KEY}.created"
      if [ -f "$_sentinel_file" ]; then
        _sentinel_mtime=$(portable_stat_mtime "$_sentinel_file")
        _sentinel_age=$(( $(date +%s) - _sentinel_mtime ))
        _sentinel_ttl="${RITE_FOLLOWUP_SENTINEL_TTL_S:-60}"
        if [ "$_sentinel_age" -lt "$_sentinel_ttl" ]; then
          print_info "  Sentinel active for finding '${_clean_title}' (${_sentinel_age}s ago) — skipping finding #${_finding_index}"
          _sentinel_skipped=true
        fi
      fi
      unset _sentinel_dir _sentinel_file _sentinel_mtime _sentinel_age _sentinel_ttl
    fi

    mkdir -p "$RITE_LOCK_DIR" 2>/dev/null || true
    _lock_contended_file=$(mktemp "${RITE_LOCK_DIR}/.contended-signal-XXXXXX")
    export RITE_FOLLOWUP_LOCK_CONTENDED_FILE="$_lock_contended_file"

    _followup_lock_held=false
    _skip_followup_creation=false
    if [ "${_sentinel_skipped:-false}" != "true" ] && \
       acquire_pr_followup_lock "$PR_NUMBER" "${_FOLLOWUP_FINDING_KEY:-${ISSUE_NUMBER:-}}" 2>/dev/null; then
      _followup_lock_held=true
    elif [ "${_sentinel_skipped:-false}" = "true" ]; then
      _skip_followup_creation=true
    else
      _lock_scope="PR #$PR_NUMBER${_FOLLOWUP_FINDING_KEY:+ / finding ${_FOLLOWUP_FINDING_KEY}}"
      print_warning "Could not acquire follow-up lock for ${_lock_scope} after 60s — skipping finding #${_finding_index} to prevent duplicates."
      _diag "FOLLOWUP_LOCK_TIMEOUT issue=${ISSUE_NUMBER:-} pr=${PR_NUMBER} finding_index=${_finding_index}"
      # Write orphan artifact so the finding is not silently lost: the durable
      # orphaned-followup-items.md trail is the only evidence that this finding
      # exists if the lock never becomes available.
      _lock_timeout_orphan_file="${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}/orphaned-followup-items.md"
      mkdir -p "${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}" 2>/dev/null || true
      {
        echo "---"
        echo "# Orphaned Follow-up Item (finding #${_finding_index}) — lock timeout"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# PR: #${PR_NUMBER}"
        echo "# Source issue: #${ISSUE_NUMBER:-unknown}"
        echo "# Intended title: ${ISSUE_TITLE:-}"
        echo "# Re-run:  rite ${ISSUE_NUMBER:-N} --assess-and-fix  (after resolving lock contention)"
        echo ""
        printf '%s\n' "$FOLLOWUP_BODY"
      } >> "$_lock_timeout_orphan_file" || true
      print_error "  Item NOT tracked (lock timeout). Saved to: $_lock_timeout_orphan_file"
      _followup_creation_failed=true
      _skip_followup_creation=true
    fi

    _lock_was_contended=false
    if [ -n "${_lock_contended_file:-}" ] && [ -f "$_lock_contended_file" ]; then
      _contended_content=$(cat "$_lock_contended_file" 2>/dev/null || true)
      [ "$_contended_content" = "contended" ] && _lock_was_contended=true
    fi
    rm -f "${_lock_contended_file:-}" 2>/dev/null || true
    unset RITE_FOLLOWUP_LOCK_CONTENDED_FILE

    if [ "${_skip_followup_creation:-false}" != "true" ]; then

      # Dedup check — reads/writes EXISTING_ISSUE; uses ISSUE_SEARCH and ISSUE_NUMBER
      EXISTING_ISSUE=""
      _followup_dedup_check

      if [ -n "$EXISTING_ISSUE" ]; then
        [ "$_followup_lock_held" = "true" ] && release_pr_followup_lock "$PR_NUMBER" "${_FOLLOWUP_FINDING_KEY:-${ISSUE_NUMBER:-}}" 2>/dev/null || true
        _followup_lock_held=false
        print_info "Finding already tracked in #$EXISTING_ISSUE (skipping): $_clean_title"
        FOLLOWUP_NUMBERS="${FOLLOWUP_NUMBERS}${EXISTING_ISSUE} "
        _rollup_any_created=true
      else
        # Ensure labels exist and create the per-finding issue
        ensure_labels_exist "$_finding_labels"
        _finding_body_file=$(mktemp)
        printf '%s' "$FOLLOWUP_BODY" > "$_finding_body_file"
        _new_issue_url=""
        if _new_issue_url=$(gh_safe issue create \
            --title "$ISSUE_TITLE" \
            --body-file "$_finding_body_file" \
            --label "$_finding_labels"); then
          rm -f "$_finding_body_file"
          _new_issue_num=$(echo "$_new_issue_url" | grep -oE '[0-9]+$' || true)
          _new_issue_num="${_new_issue_num:-}"

          if [ -n "$_new_issue_num" ]; then
            FOLLOWUP_NUMBERS="${FOLLOWUP_NUMBERS}${_new_issue_num} "
            _rollup_any_created=true

            # Durable local evidence (primary dedup guard across processes)
            # Keyed by _FOLLOWUP_FINDING_KEY (source-issue + title slug) so
            # each finding gets its own evidence file.
            if ! write_followup_evidence "$PR_NUMBER" "$_new_issue_num" "${_FOLLOWUP_FINDING_KEY:-${ISSUE_NUMBER:-}}"; then
              print_warning "Could not write local evidence file for follow-up #$_new_issue_num — dedup relies solely on GitHub API"
            fi

            # Machine-readable marker comment on PR (secondary dedup guard)
            _finding_comment="<!-- ${RITE_MARKER_FOLLOWUP}:${_new_issue_num} -->
📋 **Follow-up issue created:** #${_new_issue_num} — ${_clean_title}

**Severity:** ${_f_severity} | **Label:** ${_rollup_base_label}"
            _finding_comment_file=$(mktemp)
            printf '%s' "$_finding_comment" > "$_finding_comment_file"
            if ! gh_safe pr comment "$PR_NUMBER" --body-file "$_finding_comment_file" 2>/dev/null; then
              print_warning "PR comment write failed for follow-up #$_new_issue_num — local evidence covers dedup"
            fi
            rm -f "$_finding_comment_file"

            # Sentinel: short-lived FS dedup oracle for this finding.
            # Keyed by _FOLLOWUP_FINDING_KEY (source-issue + title slug) so
            # each finding gets its own sentinel (not one shared by all findings
            # from the same source issue).
            if [ -n "${_FOLLOWUP_FINDING_KEY:-}" ]; then
              _sentinel_write_dir="${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}/followup-sentinels"
              mkdir -p "$_sentinel_write_dir" 2>/dev/null || true
              if ! touch "${_sentinel_write_dir}/finding-${_FOLLOWUP_FINDING_KEY}.created" 2>/dev/null; then
                _diag "FOLLOWUP_SENTINEL_WRITE_FAILED finding=${_FOLLOWUP_FINDING_KEY} dir=${_sentinel_write_dir}"
                print_warning "Could not write follow-up sentinel for finding '${_clean_title}' — dedup relies on lock dwell only."
              fi
              unset _sentinel_write_dir
            fi

            [ "$_followup_lock_held" = "true" ] && release_pr_followup_lock "$PR_NUMBER" "${_FOLLOWUP_FINDING_KEY:-${ISSUE_NUMBER:-}}" 2>/dev/null || true
            _followup_lock_held=false

            print_success "  Created #$_new_issue_num: $_clean_title"
            echo "     URL: $_new_issue_url"
          else
            rm -f "$_finding_body_file"
            [ "$_followup_lock_held" = "true" ] && release_pr_followup_lock "$PR_NUMBER" "${_FOLLOWUP_FINDING_KEY:-${ISSUE_NUMBER:-}}" 2>/dev/null || true
            _followup_lock_held=false
            print_warning "  Failed to parse issue number from: $_new_issue_url"
            _followup_creation_failed=true
          fi
        else
          # gh issue create failed — save orphan artifact
          _orphaned_file="${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}/orphaned-followup-items.md"
          mkdir -p "${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}" 2>/dev/null || true
          {
            echo "---"
            echo "# Orphaned Follow-up Item (finding #${_finding_index})"
            echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "# PR: #${PR_NUMBER}"
            echo "# Source issue: #${ISSUE_NUMBER:-unknown}"
            echo "# Intended title: ${ISSUE_TITLE:-}"
            echo "# Re-run:  rite ${ISSUE_NUMBER:-N} --assess-and-fix  (after resolving gh API issue)"
            echo ""
            cat "$_finding_body_file" 2>/dev/null || echo "(body file unavailable)"
          } >> "$_orphaned_file" || true
          rm -f "$_finding_body_file"
          [ "$_followup_lock_held" = "true" ] && release_pr_followup_lock "$PR_NUMBER" "${_FOLLOWUP_FINDING_KEY:-${ISSUE_NUMBER:-}}" 2>/dev/null || true
          _followup_lock_held=false
          print_warning "  Failed to create follow-up for: $_clean_title"
          print_error "  Item NOT tracked. Saved to: $_orphaned_file"
          _followup_creation_failed=true
        fi
      fi
    fi  # end _skip_followup_creation guard

    # Safety net: release lock if still held via unexpected path (set +e active)
    [ "$_followup_lock_held" = "true" ] && release_pr_followup_lock "$PR_NUMBER" "${_FOLLOWUP_FINDING_KEY:-${ISSUE_NUMBER:-}}" 2>/dev/null || true
    _followup_lock_held=false

  done < <(echo "${FILTERED_CONTENT:-}" | grep -E "^### .* - ACTIONABLE_(NOW|LATER)" || true)

  # Post-loop cap report: emit diag + warning when the cap was hit so nightly
  # health reports can surface the truncation event.  Capped findings are written
  # to orphaned-followup-items.md (same as creation-failure path) so no finding
  # is silently lost — operators can re-run with a higher cap or disable it
  # (RITE_MAX_FINDINGS_PER_RUN=0) to process all findings.
  if [ "${_findings_skipped_by_cap:-0}" -gt 0 ]; then
    _processed_count=$((_finding_index - _findings_skipped_by_cap))
    print_warning "Per-finding cap hit: processed ${_processed_count} of ${_finding_index} API-eligible (non-LOW) findings (cap=${_findings_cap_validated}, skipped=${_findings_skipped_by_cap})."
    print_info "  Capped findings saved to: ${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}/orphaned-followup-items.md"
    print_info "  To process all findings: set RITE_MAX_FINDINGS_PER_RUN=0 (or raise the cap) in .rite/config"
    _diag "FOLLOWUP_CAP_HIT issue=${ISSUE_NUMBER:-} pr=${PR_NUMBER} processed=${_processed_count} skipped=${_findings_skipped_by_cap} cap=${_findings_cap_validated}"
    unset _processed_count
  fi

  # Post-loop dwell: lets GitHub index catch up before any subsequent waiter
  # acquires a lock and runs a dedup search.  Runs once per batch of findings
  # (not per finding) to avoid multiplying the delay by finding count.
  # Only fires when at least one issue was created this run.
  if [ "${_rollup_any_created:-false}" = "true" ]; then
    _dwell_seconds="${RITE_FOLLOWUP_LOCK_DWELL_S:-5}"
    if [ "$_dwell_seconds" -gt 0 ] 2>/dev/null; then
      sleep "$_dwell_seconds"
    fi
    unset _dwell_seconds
  fi

  # Legacy alias: FOLLOWUP_NUMBER for the final summary line (set to first number
  # if any were created; empty otherwise).
  FOLLOWUP_NUMBER=$(echo "$FOLLOWUP_NUMBERS" | grep -oE '^[0-9]+' || true)
  FOLLOWUP_NUMBER="${FOLLOWUP_NUMBER:-}"

  if [ "${_rollup_any_created:-false}" = "true" ] && [ -n "$FOLLOWUP_NUMBERS" ]; then
    # Build "#N" reference list from space-separated numbers for display
    _refs=""
    for _rn in $FOLLOWUP_NUMBERS; do
      _refs="${_refs}#${_rn} "
    done
    _refs=$(echo "$_refs" | sed 's/[[:space:]]*$//' || true)
    print_info "Follow-up issues created/found: ${_refs}"
    print_info "Run \`rite <issue_number>\` for each to address them separately."
  elif [ "${_followup_creation_failed:-false}" != "true" ]; then
    print_info "No new follow-up issues needed (all findings already tracked or sentinel active)"
  fi
fi
set -e  # Re-enable errexit after follow-up issue creation

# Final summary — check _followup_creation_failed first.
# If follow-up issue creation failed, exit 1 to prevent silent data loss.
# Only proceed to the merge-decision exit code when follow-up creation succeeded.
# MERGE_EXIT_CODE=1 only when CRITICAL items remain (set at line ~785 above).
print_header "✅ Assessment Complete"

echo "Summary of actions taken:"
[ "${CREATE_FOLLOWUP_ISSUES:-false}" = true ] && [ -n "${FOLLOWUP_NUMBERS:-}" ] && echo "  ✅ Follow-up issues created/tracked: ${FOLLOWUP_NUMBERS}"
[ "${CREATE_FOLLOWUP_ISSUES:-false}" = true ] && [ "${_followup_creation_failed:-false}" = true ] && echo "  ⚠️  One or more follow-up issues failed to create (items NOT tracked — see orphaned-followup-items.md)"
[ "${CREATE_LOW_BATCH:-false}" = true ] && [ "${LOW_COUNT:-0}" -gt 0 ] && echo "  ✅ Batched LOW priority items into single issue"

echo ""

if [ "${_followup_creation_failed:-false}" = true ]; then
  print_error "Follow-up issue creation failed — workflow halted to prevent silent data loss"
  exit 1
elif [ "$MERGE_EXIT_CODE" -eq 0 ]; then
  print_success "All issues resolved or tracked - ready to proceed"
  exit 0
else
  print_error "CRITICAL issues remain — manual intervention required"
  exit 1
fi
