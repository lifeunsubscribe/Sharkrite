#!/bin/bash
# lib/core/docs-command.sh
#
# rite docs [instructions] — circumstantial dispatch entry point for cluster-B
# doc-sync features.
#
# Dispatches based on effective documentation state:
#   never-run   → consent/enable flow (ask once, scaffold .rite/doc-sync.md)
#   run-before  → drift audit (report potential inaccuracies vs current code)
#   input given → directed-update engine (docs_directed_update)
#
# Public API:
#   rite_docs [instructions]        — main entry point; called by bin/rite
#   rite_docs_directed_update       — public name used by existing dispatch; forwards to docs_directed_update
#   docs_directed_update INSTR      — directed-update engine (#1049)
#   docs_reconcile_drift            — reconcile all drift backlog entries (#1049)

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
source "$RITE_LIB_DIR/utils/markers.sh"
source "$RITE_LIB_DIR/utils/docs-map.sh"
source "$RITE_LIB_DIR/utils/doc-consent.sh"
source "$RITE_LIB_DIR/utils/drift-log.sh"
source "$RITE_LIB_DIR/providers/provider-interface.sh"
# load_provider must run at top level (not inside $()) — see behavioral-design.md
load_provider "${RITE_REVIEW_PROVIDER:-claude}"

# Source gh-retry for gh_safe (required by _docs_apply_approved).
source "$RITE_LIB_DIR/utils/gh-retry.sh"

# ---------------------------------------------------------------------------
# _docs_resolve_state
#
# Determine effective doc state from file presence + RITE_DOC_MODE env.
# Uses .rite/doc-sync.md existence as the canonical Layer 2 activation switch
# (assess-documentation.sh line 1958 — same gate, no parallel mechanism).
#
# Echoes one of: "never-run", "sync", "changelog", "mismatch"
# ---------------------------------------------------------------------------
_docs_resolve_state() {
  local doc_sync_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/doc-sync.md"

  if [ -f "$doc_sync_file" ]; then
    echo "sync"
    return 0
  fi

  case "${RITE_DOC_MODE:-}" in
    sync)
      # Mode is sync but the file is missing — config/file are out of sync
      echo "mismatch"
      ;;
    changelog)
      echo "changelog"
      ;;
    *)
      # Neither var nor file → never been configured
      echo "never-run"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _docs_ensure_map
#
# Ensure .rite/state/docs-map.tsv exists, respecting RITE_DOCS_MAP_AUTO.
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
# rite_docs_directed_update
#
# Public dispatch name used by existing callers in this file.
# Forwards to docs_directed_update (the engine implementation from #1049).
# The name is part of the #1045 public API surface; do not rename it.
# ---------------------------------------------------------------------------
rite_docs_directed_update() {
  docs_directed_update "$@"
}

# ===========================================================================
# Docs update engine (#1049)
# ===========================================================================

# ---------------------------------------------------------------------------
# _docs_build_map_context MAP_FILE [BYTE_CAP]
#
# Print a human-readable inventory of doc files from the TSV map, suitable
# for inclusion in an LLM prompt. Each file is listed with its headings.
# Capped at BYTE_CAP bytes (default 30000) to keep prompts manageable.
# ---------------------------------------------------------------------------
_docs_build_map_context() {
  local map_file="$1"
  local byte_cap="${2:-30000}"
  local _ctx=""
  local _total=0
  local _cur_file=""
  local _cur_headings=""
  local _line

  if [ ! -f "$map_file" ]; then
    printf '(no docs map available)\n'
    return 0
  fi

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in '#'*) continue ;; esac
    local _fp _h_text
    _fp="$(printf '%s' "$_line" | cut -f1 || true)"
    _h_text="$(printf '%s' "$_line" | cut -f5 || true)"
    [ -z "$_fp" ] && continue

    local _abs="${RITE_PROJECT_ROOT}/${_fp}"
    [ -f "$_abs" ] || continue

    if [ "$_fp" != "$_cur_file" ]; then
      # Flush previous file entry before switching to the new file.
      if [ -n "$_cur_file" ]; then
        local _entry="- ${_cur_file}"
        [ -n "$_cur_headings" ] && _entry="${_entry} (${_cur_headings})"
        _total=$((_total + ${#_entry}))
        if [ "$_total" -gt "$byte_cap" ]; then
          _ctx="${_ctx}(additional docs omitted — byte cap reached)"$'\n'
          _cur_file=""  # Prevent final-flush from re-appending this file after the omitted marker
          break
        fi
        _ctx="${_ctx}${_entry}"$'\n'
      fi
      _cur_file="$_fp"
      _cur_headings=""
    fi

    if [ -n "$_h_text" ]; then
      if [ -n "$_cur_headings" ]; then
        _cur_headings="${_cur_headings}, ${_h_text}"
      else
        _cur_headings="$_h_text"
      fi
    fi
  done < "$map_file"

  # Flush the final file (cap check prevents over-budget appends on normal loop exit).
  if [ -n "$_cur_file" ]; then
    local _last_entry="- ${_cur_file}"
    [ -n "$_cur_headings" ] && _last_entry="${_last_entry} (${_cur_headings})"
    _total=$((_total + ${#_last_entry}))
    if [ "$_total" -gt "$byte_cap" ]; then
      _ctx="${_ctx}(additional docs omitted — byte cap reached)"$'\n'
    else
      _ctx="${_ctx}${_last_entry}"$'\n'
    fi
  fi

  printf '%s' "$_ctx"
}

# ---------------------------------------------------------------------------
# _docs_drift_load_entries LOG_PATH OUT_DIR
#
# Parse the drift log at LOG_PATH and write each delimited entry block to a
# numbered file in OUT_DIR: entry_1.txt, entry_2.txt, …
# Echoes the total entry count.
# ---------------------------------------------------------------------------
_docs_drift_load_entries() {
  local log_path="$1"
  local out_dir="$2"
  # markers.sh is sourced at module load time, so RITE_MARKER_DOC_DRIFT is always set.
  # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_DOC_DRIFT is an internal marker constant (defined in markers.sh), not a user config var; _RITE_ prefix cannot be used as RITE_MARKER_* is the canonical convention for all marker constants; ledger is frozen per 2026-07-14 rule
  local _marker="${RITE_MARKER_DOC_DRIFT}"
  local _entry_idx=0
  local _in_entry=0
  local _entry_buf=""
  local _line

  if [ ! -f "$log_path" ]; then
    echo "0"
    return 0
  fi

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "<!-- ${_marker} pr:"*)
        _in_entry=1
        _entry_buf="${_line}"$'\n'
        ;;
      "<!-- /${_marker} -->")
        if [ "$_in_entry" -eq 1 ]; then
          _entry_buf="${_entry_buf}${_line}"$'\n'
          _entry_idx=$((_entry_idx + 1))
          printf '%s' "$_entry_buf" > "${out_dir}/entry_${_entry_idx}.txt"
          _in_entry=0
          _entry_buf=""
        fi
        ;;
      *)
        if [ "$_in_entry" -eq 1 ]; then
          _entry_buf="${_entry_buf}${_line}"$'\n'
        fi
        ;;
    esac
  done < "$log_path"

  echo "$_entry_idx"
}

# ---------------------------------------------------------------------------
# _docs_drift_burn_entries LOG_PATH BURN_INDICES
#
# Remove the drift entries whose 1-based indices appear in the
# space-separated BURN_INDICES string from the log at LOG_PATH.
# Deletes the entire log file when no entries remain (burn-down semantics).
# Echoes the number of remaining entries after burn-down.
# ---------------------------------------------------------------------------
_docs_drift_burn_entries() {
  local log_path="$1"
  local burn_indices="${2:-}"
  # markers.sh is sourced at module load time, so RITE_MARKER_DOC_DRIFT is always set.
  # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_DOC_DRIFT is an internal marker constant (defined in markers.sh), not a user config var; _RITE_ prefix cannot be used as RITE_MARKER_* is the canonical convention for all marker constants; ledger is frozen per 2026-07-14 rule
  local _marker="${RITE_MARKER_DOC_DRIFT}"

  if [ ! -f "$log_path" ]; then
    echo "0"
    return 0
  fi

  # Nothing to burn: just count existing entries and return.
  if [ -z "$burn_indices" ]; then
    grep -c "<!-- ${_marker} pr:[0-9]" "$log_path" || true
    return 0
  fi

  local _tmp_file
  _tmp_file="$(mktemp)"
  local _entry_idx=0
  local _in_entry=0
  local _skip_entry=0
  local _entry_buf=""
  local _remaining=0
  local _line

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "<!-- ${_marker} pr:"*)
        _entry_idx=$((_entry_idx + 1))
        _in_entry=1
        _skip_entry=0
        # Check whether this entry index is in the burn list.
        local _bi
        for _bi in $burn_indices; do
          if [ "$_bi" = "$_entry_idx" ]; then
            _skip_entry=1
            break
          fi
        done
        [ "$_skip_entry" -eq 0 ] && _remaining=$((_remaining + 1))
        _entry_buf="${_line}"$'\n'
        ;;
      "<!-- /${_marker} -->")
        if [ "$_in_entry" -eq 1 ]; then
          _entry_buf="${_entry_buf}${_line}"$'\n'
          if [ "$_skip_entry" -eq 0 ]; then
            printf '%s' "$_entry_buf" >> "$_tmp_file"
          fi
          _in_entry=0
          _entry_buf=""
          _skip_entry=0
        fi
        ;;
      *)
        if [ "$_in_entry" -eq 1 ]; then
          _entry_buf="${_entry_buf}${_line}"$'\n'
        else
          # Non-entry content (header, separators): pass through.
          printf '%s\n' "$_line" >> "$_tmp_file"
        fi
        ;;
    esac
  done < "$log_path"

  if [ "$_remaining" -eq 0 ]; then
    # All entries drained: delete the log file entirely.
    rm -f "$log_path" "$_tmp_file"
  else
    mv "$_tmp_file" "$log_path"
  fi

  echo "$_remaining"
}

# ---------------------------------------------------------------------------
# _docs_write_update_prompt PROMPT_FILE INSTRUCTION ENTRIES_DIR ENTRY_COUNT
#                           MAP_CONTEXT [ACCUMULATED_FEEDBACK]
#
# Write the LLM prompt for a directed-update round to PROMPT_FILE.
# ---------------------------------------------------------------------------
_docs_write_update_prompt() {
  local prompt_file="$1"
  local instruction="$2"
  local entries_dir="$3"
  local entry_count="$4"
  local map_context="$5"
  local accumulated_feedback="${6:-}"

  local _drift_section=""
  if [ "$entry_count" -gt 0 ]; then
    _drift_section="Current drift log entries (changes that may need doc updates):
"
    local _ei=1
    while [ "$_ei" -le "$entry_count" ]; do
      local _ef="${entries_dir}/entry_${_ei}.txt"
      if [ -f "$_ef" ]; then
        _drift_section="${_drift_section}
[${_ei}] $(cat "$_ef")
"
      fi
      _ei=$((_ei + 1))
    done
  fi

  local _feedback_section=""
  if [ -n "$accumulated_feedback" ]; then
    _feedback_section="REVISION FEEDBACK (incorporate these corrections in the next round):
${accumulated_feedback}
"
  fi

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: instruction, map_context, drift and feedback vars must expand
  cat > "$prompt_file" <<PROMPT_EOF
You are a technical documentation writer. Update or create documentation files as instructed.

INSTRUCTION: ${instruction}

DOCUMENTATION INVENTORY (files you may update or create new files within the same directories):
${map_context}

${_drift_section}
${_feedback_section}
For each documentation change needed, emit EXACTLY this format — no variation:

<<PROPOSAL>>
FILE: {project-relative path to the doc file, e.g. docs/architecture/behavioral-design.md}
ACTION: UPDATE
DRIFT_COVERS: {space-separated 1-based drift entry indices this resolves, or leave the line empty}
<<PROPOSAL_BODY>>
{complete file content — include ALL existing content with your changes applied}
<<END_PROPOSAL>>

To create a new file:

<<PROPOSAL>>
FILE: {project-relative path for the new file, e.g. docs/adr-042-caching.md}
ACTION: CREATE
DRIFT_COVERS: {indices or leave empty}
<<PROPOSAL_BODY>>
{complete new file content}
<<END_PROPOSAL>>

If no documentation changes are needed for this instruction: respond with ONLY the text "NO_CHANGES_NEEDED".

Rules:
- Only propose changes directly related to the instruction
- For UPDATE: emit the COMPLETE current file content with your edits applied (not just the changed section)
- For CREATE: emit the complete new file content
- Reference drift entries by number in DRIFT_COVERS when your proposal resolves them
- Do NOT propose a file that does not need changes
PROMPT_EOF
}

# ---------------------------------------------------------------------------
# _docs_write_reconcile_prompt PROMPT_FILE ENTRIES_DIR ENTRY_COUNT
#                              MAP_CONTEXT [ACCUMULATED_FEEDBACK]
#
# Write the LLM prompt for a reconcile-drift round to PROMPT_FILE.
# ---------------------------------------------------------------------------
_docs_write_reconcile_prompt() {
  local prompt_file="$1"
  local entries_dir="$2"
  local entry_count="$3"
  local map_context="$4"
  local accumulated_feedback="${5:-}"

  local _drift_section="Drift log entries to reconcile (update docs to resolve these):
"
  local _ei=1
  while [ "$_ei" -le "$entry_count" ]; do
    local _ef="${entries_dir}/entry_${_ei}.txt"
    if [ -f "$_ef" ]; then
      _drift_section="${_drift_section}
[${_ei}] $(cat "$_ef")
"
    fi
    _ei=$((_ei + 1))
  done

  local _feedback_section=""
  if [ -n "$accumulated_feedback" ]; then
    _feedback_section="REVISION FEEDBACK:
${accumulated_feedback}
"
  fi

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: drift_section, map_context and feedback vars must expand
  cat > "$prompt_file" <<REC_PROMPT_EOF
You are a technical documentation writer. Reconcile documentation drift.

The drift entries below record merges where code changed but documentation may
not have been updated. For each implicated doc file, propose the necessary update.

DOCUMENTATION INVENTORY (files you may update, or create new files):
${map_context}

${_drift_section}
${_feedback_section}
For each documentation change needed, emit EXACTLY this format:

<<PROPOSAL>>
FILE: {project-relative path to the doc file}
ACTION: UPDATE
DRIFT_COVERS: {space-separated 1-based drift entry indices this resolves}
<<PROPOSAL_BODY>>
{complete file content with your changes applied}
<<END_PROPOSAL>>

For creating a new file:

<<PROPOSAL>>
FILE: {project-relative path for the new file}
ACTION: CREATE
DRIFT_COVERS: {indices}
<<PROPOSAL_BODY>>
{complete new file content}
<<END_PROPOSAL>>

If no changes are warranted: respond with ONLY "NO_CHANGES_NEEDED".
REC_PROMPT_EOF
}

# ---------------------------------------------------------------------------
# _docs_parse_proposals LLM_OUTPUT OUT_DIR
#
# Parse <<PROPOSAL>>…<<END_PROPOSAL>> blocks from LLM_OUTPUT into structured
# files in OUT_DIR:
#   proposal_N_file.txt    — project-relative target path
#   proposal_N_action.txt  — UPDATE or CREATE
#   proposal_N_drift.txt   — space-separated 1-based drift indices (may be empty)
#   proposal_N_content.txt — full proposed file content
#
# Echoes the total proposal count.
# ---------------------------------------------------------------------------
_docs_parse_proposals() {
  local llm_output="$1"
  local out_dir="$2"
  local _prop_idx=0
  local _in_prop=0
  local _in_body=0
  local _prop_file=""
  local _prop_action=""
  local _prop_drift=""
  local _body_file=""
  local _line

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "<<PROPOSAL>>")
        _in_prop=1
        _in_body=0
        _prop_file=""
        _prop_action=""
        _prop_drift=""
        _body_file=""
        ;;
      "<<PROPOSAL_BODY>>")
        if [ "$_in_prop" -eq 1 ] && [ -n "$_prop_file" ]; then
          _prop_idx=$((_prop_idx + 1))
          _body_file="${out_dir}/proposal_${_prop_idx}_content.txt"
          printf '' > "$_body_file"
          printf '%s' "$_prop_file" > "${out_dir}/proposal_${_prop_idx}_file.txt"
          printf '%s' "$_prop_action" > "${out_dir}/proposal_${_prop_idx}_action.txt"
          printf '%s' "$_prop_drift" > "${out_dir}/proposal_${_prop_idx}_drift.txt"
          _in_body=1
        fi
        ;;
      "<<END_PROPOSAL>>")
        _in_prop=0
        _in_body=0
        _body_file=""
        ;;
      *)
        if [ "$_in_body" -eq 1 ] && [ -n "$_body_file" ]; then
          printf '%s\n' "$_line" >> "$_body_file"
        elif [ "$_in_prop" -eq 1 ] && [ "$_in_body" -eq 0 ]; then
          # Parse header fields (strip leading "KEY: " prefix portably).
          case "$_line" in
            FILE:*)
              _prop_file="${_line#FILE:}"
              _prop_file="${_prop_file# }"
              # Reject absolute paths and traversal attempts — flag early so preview omits them.
              case "$_prop_file" in
                /*|*..*) print_warning "Unsafe path rejected from LLM proposal: ${_prop_file}" >&2; _prop_file="" ;;
              esac
              ;;
            ACTION:*)
              _prop_action="${_line#ACTION:}"
              _prop_action="${_prop_action# }"
              ;;
            DRIFT_COVERS:*)
              _prop_drift="${_line#DRIFT_COVERS:}"
              _prop_drift="${_prop_drift# }"
              ;;
          esac
        fi
        ;;
    esac
  done <<EOF_PARSE
$llm_output
EOF_PARSE

  echo "$_prop_idx"
}

# ---------------------------------------------------------------------------
# _docs_show_all_proposals PROPOSAL_DIR COUNT PROJECT_ROOT
#
# Display all proposals: unified diff for UPDATE, full content for CREATE.
# Also shows which drift entries each proposal covers.
# ---------------------------------------------------------------------------
_docs_show_all_proposals() {
  local proposal_dir="$1"
  local count="$2"
  local project_root="$3"
  local _i=1

  while [ "$_i" -le "$count" ]; do
    local _pfile _paction _pdrift _pcontent_file
    _pfile="$(cat "${proposal_dir}/proposal_${_i}_file.txt" 2>/dev/null || true)"
    _paction="$(cat "${proposal_dir}/proposal_${_i}_action.txt" 2>/dev/null || true)"
    _pdrift="$(cat "${proposal_dir}/proposal_${_i}_drift.txt" 2>/dev/null || true)"
    _pcontent_file="${proposal_dir}/proposal_${_i}_content.txt"

    echo "" >&2
    echo "┌─ Proposal ${_i}/${count}: ${_paction:-UPDATE} ${_pfile}" >&2
    if [ -n "$_pdrift" ]; then
      echo "│  Covers drift entries: ${_pdrift}" >&2
    fi
    echo "│" >&2

    if [ "$_paction" = "CREATE" ]; then
      echo "│  [NEW FILE — full content]" >&2
      while IFS= read -r _cl || [ -n "$_cl" ]; do
        printf '│  %s\n' "$_cl" >&2
      done < "$_pcontent_file"
    else
      local _orig="${project_root}/${_pfile}"
      if [ -f "$_orig" ]; then
        # Show a unified diff between the original and proposed content.
        diff -u "$_orig" "$_pcontent_file" 2>/dev/null | \
          while IFS= read -r _dl || [ -n "$_dl" ]; do
            printf '│  %s\n' "$_dl" >&2
          done || true
      else
        echo "│  [NEW FILE (path not yet in tree)]" >&2
        while IFS= read -r _cl || [ -n "$_cl" ]; do
          printf '│  %s\n' "$_cl" >&2
        done < "$_pcontent_file"
      fi
    fi

    echo "└──────────────────────────────────────────────────────────" >&2
    _i=$((_i + 1))
  done
}

# ---------------------------------------------------------------------------
# _docs_apply_approved INSTRUCTION PROPOSAL_DIR COUNT
#
# Apply all COUNT proposals from PROPOSAL_DIR in a temporary worktree forked
# from origin/${RITE_TARGET_BRANCH:-main}. Burns down covered drift entries in
# the same commit. Creates a docs PR (no auto-merge) and prints its URL.
#
# Integration-aware base: both the worktree fork point and the gh pr create
# --base argument use ${RITE_TARGET_BRANCH:-main} so non-main integration
# branches are honoured automatically.
# ---------------------------------------------------------------------------
_docs_apply_approved() {
  local instruction="$1"
  local proposal_dir="$2"
  local count="$3"

  # Integration-aware base: honour RITE_TARGET_BRANCH with main as fallback.
  # This variable is set by the integration-branch feature (cluster A) and is
  # referenced defensively here — we do not implement its plumbing.
  local base_branch="${RITE_TARGET_BRANCH:-main}"

  local _ts
  _ts="$(date +%Y%m%d-%H%M%S)"
  local docs_branch="docs/directed-update-${_ts}-$$"
  local wt_dir="${RITE_PROJECT_ROOT}/.rite/worktrees/docs-update-$$-${_ts}"

  # Trap: clean up worktree on interrupt so the registered branch does not orphan.
  # Variable-scoped (non-glob) per project trap conventions.
  trap "git -C \"${RITE_PROJECT_ROOT}\" worktree remove --force \"${wt_dir}\" 2>/dev/null || true; rm -rf \"${wt_dir}\" 2>/dev/null || true" INT TERM

  # Fetch the target branch so the worktree fork is current.
  git -C "$RITE_PROJECT_ROOT" fetch origin "$base_branch" 2>/dev/null \
    || print_warning "Could not fetch origin/${base_branch} — using local state"

  mkdir -p "$(dirname "$wt_dir")"
  if ! git -C "$RITE_PROJECT_ROOT" worktree add -b "$docs_branch" \
      "$wt_dir" "origin/${RITE_TARGET_BRANCH:-main}" 2>/dev/null; then
    print_warning "Could not fork from origin/${base_branch} — falling back to HEAD"
    git -C "$RITE_PROJECT_ROOT" worktree add -b "$docs_branch" "$wt_dir" HEAD
  fi

  # Apply each proposal's content to the worktree.
  local _i=1
  local _all_drift_indices=""
  while [ "$_i" -le "$count" ]; do
    local _pfile _paction _pdrift
    _pfile="$(cat "${proposal_dir}/proposal_${_i}_file.txt" 2>/dev/null || true)"
    _paction="$(cat "${proposal_dir}/proposal_${_i}_action.txt" 2>/dev/null || true)"
    _pdrift="$(cat "${proposal_dir}/proposal_${_i}_drift.txt" 2>/dev/null || true)"

    if [ -z "$_pfile" ]; then
      _i=$((_i + 1))
      continue
    fi

    # Validate path: reject absolute paths and traversal attempts to prevent
    # writes outside the worktree (the sandboxing guarantee of this function).
    case "$_pfile" in
      /*|*..*)
        print_warning "  Rejected unsafe path: ${_pfile} — skipping"
        _i=$((_i + 1))
        continue
        ;;
    esac

    local _target="${wt_dir}/${_pfile}"
    mkdir -p "$(dirname "$_target")"
    cp "${proposal_dir}/proposal_${_i}_content.txt" "$_target"
    print_info "  Applied: ${_paction:-UPDATE} ${_pfile}"

    if [ -n "$_pdrift" ]; then
      _all_drift_indices="${_all_drift_indices} ${_pdrift}"
    fi

    _i=$((_i + 1))
  done

  # Burn down covered drift entries in the worktree's copy of the drift log.
  # The drift log in the worktree (forked from origin/base) is the authoritative
  # version — drift_log_append commits+pushes after each append, so origin has it.
  # Derive path from drift_log_path() to avoid hardcoding the filename here.
  local _source_drift_log _drift_log_rel _wt_drift_log
  _source_drift_log="$(drift_log_path 2>/dev/null || true)"
  _drift_log_rel="${_source_drift_log#"${RITE_PROJECT_ROOT}/"}"
  _wt_drift_log="${wt_dir}/${_drift_log_rel}"
  if [ -n "$_all_drift_indices" ] && [ -f "$_wt_drift_log" ]; then
    # Verify the worktree log has the same entry count as the local log before
    # burning by positional index — a diverged count means positions would be wrong.
    local _local_entry_count _wt_entry_count
    _local_entry_count="$(drift_log_entry_count "$_source_drift_log" 2>/dev/null || echo "0")"
    _wt_entry_count="$(drift_log_entry_count "$_wt_drift_log" 2>/dev/null || echo "0")"
    if [ "$_local_entry_count" != "$_wt_entry_count" ]; then
      print_warning "  Drift log diverged (local: ${_local_entry_count}, worktree: ${_wt_entry_count}) — skipping burn-down to prevent wrong-entry removal"
    else
      local _remaining
      _remaining="$(_docs_drift_burn_entries "$_wt_drift_log" "$_all_drift_indices")"
      if [ "$_remaining" -eq 0 ]; then
        # _docs_drift_burn_entries deleted the file; stage the deletion.
        git -C "$wt_dir" rm --force "$_drift_log_rel" 2>/dev/null || true
        print_info "  Drift log fully drained — ${_drift_log_rel} deleted"
      else
        print_info "  Drift log: ${_remaining} entries remain after burn-down"
      fi
    fi
  fi

  # Stage, commit, push.
  git -C "$wt_dir" add . 2>/dev/null || true

  local _commit_title
  if [ "$instruction" = "reconcile" ] || [ -z "$instruction" ]; then
    _commit_title="docs: reconcile drift backlog"
  else
    _commit_title="docs: directed update — ${instruction}"
    [ "${#_commit_title}" -gt 72 ] && _commit_title="${_commit_title:0:69}..."
  fi

  if ! git -C "$wt_dir" commit -m "$_commit_title" 2>/dev/null; then
    print_warning "Nothing to commit — proposals produced no file changes"
    trap - INT TERM
    git -C "$RITE_PROJECT_ROOT" worktree remove --force "$wt_dir" 2>/dev/null || true
    rm -rf "$wt_dir" 2>/dev/null || true
    return 0
  fi

  # Push the docs branch (integration-aware base is on main here; the branch
  # name is self-descriptive for the docs PR).
  if ! git -C "$wt_dir" push origin "$docs_branch" 2>/dev/null; then
    print_warning "Push failed — branch '${docs_branch}' committed locally but not pushed"
    trap - INT TERM
    git -C "$RITE_PROJECT_ROOT" worktree remove --force "$wt_dir" 2>/dev/null || true
    rm -rf "$wt_dir" 2>/dev/null || true
    return 1
  fi

  # Build PR body.
  local _pr_body_file
  _pr_body_file="$(mktemp)"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: instruction, base_branch and list vars must expand
  cat > "$_pr_body_file" <<PR_BODY_EOF
## Docs update

**Instruction**: ${instruction}
**Base branch**: ${base_branch}

### Files changed or created

$(
  _j=1
  while [ "$_j" -le "$count" ]; do
    _pf="$(cat "${proposal_dir}/proposal_${_j}_file.txt" 2>/dev/null || true)"
    _pa="$(cat "${proposal_dir}/proposal_${_j}_action.txt" 2>/dev/null || true)"
    [ -n "$_pf" ] && printf '- %s: %s\n' "${_pa:-UPDATE}" "$_pf"
    _j=$((_j + 1))
  done
)

### Drift entries drained

${_all_drift_indices:-(none)}

---
*Created by \`rite docs\` — review and merge manually (no auto-merge).*
PR_BODY_EOF

  # Create the PR with the integration-aware base.
  # gh_safe wraps gh with retry; use --base ${RITE_TARGET_BRANCH:-main} (same
  # variable as the worktree fork point above — both must stay in sync).
  # The --label flag is intentionally absent: repos without a 'documentation' label
  # would fail the create. Instead, attach the label as a best-effort post-create edit.
  local _pr_url
  if ! _pr_url="$(gh_safe pr create \
    --base "${RITE_TARGET_BRANCH:-main}" \
    --head "$docs_branch" \
    --title "$_commit_title" \
    --body-file "$_pr_body_file" 2>/dev/null)"; then
    print_warning "PR creation failed — branch '${docs_branch}' is pushed; create the PR manually"
    rm -f "$_pr_body_file"
    trap - INT TERM
    git -C "$RITE_PROJECT_ROOT" worktree remove --force "$wt_dir" 2>/dev/null || true
    rm -rf "$wt_dir" 2>/dev/null || true
    return 1
  fi
  rm -f "$_pr_body_file"
  # Best-effort label — ignored for repos without a 'documentation' label.
  gh_safe pr edit "$_pr_url" --add-label "documentation" 2>/dev/null || true

  print_success "Docs PR created: ${_pr_url}"
  print_info "Review and merge manually — no auto-merge."

  # Clean up the temporary worktree.
  trap - INT TERM
  git -C "$RITE_PROJECT_ROOT" worktree remove --force "$wt_dir" 2>/dev/null || true
  rm -rf "$wt_dir" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# docs_directed_update INSTRUCTION
#
# Implements `rite docs "<instruction>"` (case 3 of #1045's dispatcher):
#   1. Ensure docs map is fresh.
#   2. Load drift log entries as numbered context.
#   3. Call the LLM (doc_assessment role) to generate proposals.
#   4. Run the preview → (y)es / (n)o / (f)eedback loop (modelled on plan-issues).
#   5. Apply approved proposals in a temp worktree and open a docs PR.
#
# Works in BOTH consent modes (sync and changelog): an explicitly commanded,
# previewed, human-approved update IS consent — this engine never checks the
# Layer-2 consent gate (.rite/doc-sync.md, assessed at assess-documentation.sh
# line 1960) before an approved apply. That gate governs AUTONOMOUS writes only.
# ---------------------------------------------------------------------------
docs_directed_update() {
  local instruction="${1:-}"
  if [ -z "$instruction" ]; then
    print_warning "docs directed update: no instruction provided (usage: rite docs \"<instruction>\")"
    return 1
  fi

  print_info "Directed doc update: ${instruction}"

  # Ensure docs map is current (honours RITE_DOCS_MAP_AUTO).
  docs_map_ensure || {
    print_warning "docs map unavailable — cannot proceed with directed update"
    return 1
  }

  local map_file
  map_file="$(docs_map_path)"

  # Temp workspace for this invocation (scoped with PID to isolate concurrent calls).
  local _du_tmpdir
  _du_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/rite_docs_du_$$_XXXXXX")"
  local _du_proposal_dir="${_du_tmpdir}/proposals"
  mkdir -p "$_du_proposal_dir"
  # Cleanup trap (variable-scoped, non-glob per project conventions).
  trap "rm -rf \"${_du_tmpdir}\" 2>/dev/null || true" INT TERM

  # Load drift log entries into numbered files for prompt context.
  local _drift_log
  _drift_log="$(drift_log_path 2>/dev/null || true)"
  local _entry_count=0
  if [ -n "$_drift_log" ] && [ -f "$_drift_log" ]; then
    _entry_count="$(_docs_drift_load_entries "$_drift_log" "$_du_tmpdir")"
  fi

  local _map_ctx
  _map_ctx="$(_docs_build_map_context "$map_file" 30000)"

  local _accumulated_feedback=""
  local _iteration=0

  while true; do
    _iteration=$((_iteration + 1))

    # Build prompt.
    local _du_prompt_file
    _du_prompt_file="$(mktemp "${_du_tmpdir}/prompt_XXXXXX")"
    _docs_write_update_prompt "$_du_prompt_file" "$instruction" "$_du_tmpdir" \
      "$_entry_count" "$_map_ctx" "$_accumulated_feedback"

    print_info "Requesting doc proposals (round ${_iteration})…"
    local _du_llm_out _du_llm_rc
    _du_llm_rc=0
    _du_llm_out="$(provider_run_prompt_with_timeout \
      "$(cat "$_du_prompt_file")" \
      "$(provider_resolve_model doc_assessment)" \
      true \
      "${RITE_DOC_ASSESSMENT_TIMEOUT:-300}" 2>/dev/null)" \
      || _du_llm_rc=$?
    rm -f "$_du_prompt_file"

    if [ "$_du_llm_rc" -eq 124 ]; then
      print_warning "Doc update: provider timed out after ${RITE_DOC_ASSESSMENT_TIMEOUT:-300}s"
      rm -rf "$_du_tmpdir" 2>/dev/null || true
      return 1
    elif [ "$_du_llm_rc" -ne 0 ]; then
      print_warning "Doc update: provider call failed (exit ${_du_llm_rc})"
      rm -rf "$_du_tmpdir" 2>/dev/null || true
      return 1
    fi

    if echo "$_du_llm_out" | grep -q "^NO_CHANGES_NEEDED"; then
      print_info "No documentation changes needed for this instruction"
      rm -rf "$_du_tmpdir" 2>/dev/null || true
      return 0
    fi

    # Parse proposals into structured temp files.
    rm -f "${_du_proposal_dir}"/proposal_* 2>/dev/null || true
    local _du_prop_count
    _du_prop_count="$(_docs_parse_proposals "$_du_llm_out" "$_du_proposal_dir")"

    if [ "$_du_prop_count" -eq 0 ]; then
      print_warning "No proposals found in provider response — try a more specific instruction"
      rm -rf "$_du_tmpdir" 2>/dev/null || true
      return 0
    fi

    # Show all proposals to the user.
    _docs_show_all_proposals "$_du_proposal_dir" "$_du_prop_count" "$RITE_PROJECT_ROOT"

    echo ""
    local _DU_RESP=""
    # EOF on non-interactive stdin (e.g. piped /dev/null): read returns non-zero.
    # Treat EOF as cancel to avoid an unbounded loop of paid LLM calls.
    if ! read -p "Apply these doc changes? (y)es / (n)o / (f)eedback: " -r _DU_RESP; then
      print_info "Non-interactive — no changes applied"
      trap - INT TERM
      rm -rf "$_du_tmpdir" 2>/dev/null || true
      return 0
    fi

    case "$_DU_RESP" in
      [Yy]|[Yy]es|yes)
        _docs_apply_approved "$instruction" "$_du_proposal_dir" "$_du_prop_count"
        local _du_apply_rc=$?
        trap - INT TERM
        rm -rf "$_du_tmpdir" 2>/dev/null || true
        return $_du_apply_rc
        ;;
      [Nn]|[Nn]o|no)
        print_info "Cancelled — no changes applied"
        trap - INT TERM
        rm -rf "$_du_tmpdir" 2>/dev/null || true
        return 0
        ;;
      *)
        # Anything else is treated as feedback for the next regeneration round.
        local _du_fb="$_DU_RESP"
        if echo "$_DU_RESP" | grep -qiE '^f(eedback)?$'; then
          echo ""
          echo "What changes do you want? (press Enter twice when done)"
          echo ""
          _du_fb=""
          local _du_fe=0
          while IFS= read -r _du_fl; do
            if [ -z "$_du_fl" ]; then
              _du_fe=$((_du_fe + 1))
              [ "$_du_fe" -ge 2 ] && break
              _du_fb="${_du_fb}"$'\n'
            else
              _du_fe=0
              _du_fb="${_du_fb}${_du_fl}"$'\n'
            fi
          done
        fi

        if [ -z "$_du_fb" ]; then
          print_warning "No feedback provided — showing proposals again"
          continue
        fi

        # Accumulate feedback across iterations so corrections compound.
        if [ -n "$_accumulated_feedback" ]; then
          _accumulated_feedback="${_accumulated_feedback}

---
${_du_fb}"
        else
          _accumulated_feedback="$_du_fb"
        fi

        print_status "Regenerating with feedback…"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# docs_reconcile_drift
#
# Reconcile mode: load all drift backlog entries, generate proposals (one per
# implicated doc, grouped), run the preview → approve/skip/feedback loop, and
# apply all approved changes in ONE docs PR.
#
# Zero drift entries → print info and exit 0 (not an error).
# ---------------------------------------------------------------------------
docs_reconcile_drift() {
  local _drift_log
  _drift_log="$(drift_log_path 2>/dev/null || true)"

  if [ -z "$_drift_log" ] || [ ! -f "$_drift_log" ]; then
    print_info "No drift log found — nothing to reconcile"
    return 0
  fi

  local _rc_tmpdir
  _rc_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/rite_docs_rc_$$_XXXXXX")"
  local _rc_proposal_dir="${_rc_tmpdir}/proposals"
  mkdir -p "$_rc_proposal_dir"
  # Cleanup trap (variable-scoped, non-glob per project conventions).
  trap "rm -rf \"${_rc_tmpdir}\" 2>/dev/null || true" INT TERM

  local _entry_count
  _entry_count="$(_docs_drift_load_entries "$_drift_log" "$_rc_tmpdir")"

  if [ "$_entry_count" -eq 0 ]; then
    print_info "Drift log has no entries — nothing to reconcile"
    rm -rf "$_rc_tmpdir" 2>/dev/null || true
    return 0
  fi

  print_info "Reconciling ${_entry_count} drift entry(ies)…"

  # Ensure docs map is current.
  docs_map_ensure || {
    print_warning "docs map unavailable — cannot proceed with reconcile"
    rm -rf "$_rc_tmpdir" 2>/dev/null || true
    return 1
  }

  local map_file
  map_file="$(docs_map_path)"
  local _map_ctx
  _map_ctx="$(_docs_build_map_context "$map_file" 30000)"

  local _accumulated_feedback=""
  local _rc_iteration=0

  while true; do
    _rc_iteration=$((_rc_iteration + 1))

    local _rc_prompt_file
    _rc_prompt_file="$(mktemp "${_rc_tmpdir}/prompt_XXXXXX")"
    _docs_write_reconcile_prompt "$_rc_prompt_file" "$_rc_tmpdir" "$_entry_count" \
      "$_map_ctx" "$_accumulated_feedback"

    print_info "Requesting reconcile proposals (round ${_rc_iteration})…"
    local _rc_llm_out _rc_llm_rc
    _rc_llm_rc=0
    _rc_llm_out="$(provider_run_prompt_with_timeout \
      "$(cat "$_rc_prompt_file")" \
      "$(provider_resolve_model doc_assessment)" \
      true \
      "${RITE_DOC_ASSESSMENT_TIMEOUT:-300}" 2>/dev/null)" \
      || _rc_llm_rc=$?
    rm -f "$_rc_prompt_file"

    if [ "$_rc_llm_rc" -eq 124 ]; then
      print_warning "Doc reconcile: provider timed out after ${RITE_DOC_ASSESSMENT_TIMEOUT:-300}s"
      rm -rf "$_rc_tmpdir" 2>/dev/null || true
      return 1
    elif [ "$_rc_llm_rc" -ne 0 ]; then
      print_warning "Doc reconcile: provider call failed (exit ${_rc_llm_rc})"
      rm -rf "$_rc_tmpdir" 2>/dev/null || true
      return 1
    fi

    if echo "$_rc_llm_out" | grep -q "^NO_CHANGES_NEEDED"; then
      print_info "No changes needed — drift entries may already be resolved"
      rm -rf "$_rc_tmpdir" 2>/dev/null || true
      return 0
    fi

    rm -f "${_rc_proposal_dir}"/proposal_* 2>/dev/null || true
    local _rc_prop_count
    _rc_prop_count="$(_docs_parse_proposals "$_rc_llm_out" "$_rc_proposal_dir")"

    if [ "$_rc_prop_count" -eq 0 ]; then
      print_warning "No proposals generated for drift reconcile"
      rm -rf "$_rc_tmpdir" 2>/dev/null || true
      return 0
    fi

    _docs_show_all_proposals "$_rc_proposal_dir" "$_rc_prop_count" "$RITE_PROJECT_ROOT"

    echo ""
    local _RC_RESP=""
    # EOF on non-interactive stdin: treat as cancel to avoid an unbounded loop of LLM calls.
    if ! read -p "Apply these reconcile changes? (y)es / (n)o / (f)eedback: " -r _RC_RESP; then
      print_info "Non-interactive — no changes applied"
      trap - INT TERM
      rm -rf "$_rc_tmpdir" 2>/dev/null || true
      return 0
    fi

    case "$_RC_RESP" in
      [Yy]|[Yy]es|yes)
        _docs_apply_approved "reconcile" "$_rc_proposal_dir" "$_rc_prop_count"
        local _rc_apply_rc=$?
        trap - INT TERM
        rm -rf "$_rc_tmpdir" 2>/dev/null || true
        return $_rc_apply_rc
        ;;
      [Nn]|[Nn]o|no)
        print_info "Cancelled — no reconcile changes applied"
        trap - INT TERM
        rm -rf "$_rc_tmpdir" 2>/dev/null || true
        return 0
        ;;
      *)
        local _rc_fb="$_RC_RESP"
        if echo "$_RC_RESP" | grep -qiE '^f(eedback)?$'; then
          echo ""
          echo "What changes do you want? (press Enter twice when done)"
          echo ""
          _rc_fb=""
          local _rc_fe=0
          while IFS= read -r _rc_fl; do
            if [ -z "$_rc_fl" ]; then
              _rc_fe=$((_rc_fe + 1))
              [ "$_rc_fe" -ge 2 ] && break
              _rc_fb="${_rc_fb}"$'\n'
            else
              _rc_fe=0
              _rc_fb="${_rc_fb}${_rc_fl}"$'\n'
            fi
          done
        fi

        if [ -z "$_rc_fb" ]; then
          print_warning "No feedback provided — showing proposals again"
          continue
        fi

        if [ -n "$_accumulated_feedback" ]; then
          _accumulated_feedback="${_accumulated_feedback}

---
${_rc_fb}"
        else
          _accumulated_feedback="$_rc_fb"
        fi

        print_status "Regenerating with feedback…"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# _docs_enable_flow [instructions]
#
# Never-run path: ask the consent question, scaffold .rite/doc-sync.md on yes,
# record RITE_DOC_MODE, and build the docs map.
# If instructions are also provided, they are passed to docs_directed_update
# after the enable flow completes.
#
# Prompt is default-no; non-TTY takes the "no" branch (never hangs).
# ---------------------------------------------------------------------------
_docs_enable_flow() {
  local instructions="${1:-}"

  local doc_sync_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/doc-sync.md"
  local doc_sync_example_local="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/doc-sync.md.example"
  local doc_sync_example_install="${RITE_INSTALL_DIR:-${RITE_LIB_DIR%/lib}}/templates/doc-sync.md.example"

  echo "" >&2
  echo "  Sharkrite can update files in docs/ when code changes make them inaccurate." >&2

  local reply_val="N"
  if [ -t 0 ]; then
    read -p "  Enable doc-sync and keep docs/ accurate after each merge? [y/N] " -n 1 -r
    echo
    reply_val="${REPLY:-N}"
  fi

  if [[ "$reply_val" =~ ^[Yy]$ ]]; then
    # Yes: scaffold doc-sync.md from template + record sync + build map
    if [ ! -f "$doc_sync_file" ]; then
      if [ -f "$doc_sync_example_local" ]; then
        cp "$doc_sync_example_local" "$doc_sync_file"
      elif [ -f "$doc_sync_example_install" ]; then
        cp "$doc_sync_example_install" "$doc_sync_file"
      else
        print_warning "No template found — create .rite/doc-sync.md manually"
        return 1
      fi
    fi
    record_doc_mode "sync"
    print_success "Doc-sync enabled — .rite/doc-sync.md created (edit to customize)"
    docs_map_build
    print_success "Docs map built"

    # If drift entries exist, offer to reconcile them now that sync is enabled.
    local drift_path
    drift_path="$(drift_log_path 2>/dev/null || true)"
    if [ -n "$drift_path" ] && [ -f "$drift_path" ]; then
      local entry_count
      entry_count="$(drift_log_entry_count "$drift_path" || echo "0")"
      if [ "$entry_count" -gt 0 ]; then
        echo "" >&2
        local _reconcile_reply="N"
        if [ -t 0 ]; then
          read -p "  Reconcile $entry_count existing drift entries now? [y/N] " -n 1 -r
          echo
          _reconcile_reply="${REPLY:-N}"
        fi
        if [[ "$_reconcile_reply" =~ ^[Yy]$ ]]; then
          docs_reconcile_drift || true
        else
          print_info "  $entry_count drift entries recorded — run 'rite docs' to reconcile later"
        fi
      fi
    fi

    # If instructions were also provided, route to the directed-update engine.
    if [ -n "$instructions" ]; then
      echo ""
      docs_directed_update "$instructions" || true
    fi
  else
    # No: record changelog mode + build map
    record_doc_mode "changelog"
    print_info "Changelog mode — drift notes only; run 'rite docs' again to audit"
    docs_map_build
    print_info "Docs map built"

    if [ -n "$instructions" ]; then
      echo ""
      docs_directed_update "$instructions" || true
    fi
  fi
}

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

    # Tail-offer: enable doc-sync and reconcile now?
    echo ""
    local _enable_reply="N"
    if [ -t 0 ]; then
      read -p "  Enable doc-sync and reconcile these $_finding_count entries now? [y/N] " -n 1 -r
      echo
      _enable_reply="${REPLY:-N}"
    fi
    if [[ "$_enable_reply" =~ ^[Yy]$ ]]; then
      # _docs_enable_flow already contains its own reconcile offer — let that
      # single site own the decision; do NOT add a second unconditional call here.
      _docs_enable_flow ""
    fi
  else
    # sync mode: report only (applying updates is the directed-update engine)
    print_info "Sync mode audit complete — run 'rite docs \"<instruction>\"' to apply updates"
  fi
}

# ---------------------------------------------------------------------------
# rite_docs [instructions]
#
# Main entry point. Dispatches based on effective documentation state.
#
# Arguments:
#   $@  optional instructions for directed-update (passed through to engine)
# ---------------------------------------------------------------------------
rite_docs() {
  local instructions="${*:-}"

  local state
  state="$(_docs_resolve_state)"

  case "$state" in

    never-run)
      # First-ever run: ask consent, then optionally route input
      _docs_enable_flow "$instructions"
      ;;

    mismatch)
      # RITE_DOC_MODE=sync but .rite/doc-sync.md is missing
      local doc_sync_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/doc-sync.md"
      local doc_sync_example_local="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/doc-sync.md.example"
      local doc_sync_example_install="${RITE_INSTALL_DIR:-${RITE_LIB_DIR%/lib}}/templates/doc-sync.md.example"

      print_warning "RITE_DOC_MODE=sync is recorded but .rite/doc-sync.md is missing"

      local _rescaffold_reply="N"
      if [ -t 0 ]; then
        read -p "  Re-scaffold .rite/doc-sync.md from the template? [y/N] " -n 1 -r
        echo
        _rescaffold_reply="${REPLY:-N}"
      fi

      if [[ "$_rescaffold_reply" =~ ^[Yy]$ ]]; then
        if [ -f "$doc_sync_example_local" ]; then
          cp "$doc_sync_example_local" "$doc_sync_file"
        elif [ -f "$doc_sync_example_install" ]; then
          cp "$doc_sync_example_install" "$doc_sync_file"
        else
          print_warning "No template found — create .rite/doc-sync.md manually"
          exit 1
        fi
        print_success ".rite/doc-sync.md re-scaffolded from template"
        # After scaffolding, route to directed-update or audit.
        if [ -n "$instructions" ]; then
          rite_docs_directed_update "$instructions" || true
        else
          _docs_run_audit "sync"
        fi
      else
        echo "  To fix: re-run 'rite docs', or set RITE_DOC_MODE=changelog in .rite/config" >&2
        exit 1
      fi
      ;;

    sync|changelog)
      # Ensure map exists (self-heal silently or prompt when auto-rebuild disabled)
      _docs_ensure_map || exit 1

      if [ -n "$instructions" ]; then
        # Input present → directed-update engine (via public API name for stub-ability)
        rite_docs_directed_update "$instructions" || true
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
