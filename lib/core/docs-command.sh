#!/bin/bash
# lib/core/docs-command.sh
#
# Orchestrator for `rite docs [instructions]`.
#
# Dispatches based on documentation state (circumstantial routing):
#   never-run       → consent/enable flow (ask doc mode, scaffold if yes, build map)
#   run-before      → drift audit (ensure map, run doc_assessment, report findings)
#   input present   → directed-update seam (stub: deferred to #1049)
#
# The three cases can overlap: input + never-run → enable flow first, then seam.
#
# Layer 2 activation switch (canonical): .rite/doc-sync.md existence.
# (assess-documentation.sh line 1647 — do NOT build a parallel mechanism)
#
# Public API:
#   rite_docs [instructions...]       — main entrypoint called by bin/rite
#   rite_docs_directed_update [...]   — stub; body lands in #1049

set -euo pipefail

# ---------------------------------------------------------------------------
# Re-source guard: skip if already loaded (idempotent sourcing).
# Sentinel: rite_docs — stable, defined only by this file.
# ---------------------------------------------------------------------------
if declare -f rite_docs >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Bootstrap: ensure RITE_LIB_DIR and helpers are available.
# In production, config.sh is always loaded first by bin/rite.
# The guard here makes this file sourceable standalone (re-source safety test).
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
# load_provider must be called at top level, never inside $()
load_provider "${RITE_REVIEW_PROVIDER:-claude}"

# ---------------------------------------------------------------------------
# _docs_cmd_effective_state
#
# Echo one of: "sync" | "changelog" | "mismatch" | "never-run"
#
# Effective state resolution:
#   .rite/doc-sync.md exists                     → "sync"
#   RITE_DOC_MODE=sync but doc-sync.md missing   → "mismatch"
#   RITE_DOC_MODE=changelog                      → "changelog"
#   neither var nor file                         → "never-run"
# ---------------------------------------------------------------------------
_docs_cmd_effective_state() {
  local doc_sync_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/doc-sync.md"
  local doc_mode="${RITE_DOC_MODE:-}"

  if [ -f "$doc_sync_file" ]; then
    echo "sync"
    return 0
  fi

  case "$doc_mode" in
    sync)
      # doc-sync.md present would have been caught above; file is missing
      echo "mismatch"
      ;;
    changelog)
      echo "changelog"
      ;;
    *)
      echo "never-run"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _docs_cmd_ensure_map
#
# Self-heal: ensure the docs map exists.
# - RITE_DOCS_MAP_AUTO=true (default): silent rebuild via docs_map_ensure
# - RITE_DOCS_MAP_AUTO=false and map missing: prompt [y/N] (default-no)
#   Declined → exit 1 with manual rebuild instruction.
# - Map already exists: no-op (docs_map_ensure is idempotent on missing-only).
# ---------------------------------------------------------------------------
_docs_cmd_ensure_map() {
  local map_file
  map_file="$(docs_map_path)"

  if [ -f "$map_file" ]; then
    return 0
  fi

  # Map is missing.
  if [ "${RITE_DOCS_MAP_AUTO:-true}" != "false" ]; then
    # Auto-rebuild allowed: silent rebuild
    docs_map_ensure || true
    return 0
  fi

  # RITE_DOCS_MAP_AUTO=false and map is missing — warn and prompt (default-no)
  print_warning "Docs map is missing and RITE_DOCS_MAP_AUTO=false"
  if [ -t 0 ]; then
    echo ""
    read -p "Rebuild docs map now? [y/N] " -n 1 -r
    echo
    if [[ ${REPLY:-N} =~ ^[Yy]$ ]]; then
      docs_map_build
      print_success "Docs map rebuilt"
      return 0
    fi
  fi

  # Non-TTY or declined
  print_error "Docs map missing — rebuild disabled (RITE_DOCS_MAP_AUTO=false). Run: rite docs"
  echo "  To rebuild manually: source lib/utils/docs-map.sh && docs_map_build"
  exit 1
}

# ---------------------------------------------------------------------------
# _docs_cmd_self_heal_mismatch
#
# RITE_DOC_MODE=sync but .rite/doc-sync.md is missing.
# Warn + offer re-scaffold from template [y/N] (default-no).
# Declined → exit 1 with instructions.
# ---------------------------------------------------------------------------
_docs_cmd_self_heal_mismatch() {
  local doc_sync_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/doc-sync.md"
  local doc_sync_example="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/doc-sync.md.example"

  print_warning "RITE_DOC_MODE=sync but .rite/doc-sync.md is missing"

  if [ -t 0 ]; then
    echo ""
    echo "  .rite/doc-sync.md is the Layer 2 activation switch."
    echo "  Without it, sharkrite treats this as changelog mode."
    read -p "  Re-scaffold .rite/doc-sync.md from the template? [y/N] " -n 1 -r
    echo
    if [[ ${REPLY:-N} =~ ^[Yy]$ ]]; then
      if [ -f "$doc_sync_example" ]; then
        cp "$doc_sync_example" "$doc_sync_file"
        print_success "Created .rite/doc-sync.md from template"
        return 0
      else
        print_error "Template not found: $doc_sync_example"
        echo "  Run 'rite --init' to restore templates"
        exit 1
      fi
    fi
  fi

  # Non-TTY or declined
  print_error "Mismatch: RITE_DOC_MODE=sync but .rite/doc-sync.md is missing"
  echo "  Options:"
  echo "    re-run 'rite docs' and answer Y to re-scaffold"
  echo "    set RITE_DOC_MODE=changelog in .rite/config to use changelog mode"
  exit 1
}

# ---------------------------------------------------------------------------
# _docs_cmd_enable_flow
#
# Case 1: never-run → ask consent + scaffold (if yes) + build map.
# Same consent question as bin/rite's --init flow and doc-consent.sh's
# ensure_doc_mode. Reuses record_doc_mode and docs_map_build from the
# already-sourced helpers.
#
# Returns 0 on success. The caller decides whether to also run the seam (case 3).
# ---------------------------------------------------------------------------
_docs_cmd_enable_flow() {
  local doc_sync_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/doc-sync.md"
  local doc_sync_example="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/doc-sync.md.example"

  echo ""
  echo "  Sharkrite can update files in docs/ when code changes make them inaccurate."

  local _answer="n"
  read -p "  May sharkrite update files in docs/ when code changes make them inaccurate? [y/N] " -n 1 -r 2>/dev/null || true
  echo
  _answer="${REPLY:-N}"

  if [[ $_answer =~ ^[Yy]$ ]]; then
    # Yes: scaffold .rite/doc-sync.md if absent, record sync
    if [ ! -f "$doc_sync_file" ]; then
      if [ -f "$doc_sync_example" ]; then
        cp "$doc_sync_example" "$doc_sync_file"
        print_success "Created .rite/doc-sync.md (Layer 2 doc sync enabled)"
      else
        print_warning "Template not found: $doc_sync_example — run 'rite --init' to restore"
      fi
    fi
    record_doc_mode "sync"
    print_success "Doc mode: sync (docs/ will be kept accurate after merges)"
  else
    # No: record changelog only
    record_doc_mode "changelog"
    print_info "Doc mode: changelog (drift notes only; re-run 'rite docs' to change)"
  fi

  # Build the docs map (both branches)
  print_info "Building docs map..."
  docs_map_build
  print_success "Docs map built"

  # Inform about any pre-existing drift entries
  local _drift_file
  _drift_file="$(drift_log_path)" || true
  if [ -f "${_drift_file:-}" ]; then
    local _count
    _count="$(drift_log_entry_count "$_drift_file")" || true
    if [ "${_count:-0}" -gt 0 ]; then
      print_info "Drift log has $_count existing entries — reconciliation lands with #1049 (deferred)"
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# _docs_cmd_audit
#
# Case 2: run-before + no input → drift audit.
# Ensures map, then runs doc_assessment to verify mapped docs against current code.
# Reports findings as structured drift entries reusing drift-log entry fields.
#
# Changelog mode: appends findings via drift_log_append, then tail-offers enable.
# Sync mode: report only (applying updates is #1049's engine).
# ---------------------------------------------------------------------------
_docs_cmd_audit() {
  local current_state="$1"

  # Ensure map exists first
  _docs_cmd_ensure_map

  local map_file
  map_file="$(docs_map_path)"

  if [ ! -f "$map_file" ]; then
    print_warning "Docs map still missing after ensure — skipping audit"
    return 0
  fi

  print_info "Running doc drift audit..."
  echo ""

  # Build prompt from map contents
  local _map_content
  _map_content="$(cat "$map_file")"

  # Load doc-sync rules if in sync mode (for context, not for editing)
  local _doc_sync_content=""
  local _doc_sync_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/doc-sync.md"
  if [ -f "$_doc_sync_file" ]; then
    _doc_sync_content="$(cat "$_doc_sync_file")"
  fi

  # Collect recently changed source files from git log (last 20 commits, non-doc)
  local _changed_files=""
  _changed_files="$(git -C "$RITE_PROJECT_ROOT" log --name-only --pretty=format: -20 2>/dev/null \
    | grep -v '^$' \
    | grep -v '^docs/' \
    | grep -v '^\.rite/' \
    | sort -u \
    | head -30 || true)"

  local _prompt_file
  _prompt_file="$(mktemp)"
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand in prompt
  cat > "$_prompt_file" <<EOF
You are a documentation accuracy auditor. Review the documentation inventory below
and identify sections that may be inaccurate given the recently changed source files.

Output ONLY a structured findings list. For each finding:
  DOC: <relative doc path>
  SECTION: <heading text>
  SUSPECTED: <one-line description of what may be inaccurate>

If no documentation drift is detected, output exactly: NO_DRIFT_DETECTED

Documentation inventory (docs-map.tsv):
${_map_content}

Recently changed source files (non-doc):
${_changed_files:-  (none available)}

Doc-sync rules (from .rite/doc-sync.md):
${_doc_sync_content:-  (not configured)}
EOF

  local _audit_output=""
  local _audit_stderr_file
  _audit_stderr_file="$(mktemp)"
  _audit_output="$(provider_run_prompt_with_timeout \
    "$(cat "$_prompt_file")" \
    "$(provider_resolve_model doc_assessment)" \
    true \
    "${RITE_ASSESSMENT_TIMEOUT:-300}" \
    2>"$_audit_stderr_file")" || true
  rm -f "$_prompt_file"

  if [ -s "$_audit_stderr_file" ]; then
    print_warning "Audit provider error: $(cat "$_audit_stderr_file")"
  fi
  rm -f "$_audit_stderr_file"

  if [ -z "$_audit_output" ]; then
    print_info "Audit returned no output (timeout or empty)"
    return 0
  fi

  if echo "$_audit_output" | grep -q "^NO_DRIFT_DETECTED"; then
    print_success "No documentation drift detected"
    return 0
  fi

  # Parse and display findings
  echo ""
  print_header "Documentation Drift Findings"
  echo "$_audit_output"
  echo ""

  # Count findings (lines starting with DOC:)
  local _finding_count
  _finding_count="$(echo "$_audit_output" | grep -c '^DOC:' || true)"

  if [ "$current_state" = "changelog" ]; then
    # Changelog mode: append findings to drift log via drift_log_append
    if [ "${_finding_count:-0}" -gt 0 ]; then
      # Format implicated docs from audit output
      local _implicated=""
      local _suspected=""
      local _doc_line=""
      local _section_line=""
      local _suspected_line=""

      while IFS= read -r _line; do
        case "$_line" in
          DOC:*)
            _doc_line="${_line#DOC: }"
            ;;
          SECTION:*)
            _section_line="${_line#SECTION: }"
            ;;
          SUSPECTED:*)
            _suspected_line="${_line#SUSPECTED: }"
            if [ -n "$_doc_line" ]; then
              if [ -n "$_implicated" ]; then
                _implicated="${_implicated}
- ${_doc_line} — ${_section_line:-unknown}"
              else
                _implicated="- ${_doc_line} — ${_section_line:-unknown}"
              fi
              if [ -z "$_suspected" ]; then
                _suspected="$_suspected_line"
              else
                _suspected="${_suspected}; ${_suspected_line}"
              fi
              _doc_line=""
              _section_line=""
              _suspected_line=""
            fi
            ;;
        esac
      done <<EOF_FINDINGS
$_audit_output
EOF_FINDINGS

      # Use "-" as PR and issue placeholders (demand audit, not merge-triggered)
      drift_log_append "-" "-" "(demand audit via rite docs)" "$_implicated" \
        "${_suspected:-see findings above}"
      print_info "Appended $_finding_count finding(s) to drift log"
    fi

    # Tail-offer: enable doc-sync
    echo ""
    local _offer_answer="n"
    if [ -t 0 ]; then
      read -p "Enable doc-sync and reconcile these $_finding_count entries now? [y/N] " -n 1 -r
      echo
      _offer_answer="${REPLY:-N}"
    fi

    if [[ $_offer_answer =~ ^[Yy]$ ]]; then
      _docs_cmd_enable_flow
      print_info "Reconcile engine lands with #1049 — re-run 'rite docs' after it ships"
    fi
  else
    # Sync mode: report only
    print_info "Sync mode: $_finding_count potential drift finding(s) above"
    print_info "Applying updates lands with #1049 — re-run 'rite docs' after it ships"
  fi
}

# ---------------------------------------------------------------------------
# rite_docs_directed_update
#
# Stub for Case 3: input present → directed-update seam.
# Body lands in #1049; this stub names #1049 and returns 1 so callers notice
# nothing was applied.
#
# Arguments: any instructions passed by the user (forwarded by rite_docs)
# Returns: 1 (nothing applied)
# ---------------------------------------------------------------------------
rite_docs_directed_update() {
  print_info "Directed doc updates land with #1049 — findings above are recorded; re-run after it ships"
  return 1
}

# ---------------------------------------------------------------------------
# rite_docs [instructions...]
#
# Main entrypoint. Dispatches based on effective documentation state.
#
# Arguments:
#   $@  Optional free-text instructions for the directed-update seam (#1049)
# ---------------------------------------------------------------------------
rite_docs() {
  local _instructions="${*:-}"
  local _has_input=false
  [ -n "$_instructions" ] && _has_input=true

  # Determine effective state
  local _state
  _state="$(_docs_cmd_effective_state)"

  case "$_state" in
    mismatch)
      # Self-heal: RITE_DOC_MODE=sync but .rite/doc-sync.md is missing
      _docs_cmd_self_heal_mismatch
      # If self-heal succeeded (user said Y), re-read state
      _state="$(_docs_cmd_effective_state)"
      ;;
  esac

  case "$_state" in
    never-run)
      # Case 1: first-ever run → enable flow
      _docs_cmd_enable_flow
      # If instructions were also passed, route to directed-update seam after
      if [ "$_has_input" = true ]; then
        echo ""
        rite_docs_directed_update "$_instructions" || true
      fi
      ;;

    sync|changelog)
      if [ "$_has_input" = true ]; then
        # Case 3: input present → directed-update seam
        # First run an audit so findings are visible, then name #1049
        _docs_cmd_ensure_map
        _docs_cmd_audit "$_state" || true
        echo ""
        rite_docs_directed_update "$_instructions" || true
      else
        # Case 2: run-before + no input → audit
        _docs_cmd_audit "$_state"
      fi
      ;;

    mismatch)
      # Self-heal returned mismatch again (user declined re-scaffold) — already exited
      # This branch is unreachable but keeps the case exhaustive.
      exit 1
      ;;

    *)
      print_error "docs-command: unknown state '$_state'"
      exit 1
      ;;
  esac

  return 0
}
