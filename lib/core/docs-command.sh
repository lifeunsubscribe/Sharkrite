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
# _docs_apply_approved APPROVED_DIR DRIFT_PATH INSTRUCTIONS MODE TARGET_BRANCH [SKIP_BURNDOWN]
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

  # Count approved proposals
  local _aa_count=0
  if [ -d "$_aa_dir" ]; then
    _aa_count="$(find "$_aa_dir" -name 'approved_*.txt' -type f 2>/dev/null | wc -l | tr -d ' ' || true)"
  fi
  if [ "$_aa_count" -eq 0 ]; then
    print_info "No approved proposals to apply"
    return 0
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
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: branch, mode, and instruction vars must expand
  _aa_pr_body="$(cat <<PR_BODY_EOF
## Docs update

**Mode**: ${_aa_mode}
**Instructions**: ${_aa_instructions:-reconcile drift backlog}
**Base branch**: \`${_aa_target}\`

This PR was created by \`rite docs\`. Review and merge when ready.
**No auto-merge** — this PR requires human review before merging.

${_aa_all_drift_refs:+**Drift entries addressed**:${_aa_all_drift_refs}}
PR_BODY_EOF
)"

  echo "" >&2
  print_info "Creating docs PR targeting '${_aa_target}'..."

  # gh_safe must be called from within the worktree so gh can detect the repo remote
  ( cd "$_aa_wt_path" && gh_safe pr create \
    --base "${_aa_target}" \
    --title "$_aa_pr_title" \
    --body "$_aa_pr_body" ) || \
    print_warning "PR creation failed — branch '${_aa_branch}' was pushed; create PR manually" >&2

  # Remove worktree; branch remains for the open PR
  git -C "$RITE_PROJECT_ROOT" worktree remove "$_aa_wt_path" --force 2>/dev/null || true
  git -C "$RITE_PROJECT_ROOT" worktree prune 2>/dev/null || true

  print_success "Docs PR created on base '${_aa_target}' — review and merge when ready"
  return 0
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

    local _ue_proposals_raw="" _ue_llm_rc=0
    _ue_proposals_raw="$(provider_run_prompt_with_timeout \
      "$(cat "$_ue_prompt_file")" \
      "$(provider_resolve_model doc_assessment)" \
      true \
      "$_ue_timeout" 2>/dev/null)" || _ue_llm_rc=$?
    rm -f "$_ue_prompt_file"

    if [ "$_ue_llm_rc" -eq 124 ]; then
      print_warning "Provider call timed out after ${_ue_timeout}s — no proposals generated" >&2
      return 1
    elif [ "$_ue_llm_rc" -ne 0 ]; then
      print_warning "Provider call failed (exit ${_ue_llm_rc}) — no proposals generated" >&2
      return 1
    fi

    if [ -z "$_ue_proposals_raw" ]; then
      print_info "No proposals returned"
      return 0
    fi

    if printf '%s\n' "$_ue_proposals_raw" | grep -q "^NO_PROPOSALS_NEEDED"; then
      print_info "Doc assessment: no changes needed"
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
        rm -f "$_ue_old_tmp" "$_ue_new_tmp"
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
    return "$_ue_apply_rc"
  done

  print_warning "Max proposal regeneration attempts reached — no changes applied"
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
  local _lme_dir="${RITE_STATE_DIR:-}/doc-drift/main"
  [ -d "$_lme_dir" ] || return 0
  local _lme_f _lme_doc _lme_cnt
  while IFS= read -r _lme_f || [ -n "$_lme_f" ]; do
    [ -f "$_lme_f" ] || continue
    _lme_doc="$(awk -F'\t' '{for(i=1;i<=NF;i++){if(substr($i,1,4)=="doc="){print substr($i,5); exit}}}' \
      "$_lme_f" | head -1 || true)"
    [ -n "$_lme_doc" ] || continue
    _lme_cnt="$(grep -c '^doc=' "$_lme_f" || true)"
    [ "$_lme_cnt" -gt 0 ] && printf '%s\n' "$_lme_doc"
  done < <(find "$_lme_dir" -name '*.log' -type f 2>/dev/null | sort || true)
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
  local _mp_target="${RITE_TARGET_BRANCH:-main}"
  local _mp_timeout="${RITE_DOC_ASSESSMENT_TIMEOUT:-300}"

  # Read entry file for this doc from the main-branch drift store
  local _mp_entry_file
  _mp_entry_file="$(_drift_entry_path "$_mp_doc" "main" || true)"
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

    local _mp_raw="" _mp_llm_rc=0
    _mp_raw="$(provider_run_prompt_with_timeout \
      "$(cat "$_mp_prompt_file")" \
      "$(provider_resolve_model doc_update)" \
      true \
      "$_mp_timeout" 2>/dev/null)" || _mp_llm_rc=$?
    rm -f "$_mp_prompt_file"

    if [ "$_mp_llm_rc" -eq 124 ]; then
      print_warning "Provider call timed out after ${_mp_timeout}s — no proposals generated for ${_mp_doc}" >&2
      return 1
    elif [ "$_mp_llm_rc" -ne 0 ]; then
      print_warning "Provider call failed (exit ${_mp_llm_rc}) — no proposals generated for ${_mp_doc}" >&2
      return 1
    fi

    if [ -z "$_mp_raw" ]; then
      print_info "No proposals returned for ${_mp_doc}"
      return 0
    fi

    if printf '%s\n' "$_mp_raw" | grep -q "^NO_PROPOSALS_NEEDED"; then
      print_info "Doc pass: no changes needed for ${_mp_doc}"
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
            drift_log_append "$_mp_p_file" "main" "0" "-" \
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
        rm -f "$_mp_old_tmp" "$_mp_new_tmp"
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
      return 0
    fi

    local _mp_apply_rc=0
    _docs_apply_approved \
      "$_mp_appr_dir" \
      "" \
      "" \
      "reconcile" \
      "$_mp_target" \
      "true" || _mp_apply_rc=$?
    rm -rf "$_mp_appr_dir"
    return "$_mp_apply_rc"
  done

  print_warning "Max proposal regeneration attempts reached for ${_mp_doc} — no changes applied"
  return 1
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
    while IFS= read -r _rd_doc || [ -n "$_rd_doc" ]; do
      [ -n "$_rd_doc" ] || continue
      echo "" >&2
      print_info "Processing doc: ${_rd_doc}"
      _docs_main_entries_pass "$_rd_doc" || true
    done < <(_docs_list_main_entry_docs || true)
    return 0
  fi

  # Fallback: legacy flat drift log (pre-#1425 entries).
  local _rd_drift_path
  _rd_drift_path="$(drift_log_path 2>/dev/null || true)"

  if [ -z "$_rd_drift_path" ] || [ ! -f "$_rd_drift_path" ]; then
    print_info "No drift log found — nothing to reconcile"
    return 0
  fi

  local _rd_count
  _rd_count="$(drift_log_entry_count "$_rd_drift_path" || echo "0")"

  if [ "$_rd_count" -eq 0 ]; then
    print_info "Drift log is empty — nothing to reconcile"
    return 0
  fi

  print_info "Reconciling ${_rd_count} drift entr$([ "$_rd_count" -eq 1 ] && echo 'y' || echo 'ies') from flat log..."
  docs_map_ensure || true
  _docs_update_engine "reconcile" ""
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
# rite_docs [instructions]
#
# Main entry point. Dispatches based on effective documentation state.
#
# Arguments:
#   $@  optional instructions for directed-update (passed through to seam)
# ---------------------------------------------------------------------------
rite_docs() {
  local instructions="${*:-}"

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
