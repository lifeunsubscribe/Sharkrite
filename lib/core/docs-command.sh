#!/bin/bash
# lib/core/docs-command.sh
#
# rite docs [instructions] — circumstantial dispatch entry point for cluster-B
# doc features (consent, drift audit/reconcile, directed updates).
#
# Dispatches based on effective documentation state:
#   never-run   → consent/enable flow (unset or off: ask, record sync|off)
#   run-before  → drift audit (report potential inaccuracies vs current code)
#   input given → directed-update seam (engine lands with #1049)
#
# Public API:
#   rite_docs [instructions]       — main entry point; called by bin/rite
#   docs_directed_update           — directed-update engine entry point

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing).
# Sentinel: rite_docs — stable, defined only by this file.
if declare -f rite_docs >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Bootstrap: ensure RITE_LIB_DIR is available.
# In production, config.sh is always loaded first; the guard here makes this
# file sourceable standalone (e.g. during the re-source safety regression test).
# ---------------------------------------------------------------------------
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _DOCS_CMD_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_DOCS_CMD_SELF_DIR/../utils/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"
source "$RITE_LIB_DIR/utils/logging.sh"
source "$RITE_LIB_DIR/utils/docs-map.sh"
source "$RITE_LIB_DIR/utils/doc-consent.sh"
source "$RITE_LIB_DIR/utils/drift-log.sh"
source "$RITE_LIB_DIR/utils/markers.sh"
source "$RITE_LIB_DIR/utils/gh-retry.sh"
source "$RITE_LIB_DIR/providers/provider-interface.sh"
# load_provider must run at top level (not inside $()) — see behavioral-design.md
load_provider "${RITE_REVIEW_PROVIDER:-claude}"

# ---------------------------------------------------------------------------
# _docs_resolve_state
#
# Determine effective doc state from RITE_DOC_MODE alone. (It used to key on
# .rite/doc-sync.md, the switch for the per-merge doc-sync rewrite retired
# 2026-10-21; a leftover file is now ignored.)
#
# Echoes one of: "never-run" (unset or off — ask again), "sync", "changelog"
# ---------------------------------------------------------------------------
_docs_resolve_state() {
  case "${RITE_DOC_MODE:-}" in
    sync)      echo "sync" ;;
    changelog) echo "changelog" ;;
    *)         echo "never-run" ;;
  esac
}

# ---------------------------------------------------------------------------
# _docs_ensure_map
#
# Ensure docs/docs-map.tsv exists, respecting RITE_DOCS_MAP_AUTO.
# When auto-rebuild is disabled and the map is missing, prompt interactively
# (default-no, non-TTY takes the "no" branch — never hangs).
#
# Returns: 0 on success, 1 when map is missing and user declined rebuild.
# ---------------------------------------------------------------------------
_docs_ensure_map() {
  local map_file
  map_file="$(docs_map_path)"

  if [ -f "$map_file" ]; then
    return 0
  fi

  local auto_enabled="${RITE_DOCS_MAP_AUTO:-true}"
  if [ "$auto_enabled" = "false" ] || [ "$auto_enabled" = "0" ]; then
    local reply_val="N"
    if [ -t 0 ]; then
      echo "" >&2
      read -p "  Docs map missing and auto-rebuild disabled — rebuild now? [y/N] " -n 1 -r
      echo
      reply_val="${REPLY:-N}"
    fi
    if [[ "$reply_val" =~ ^[Yy]$ ]]; then
      docs_map_build
      return 0
    fi
    print_warning "Docs map missing. To rebuild: RITE_DOCS_MAP_AUTO=true rite docs"
    echo "  Or set RITE_DOCS_MAP_AUTO=true in .rite/config" >&2
    return 1
  fi

  # Auto-rebuild enabled: silent rebuild
  docs_map_build
}

# ---------------------------------------------------------------------------
# _docs_burn_drift_entries DRIFT_PATH PR_REFS_SPACE_SEP
#
# Remove drift log entries matching the given space-separated "pr:N" refs.
# Rewrites the file in-place. Deletes the file when no entries remain.
# No-op when the file is absent or pr_refs is empty / "none".
# ---------------------------------------------------------------------------
_docs_burn_drift_entries() {
  local _bd_path="${1:-}"
  local _bd_refs="${2:-}"

  [ -f "$_bd_path" ] || return 0
  [ -n "$_bd_refs" ] || return 0
  [ "$_bd_refs" = "none" ] && return 0

  # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_DOC_DRIFT is an internal marker constant (defined in markers.sh), not a user config var; _RITE_ prefix cannot be used as RITE_MARKER_* is the canonical convention for all marker constants; ledger is frozen per 2026-07-14 rule
  local _bd_marker="$RITE_MARKER_DOC_DRIFT"
  local _bd_tmp
  _bd_tmp="$(mktemp)"
  local _bd_skip=0
  local _bd_line

  while IFS= read -r _bd_line || [ -n "$_bd_line" ]; do
    case "$_bd_line" in
      "<!-- ${_bd_marker} pr:"*)
        # Extract pr:N and check if it is in the removal list
        local _bd_entry_pr
        _bd_entry_pr="$(printf '%s' "$_bd_line" | grep -oE 'pr:[0-9]+' | head -1 || true)"
        # Match whole token: pad refs with spaces for reliable grep -F
        if printf ' %s ' "$_bd_refs" | grep -qF " ${_bd_entry_pr} " 2>/dev/null; then
          _bd_skip=1
          continue
        fi
        ;;
      "<!-- /${_bd_marker} -->")
        if [ "$_bd_skip" = "1" ]; then
          _bd_skip=0
          continue
        fi
        ;;
    esac
    [ "$_bd_skip" = "0" ] && printf '%s\n' "$_bd_line" >> "$_bd_tmp"
  done < "$_bd_path"

  mv "$_bd_tmp" "$_bd_path"

  # Delete the log when all entries have drained
  local _bd_remaining
  _bd_remaining="$(drift_log_entry_count "$_bd_path" || echo "0")"
  if [ "$_bd_remaining" -eq 0 ]; then
    rm -f "$_bd_path"
  fi
}

# ---------------------------------------------------------------------------
# _docs_apply_approved APPROVED_DIR DRIFT_PATH INSTRUCTIONS MODE TARGET_BRANCH [SKIP_BURNDOWN] [ENTRY_FILE]
#
# Apply every approved proposal (files in APPROVED_DIR) inside a temporary
# worktree forked from origin/${TARGET_BRANCH:-main}, burn down covered drift
# entries in the same commit, push the docs branch, and open a docs PR.
# The PR is NOT auto-merged — it goes through normal human review.
#
# SKIP_BURNDOWN (6th arg, default false): pass "true" to suppress legacy
# flat-log burn-down (used by _docs_main_entries_pass whose scope boundary
# explicitly forbids legacy entry removal).
#
# ENTRY_FILE (7th arg, optional): path to a structured drift entry TSV file
# (RITE_STATE_DIR/doc-drift/<branch>/<slug>.log).  When provided:
#   - All entries in the file are folded into the PR body as a readable block
#     (the permanent record of why the doc changed).
#   - Entries are removed from the store only after gh pr create succeeds;
#     a failed PR creation leaves the file intact.
#
# Consent-gate rationale: this function is reached ONLY after explicit human
# approval in the preview loop — explicit command + preview approval IS consent.
# The Layer 2 gate (assess-documentation.sh) governs autonomous writes only.
# ---------------------------------------------------------------------------
_docs_apply_approved() {
  local _aa_dir="${1:-}"
  local _aa_drift_path="${2:-}"  # unused; kept for interface compat with _docs_update_engine caller
  local _aa_instructions="${3:-}"
  local _aa_mode="${4:-directed}"
  local _aa_target="${5:-${RITE_TARGET_BRANCH:-main}}"
  local _aa_skip_burndown="${6:-false}"
  local _aa_entry_file="${7:-}"

  # Count approved proposals
  local _aa_count=0
  if [ -d "$_aa_dir" ]; then
    _aa_count="$(find "$_aa_dir" -name 'approved_*.txt' -type f 2>/dev/null | wc -l | tr -d ' ' || true)"
  fi
  if [ "$_aa_count" -eq 0 ]; then
    print_info "No approved proposals to apply"
    return 0
  fi

  # Read the structured entry file snapshot BEFORE any worktree/git operations.
  # Used for PR body folding and post-PR-create removal.  Read once so the
  # removal loop iterates the same content even if the file is partially written
  # by a concurrent process between fold and remove.
  local _aa_entries_snapshot=""
  if [ -n "$_aa_entry_file" ] && [ -f "$_aa_entry_file" ]; then
    _aa_entries_snapshot="$(cat "$_aa_entry_file" 2>/dev/null || true)"
  fi

  # Build the folded entries markdown block for the PR body.
  local _aa_folded_block=""
  if [ -n "$_aa_entries_snapshot" ]; then
    local _aa_fold_lines=""
    local _aa_el
    while IFS= read -r _aa_el || [ -n "$_aa_el" ]; do
      [ -n "$_aa_el" ] || continue
      local _aa_e_doc _aa_e_assertion _aa_e_kind _aa_e_pr _aa_e_evidence
      _aa_e_doc="$(printf '%s' "$_aa_el" | awk -F'\t' \
        '{for(i=1;i<=NF;i++){if(substr($i,1,4)=="doc="){print substr($i,5);exit}}}' || true)"
      _aa_e_assertion="$(printf '%s' "$_aa_el" | awk -F'\t' \
        '{for(i=1;i<=NF;i++){if(substr($i,1,10)=="assertion="){print substr($i,11);exit}}}' || true)"
      _aa_e_kind="$(printf '%s' "$_aa_el" | awk -F'\t' \
        '{for(i=1;i<=NF;i++){if(substr($i,1,5)=="kind="){print substr($i,6);exit}}}' || true)"
      _aa_e_pr="$(printf '%s' "$_aa_el" | awk -F'\t' \
        '{for(i=1;i<=NF;i++){if(substr($i,1,3)=="pr="){print substr($i,4);exit}}}' || true)"
      _aa_e_evidence="$(printf '%s' "$_aa_el" | awk -F'\t' \
        '{for(i=1;i<=NF;i++){if(substr($i,1,9)=="evidence="){print substr($i,10);exit}}}' || true)"
      [ -n "$_aa_e_doc" ] || continue
      _aa_fold_lines="${_aa_fold_lines}- **${_aa_e_doc}** — \"${_aa_e_assertion}\" _(${_aa_e_kind})_
  PRs: ${_aa_e_pr} | Evidence: \`${_aa_e_evidence}\`
"
    done <<FOLD_EOF
$_aa_entries_snapshot
FOLD_EOF
    if [ -n "$_aa_fold_lines" ]; then
      _aa_folded_block="
**Drift entries consumed by this PR:**

${_aa_fold_lines}"
    fi
  fi

  # Build docs branch name (unique: PID + seconds)
  local _aa_ts
  _aa_ts="$(date -u +%Y%m%d%H%M%S)"
  local _aa_branch="docs/${_aa_mode}-${_aa_ts}"
  local _aa_wt_path="${TMPDIR:-/tmp}/rite_docs_wt_${$}_${_aa_ts}"

  # Fetch best-effort (network call, non-fatal)
  git -C "$RITE_PROJECT_ROOT" fetch origin "$_aa_target" 2>/dev/null || true

  # Create worktree forked from origin/$_aa_target
  if ! git -C "$RITE_PROJECT_ROOT" worktree add \
    "$_aa_wt_path" -b "$_aa_branch" \
    "origin/${_aa_target}" 2>/dev/null; then
    print_warning "Could not create docs worktree on 'origin/${_aa_target}' — check that the branch exists and has been fetched" >&2
    return 1
  fi

  # Apply each approved proposal to the worktree
  local _aa_all_drift_refs=""
  local _aa_pf
  for _aa_pf in "${_aa_dir}"/approved_*.txt; do
    [ -f "$_aa_pf" ] || continue

    local _aa_action="" _aa_file="" _aa_drift="" _aa_content=""
    local _aa_in_content=0
    local _aa_ln

    while IFS= read -r _aa_ln || [ -n "$_aa_ln" ]; do
      if [ "$_aa_in_content" = "1" ]; then
        _aa_content="${_aa_content}${_aa_ln}"$'\n'
      else
        case "$_aa_ln" in
          "ACTION: "*)     _aa_action="${_aa_ln#ACTION: }" ;;
          "FILE: "*)       _aa_file="${_aa_ln#FILE: }" ;;
          "DRIFT_REFS: "*) _aa_drift="${_aa_ln#DRIFT_REFS: }" ;;
          "---CONTENT---") _aa_in_content=1 ;;
        esac
      fi
    done < "$_aa_pf"

    [ -n "$_aa_file" ] || continue
    # Reject absolute paths and directory traversal to prevent writes outside the worktree
    # shellcheck disable=SC2221,SC2222
    # SC2221/2222: patterns are distinct — *../* matches mid-traversal (foo/../bar),
    # */.. matches end-traversal (foo/..) which has no / after .. and is not covered by *../*
    case "$_aa_file" in
      /*|*../*|*/..|../*|..)
        print_warning "Rejected proposal: unsafe FILE path '$_aa_file'" >&2
        continue
        ;;
    esac

    local _aa_target_file="${_aa_wt_path}/${_aa_file}"

    # Apply-site TOCTOU guard: refuse CREATE when the file already exists in
    # the worktree (i.e. it was present on origin at the fetch above).
    # Mirrors the preview-time guard in _docs_update_engine (lines 646-654).
    if [ "$_aa_action" = "CREATE" ] && [ -f "$_aa_target_file" ]; then
      print_warning "Skipping CREATE for '${_aa_file}': file already exists in worktree — use ACTION: EDIT to update an existing file" >&2
      continue
    fi

    mkdir -p "$(dirname "$_aa_target_file")"
    # Strip trailing newline added by the accumulation loop (printf is idempotent)
    printf '%s' "$_aa_content" > "$_aa_target_file"

    # Accumulate drift refs (strip "none")
    if [ -n "$_aa_drift" ] && [ "$_aa_drift" != "none" ]; then
      _aa_all_drift_refs="${_aa_all_drift_refs} ${_aa_drift}"
    fi
  done

  # Burn down drift entries in the worktree's copy of the drift log.
  # drift_log_path is called from within the worktree cwd so git rev-parse
  # --show-toplevel returns the worktree root, not the main checkout root.
  # Skipped when _aa_skip_burndown=true (e.g. _docs_main_entries_pass, whose
  # scope boundary explicitly forbids removing legacy flat-log entries).
  if [ -n "$_aa_all_drift_refs" ] && [ "$_aa_skip_burndown" != "true" ]; then
    local _aa_wt_drift
    _aa_wt_drift="$(cd "$_aa_wt_path" && drift_log_path 2>/dev/null || true)"
    if [ -n "$_aa_wt_drift" ] && [ -f "$_aa_wt_drift" ]; then
      _docs_burn_drift_entries "$_aa_wt_drift" "$_aa_all_drift_refs"
    fi
  fi

  # Stage proposals first (without the map), then check for meaningful changes.
  # Rebuilding the map before this check causes a spurious docs PR on no-op runs
  # because the header's built=<timestamp> changes every invocation.
  git -C "$_aa_wt_path" add . 2>/dev/null || true

  if git -C "$_aa_wt_path" diff --cached --quiet 2>/dev/null; then
    print_warning "Nothing staged in docs worktree — no changes to commit"
    git -C "$RITE_PROJECT_ROOT" worktree remove "$_aa_wt_path" --force 2>/dev/null || true
    return 0
  fi

  # Rebuild the docs map in the worktree so the PR includes the updated
  # navigation index alongside the doc content changes.
  # docs_map_build is deterministic (zero provider calls).
  ( export RITE_PROJECT_ROOT="$_aa_wt_path"; unset RITE_STATE_DIR 2>/dev/null || true
    docs_map_build ) || true
  git -C "$_aa_wt_path" add docs/docs-map.tsv 2>/dev/null || true

  # Commit message (72-char cap)
  local _aa_commit_msg
  if [ "$_aa_mode" = "directed" ]; then
    _aa_commit_msg="docs: ${_aa_instructions:-directed update}"
  else
    _aa_commit_msg="docs: reconcile drift backlog"
  fi
  _aa_commit_msg="$(printf '%s' "$_aa_commit_msg" | cut -c1-72)"

  local _aa_commit_err="" _aa_commit_rc=0
  _aa_commit_err="$(git -C "$_aa_wt_path" commit -m "$_aa_commit_msg" 2>&1)" || _aa_commit_rc=$?
  if [ "$_aa_commit_rc" -ne 0 ]; then
    print_warning "Docs commit failed (exit ${_aa_commit_rc}): ${_aa_commit_err}" >&2
    git -C "$RITE_PROJECT_ROOT" worktree remove "$_aa_wt_path" --force 2>/dev/null || true
    git -C "$RITE_PROJECT_ROOT" worktree prune 2>/dev/null || true
    git -C "$RITE_PROJECT_ROOT" branch -D "$_aa_branch" 2>/dev/null || true
    return 1
  fi

  # Push docs branch
  local _aa_push_rc=0
  git -C "$_aa_wt_path" push origin "$_aa_branch" 2>&1 || \
    { git -C "$RITE_PROJECT_ROOT" push origin "$_aa_branch" 2>&1 || _aa_push_rc=$?; }
  if [ "$_aa_push_rc" -ne 0 ]; then
    print_warning "Push failed (exit ${_aa_push_rc}) — branch '${_aa_branch}' exists locally only" >&2
    print_warning "  To push manually: git push origin '${_aa_branch}'" >&2
    git -C "$RITE_PROJECT_ROOT" worktree remove "$_aa_wt_path" --force 2>/dev/null || true
    git -C "$RITE_PROJECT_ROOT" worktree prune 2>/dev/null || true
    return 1
  fi

  # PR title (70-char cap)
  local _aa_pr_title
  if [ "$_aa_mode" = "directed" ]; then
    _aa_pr_title="docs: ${_aa_instructions:-directed update}"
  else
    _aa_pr_title="docs: reconcile drift backlog"
  fi
  _aa_pr_title="$(printf '%s' "$_aa_pr_title" | cut -c1-70)"

  local _aa_pr_body
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: branch, mode, instruction, and folded-entries vars must expand
  _aa_pr_body="$(cat <<PR_BODY_EOF
## Docs update

**Mode**: ${_aa_mode}
**Instructions**: ${_aa_instructions:-reconcile drift backlog}
**Base branch**: \`${_aa_target}\`

This PR was created by \`rite docs\`. Review and merge when ready.
**No auto-merge** — this PR requires human review before merging.

${_aa_all_drift_refs:+**Drift entries addressed**:${_aa_all_drift_refs}}
${_aa_folded_block}
PR_BODY_EOF
)"

  echo "" >&2
  print_info "Creating docs PR targeting '${_aa_target}'..."

  # gh_safe must be called from within the worktree so gh can detect the repo remote.
  # Capture the exit code: structured entries are removed only on success (#1432).
  local _aa_pr_rc=0
  ( cd "$_aa_wt_path" && gh_safe pr create \
    --base "${_aa_target}" \
    --title "$_aa_pr_title" \
    --body "$_aa_pr_body" ) || _aa_pr_rc=$?

  if [ "$_aa_pr_rc" -ne 0 ]; then
    print_warning "PR creation failed — branch '${_aa_branch}' was pushed; create PR manually" >&2
  fi

  # Remove worktree; branch remains for the open PR
  git -C "$RITE_PROJECT_ROOT" worktree remove "$_aa_wt_path" --force 2>/dev/null || true
  git -C "$RITE_PROJECT_ROOT" worktree prune 2>/dev/null || true

  # Remove consumed structured entries only after PR creation succeeded.
  # Iterates the pre-read snapshot so file modifications during removal do not
  # affect the loop.  Scoped to exact (doc, branch, assertion) keys — no glob.
  if [ "$_aa_pr_rc" -eq 0 ] && [ -n "$_aa_entries_snapshot" ]; then
    local _aa_rl
    while IFS= read -r _aa_rl || [ -n "$_aa_rl" ]; do
      [ -n "$_aa_rl" ] || continue
      local _aa_r_doc _aa_r_branch _aa_r_assertion
      _aa_r_doc="$(printf '%s' "$_aa_rl" | awk -F'\t' \
        '{for(i=1;i<=NF;i++){if(substr($i,1,4)=="doc="){print substr($i,5);exit}}}' || true)"
      _aa_r_branch="$(printf '%s' "$_aa_rl" | awk -F'\t' \
        '{for(i=1;i<=NF;i++){if(substr($i,1,7)=="branch="){print substr($i,8);exit}}}' || true)"
      _aa_r_assertion="$(printf '%s' "$_aa_rl" | awk -F'\t' \
        '{for(i=1;i<=NF;i++){if(substr($i,1,10)=="assertion="){print substr($i,11);exit}}}' || true)"
      [ -n "$_aa_r_doc" ] || continue
      drift_log_remove_entry "$_aa_r_doc" "${_aa_r_branch:-main}" "$_aa_r_assertion" || true
    done <<REMOVE_EOF
$_aa_entries_snapshot
REMOVE_EOF
  fi

  if [ "$_aa_pr_rc" -eq 0 ]; then
    print_success "Docs PR created on base '${_aa_target}' — review and merge when ready"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _docs_proposal_guards OLD_BYTES NEW_BYTES CONTENT DESCRIPTION GROWTH_THRESHOLD COMMITTER_NAMES
#
# Computed preview guards for every doc-proposal preview:
#   1. Length-neutrality: display old/new/delta; flag growth > threshold.
#   2. Shipped-product-only: highlight date patterns and committer names.
#
# Never auto-rejects. Output is informational only (all writes to stderr).
# Guard 1 threshold: RITE_DOC_GROWTH_WARN_PCT (default 15%).
# Guard 2 committer names: space-separated string of names (min 3 chars each).
# ---------------------------------------------------------------------------
_docs_proposal_guards() {
  local _pg_old_bytes="${1:-0}"
  local _pg_new_bytes="${2:-0}"
  local _pg_content="${3:-}"
  local _pg_desc="${4:-}"
  local _pg_threshold="${5:-15}"
  local _pg_committer_names="${6:-}"

  # ── Guard 1: length-neutrality ──────────────────────────────────────────
  if [ "$_pg_old_bytes" -gt 0 ]; then
    local _pg_delta=$(( _pg_new_bytes - _pg_old_bytes ))
    # Percentage growth (integer; truncates toward zero; negative = shrinkage)
    local _pg_pct=$(( (_pg_delta * 100) / _pg_old_bytes ))
    if [ "$_pg_delta" -ge 0 ]; then
      printf '  Size: %d → %d bytes (+%d bytes, +%d%%)\n' \
        "$_pg_old_bytes" "$_pg_new_bytes" "$_pg_delta" "$_pg_pct" >&2
    else
      local _pg_abs_delta=$(( -_pg_delta ))
      printf '  Size: %d → %d bytes (-%d bytes, %d%%)\n' \
        "$_pg_old_bytes" "$_pg_new_bytes" "$_pg_abs_delta" "$_pg_pct" >&2
    fi
    if [ "$_pg_delta" -gt 0 ] && [ "$_pg_pct" -gt "$_pg_threshold" ] && [ -z "$_pg_desc" ]; then
      printf '  [FLAG] Growth +%d%% exceeds %d%% threshold — no DESCRIPTION: line found; add one to explain the growth\n' \
        "$_pg_pct" "$_pg_threshold" >&2
    fi
  else
    printf '  Size: new file, %d bytes\n' "$_pg_new_bytes" >&2
  fi

  # ── Guard 2: shipped-product-only — date patterns ───────────────────────
  local _pg_date_hits=""
  _pg_date_hits="$(printf '%s' "$_pg_content" \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}|(January|February|March|April|May|June|July|August|September|October|November|December) [0-9]{4}|[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}' \
    | sort -u || true)"
  if [ -n "$_pg_date_hits" ]; then
    printf '  [FLAG] Date patterns in proposed text (verify these are not implementation-specific):\n' >&2
    printf '%s\n' "$_pg_date_hits" | sed 's/^/    /' >&2
  fi

  # ── Guard 2: shipped-product-only — committer names ─────────────────────
  if [ -n "$_pg_committer_names" ] && [ -n "$_pg_content" ]; then
    local _pg_name_hits=""
    local _pg_name
    while IFS= read -r _pg_name || [ -n "$_pg_name" ]; do
      [ -n "$_pg_name" ] || continue
      if printf '%s' "$_pg_content" | grep -qF "$_pg_name" 2>/dev/null; then
        _pg_name_hits="${_pg_name_hits}${_pg_name}"$'\n'
      fi
    done <<NAMES_EOF
$_pg_committer_names
NAMES_EOF
    if [ -n "$_pg_name_hits" ]; then
      printf '  [FLAG] Committer names in proposed text (verify these belong in shipped docs):\n' >&2
      printf '%s' "$_pg_name_hits" | sed 's/^/    /' >&2
    fi
  fi
}

# ---------------------------------------------------------------------------
# _docs_update_engine MODE INSTRUCTIONS
#
# Core directed-update / reconcile engine.
#
# Workflow:
#   1. Load docs map + relevant doc contents + drift log for LLM context.
#   2. Call LLM (doc_assessment role) to generate structured proposals.
#   3. Per-proposal preview → approve / skip / feedback loop.
#   4. On feedback: accumulate, regenerate proposals (up to 5 attempts).
#   5. On all-approved/skipped: apply approved changes in a temporary worktree
#      forked from origin/${RITE_TARGET_BRANCH:-main}, burn down covered drift
#      entries in the same commit, create docs PR (no auto-merge).
#
# Consent-gate rationale: the Layer 2 gate (assess-documentation.sh:1960) governs
# AUTONOMOUS doc writes. An explicitly commanded, previewed, human-approved update
# IS consent — the engine deliberately does NOT check the gate before an
# approved apply. Both sync and changelog consent modes are intentionally supported.
#
# Arguments:
#   $1  mode          — "directed" or "reconcile"
#   $2  instructions  — user-provided instruction string (empty for reconcile)
# ---------------------------------------------------------------------------
_docs_update_engine() {
  local _ue_mode="${1:-directed}"
  local _ue_instr="${2:-}"
  local _ue_target="${RITE_TARGET_BRANCH:-main}"
  local _ue_timeout="${RITE_DOC_ASSESSMENT_TIMEOUT:-300}"

  # DOC_PASS diag tracking.
  local _ue_llm_elapsed_s=0 _ue_input_bytes=0 _ue_had_feedback=0
  local _ue_call_start _ue_call_end

  # ---- Input assembly ----

  # Docs map
  local _ue_map_file
  _ue_map_file="$(docs_map_path)"
  local _ue_map_content=""

  # Current doc file content excerpts (for EDIT context, capped at 15KB total)
  local _ue_doc_ctx="" _ue_ctx_files="" _ue_doc_bytes=0 _ue_doc_cap=15000
  local _ue_skipped_cap_files=""
  if [ -f "$_ue_map_file" ]; then
    local _ue_ml
    while IFS= read -r _ue_ml || [ -n "$_ue_ml" ]; do
      case "$_ue_ml" in '#'*) continue ;; esac
      local _ue_fp
      _ue_fp="$(printf '%s' "$_ue_ml" | cut -f1 || true)"
      [ -z "$_ue_fp" ] && continue
      local _ue_abs="${RITE_PROJECT_ROOT}/${_ue_fp}"
      [ -f "$_ue_abs" ] || continue
      # Skip duplicate paths already in context
      case $'\n'"$_ue_doc_ctx" in *$'\n'"--- ${_ue_fp} ---"*) continue ;; esac
      local _ue_excerpt
      _ue_excerpt="$(head -c 2000 "$_ue_abs" 2>/dev/null || true)"
      local _ue_entry="--- ${_ue_fp} ---
${_ue_excerpt}

"
      if [ $((_ue_doc_bytes + ${#_ue_entry})) -gt "$_ue_doc_cap" ]; then
        _ue_skipped_cap_files="${_ue_skipped_cap_files}  ${_ue_fp}"$'\n'
        continue
      fi
      _ue_doc_bytes=$((_ue_doc_bytes + ${#_ue_entry}))
      _ue_doc_ctx="${_ue_doc_ctx}${_ue_entry}"
      _ue_ctx_files="${_ue_ctx_files}${_ue_fp}"$'\n'
    done < "$_ue_map_file"
  fi
  # Advertise only files that entered context so the model doesn't propose
  # EDIT for cap-skipped or map-absent paths.
  _ue_map_content="$_ue_ctx_files"

  # Warn deterministically when docs were excluded by the budget cap — the model
  # won't propose EDITs for them (they're not in the advertised list), so the user
  # needs this information now rather than discovering it via a silent no-op run.
  if [ -n "$_ue_skipped_cap_files" ]; then
    print_warning "Some docs were excluded by the 15KB context budget and are not visible to the model:" >&2
    printf '%s' "$_ue_skipped_cap_files" >&2
    print_warning "To update these docs, narrow your instruction to target them specifically, or split into separate runs." >&2
  fi

  # Drift log content
  local _ue_drift_path
  _ue_drift_path="$(drift_log_path 2>/dev/null || true)"
  local _ue_drift_content=""
  if [ -n "$_ue_drift_path" ] && [ -f "$_ue_drift_path" ]; then
    _ue_drift_content="$(cat "$_ue_drift_path" 2>/dev/null || true)"
  fi

  # Fetch origin/<target> so the CREATE guard's git cat-file check reflects the
  # current remote state, not a potentially stale local tracking ref.
  git -C "$RITE_PROJECT_ROOT" fetch origin "$_ue_target" 2>/dev/null || {
    print_warning "Could not fetch origin/${_ue_target} — CREATE guard may miss files pushed since last fetch" >&2
  }

  # Cache committer names once per engine invocation for the shipped-product guard.
  # Filtered to names >= 3 chars to reduce false positives on short tokens.
  local _ue_committer_names=""
  _ue_committer_names="$(git -C "$RITE_PROJECT_ROOT" log --format='%an' 2>/dev/null \
    | sort -u | awk 'length >= 3' || true)"
  local _ue_growth_threshold="${RITE_DOC_GROWTH_WARN_PCT:-15}"
  case "$_ue_growth_threshold" in
    *[!0-9]*|"")
      printf 'Notice: RITE_DOC_GROWTH_WARN_PCT="%s" is not a valid integer — using default 15\n' \
        "$_ue_growth_threshold" >&2
      _ue_growth_threshold=15 ;;
  esac

  local _ue_accum_fb=""
  local _ue_attempt=0
  # Per-generation unique end token prevents content containing ---END--- from
  # being mistaken for the proposal delimiter (issue #1233).
  local _ue_end_token="---END-${RANDOM}${RANDOM}---"

  while [ "$_ue_attempt" -lt 5 ]; do
    _ue_attempt=$((_ue_attempt + 1))

    # ---- Build LLM prompt ----
    local _ue_task_line
    if [ "$_ue_mode" = "directed" ]; then
      _ue_task_line="Task: ${_ue_instr}"
    else
      _ue_task_line="Task: Review the drift log entries below and propose documentation updates to address each one."
    fi

    local _ue_fb_section=""
    if [ -n "$_ue_accum_fb" ]; then
      _ue_fb_section="
Feedback from previous proposal round — incorporate in new proposals:
${_ue_accum_fb}
"
    fi

    local _ue_prompt_file
    _ue_prompt_file="$(mktemp)"
    # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: task, context, and feedback section vars must expand
    cat > "$_ue_prompt_file" <<DOC_UPDATE_EOF
You are a documentation writer for a software project.

${_ue_task_line}
${_ue_fb_section}
Documentation files in model context (EDIT proposals must target only these paths):
${_ue_map_content}

Current file contents (excerpts, for EDIT proposals):
${_ue_doc_ctx}

Drift log (sections that may be inaccurate after recent code changes):
${_ue_drift_content}

Output proposals in EXACTLY this format — no text outside the delimiters:

For a file to EDIT (output FULL new content of the file):
---PROPOSAL---
ACTION: EDIT
FILE: <project-relative path, e.g. docs/foo.md>
DRIFT_REFS: <space-separated pr:N entries from drift log this change addresses, or "none">
DESCRIPTION: <one-line summary of what changes and why>
---CONTENT---
<complete new content of the file>
${_ue_end_token}

For a NEW file to CREATE:
---PROPOSAL---
ACTION: CREATE
FILE: <project-relative path for the new file, e.g. docs/adr-042-caching.md>
DRIFT_REFS: none
DESCRIPTION: <one-line summary>
---CONTENT---
<complete content of the new file>
${_ue_end_token}

If no changes are needed, output only the line: NO_PROPOSALS_NEEDED
DOC_UPDATE_EOF

    print_info "Generating doc proposals (attempt ${_ue_attempt}/5)..."

    # Measure input bytes on first iteration; accumulate timing across all.
    if [ "$_ue_attempt" -eq 1 ]; then
      _ue_input_bytes="$(wc -c < "$_ue_prompt_file" 2>/dev/null | tr -d ' ' || true)"
      _ue_input_bytes="${_ue_input_bytes:-0}"
    fi
    _ue_call_start=$(date +%s)

    local _ue_proposals_raw="" _ue_llm_rc=0
    _ue_proposals_raw="$(provider_run_prompt_with_timeout \
      "$(cat "$_ue_prompt_file")" \
      "$(provider_resolve_model doc_assessment)" \
      true \
      "$_ue_timeout" 2>/dev/null)" || _ue_llm_rc=$?
    rm -f "$_ue_prompt_file"

    _ue_call_end=$(date +%s)
    _ue_llm_elapsed_s=$((_ue_llm_elapsed_s + _ue_call_end - _ue_call_start))

    if [ "$_ue_llm_rc" -eq 124 ]; then
      print_warning "Provider call timed out after ${_ue_timeout}s — no proposals generated" >&2
      _diag "DOC_PASS kind=docs doc=- duration_s=${_ue_llm_elapsed_s} input_bytes=${_ue_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "-" "$_ue_llm_elapsed_s"
      return 1
    elif [ "$_ue_llm_rc" -ne 0 ]; then
      print_warning "Provider call failed (exit ${_ue_llm_rc}) — no proposals generated" >&2
      _diag "DOC_PASS kind=docs doc=- duration_s=${_ue_llm_elapsed_s} input_bytes=${_ue_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "-" "$_ue_llm_elapsed_s"
      return 1
    fi

    if [ -z "$_ue_proposals_raw" ]; then
      print_info "No proposals returned"
      _diag "DOC_PASS kind=docs doc=- duration_s=${_ue_llm_elapsed_s} input_bytes=${_ue_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "-" "$_ue_llm_elapsed_s"
      return 0
    fi

    if printf '%s\n' "$_ue_proposals_raw" | grep -q "^NO_PROPOSALS_NEEDED"; then
      print_info "Doc assessment: no changes needed"
      _diag "DOC_PASS kind=docs doc=- duration_s=${_ue_llm_elapsed_s} input_bytes=${_ue_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "-" "$_ue_llm_elapsed_s"
      return 0
    fi

    # ---- Parse proposals ----
    local _ue_props_dir
    _ue_props_dir="$(mktemp -d)"
    local _ue_prop_count=0
    local _ue_in_prop=0 _ue_in_content=0
    local _ue_cur_action="" _ue_cur_file="" _ue_cur_drift="" _ue_cur_desc="" _ue_cur_content=""

    local _ue_raw_file
    _ue_raw_file="$(mktemp)"
    printf '%s\n' "$_ue_proposals_raw" > "$_ue_raw_file"

    local _ue_rl
    while IFS= read -r _ue_rl || [ -n "$_ue_rl" ]; do
      case "$_ue_rl" in
        "---PROPOSAL---")
          if [ "$_ue_in_content" = "1" ]; then
            _ue_cur_content="${_ue_cur_content}${_ue_rl}"$'\n'
          else
            _ue_in_prop=1; _ue_in_content=0
            _ue_cur_action=""; _ue_cur_file=""; _ue_cur_drift=""; _ue_cur_desc=""; _ue_cur_content=""
          fi
          ;;
        "---CONTENT---")
          if [ "$_ue_in_content" = "1" ]; then
            _ue_cur_content="${_ue_cur_content}${_ue_rl}"$'\n'
          else
            [ "$_ue_in_prop" = "1" ] && _ue_in_content=1
          fi
          ;;
        "${_ue_end_token}")
          if [ "$_ue_in_prop" = "1" ] && [ -n "$_ue_cur_file" ]; then
            _ue_prop_count=$((_ue_prop_count + 1))
            {
              printf 'ACTION: %s\n' "$_ue_cur_action"
              printf 'FILE: %s\n' "$_ue_cur_file"
              printf 'DRIFT_REFS: %s\n' "${_ue_cur_drift:-none}"
              printf 'DESCRIPTION: %s\n' "$_ue_cur_desc"
              printf -- '---CONTENT---\n'
              printf '%s' "$_ue_cur_content"
            } > "${_ue_props_dir}/proposal_${_ue_prop_count}.txt"
          fi
          _ue_in_prop=0; _ue_in_content=0
          ;;
        *)
          if [ "$_ue_in_prop" = "1" ]; then
            if [ "$_ue_in_content" = "1" ]; then
              _ue_cur_content="${_ue_cur_content}${_ue_rl}"$'\n'
            else
              case "$_ue_rl" in
                "ACTION: "*)     _ue_cur_action="${_ue_rl#ACTION: }" ;;
                "FILE: "*)       _ue_cur_file="${_ue_rl#FILE: }" ;;
                "DRIFT_REFS: "*) _ue_cur_drift="${_ue_rl#DRIFT_REFS: }" ;;
                "DESCRIPTION: "*) _ue_cur_desc="${_ue_rl#DESCRIPTION: }" ;;
              esac
            fi
          fi
          ;;
      esac
    done < "$_ue_raw_file"
    rm -f "$_ue_raw_file"

    if [ "$_ue_prop_count" -eq 0 ]; then
      if printf '%s\n' "$_ue_proposals_raw" | grep -q "^---PROPOSAL---$"; then
        print_warning "Model output contained '---PROPOSAL---' markers but zero complete proposals were parsed — model may have used '---END---' instead of expected end token '${_ue_end_token}'; re-run to generate a new unique end token" >&2
      fi
      print_info "No actionable proposals in LLM output"
      rm -rf "$_ue_props_dir"
      _diag "DOC_PASS kind=docs doc=- duration_s=${_ue_llm_elapsed_s} input_bytes=${_ue_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "-" "$_ue_llm_elapsed_s"
      return 0
    fi

    echo "" >&2
    print_info "${_ue_prop_count} proposal(s) to review:"

    # ---- Per-proposal review loop ----
    local _ue_appr_dir
    _ue_appr_dir="$(mktemp -d)"
    local _ue_appr_count=0
    local _ue_feedback_this_round="" _ue_pi=1

    while [ "$_ue_pi" -le "$_ue_prop_count" ]; do
      local _ue_pf="${_ue_props_dir}/proposal_${_ue_pi}.txt"
      [ -f "$_ue_pf" ] || { _ue_pi=$((_ue_pi + 1)); continue; }

      # Extract header fields from proposal file
      local _ue_p_action _ue_p_file _ue_p_drift _ue_p_desc _ue_p_content
      _ue_p_action="$(grep '^ACTION: ' "$_ue_pf" | head -1 | cut -d' ' -f2- || true)"
      _ue_p_file="$(grep '^FILE: ' "$_ue_pf" | head -1 | cut -d' ' -f2- || true)"
      _ue_p_drift="$(grep '^DRIFT_REFS: ' "$_ue_pf" | head -1 || true)"
      _ue_p_drift="${_ue_p_drift#DRIFT_REFS: }"
      _ue_p_desc="$(grep '^DESCRIPTION: ' "$_ue_pf" | head -1 || true)"
      _ue_p_desc="${_ue_p_desc#DESCRIPTION: }"

      # Extract content (everything after ---CONTENT--- line)
      _ue_p_content=""
      local _ue_in_c=0 _ue_cl
      while IFS= read -r _ue_cl || [ -n "$_ue_cl" ]; do
        if [ "$_ue_in_c" = "1" ]; then
          _ue_p_content="${_ue_p_content}${_ue_cl}"$'\n'
        elif [ "$_ue_cl" = "---CONTENT---" ]; then
          _ue_in_c=1
        fi
      done < "$_ue_pf"

      # Reject unsafe paths before preview (absolute or directory traversal)
      # shellcheck disable=SC2221,SC2222
      # SC2221/2222: patterns are distinct — *../* matches mid-traversal (foo/../bar),
      # */.. matches end-traversal (foo/..) which has no / after .. and is not covered by *../*
      case "$_ue_p_file" in
        /*|*../*|*/..|../*|..)
          print_warning "  Skipping proposal with unsafe FILE path: '$_ue_p_file'" >&2
          _ue_pi=$((_ue_pi + 1))
          continue
          ;;
      esac

      # Refuse EDIT proposals when the file was not in the LLM's context:
      # either dropped by the 15KB budget cap or absent from the docs map entirely.
      # Guard is skipped when _ue_ctx_files is empty (map absent or empty) so that
      # a missing map does not block every EDIT proposal wholesale.
      if [ "$_ue_p_action" = "EDIT" ]; then
        if [ -n "$_ue_ctx_files" ]; then
          case $'\n'"$_ue_ctx_files" in
            *$'\n'"${_ue_p_file}"$'\n'*) : ;;
            *)
              print_warning "  Auto-skipping EDIT for '${_ue_p_file}': file not in model context (absent from docs map or excluded by 15KB cap) — model never read its content; rebuild the docs map (rite docs) or narrow the instruction to a doc listed in the context block above" >&2
              _ue_pi=$((_ue_pi + 1))
              continue
              ;;
          esac
        fi
        local _ue_abs_size_check="${RITE_PROJECT_ROOT}/${_ue_p_file}"
        if [ -f "$_ue_abs_size_check" ]; then
          local _ue_file_size
          _ue_file_size="$(wc -c < "$_ue_abs_size_check" 2>/dev/null || echo 0)"
          if [ "$_ue_file_size" -gt 2000 ]; then
            print_warning "  Auto-skipping EDIT for '${_ue_p_file}': file is ${_ue_file_size} bytes but model only saw first 2,000 bytes — accepting would truncate unseen content" >&2
            _ue_pi=$((_ue_pi + 1))
            continue
          fi
        elif ! git -C "$RITE_PROJECT_ROOT" cat-file -e "origin/${_ue_target}:${_ue_p_file}" 2>/dev/null; then
          print_warning "  Auto-skipping EDIT for '${_ue_p_file}': file does not exist locally or on origin/${_ue_target} — use ACTION: CREATE for a new file" >&2
          _ue_pi=$((_ue_pi + 1))
          continue
        fi
      fi

      # Refuse CREATE proposals when the target already exists locally or on
      # origin/<target>: the model authored content without reading the original,
      # so accepting would overwrite it wholesale with unreviewed content.
      if [ "$_ue_p_action" = "CREATE" ]; then
        local _ue_abs_create_check="${RITE_PROJECT_ROOT}/${_ue_p_file}"
        if [ -f "$_ue_abs_create_check" ] || \
            git -C "$RITE_PROJECT_ROOT" cat-file -e "origin/${_ue_target}:${_ue_p_file}" 2>/dev/null; then
          print_warning "  Auto-skipping CREATE for '${_ue_p_file}': file already exists — use ACTION: EDIT to update an existing file" >&2
          _ue_pi=$((_ue_pi + 1))
          continue
        fi
      fi

      # Show preview header
      echo "" >&2
      echo "──────────────────────────────────────────────" >&2
      printf '  Proposal %d/%d  [%s]  %s\n' "$_ue_pi" "$_ue_prop_count" "$_ue_p_action" "$_ue_p_file" >&2
      [ -n "$_ue_p_drift" ] && [ "$_ue_p_drift" != "none" ] && \
        printf '  Covers: %s\n' "$_ue_p_drift" >&2
      printf '  %s\n' "$_ue_p_desc" >&2
      echo "" >&2

      if [ "$_ue_p_action" = "CREATE" ]; then
        echo "  [CREATE — new file, full content shown]" >&2
        printf '%s\n' "$_ue_p_content" | head -40 >&2
        local _ue_total_lines
        _ue_total_lines="$(printf '%s\n' "$_ue_p_content" | wc -l | tr -d ' ')"
        [ "$_ue_total_lines" -gt 40 ] && \
          printf '  ... (%d lines total)\n' "$_ue_total_lines" >&2
        echo "" >&2
        _docs_proposal_guards 0 "$(printf '%s' "$_ue_p_content" | wc -c | tr -d ' ')" "$_ue_p_content" \
          "$_ue_p_desc" "$_ue_growth_threshold" "$_ue_committer_names"
      else
        # EDIT: show unified diff against origin/<target> content (what the worktree
        # forks from) — not the local checkout, which may diverge from origin and
        # would show the user a delta that doesn't match what gets committed.
        local _ue_old_tmp _ue_new_tmp
        _ue_old_tmp="$(mktemp)"
        _ue_new_tmp="$(mktemp)"
        if ! git -C "$RITE_PROJECT_ROOT" show "origin/${_ue_target}:${_ue_p_file}" > "$_ue_old_tmp" 2>/dev/null; then
          local _ue_abs_path="${RITE_PROJECT_ROOT}/${_ue_p_file}"
          if [ -f "$_ue_abs_path" ]; then
            cat "$_ue_abs_path" > "$_ue_old_tmp"
          else
            printf '' > "$_ue_old_tmp"
          fi
        fi
        printf '%s' "$_ue_p_content" > "$_ue_new_tmp"
        diff -u "$_ue_old_tmp" "$_ue_new_tmp" >&2 || true
        echo "" >&2
        local _ue_old_bytes _ue_new_bytes _ue_added_lines
        _ue_old_bytes="$(wc -c < "$_ue_old_tmp" 2>/dev/null || echo 0)"
        _ue_old_bytes="$(printf '%s' "$_ue_old_bytes" | tr -d ' ')"
        _ue_new_bytes="$(wc -c < "$_ue_new_tmp" 2>/dev/null || echo 0)"
        _ue_new_bytes="$(printf '%s' "$_ue_new_bytes" | tr -d ' ')"
        _ue_added_lines="$(diff "$_ue_old_tmp" "$_ue_new_tmp" | grep '^>' | cut -c3- || true)"
        rm -f "$_ue_old_tmp" "$_ue_new_tmp"
        _docs_proposal_guards "$_ue_old_bytes" "$_ue_new_bytes" "$_ue_added_lines" \
          "$_ue_p_desc" "$_ue_growth_threshold" "$_ue_committer_names"
      fi

      echo "" >&2
      local _ue_input="n"
      read -p "  Apply this change? (y)es / (n)o / (f)eedback: " -r _ue_input || true
      echo "" >&2

      case "$_ue_input" in
        [Yy]|[Yy][Ee][Ss])
          _ue_appr_count=$((_ue_appr_count + 1))
          cp "$_ue_pf" "${_ue_appr_dir}/approved_${_ue_appr_count}.txt"
          print_info "  Approved: ${_ue_p_file}"
          ;;
        [Nn]|[Nn][Oo])
          print_info "  Skipped: ${_ue_p_file}"
          ;;
        "")
          # Empty input (bare Enter) skips this proposal only, same as 'n'
          print_info "  Skipped: ${_ue_p_file}"
          ;;
        [Ff]|[Ff][Ee][Ee][Dd][Bb][Aa][Cc][Kk])
          # Explicit f/feedback: collect multi-line feedback; re-prompt on empty
          echo "  What changes do you want? (press Enter twice when done)" >&2
          local _ue_this_fb=""
          local _ue_empty_ct=0
          while IFS= read -r _ue_fb_line; do
            if [ -z "$_ue_fb_line" ]; then
              _ue_empty_ct=$((_ue_empty_ct + 1))
              [ "$_ue_empty_ct" -ge 2 ] && break
              _ue_this_fb="${_ue_this_fb}"$'\n'
            else
              _ue_empty_ct=0
              _ue_this_fb="${_ue_this_fb}${_ue_fb_line}"$'\n'
            fi
          done
          _ue_this_fb=$(printf '%s' "$_ue_this_fb" | sed 's/[[:space:]]*$//' || true)
          if [ -n "$_ue_this_fb" ]; then
            _ue_feedback_this_round="$_ue_this_fb"
            print_info "  Feedback captured — regenerating all proposals..."
            break
          else
            # Empty feedback: re-prompt this proposal without discarding approvals
            print_warning "  No feedback entered — please re-answer for proposal ${_ue_pi}" >&2
            continue
          fi
          ;;
        *)
          # Unrecognized input: re-prompt this proposal without discarding approvals
          print_warning "  Unrecognized response '${_ue_input}' — please enter y, n, or f" >&2
          continue
          ;;
      esac
      _ue_pi=$((_ue_pi + 1))
    done

    rm -rf "$_ue_props_dir"

    if [ -n "$_ue_feedback_this_round" ]; then
      rm -rf "$_ue_appr_dir"
      _ue_had_feedback=1
      if [ -n "$_ue_accum_fb" ]; then
        _ue_accum_fb="${_ue_accum_fb}
---
${_ue_feedback_this_round}"
      else
        _ue_accum_fb="$_ue_feedback_this_round"
      fi
      continue
    fi

    # All proposals reviewed without feedback
    if [ "$_ue_appr_count" -eq 0 ]; then
      print_info "No changes approved — nothing to apply"
      rm -rf "$_ue_appr_dir"
      local _ue_outcome_rej="rejected"
      [ "$_ue_had_feedback" -eq 1 ] && _ue_outcome_rej="feedback"
      _diag "DOC_PASS kind=docs doc=- duration_s=${_ue_llm_elapsed_s} input_bytes=${_ue_input_bytes} outcome=${_ue_outcome_rej}"
      _docs_warn_doc_pass_threshold "-" "$_ue_llm_elapsed_s"
      return 0
    fi

    # Apply approved changes
    local _ue_apply_rc=0
    _docs_apply_approved \
      "$_ue_appr_dir" \
      "${_ue_drift_path:-}" \
      "$_ue_instr" \
      "$_ue_mode" \
      "$_ue_target" || _ue_apply_rc=$?
    rm -rf "$_ue_appr_dir"
    _diag "DOC_PASS kind=docs doc=- duration_s=${_ue_llm_elapsed_s} input_bytes=${_ue_input_bytes} outcome=accepted"
    _docs_warn_doc_pass_threshold "-" "$_ue_llm_elapsed_s"
    return "$_ue_apply_rc"
  done

  print_warning "Max proposal regeneration attempts reached — no changes applied"
  local _ue_outcome_max="rejected"
  [ "$_ue_had_feedback" -eq 1 ] && _ue_outcome_max="feedback"
  _diag "DOC_PASS kind=docs doc=- duration_s=${_ue_llm_elapsed_s} input_bytes=${_ue_input_bytes} outcome=${_ue_outcome_max}"
  _docs_warn_doc_pass_threshold "-" "$_ue_llm_elapsed_s"
  return 1
}

# ---------------------------------------------------------------------------
# docs_directed_update INSTRUCTIONS
#
# Directed doc update engine entry point.
# Ensures the docs map is fresh, then calls _docs_update_engine in "directed"
# mode with the given instructions.
#
# Works in BOTH consent modes (sync and changelog): an explicitly commanded,
# previewed, human-approved update IS consent — the Layer 2 gate in
# assess-documentation.sh is not checked on the approved-apply path.
# ---------------------------------------------------------------------------
docs_directed_update() {
  local _du_instr="${*:-}"

  if [ -z "$_du_instr" ]; then
    print_warning "docs directed-update: no instructions provided (usage: rite docs \"<instruction>\")"
    return 1
  fi

  docs_map_ensure || true  # best-effort; engine can proceed with stale/missing map
  _docs_update_engine "directed" "$_du_instr"
}

# ---------------------------------------------------------------------------
# _docs_extract_section FILE HEADING_LEVEL HEADING_TEXT
#
# Extract one section from FILE by its heading anchor (level + text).
# Mirrors _plan_extract_section from plan-issues.sh without sourcing that file.
# Output: heading line + body up to (not including) the next same-or-higher
# heading, or EOF.  Preamble: HEADING_LEVEL="" → lines before the first heading.
# ---------------------------------------------------------------------------
_docs_extract_section() {
  local _des_file="$1"
  local _des_level="$2"
  local _des_text="$3"
  [ -f "$_des_file" ] || return 0

  if [ -z "$_des_level" ]; then
    awk 'BEGIN{inf=0}
      /^```/||/^~~~/{inf=!inf; print; next}
      !inf&&/^#/{exit}
      {print}' "$_des_file"
  else
    TGT_TEXT="$_des_text" awk -v tgt_level="$_des_level" '
      BEGIN{capturing=0;inf=0;tgt_l=tgt_level+0;tgt_text=ENVIRON["TGT_TEXT"]}
      /^```/||/^~~~/{inf=!inf; if(capturing)print; next}
      !inf&&/^#/{
        n=0; line=$0
        while(substr(line,1,1)=="#"){n++;line=substr(line,2)}
        if(substr(line,1,1)==" ") line=substr(line,2)
        if(substr(line,1,1)=="\t") line=substr(line,2)
        if(length(line)>0&&substr(line,length(line),1)==" ") line=substr(line,1,length(line)-1)
        if(length(line)>0&&substr(line,length(line),1)=="\t") line=substr(line,1,length(line)-1)
        gsub(/\t/,"",line)
        if(!capturing){
          if(n==tgt_l&&line==tgt_text){capturing=1;print}
        } else {
          if(n<=tgt_l){exit}
          print
        }
        next
      }
      capturing{print}
    ' "$_des_file"
  fi
}

# ---------------------------------------------------------------------------
# _docs_list_main_entry_docs
#
# Echo one doc path per line for every doc that has branch=main drift entries
# in RITE_STATE_DIR/doc-drift/main/.  Reads the doc= field from the entry file
# directly (avoids slug-reversal ambiguity).
# ---------------------------------------------------------------------------
_docs_list_main_entry_docs() {
  _docs_list_branch_entry_docs "main"
}

# ---------------------------------------------------------------------------
# _docs_list_branch_entry_docs BRANCH
#
# Echo one doc path per line for every doc that has drift entries for the
# given branch in RITE_STATE_DIR/doc-drift/<branch>/.
# Parameterized version of _docs_list_main_entry_docs.
# ---------------------------------------------------------------------------
_docs_list_branch_entry_docs() {
  local _lbd_branch="${1:-main}"
  local _lbd_dir="${RITE_STATE_DIR:-}/doc-drift/${_lbd_branch}"
  [ -d "$_lbd_dir" ] || return 0
  local _lbd_f _lbd_doc _lbd_cnt
  while IFS= read -r _lbd_f || [ -n "$_lbd_f" ]; do
    [ -f "$_lbd_f" ] || continue
    _lbd_doc="$(awk -F'\t' '{for(i=1;i<=NF;i++){if(substr($i,1,4)=="doc="){print substr($i,5); exit}}}' \
      "$_lbd_f" | head -1 || true)"
    [ -n "$_lbd_doc" ] || continue
    _lbd_cnt="$(grep -c '^doc=' "$_lbd_f" || true)"
    [ "$_lbd_cnt" -gt 0 ] && printf '%s\n' "$_lbd_doc"
  done < <(find "$_lbd_dir" -name '*.log' -type f 2>/dev/null | sort || true)
}

# ---------------------------------------------------------------------------
# _docs_is_adr_in_map DOC
#
# Returns 0 (true) when DOC is classified as an ADR type in the docs-map
# (adr_flag col 3 = "adr" or type col 7 = "adr").
# Returns 1 when the map is absent or DOC has no ADR classification.
# Internal helper — used by the promote doc-pass to route ADR observations.
# ---------------------------------------------------------------------------
_docs_is_adr_in_map() {
  local _diam_doc="${1:-}"
  [ -n "$_diam_doc" ] || return 1
  local _diam_map
  _diam_map="$(docs_map_path)"
  [ -f "$_diam_map" ] || return 1
  awk -F'\t' -v doc="$_diam_doc" \
    'NR>1 && !/^#/ && $1==doc && ($3=="adr" || $7=="adr"){found=1; exit} END{exit (found+0 ? 0 : 1)}' \
    "$_diam_map" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# _docs_list_adr_drift_docs
#
# Echo one doc path per line for every ADR doc that has pending ADR drift
# entries in RITE_STATE_DIR/doc-drift-adr/.
# ---------------------------------------------------------------------------
_docs_list_adr_drift_docs() {
  local _ladd_base="${RITE_STATE_DIR:-}/doc-drift-adr"
  [ -d "$_ladd_base" ] || return 0
  local _ladd_f _ladd_doc _ladd_cnt
  while IFS= read -r _ladd_f || [ -n "$_ladd_f" ]; do
    [ -f "$_ladd_f" ] || continue
    _ladd_doc="$(awk -F'\t' '{for(i=1;i<=NF;i++){if(substr($i,1,4)=="doc="){print substr($i,5); exit}}}' \
      "$_ladd_f" | head -1 || true)"
    [ -n "$_ladd_doc" ] || continue
    _ladd_cnt="$(grep -c '^doc=' "$_ladd_f" || true)"
    [ "${_ladd_cnt:-0}" -gt 0 ] && printf '%s\n' "$_ladd_doc"
  done < <(find "$_ladd_base" -name '*.log' -type f 2>/dev/null | sort || true)
}

# ---------------------------------------------------------------------------
# _docs_bounded_context_for_doc DOC
#
# Assemble bounded LLM context for a single doc:
#   - Map-anchored sections of the target doc (up to 8 KB)
#   - ADR files that link to this doc (up to 4 KB, from docs_map_adr_links)
# Writes the formatted context block to stdout.
# ---------------------------------------------------------------------------
_docs_bounded_context_for_doc() {
  local _bcd_doc="$1"
  local _bcd_abs="${RITE_PROJECT_ROOT}/${_bcd_doc}"
  local _bcd_section_cap=8000
  local _bcd_adr_cap=4000

  local _bcd_map_file
  _bcd_map_file="$(docs_map_path)"

  # --- Pass 1: map-anchored section reads for the target doc ---
  local _bcd_sec_bytes=0
  local _bcd_sec_content=""
  if [ -f "$_bcd_map_file" ] && [ -f "$_bcd_abs" ]; then
    local _bcd_fp _bcd_sha _bcd_af _bcd_hl _bcd_ht _bcd_fpr _bcd_dt _bcd_rb _bcd_tg _bcd_nt
    while IFS=$'\001' read -r _bcd_fp _bcd_sha _bcd_af _bcd_hl _bcd_ht _bcd_fpr _bcd_dt _bcd_rb _bcd_tg _bcd_nt; do
      [ "$_bcd_fp" = "$_bcd_doc" ] || continue
      local _bcd_sec
      _bcd_sec="$(_docs_extract_section "$_bcd_abs" "${_bcd_hl:-}" "${_bcd_ht:-}" || true)"
      [ -n "$_bcd_sec" ] || continue
      local _bcd_anchor="${_bcd_ht:-(preamble)}"
      local _bcd_entry
      _bcd_entry="--- ${_bcd_doc} § ${_bcd_anchor} ---
${_bcd_sec}

"
      if [ $((_bcd_sec_bytes + ${#_bcd_entry})) -gt "$_bcd_section_cap" ]; then
        _bcd_sec_content="${_bcd_sec_content}(remaining sections omitted — byte cap)
"
        break
      fi
      _bcd_sec_bytes=$((_bcd_sec_bytes + ${#_bcd_entry}))
      _bcd_sec_content="${_bcd_sec_content}${_bcd_entry}"
    done < <(awk -F'\t' '/^#/{next}{printf "%s\001%s\001%s\001%s\001%s\001%s\001%s\001%s\001%s\001%s\n",$1,(NF>=2)?$2:"",(NF>=3)?$3:"-",(NF>=4)?$4:"",(NF>=5)?$5:"",(NF>=6)?$6:"",(NF>=7)?$7:"other",(NF>=8)?$8:"-",(NF>=9)?$9:"-",(NF>=10)?$10:"-"}' "$_bcd_map_file" || true)
  fi

  # --- Pass 2: ADR files that reference this doc ---
  local _bcd_adr_bytes=0
  local _bcd_adr_content=""
  local _bcd_seen_adrs=""
  if [ -f "$_bcd_map_file" ]; then
    local _bcd_a_fp _bcd_a_sha _bcd_a_af _bcd_a_r1 _bcd_a_r2 _bcd_a_r3 _bcd_a_r4 _bcd_a_r5 _bcd_a_r6 _bcd_a_r7
    while IFS=$'\001' read -r _bcd_a_fp _bcd_a_sha _bcd_a_af _bcd_a_r1 _bcd_a_r2 _bcd_a_r3 _bcd_a_r4 _bcd_a_r5 _bcd_a_r6 _bcd_a_r7; do
      [ "$_bcd_a_af" = "adr" ] || continue
      # Dedup: process each ADR file once
      case $'\n'"$_bcd_seen_adrs"$'\n' in *$'\n'"${_bcd_a_fp}"$'\n'*) continue ;; esac
      _bcd_seen_adrs="${_bcd_seen_adrs}${_bcd_a_fp}"$'\n'
      local _bcd_adr_abs="${RITE_PROJECT_ROOT}/${_bcd_a_fp}"
      [ -f "$_bcd_adr_abs" ] || continue
      local _bcd_links
      _bcd_links="$(docs_map_adr_links "$_bcd_a_fp" 2>/dev/null || true)"
      printf '%s\n' "$_bcd_links" | grep -qxF "$_bcd_doc" 2>/dev/null || continue
      local _bcd_adr_excerpt
      _bcd_adr_excerpt="$(head -c 3000 "$_bcd_adr_abs" 2>/dev/null || true)"
      local _bcd_adr_entry
      _bcd_adr_entry="--- ADR: ${_bcd_a_fp} ---
${_bcd_adr_excerpt}

"
      if [ $((_bcd_adr_bytes + ${#_bcd_adr_entry})) -gt "$_bcd_adr_cap" ]; then
        break
      fi
      _bcd_adr_bytes=$((_bcd_adr_bytes + ${#_bcd_adr_entry}))
      _bcd_adr_content="${_bcd_adr_content}${_bcd_adr_entry}"
    done < <(awk -F'\t' '/^#/{next}{printf "%s\001%s\001%s\001%s\001%s\001%s\001%s\001%s\001%s\001%s\n",$1,(NF>=2)?$2:"",(NF>=3)?$3:"-",(NF>=4)?$4:"",(NF>=5)?$5:"",(NF>=6)?$6:"",(NF>=7)?$7:"other",(NF>=8)?$8:"-",(NF>=9)?$9:"-",(NF>=10)?$10:"-"}' "$_bcd_map_file" || true)
  fi

  printf '%s' "$_bcd_sec_content"
  [ -n "$_bcd_adr_content" ] && printf '%s' "$_bcd_adr_content"
  return 0
}

# ---------------------------------------------------------------------------
# _docs_warn_doc_pass_threshold DOC DURATION_S
#
# Prints an info-level suggestion when DURATION_S exceeds
# RITE_DOC_PASS_WARN_SECONDS (default 120).  Called after every DOC_PASS diag
# emission so the suggestion appears at most once per pass.
# ---------------------------------------------------------------------------
_docs_warn_doc_pass_threshold() {
  local _dwt_doc="${1:-}"
  local _dwt_dur="${2:-0}"
  local _dwt_thresh="${RITE_DOC_PASS_WARN_SECONDS:-120}"
  if [ "$_dwt_dur" -gt "$_dwt_thresh" ] 2>/dev/null; then
    print_info "Doc pass took ${_dwt_dur}s — for targeted runs: rite align-docs ${_dwt_doc}"
  fi
}

# ---------------------------------------------------------------------------
# _docs_main_entries_pass DOC
#
# Tier 2 per-doc engine for branch=main drift entries.
#
# 1. Reads structured entries for DOC from RITE_STATE_DIR/doc-drift/main/.
# 2. Assembles bounded input (map-anchored sections, ADR context, entries,
#    diff summary extracted from entry evidence fields).
# 3. Calls provider_resolve_model doc_update (not doc_assessment).
# 4. Validates response contains both a ---NARRATIVE--- block AND at least one
#    ---PROPOSAL--- block; missing either → accumulates feedback and retries
#    (up to 5 attempts, same as _docs_update_engine).
# 5. REFINE proposals (ACTION: REFINE) → interactive prompt; on approval
#    writes a kind=refinement drift entry; never applied as doc edits.
# 6. EDIT / CREATE proposals → #1208 guards + existing preview loop.
# 7. Approved EDIT/CREATE changes → _docs_apply_approved (same docs-PR path).
#
# Notes:
# - Entry burn-down is NOT performed here (deferred to a separate issue).
# - The #1233 per-generation end token prevents content containing ---END---
#   from being mistaken for a proposal delimiter.
# ---------------------------------------------------------------------------
_docs_main_entries_pass() {
  local _mp_doc="$1"
  # Branch whose drift entries are being processed (default: main).
  # Callers in the promote doc pass pass the integration branch name so
  # entries recorded for that branch are read and consumed.
  local _mp_branch="${2:-main}"
  # Base branch for the resulting docs PR (always main when called from
  # promote; defaults to RITE_TARGET_BRANCH for the rite docs path).
  local _mp_target="${3:-${RITE_TARGET_BRANCH:-main}}"
  local _mp_timeout="${RITE_DOC_ASSESSMENT_TIMEOUT:-300}"
  # kind=promote when called from the post-promote doc pass; kind=docs otherwise.
  local _mp_kind="${4:-docs}"

  # DOC_PASS diag tracking: accumulated LLM time, last prompt bytes, feedback flag.
  local _mp_llm_elapsed_s=0 _mp_input_bytes=0 _mp_had_feedback=0
  local _mp_call_start _mp_call_end

  # Read entry file for this doc from the branch's drift store
  local _mp_entry_file
  _mp_entry_file="$(_drift_entry_path "$_mp_doc" "$_mp_branch" || true)"
  if [ -z "$_mp_entry_file" ] || [ ! -f "$_mp_entry_file" ]; then
    print_info "  No main-branch entries for ${_mp_doc}"
    return 0
  fi

  # Collect entries as formatted text; extract evidence for diff summary
  local _mp_entries_text="" _mp_diff_summary=""
  local _mp_eline
  while IFS= read -r _mp_eline || [ -n "$_mp_eline" ]; do
    [ -n "$_mp_eline" ] || continue
    _mp_entries_text="${_mp_entries_text}${_mp_eline}
"
    local _mp_ev
    _mp_ev="$(printf '%s' "$_mp_eline" | awk -F'\t' \
      '{for(i=1;i<=NF;i++){if(substr($i,1,9)=="evidence="){print substr($i,10); break}}}' || true)"
    if [ -n "$_mp_ev" ] && [ "$_mp_ev" != "-" ]; then
      _mp_diff_summary="${_mp_diff_summary}${_mp_ev}
"
    fi
  done < "$_mp_entry_file"

  # Bounded context: map-anchored sections + ADR references
  local _mp_doc_ctx
  _mp_doc_ctx="$(_docs_bounded_context_for_doc "$_mp_doc" || true)"

  # Fetch origin/<target> so the #1208 CREATE/EDIT guards reflect current remote state
  git -C "$RITE_PROJECT_ROOT" fetch origin "$_mp_target" 2>/dev/null || {
    print_warning "Could not fetch origin/${_mp_target} — CREATE guard may miss recently-pushed files" >&2
  }

  # Context-membership list for the #1208 EDIT guard: this pass is scoped to
  # a single doc, so only that doc (plus any CREATE targets) is in context.
  local _mp_ctx_files="${_mp_doc}
"

  # Cache committer names once per pass for the shipped-product guard.
  local _mp_committer_names=""
  _mp_committer_names="$(git -C "$RITE_PROJECT_ROOT" log --format='%an' 2>/dev/null \
    | sort -u | awk 'length >= 3' || true)"
  local _mp_growth_threshold="${RITE_DOC_GROWTH_WARN_PCT:-15}"
  case "$_mp_growth_threshold" in
    *[!0-9]*|"")
      printf 'Notice: RITE_DOC_GROWTH_WARN_PCT="%s" is not a valid integer — using default 15\n' \
        "$_mp_growth_threshold" >&2
      _mp_growth_threshold=15 ;;
  esac

  local _mp_accum_fb=""
  local _mp_attempt=0
  # Per-generation end token (#1233): prevents doc content containing ---END---
  # from being mistaken for a proposal delimiter.
  local _mp_end_token="---END-${RANDOM}${RANDOM}---"

  while [ "$_mp_attempt" -lt 5 ]; do
    _mp_attempt=$((_mp_attempt + 1))

    local _mp_fb_section=""
    if [ -n "$_mp_accum_fb" ]; then
      _mp_fb_section="
Feedback from previous proposal round — incorporate in new proposals:
${_mp_accum_fb}
"
    fi

    local _mp_prompt_file
    _mp_prompt_file="$(mktemp)"
    # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: doc, context, entry, and feedback vars must expand
    cat > "$_mp_prompt_file" <<DOC_MAIN_EOF
You are a documentation writer performing a Tier 2 documentation correction pass.

Target doc: ${_mp_doc}
${_mp_fb_section}
REQUIRED OUTPUT FORMAT — both sections are mandatory:

1. A ---NARRATIVE--- block (2-5 sentences explaining what changed in the code and why the doc needs updating).
2. At least one ---PROPOSAL--- block with an explicit edit.

For assertions you cannot verify deterministically (e.g. subjective quality claims like "the experience is smooth"), output a REFINE proposal — propose enforceable, checkable wording instead of an EDIT.

Bounded context for ${_mp_doc} (map-anchored sections + referencing ADRs):
${_mp_doc_ctx}

Drift entries (tab-separated: doc=, branch=, pr=, issue=, assertion=, kind=, evidence=, recorded=):
${_mp_entries_text}

Diff summary (changed files/tests that triggered these entries):
${_mp_diff_summary:-none recorded}

Output in this EXACT format (missing either section causes a retry):

---NARRATIVE---
<2-5 sentences: what changed in the code and why the doc needs updating>
---END-NARRATIVE---

For each doc to edit (full new content of the entire file — NOT just the changed section):
---PROPOSAL---
ACTION: EDIT
FILE: ${_mp_doc}
DRIFT_REFS: <space-separated pr:N from the entries above, or "none">
DESCRIPTION: <one-line summary>
---CONTENT---
<complete new content of the entire file>
${_mp_end_token}

For nondeterministic assertions (propose enforceable rewording):
---PROPOSAL---
ACTION: REFINE
FILE: ${_mp_doc}
DRIFT_REFS: <pr:N refs or "none">
DESCRIPTION: <why this assertion is not verifiable and what checkable form it should take>
---CONTENT---
<proposed enforceable rewording>
${_mp_end_token}

If no changes are needed: NO_PROPOSALS_NEEDED
DOC_MAIN_EOF

    print_info "Running Tier 2 doc pass for ${_mp_doc} (attempt ${_mp_attempt}/5)..."

    _mp_input_bytes="$(wc -c < "$_mp_prompt_file" 2>/dev/null | tr -d ' ' || true)"
    _mp_input_bytes="${_mp_input_bytes:-0}"
    _mp_call_start=$(date +%s)
    local _mp_raw="" _mp_llm_rc=0
    _mp_raw="$(provider_run_prompt_with_timeout \
      "$(cat "$_mp_prompt_file")" \
      "$(provider_resolve_model doc_update)" \
      true \
      "$_mp_timeout" 2>/dev/null)" || _mp_llm_rc=$?
    _mp_call_end=$(date +%s)
    _mp_llm_elapsed_s=$((_mp_llm_elapsed_s + _mp_call_end - _mp_call_start))
    rm -f "$_mp_prompt_file"

    if [ "$_mp_llm_rc" -eq 124 ]; then
      print_warning "Provider call timed out after ${_mp_timeout}s — no proposals generated for ${_mp_doc}" >&2
      _diag "DOC_PASS kind=${_mp_kind} doc=${_mp_doc} duration_s=${_mp_llm_elapsed_s} input_bytes=${_mp_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "$_mp_doc" "$_mp_llm_elapsed_s"
      return 1
    elif [ "$_mp_llm_rc" -ne 0 ]; then
      print_warning "Provider call failed (exit ${_mp_llm_rc}) — no proposals generated for ${_mp_doc}" >&2
      _diag "DOC_PASS kind=${_mp_kind} doc=${_mp_doc} duration_s=${_mp_llm_elapsed_s} input_bytes=${_mp_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "$_mp_doc" "$_mp_llm_elapsed_s"
      return 1
    fi

    if [ -z "$_mp_raw" ]; then
      print_info "No proposals returned for ${_mp_doc}"
      _diag "DOC_PASS kind=${_mp_kind} doc=${_mp_doc} duration_s=${_mp_llm_elapsed_s} input_bytes=${_mp_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "$_mp_doc" "$_mp_llm_elapsed_s"
      return 0
    fi

    if printf '%s\n' "$_mp_raw" | grep -q "^NO_PROPOSALS_NEEDED"; then
      print_info "Doc pass: no changes needed for ${_mp_doc}"
      _diag "DOC_PASS kind=${_mp_kind} doc=${_mp_doc} duration_s=${_mp_llm_elapsed_s} input_bytes=${_mp_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "$_mp_doc" "$_mp_llm_elapsed_s"
      return 0
    fi

    # Validate: response must contain both a narrative and at least one proposal
    local _mp_has_narrative=0 _mp_has_proposal=0
    printf '%s\n' "$_mp_raw" | grep -q "^---NARRATIVE---" && _mp_has_narrative=1 || true
    printf '%s\n' "$_mp_raw" | grep -q "^---PROPOSAL---" && _mp_has_proposal=1 || true

    if [ "$_mp_has_narrative" -eq 0 ] || [ "$_mp_has_proposal" -eq 0 ]; then
      local _mp_missing=""
      [ "$_mp_has_narrative" -eq 0 ] && _mp_missing="a ---NARRATIVE--- block"
      if [ "$_mp_has_proposal" -eq 0 ]; then
        _mp_missing="${_mp_missing:+${_mp_missing} and }at least one ---PROPOSAL--- block"
      fi
      local _mp_val_fb="Response is missing ${_mp_missing}. Both are required: a narrative explaining why the doc needs updating, and at least one explicit edit proposal."
      if [ -n "$_mp_accum_fb" ]; then
        _mp_accum_fb="${_mp_accum_fb}
---
${_mp_val_fb}"
      else
        _mp_accum_fb="$_mp_val_fb"
      fi
      print_warning "  Proposal for ${_mp_doc} missing ${_mp_missing} — retrying (${_mp_attempt}/5)..." >&2
      continue
    fi

    # Extract and display the narrative
    local _mp_narrative="" _mp_in_nar=0
    local _mp_nar_line
    while IFS= read -r _mp_nar_line || [ -n "$_mp_nar_line" ]; do
      case "$_mp_nar_line" in
        "---NARRATIVE---")     _mp_in_nar=1 ;;
        "---END-NARRATIVE---") _mp_in_nar=0 ;;
        *) [ "$_mp_in_nar" = "1" ] && _mp_narrative="${_mp_narrative}${_mp_nar_line}"$'\n' ;;
      esac
    done <<EOF_NAR
$_mp_raw
EOF_NAR
    if [ -n "$_mp_narrative" ]; then
      echo "" >&2
      print_info "Narrative for ${_mp_doc}:"
      printf '%s' "$_mp_narrative" >&2
    fi

    # --- Parse proposals ---
    local _mp_props_dir
    _mp_props_dir="$(mktemp -d)"
    local _mp_prop_count=0
    local _mp_in_prop=0 _mp_in_content=0
    local _mp_cur_action="" _mp_cur_file="" _mp_cur_drift="" _mp_cur_desc="" _mp_cur_content=""

    local _mp_raw_file
    _mp_raw_file="$(mktemp)"
    printf '%s\n' "$_mp_raw" > "$_mp_raw_file"

    local _mp_rl
    while IFS= read -r _mp_rl || [ -n "$_mp_rl" ]; do
      case "$_mp_rl" in
        "---NARRATIVE---"|"---END-NARRATIVE---")
          # Narrative delimiters are not proposals; include in content if inside one
          [ "$_mp_in_content" = "1" ] && _mp_cur_content="${_mp_cur_content}${_mp_rl}"$'\n'
          ;;
        "---PROPOSAL---")
          if [ "$_mp_in_content" = "1" ]; then
            _mp_cur_content="${_mp_cur_content}${_mp_rl}"$'\n'
          else
            _mp_in_prop=1; _mp_in_content=0
            _mp_cur_action=""; _mp_cur_file=""; _mp_cur_drift=""; _mp_cur_desc=""; _mp_cur_content=""
          fi
          ;;
        "---CONTENT---")
          if [ "$_mp_in_content" = "1" ]; then
            _mp_cur_content="${_mp_cur_content}${_mp_rl}"$'\n'
          else
            [ "$_mp_in_prop" = "1" ] && _mp_in_content=1
          fi
          ;;
        "${_mp_end_token}")
          if [ "$_mp_in_prop" = "1" ] && [ -n "$_mp_cur_file" ]; then
            _mp_prop_count=$((_mp_prop_count + 1))
            {
              printf 'ACTION: %s\n' "$_mp_cur_action"
              printf 'FILE: %s\n' "$_mp_cur_file"
              printf 'DRIFT_REFS: %s\n' "${_mp_cur_drift:-none}"
              printf 'DESCRIPTION: %s\n' "$_mp_cur_desc"
              printf -- '---CONTENT---\n'
              printf '%s' "$_mp_cur_content"
            } > "${_mp_props_dir}/proposal_${_mp_prop_count}.txt"
          fi
          _mp_in_prop=0; _mp_in_content=0
          ;;
        *)
          if [ "$_mp_in_prop" = "1" ]; then
            if [ "$_mp_in_content" = "1" ]; then
              _mp_cur_content="${_mp_cur_content}${_mp_rl}"$'\n'
            else
              case "$_mp_rl" in
                "ACTION: "*)      _mp_cur_action="${_mp_rl#ACTION: }" ;;
                "FILE: "*)        _mp_cur_file="${_mp_rl#FILE: }" ;;
                "DRIFT_REFS: "*)  _mp_cur_drift="${_mp_rl#DRIFT_REFS: }" ;;
                "DESCRIPTION: "*) _mp_cur_desc="${_mp_rl#DESCRIPTION: }" ;;
              esac
            fi
          fi
          ;;
      esac
    done < "$_mp_raw_file"
    rm -f "$_mp_raw_file"

    if [ "$_mp_prop_count" -eq 0 ]; then
      if printf '%s\n' "$_mp_raw" | grep -q "^---PROPOSAL---$"; then
        print_warning "Model output contained '---PROPOSAL---' markers but zero complete proposals were parsed — model may have used the wrong end token '${_mp_end_token}'; re-run to generate a new unique end token" >&2
      fi
      print_info "No actionable proposals for ${_mp_doc}"
      rm -rf "$_mp_props_dir"
      _diag "DOC_PASS kind=${_mp_kind} doc=${_mp_doc} duration_s=${_mp_llm_elapsed_s} input_bytes=${_mp_input_bytes} outcome=rejected"
      return 0
    fi

    echo "" >&2
    print_info "${_mp_prop_count} proposal(s) for ${_mp_doc}:"

    # --- Per-proposal preview loop (with #1208 guards) ---
    local _mp_appr_dir
    _mp_appr_dir="$(mktemp -d)"
    local _mp_appr_count=0
    local _mp_feedback_this_round="" _mp_pi=1

    while [ "$_mp_pi" -le "$_mp_prop_count" ]; do
      local _mp_pf="${_mp_props_dir}/proposal_${_mp_pi}.txt"
      [ -f "$_mp_pf" ] || { _mp_pi=$((_mp_pi + 1)); continue; }

      local _mp_p_action _mp_p_file _mp_p_drift _mp_p_desc _mp_p_content
      _mp_p_action="$(grep '^ACTION: ' "$_mp_pf" | head -1 | cut -d' ' -f2- || true)"
      _mp_p_file="$(grep '^FILE: ' "$_mp_pf" | head -1 | cut -d' ' -f2- || true)"
      _mp_p_drift="$(grep '^DRIFT_REFS: ' "$_mp_pf" | head -1 || true)"
      _mp_p_drift="${_mp_p_drift#DRIFT_REFS: }"
      _mp_p_desc="$(grep '^DESCRIPTION: ' "$_mp_pf" | head -1 || true)"
      _mp_p_desc="${_mp_p_desc#DESCRIPTION: }"

      _mp_p_content=""
      local _mp_in_c=0 _mp_cl
      while IFS= read -r _mp_cl || [ -n "$_mp_cl" ]; do
        if [ "$_mp_in_c" = "1" ]; then
          _mp_p_content="${_mp_p_content}${_mp_cl}"$'\n'
        elif [ "$_mp_cl" = "---CONTENT---" ]; then
          _mp_in_c=1
        fi
      done < "$_mp_pf"

      # Reject unsafe paths before preview
      # shellcheck disable=SC2221,SC2222
      case "$_mp_p_file" in
        /*|*../*|*/..|../*|..)
          print_warning "  Skipping proposal with unsafe FILE path: '$_mp_p_file'" >&2
          _mp_pi=$((_mp_pi + 1))
          continue
          ;;
      esac

      # REFINE action: record a kind=refinement drift entry (not a doc edit)
      if [ "$_mp_p_action" = "REFINE" ]; then
        echo "" >&2
        echo "──────────────────────────────────────────────" >&2
        printf '  Proposal %d/%d  [REFINE]  %s\n' "$_mp_pi" "$_mp_prop_count" "$_mp_p_file" >&2
        [ -n "$_mp_p_desc" ] && printf '  %s\n' "$_mp_p_desc" >&2
        echo "" >&2
        printf '  Proposed enforceable rewording:\n' >&2
        printf '%s\n' "$_mp_p_content" | head -10 >&2
        echo "" >&2
        local _mp_ref_input="n"
        read -p "  Record as refinement entry? (y)es / (n)o: " -r _mp_ref_input || true
        echo "" >&2
        case "$_mp_ref_input" in
          [Yy]|[Yy][Ee][Ss])
            drift_log_append "$_mp_p_file" "$_mp_branch" "0" "-" \
              "${_mp_p_desc}" "refinement" \
              "nondeterministic assertion; proposed rewording: ${_mp_p_content}" || true
            print_info "  Refinement entry recorded for ${_mp_p_file}"
            ;;
          *)
            print_info "  Skipped refinement for ${_mp_p_file}"
            ;;
        esac
        _mp_pi=$((_mp_pi + 1))
        continue
      fi

      # #1208 guard: EDIT context-membership check
      if [ "$_mp_p_action" = "EDIT" ]; then
        if [ -n "$_mp_ctx_files" ]; then
          case $'\n'"$_mp_ctx_files" in
            *$'\n'"${_mp_p_file}"$'\n'*) : ;;
            *)
              print_warning "  Auto-skipping EDIT for '${_mp_p_file}': file not in model context (pass is scoped to ${_mp_doc})" >&2
              _mp_pi=$((_mp_pi + 1))
              continue
              ;;
          esac
        fi
        # #1208 guard: large-file check — threshold matches _bcd_section_cap (8000)
        # in _docs_bounded_context_for_doc; files within the cap have their full
        # content loaded so EDIT is safe; files beyond the cap were seen only in
        # excerpt, making a whole-file overwrite unsafe.
        local _mp_abs_size="${RITE_PROJECT_ROOT}/${_mp_p_file}"
        if [ -f "$_mp_abs_size" ]; then
          local _mp_file_size
          _mp_file_size="$(wc -c < "$_mp_abs_size" 2>/dev/null || echo 0)"
          if [ "$_mp_file_size" -gt 8000 ]; then
            print_warning "  Auto-skipping EDIT for '${_mp_p_file}': file is ${_mp_file_size} bytes but model only saw bounded excerpt" >&2
            _mp_pi=$((_mp_pi + 1))
            continue
          fi
        elif ! git -C "$RITE_PROJECT_ROOT" cat-file -e "origin/${_mp_target}:${_mp_p_file}" 2>/dev/null; then
          print_warning "  Auto-skipping EDIT for '${_mp_p_file}': file does not exist locally or on origin/${_mp_target} — use ACTION: CREATE for a new file" >&2
          _mp_pi=$((_mp_pi + 1))
          continue
        fi
      fi

      # #1208 guard: CREATE-exists check
      if [ "$_mp_p_action" = "CREATE" ]; then
        local _mp_abs_create="${RITE_PROJECT_ROOT}/${_mp_p_file}"
        if [ -f "$_mp_abs_create" ] || \
           git -C "$RITE_PROJECT_ROOT" cat-file -e "origin/${_mp_target}:${_mp_p_file}" 2>/dev/null; then
          print_warning "  Auto-skipping CREATE for '${_mp_p_file}': file already exists — use ACTION: EDIT to update an existing file" >&2
          _mp_pi=$((_mp_pi + 1))
          continue
        fi
      fi

      # Show preview header
      echo "" >&2
      echo "──────────────────────────────────────────────" >&2
      printf '  Proposal %d/%d  [%s]  %s\n' "$_mp_pi" "$_mp_prop_count" "$_mp_p_action" "$_mp_p_file" >&2
      [ -n "$_mp_p_drift" ] && [ "$_mp_p_drift" != "none" ] && \
        printf '  Covers: %s\n' "$_mp_p_drift" >&2
      [ -n "$_mp_p_desc" ] && printf '  %s\n' "$_mp_p_desc" >&2
      echo "" >&2

      if [ "$_mp_p_action" = "CREATE" ]; then
        echo "  [CREATE — new file, full content shown]" >&2
        printf '%s\n' "$_mp_p_content" | head -40 >&2
        local _mp_total_lines
        _mp_total_lines="$(printf '%s\n' "$_mp_p_content" | wc -l | tr -d ' ')"
        [ "$_mp_total_lines" -gt 40 ] && \
          printf '  ... (%d lines total)\n' "$_mp_total_lines" >&2
        echo "" >&2
        _docs_proposal_guards 0 "$(printf '%s' "$_mp_p_content" | wc -c | tr -d ' ')" "$_mp_p_content" \
          "$_mp_p_desc" "$_mp_growth_threshold" "$_mp_committer_names"
      else
        local _mp_old_tmp _mp_new_tmp
        _mp_old_tmp="$(mktemp)"
        _mp_new_tmp="$(mktemp)"
        if ! git -C "$RITE_PROJECT_ROOT" show "origin/${_mp_target}:${_mp_p_file}" > "$_mp_old_tmp" 2>/dev/null; then
          local _mp_abs_path="${RITE_PROJECT_ROOT}/${_mp_p_file}"
          if [ -f "$_mp_abs_path" ]; then
            cat "$_mp_abs_path" > "$_mp_old_tmp"
          else
            printf '' > "$_mp_old_tmp"
          fi
        fi
        printf '%s' "$_mp_p_content" > "$_mp_new_tmp"
        diff -u "$_mp_old_tmp" "$_mp_new_tmp" >&2 || true
        echo "" >&2
        local _mp_old_bytes _mp_new_bytes _mp_added_lines
        _mp_old_bytes="$(wc -c < "$_mp_old_tmp" 2>/dev/null || echo 0)"
        _mp_old_bytes="$(printf '%s' "$_mp_old_bytes" | tr -d ' ')"
        _mp_new_bytes="$(wc -c < "$_mp_new_tmp" 2>/dev/null || echo 0)"
        _mp_new_bytes="$(printf '%s' "$_mp_new_bytes" | tr -d ' ')"
        _mp_added_lines="$(diff "$_mp_old_tmp" "$_mp_new_tmp" | grep '^>' | cut -c3- || true)"
        rm -f "$_mp_old_tmp" "$_mp_new_tmp"
        _docs_proposal_guards "$_mp_old_bytes" "$_mp_new_bytes" "$_mp_added_lines" \
          "$_mp_p_desc" "$_mp_growth_threshold" "$_mp_committer_names"
      fi

      echo "" >&2
      local _mp_input="n"
      read -p "  Apply this change? (y)es / (n)o / (f)eedback: " -r _mp_input || true
      echo "" >&2

      case "$_mp_input" in
        [Yy]|[Yy][Ee][Ss])
          _mp_appr_count=$((_mp_appr_count + 1))
          cp "$_mp_pf" "${_mp_appr_dir}/approved_${_mp_appr_count}.txt"
          print_info "  Approved: ${_mp_p_file}"
          ;;
        [Nn]|[Nn][Oo]|"")
          print_info "  Skipped: ${_mp_p_file}"
          ;;
        [Ff]|[Ff][Ee][Ee][Dd][Bb][Aa][Cc][Kk])
          echo "  What changes do you want? (press Enter twice when done)" >&2
          local _mp_this_fb="" _mp_empty_ct=0
          while IFS= read -r _mp_fb_line; do
            if [ -z "$_mp_fb_line" ]; then
              _mp_empty_ct=$((_mp_empty_ct + 1))
              [ "$_mp_empty_ct" -ge 2 ] && break
              _mp_this_fb="${_mp_this_fb}"$'\n'
            else
              _mp_empty_ct=0
              _mp_this_fb="${_mp_this_fb}${_mp_fb_line}"$'\n'
            fi
          done
          _mp_this_fb=$(printf '%s' "$_mp_this_fb" | sed 's/[[:space:]]*$//' || true)
          if [ -n "$_mp_this_fb" ]; then
            _mp_feedback_this_round="$_mp_this_fb"
            print_info "  Feedback captured — regenerating all proposals for ${_mp_doc}..."
            break
          else
            print_warning "  No feedback entered — please re-answer for proposal ${_mp_pi}" >&2
            continue
          fi
          ;;
        *)
          print_warning "  Unrecognized response '${_mp_input}' — please enter y, n, or f" >&2
          continue
          ;;
      esac
      _mp_pi=$((_mp_pi + 1))
    done

    rm -rf "$_mp_props_dir"

    if [ -n "$_mp_feedback_this_round" ]; then
      rm -rf "$_mp_appr_dir"
      _mp_had_feedback=1
      if [ -n "$_mp_accum_fb" ]; then
        _mp_accum_fb="${_mp_accum_fb}
---
${_mp_feedback_this_round}"
      else
        _mp_accum_fb="$_mp_feedback_this_round"
      fi
      continue
    fi

    if [ "$_mp_appr_count" -eq 0 ]; then
      print_info "No changes approved for ${_mp_doc} — nothing to apply"
      rm -rf "$_mp_appr_dir"
      local _mp_outcome_rej="rejected"
      [ "$_mp_had_feedback" -eq 1 ] && _mp_outcome_rej="feedback"
      _diag "DOC_PASS kind=${_mp_kind} doc=${_mp_doc} duration_s=${_mp_llm_elapsed_s} input_bytes=${_mp_input_bytes} outcome=${_mp_outcome_rej}"
      _docs_warn_doc_pass_threshold "$_mp_doc" "$_mp_llm_elapsed_s"
      return 0
    fi

    local _mp_apply_rc=0
    _docs_apply_approved \
      "$_mp_appr_dir" \
      "" \
      "" \
      "reconcile" \
      "$_mp_target" \
      "true" \
      "$_mp_entry_file" || _mp_apply_rc=$?
    rm -rf "$_mp_appr_dir"
    _diag "DOC_PASS kind=${_mp_kind} doc=${_mp_doc} duration_s=${_mp_llm_elapsed_s} input_bytes=${_mp_input_bytes} outcome=accepted"
    _docs_warn_doc_pass_threshold "$_mp_doc" "$_mp_llm_elapsed_s"
    return "$_mp_apply_rc"
  done

  local _mp_outcome_max="rejected"
  [ "$_mp_had_feedback" -eq 1 ] && _mp_outcome_max="feedback"
  _diag "DOC_PASS kind=${_mp_kind} doc=${_mp_doc} duration_s=${_mp_llm_elapsed_s} input_bytes=${_mp_input_bytes} outcome=${_mp_outcome_max}"
  _docs_warn_doc_pass_threshold "$_mp_doc" "$_mp_llm_elapsed_s"
  print_warning "Max proposal regeneration attempts reached for ${_mp_doc} — no changes applied"
  return 1
}

# ---------------------------------------------------------------------------
# _adr_approval_history_path
#
# Returns the path to the ADR drift approval history file.
# Human-editable; machine-readable markers drive suppression.
# Default: ${RITE_STATE_DIR}/adr-approval-history.md
# ---------------------------------------------------------------------------
_adr_approval_history_path() {
  local _aahp_state_dir="${RITE_STATE_DIR:-${RITE_PROJECT_ROOT:-${PWD}}/.rite/state}"
  printf '%s/adr-approval-history.md' "$_aahp_state_dir"
}

# ---------------------------------------------------------------------------
# _adr_approval_history_lookup DOC ASSERTION
#
# Returns 0 (suppressed) when the (DOC, ASSERTION) pair already has a recorded
# decision in the ADR approval history file.  Returns 1 when no entry found.
#
# Machine-readable marker format searched:
#   <!-- adrhist doc=<doc> assertion=<assertion> decision=<val> date=<date> -->
# ---------------------------------------------------------------------------
_adr_approval_history_lookup() {
  local _aahl_doc="${1:-}"
  local _aahl_assertion="${2:-}"
  [ -n "$_aahl_doc" ] || return 1

  local _aahl_hist_path
  _aahl_hist_path="$(_adr_approval_history_path)"
  [ -f "$_aahl_hist_path" ] || return 1

  local _aahl_norm="${_aahl_assertion//$'\t'/ }"
  _aahl_norm="${_aahl_norm//$'\n'/ }"

  local _aahl_line
  while IFS= read -r _aahl_line || [ -n "$_aahl_line" ]; do
    case "$_aahl_line" in
      "<!-- adrhist doc=${_aahl_doc} "*)
        if printf '%s' "$_aahl_line" | grep -qF "assertion=${_aahl_norm} decision=" 2>/dev/null; then
          return 0
        fi
        ;;
    esac
  done < "$_aahl_hist_path"
  return 1
}

# ---------------------------------------------------------------------------
# _adr_approval_history_record DOC ASSERTION DECISION RATIONALE
#
# Append one ADR approval record to the history file.
# Creates the file with a header block when absent.
#
# DECISION must be one of: addressed, rejected, deferred
# ---------------------------------------------------------------------------
_adr_approval_history_record() {
  local _aahr_doc="${1:-}"
  local _aahr_assertion="${2:-}"
  local _aahr_decision="${3:-rejected}"
  local _aahr_rationale="${4:-}"
  [ -n "$_aahr_doc" ] || return 1

  local _aahr_hist_path
  _aahr_hist_path="$(_adr_approval_history_path)"
  mkdir -p "$(dirname "$_aahr_hist_path")" 2>/dev/null || true

  if [ ! -f "$_aahr_hist_path" ]; then
    cat > "$_aahr_hist_path" << 'ADRHIST_HEADER_EOF'
# ADR Drift Approval History

<!-- Human-editable. Each entry records one decision per (doc, assertion) pair. -->
<!-- The machine-readable marker (<!-- adrhist ... -->) drives suppression in align-docs reconcile. -->

ADRHIST_HEADER_EOF
  fi

  local _aahr_norm="${_aahr_assertion//$'\t'/ }"
  _aahr_norm="${_aahr_norm//$'\n'/ }"

  local _aahr_date
  _aahr_date="$(date -u +%Y-%m-%d 2>/dev/null || echo 'unknown')"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: doc, assertion, decision, rationale, date vars must expand
  cat >> "$_aahr_hist_path" <<ADRHIST_RECORD_EOF
<!-- adrhist doc=${_aahr_doc} assertion=${_aahr_norm} decision=${_aahr_decision} date=${_aahr_date} -->
## ${_aahr_doc}

**Assertion**: ${_aahr_norm}
**Decision**: ${_aahr_decision}
**Date**: ${_aahr_date}
**Rationale**: ${_aahr_rationale:-none recorded}

ADRHIST_RECORD_EOF
}

# ---------------------------------------------------------------------------
# docs_reconcile_adr_drift
#
# Reconcile pending ADR drift observations (doc-drift-adr/) with history-aware
# suppression.  Run as part of `rite align-docs` reconcile.
#
# For each ADR doc with pending entries:
#   1. Skip entries already decided in the ADR approval history.
#   2. Present unsuppressed entries interactively via a y/r/s loop.
#   3. (y) Address: route through _docs_main_entries_pass for propose/approve
#      loop + docs-PR creation, then record the decision and remove the entry.
#   4. (r) Reject: record rejection (suppresses future re-ask) and remove the entry.
#   5. (s) Skip: leave the entry in place for the next reconcile.
#
# Non-TTY: print pending observations and exit (no prompts, no mutations).
# Zero entries → prints an info line and exits 0.
# ---------------------------------------------------------------------------
docs_reconcile_adr_drift() {
  local _ard_count=0
  if declare -f adr_drift_log_entry_count >/dev/null 2>&1; then
    _ard_count="$(adr_drift_log_entry_count --total || echo 0)"
  fi
  _ard_count="${_ard_count:-0}"

  if [ "$_ard_count" -eq 0 ]; then
    print_info "No ADR drift observations — nothing to reconcile"
    return 0
  fi

  print_info "Reconciling ${_ard_count} ADR observation(s)..."

  local _ard_adr_base="${RITE_STATE_DIR:-}/doc-drift-adr"
  [ -d "$_ard_adr_base" ] || return 0

  local _ard_entry_file
  while IFS= read -r _ard_entry_file <&3 || [ -n "${_ard_entry_file:-}" ]; do
    [ -f "$_ard_entry_file" ] || continue

    # Extract the doc path from the first entry in the file
    local _ard_doc
    _ard_doc="$(awk -F'\t' '{for(i=1;i<=NF;i++){if(substr($i,1,4)=="doc="){print substr($i,5); exit}}}' \
      "$_ard_entry_file" | head -1 || true)"
    [ -n "${_ard_doc:-}" ] || continue

    # Process each entry line in this file
    local _ard_line _ard_assertion _ard_kind
    while IFS= read -r _ard_line <&4 || [ -n "${_ard_line:-}" ]; do
      # Only process data lines (start with doc=)
      case "$_ard_line" in doc=*) ;; *) continue ;; esac

      _ard_assertion="$(printf '%s' "$_ard_line" \
        | awk -F'\t' '{for(i=1;i<=NF;i++){if(substr($i,1,10)=="assertion="){print substr($i,11); exit}}}' \
        || true)"
      _ard_kind="$(printf '%s' "$_ard_line" \
        | awk -F'\t' '{for(i=1;i<=NF;i++){if(substr($i,1,5)=="kind="){print substr($i,6); exit}}}' \
        || true)"

      # Suppress entries already decided in the approval history
      if _adr_approval_history_lookup "$_ard_doc" "${_ard_assertion:-}" 2>/dev/null; then
        print_info "  Already decided — skipping: ${_ard_assertion:-}"
        continue
      fi

      # Non-TTY: just report pending observations; no prompts
      if [ "${_RITE_FORCE_TTY:-0}" != "1" ] && [ ! -t 0 ]; then
        print_info "  Pending ADR observation (${_ard_kind:-unknown}) for ${_ard_doc}: ${_ard_assertion:-}"
        continue
      fi

      # TTY: interactive y/r/s loop
      echo "" >&2
      print_info "ADR observation for ${_ard_doc}"
      printf '  Kind: %s\n' "${_ard_kind:-unknown}" >&2
      printf '  Assertion: %s\n' "${_ard_assertion:-}" >&2
      echo "" >&2
      local _ard_reply=""
      read -p "  Address (y), Reject (r), Skip (s)? [y/r/s] " -n 1 -r
      echo "" >&2
      _ard_reply="${REPLY:-s}"

      case "${_ard_reply:-s}" in
        [Yy])
          # Write a temporary main-branch entry so _docs_main_entries_pass can
          # run the propose/approve loop for this ADR observation; remove it after.
          drift_log_append "$_ard_doc" "main" "-" "-" "${_ard_assertion:-}" \
            "${_ard_kind:-refinement}" "-" || true
          _docs_main_entries_pass "$_ard_doc" "main" "main" || true
          drift_log_remove_entry "$_ard_doc" "main" "${_ard_assertion:-}" || true
          _adr_approval_history_record "$_ard_doc" "${_ard_assertion:-}" \
            "addressed" "Reconciled via rite align-docs" || true
          adr_drift_log_remove_entry "$_ard_doc" "${_ard_assertion:-}" || true
          ;;
        [Rr])
          # Rejection: record so the same question is not re-asked
          _adr_approval_history_record "$_ard_doc" "${_ard_assertion:-}" \
            "rejected" "Rejected during rite align-docs reconcile" || true
          adr_drift_log_remove_entry "$_ard_doc" "${_ard_assertion:-}" || true
          ;;
        *)
          print_info "  Skipped — observation kept for next reconcile"
          ;;
      esac
    done 4< "$_ard_entry_file"
  done 3< <(find "$_ard_adr_base" -name '*.log' -type f 2>/dev/null | sort || true)
}

# ---------------------------------------------------------------------------
# docs_reconcile_drift
#
# Reconcile mode: run the Tier 2 doc-update pass over pending drift entries.
#
# Priority path: branch=main entries in the new structured store (RITE_STATE_DIR/
# doc-drift/main/).  Groups by doc and runs one bounded pass per doc via
# _docs_main_entries_pass (doc_update model, narrative+edits validation).
#
# Fallback path: legacy flat drift log (docs/sharkrite-drift-log.md) for
# entries recorded before the new schema (pre-#1425).
#
# Invoked from the reconcile offers in _docs_run_audit and rite_docs.
# Zero entries (either store) → prints an info line and exits 0.
# Entries for branches other than main are untouched.
# ---------------------------------------------------------------------------
docs_reconcile_drift() {
  # Priority: check for branch=main entries in the new structured store.
  local _rd_main_count=0
  if [ -n "${RITE_STATE_DIR:-}" ]; then
    _rd_main_count="$(drift_log_entry_count --branch main || echo 0)"
  fi

  if [ "$_rd_main_count" -gt 0 ]; then
    print_info "Reconciling ${_rd_main_count} drift entr$([ "$_rd_main_count" -eq 1 ] && echo 'y' || echo 'ies') for branch=main..."
    docs_map_ensure || true
    local _rd_doc
    while IFS= read -r _rd_doc <&3 || [ -n "${_rd_doc:-}" ]; do
      [ -n "$_rd_doc" ] || continue
      echo "" >&2
      print_info "Processing doc: ${_rd_doc}"
      _docs_main_entries_pass "$_rd_doc" || true
    done 3< <(_docs_list_main_entry_docs || true)
    # Also reconcile ADR drift observations after the main entry pass
    docs_reconcile_adr_drift || true
    return 0
  fi

  # Fallback: legacy flat drift log (pre-#1425 entries).
  local _rd_drift_path
  _rd_drift_path="$(drift_log_path 2>/dev/null || true)"

  if [ -z "$_rd_drift_path" ] || [ ! -f "$_rd_drift_path" ]; then
    print_info "No drift log found — nothing to reconcile"
    docs_reconcile_adr_drift || true
    return 0
  fi

  local _rd_count
  _rd_count="$(drift_log_entry_count "$_rd_drift_path" || echo "0")"

  if [ "$_rd_count" -eq 0 ]; then
    print_info "Drift log is empty — nothing to reconcile"
    docs_reconcile_adr_drift || true
    return 0
  fi

  print_info "Reconciling ${_rd_count} drift entr$([ "$_rd_count" -eq 1 ] && echo 'y' || echo 'ies') from flat log..."
  docs_map_ensure || true
  _docs_update_engine "reconcile" ""

  # Always run ADR drift reconcile after the regular reconcile pass
  docs_reconcile_adr_drift || true
}

# _docs_enable_flow was removed — consent is now owned by `rite align-docs`.

# ---------------------------------------------------------------------------
# _docs_run_audit [mode]
#
# Audit mode: verify mapped docs against current code via the doc_assessment
# role, then report (and optionally append to drift log in changelog mode).
#
# Arguments:
#   $1  effective state — "sync" or "changelog"
#
# LLM calls: provider_run_prompt_with_timeout with provider_resolve_model doc_assessment
# ---------------------------------------------------------------------------
_docs_run_audit() {
  local state="${1:-changelog}"

  # Ensure map exists before attempting the audit
  _docs_ensure_map || return 1

  local map_file
  map_file="$(docs_map_path)"

  # Build inventory: collect unique doc file paths from the map
  local _inventory_paths=""
  local _line
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in '#'*) continue ;; esac
    local _path
    _path="$(echo "$_line" | cut -f1 || true)"
    [ -z "$_path" ] && continue
    # Add only new paths (whole-line de-duplicate — newline anchors prevent substring collision)
    case $'\n'"$_inventory_paths"$'\n' in
      *$'\n'"$_path"$'\n'*) ;;
      *) _inventory_paths="${_inventory_paths}${_path}"$'\n' ;;
    esac
  done < "$map_file"
  _inventory_paths="${_inventory_paths%$'\n'}"

  if [ -z "$_inventory_paths" ]; then
    print_info "Docs map is empty — no docs to audit"
    return 0
  fi

  # Build map inventory section for the prompt (file + headings)
  local _map_context=""
  local _total_bytes=0
  local _byte_cap=40000
  local _doc_path
  while IFS= read -r _doc_path || [ -n "$_doc_path" ]; do
    [ -z "$_doc_path" ] && continue
    local _abs="${RITE_PROJECT_ROOT}/${_doc_path}"
    [ -f "$_abs" ] || continue

    # Collect headings for this doc from the map
    local _headings=""
    local _map_row
    while IFS= read -r _map_row || [ -n "$_map_row" ]; do
      case "$_map_row" in '#'*) continue ;; esac
      local _row_path _h_text
      _row_path="$(echo "$_map_row" | cut -f1 || true)"
      _h_text="$(echo "$_map_row" | cut -f5 || true)"
      [ "$_row_path" = "$_doc_path" ] && [ -n "$_h_text" ] && \
        _headings="${_headings}  - ${_h_text}"$'\n'
    done < "$map_file"

    # Read a capped excerpt of the doc content
    local _doc_excerpt
    _doc_excerpt="$(head -c 3000 "$_abs" 2>/dev/null || true)"

    local _entry="--- ${_doc_path} ---
Headings:
${_headings}Content excerpt:
${_doc_excerpt}

"
    local _entry_len="${#_entry}"
    _total_bytes=$((_total_bytes + _entry_len))
    if [ "$_total_bytes" -gt "$_byte_cap" ]; then
      _map_context="${_map_context}(remaining docs omitted — byte cap reached)
"
      break
    fi
    _map_context="${_map_context}${_entry}"
  done <<EOF_PATHS
$_inventory_paths
EOF_PATHS

  # Gather recent git log summary for code-change context
  local _recent_log
  _recent_log="$(git -C "$RITE_PROJECT_ROOT" log --oneline -20 2>/dev/null || true)"

  # Build the audit prompt
  local _prompt_file
  _prompt_file="$(mktemp)"
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: doc path and context vars must expand
  cat > "$_prompt_file" <<AUDIT_EOF
You are a documentation accuracy auditor. Review the documentation files below
and identify sections that may be inaccurate or outdated given the recent code
changes shown in the git log.

For each potential inaccuracy, output EXACTLY ONE line in this format:
DRIFT: <doc_path> — "<section_heading>" — <one_line_suspected_inaccuracy>

Use the exact section heading text from the doc's Headings list.
If no inaccuracies are found, output: NOTHING_FOUND

Recent git changes:
${_recent_log}

Documentation inventory:
${_map_context}
AUDIT_EOF

  local _doc_count
  _doc_count=$(printf '%s\n' "$_inventory_paths" | grep -c '.' || true)
  print_info "Auditing ${_doc_count} doc(s) via doc_assessment model..."

  local _timeout="${RITE_DOC_ASSESSMENT_TIMEOUT:-300}"
  local _audit_output _audit_exit
  _audit_exit=0
  _audit_output="$(provider_run_prompt_with_timeout "$(cat "$_prompt_file")" \
    "$(provider_resolve_model doc_assessment)" true "$_timeout" 2>/dev/null)" \
    || _audit_exit=$?
  rm -f "$_prompt_file"

  if [ "$_audit_exit" -eq 124 ]; then
    print_warning "Audit timed out after ${_timeout}s — cannot determine drift" >&2
    return 1
  elif [ "$_audit_exit" -ne 0 ]; then
    print_warning "Audit provider call failed (exit ${_audit_exit}) — cannot determine drift" >&2
    return 1
  fi

  if [ -z "$_audit_output" ]; then
    print_warning "Audit returned empty output (exit 0) — cannot determine drift" >&2
    return 1
  fi

  if echo "$_audit_output" | grep -q "^NOTHING_FOUND"; then
    print_info "Audit complete — no drift detected"
    return 0
  fi

  # Parse DRIFT: lines into structured findings
  local _finding_count=0
  local _implicated_docs_block=""
  local _suspected_all=""
  local _audit_line
  while IFS= read -r _audit_line || [ -n "$_audit_line" ]; do
    case "$_audit_line" in
      DRIFT:*)
        # Format: DRIFT: path — "section" — inaccuracy
        local _rest="${_audit_line#DRIFT: }"
        local _drift_path="${_rest%% —*}"
        local _drift_rest="${_rest#*— }"
        local _section="${_drift_rest%% —*}"
        # Quoted-pattern form ('"' not \") — a backslash-escaped quote inside
        # ${} inside "" leaves a stray } after the lint brace-counter's quote
        # stripping, false-flagging every later `local` as outside-function
        # (Rule 07 heuristic gap; same class as promotion-composer, #1095).
        _section="${_section#'"'}"
        _section="${_section%'"'}"
        local _suspected="${_drift_rest#*— }"
        _implicated_docs_block="${_implicated_docs_block}- ${_drift_path} — \"${_section}\""$'\n'
        if [ -n "$_suspected_all" ]; then
          _suspected_all="${_suspected_all}; ${_suspected}"
        else
          _suspected_all="$_suspected"
        fi
        _finding_count=$((_finding_count + 1))
        ;;
    esac
  done <<EOF_AUDIT
$_audit_output
EOF_AUDIT

  if [ "$_finding_count" -eq 0 ]; then
    print_info "Audit complete — no drift detected"
    return 0
  fi

  _implicated_docs_block="${_implicated_docs_block%$'\n'}"

  echo ""
  print_info "Audit found $_finding_count potential drift finding(s):"
  echo ""
  echo "$_implicated_docs_block"
  echo ""

  if [ "$state" = "changelog" ]; then
    # Append to drift log (pr:0 = audit-triggered, not PR-triggered)
    drift_log_append "0" "-" "(on-demand audit)" "$_implicated_docs_block" \
      "${_suspected_all:-On-demand audit via rite docs — $_finding_count potential inaccuracy(ies)}" || true
    print_info "Findings recorded in drift log"

    # Tail-offer: switch to sync and reconcile?
    echo ""
    local _enable_reply="N"
    if [ -t 0 ]; then
      read -p "  Reconcile these $_finding_count entries now? [y/N] " -n 1 -r
      echo
      _enable_reply="${REPLY:-N}"
    fi
    if [[ "$_enable_reply" =~ ^[Yy]$ ]]; then
      # Reconciling here is the opt-in to the interactive loop: move the
      # repo from legacy changelog to sync, then run it.
      record_doc_mode "sync"
      docs_reconcile_drift || true
    fi
  else
    # sync mode: drift reported — offer to reconcile via the engine
    docs_reconcile_drift || true
  fi
}

# ---------------------------------------------------------------------------
# docs_resume_proposal BRANCH
#
# Resume a saved doc proposal created by a terminal-less promote run.
#
# Loads ${RITE_STATE_DIR}/doc-proposal-${safe_branch}.md, runs each listed
# doc through _docs_main_entries_pass (the same y/n/f approval loop used in
# the TTY promote path), then removes the proposal file after the loop
# completes.
#
# Missing proposal file → return 1 listing ${RITE_STATE_DIR}/doc-proposal-*.md
# candidates so the operator knows what is available.
#
# Slash-containing branch names are resolved via the safe-name convention
# (slashes replaced with dashes) used when the file was originally saved.
# The original branch name is recovered from the proposal-file header so
# _docs_main_entries_pass reads the correct drift entry store.
# ---------------------------------------------------------------------------
docs_resume_proposal() {
  local _rp_branch="${1:-}"
  if [ -z "$_rp_branch" ]; then
    print_error "rite docs --resume requires a branch name"
    echo "  Usage: rite docs --resume <branch>" >&2
    return 1
  fi

  local _rp_safe="${_rp_branch//\//-}"
  local _rp_state_dir="${RITE_STATE_DIR:-${RITE_PROJECT_ROOT}/.rite/state}"
  local _rp_proposal="${_rp_state_dir}/doc-proposal-${_rp_safe}.md"

  if [ ! -f "$_rp_proposal" ]; then
    print_error "No saved proposal for branch '${_rp_branch}' (expected: ${_rp_proposal})"
    local _rp_candidates
    _rp_candidates="$(find "$_rp_state_dir" -name 'doc-proposal-*.md' -type f 2>/dev/null | sort || true)"
    if [ -n "$_rp_candidates" ]; then
      echo "  Saved proposals available:" >&2
      local _rp_c
      while IFS= read -r _rp_c || [ -n "$_rp_c" ]; do
        [ -n "$_rp_c" ] || continue
        printf '    %s\n' "$_rp_c" >&2
      done <<CAND_EOF
$_rp_candidates
CAND_EOF
    else
      printf '  No saved proposals found in %s\n' "$_rp_state_dir" >&2
    fi
    return 1
  fi

  # Require a terminal — the approval loop is meaningless without one; a
  # non-TTY run would auto-skip everything then destroy the proposal file.
  # _RITE_FORCE_TTY=1 allows tests to exercise this path without a real terminal.
  if [ "${_RITE_FORCE_TTY:-0}" != "1" ] && [ ! -t 0 ]; then
    print_error "rite docs --resume requires a terminal (no TTY detected)"
    printf '  Proposal preserved at: %s\n' "$_rp_proposal" >&2
    return 1
  fi

  # Recover original branch name (may contain slashes) from the file header.
  local _rp_file_branch
  _rp_file_branch="$(grep '^# Pending doc proposal:' "$_rp_proposal" | head -1 | \
    sed 's/^# Pending doc proposal: //' || true)"
  _rp_file_branch="${_rp_file_branch:-${_rp_branch}}"

  print_info "Resuming doc proposal for branch '${_rp_file_branch}'"

  # Parse doc list: lines matching "- <path>" under the "Docs with pending entries:" header.
  local _rp_docs="" _rp_in_list=0 _rp_dl
  while IFS= read -r _rp_dl || [ -n "$_rp_dl" ]; do
    case "$_rp_dl" in
      "Docs with pending entries:") _rp_in_list=1 ;;
      "- "*)
        [ "$_rp_in_list" = "1" ] && _rp_docs="${_rp_docs}${_rp_dl#- }"$'\n'
        ;;
      "") _rp_in_list=0 ;;
    esac
  done < "$_rp_proposal"

  if [ -z "$_rp_docs" ]; then
    print_warning "No docs listed in proposal file — format drift suspected; proposal preserved at: ${_rp_proposal}"
    return 1
  fi

  docs_map_ensure || true

  # Use fd 3 for the doc list so fd 0 (stdin/TTY) stays available for
  # interactive read prompts inside _docs_main_entries_pass.
  local _rp_tmp _rp_doc _rp_failed=0
  _rp_tmp="$(mktemp)"
  printf '%s' "$_rp_docs" > "$_rp_tmp"
  while IFS= read -r _rp_doc <&3 || [ -n "${_rp_doc:-}" ]; do
    [ -n "$_rp_doc" ] || continue
    echo "" >&2
    print_info "Processing doc: ${_rp_doc}"
    _docs_main_entries_pass "$_rp_doc" "$_rp_file_branch" "main" || _rp_failed=1
  done 3< "$_rp_tmp"
  rm -f "$_rp_tmp"

  if [ "$_rp_failed" = "1" ]; then
    print_warning "One or more docs failed to process — proposal preserved at: ${_rp_proposal}"
    return 1
  fi

  rm -f "$_rp_proposal"
  print_success "Doc resume complete for branch '${_rp_file_branch}' — proposal file removed"
  return 0
}

# ---------------------------------------------------------------------------
# _docs_jic_covers_for_doc DOC
#
# Emit the fingerprint set for doc DOC — the union of paths that, if changed,
# would plausibly affect this doc's accuracy.  Used by the cross-doc
# just-in-case pass to compute the deterministic intersection with a
# promotion diff before any model is consulted.
#
# Emits one path per line (deduplicated):
#   1. Enforcing bats file paths (from sharkrite-enforced-by markers in doc)
#   2. Source paths from those bats files' sharkrite-test-covers: headers
#      (function-scope suffix stripped: lib/foo.sh::func → lib/foo.sh)
#   3. ADR-linked doc paths for this doc (via docs_map_adr_links)
#
# Returns 0 with empty output when no fingerprint data is available.
# ---------------------------------------------------------------------------
_docs_jic_covers_for_doc() {
  local _jc_doc="$1"
  local _jc_project_root="${RITE_PROJECT_ROOT:-.}"

  # Use a temp file to accumulate paths before deduplication so the caller
  # sees a clean deduplicated stream without a nested function.
  local _jc_tmp=""
  _jc_tmp="$(mktemp "${TMPDIR:-/tmp}/rite_jic_XXXXXX" 2>/dev/null)" || return 0

  # 1+2: enforcing tests (from sharkrite-enforced-by markers) and their covers paths
  local _jc_bats
  while IFS= read -r _jc_bats || [ -n "${_jc_bats:-}" ]; do
    [ -n "$_jc_bats" ] || continue
    _jc_bats="${_jc_bats#./}"
    printf '%s\n' "$_jc_bats" >> "$_jc_tmp"

    # resolve bats file to absolute path for reading
    local _jc_bats_abs
    case "$_jc_bats" in
      /*) _jc_bats_abs="$_jc_bats" ;;
      *)  _jc_bats_abs="${_jc_project_root}/${_jc_bats}" ;;
    esac
    [ -f "$_jc_bats_abs" ] || continue

    # read sharkrite-test-covers: header (first 15 lines)
    local _jc_header
    # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_TEST_COVERS is a marker constant defined in markers.sh; _RITE_ prefix cannot be used; ledger frozen
    _jc_header="$(head -15 "$_jc_bats_abs" 2>/dev/null \
      | grep -E "^# ${RITE_MARKER_TEST_COVERS}:" \
      | head -1 \
      | sed -E "s/^# ${RITE_MARKER_TEST_COVERS}:[[:space:]]*//" || true)"
    [ -n "$_jc_header" ] || continue

    # Split comma-separated paths, strip function-scope suffix (::func)
    local _jc_entry
    while IFS= read -r _jc_entry || [ -n "${_jc_entry:-}" ]; do
      [ -n "$_jc_entry" ] || continue
      _jc_entry="$(printf '%s' "$_jc_entry" \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
      [ -n "$_jc_entry" ] || continue
      _jc_entry="${_jc_entry%%::*}"
      [ -n "$_jc_entry" ] || continue
      printf '%s\n' "$_jc_entry" >> "$_jc_tmp"
    done < <(printf '%s\n' "$_jc_header" | tr ',' '\n' || true)
  done < <(docs_map_enforcing_tests "$_jc_doc" 2>/dev/null || true)

  # 3: ADR-linked doc paths (docs_map_adr_links works on any markdown, not just ADRs)
  local _jc_link
  while IFS= read -r _jc_link || [ -n "${_jc_link:-}" ]; do
    [ -n "$_jc_link" ] || continue
    printf '%s\n' "${_jc_link#./}" >> "$_jc_tmp"
  done < <(docs_map_adr_links "$_jc_doc" 2>/dev/null || true)

  # Emit deduplicated paths then clean up (|| true: empty file is fine)
  sort -u "$_jc_tmp" 2>/dev/null || true
  rm -f "$_jc_tmp"
  return 0
}

# ---------------------------------------------------------------------------
# _docs_cross_doc_just_in_case_pass BRANCH PR DIFF_NEWLINE
#
# Cross-doc just-in-case drift detector.  Called from docs_run_promote_doc_pass
# after the primary declared-doc pass completes.
#
# Intersection stage (zero model calls):
#   For every doc in the map that does NOT already have drift entries for BRANCH,
#   compute its fingerprint set (_docs_jic_covers_for_doc) and intersect it with
#   DIFF_NEWLINE.  Docs with a non-empty intersection form the residue.
#
# If residue is empty → return 0 with no provider invocation.
#
# Triage stage (one bounded model call):
#   Send all (doc, evidence) residue pairs to provider_resolve_model triage in a
#   single call.  Parse the JSON response; write a drift entry for every doc
#   where the model returns implicated=true.
#
# Contract:
#   - Never proposes or applies edits to any doc — entries only.
#   - Declared docs (those already in the drift store for BRANCH) are excluded.
#   - The ADR is NOT excluded — it may receive entries but never edits.
#   - All failures warn and return 0 (best-effort, never blocks promote).
#   - No bare `exit`.
# ---------------------------------------------------------------------------
_docs_cross_doc_just_in_case_pass() {
  local _ji_branch="${1:?_docs_cross_doc_just_in_case_pass: branch required}"
  local _ji_pr="${2:-}"
  local _ji_diff="${3:-}"

  # Guard: no diff → nothing to intersect
  [ -n "${_ji_diff:-}" ] || return 0

  # Guard: map required
  local _ji_map
  _ji_map="$(docs_map_path)"
  [ -f "$_ji_map" ] || return 0

  # Guard: provider required for the triage stage
  if ! declare -f provider_run_prompt_with_timeout >/dev/null 2>&1 || \
     ! declare -f provider_resolve_model >/dev/null 2>&1; then
    # Provider not loaded; skip silently — caller must load provider first
    return 0
  fi

  # Get docs already processed by the main pass (the "declared docs")
  local _ji_declared_docs=""
  _ji_declared_docs="$(_docs_list_branch_entry_docs "$_ji_branch" 2>/dev/null || true)"

  # Enumerate all unique docs in the map (column 1, skip comment header)
  local _ji_all_docs=""
  _ji_all_docs="$(awk -F'\t' 'NR>1 && !/^#/ && $1!="" {print $1}' "$_ji_map" \
    | sort -u 2>/dev/null || true)"
  [ -n "${_ji_all_docs:-}" ] || return 0

  # ── Intersection stage (zero model calls) ─────────────────────────────────
  # _ji_residue: newline-separated "doc|evidence" pairs where evidence is
  # comma-separated matched paths
  local _ji_residue=""

  local _ji_doc
  while IFS= read -r _ji_doc || [ -n "${_ji_doc:-}" ]; do
    [ -n "$_ji_doc" ] || continue

    # Skip declared docs — already handled by the main pass
    if printf '%s\n' "${_ji_declared_docs:-}" | grep -qxF "$_ji_doc"; then
      continue
    fi

    # Build fingerprint set for this doc
    local _ji_fp_set=""
    _ji_fp_set="$(_docs_jic_covers_for_doc "$_ji_doc" 2>/dev/null || true)"
    [ -n "${_ji_fp_set:-}" ] || continue

    # Intersect fingerprint set with diff — supports exact paths and glob patterns
    # (grep -qxF would reject globs like lib/core/** that covers headers legitimately emit)
    local _ji_hits=""
    local _ji_fp
    while IFS= read -r _ji_fp || [ -n "${_ji_fp:-}" ]; do
      [ -n "$_ji_fp" ] || continue
      local _ji_fp_hit=0
      local _ji_dp
      while IFS= read -r _ji_dp || [ -n "${_ji_dp:-}" ]; do
        [ -n "$_ji_dp" ] || continue
        # case with unquoted pattern enables glob expansion (e.g. lib/core/**)
        # shellcheck disable=SC2254
        case "$_ji_dp" in
          $_ji_fp) _ji_fp_hit=1; break ;;
        esac
      done < <(printf '%s\n' "$_ji_diff")
      if [ "$_ji_fp_hit" -eq 1 ]; then
        if [ -n "${_ji_hits:-}" ]; then
          _ji_hits="${_ji_hits},${_ji_fp}"
        else
          _ji_hits="$_ji_fp"
        fi
      fi
    done < <(printf '%s\n' "$_ji_fp_set")

    [ -n "${_ji_hits:-}" ] || continue

    if [ -n "${_ji_residue:-}" ]; then
      _ji_residue="${_ji_residue}
${_ji_doc}|${_ji_hits}"
    else
      _ji_residue="${_ji_doc}|${_ji_hits}"
    fi
  done < <(printf '%s\n' "$_ji_all_docs")

  # Clean intersection → no model call
  [ -n "${_ji_residue:-}" ] || return 0

  # ── Triage stage (one bounded model call) ──────────────────────────────────
  local _ji_timeout="${RITE_DOC_CLAUDE_TIMEOUT:-30}"
  local _ji_diff_summary
  _ji_diff_summary="$(printf '%s\n' "$_ji_diff" | head -20 || true)"

  local _ji_prompt
  _ji_prompt="You are a documentation drift classifier.

A promotion PR (#${_ji_pr:-unknown}) merged these files (up to 20 shown):
${_ji_diff_summary}

The following docs may be affected (doc path | intersecting evidence files):
${_ji_residue}

For each doc, decide: does the evidence suggest this doc may need a drift entry?
Output a JSON array with one object per doc:
[
  {
    \"doc\": \"docs/path/to/doc.md\",
    \"implicated\": true,
    \"kind\": \"test-scope\",
    \"assertion\": \"one-sentence description of what may be stale (max 120 chars)\"
  }
]

kind must be one of: addition, refinement, contradiction, test-scope, reference-missing
- test-scope: only a test file changed (testing strategy may need doc update)
- contradiction: a behavior-defining source file changed in a way that may contradict the doc
- addition: new behavior was added that the doc should describe
- refinement: an assertion may need clarifying wording
- reference-missing: a referenced doc or linked file changed
If a hit is unlikely to cause genuine drift in that doc, set implicated=false.
Output ONLY the JSON array, no prose."

  local _ji_input_bytes="${#_ji_prompt}"
  local _ji_call_start _ji_call_end _ji_call_elapsed
  _ji_call_start=$(date +%s)
  local _ji_raw=""
  local _ji_triage_exit=0
  _ji_raw="$(provider_run_prompt_with_timeout \
    "$_ji_prompt" \
    "$(provider_resolve_model triage)" \
    true \
    "$_ji_timeout" \
    2>/dev/null)" || _ji_triage_exit=$?
  _ji_call_end=$(date +%s)
  _ji_call_elapsed=$((_ji_call_end - _ji_call_start))

  if [ "$_ji_triage_exit" -ne 0 ] || [ -z "${_ji_raw:-}" ]; then
    print_warning "Just-in-case pass: triage call failed (exit ${_ji_triage_exit}) — no cross-doc entries written" >&2
    _diag "DOC_PASS kind=promote doc=- duration_s=${_ji_call_elapsed} input_bytes=${_ji_input_bytes} outcome=rejected"
    _docs_warn_doc_pass_threshold "-" "$_ji_call_elapsed"
    return 0
  fi

  # Strip fenced JSON if present (models wrap output in ```json...```)
  local _ji_clean
  _ji_clean="$(printf '%s' "$_ji_raw" | sed 's/^```[a-zA-Z]*$//' | sed 's/^```$//' || true)"
  [ -n "${_ji_clean:-}" ] || _ji_clean="$_ji_raw"

  # Parse and write entries
  if ! command -v jq >/dev/null 2>&1; then
    print_warning "Just-in-case pass: jq not available — cannot parse triage response" >&2
    _diag "DOC_PASS kind=promote doc=- duration_s=${_ji_call_elapsed} input_bytes=${_ji_input_bytes} outcome=rejected"
    return 0
  fi

  local _ji_entry_count=0
  local _ji_jq_out=""
  local _ji_jq_exit=0
  _ji_jq_out="$(printf '%s' "$_ji_clean" \
    | jq -r '.[] | select(.implicated == true) | "\(.doc)\t\(.kind)\t\(.assertion)"' \
    2>/dev/null)" || _ji_jq_exit=$?

  if [ "$_ji_jq_exit" -ne 0 ]; then
    print_warning "Just-in-case pass: triage response unparseable (jq exit ${_ji_jq_exit}) — findings discarded" >&2
    return 0
  fi

  [ -n "${_ji_jq_out:-}" ] || return 0

  local _ji_rec
  while IFS= read -r _ji_rec || [ -n "${_ji_rec:-}" ]; do
    [ -n "$_ji_rec" ] || continue
    local _ji_rec_doc _ji_rec_kind _ji_rec_assert
    _ji_rec_doc="$(printf '%s' "$_ji_rec" | cut -f1 || true)"
    _ji_rec_kind="$(printf '%s' "$_ji_rec" | cut -f2 || true)"
    _ji_rec_assert="$(printf '%s' "$_ji_rec" | cut -f3- || true)"
    [ -n "${_ji_rec_doc:-}" ] || continue
    # Validate kind — drift_log_append rejects invalid kinds anyway but guard early
    case "${_ji_rec_kind:-}" in
      addition|refinement|contradiction|test-scope|reference-missing) ;;
      *) _ji_rec_kind="refinement" ;;
    esac
    # ADR docs: route to the ADR namespace — never edits at promote time.
    # Non-ADR docs: write to the regular branch drift store.
    if _docs_is_adr_in_map "$_ji_rec_doc" 2>/dev/null; then
      adr_drift_log_append \
        "$_ji_rec_doc" \
        "${_ji_pr:-}" \
        "-" \
        "${_ji_rec_assert:-just-in-case cross-doc hit}" \
        "$_ji_rec_kind" \
        "promote cross-doc pass: promotion diff intersected doc fingerprint set" \
        2>/dev/null || true
    else
      drift_log_append \
        "$_ji_rec_doc" \
        "$_ji_branch" \
        "${_ji_pr:-}" \
        "-" \
        "${_ji_rec_assert:-just-in-case cross-doc hit}" \
        "$_ji_rec_kind" \
        "promote cross-doc pass: promotion diff intersected doc fingerprint set" \
        2>/dev/null || true
    fi
    _ji_entry_count=$((_ji_entry_count + 1))
  done < <(printf '%s\n' "$_ji_jq_out")

  if [ "$_ji_entry_count" -gt 0 ]; then
    print_info "Just-in-case pass: ${_ji_entry_count} cross-doc entr$([ "$_ji_entry_count" -eq 1 ] && echo 'y' || echo 'ies') written"
  else
    print_info "Just-in-case pass: triage found no implicated cross-docs"
  fi

  local _ji_outcome="rejected"
  [ "$_ji_entry_count" -gt 0 ] && _ji_outcome="accepted"
  _diag "DOC_PASS kind=promote doc=- duration_s=${_ji_call_elapsed} input_bytes=${_ji_input_bytes} outcome=${_ji_outcome}"
  _docs_warn_doc_pass_threshold "-" "$_ji_call_elapsed"
  return 0
}

# ---------------------------------------------------------------------------
# docs_run_promote_doc_pass BRANCH [PR]
#
# Tier 2 post-merge doc pass for a completed promotion.  Called from
# promote-branch.sh Phase 8 after the squash merge succeeds.
#
# Reads structured drift entries for BRANCH from RITE_STATE_DIR/doc-drift/<branch>/.
# The docs PR always targets main (independent of RITE_TARGET_BRANCH, which may
# still point at the now-deleted integration branch).
#
# TTY attached:     runs the interactive propose/approve loop per doc via
#                   _docs_main_entries_pass.
# No TTY attached:  saves a proposal summary to
#                   ${RITE_STATE_DIR}/doc-proposal-<branch-safe>.md and prints
#                   the exact resume command so the operator can act later.
#
# Contract (§ #1435):
#   - Doc rejection never blocks anything — the code already merged.
#   - At most one doc update per promotion (one docs PR per doc).
#   - All failures warn and return 0 — promote's exit code is never altered.
#   - No bare `exit`.
#   - After the declared-doc pass, runs _docs_cross_doc_just_in_case_pass
#     (best-effort, entries only, never edits or prompts).
# ---------------------------------------------------------------------------
docs_run_promote_doc_pass() {
  local _dp_branch="${1:?docs_run_promote_doc_pass: branch required}"
  local _dp_pr="${2:-}"

  # Capture the promotion diff now.  The squash-merge happened via GitHub API so
  # the local HEAD may be stale — fetch origin/main first so the diff reflects
  # the actual squash-merge commit, not whatever was checked out locally.
  local _dp_diff=""
  git -C "${RITE_PROJECT_ROOT:-.}" fetch origin main --quiet 2>/dev/null || true
  _dp_diff="$(git -C "${RITE_PROJECT_ROOT:-.}" diff origin/main~1..origin/main --name-only 2>/dev/null || true)"

  docs_map_ensure || true  # best-effort; engine can proceed with stale/missing map

  # Count entries for this branch; skip declared-doc pass when nothing to do.
  local _dp_count=0
  _dp_count="$(drift_log_entry_count --branch "$_dp_branch" || echo 0)"
  _dp_count="${_dp_count:-0}"

  if [ "$_dp_count" -gt 0 ]; then
    print_info "Tier 2 doc pass for branch '${_dp_branch}' (${_dp_count} entr$([ "$_dp_count" -eq 1 ] && echo 'y' || echo 'ies'))..."

    local _dp_docs=""
    _dp_docs="$(_docs_list_branch_entry_docs "$_dp_branch" || true)"

    if [ -n "${_dp_docs:-}" ]; then
      # _RITE_FORCE_TTY=1 allows tests to exercise the TTY branch without a real terminal.
      if [ "${_RITE_FORCE_TTY:-0}" = "1" ] || [ -t 0 ]; then
        # TTY: run the interactive propose/approve loop for each implicated doc.
        # _mp_target is explicitly "main" so the docs PR is not routed to the
        # now-deleted integration branch.
        # Use fd 3 for the doc list so fd 0 (stdin/TTY) remains available for
        # interactive read prompts inside _docs_main_entries_pass.
        local _dp_doc
        while IFS= read -r _dp_doc <&3 || [ -n "${_dp_doc:-}" ]; do
          [ -n "$_dp_doc" ] || continue
          # ADR docs must never be edited at promote — a wrong ADR edit is a wrong
          # product. ADR observations go to the ADR namespace (doc-drift-adr/) via
          # _docs_cross_doc_just_in_case_pass and are reconciled by docs_reconcile_adr_drift.
          if _docs_is_adr_in_map "$_dp_doc" 2>/dev/null; then
            print_info "  ADR doc ${_dp_doc}: observations in ADR namespace — skipping promote edit pass"
            continue
          fi
          echo "" >&2
          print_info "Processing doc: ${_dp_doc}"
          _docs_main_entries_pass "$_dp_doc" "$_dp_branch" "main" "promote" || true
        done 3< <(_docs_list_branch_entry_docs "$_dp_branch" || true)
      else
        # No TTY: save a proposal summary so the operator can review and apply
        # with `rite docs --resume <branch>` (loading implemented in the next issue).
        local _dp_safe_branch="${_dp_branch//\//-}"
        local _dp_proposal="${RITE_STATE_DIR:-}/doc-proposal-${_dp_safe_branch}.md"
        mkdir -p "$(dirname "$_dp_proposal")" 2>/dev/null || true
        local _dp_write_ok=0
        {
          printf '# Pending doc proposal: %s\n\n' "$_dp_branch"
          printf 'Recorded: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
          printf 'Drift entries: %s\n\n' "$_dp_count"
          printf 'Docs with pending entries:\n'
          local _dp_d
          while IFS= read -r _dp_d || [ -n "$_dp_d" ]; do
            [ -n "$_dp_d" ] || continue
            printf -- '- %s\n' "$_dp_d"
          done <<DOCS_EOF
$_dp_docs
DOCS_EOF
        } > "$_dp_proposal" 2>/dev/null && _dp_write_ok=1 || true
        if [ "$_dp_write_ok" = "1" ]; then
          print_info "Promote doc proposal saved — review when ready"
          printf '\n  Run: rite docs --resume %s\n' "$_dp_branch" >&2
        else
          print_warning "Could not write doc proposal to '${_dp_proposal}' — drift entries remain for manual review" >&2
        fi
      fi
    else
      print_info "No doc entries found for branch '${_dp_branch}'"
    fi
  else
    print_info "No drift entries for branch '${_dp_branch}' — skipping declared-doc pass"
  fi

  # ── Cross-doc just-in-case pass (§ #1435) ─────────────────────────────────
  # Runs after the declared-doc pass, even when that pass found nothing.
  # Best-effort: failures warn and return 0.
  if [ -n "${_dp_diff:-}" ]; then
    _docs_cross_doc_just_in_case_pass "$_dp_branch" "${_dp_pr:-}" "$_dp_diff" || true
  fi

  return 0
}

# ---------------------------------------------------------------------------
# docs_resolve_doc_scope [name ...]
#
# Resolve zero or more doc name arguments against the docs map, emitting one
# resolved project-relative path per line on stdout.
#
# No args:      echoes every unique file path in the map.
# With args:    each name is accepted with or without the .md extension and
#               matched by basename; results are deduped.
# Unknown name: prints an error and closest candidates to stderr; exits 1.
#               Never auto-adopts a candidate — block with instructions.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2120
docs_resolve_doc_scope() {
  docs_map_ensure || true
  local _rs_map_file
  _rs_map_file="$(docs_map_path)"

  # Collect all unique doc paths from the map (column 1, skip header/comments).
  local _rs_all_docs=""
  if [ -f "$_rs_map_file" ]; then
    _rs_all_docs="$(awk -F'\t' '/^#/{next} NF>=1 && $1!=""{print $1}' "$_rs_map_file" \
      | sort -u || true)"
  fi

  # No args: return everything in the map.
  if [ "$#" -eq 0 ]; then
    printf '%s\n' "$_rs_all_docs"
    return 0
  fi

  local _rs_resolved=""

  local _rs_arg
  for _rs_arg in "$@"; do
    # Guard empty or whitespace-only arg.
    case "$_rs_arg" in
      "") continue ;;
      *[[:space:]]*)
        printf 'error: doc name "%s" contains whitespace — did you mean to quote two separate names?\n' "$_rs_arg" >&2
        printf 'to specify a doc: rite align-docs <basename-without-extension>\n' >&2
        return 1
        ;;
    esac

    # Normalize: strip .md suffix so both "foo" and "foo.md" yield the same key.
    local _rs_base="${_rs_arg%.md}"

    # Find ALL matching map entries by comparing basenames without extension.
    # Collect into a newline-separated list; error if more than one match found.
    local _rs_match=""
    local _rs_all_matches=""
    local _rs_doc
    while IFS= read -r _rs_doc || [ -n "$_rs_doc" ]; do
      [ -n "$_rs_doc" ] || continue
      local _rs_doc_base
      _rs_doc_base="$(basename "$_rs_doc" .md)"
      if [ "$_rs_doc_base" = "$_rs_base" ]; then
        _rs_all_matches="${_rs_all_matches}${_rs_doc}"$'\n'
      fi
    done <<_RS_MAP_EOF
$_rs_all_docs
_RS_MAP_EOF

    # Count matches; refuse to auto-adopt when ambiguous.
    local _rs_match_count
    _rs_match_count="$(printf '%s' "$_rs_all_matches" | grep -c '.' || true)"
    if [ "$_rs_match_count" -gt 1 ]; then
      printf 'error: "%s" is ambiguous — multiple docs share that basename:\n' "$_rs_arg" >&2
      printf '%s' "$_rs_all_matches" | sed 's/^/  /' >&2
      printf 'use the full project-relative path to disambiguate\n' >&2
      return 1
    fi
    _rs_match="$(printf '%s' "$_rs_all_matches" | head -1 || true)"

    if [ -z "$_rs_match" ]; then
      printf 'error: unknown doc "%s" — not found in docs-map.tsv\n' "$_rs_arg" >&2
      # List candidates whose basename contains the query string as a substring.
      local _rs_cands=""
      local _rs_cd
      while IFS= read -r _rs_cd || [ -n "$_rs_cd" ]; do
        [ -n "$_rs_cd" ] || continue
        local _rs_cb
        _rs_cb="$(basename "$_rs_cd" .md)"
        case "$_rs_cb" in
          *"$_rs_base"*) _rs_cands="${_rs_cands}  ${_rs_cd}"$'\n' ;;
        esac
      done <<_RS_CAND_EOF
$_rs_all_docs
_RS_CAND_EOF

      if [ -n "$_rs_cands" ]; then
        printf 'closest matches:\n' >&2
        printf '%s' "$_rs_cands" >&2
      else
        printf 'no close matches; available docs (first 5):\n' >&2
        printf '%s\n' "$_rs_all_docs" | head -5 | sed 's/^/  /' >&2
      fi
      printf 'to specify a doc: rite align-docs <basename-without-extension>\n' >&2
      return 1
    fi

    # Dedupe: skip if this path is already in the resolved list.
    case $'\n'"$_rs_resolved"$'\n' in
      *$'\n'"$_rs_match"$'\n'*) ;;
      *) _rs_resolved="${_rs_resolved}${_rs_match}"$'\n' ;;
    esac
  done

  printf '%s' "$_rs_resolved"
}

# ---------------------------------------------------------------------------
# _docs_restructure_history_path
#
# Returns the path to the restructure approval history file.
# Default: ${RITE_STATE_DIR:-${RITE_PROJECT_ROOT}/.rite/state}/doc-approval-history.md
# ---------------------------------------------------------------------------
_docs_restructure_history_path() {
  local _rhp_state_dir="${RITE_STATE_DIR:-${RITE_PROJECT_ROOT:-${PWD}}/.rite/state}"
  printf '%s/doc-approval-history.md' "$_rhp_state_dir"
}

# ---------------------------------------------------------------------------
# _docs_restructure_history_lookup DOC
#
# Echo "decision<TAB>size_bytes" for the most recent history entry for DOC.
# Echoes empty string when no entry exists for the doc.
#
# Machine-readable marker format searched:
#   <!-- reshist doc=<doc> decision=<val> size_bytes=<N> date=<YYYY-MM-DD> -->
# ---------------------------------------------------------------------------
_docs_restructure_history_lookup() {
  local _rhl_doc="${1:-}"
  [ -n "$_rhl_doc" ] || return 0

  local _rhl_hist_path
  _rhl_hist_path="$(_docs_restructure_history_path)"
  [ -f "$_rhl_hist_path" ] || return 0

  # Parse machine-readable marker lines; keep the last match (most recent entry).
  local _rhl_decision="" _rhl_size="" _rhl_line
  while IFS= read -r _rhl_line || [ -n "$_rhl_line" ]; do
    case "$_rhl_line" in
      "<!-- reshist doc=${_rhl_doc} "*)
        local _rhl_d _rhl_s
        _rhl_d="$(printf '%s' "$_rhl_line" \
          | grep -oE 'decision=[^ >]+' | cut -d= -f2 || true)"
        _rhl_s="$(printf '%s' "$_rhl_line" \
          | grep -oE 'size_bytes=[0-9]+' | cut -d= -f2 || true)"
        [ -n "$_rhl_d" ] && _rhl_decision="$_rhl_d"
        [ -n "$_rhl_s" ] && _rhl_size="$_rhl_s"
        ;;
    esac
  done < "$_rhl_hist_path"

  [ -n "$_rhl_decision" ] || return 0
  printf '%s\t%s' "$_rhl_decision" "${_rhl_size:-0}"
}

# ---------------------------------------------------------------------------
# _docs_restructure_should_propose DOC CURRENT_SIZE_BYTES
#
# Returns 0 when a restructure proposal should be raised, 1 when suppressed.
#
# Suppression rule: a prior decision exists AND the doc has NOT grown by at
# least RITE_DOC_RESTRUCTURE_REGROWTH_PCT (default 25) percent since the
# size recorded at that decision.  When the doc grows past the threshold the
# proposal is re-raised.
# ---------------------------------------------------------------------------
_docs_restructure_should_propose() {
  local _rsp_doc="${1:-}"
  local _rsp_current="${2:-0}"
  [ -n "$_rsp_doc" ] || return 0

  local _rsp_threshold="${RITE_DOC_RESTRUCTURE_REGROWTH_PCT:-25}"
  case "$_rsp_threshold" in
    *[!0-9]*|"") _rsp_threshold=25 ;;
  esac

  local _rsp_lookup
  _rsp_lookup="$(_docs_restructure_history_lookup "$_rsp_doc" || true)"
  [ -n "$_rsp_lookup" ] || return 0  # No history entry → always propose

  local _rsp_recorded
  _rsp_recorded="$(printf '%s' "$_rsp_lookup" | cut -f2 || true)"

  case "${_rsp_recorded:-}" in ''|*[!0-9]*) _rsp_recorded=0 ;; esac

  # Can't compute growth when recorded_size is 0 — re-raise
  [ "$_rsp_recorded" -gt 0 ] || return 0

  # Validate current size
  case "${_rsp_current:-}" in ''|*[!0-9]*) _rsp_current=0 ;; esac

  # Growth percentage: integer arithmetic, truncates toward zero
  local _rsp_growth
  _rsp_growth=$(( (_rsp_current - _rsp_recorded) * 100 / _rsp_recorded ))

  # Re-raise only when growth is strictly at or above the threshold
  if [ "$_rsp_growth" -ge "$_rsp_threshold" ]; then
    return 0
  fi
  return 1  # Below threshold — suppress
}

# ---------------------------------------------------------------------------
# _docs_restructure_record_decision DOC QUESTION DECISION RATIONALE SIZE_BYTES
#
# Append a restructure decision record to the approval history file.
# Creates the file with a header block when it does not yet exist.
#
# DECISION must be one of: accepted, rejected, no-restructure-needed
# ---------------------------------------------------------------------------
_docs_restructure_record_decision() {
  local _rrd_doc="${1:-}"
  local _rrd_question="${2:-Should this doc be restructured?}"
  local _rrd_decision="${3:-rejected}"
  local _rrd_rationale="${4:-}"
  local _rrd_size="${5:-0}"

  [ -n "$_rrd_doc" ] || return 1

  local _rrd_hist_path
  _rrd_hist_path="$(_docs_restructure_history_path)"
  local _rrd_dir
  _rrd_dir="$(dirname "$_rrd_hist_path")"
  mkdir -p "$_rrd_dir" 2>/dev/null || true

  if [ ! -f "$_rrd_hist_path" ]; then
    cat > "$_rrd_hist_path" << 'HIST_HEADER_EOF'
# Doc Restructure Approval History

<!-- Human-editable. Each entry records one restructure decision per doc. -->
<!-- The machine-readable marker (<!-- reshist ... -->) drives the stability suppression rule. -->

HIST_HEADER_EOF
  fi

  local _rrd_date
  _rrd_date="$(date -u +%Y-%m-%d 2>/dev/null || echo 'unknown')"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: doc, question, decision, rationale, size, date vars must expand
  cat >> "$_rrd_hist_path" <<RECORD_EOF
<!-- reshist doc=${_rrd_doc} decision=${_rrd_decision} size_bytes=${_rrd_size} date=${_rrd_date} -->
## ${_rrd_doc}

**Question**: ${_rrd_question}
**Decision**: ${_rrd_decision}
**Date**: ${_rrd_date}
**Rationale**: ${_rrd_rationale:-none recorded}
**Size at decision**: ${_rrd_size} bytes

RECORD_EOF
}

# ---------------------------------------------------------------------------
# docs_run_restructure_assessment [DOC ...]
#
# Restructure assessment pass for rite align-docs.  Runs FIRST in the
# align-docs sequence, before any assertion audit.
#
# For each in-scope doc:
#   1. Check stability rule: suppress when the doc has not grown by at least
#      RITE_DOC_RESTRUCTURE_REGROWTH_PCT (default 25%) since the last decision.
#   2. Call provider_resolve_model doc_update to generate restructure proposals.
#   3. Surface proposals through the per-proposal approval loop (y/n).
#   4. Record every decision (accepted/rejected/no-restructure-needed) in
#      ${RITE_STATE_DIR}/doc-approval-history.md.
#   5. Approved proposals are applied through _docs_apply_approved — never
#      written directly to docs files.
#
# No args: assess every doc in the docs map.
# ---------------------------------------------------------------------------
docs_run_restructure_assessment() {
  # Migrate legacy flat drift log to schema store on first align-docs run.
  # Non-interactive; runs before the TTY guard so it fires in any invocation context.
  migrate_legacy_drift_log || true

  local _rra_docs_raw=""
  local _rra_arg
  for _rra_arg in "$@"; do
    _rra_docs_raw="${_rra_docs_raw}${_rra_arg}"$'\n'
  done

  if [ -z "$_rra_docs_raw" ]; then
    _rra_docs_raw="$(docs_resolve_doc_scope 2>/dev/null || true)"
    if [ -z "$_rra_docs_raw" ]; then
      print_info "Restructure assessment: no docs in scope"
      return 0
    fi
  fi

  # Non-TTY: skip to avoid recording false rejections for proposals no human saw.
  # Tests may bypass with _RITE_FORCE_TTY=1 (same pattern as _docs_promote_pass).
  if [ "${_RITE_FORCE_TTY:-0}" != "1" ] && [ ! -t 0 ]; then
    print_info "Restructure assessment: not an interactive terminal — skipped (run 'rite align-docs' interactively)"
    return 0
  fi

  local _rra_timeout="${RITE_DOC_ASSESSMENT_TIMEOUT:-300}"
  local _rra_target="${RITE_TARGET_BRANCH:-main}"
  local _rra_threshold="${RITE_DOC_RESTRUCTURE_REGROWTH_PCT:-25}"
  case "$_rra_threshold" in *[!0-9]*|"") _rra_threshold=25 ;; esac

  git -C "$RITE_PROJECT_ROOT" fetch origin "$_rra_target" 2>/dev/null || true

  local _rra_doc
  while IFS= read -r _rra_doc <&3 || [ -n "$_rra_doc" ]; do
    [ -n "$_rra_doc" ] || continue

    local _rra_call_elapsed=0 _rra_input_bytes=0 _rra_call_start _rra_call_end

    local _rra_abs="${RITE_PROJECT_ROOT}/${_rra_doc}"
    local _rra_size=0
    if [ -f "$_rra_abs" ]; then
      _rra_size="$(wc -c < "$_rra_abs" 2>/dev/null || echo 0)"
      _rra_size="$(printf '%s' "$_rra_size" | tr -d ' ')"
    fi

    # Stability check: suppress when below regrowth threshold
    if ! _docs_restructure_should_propose "$_rra_doc" "$_rra_size"; then
      print_info "Restructure assessment: ${_rra_doc} below regrowth threshold (${_rra_threshold}%) — skipped"
      continue
    fi

    # Gather docs-map section list for this doc
    local _rra_map_file
    _rra_map_file="$(docs_map_path)"
    local _rra_section_list=""
    if [ -f "$_rra_map_file" ]; then
      local _rra_ml
      while IFS= read -r _rra_ml || [ -n "$_rra_ml" ]; do
        case "$_rra_ml" in '#'*) continue ;; esac
        local _rra_ml_path _rra_ml_heading
        _rra_ml_path="$(printf '%s' "$_rra_ml" | cut -f1 || true)"
        [ "$_rra_ml_path" = "$_rra_doc" ] || continue
        _rra_ml_heading="$(printf '%s' "$_rra_ml" | cut -f5 || true)"
        [ -n "$_rra_ml_heading" ] && \
          _rra_section_list="${_rra_section_list}  - ${_rra_ml_heading}"$'\n'
      done < "$_rra_map_file"
    fi

    local _rra_doc_ctx=""
    [ -f "$_rra_abs" ] && _rra_doc_ctx="$(head -c 4000 "$_rra_abs" 2>/dev/null || true)"

    local _rra_end_token="${_RITE_RESTRUCT_END_TOKEN:-"---RESTRUCT-END-${RANDOM}${RANDOM}---"}"
    # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_ENFORCED_BY is a marker constant defined in markers.sh; _RITE_ prefix cannot be used; ledger frozen
    local _rra_enforced_by_marker="$RITE_MARKER_ENFORCED_BY"

    local _rra_prompt_file
    _rra_prompt_file="$(mktemp)"
    # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: doc, size, sections, context, and end-token vars must expand
    cat > "$_rra_prompt_file" <<RESTRUCTURE_PROMPT_EOF
You are a documentation architect reviewing a single documentation file.

Doc: ${_rra_doc}
Current size: ${_rra_size} bytes

Sections (from docs-map):
${_rra_section_list:-  (no sections mapped yet)}

Content excerpt (first 4KB):
${_rra_doc_ctx}

Assess whether this doc should be split, merged, or consolidated:
- An oversized doc can split into an ADR plus feature docs.
- Overlapping sections with other docs can be merged or de-duplicated.
- ${_rra_enforced_by_marker} markers and cross-links must be re-pointed after restructuring.
- Quality-of-vision judgements (philosophy, budget vs scale) are NOT in scope.

If restructuring is warranted, output EXACTLY this format:

---RESTRUCTURE-QUESTION---
<one sentence: the specific restructure question for the approval history>
---END-QUESTION---

For each file change needed (EDIT an existing file or CREATE a new file):
---PROPOSAL---
ACTION: EDIT|CREATE
FILE: <project-relative path>
DRIFT_REFS: none
DESCRIPTION: <one-line summary>
---CONTENT---
<complete new content of the file>
${_rra_end_token}

If no restructuring is needed, output ONLY: NO_RESTRUCTURE_NEEDED
RESTRUCTURE_PROMPT_EOF

    print_info "Running restructure assessment for ${_rra_doc}..."

    _rra_input_bytes="$(wc -c < "$_rra_prompt_file" 2>/dev/null | tr -d ' ' || true)"
    _rra_input_bytes="${_rra_input_bytes:-0}"
    _rra_call_start=$(date +%s)

    local _rra_raw="" _rra_llm_rc=0
    _rra_raw="$(provider_run_prompt_with_timeout \
      "$(cat "$_rra_prompt_file")" \
      "$(provider_resolve_model doc_update)" \
      true \
      "$_rra_timeout" 2>/dev/null)" || _rra_llm_rc=$?
    rm -f "$_rra_prompt_file"

    _rra_call_end=$(date +%s)
    _rra_call_elapsed=$((_rra_call_end - _rra_call_start))

    if [ "$_rra_llm_rc" -eq 124 ]; then
      print_warning "Restructure assessment timed out after ${_rra_timeout}s for ${_rra_doc}" >&2
      _diag "DOC_PASS kind=align doc=${_rra_doc} duration_s=${_rra_call_elapsed} input_bytes=${_rra_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "$_rra_doc" "$_rra_call_elapsed"
      continue
    elif [ "$_rra_llm_rc" -ne 0 ]; then
      print_warning "Restructure assessment provider call failed (exit ${_rra_llm_rc}) for ${_rra_doc}" >&2
      _diag "DOC_PASS kind=align doc=${_rra_doc} duration_s=${_rra_call_elapsed} input_bytes=${_rra_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "$_rra_doc" "$_rra_call_elapsed"
      continue
    fi

    if [ -z "$_rra_raw" ]; then
      print_info "No restructure proposals returned for ${_rra_doc}"
      _diag "DOC_PASS kind=align doc=${_rra_doc} duration_s=${_rra_call_elapsed} input_bytes=${_rra_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "$_rra_doc" "$_rra_call_elapsed"
      continue
    fi

    if printf '%s\n' "$_rra_raw" | grep -q "^NO_RESTRUCTURE_NEEDED"; then
      print_info "Restructure assessment: no restructuring needed for ${_rra_doc}"
      _docs_restructure_record_decision \
        "$_rra_doc" \
        "Should ${_rra_doc} be restructured?" \
        "no-restructure-needed" \
        "LLM assessment: no restructuring warranted" \
        "$_rra_size" || true
      _diag "DOC_PASS kind=align doc=${_rra_doc} duration_s=${_rra_call_elapsed} input_bytes=${_rra_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "$_rra_doc" "$_rra_call_elapsed"
      continue
    fi

    # Extract the restructure question from the response
    local _rra_question="Should ${_rra_doc} be restructured?"
    local _rra_in_q=0 _rra_q_line
    while IFS= read -r _rra_q_line || [ -n "$_rra_q_line" ]; do
      case "$_rra_q_line" in
        "---RESTRUCTURE-QUESTION---") _rra_in_q=1 ;;
        "---END-QUESTION---") _rra_in_q=0 ;;
        *) [ "$_rra_in_q" = "1" ] && [ -n "$_rra_q_line" ] && _rra_question="$_rra_q_line" ;;
      esac
    done <<QUESTION_PARSE_EOF
$_rra_raw
QUESTION_PARSE_EOF

    # Parse proposals (same structure as _docs_update_engine)
    local _rra_props_dir
    _rra_props_dir="$(mktemp -d)"
    local _rra_prop_count=0
    local _rra_in_prop=0 _rra_in_content=0
    local _rra_cur_action="" _rra_cur_file="" _rra_cur_drift="" _rra_cur_desc="" _rra_cur_content=""

    local _rra_raw_file
    _rra_raw_file="$(mktemp)"
    printf '%s\n' "$_rra_raw" > "$_rra_raw_file"

    local _rra_rl
    while IFS= read -r _rra_rl || [ -n "$_rra_rl" ]; do
      case "$_rra_rl" in
        "---RESTRUCTURE-QUESTION---"|"---END-QUESTION---")
          [ "$_rra_in_content" = "1" ] && \
            _rra_cur_content="${_rra_cur_content}${_rra_rl}"$'\n'
          ;;
        "---PROPOSAL---")
          if [ "$_rra_in_content" = "1" ]; then
            _rra_cur_content="${_rra_cur_content}${_rra_rl}"$'\n'
          else
            _rra_in_prop=1; _rra_in_content=0
            _rra_cur_action=""; _rra_cur_file=""; _rra_cur_drift=""
            _rra_cur_desc=""; _rra_cur_content=""
          fi
          ;;
        "---CONTENT---")
          if [ "$_rra_in_content" = "1" ]; then
            _rra_cur_content="${_rra_cur_content}${_rra_rl}"$'\n'
          else
            [ "$_rra_in_prop" = "1" ] && _rra_in_content=1
          fi
          ;;
        "${_rra_end_token}")
          if [ "$_rra_in_prop" = "1" ] && [ -n "$_rra_cur_file" ]; then
            _rra_prop_count=$((_rra_prop_count + 1))
            {
              printf 'ACTION: %s\n' "$_rra_cur_action"
              printf 'FILE: %s\n' "$_rra_cur_file"
              printf 'DRIFT_REFS: %s\n' "${_rra_cur_drift:-none}"
              printf 'DESCRIPTION: %s\n' "$_rra_cur_desc"
              printf -- '---CONTENT---\n'
              printf '%s' "$_rra_cur_content"
            } > "${_rra_props_dir}/proposal_${_rra_prop_count}.txt"
          fi
          _rra_in_prop=0; _rra_in_content=0
          ;;
        *)
          if [ "$_rra_in_prop" = "1" ]; then
            if [ "$_rra_in_content" = "1" ]; then
              _rra_cur_content="${_rra_cur_content}${_rra_rl}"$'\n'
            else
              case "$_rra_rl" in
                "ACTION: "*)      _rra_cur_action="${_rra_rl#ACTION: }" ;;
                "FILE: "*)        _rra_cur_file="${_rra_rl#FILE: }" ;;
                "DRIFT_REFS: "*)  _rra_cur_drift="${_rra_rl#DRIFT_REFS: }" ;;
                "DESCRIPTION: "*) _rra_cur_desc="${_rra_rl#DESCRIPTION: }" ;;
              esac
            fi
          fi
          ;;
      esac
    done < "$_rra_raw_file"
    rm -f "$_rra_raw_file"

    if [ "$_rra_prop_count" -eq 0 ]; then
      rm -rf "$_rra_props_dir"
      if printf '%s\n' "$_rra_raw" | grep -q "^---PROPOSAL---"; then
        # Proposals were started but the end token never matched — transient parse
        # error, not a genuine "no restructuring needed". Don't record a decision;
        # the proposal will re-raise on the next run.
        print_warning "Restructure parse error for ${_rra_doc}: end token unmatched — not recording a decision (will re-raise on next run)" >&2
      else
        print_info "No actionable restructure proposals for ${_rra_doc}"
      fi
      _diag "DOC_PASS kind=align doc=${_rra_doc} duration_s=${_rra_call_elapsed} input_bytes=${_rra_input_bytes} outcome=rejected"
      _docs_warn_doc_pass_threshold "$_rra_doc" "$_rra_call_elapsed"
      continue
    fi

    echo "" >&2
    print_info "${_rra_prop_count} restructure proposal(s) for ${_rra_doc}:"
    printf '  Question: %s\n' "$_rra_question" >&2
    echo "" >&2

    # Per-proposal approval loop
    local _rra_appr_dir
    _rra_appr_dir="$(mktemp -d)"
    local _rra_appr_count=0 _rra_pi=1

    while [ "$_rra_pi" -le "$_rra_prop_count" ]; do
      local _rra_pf="${_rra_props_dir}/proposal_${_rra_pi}.txt"
      [ -f "$_rra_pf" ] || { _rra_pi=$((_rra_pi + 1)); continue; }

      local _rra_p_action _rra_p_file _rra_p_desc
      _rra_p_action="$(grep '^ACTION: ' "$_rra_pf" | head -1 | cut -d' ' -f2- || true)"
      _rra_p_file="$(grep '^FILE: ' "$_rra_pf" | head -1 | cut -d' ' -f2- || true)"
      _rra_p_desc="$(grep '^DESCRIPTION: ' "$_rra_pf" | head -1 || true)"
      _rra_p_desc="${_rra_p_desc#DESCRIPTION: }"

      # Reject unsafe paths
      # shellcheck disable=SC2221,SC2222
      case "$_rra_p_file" in
        /*|*../*|*/..|../*|..)
          print_warning "  Skipping proposal with unsafe FILE path: '$_rra_p_file'" >&2
          _rra_pi=$((_rra_pi + 1))
          continue
          ;;
      esac

      echo "──────────────────────────────────────────────" >&2
      printf '  Restructure %d/%d  [%s]  %s\n' \
        "$_rra_pi" "$_rra_prop_count" "$_rra_p_action" "$_rra_p_file" >&2
      [ -n "$_rra_p_desc" ] && printf '  %s\n' "$_rra_p_desc" >&2
      echo "" >&2

      local _rra_input="n"
      read -p "  Accept this restructure change? (y)es / (n)o: " -r _rra_input || true
      echo "" >&2

      case "$_rra_input" in
        [Yy]|[Yy][Ee][Ss])
          _rra_appr_count=$((_rra_appr_count + 1))
          cp "$_rra_pf" "${_rra_appr_dir}/approved_${_rra_appr_count}.txt"
          print_info "  Accepted: ${_rra_p_file}"
          ;;
        *)
          print_info "  Skipped: ${_rra_p_file}"
          ;;
      esac
      _rra_pi=$((_rra_pi + 1))
    done

    rm -rf "$_rra_props_dir"

    local _rra_decision _rra_rationale
    if [ "$_rra_appr_count" -gt 0 ]; then
      _rra_decision="accepted"
      _rra_rationale="User approved ${_rra_appr_count} restructure proposal(s)"
      # Approved restructures go through the docs-PR apply path — never written directly
      _docs_apply_approved \
        "$_rra_appr_dir" \
        "" \
        "restructure ${_rra_doc}" \
        "restructure" \
        "$_rra_target" || true
    else
      _rra_decision="rejected"
      _rra_rationale="User rejected all restructure proposals"
    fi

    rm -rf "$_rra_appr_dir"

    _docs_restructure_record_decision \
      "$_rra_doc" \
      "$_rra_question" \
      "$_rra_decision" \
      "$_rra_rationale" \
      "$_rra_size" || true
    _diag "DOC_PASS kind=align doc=${_rra_doc} duration_s=${_rra_call_elapsed} input_bytes=${_rra_input_bytes} outcome=${_rra_decision}"
    _docs_warn_doc_pass_threshold "$_rra_doc" "$_rra_call_elapsed"
  done 3<<DOCS_LOOP_EOF
$_rra_docs_raw
DOCS_LOOP_EOF
}

# ---------------------------------------------------------------------------
# Shipped default rubric strings per doc type (used by docs_run_assertion_audit).
# Plain assignment with ${VAR:-default} idiom — idempotent, not readonly.
# Map's rubric column overrides these per-section when it is not "-".
# ---------------------------------------------------------------------------
_DOCS_AUDIT_RUBRIC_ACCURACY="${_DOCS_AUDIT_RUBRIC_ACCURACY:-"Accuracy check — verify every assertion in this section against the code it references: (1) does the code actually behave as described? (2) are referenced interfaces, flags, defaults, or return values still current? Flag incorrect or stale assertions."}"

# sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_ENFORCED_BY is a marker constant defined in markers.sh; _RITE_ prefix cannot be used as RITE_MARKER_* is the canonical convention; ledger frozen per 2026-07-14 rule
_DOCS_AUDIT_RUBRIC_FEATURE="${_DOCS_AUDIT_RUBRIC_FEATURE:-"Feature-doc role check: (1) does this section stay within one feature boundary — flag anything that describes a sibling feature? (2) does every observable-behavior assertion name an enforcing test via a '<!-- ${RITE_MARKER_ENFORCED_BY}: path.bats -->' marker, or is the assertion flagged as un-enforced? (3) does any assertion duplicate content in a sibling feature doc?"}"

_DOCS_AUDIT_RUBRIC_ADR="${_DOCS_AUDIT_RUBRIC_ADR:-"ADR role check — compare across docs: (1) does this ADR section link every feature doc it covers? List any feature docs in the project not linked. (2) does any feature doc contradict a decision in this section? (3) are there code areas this section claims to cover with zero feature-doc coverage? (4) do the architectural decisions in this section still hold given the current codebase?"}"

# ---------------------------------------------------------------------------
# docs_run_assertion_audit [DOC ...]
#
# Assertion audit pass for rite align-docs. Runs AFTER docs_run_restructure_assessment.
#
# For each in-scope doc, iterates over every docs-map section and makes one
# provider_resolve_model doc_update call per section.  Each call receives:
#   - the map-anchored section content (via _docs_extract_section)
#   - code files referenced in the section (byte-capped at 3 KB total)
#   - the applicable rubric: accuracy (all docs) + role (feature/ADR types)
#
# The map's rubric column overrides shipped defaults when present and != '-'.
# ADR role check uses docs_map_adr_links to compute missing-link context.
#
# Before running: displays in-scope docs, section count, and model-call count
# and asks for confirmation.  Declining exits 0 with zero model calls made.
#
# Findings routing:
#   nondeterministic — auto-recorded as kind=refinement drift entry (no prompt)
#   accuracy / role  — presented to user; y records a drift entry, n skips
#
# Non-interactive (non-TTY): skipped with an info message.
# Tests may bypass the TTY check with _RITE_FORCE_TTY=1.
# ---------------------------------------------------------------------------
docs_run_assertion_audit() {
  # Non-TTY: skip to avoid recording false entries for output no human saw.
  if [ "${_RITE_FORCE_TTY:-0}" != "1" ] && [ ! -t 0 ]; then
    print_info "Assertion audit skipped (not an interactive terminal — run 'rite align-docs' interactively)"
    return 0
  fi

  # Resolve doc scope
  local _aau_docs_raw=""
  if [ "$#" -gt 0 ]; then
    local _aau_arg
    for _aau_arg in "$@"; do
      _aau_docs_raw="${_aau_docs_raw}${_aau_arg}"$'\n'
    done
  else
    _aau_docs_raw="$(docs_resolve_doc_scope 2>/dev/null || true)"
  fi
  if [ -z "$_aau_docs_raw" ]; then
    print_info "Assertion audit: no docs in scope"
    return 0
  fi

  # Ensure map
  local _aau_map_file
  _aau_map_file="$(docs_map_path)"
  if [ ! -f "$_aau_map_file" ]; then
    print_info "Assertion audit: docs map not found — run 'rite docs' first to build the map"
    return 0
  fi

  # Build section list: one entry per map row for in-scope docs.
  # Format: doc_path TAB heading_level TAB heading_text TAB type TAB rubric_col
  local _aau_section_list=""
  local _aau_section_count=0

  local _aau_d
  while IFS= read -r _aau_d <&3 || [ -n "$_aau_d" ]; do
    [ -n "$_aau_d" ] || continue
    local _aau_fp _aau_sha _aau_af _aau_hl _aau_ht _aau_fpr _aau_dt _aau_rb _aau_tg _aau_nt
    while IFS=$'\001' read -r _aau_fp _aau_sha _aau_af _aau_hl _aau_ht _aau_fpr _aau_dt _aau_rb _aau_tg _aau_nt; do
      [ "$_aau_fp" = "$_aau_d" ] || continue
      _aau_section_list="${_aau_section_list}${_aau_fp}	${_aau_hl:-}	${_aau_ht:-}	${_aau_dt:-other}	${_aau_rb:--}
"
      _aau_section_count=$((_aau_section_count + 1))
    done < <(awk -F'\t' '/^#/{next}{printf "%s\001%s\001%s\001%s\001%s\001%s\001%s\001%s\001%s\001%s\n",$1,(NF>=2)?$2:"",(NF>=3)?$3:"-",(NF>=4)?$4:"",(NF>=5)?$5:"",(NF>=6)?$6:"",(NF>=7)?$7:"other",(NF>=8)?$8:"-",(NF>=9)?$9:"-",(NF>=10)?$10:"-"}' "$_aau_map_file" || true)
  done 3<<DOCS_SCOPE_EOF
$_aau_docs_raw
DOCS_SCOPE_EOF

  if [ "$_aau_section_count" -eq 0 ]; then
    print_info "Assertion audit: no sections found in docs map for in-scope docs"
    return 0
  fi

  local _aau_doc_count=0
  _aau_doc_count="$(printf '%s\n' "$_aau_docs_raw" | grep -c '.' || true)"

  # Pre-run confirmation gate
  echo "" >&2
  print_info "Assertion audit plan:"
  printf '  Docs:          %d\n' "$_aau_doc_count" >&2
  printf '  Sections:      %d\n' "$_aau_section_count" >&2
  printf '  Model calls:   %d  (one per section, doc_update model)\n' "$_aau_section_count" >&2
  echo "" >&2

  local _aau_confirm="n"
  read -p "  Proceed with assertion audit? [y/N] " -r _aau_confirm || true
  echo "" >&2
  case "${_aau_confirm:-n}" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *)
      print_info "Assertion audit cancelled"
      return 0
      ;;
  esac

  local _aau_timeout="${RITE_DOC_ASSESSMENT_TIMEOUT:-300}"
  local _aau_branch
  _aau_branch="$(git -C "${RITE_PROJECT_ROOT:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"

  # Temp file: accumulates findings across all sections.
  # Format per line: doc_path TAB section_heading TAB type TAB description
  local _aau_findings_file
  _aau_findings_file="$(mktemp)"

  local _aau_calls=0
  local _aau_total_elapsed=0 _aau_total_bytes=0
  local _aau_sl
  while IFS= read -r _aau_sl <&4 || [ -n "$_aau_sl" ]; do
    [ -n "$_aau_sl" ] || continue

    local _aau_sl_doc _aau_sl_hl _aau_sl_ht _aau_sl_dt _aau_sl_rb
    _aau_sl_doc="$(printf '%s' "$_aau_sl" | cut -f1 || true)"
    _aau_sl_hl="$(printf '%s' "$_aau_sl" | cut -f2 || true)"
    _aau_sl_ht="$(printf '%s' "$_aau_sl" | cut -f3 || true)"
    _aau_sl_dt="$(printf '%s' "$_aau_sl" | cut -f4 || true)"
    _aau_sl_rb="$(printf '%s' "$_aau_sl" | cut -f5 || true)"

    local _aau_abs="${RITE_PROJECT_ROOT}/${_aau_sl_doc}"
    [ -f "$_aau_abs" ] || continue

    # Extract this section's content (map-anchored, never the whole document)
    local _aau_sec
    _aau_sec="$(_docs_extract_section "$_aau_abs" "$_aau_sl_hl" "$_aau_sl_ht" || true)"
    [ -n "$_aau_sec" ] || continue

    # Code context: scan section for referenced code file paths and read them.
    # Byte cap: 1500 bytes per file, 3000 bytes total.
    local _aau_code_ctx="" _aau_code_bytes=0 _aau_code_cap=3000 _aau_file_cap=1500
    local _aau_seen_refs=""
    local _aau_ref
    while IFS= read -r _aau_ref || [ -n "$_aau_ref" ]; do
      [ -n "$_aau_ref" ] || continue
      case $'\n'"$_aau_seen_refs"$'\n' in *$'\n'"${_aau_ref}"$'\n'*) continue ;; esac
      _aau_seen_refs="${_aau_seen_refs}${_aau_ref}"$'\n'
      local _aau_ref_abs="${RITE_PROJECT_ROOT}/${_aau_ref}"
      [ -f "$_aau_ref_abs" ] || continue
      local _aau_ref_excerpt
      _aau_ref_excerpt="$(head -c "$_aau_file_cap" "$_aau_ref_abs" 2>/dev/null || true)"
      [ -n "$_aau_ref_excerpt" ] || continue
      local _aau_ref_entry="--- ${_aau_ref} ---
${_aau_ref_excerpt}

"
      if [ $((_aau_code_bytes + ${#_aau_ref_entry})) -le "$_aau_code_cap" ]; then
        _aau_code_bytes=$((_aau_code_bytes + ${#_aau_ref_entry}))
        _aau_code_ctx="${_aau_code_ctx}${_aau_ref_entry}"
      fi
    done < <(printf '%s\n' "$_aau_sec" | grep -oE '(lib|bin|tests|tools)/[a-zA-Z0-9_./-]+\.(sh|bats)' | sort -u || true)

    # Rubric selection: map's rubric column wins over shipped defaults.
    local _aau_acc_rubric="$_DOCS_AUDIT_RUBRIC_ACCURACY"
    local _aau_role_rubric=""
    local _aau_override_loaded=false
    if [ "${_aau_sl_rb:-}" != "-" ] && [ -n "${_aau_sl_rb:-}" ]; then
      local _aau_rb_abs="${RITE_PROJECT_ROOT}/${_aau_sl_rb}"
      if [ -f "$_aau_rb_abs" ]; then
        _aau_acc_rubric="$(cat "$_aau_rb_abs" 2>/dev/null || true)"
        if [ -n "$_aau_acc_rubric" ]; then
          _aau_override_loaded=true
        else
          print_warning "Assertion audit: rubric-override '${_aau_sl_rb}' missing or empty; using type-based default" >&2
        fi
      else
        print_warning "Assertion audit: rubric-override '${_aau_sl_rb}' missing or empty; using type-based default" >&2
      fi
    fi
    if [ "$_aau_override_loaded" = "false" ]; then
      _aau_acc_rubric="$_DOCS_AUDIT_RUBRIC_ACCURACY"
      case "${_aau_sl_dt:-other}" in
        feature) _aau_role_rubric="$_DOCS_AUDIT_RUBRIC_FEATURE" ;;
        adr)     _aau_role_rubric="$_DOCS_AUDIT_RUBRIC_ADR" ;;
      esac
    fi

    # ADR cross-doc context: compare docs_map_adr_links against all feature docs.
    local _aau_adr_ctx=""
    if [ "${_aau_sl_dt:-other}" = "adr" ]; then
      local _aau_linked
      _aau_linked="$(docs_map_adr_links "$_aau_sl_doc" 2>/dev/null || true)"
      local _aau_all_feat
      _aau_all_feat="$(awk -F'\t' '/^#/{next} NF>=7 && $7=="feature"{print $1}' \
        "$_aau_map_file" 2>/dev/null | sort -u || true)"
      local _aau_missing=""
      local _aau_feat
      while IFS= read -r _aau_feat <&5 || [ -n "$_aau_feat" ]; do
        [ -n "$_aau_feat" ] || continue
        if ! printf '%s\n' "$_aau_linked" | grep -qxF "$_aau_feat" 2>/dev/null; then
          _aau_missing="${_aau_missing}  - ${_aau_feat}"$'\n'
        fi
      done 5<<FEAT_LOOP_EOF
$_aau_all_feat
FEAT_LOOP_EOF
      if [ -n "$_aau_missing" ]; then
        _aau_adr_ctx="ADR cross-doc check:
Feature docs in the project NOT linked from this ADR:
${_aau_missing}"
      fi
    fi

    # Assemble role section and code section for the prompt (avoid blank lines
    # when absent so the model doesn't see confusing empty headers).
    local _aau_role_section="" _aau_code_section="" _aau_adr_section=""
    [ -n "$_aau_role_rubric" ] && _aau_role_section="--- ROLE RUBRIC ---
${_aau_role_rubric}
"
    [ -n "$_aau_code_ctx" ] && _aau_code_section="--- REFERENCED CODE ---
${_aau_code_ctx}"
    [ -n "$_aau_adr_ctx" ] && _aau_adr_section="${_aau_adr_ctx}
"

    local _aau_pf
    _aau_pf="$(mktemp)"
    # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: doc path, section content, rubric, code ctx, and adr ctx vars must expand
    cat > "$_aau_pf" <<AUDIT_SECTION_EOF
You are auditing one section of a documentation file for accuracy and role compliance.

Section: ${_aau_sl_doc} § ${_aau_sl_ht:-(preamble)}
Doc type: ${_aau_sl_dt:-other}

--- ACCURACY RUBRIC ---
${_aau_acc_rubric}

${_aau_role_section}${_aau_adr_section}--- SECTION CONTENT ---
${_aau_sec}

${_aau_code_section}
Output ONLY lines in this exact format for each issue found:
FINDING: <type>|<one-line description>

Where <type> is one of:
  accuracy         assertion in the section does not match the code
  nondeterministic assertion cannot be verified statically (will become a refinement entry)
  role             section violates its doc-type role rubric

If no issues are found, output only: NOTHING_FOUND
AUDIT_SECTION_EOF

    _aau_calls=$((_aau_calls + 1))

    local _aau_sec_bytes _aau_sec_start _aau_sec_end _aau_sec_elapsed
    _aau_sec_bytes="$(wc -c < "$_aau_pf" 2>/dev/null | tr -d ' ' || true)"
    _aau_sec_bytes="${_aau_sec_bytes:-0}"
    _aau_sec_start=$(date +%s)

    local _aau_raw="" _aau_llm_rc=0
    _aau_raw="$(provider_run_prompt_with_timeout \
      "$(cat "$_aau_pf")" \
      "$(provider_resolve_model doc_update)" \
      true \
      "$_aau_timeout" 2>/dev/null)" || _aau_llm_rc=$?
    rm -f "$_aau_pf"

    _aau_sec_end=$(date +%s)
    _aau_sec_elapsed=$((_aau_sec_end - _aau_sec_start))
    _aau_total_elapsed=$((_aau_total_elapsed + _aau_sec_elapsed))
    _aau_total_bytes=$((_aau_total_bytes + _aau_sec_bytes))

    if [ "$_aau_llm_rc" -eq 124 ]; then
      print_warning "Assertion audit: timed out on ${_aau_sl_doc} § ${_aau_sl_ht:-(preamble)}" >&2
      continue
    elif [ "$_aau_llm_rc" -ne 0 ]; then
      print_warning "Assertion audit: provider call failed for ${_aau_sl_doc} § ${_aau_sl_ht:-(preamble)}" >&2
      continue
    fi

    # Parse FINDING: lines and append to findings file
    local _aau_raw_line
    while IFS= read -r _aau_raw_line || [ -n "$_aau_raw_line" ]; do
      case "$_aau_raw_line" in
        FINDING:*)
          local _aau_f_rest="${_aau_raw_line#FINDING: }"
          # Also strip "FINDING:" without trailing space (model may omit it)
          [ "$_aau_f_rest" = "$_aau_raw_line" ] && _aau_f_rest="${_aau_raw_line#FINDING:}"
          local _aau_f_type="${_aau_f_rest%%|*}"
          local _aau_f_desc="${_aau_f_rest#*|}"
          # Sanitize tabs so the TSV's cut -f4 read-back returns the full description.
          _aau_f_desc="${_aau_f_desc//$'\t'/ }"
          [ -n "$_aau_f_type" ] && [ -n "$_aau_f_desc" ] && [ "$_aau_f_type" != "$_aau_f_rest" ] && \
            printf '%s\t%s\t%s\t%s\n' \
              "$_aau_sl_doc" "${_aau_sl_ht:-(preamble)}" "$_aau_f_type" "$_aau_f_desc" >> "$_aau_findings_file"
          ;;
      esac
    done <<RAW_EOF
$_aau_raw
RAW_EOF

  done 4<<SECTION_LOOP_EOF
$_aau_section_list
SECTION_LOOP_EOF

  # Count findings
  local _aau_total=0
  _aau_total="$(grep -c '.' "$_aau_findings_file" || true)"

  echo "" >&2
  print_info "Assertion audit complete: ${_aau_calls} section(s) checked, ${_aau_total} finding(s)"

  # Clear pre-existing drift entries for every audited doc (across all branches)
  # and rebuild the docs map — before new entries are appended and before the
  # early return, so both the clean-audit and findings paths run both operations.
  # This is the "consumed or cleared" half of the bounded-entries contract.
  if [ -n "${_aau_docs_raw:-}" ] && declare -f drift_log_clear_doc >/dev/null 2>&1; then
    local _aau_clear_doc
    while IFS= read -r _aau_clear_doc || [ -n "$_aau_clear_doc" ]; do
      [ -n "$_aau_clear_doc" ] || continue
      drift_log_clear_doc "$_aau_clear_doc" || true
    done <<CLEAR_DOCS_EOF
$_aau_docs_raw
CLEAR_DOCS_EOF
  fi

  if declare -f docs_map_build >/dev/null 2>&1; then
    local _aau_map_rc=0
    docs_map_build || _aau_map_rc=$?
    if [ "$_aau_map_rc" -eq 0 ]; then
      print_info "Docs map rebuilt post-audit"
    else
      print_warning "Docs map rebuild failed post-audit"
    fi
  fi

  if [ "$_aau_total" -eq 0 ]; then
    rm -f "$_aau_findings_file"
    return 0
  fi

  # Findings routing: propose/approve loop.
  # nondeterministic → auto-record as refinement (no prompt).
  # accuracy / role   → prompt user (y: record drift entry, n: skip).
  echo "" >&2
  local _aau_approved=0 _aau_auto=0
  local _aau_fi
  while IFS= read -r _aau_fi <&6 || [ -n "$_aau_fi" ]; do
    [ -n "$_aau_fi" ] || continue
    local _aau_fi_doc _aau_fi_sec _aau_fi_type _aau_fi_desc
    _aau_fi_doc="$(printf '%s' "$_aau_fi" | cut -f1 || true)"
    _aau_fi_sec="$(printf '%s' "$_aau_fi" | cut -f2 || true)"
    _aau_fi_type="$(printf '%s' "$_aau_fi" | cut -f3 || true)"
    _aau_fi_desc="$(printf '%s' "$_aau_fi" | cut -f4- || true)"

    local _aau_fi_kind="refinement"
    case "$_aau_fi_type" in
      accuracy) _aau_fi_kind="contradiction" ;;
      role)     _aau_fi_kind="reference-missing" ;;
      *)        _aau_fi_kind="refinement" ;;
    esac

    if [ "$_aau_fi_type" = "nondeterministic" ]; then
      drift_log_append \
        "$_aau_fi_doc" "$_aau_branch" "0" "-" \
        "${_aau_fi_desc}" "refinement" \
        "nondeterministic assertion; section: ${_aau_fi_sec}" || true
      _aau_auto=$((_aau_auto + 1))
      continue
    fi

    echo "──────────────────────────────────────────────" >&2
    printf '  Finding [%s]  %s § %s\n' "$_aau_fi_type" "$_aau_fi_doc" "$_aau_fi_sec" >&2
    printf '  %s\n' "$_aau_fi_desc" >&2
    echo "" >&2
    local _aau_fi_reply="n"
    read -p "  Record as drift entry (${_aau_fi_kind})? (y)es / (n)o: " -r _aau_fi_reply || true
    echo "" >&2
    case "${_aau_fi_reply:-n}" in
      [Yy]|[Yy][Ee][Ss])
        drift_log_append \
          "$_aau_fi_doc" "$_aau_branch" "0" "-" \
          "${_aau_fi_desc}" "$_aau_fi_kind" \
          "assertion audit; section: ${_aau_fi_sec}" || true
        _aau_approved=$((_aau_approved + 1))
        print_info "  Drift entry recorded"
        ;;
      *)
        print_info "  Skipped"
        ;;
    esac
  done 6< "$_aau_findings_file"

  rm -f "$_aau_findings_file"

  echo "" >&2
  local _aau_recorded=$((_aau_approved + _aau_auto))
  print_info "Assertion audit: ${_aau_recorded} finding(s) recorded (${_aau_auto} auto-refinement, ${_aau_approved} user-accepted)"
  local _aau_outcome="rejected"
  [ "$_aau_recorded" -gt 0 ] && _aau_outcome="accepted"
  _diag "DOC_PASS kind=align doc=- duration_s=${_aau_total_elapsed} input_bytes=${_aau_total_bytes} outcome=${_aau_outcome}"
  _docs_warn_doc_pass_threshold "-" "$_aau_total_elapsed"
}

# ---------------------------------------------------------------------------
# rite_docs [instructions]
#
# Main entry point. Dispatches based on effective documentation state.
#
# Arguments:
#   $@  optional instructions for directed-update (passed through to seam)
# ---------------------------------------------------------------------------
rite_docs() {
  local instructions="${*:-}"

  # --resume <branch>: load a saved proposal from a terminal-less promote and
  # run it through the interactive approval loop.
  case "${instructions:-}" in
    --resume|--resume\ *)
      local _rd_resume_branch="${instructions#--resume}"
      _rd_resume_branch="${_rd_resume_branch# }"
      docs_resume_proposal "$_rd_resume_branch"
      return $?
      ;;
  esac

  local state
  state="$(_docs_resolve_state)"

  case "$state" in

    never-run)
      if [ -n "$instructions" ]; then
        # Explicit directed update — the command itself is consent; run it directly.
        _docs_ensure_map || exit 1
        docs_directed_update "$instructions" || true
      else
        # No instructions and no consent recorded: direct user to the switch.
        print_info "Doc drift tracking is not enabled. Run 'rite align-docs' to turn it on or off."
      fi
      ;;

    sync|changelog)
      # Ensure map exists (self-heal silently or prompt when auto-rebuild disabled)
      _docs_ensure_map || exit 1

      if [ -n "$instructions" ]; then
        # Input present → directed-update engine
        docs_directed_update "$instructions" || true
      else
        # No input → audit
        _docs_run_audit "$state"
      fi
      ;;

    *)
      print_warning "docs: unexpected state '$state'"
      exit 1
      ;;
  esac
}
