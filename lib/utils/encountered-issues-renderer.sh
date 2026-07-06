#!/bin/bash
# lib/utils/encountered-issues-renderer.sh
#
# Renders docs/architecture/encountered-issues.md from closed GitHub issues and
# PRs that carry the <!-- sharkrite-recurring-pattern --> in-body marker block.
#
# Each marker block represents one bug class that recurred 2+ times during
# dogfooding. The rendered file lists each pattern, its instances, root cause,
# and mitigation — so future Claude sessions can diagnose similar bugs faster.
#
# Discovery mechanism:
#   Primary path  — closed issues/PRs whose BODY contains the marker block
#                   <!-- sharkrite-recurring-pattern --> ... <!-- /sharkrite-recurring-pattern -->
#   Legacy path   — closed issues with the `recurring-pattern` LABEL (transition period)
#   Both paths are unioned and deduplicated by issue number so that issues
#   labeled during the pre-marker era are still ingested. Once all known
#   patterns carry the marker, the label path can be removed.
#
# To register a new pattern: add the marker block (see encountered-issues.md
# for the format) to the issue or PR body — no label needed.
#
# Usage (standalone): lib/utils/encountered-issues-renderer.sh
# Usage (via rite):   rite --refresh-encountered-issues
# Usage (in tests):   RITE_SOURCE_FUNCTIONS_ONLY=1 source encountered-issues-renderer.sh

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f render_encountered_issues >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"
source "$RITE_LIB_DIR/utils/gh-retry.sh"
source "$RITE_LIB_DIR/utils/markers.sh"

# ---------------------------------------------------------------------------
# _extract_marker_block(body)
#
# Extracts the content between <!-- sharkrite-recurring-pattern --> and
# <!-- /sharkrite-recurring-pattern --> from the given body text.
#
# The open marker must appear as the COMPLETE HTML comment tag (no prefix/suffix
# other than optional whitespace) — this is the format anchor that prevents a
# body which merely DOCUMENTS the marker from matching (bare-prefix-guard rule).
#
# Returns the block content on stdout, or empty string if no block found.
# ---------------------------------------------------------------------------
_extract_marker_block() {
  local body="$1"
  local open_marker="<!-- ${RITE_MARKER_RECURRING_PATTERN} -->"
  local close_marker="<!-- /${RITE_MARKER_RECURRING_PATTERN} -->"

  # awk-based extraction with fenced-code-block guard (mirrors conventions.md approach).
  # Convention block content is processed FIRST — lines inside the marker block
  # are never seen by the fence guard (prevents a backtick-fence inside the block
  # from prematurely toggling the guard and truncating the block).
  # Inline on one line so Rule 8's next-line lookahead picks up `|| true`.
  echo "$body" | awk -v open="$open_marker" -v close="$close_marker" '$0 == open && !in_fence { in_block=1; buf=""; next } in_block && $0 == close { print buf; in_block=0; next } in_block { buf = (buf == "") ? $0 : buf "\n" $0; next } !in_fence && /^[[:space:]]{0,3}```/ { fence_str=$0; sub(/^[[:space:]]*/,"",fence_str); fence_len=0; while(substr(fence_str,fence_len+1,1)=="`") fence_len++; in_fence=1; next } in_fence && /^[[:space:]]{0,3}```/ { close_str=$0; sub(/^[[:space:]]*/,"",close_str); close_len=0; while(substr(close_str,close_len+1,1)=="`") close_len++; close_after=substr(close_str,close_len+1); if(close_len>=fence_len && close_after~/^[[:space:]]*$/) { in_fence=0; fence_len=0 }; next } in_fence { next } $0 == close { next }' || true
}

# ---------------------------------------------------------------------------
# _body_has_recurring_marker(body)
#
# Returns 0 (true) if the body contains a REAL (format-anchored) marker block.
# Returns 1 if not present or only found in documentation examples.
#
# Format anchor: the open tag must appear as the complete, literal HTML comment
# "<!-- sharkrite-recurring-pattern -->" — not a bare "sharkrite-recurring-pattern:"
# prefix, not inside a fenced code block.  This prevents issue bodies that
# merely DOCUMENT the marker format from being treated as carriers.
# ---------------------------------------------------------------------------
_body_has_recurring_marker() {
  local body="$1"
  local block
  block=$(_extract_marker_block "$body")
  [ -n "$block" ]
}

# ---------------------------------------------------------------------------
# render_encountered_issues()
#
# Fetches closed issues and PRs that carry the sharkrite-recurring-pattern
# in-body marker block from GitHub, renders sorted markdown to OUTPUT_FILE
# (defaults to docs/architecture/encountered-issues.md).
#
# Also ingests issues with the legacy `recurring-pattern` label (transition
# period — allows pre-marker issues to still appear in the catalog).
#
# Environment:
#   RITE_PROJECT_ROOT  — project root (set by config.sh)
#   OUTPUT_FILE        — override output path (optional, for testing)
#
# Exit codes:
#   0 — rendered successfully
#   1 — gh CLI unavailable or fetch failed
# ---------------------------------------------------------------------------
render_encountered_issues() {
  local output_file="${OUTPUT_FILE:-$RITE_PROJECT_ROOT/docs/architecture/encountered-issues.md}"
  local legacy_label="recurring-pattern"

  # Ensure output directory exists
  mkdir -p "$(dirname "$output_file")"

  # ── Primary path: body-marker harvest ────────────────────────────────────
  # Fetch all recently closed issues and filter to those whose body contains the
  # format-anchored marker.  The --search flag uses GitHub's "in:body" qualifier
  # to pre-filter server-side; we still validate locally to reject documentation
  # examples (bare-prefix-guard requirement).
  #
  # We search for the marker name WITHOUT the HTML comment delimiters, since
  # GitHub's issue search strips HTML comments.  The format anchor is enforced
  # locally by _body_has_recurring_marker() after fetch.
  print_info "Fetching closed issues/PRs with body marker '${RITE_MARKER_RECURRING_PATTERN}'..." >&2

  # GitHub strips HTML comments before indexing, so the "in:body" search qualifier
  # will return zero results for markers that exist ONLY inside <!-- --> tags.
  # Strategy: try the server-side search first (fast, handles non-HTML-comment
  # markers), then always backstop with a bounded recently-closed fetch and a
  # local _body_has_recurring_marker scan to catch HTML-comment-only markers.
  # Results from both paths are merged and deduplicated by number.

  local marker_issues_json marker_prs_json
  # Issues: server-side pre-filter attempt (may return empty due to HTML-comment stripping)
  # --limit 1000 (gh's max page) so aged issues are not silently dropped as the
  # repo grows — the previous --limit 200 window could miss patterns older than
  # the 200 most-recently-closed issues (#923).
  local _server_issues_json
  _server_issues_json=$(gh_safe issue list \
    --state closed \
    --search "${RITE_MARKER_RECURRING_PATTERN} in:body" \
    --json number,title,body,closedAt,closedByPullRequestsReferences \
    --limit 1000 2>/dev/null || true)
  _server_issues_json="${_server_issues_json:-[]}"

  # Issues: bounded recently-closed fetch for local scan backstop.
  # GitHub strips HTML comments from the indexed body, so "in:body" misses
  # markers that live inside <!-- --> tags.  Fetch the 1000 most recent closed
  # issues and validate locally; merge with the server-side results so neither
  # path is the only line of defence.  1000 = gh's max page, matching the
  # closed-PR cleanup fallback (workflow-runner.sh Tier 2) for consistency.
  local _recent_issues_json
  _recent_issues_json=$(gh_safe issue list \
    --state closed \
    --json number,title,body,closedAt,closedByPullRequestsReferences \
    --limit 1000 2>/dev/null || true)
  _recent_issues_json="${_recent_issues_json:-[]}"

  # Merge server + recent; unique_by(.number) keeps the first occurrence (server result
  # is first, so its richer data wins when both paths find the same issue).
  marker_issues_json=$(jq -n \
    --argjson srv "$_server_issues_json" \
    --argjson rec "$_recent_issues_json" \
    '($srv + $rec) | unique_by(.number)' 2>/dev/null || echo "[]")
  marker_issues_json="${marker_issues_json:-[]}"

  # PRs: same two-path approach.
  # --limit 1000 matches the issue backstop and gh's max page size (#923).
  local _server_prs_json
  _server_prs_json=$(gh_safe pr list \
    --state closed \
    --search "${RITE_MARKER_RECURRING_PATTERN} in:body" \
    --json number,title,body,closedAt \
    --limit 1000 2>/dev/null || true)
  _server_prs_json="${_server_prs_json:-[]}"

  # PRs: bounded recently-closed fetch backstop.
  # --limit 1000 so marker-carrying PRs that age past the old 300-result window
  # are still harvested during the local _body_has_recurring_marker scan.
  local _recent_prs_json
  _recent_prs_json=$(gh_safe pr list \
    --state closed \
    --json number,title,body,closedAt \
    --limit 1000 2>/dev/null || true)
  _recent_prs_json="${_recent_prs_json:-[]}"

  # Merge server + recent PR results; server wins on duplicates.
  marker_prs_json=$(jq -n \
    --argjson srv "$_server_prs_json" \
    --argjson rec "$_recent_prs_json" \
    '($srv + $rec) | unique_by(.number)' 2>/dev/null || echo "[]")
  marker_prs_json="${marker_prs_json:-[]}"

  # ── Legacy path: label harvest (transition period) ────────────────────────
  # Still ingest issues with the old `recurring-pattern` label so that patterns
  # documented before this marker was introduced are not lost.
  # Removed once all known patterns have been migrated to the marker.
  print_info "Fetching closed issues with legacy label '${legacy_label}' (transition)..." >&2

  local legacy_issues_json
  # --limit 1000 matches the marker backstop so legacy-labeled patterns are not
  # silently dropped from the catalog as the repo grows past 200+ closed issues.
  legacy_issues_json=$(gh_safe issue list \
    --label "$legacy_label" \
    --state closed \
    --json number,title,body,closedAt,closedByPullRequestsReferences \
    --limit 1000 2>/dev/null || true)
  legacy_issues_json="${legacy_issues_json:-[]}"

  # ── Local format-anchor validation ───────────────────────────────────────
  # Filter marker_issues_json to only entries where the body actually contains
  # a REAL (format-anchored) <!-- sharkrite-recurring-pattern --> block.
  # This rejects issues whose bodies merely document the marker format.
  #
  # Implementation: write each body to a temp file, run _body_has_recurring_marker,
  # collect passing indices, then rebuild a filtered JSON array with jq.
  local _marker_count _marker_count_raw
  _marker_count_raw=$(echo "$marker_issues_json" | jq 'length' 2>/dev/null || echo "0")
  # Digits-only guard: jq may return empty/null if the input was malformed;
  # a non-integer would abort the while loop under set -e.  Default to 0.
  case "${_marker_count_raw:-}" in
    ''|*[!0-9]*) _marker_count=0 ;;
    *) _marker_count="$_marker_count_raw" ;;
  esac

  # _validated_indices accumulates as "0,2,5" — a comma-separated list of
  # passing array indices. jq's .[0,2,5] slice syntax selects exactly those
  # elements without a shell loop, producing a filtered array in one jq call.
  local _validated_indices=""
  local _vi=0
  while [ "$_vi" -lt "$_marker_count" ]; do
    local _candidate_body
    _candidate_body=$(echo "$marker_issues_json" | jq -r ".[$_vi].body // \"\"" 2>/dev/null || true)
    if _body_has_recurring_marker "$_candidate_body"; then
      _validated_indices="${_validated_indices:+$_validated_indices,}$_vi"
    fi
    _vi=$((_vi + 1))
  done

  # Rebuild validated issues array from passing indices
  local validated_marker_issues_json
  if [ -n "$_validated_indices" ]; then
    validated_marker_issues_json=$(echo "$marker_issues_json" | jq "[.[$_validated_indices]]" 2>/dev/null || echo "[]")
  else
    validated_marker_issues_json="[]"
  fi

  # Validate PR marker bodies similarly; synthesize issue-like shape (no closedByPullRequestsReferences)
  local _pr_count _pr_count_raw
  _pr_count_raw=$(echo "$marker_prs_json" | jq 'length' 2>/dev/null || echo "0")
  # Digits-only guard: same rationale as _marker_count above.
  case "${_pr_count_raw:-}" in
    ''|*[!0-9]*) _pr_count=0 ;;
    *) _pr_count="$_pr_count_raw" ;;
  esac

  local _pr_validated_indices=""
  local _pi=0
  while [ "$_pi" -lt "$_pr_count" ]; do
    local _pr_candidate_body
    _pr_candidate_body=$(echo "$marker_prs_json" | jq -r ".[$_pi].body // \"\"" 2>/dev/null || true)
    if _body_has_recurring_marker "$_pr_candidate_body"; then
      _pr_validated_indices="${_pr_validated_indices:+$_pr_validated_indices,}$_pi"
    fi
    _pi=$((_pi + 1))
  done

  # PRs become issue-like records with closedByPullRequestsReferences = [] (they ARE the PR)
  local validated_marker_prs_json
  if [ -n "$_pr_validated_indices" ]; then
    validated_marker_prs_json=$(echo "$marker_prs_json" | jq "[.[$_pr_validated_indices] | {number, title, body, closedAt, closedByPullRequestsReferences: []}]" 2>/dev/null || echo "[]")
  else
    validated_marker_prs_json="[]"
  fi

  # ── Merge + deduplicate by issue number ───────────────────────────────────
  # Union of marker issues, marker PRs, and legacy label issues.
  # When the same number appears in multiple sources, the first occurrence wins
  # (marker takes priority over legacy label, since marker bodies are richer).
  # jq's unique_by preserves first occurrence in the array.
  local all_issues_json
  all_issues_json=$(jq -n \
    --argjson marker "$validated_marker_issues_json" \
    --argjson prs "$validated_marker_prs_json" \
    --argjson legacy "$legacy_issues_json" \
    '($marker + $prs + $legacy) | unique_by(.number)' 2>/dev/null || echo "[]")
  all_issues_json="${all_issues_json:-[]}"

  local count
  count=$(echo "$all_issues_json" | jq 'length' 2>/dev/null || echo "0")

  local marker_found legacy_found
  marker_found=$(echo "$validated_marker_issues_json" | jq 'length' 2>/dev/null || echo "0")
  legacy_found=$(echo "$legacy_issues_json" | jq 'length' 2>/dev/null || echo "0")
  print_info "Found ${marker_found} issue(s) with body marker, ${legacy_found} with legacy label, ${count} total after dedup" >&2

  # Sort by issue number ascending (stable, deterministic output)
  local sorted_json
  sorted_json=$(echo "$all_issues_json" | jq 'sort_by(.number)' 2>/dev/null || echo "[]")

  local today
  today=$(date '+%Y-%m-%d')

  # ── Write header ──────────────────────────────────────────────────────────
  {
    echo "<!-- Auto-generated by encountered-issues-renderer.sh. Do not hand-edit."
    echo "     To add a pattern: add a <!-- ${RITE_MARKER_RECURRING_PATTERN} --> block to the"
    echo "     closed issue or PR body and run \`rite --refresh-encountered-issues\`."
    echo "     Last refreshed: $today -->"
    echo ""
    echo "# Encountered Issues — Recurring Bug Pattern Catalog"
    echo ""
    echo "> **Auto-generated. Do not hand-edit.** To add a pattern, add a"
    echo "> \`<!-- ${RITE_MARKER_RECURRING_PATTERN} -->\` block to the closed issue or PR body"
    echo "> and run \`rite --refresh-encountered-issues\`."
    echo ""
    echo "This catalog lists bug classes that recurred 2+ times during Sharkrite"
    echo "dogfooding. Its purpose: let future Claude sessions recognize a familiar"
    echo "pattern quickly and apply the known fix rather than re-diagnosing from scratch."
    echo ""
    echo "Each entry includes: the pattern name, recurrence instances (PRs + dates),"
    echo "root-cause class, and the mitigation or lint rule that prevents recurrence."
    echo ""
    if [ "$count" -eq 0 ]; then
      echo "---"
      echo ""
      echo "_No recurring patterns recorded yet. Add a_"
      echo "_\`<!-- ${RITE_MARKER_RECURRING_PATTERN} -->\` block to a closed issue or PR body_"
      echo "_and re-run \`rite --refresh-encountered-issues\`._"
    else
      echo "## Table of Contents"
      echo ""

      # TOC: one entry per issue
      local i=0
      while [ "$i" -lt "$count" ]; do
        local title number anchor
        title=$(echo "$sorted_json" | jq -r ".[$i].title" 2>/dev/null || echo "")
        number=$(echo "$sorted_json" | jq -r ".[$i].number" 2>/dev/null || echo "")
        # GitHub-style anchor: lowercase, spaces→hyphens, strip non-alphanum-hyphen
        anchor=$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | sed 's/--*/-/g' || true)
        echo "- [#${number}: ${title}](#${anchor})"
        i=$((i + 1))
      done

      echo ""
      echo "---"

      # ── One entry per issue ──────────────────────────────────────────────
      i=0
      while [ "$i" -lt "$count" ]; do
        local issue_number issue_title issue_body issue_closed_at pr_refs_json
        issue_number=$(echo "$sorted_json" | jq -r ".[$i].number" 2>/dev/null || echo "")
        issue_title=$(echo "$sorted_json" | jq -r ".[$i].title" 2>/dev/null || echo "")
        issue_body=$(echo "$sorted_json" | jq -r ".[$i].body // \"\"" 2>/dev/null || echo "")
        issue_closed_at=$(echo "$sorted_json" | jq -r ".[$i].closedAt // \"\"" 2>/dev/null | cut -dT -f1 || echo "")
        pr_refs_json=$(echo "$sorted_json" | jq -r ".[$i].closedByPullRequestsReferences" 2>/dev/null || echo "[]")

        echo ""
        echo "## ${issue_title}"
        echo ""

        # ── Instances ───────────────────────────────────────────────────────
        echo "**Issue:** [#${issue_number}](https://github.com/lifeunsubscribe/Sharkrite/issues/${issue_number})"
        echo ""

        # Closing PRs (sorted by number)
        local pr_count
        pr_count=$(echo "$pr_refs_json" | jq 'length' 2>/dev/null || echo "0")
        if [ "$pr_count" -gt 0 ]; then
          echo "**Fixed by:**"
          echo ""
          local pr_sorted
          pr_sorted=$(echo "$pr_refs_json" | jq 'sort_by(.number)' 2>/dev/null || echo "[]")
          local j=0
          while [ "$j" -lt "$pr_count" ]; do
            local pr_num
            pr_num=$(echo "$pr_sorted" | jq -r ".[$j].number" 2>/dev/null || echo "")
            echo "- PR [#${pr_num}](https://github.com/lifeunsubscribe/Sharkrite/pull/${pr_num})"
            j=$((j + 1))
          done
          echo ""
        fi

        [ -n "$issue_closed_at" ] && echo "**Closed:** ${issue_closed_at}" && echo ""

        # ── Body sections ────────────────────────────────────────────────────
        # Priority 0: extract the in-body marker block content (new mechanism).
        # Falls through to legacy strategies for pre-marker issues.
        _render_body_sections "$issue_body"

        echo "---"

        i=$((i + 1))
      done
    fi
  } > "$output_file"

  print_success "Wrote $count pattern(s) to $output_file" >&2
  echo "$output_file"
}

# ---------------------------------------------------------------------------
# _render_body_sections(body)
#
# Extracts meaningful content from an issue body in priority order:
#
#   0. <!-- sharkrite-recurring-pattern --> block (new in-body marker)
#   1. **Description**: field (standard Sharkrite issue template — after the
#      "---" divider that follows the Bug Confirmation block)
#   2. Canonical ## headings: Description, Root Cause, Variants, Mitigation,
#      Related (for custom recurring-pattern issues with explicit structure)
#   3. First meaningful prose paragraph after any ## block (fallback)
#
# Intentionally skips: Bug confirmation blocks, code blocks, bash commands.
# ---------------------------------------------------------------------------
_render_body_sections() {
  local body="$1"

  if [ -z "$body" ]; then
    echo "_No description._"
    echo ""
    return
  fi

  # ── Strategy 0: In-body marker block (new mechanism) ─────────────────────
  # When the body carries a <!-- sharkrite-recurring-pattern --> block,
  # render its content verbatim (it already contains structured fields like
  # **Pattern:**, **Root Cause:**, **Mitigation:**).
  local marker_block
  marker_block=$(_extract_marker_block "$body")
  if [ -n "$marker_block" ]; then
    # Strip leading/trailing blank lines (portable awk — no BSD-sed \n quirks).
    # Inlined onto one line so Rule 8's next-line lookahead picks up `|| true`.
    marker_block=$(echo "$marker_block" | awk '/[^[:space:]]/ { found=1 } found { lines[n++] = $0 } END { while (n > 0 && lines[n-1] ~ /^[[:space:]]*$/) n--; for (i = 0; i < n; i++) print lines[i] }' || true)
    if [ -n "$marker_block" ]; then
      echo "$marker_block"
      echo ""
      return
    fi
  fi

  # ── Strategy 1: Extract **Description**: from standard Sharkrite template ──
  # The template puts "---\n\n**Time**: ...\n\n**Description**:\nProse here\n\n"
  # after the Bug Confirmation block. Extract the Description value.
  local description_text
  # Extract the **Description**: block: from the header line through the next
  # **Bold**: header / ## heading / --- divider. The awk script is kept on a
  # single line so sharkrite-lint Rule 8's next-line lookahead picks up `|| true`.
  description_text=$(echo "$body" | awk '/^\*\*Description\*\*:/ { found = 1; remainder = $0; sub(/^\*\*Description\*\*:[[:space:]]*/, "", remainder); if (remainder != "") buf = remainder; next } found == 1 { if (/^\*\*[A-Za-z].*\*\*:/ || /^## / || /^---$/) { found = 2; exit } buf = (buf == "" ? $0 : buf "\n" $0) } END { if (buf != "") print buf }' || true)
  description_text="${description_text:-}"

  if [ -n "$description_text" ]; then
    # Strip leading/trailing blank lines (portable awk — no BSD-sed \n quirks).
    # Inlined onto one line so Rule 8's next-line lookahead picks up `|| true`.
    description_text=$(echo "$description_text" | awk '/[^[:space:]]/ { found=1 } found { lines[n++] = $0 } END { while (n > 0 && lines[n-1] ~ /^[[:space:]]*$/) n--; for (i = 0; i < n; i++) print lines[i] }' || true)
    if [ -n "$description_text" ]; then
      echo "**Description:**"
      echo ""
      echo "$description_text"
      echo ""
      return
    fi
  fi

  # ── Strategy 2: Canonical ## headings ────────────────────────────────────
  # Used when the issue was written with explicit structure (## Root Cause etc.)
  if echo "$body" | grep -qE '^## (Description|Root Cause|Variants|Mitigation|Related)$'; then
    echo "$body" | awk '
      /^## (Description|Root Cause|Variants|Mitigation|Related)$/ {
        if (buf != "" && current != "") {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", buf)
          print "**" current ":**"
          print ""
          print buf
          print ""
        }
        current = $0
        sub(/^## /, "", current)
        buf = ""
        next
      }
      /^## / { current = ""; buf = ""; next }
      current != "" { buf = (buf == "" ? $0 : buf "\n" $0) }
      END {
        if (buf != "" && current != "") {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", buf)
          print "**" current ":**"
          print ""
          print buf
          print ""
        }
      }
    '
    return
  fi

  # ── Strategy 3: First prose paragraph after the "---" divider ────────────
  # Skip the Bug Confirmation block entirely (before the first "---"), then
  # extract the first non-empty, non-code prose paragraph.
  local prose_excerpt
  # First prose paragraph after the "---" divider, skipping headings, code
  # blocks, and standard Sharkrite sections. Inlined onto one line so Rule 8's
  # next-line lookahead picks up `|| true`.
  prose_excerpt=$(echo "$body" | awk '/^---$/ { past_divider = 1; next } past_divider != 1 { next } /^## / { next } /^```/ { in_code = !in_code; next } in_code { next } /^\*\*Time\*\*:/ { next } /^\*\*Claude Context\*\*:/ { exit } /^\*\*Acceptance Criteria\*\*:/ { exit } /^[[:space:]]*$/ { if (chars > 0) { blanks++; if (blanks >= 2) exit } next } { blanks = 0; print; chars += length($0); if (chars > 600) exit }' | head -20 || true)

  if [ -n "$prose_excerpt" ]; then
    echo "**Summary:**"
    echo ""
    echo "$prose_excerpt"
    echo ""
  else
    echo "_See [issue body](https://github.com/lifeunsubscribe/Sharkrite/issues/) for details._"
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Function-only guard: when sourced with RITE_SOURCE_FUNCTIONS_ONLY=1, stop
# here so tests can load only function definitions without running the program.
# ---------------------------------------------------------------------------
if [ "${RITE_SOURCE_FUNCTIONS_ONLY:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi

# ── Executable body (runs when invoked directly) ──────────────────────────

if [ -z "${RITE_PROJECT_ROOT:-}" ]; then
  echo "ERROR: RITE_PROJECT_ROOT is not set. Source config.sh first or run via 'rite --refresh-encountered-issues'." >&2
  exit 1
fi

render_encountered_issues
