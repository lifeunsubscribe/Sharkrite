#!/bin/bash
# lib/utils/promotion-composer.sh
# Promotion PR body composer.
#
# Turns ledger entries, constituent PR titles/bodies/review summaries, aggregate
# diff stats, recorded --sync conflicts, and the doc drift log (when present)
# into a plain-English promotion PR narrative with per-issue subsections.
#
# Falls back to a deterministic template when the LLM call fails or returns
# empty output. Composer failure NEVER blocks promotion — both paths return 0.
#
# Data-flow convention:
#   stdout  = composed PR body (ready to pass to gh pr create --body)
#   stderr  = user-facing messages (print_warning, print_info)
#
# Public API:
#   gather_promotion_context  <branch> <out_file>
#   compose_promotion_pr_body <branch> <context_file>
#
# Dependencies (sourced by the caller before this file):
#   provider-interface.sh + a loaded provider (for provider_run_prompt_with_timeout
#   and provider_resolve_model)
#   lib/utils/colors.sh (for print_warning)
#   lib/utils/integration-ledger.sh (for integration_ledger_entries)
#   lib/utils/gh-retry.sh (for gh_safe)
#   lib/utils/git-helpers.sh (for git_fetch_safe)
#
# No command wiring, no PR creation, no pushes, no ledger writes — this is a
# pure read-and-compose helper consumed by the later --promote issues.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f compose_promotion_pr_body >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Bootstrap RITE_LIB_DIR if not already set (tests source this file directly)
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _PC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  source "$_PC_SCRIPT_DIR/config.sh"
fi

# Lazy-load dependencies only when not already available.
# Callers in production already have these loaded; tests that source this file
# directly may not — these guards prevent double-sourcing under set -e.

if ! declare -f gh_safe >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/gh-retry.sh"
fi

if ! declare -f git_fetch_safe >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/git-helpers.sh"
fi

if ! declare -f integration_ledger_entries >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/integration-ledger.sh"
fi

if ! declare -f print_warning >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/colors.sh"
fi

# Hard cap on assembled context (~50 KB, same default as RITE_PLAN_DOC_BYTE_CAP).
# Patch snips are the first thing truncated when the cap is approached.
_PROMOTION_CONTEXT_CAP_BYTES=51200

# =============================================================================
# _parse_ledger_field <line> <field>
#
# Extracts a tab-separated key=value field from a ledger line.
# e.g. _parse_ledger_field "$line" "issue" → "42"
# Returns empty string when the field is absent (never fails under set -e).
# =============================================================================
_parse_ledger_field() {
  local line="$1"
  local field="$2"
  # Each field is tab-separated in the form key=value
  # Use parameter expansion to avoid sed/awk portability concerns.
  echo "$line" | tr '\t' '\n' | grep "^${field}=" | cut -d= -f2- || true
}

# =============================================================================
# gather_promotion_context <branch> <out_file>
#
# Assembles a context document for the promotion PR composer and writes it to
# <out_file>.  Every sub-step is best-effort (|| true) — gathering must never
# hard-fail so that composer failure cannot block a promotion.
#
# Context sections (in order):
#   1. Ledger entries (integration_ledger_entries)
#   2. Per-entry: PR title/body, latest Findings: line, issue labels/body
#   3. Aggregate diff stats (git diff --stat origin/main...origin/<branch>)
#   4. Per-issue git show --stat + first ~120 patch lines (snipped diff examples)
#   5. Sync-conflict history from .rite/logs/*.log INTEGRATION_SYNC diag lines
#   6. Doc drift log verbatim when present (docs/sharkrite-drift-log.md)
#
# Context is hard-capped at _PROMOTION_CONTEXT_CAP_BYTES; patch snips are
# truncated first to stay within the cap.
# =============================================================================
gather_promotion_context() {
  local branch="$1"
  local out_file="$2"

  # Start fresh
  printf '' > "$out_file"

  # -------------------------------------------------------------------------
  # 1. Ledger entries
  # -------------------------------------------------------------------------
  local ledger_entries
  ledger_entries=$(integration_ledger_entries "$branch" 2>/dev/null || true)

  {
    printf '## Ledger entries (branch: %s)\n\n' "$branch"
    if [ -n "$ledger_entries" ]; then
      printf '%s\n' "$ledger_entries"
    else
      printf '(no ledger entries found)\n'
    fi
    printf '\n'
  } >> "$out_file"

  # -------------------------------------------------------------------------
  # 2. Per-entry: PR context and issue context
  # -------------------------------------------------------------------------
  {
    printf '## Per-issue context\n\n'
  } >> "$out_file"

  # Patch snips are collected separately so they can be truncated first
  local snips_file
  snips_file=$(mktemp)

  if [ -n "$ledger_entries" ]; then
    while IFS= read -r entry_line; do
      # Skip empty lines (e.g. trailing newline from ledger file)
      [ -n "$entry_line" ] || continue

      local issue_num pr_num entry_sha promoted
      issue_num=$(_parse_ledger_field "$entry_line" "issue" || true)
      pr_num=$(_parse_ledger_field "$entry_line" "pr" || true)
      entry_sha=$(_parse_ledger_field "$entry_line" "sha" || true)
      promoted=$(_parse_ledger_field "$entry_line" "promoted" || true)

      {
        printf '### Issue #%s (PR #%s, sha=%s, promoted=%s)\n\n' \
          "${issue_num:-?}" "${pr_num:-?}" "${entry_sha:-?}" "${promoted:-?}"
      } >> "$out_file"

      # PR title and body (best-effort)
      if [ -n "${pr_num:-}" ]; then
        local pr_json pr_title pr_body pr_state
        pr_json=$(gh_safe pr view "$pr_num" \
          --json title,body,state 2>/dev/null || true)
        if [ -n "$pr_json" ]; then
          pr_title=$(printf '%s' "$pr_json" | \
            grep -o '"title":"[^"]*"' | cut -d'"' -f4 || true)
          # Use jq when available for robust JSON extraction; fall back to grep
          if command -v jq >/dev/null 2>&1; then
            pr_body=$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null || true)
            pr_state=$(printf '%s' "$pr_json" | jq -r '.state // ""' 2>/dev/null || true)
          else
            pr_body=""
            pr_state=$(printf '%s' "$pr_json" | \
              grep -o '"state":"[^"]*"' | cut -d'"' -f4 || true)
          fi
          {
            printf '**PR title**: %s\n' "${pr_title:-<unavailable>}"
            printf '**PR state**: %s\n\n' "${pr_state:-<unavailable>}"
            if [ -n "${pr_body:-}" ]; then
              printf '**PR body** (first 60 lines):\n```\n'
              printf '%s' "$pr_body" | head -60 || true
              printf '\n```\n\n'
            fi
          } >> "$out_file"

          # Latest review Findings: line for this PR (best-effort)
          # Fetch the most recent sharkrite-local-review PR comment and extract
          # the "Findings: 🔴 CRITICAL: N | ..." summary line.
          local review_comment findings_line
          review_comment=$(gh_safe pr view "$pr_num" \
            --json comments \
            --jq '[.comments[] | select(.body | contains("<!-- sharkrite-local-review"))] | last | .body // ""' \
            2>/dev/null || true)
          if [ -n "${review_comment:-}" ]; then
            findings_line=$(printf '%s' "$review_comment" | \
              grep -E "CRITICAL: *[0-9]+.*HIGH: *[0-9]+.*MEDIUM: *[0-9]+.*LOW: *[0-9]+" | \
              head -1 || true)
            if [ -n "${findings_line:-}" ]; then
              {
                printf '**Review summary**: %s\n\n' "$findings_line"
              } >> "$out_file"
            fi
          fi
        fi
      fi

      # Issue labels and body for urgency depth signals (best-effort)
      if [ -n "${issue_num:-}" ]; then
        local issue_json issue_labels issue_body_short
        issue_json=$(gh_safe issue view "$issue_num" \
          --json labels,body 2>/dev/null || true)
        if [ -n "${issue_json:-}" ] && command -v jq >/dev/null 2>&1; then
          issue_labels=$(printf '%s' "$issue_json" | \
            jq -r '[.labels[].name] | join(", ")' 2>/dev/null || true)
          issue_body_short=$(printf '%s' "$issue_json" | \
            jq -r '.body // ""' 2>/dev/null | head -20 || true)
          {
            printf '**Issue labels**: %s\n' "${issue_labels:-<unavailable>}"
            if [ -n "${issue_body_short:-}" ]; then
              printf '**Issue body** (first 20 lines):\n```\n'
              printf '%s\n' "$issue_body_short"
              printf '```\n'
            fi
            printf '\n'
          } >> "$out_file"
        fi
      fi

      # Patch snip for this entry SHA (collected separately for cap-aware truncation)
      if [ -n "${entry_sha:-}" ]; then
        {
          printf '### Patch snip: sha=%s (issue #%s)\n' "$entry_sha" "${issue_num:-?}"
          git -C "${RITE_PROJECT_ROOT:-.}" show --stat "$entry_sha" 2>/dev/null || true
          printf '\n--- patch (first 120 lines) ---\n'
          git -C "${RITE_PROJECT_ROOT:-.}" show "$entry_sha" 2>/dev/null | head -120 || true
          printf '\n'
        } >> "$snips_file"
      fi

    done <<< "$ledger_entries"
  fi

  # -------------------------------------------------------------------------
  # 3. Aggregate diff stats
  # -------------------------------------------------------------------------
  {
    printf '## Aggregate diff stats (origin/main...origin/%s)\n\n' "$branch"
    # Fetch both refs best-effort; single ref per call per git-helpers.sh contract
    git_fetch_safe origin main 2>/dev/null || true
    git_fetch_safe origin "$branch" 2>/dev/null || true
    git -C "${RITE_PROJECT_ROOT:-.}" diff --stat "origin/main...origin/${branch}" 2>/dev/null || true
    printf '\n'
  } >> "$out_file"

  # -------------------------------------------------------------------------
  # 4. Append patch snips (truncated first if cap is approached)
  # -------------------------------------------------------------------------
  local current_size snips_size
  current_size=$(wc -c < "$out_file" 2>/dev/null || echo 0)
  snips_size=$(wc -c < "$snips_file" 2>/dev/null || echo 0)

  if [ "$((current_size + snips_size))" -le "$_PROMOTION_CONTEXT_CAP_BYTES" ]; then
    # Fits within cap — append all snips
    cat "$snips_file" >> "$out_file" || true
  else
    # Truncate snips to fit within the cap
    local available_bytes
    available_bytes=$(( _PROMOTION_CONTEXT_CAP_BYTES - current_size ))
    if [ "$available_bytes" -gt 0 ]; then
      {
        printf '## Patch snips (truncated to fit ~50 KB context cap)\n\n'
        head -c "$available_bytes" "$snips_file" 2>/dev/null || true
        printf '\n[... patch snips truncated at context cap ...]\n'
      } >> "$out_file" || true
    else
      printf '## Patch snips (omitted — context cap reached)\n\n' >> "$out_file" || true
    fi
  fi
  rm -f "$snips_file"

  # -------------------------------------------------------------------------
  # 5. Sync-conflict history from .rite/logs/*.log
  # -------------------------------------------------------------------------
  {
    printf '## Sync-conflict history\n\n'
    # The --sync command emits [diag] INTEGRATION_SYNC branch=<branch> ... lines.
    # Grep .rite/logs/*.log for lines matching this branch (best-effort).
    local log_dir="${RITE_LOG_DIR:-${RITE_STATE_DIR:+$(dirname "$RITE_STATE_DIR")/logs}}"
    local sync_lines=""
    if [ -n "${log_dir:-}" ] && [ -d "$log_dir" ]; then
      # Use a glob expansion; bash 3.2 compatible (no mapfile)
      local found_any=false
      for _log in "$log_dir"/*.log; do
        [ -f "$_log" ] || continue
        local _hits
        _hits=$(grep -E "INTEGRATION_SYNC branch=${branch}( |$)" "$_log" 2>/dev/null || true)
        if [ -n "$_hits" ]; then
          sync_lines="${sync_lines:+${sync_lines}
}${_hits}"
          found_any=true
        fi
      done
      if $found_any && [ -n "$sync_lines" ]; then
        printf '%s\n\n' "$sync_lines"
      else
        printf '(no sync-conflict records found for this branch)\n\n'
      fi
    else
      printf '(log directory not found — skipping sync history)\n\n'
    fi
  } >> "$out_file"

  # -------------------------------------------------------------------------
  # 6. Doc drift log (verbatim when present)
  # -------------------------------------------------------------------------
  local drift_log="${RITE_PROJECT_ROOT:-.}/docs/sharkrite-drift-log.md"
  if [ -f "$drift_log" ]; then
    {
      printf '## Known doc drift (docs/sharkrite-drift-log.md)\n\n'
      cat "$drift_log"
      printf '\n'
    } >> "$out_file"
  fi
}

# =============================================================================
# compose_promotion_pr_body <branch> <context_file>
#
# Emits the full promotion PR body on stdout.  User-facing messages go to
# stderr.  Returns 0 in both the LLM-success and fallback paths — a composer
# failure must NEVER block promotion.
#
# Steps:
#   1. Parse ledger entries from the context file (for depth signals + Closes tail)
#   2. Compute depth signals (diff lines, issue count, priority-high count,
#      sync-conflict count) and embed in prompt
#   3. Call provider_run_prompt_with_timeout on the promote role
#   4. Non-zero exit OR empty/whitespace-only output → print_warning + fallback
#   5. In both paths, append deterministic tail (## Constituent issues + drift)
# =============================================================================
compose_promotion_pr_body() {
  local branch="$1"
  local context_file="$2"

  # -------------------------------------------------------------------------
  # 1. Re-read the ledger entries (from integration-ledger.sh, not the context
  #    file, so the tail is always live and deterministic).
  # -------------------------------------------------------------------------
  local ledger_entries
  ledger_entries=$(integration_ledger_entries "$branch" 2>/dev/null || true)

  # Build the list of unpromoted entries for the Closes tail and depth signals.
  # "promoted=false" entries are in-flight; "promoted=true" were already
  # included in an earlier promotion cycle (excluded per #1050 criteria).
  local unpromoted_issues=""
  local unpromoted_count=0
  local priority_high_count=0

  if [ -n "$ledger_entries" ]; then
    while IFS= read -r _entry; do
      [ -n "$_entry" ] || continue
      local _promoted
      _promoted=$(_parse_ledger_field "$_entry" "promoted" || true)
      [ "${_promoted:-}" = "false" ] || continue

      local _inum _pnum _sha
      _inum=$(_parse_ledger_field "$_entry" "issue" || true)
      _pnum=$(_parse_ledger_field "$_entry" "pr" || true)
      _sha=$(_parse_ledger_field "$_entry" "sha" || true)

      # Fetch PR title for the Closes line (best-effort; fall back to bare identifiers)
      local _pr_title=""
      if [ -n "${_pnum:-}" ]; then
        _pr_title=$(gh_safe pr view "$_pnum" --json title \
          --jq '.title // ""' 2>/dev/null || true)
      fi

      # Short SHA (first 8 chars, portable)
      local _short_sha="${_sha:0:8}"

      # Build the closes line for this entry
      local _closes_line
      if [ -n "${_pr_title:-}" ]; then
        _closes_line="Closes #${_inum:-?} (PR #${_pnum:-?} \"${_pr_title}\", ${_short_sha:-?})"
      else
        _closes_line="Closes #${_inum:-?} (PR #${_pnum:-?}, ${_short_sha:-?})"
      fi

      unpromoted_issues="${unpromoted_issues:+${unpromoted_issues}
}${_closes_line}"
      unpromoted_count=$(( unpromoted_count + 1 ))

      # Count priority-high issues for depth signal.
      # The issue's section in the context file spans from its ### header to the
      # next ### header (or EOF).  Extract that section and check the
      # "**Issue labels**:" line — the -A 5 window is too short to reach it
      # because the PR-title/state/body block sits between the header and labels.
      local _section_labels=""
      _section_labels=$(awk "/^### Issue #${_inum} /{found=1; next} found && /^\*\*Issue labels\*\*:/{print; exit} found && /^### Issue #[0-9]+ /{exit}" "$context_file" 2>/dev/null || true)
      if printf '%s' "${_section_labels:-}" | grep -q "priority-high" 2>/dev/null; then
        priority_high_count=$(( priority_high_count + 1 ))
      fi
    done <<< "$ledger_entries"
  fi

  # -------------------------------------------------------------------------
  # 2. Compute aggregate diff depth signals
  # -------------------------------------------------------------------------
  local total_diff_lines=0
  total_diff_lines=$(git -C "${RITE_PROJECT_ROOT:-.}" diff --stat "origin/main...origin/${branch}" 2>/dev/null | \
    tail -1 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | \
    grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null || echo 0) || total_diff_lines=0

  local sync_conflict_count=0
  sync_conflict_count=$(grep -c "INTEGRATION_SYNC.*outcome=conflict" "$context_file" 2>/dev/null || true)
  sync_conflict_count="${sync_conflict_count:-0}"

  # -------------------------------------------------------------------------
  # 3. Build the LLM prompt
  # -------------------------------------------------------------------------
  local prompt_file
  prompt_file=$(mktemp)

  cat > "$prompt_file" << 'PROMPT_EOF'
You are composing a promotion PR body for a software engineering team. This PR
promotes an integration branch to main and serves as the human/management-facing
review artifact for the entire batch of work.

Write a plain-English narrative with:
- A brief executive summary (2-4 sentences)
- A "## Changes" section with per-issue subsections (one H3 per issue)
  Each subsection should: summarize the change, its purpose, and review findings
- A "## Risk and quality" section: overall risk level, test coverage notes,
  any critical/high findings from reviews

IMPORTANT constraints:
- Do NOT add a "## Constituent issues" section — the caller appends this
  deterministically. Do NOT add any "Closes #N" lines.
- Do NOT add a "## Known doc drift" section — the caller appends this if applicable.
- Calibrate narrative depth and urgency wording using these computed signals:
PROMPT_EOF

  # Inject the depth signals and context
  cat >> "$prompt_file" << SIGNALS_EOF

Depth signals:
  - Total diff lines (insertions + deletions): ${total_diff_lines}
  - Unpromoted issue count: ${unpromoted_count}
  - Priority-high issue count: ${priority_high_count}
  - Sync-conflict count: ${sync_conflict_count}

(Use these to scale narrative depth: more issues/lines → more detail per section;
more priority-high or sync conflicts → stronger urgency wording in the Risk section.)

--- BEGIN PROMOTION CONTEXT ---
SIGNALS_EOF

  cat "$context_file" >> "$prompt_file" 2>/dev/null || true
  printf '\n--- END PROMOTION CONTEXT ---\n' >> "$prompt_file"

  # -------------------------------------------------------------------------
  # 4. Call the LLM (promote role)
  # -------------------------------------------------------------------------
  local llm_output=""
  local llm_exit=0

  # provider_run_prompt_with_timeout signature: (prompt, model, auto_mode, timeout)
  llm_output=$(provider_run_prompt_with_timeout \
    "$(cat "$prompt_file")" \
    "$(provider_resolve_model promote)" \
    true \
    "${RITE_ASSESSMENT_TIMEOUT:-300}" \
    2>/dev/null) || llm_exit=$?

  rm -f "$prompt_file"

  # Treat empty/whitespace-only output the same as a non-zero exit
  local llm_stripped
  llm_stripped=$(printf '%s' "${llm_output:-}" | tr -d '[:space:]' || true)
  if [ "$llm_exit" -ne 0 ] || [ -z "${llm_stripped:-}" ]; then
    print_warning "Promotion composer: LLM call failed or returned empty output — using deterministic fallback." >&2
    # Emit deterministic fallback narrative
    _emit_fallback_body "$branch" "$unpromoted_issues" "$total_diff_lines"
  else
    # LLM succeeded — emit its narrative
    printf '%s\n' "$llm_output"
  fi

  # -------------------------------------------------------------------------
  # 5. Append deterministic tail (always, in both paths)
  #    The LLM never owns these sections — they are the load-bearing lines.
  # -------------------------------------------------------------------------
  printf '\n## Constituent issues\n\n'
  if [ -n "$unpromoted_issues" ]; then
    printf '%s\n' "$unpromoted_issues"
  else
    printf '(no unpromoted ledger entries found)\n'
  fi
  printf '\n'

  # Drift log section (deterministic — verbatim from file when present)
  local drift_log="${RITE_PROJECT_ROOT:-.}/docs/sharkrite-drift-log.md"
  if [ -f "$drift_log" ]; then
    printf '## Known doc drift\n\n'
    cat "$drift_log" 2>/dev/null || true
    printf '\n'
  fi

  return 0
}

# =============================================================================
# _emit_fallback_body <branch> <unpromoted_issues> <total_diff_lines>
#
# Emits the deterministic fallback PR body to stdout when the LLM call fails.
# Per-issue lines, aggregate diff stat, and a one-line sync summary.
# =============================================================================
_emit_fallback_body() {
  local branch="$1"
  local unpromoted_issues="$2"
  local total_diff_lines="${3:-0}"

  printf "# Promotion of integration branch '%s' to main\n\n" "$branch"
  printf 'This promotion PR was generated using the deterministic fallback template\n'
  printf '(LLM narrative composition was unavailable or returned empty output).\n\n'

  printf '## Summary\n\n'
  printf 'Promotes integration branch `%s` to `main`.\n\n' "$branch"

  printf '## Changes\n\n'
  if [ -n "$unpromoted_issues" ]; then
    while IFS= read -r _line; do
      printf '- %s\n' "$_line"
    done <<< "$unpromoted_issues"
  else
    printf '(no unpromoted ledger entries found)\n'
  fi
  printf '\n'

  printf '## Diff summary\n\n'
  printf 'Total lines changed (insertions + deletions): %s\n\n' "$total_diff_lines"

  printf '## Aggregate diff stats\n\n'
  printf '```\n'
  git -C "${RITE_PROJECT_ROOT:-.}" diff --stat "origin/main...origin/${branch}" 2>/dev/null || true
  printf '```\n\n'

  printf '## Sync history\n\n'
  local sync_count=0
  local log_dir="${RITE_LOG_DIR:-${RITE_STATE_DIR:+$(dirname "$RITE_STATE_DIR")/logs}}"
  if [ -n "${log_dir:-}" ] && [ -d "$log_dir" ]; then
    for _log in "$log_dir"/*.log; do
      [ -f "$_log" ] || continue
      local _n
      _n=$(grep -cE "INTEGRATION_SYNC branch=${branch}( |$)" "$_log" 2>/dev/null || true)
      sync_count=$(( sync_count + ${_n:-0} ))
    done
  fi
  if [ "$sync_count" -gt 0 ]; then
    printf '%s sync event(s) recorded for this branch.\n\n' "$sync_count"
  else
    printf 'No sync events recorded for this branch.\n\n'
  fi
}
