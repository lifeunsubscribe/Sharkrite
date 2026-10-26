#!/bin/bash
# lib/utils/doc-consent.sh
#
# Doc-mode consent helpers.
#
# Tracks whether the user has opted in to doc-drift tracking. Records the
# decision as RITE_DOC_MODE in .rite/config. No mode ever edits docs/ on its
# own — corrections go through `rite docs`' propose/approve loop.
#
# Modes (recorded in RITE_DOC_MODE):
#   sync      — opted in: each merge records a drift entry; `rite docs`
#               offers to reconcile entries interactively
#   changelog — legacy opt-in: each merge records a drift entry
#   off       — asked and declined: nothing is recorded; `rite align-docs`
#               prompts again (first-run semantics restored)
#   (unset)   — never asked: nothing is recorded
#
# The per-merge doc-sync rewrite that `sync` used to switch on (.rite/doc-sync.md)
# was retired 2026-10-21 — it committed raw model output into orrery's README.
#
# Public API:
#   record_doc_mode <sync|changelog|off>  — write to .rite/config + export
#   ensure_doc_mode                       — no-op (consent owned by `rite align-docs`)
#   run_align_docs_switch [--disable]     — the single on/off entry point

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing).
# Sentinel: ensure_doc_mode — stable, defined only by this file.
if declare -f ensure_doc_mode >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Bootstrap: ensure RITE_PROJECT_ROOT, RITE_DATA_DIR, and helpers are available.
# In production, config.sh is always loaded first; the guard here makes this
# file sourceable standalone (e.g. during the re-source safety regression test).
# ---------------------------------------------------------------------------
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _DOC_CONSENT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_DOC_CONSENT_SELF_DIR/config.sh"
fi

# Ensure portable_sed_i is available (lives in portable-cmds.sh).
if ! declare -f portable_sed_i >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/portable-cmds.sh"
fi

# ---------------------------------------------------------------------------
# record_doc_mode <sync|changelog|off>
#
# Write RITE_DOC_MODE to .rite/config (idempotent) and export in this process.
#
# Config-write strategy (mirrors RITE_PLAN_DOCS pattern in bin/rite:1064-1069):
#   1. If a commented-out or active RITE_DOC_MODE= line exists → replace it
#   2. Otherwise → append a new line
#
# Idempotent: after two calls the config has exactly one RITE_DOC_MODE= line.
# ---------------------------------------------------------------------------
record_doc_mode() {
  local mode="$1"
  local config_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/config"

  # Validate mode argument
  case "$mode" in
    sync|changelog|off) ;;
    *)
      echo "record_doc_mode: invalid mode '$mode' (must be sync, changelog or off)" >&2
      return 1
      ;;
  esac

  # Write to config when it exists
  if [ -f "$config_file" ]; then
    # Replace an existing RITE_DOC_MODE= line (commented or uncommented).
    # The sed pattern covers: RITE_DOC_MODE=..., # RITE_DOC_MODE=...
    if grep -qE '^(# )?RITE_DOC_MODE=' "$config_file" 2>/dev/null; then
      portable_sed_i "s|^\\(# \\)\\{0,1\\}RITE_DOC_MODE=.*|RITE_DOC_MODE=\"${mode}\"|" "$config_file"
    else
      printf '\nRITE_DOC_MODE="%s"\n' "$mode" >> "$config_file"
    fi
  fi

  # Export in the current process so callers see the new value immediately.
  RITE_DOC_MODE="$mode"
  export RITE_DOC_MODE
}

# ---------------------------------------------------------------------------
# ensure_doc_mode
#
# Pre-existing-repo hook: called early in run_workflow() before the issue fetch.
#
# Consent is now owned by `rite align-docs`. This function is a permanent no-op
# so that unattended workflow runs never prompt or record consent. (It used to
# prompt in supervised TTY runs, which silently accumulated 74 unreviewed drift
# entries in sharkrite's own log by 2026-10-21.)
# ---------------------------------------------------------------------------
ensure_doc_mode() {
  return 0
}

# ---------------------------------------------------------------------------
# run_align_docs_switch [--disable]
#
# The single on/off entry point for doc drift tracking. Called by `rite align-docs`.
#
# Behaviour:
#   --disable   Record off; print confirmation. The next plain `rite align-docs`
#               will ask again (off maps to never-run in _docs_resolve_state).
#   (no args)   If already enabled (sync/changelog): report state, no prompt.
#               If non-TTY: print a message, never enable, exit 0.
#               If TTY + never enabled: ask y/n; prompt text states the audit
#               runs either way. Records sync on yes, off on no.
#               After enabling: print "Audit not yet implemented" and exit 0.
#
# Degrades gracefully in non-TTY ([ -t 0 ] false) — never enables unattended.
# ---------------------------------------------------------------------------
run_align_docs_switch() {
  local _disable_flag="${1:-}"

  if [ "$_disable_flag" = "--disable" ]; then
    record_doc_mode "off"
    if declare -f print_info >/dev/null 2>&1; then
      print_info "Doc drift tracking disabled. Run 'rite align-docs' to re-enable."
    else
      echo "  Doc drift tracking disabled. Run 'rite align-docs' to re-enable." >&2
    fi
    return 0
  fi

  if [ -n "$_disable_flag" ]; then
    echo "Error: unknown argument '${_disable_flag}'. Usage: rite align-docs [--disable]" >&2
    return 1
  fi

  # Already enabled: report and exit without re-prompting
  case "${RITE_DOC_MODE:-}" in
    sync|changelog)
      if declare -f print_info >/dev/null 2>&1; then
        print_info "Doc drift tracking is on (mode: ${RITE_DOC_MODE}). Run 'rite align-docs --disable' to turn it off."
      else
        echo "  Doc drift tracking is on (mode: ${RITE_DOC_MODE}). Run 'rite align-docs --disable' to turn it off." >&2
      fi
      if declare -f print_info >/dev/null 2>&1; then
        print_info "Audit not yet implemented."
      fi
      return 0
      ;;
  esac

  # Mode is unset or off — first-run path
  if [ ! -t 0 ]; then
    if declare -f print_info >/dev/null 2>&1; then
      print_info "Not an interactive terminal — run 'rite align-docs' interactively to configure doc drift tracking."
    else
      echo "  Not an interactive terminal — run 'rite align-docs' interactively to configure doc drift tracking." >&2
    fi
    return 0
  fi

  _align_docs_prompt_and_record
}

# ---------------------------------------------------------------------------
# _align_docs_prompt_and_record
#
# Internal helper: display the consent prompt and record the user's choice.
# Caller must have already verified stdin is a TTY before calling this.
# Extracted to allow unit tests to exercise the y/n path without needing any
# bypass of the [ -t 0 ] guard in run_align_docs_switch.
# ---------------------------------------------------------------------------
_align_docs_prompt_and_record() {
  echo "" >&2
  echo "  Sharkrite can track which docs a merge may have made inaccurate." >&2
  echo "  The audit (checking docs against code) runs either way." >&2
  local _reply_val="N"
  read -p "  Enable doc drift tracking? [y/N] " -n 1 -r
  echo >&2
  _reply_val="${REPLY:-N}"

  if [[ "$_reply_val" =~ ^[Yy]$ ]]; then
    record_doc_mode "sync"
    if declare -f print_success >/dev/null 2>&1; then
      print_success "Doc drift tracking enabled."
    else
      echo "  Doc drift tracking enabled." >&2
    fi
    if declare -f print_info >/dev/null 2>&1; then
      print_info "Audit not yet implemented — run 'rite docs' to check docs against code."
    else
      echo "  Audit not yet implemented — run 'rite docs' to check docs against code." >&2
    fi
  else
    record_doc_mode "off"
    if declare -f print_info >/dev/null 2>&1; then
      print_info "Doc drift tracking off. Run 'rite align-docs' to turn it on."
    else
      echo "  Doc drift tracking off. Run 'rite align-docs' to turn it on." >&2
    fi
  fi
}
