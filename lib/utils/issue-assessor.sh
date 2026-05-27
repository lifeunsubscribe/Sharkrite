#!/usr/bin/env bash
# issue-assessor.sh
#
# Two-part contract for keeping sharkrite's view of an issue in sync with
# reality (main and the GitHub issue state):
#
#   1. assess_issue_completion <issue_number> <issue_body>
#      Pre-launch state check. Reads the issue's acceptance criteria, inspects
#      main, classifies each criterion as DONE / PARTIAL / NOT_DONE, returns a
#      summary in globals so workflow-runner can decide:
#        FULLY_DONE    → close issue, skip dev session
#        PARTIALLY_DONE→ inject context into dev session ("skip these, focus
#                        on these")
#        NOT_STARTED   → proceed normally
#        UNKNOWN       → no parseable criteria, proceed normally
#
#   2. handle_mid_session_close <issue_number> <pr_number> <worktree_path>
#      Post-worker check. If the issue was closed during the dev session,
#      classify why and act:
#        - Closed by a merged PR ≠ ours, criteria satisfied on main → cleanup
#          our in-flight artifacts and exit success.
#        - Closed manually with no closing PR → assume user resolved it
#          another way; cleanup and exit success.
#        - Closed but criteria don't appear satisfied → abort with diagnostic;
#          leave artifacts for human inspection.
#
# Both are intentionally LLM-backed rather than heuristic. Issues vary too
# much in shape (acceptance criteria phrasing, file references, etc.) for a
# regex to be reliable. The assessor uses the utility provider with
# tool restrictions limited to read-only operations.

set -euo pipefail

# =============================================================================
# Pre-launch assessment
# =============================================================================

# Sets the following globals on return:
#   ISSUE_ASSESSMENT_SUMMARY     — FULLY_DONE | PARTIALLY_DONE | NOT_STARTED | UNKNOWN
#   ISSUE_ASSESSMENT_EVIDENCE    — short free-text summary of main's state
#   ISSUE_ASSESSMENT_COMPLETED   — newline-separated criteria already satisfied
#   ISSUE_ASSESSMENT_PENDING     — newline-separated criteria still needed
#
# Always returns 0 (failures degrade to UNKNOWN). Callers must check the
# globals, not the return code.
assess_issue_completion() {
  local issue_number="$1"
  local issue_body="${2:-}"

  ISSUE_ASSESSMENT_SUMMARY="UNKNOWN"
  ISSUE_ASSESSMENT_EVIDENCE=""
  ISSUE_ASSESSMENT_COMPLETED=""
  ISSUE_ASSESSMENT_PENDING=""

  # Empty body → can't assess. Don't waste a provider call.
  if [ -z "$issue_body" ]; then
    return 0
  fi

  # Skip if the provider isn't loaded (we may be invoked early).
  if ! command -v provider_run_prompt_with_timeout &>/dev/null; then
    return 0
  fi

  # Quoted-string interpolation, not `$(cat <<EOF)`. The heredoc-in-command-
  # substitution form recursively expands `$(...)` and backticks inside the
  # body — any such characters in the issue body crash the parser before the
  # prompt is built. See the longer note further down in this file.
  local prompt
  prompt="You are assessing whether GitHub issue #${issue_number}'s work has already been done on the main branch of the current repository.

You may use Read, Grep, Glob, and Bash (read-only commands like git log, git diff, ls, cat, grep). Do NOT modify any files.

# Issue body

${issue_body}

# Your task

Inspect the current state of main (origin/main if available, else HEAD on the main branch). For each acceptance criterion in the issue body, classify as:
  DONE     — code on main fully satisfies this criterion
  PARTIAL  — code on main partially addresses but is incomplete
  NOT_DONE — no code on main addresses this

If the issue lacks clear acceptance criteria, classify the issue as a whole.

# Output

Output EXACTLY this format. No preamble, no commentary, no markdown beyond what is shown.

SUMMARY: <FULLY_DONE|PARTIALLY_DONE|NOT_STARTED|UNKNOWN>
EVIDENCE: <one short sentence about what is on main, or \"no clear criteria\">
COMPLETED:
- <criterion text> (file:line if applicable)
PENDING:
- <criterion text>

Rules:
- SUMMARY must be exactly one of the four uppercase tokens.
- COMPLETED and PENDING sections must each begin with that header on its own line.
- Each item must start with \"- \" (dash space).
- Both sections may be empty (just the header).
- Use UNKNOWN only when the issue body has no parseable criteria."

  # Run via the utility provider with a moderate timeout (90s).
  # Use run_prompt_with_timeout which goes through --print and is non-agentic.
  # The prompt asks for tool use but providers without agentic non-print mode
  # will degrade to a best-effort textual answer based on the issue alone.
  local response
  response=$(provider_run_prompt_with_timeout "$prompt" "" "true" 90 2>/dev/null || echo "")

  if [ -z "$response" ]; then
    return 0
  fi

  # Parse SUMMARY
  local _summary
  _summary=$(echo "$response" | grep -oE '^SUMMARY:[[:space:]]+(FULLY_DONE|PARTIALLY_DONE|NOT_STARTED|UNKNOWN)' | head -1 | awk '{print $2}')
  if [ -n "${_summary:-}" ]; then
    ISSUE_ASSESSMENT_SUMMARY="$_summary"
  fi

  # Parse EVIDENCE
  ISSUE_ASSESSMENT_EVIDENCE=$(echo "$response" | grep -E '^EVIDENCE:' | head -1 | sed -E 's/^EVIDENCE:[[:space:]]*//')

  # Parse COMPLETED block (between COMPLETED: and PENDING: or end)
  ISSUE_ASSESSMENT_COMPLETED=$(echo "$response" | awk '
    /^COMPLETED:/ { in_completed=1; next }
    /^PENDING:/   { in_completed=0 }
    in_completed && /^- / { print }
  ')

  # Parse PENDING block (from PENDING: to next non-list line or end)
  ISSUE_ASSESSMENT_PENDING=$(echo "$response" | awk '
    /^PENDING:/ { in_pending=1; next }
    in_pending && /^[A-Z][A-Z_]+:/ { in_pending=0 }
    in_pending && /^- / { print }
  ')

  return 0
}

# Render the assessment as a markdown block suitable for injection into the
# dev session prompt. Only meaningful for PARTIALLY_DONE summaries.
render_assessment_for_prompt() {
  if [ "${ISSUE_ASSESSMENT_SUMMARY:-UNKNOWN}" != "PARTIALLY_DONE" ]; then
    return 0
  fi

  cat <<EOF

## Resume Context (assessor read main before this session)

${ISSUE_ASSESSMENT_EVIDENCE:-}

**Already satisfied on main — do NOT re-implement these:**
${ISSUE_ASSESSMENT_COMPLETED:-(none)}

**Still needs work:**
${ISSUE_ASSESSMENT_PENDING:-(none)}

If you find that any "still needs work" item is in fact already done, log it
to the encountered-issues scratchpad rather than silently re-implementing.
EOF
}

# =============================================================================
# In-flight work classification
# =============================================================================
#
# When an issue closes mid-session, we have to decide what to do with the
# in-flight branch's work. The naive answer "close the PR and delete the
# branch" is wrong if the in-flight work added something main doesn't have.
#
# Sets these globals on return:
#   INFLIGHT_CLASSIFICATION — EMPTY | REDUNDANT | CONFLICTING | ADDITIVE | UNKNOWN
#   INFLIGHT_EVIDENCE       — one short sentence
#
# Always returns 0; failure modes degrade to UNKNOWN.
classify_inflight_work() {
  local issue_number="$1"
  local issue_body="$2"
  local worktree_path="$3"
  local base_ref="${4:-origin/main}"

  INFLIGHT_CLASSIFICATION="UNKNOWN"
  INFLIGHT_EVIDENCE=""

  if [ -z "${worktree_path:-}" ] || [ ! -d "$worktree_path" ]; then
    INFLIGHT_CLASSIFICATION="EMPTY"
    INFLIGHT_EVIDENCE="No worktree present"
    return 0
  fi

  # Compare branch HEAD to the base. Excludes placeholder commits.
  local _diff_stat _diff_text _commit_count _meaningful_lines
  _commit_count=$(git -C "$worktree_path" rev-list --count "${base_ref}..HEAD" 2>/dev/null || echo "0")
  _diff_stat=$(git -C "$worktree_path" diff --shortstat "${base_ref}...HEAD" 2>/dev/null || echo "")

  # If no commits ahead and no uncommitted changes, EMPTY.
  local _uncommitted
  _uncommitted=$(git -C "$worktree_path" status --porcelain 2>/dev/null | grep -v '^.. \.gitignore$' | wc -l | tr -d ' ')
  if [ "${_commit_count:-0}" -eq 0 ] && [ "${_uncommitted:-0}" -eq 0 ]; then
    INFLIGHT_CLASSIFICATION="EMPTY"
    INFLIGHT_EVIDENCE="No commits ahead of $base_ref and no uncommitted changes"
    return 0
  fi

  # Treat init-only branches as EMPTY too (placeholder commit counts as work
  # in rev-list but is meaningless).
  local _non_placeholder_commits
  _non_placeholder_commits=$(git -C "$worktree_path" log --format='%s' "${base_ref}..HEAD" 2>/dev/null | grep -vE '^chore: initialize work' | wc -l | tr -d ' ')
  if [ "${_non_placeholder_commits:-0}" -eq 0 ] && [ "${_uncommitted:-0}" -eq 0 ]; then
    INFLIGHT_CLASSIFICATION="EMPTY"
    INFLIGHT_EVIDENCE="Only placeholder commits on branch"
    return 0
  fi

  # We have real in-flight work. Ask the LLM to classify it against current main.
  if ! command -v provider_run_prompt_with_timeout &>/dev/null; then
    return 0
  fi

  # Capture diff (truncated for prompt size).
  _diff_text=$(git -C "$worktree_path" diff "${base_ref}...HEAD" 2>/dev/null | head -c 12000 || echo "")
  if [ -n "${_uncommitted:-0}" ] && [ "${_uncommitted:-0}" -gt 0 ]; then
    _diff_text="${_diff_text}

# Uncommitted changes in working tree:
$(git -C "$worktree_path" diff 2>/dev/null | head -c 4000)"
  fi

  # Recent main commits since branch base — useful for spotting "elsewhere did
  # the same thing".
  local _main_summary
  _main_summary=$(git log "${base_ref}" --pretty=format:'%h %s' -20 2>/dev/null || echo "")

  # Build the prompt via a plain quoted string rather than `$(cat <<EOF)`. The
  # heredoc-in-command-substitution form recursively expands `$(...)` and
  # backticks inside the heredoc body — so any `$(...)` or unbalanced paren
  # smuggled in via the issue body, diff, or commit log crashes the parser
  # with "unexpected EOF while looking for matching `)'" before the prompt
  # is ever built. Variables expanded into a double-quoted string get their
  # literal values substituted; bash does not recursively expand the result.
  local prompt
  prompt="You are classifying an in-flight branch's work for issue #${issue_number}, which was closed by something else during the session.

Decide whether the in-flight work should be discarded or preserved.

# Issue body

${issue_body}

# Recent commits on ${base_ref} (newest first)

${_main_summary}

# In-flight branch diff (vs ${base_ref}, possibly truncated)

\`\`\`diff
${_diff_text}
\`\`\`

# Classify

Output EXACTLY one of these labels, on a line by itself, followed by EVIDENCE:

CLASSIFICATION: <REDUNDANT|CONFLICTING|ADDITIVE|UNKNOWN>
EVIDENCE: <one short sentence>

Definitions:
- REDUNDANT: in-flight work duplicates what's already on ${base_ref}; no unique value.
- CONFLICTING: in-flight work contradicts ${base_ref} (different design, conflicting changes); applying it would regress or break.
- ADDITIVE: in-flight work adds something ${base_ref} does NOT have — improvements, missed criteria, useful tests/comments — that a human reviewer would likely want preserved.
- UNKNOWN: insufficient context to decide safely.

Be conservative: lean ADDITIVE when in doubt about discarding real code, lean UNKNOWN when you can't tell."

  local response
  response=$(provider_run_prompt_with_timeout "$prompt" "" "true" 90 2>/dev/null || echo "")

  if [ -z "$response" ]; then
    return 0
  fi

  local _cls
  _cls=$(echo "$response" | grep -oE '^CLASSIFICATION:[[:space:]]+(REDUNDANT|CONFLICTING|ADDITIVE|UNKNOWN)' | head -1 | awk '{print $2}')
  if [ -n "${_cls:-}" ]; then
    INFLIGHT_CLASSIFICATION="$_cls"
  fi
  INFLIGHT_EVIDENCE=$(echo "$response" | grep -E '^EVIDENCE:' | head -1 | sed -E 's/^EVIDENCE:[[:space:]]*//')

  return 0
}

# =============================================================================
# Mid-session close detection
# =============================================================================

# Returns:
#   0 — issue still OPEN (or our own PR closed it); proceed normally
#   2 — issue CLOSED elsewhere; in-flight work pitched (EMPTY / REDUNDANT /
#       CONFLICTING with diff archived); caller should exit success
#   4 — issue CLOSED elsewhere; in-flight work was ADDITIVE and has been
#       PRESERVED for human review (PR/branch/worktree intact, comment posted);
#       caller should exit success
#   1 — UNKNOWN classification or test-suite failure; caller should abort and
#       leave artifacts for human inspection
handle_mid_session_close() {
  local issue_number="$1"
  local pr_number="${2:-}"
  local worktree_path="${3:-}"

  if [ -z "$issue_number" ]; then
    return 0
  fi

  local state
  state=$(gh issue view "$issue_number" --json state --jq '.state' 2>/dev/null || echo "")
  if [ "$state" != "CLOSED" ]; then
    return 0
  fi

  local closing_pr
  closing_pr=$(gh issue view "$issue_number" --json closedByPullRequestsReferences --jq '.closedByPullRequestsReferences[0].number // empty' 2>/dev/null || echo "")

  # Our own PR closed the issue — normal merge, not a mid-session event.
  if [ -n "${pr_number:-}" ] && [ "$closing_pr" = "$pr_number" ]; then
    return 0
  fi

  # Pull latest main so classification sees the post-close state.
  git fetch origin main 2>/dev/null || true

  echo "ℹ️  Issue #$issue_number closed during this session (by ${closing_pr:+PR #$closing_pr}${closing_pr:-manual close})" >&2

  # Re-run the issue assessor first — we want to know if the criteria are
  # actually satisfied on main now. This protects against premature closes.
  local _body
  _body=$(gh issue view "$issue_number" --json body --jq '.body // ""' 2>/dev/null || echo "")
  assess_issue_completion "$issue_number" "$_body"

  if [ "${ISSUE_ASSESSMENT_SUMMARY:-}" != "FULLY_DONE" ]; then
    # Issue closed but criteria don't appear satisfied. Don't make assumptions —
    # leave artifacts for human inspection.
    echo "⚠️  Assessment after close is ${ISSUE_ASSESSMENT_SUMMARY:-UNKNOWN}; criteria don't appear satisfied on main" >&2
    [ -n "${ISSUE_ASSESSMENT_EVIDENCE:-}" ] && echo "    Evidence: $ISSUE_ASSESSMENT_EVIDENCE" >&2
    echo "    Leaving in-flight work for human review (worktree: ${worktree_path:-N/A})" >&2
    return 1
  fi

  echo "✅ Criteria satisfied on main: ${ISSUE_ASSESSMENT_EVIDENCE:-(see assessor)}" >&2

  # Optional test verification — only when the project has a configured test
  # command. The pre-existing RITE_TEST_CMD is the canonical hook.
  if [ -n "${RITE_TEST_CMD:-}" ]; then
    echo "▶  Running test suite to verify ($RITE_TEST_CMD)..." >&2
    local _repo_root
    _repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
    if (cd "$_repo_root" && eval "$RITE_TEST_CMD") >/dev/null 2>&1; then
      echo "✅ Tests pass on main" >&2
    else
      echo "⚠️  Tests fail on main — issue closure looks premature; leaving artifacts" >&2
      return 1
    fi
  fi

  # Classify the in-flight work to decide adopt-vs-pitch.
  classify_inflight_work "$issue_number" "$_body" "${worktree_path:-}" "origin/main"

  case "${INFLIGHT_CLASSIFICATION:-UNKNOWN}" in
    EMPTY)
      echo "ℹ️  In-flight work: EMPTY — nothing to preserve" >&2
      cleanup_inflight_work "$issue_number" "${pr_number:-}" "${worktree_path:-}" "Closed during session; no in-flight work"
      return 2
      ;;
    REDUNDANT)
      echo "ℹ️  In-flight work: REDUNDANT — already covered by main" >&2
      [ -n "${INFLIGHT_EVIDENCE:-}" ] && echo "    Evidence: $INFLIGHT_EVIDENCE" >&2
      cleanup_inflight_work "$issue_number" "${pr_number:-}" "${worktree_path:-}" "Closed during session; in-flight work was redundant with main"
      return 2
      ;;
    CONFLICTING)
      echo "⚠️  In-flight work: CONFLICTING with main — pitching, archiving diff" >&2
      [ -n "${INFLIGHT_EVIDENCE:-}" ] && echo "    Evidence: $INFLIGHT_EVIDENCE" >&2
      archive_inflight_diff "$issue_number" "${worktree_path:-}" "conflicting"
      cleanup_inflight_work "$issue_number" "${pr_number:-}" "${worktree_path:-}" "Closed during session; in-flight work conflicted with main (diff archived)"
      return 2
      ;;
    ADDITIVE)
      echo "💡 In-flight work: ADDITIVE — preserving for human review" >&2
      [ -n "${INFLIGHT_EVIDENCE:-}" ] && echo "    Evidence: $INFLIGHT_EVIDENCE" >&2
      preserve_inflight_for_review "$issue_number" "${pr_number:-}" "${worktree_path:-}" "${closing_pr:-}" "${INFLIGHT_EVIDENCE:-}"
      return 4
      ;;
    *)
      echo "⚠️  In-flight work: UNKNOWN — leaving artifacts for human review" >&2
      [ -n "${INFLIGHT_EVIDENCE:-}" ] && echo "    Evidence: $INFLIGHT_EVIDENCE" >&2
      return 1
      ;;
  esac
}

# Save the in-flight diff to the project's scratchpad so a conflicting branch's
# work isn't silently lost. Useful as an audit trail / recovery hook.
archive_inflight_diff() {
  local issue_number="$1"
  local worktree_path="$2"
  local label="${3:-archived}"

  [ -z "${worktree_path:-}" ] && return 0
  [ ! -d "$worktree_path" ] && return 0

  local archive_dir="${RITE_PROJECT_ROOT:-$(git rev-parse --show-toplevel)}/${RITE_DATA_DIR:-.rite}/inflight-archive"
  mkdir -p "$archive_dir" 2>/dev/null || return 0
  local stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  local archive_file="$archive_dir/issue-${issue_number}-${label}-${stamp}.patch"

  git -C "$worktree_path" diff origin/main...HEAD > "$archive_file" 2>/dev/null || true
  if [ -s "$archive_file" ]; then
    echo "📦 Archived in-flight diff to ${archive_file#${RITE_PROJECT_ROOT:-}/}" >&2
  else
    rm -f "$archive_file" 2>/dev/null
  fi
}

# Preserve PR/branch/worktree, retitle the PR, post explanatory comment on the
# now-closed issue. The user (or a follow-up) decides whether to merge.
preserve_inflight_for_review() {
  local issue_number="$1"
  local pr_number="$2"
  local worktree_path="$3"
  local closing_pr="$4"
  local evidence="$5"

  if [ -n "${pr_number:-}" ]; then
    # Mark PR draft + retitle so it stops looking like a regular merge candidate.
    local _orig_title
    _orig_title=$(gh pr view "$pr_number" --json title --jq '.title' 2>/dev/null || echo "")
    if [ -n "$_orig_title" ] && [[ "$_orig_title" != \[Adopted\]* ]]; then
      gh pr edit "$pr_number" --title "[Adopted] $_orig_title" 2>/dev/null || true
    fi
    gh pr ready --undo "$pr_number" 2>/dev/null || true

    local close_note
    if [ -n "$closing_pr" ]; then
      close_note="Issue #$issue_number was closed during this session by PR #$closing_pr."
    else
      close_note="Issue #$issue_number was closed manually during this session."
    fi

    gh pr comment "$pr_number" --body "🤖 **In-flight work preserved for review**

$close_note Sharkrite was mid-session on this issue when it closed.

Classification: \`ADDITIVE\` — this branch contains changes \`origin/main\` does not, that a reviewer might want to keep.

**Evidence:** ${evidence:-(see classifier output)}

**Next steps:**
- Review the diff. If useful, retitle and re-target this PR (or open a follow-up issue).
- If not useful, close this PR and delete the branch.

Sharkrite did not auto-merge or auto-close." 2>/dev/null || true
    echo "✅ Preserved PR #$pr_number with [Adopted] prefix and explanatory comment" >&2
  fi

  # Mirror a comment on the issue so it's discoverable from there too.
  if [ -n "${pr_number:-}" ]; then
    gh issue comment "$issue_number" --body "🤖 Sharkrite was mid-session on this issue when it closed. In-flight work was classified \`ADDITIVE\` and preserved at PR #$pr_number for review." 2>/dev/null || true
  fi

  # Leave worktree + branch in place. They're safe to remove later via
  # \`rite cleanup-worktrees\` if the PR is closed.
  if [ -n "${worktree_path:-}" ]; then
    echo "ℹ️  Worktree preserved: $worktree_path" >&2
  fi
}

# Close in-flight PR (if any), remove worktree, delete branches.
cleanup_inflight_work() {
  local issue_number="$1"
  local pr_number="$2"
  local worktree_path="$3"
  local reason="${4:-Issue resolved during session}"

  if [ -n "${pr_number:-}" ]; then
    gh pr close "$pr_number" --comment "Closed automatically by sharkrite: $reason. Issue #$issue_number is no longer open; in-flight work superseded." 2>/dev/null || true
    echo "✅ Closed in-flight PR #$pr_number" >&2
  fi

  if [ -n "${worktree_path:-}" ] && [ -d "${worktree_path:-}" ]; then
    local branch_name
    branch_name=$(git -C "$worktree_path" branch --show-current 2>/dev/null || echo "")

    git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
    echo "✅ Removed worktree: $(basename "$worktree_path")" >&2

    if [ -n "${branch_name:-}" ]; then
      git branch -D "$branch_name" >/dev/null 2>&1 || true
      git push origin --delete "$branch_name" >/dev/null 2>&1 || true
      echo "✅ Cleaned up branch: $branch_name" >&2
    fi
  fi
}

# Export for use across sourced scripts
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  export -f assess_issue_completion
  export -f render_assessment_for_prompt
  export -f classify_inflight_work
  export -f handle_mid_session_close
  export -f archive_inflight_diff
  export -f preserve_inflight_for_review
  export -f cleanup_inflight_work
fi
