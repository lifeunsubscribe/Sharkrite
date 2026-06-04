#!/usr/bin/env bash
# tools/audit-dropped-followups.sh
#
# Audit PRs merged during an assessment-outage window for dropped follow-up issues.
#
# Background: Between 2026-06-02 18:49 UTC and 2026-06-04 20:26 UTC, assess-review-issues.sh
# was a 9-line stub (introduced by PR #260's test-bug damage). During this window, the
# ACTIONABLE_LATER → follow-up issue creation path was never invoked. PRs were merged with
# HIGH/MEDIUM/LOW findings but no sharkrite-followup-issue:N markers were posted.
#
# This script identifies "gap" PRs: PRs with findings but zero follow-up issues.
# Run this after any similar outage to find PRs that need manual triage.
#
# Usage:
#   ./tools/audit-dropped-followups.sh [--window-start DATE] [--window-end DATE]
#   ./tools/audit-dropped-followups.sh --pr-list "278 281 286 300 302 304 305 306 307 310 315"
#
# Options:
#   --window-start DATE   ISO8601 date (default: 2026-06-02T18:49:00Z)
#   --window-end DATE     ISO8601 date (default: 2026-06-04T20:26:00Z)
#   --pr-list "N N N"    Space-separated PR numbers to audit directly (bypasses window)
#   --repo OWNER/REPO     GitHub repo (default: auto-detected from git remote)
#   --help                Show this help
#
# Output: For each PR in the window, prints:
#   PR #N | Title | HIGH:N MED:N LOW:N | follow-ups:N | STATUS
#   where STATUS is GAP (needs triage) or OK (has follow-up issues or no findings)
#
# Dependencies: gh CLI, jq
#
# Example of the 2026-06-02/04 outage audit that produced issues #328-#338:
#   ./tools/audit-dropped-followups.sh \
#     --window-start 2026-06-02T18:49:00Z \
#     --window-end   2026-06-04T20:26:00Z

set -euo pipefail

# Bash 4+ required for mapfile
if (( BASH_VERSINFO[0] < 4 )); then
  echo "ERROR: Requires bash 4+. macOS ships bash 3.2; install bash via Homebrew: brew install bash" >&2
  exit 1
fi

# Source the gh retry wrapper (gh_safe) and marker constants from the sharkrite
# lib. Done at script load so all gh calls below use the retry-aware wrapper and
# marker comparisons use canonical constants.
_audit_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_audit_self_dir/../lib/utils/gh-retry.sh"
# shellcheck source=/dev/null
source "$_audit_self_dir/../lib/utils/markers.sh"

# --- Defaults ---
WINDOW_START="${WINDOW_START:-2026-06-02T18:49:00Z}"
WINDOW_END="${WINDOW_END:-2026-06-04T20:26:00Z}"
PR_LIST=""
REPO=""

# --- Arg parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --window-start) WINDOW_START="$2"; shift 2 ;;
    --window-end)   WINDOW_END="$2";   shift 2 ;;
    --pr-list)      PR_LIST="$2";      shift 2 ;;
    --repo)         REPO="$2";         shift 2 ;;
    --help|-h)
      sed -n '/^# Usage/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Detect repo ---
if [ -z "$REPO" ]; then
  REPO=$(gh_safe repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  if [ -z "$REPO" ]; then
    echo "ERROR: Could not detect repo. Pass --repo OWNER/REPO" >&2
    exit 1
  fi
fi

echo "Auditing repo: $REPO"
echo ""

# --- Build PR list ---
if [ -n "$PR_LIST" ]; then
  # Direct list provided
  IFS=' ' read -r -a prs <<< "$PR_LIST"
  echo "Auditing ${#prs[@]} PRs from --pr-list: $PR_LIST"
else
  # Find PRs merged in the window
  echo "Fetching PRs merged between $WINDOW_START and $WINDOW_END ..."
  mapfile -t prs < <(
    gh_safe pr list \
      --repo "$REPO" \
      --state merged \
      --limit 200 \
      --json number,mergedAt \
      --jq ".[] | select(.mergedAt >= \"$WINDOW_START\" and .mergedAt <= \"$WINDOW_END\") | .number"
  )
  echo "Found ${#prs[@]} merged PRs in window"
  if [ "${#prs[@]}" -eq 200 ]; then
    echo "WARNING: result count equals --limit 200. PRs merged before the window boundary may have been silently truncated." >&2
    echo "WARNING: Re-run with a narrower window or switch to: gh search prs --merged START..END (no hard limit)" >&2
  fi
fi

echo ""
echo "| PR | Title | CRIT | HIGH | MED | LOW | FollowUps | Status |"
echo "|---|---|---|---|---|---|---|---|"

gap_count=0
ok_count=0
skip_count=0

for pr in "${prs[@]}"; do
  # Fetch PR title and comments.
  # Assumption: sharkrite posts review bodies and follow-up markers as PR *issue comments*
  # (via `gh pr comment` in local-review.sh / merge-pr.sh), not as GitHub review-thread
  # comments (which live under the `reviews` field).  Therefore `--json comments` (issue
  # comments) is the correct field — `reviews` is intentionally omitted.
  # Verified against real reviewed PRs: sharkrite-local-review and sharkrite-followup-issue
  # markers both appear in .comments[].body, not in .reviews[].body.
  pr_data=$(gh_safe pr view "$pr" --repo "$REPO" --json title,comments 2>/dev/null || true)
  if [ -z "$pr_data" ]; then
    echo "| #$pr | (could not fetch) | - | - | - | - | - | SKIP |"
    (( skip_count++ )) || true
    continue
  fi

  title=$(echo "$pr_data" | jq -r '.title' | sed 's/|/\\|/g' || true)

  # Find the sharkrite-local-review comment(s), use the most recent.
  # The jq filter is built as a bash variable so ${RITE_MARKER_REVIEW} expands
  # before jq sees the string — keeps the marker comparison anchored to the
  # canonical constant from markers.sh.
  _jq_review_body="[.comments[] | select(.body | contains(\"${RITE_MARKER_REVIEW}\"))] | last | .body // \"\""
  review_body=$(echo "$pr_data" | jq -r "$_jq_review_body")

  if [ -z "$review_body" ]; then
    echo "| #$pr | $title | - | - | - | - | - | NO_REVIEW |"
    (( skip_count++ )) || true
    continue
  fi

  # Parse findings from the Findings: summary line
  # Format: **Findings:** 🔴 CRITICAL: N | 🟠 HIGH: N | 🟡 MEDIUM: N | 🟢 LOW: N
  # Isolate just the summary line first to prevent multiline grep output feeding $(( ))
  findings_line=$(echo "$review_body" | grep -m1 'Findings:' || true)
  crit=$(echo "$findings_line" | grep -oE 'CRITICAL: [0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  high=$(echo "$findings_line" | grep -oE 'HIGH: [0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  med=$(echo "$findings_line"  | grep -oE 'MEDIUM: [0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  low=$(echo "$findings_line"  | grep -oE 'LOW: [0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  crit="${crit:-0}"; high="${high:-0}"; med="${med:-0}"; low="${low:-0}"

  total_findings=$(( crit + high + med + low ))

  # Count distinct sharkrite-followup-issue:N markers in PR comments
  all_comments=$(echo "$pr_data" | jq -r '.comments[].body' || true)
  followup_count=$(echo "$all_comments" | grep -oE "${RITE_MARKER_FOLLOWUP}:[0-9]+" | sort -u | wc -l | tr -d ' ' || true)
  followup_count="${followup_count:-0}"

  # Determine status
  if [ "$total_findings" -eq 0 ]; then
    status="OK_NO_FINDINGS"
    (( ok_count++ )) || true
  elif [ "$followup_count" -gt 0 ]; then
    status="OK"
    (( ok_count++ )) || true
  else
    status="GAP"
    (( gap_count++ )) || true
  fi

  echo "| #$pr | $title | $crit | $high | $med | $low | $followup_count | $status |"
done

echo ""
echo "Summary: $gap_count GAP (needs triage), $ok_count OK, $skip_count SKIP/NO_REVIEW"

if [ "$gap_count" -gt 0 ]; then
  echo ""
  echo "ACTION REQUIRED: $gap_count PRs have findings with no follow-up issues filed."
  echo "Review each GAP PR and triage: file issues for relevant findings or dismiss with reason."
  exit 1
fi

exit 0
