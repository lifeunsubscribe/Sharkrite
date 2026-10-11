#!/bin/bash
# lib/core/docs-command.sh
#
# rite docs [instructions] — circumstantial dispatch entry point for cluster-B
# doc-sync features.
#
# Dispatches based on effective documentation state:
#   never-run   → consent/enable flow (ask once, scaffold .rite/doc-sync.md)
#   run-before  → drift audit (report potential inaccuracies vs current code)
#   input given → directed-update seam (engine lands with #1049)
#
# Public API:
#   rite_docs [instructions]       — main entry point; called by bin/rite
#   rite_docs_directed_update      — stub; replaced by #1049

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
source "$RITE_LIB_DIR/providers/provider-interface.sh"
# load_provider must run at top level (not inside $()) — see behavioral-design.md
load_provider "${RITE_REVIEW_PROVIDER:-claude}"

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
# Stub for the directed-update engine (#1049).
# Returns 1 so callers detect that nothing was applied.
# #1049 replaces this stub body; the dispatch and arg plumbing around it are
# this issue's deliverable.
# ---------------------------------------------------------------------------
rite_docs_directed_update() {
  print_info "Directed doc updates land with #1049 — findings above are recorded; re-run after it ships"
  return 1
}

# ---------------------------------------------------------------------------
# _docs_enable_flow [instructions]
#
# Never-run path: ask the consent question, scaffold .rite/doc-sync.md on yes,
# record RITE_DOC_MODE, and build the docs map.
# If instructions are also provided, they are passed to rite_docs_directed_update
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

    # If the drift log has entries, note that reconciliation lands with #1049
    local drift_path
    drift_path="$(drift_log_path 2>/dev/null || true)"
    if [ -n "$drift_path" ] && [ -f "$drift_path" ]; then
      local entry_count
      entry_count="$(drift_log_entry_count "$drift_path" || echo "0")"
      if [ "$entry_count" -gt 0 ]; then
        print_info "  $entry_count drift entries recorded — reconciliation lands with #1049"
      fi
    fi

    # If instructions were also provided, route to the directed-update seam
    if [ -n "$instructions" ]; then
      echo ""
      rite_docs_directed_update "$instructions" || true
    fi
  else
    # No: record changelog mode + build map
    record_doc_mode "changelog"
    print_info "Changelog mode — drift notes only; run 'rite docs' again to audit"
    docs_map_build
    print_info "Docs map built"

    if [ -n "$instructions" ]; then
      echo ""
      rite_docs_directed_update "$instructions" || true
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

    # Tail-offer: enable doc-sync and reconcile?
    echo ""
    local _enable_reply="N"
    if [ -t 0 ]; then
      read -p "  Enable doc-sync and reconcile these $_finding_count entries now? [y/N] " -n 1 -r
      echo
      _enable_reply="${REPLY:-N}"
    fi
    if [[ "$_enable_reply" =~ ^[Yy]$ ]]; then
      _docs_enable_flow ""
      print_info "Reconcile engine lands with #1049 — entries recorded"
    fi
  else
    # sync mode: report only (applying updates is #1049's engine)
    print_info "Sync mode audit complete — applying updates lands with #1049"
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
        # After scaffolding, route to audit or directed-update if input given
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
        # Input present → directed-update seam (stub until #1049)
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
