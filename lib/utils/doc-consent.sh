#!/bin/bash
# lib/utils/doc-consent.sh
#
# Doc-mode consent helpers.
#
# Tracks the doc-drift recording mode. Records the decision as RITE_DOC_MODE
# in .rite/config. No mode ever edits docs/ on its own — corrections go
# through `rite docs`' propose/approve loop.
#
# Modes (recorded in RITE_DOC_MODE):
#   sync      — each merge records a drift entry; `rite docs` offers to
#               reconcile entries interactively
#   changelog — legacy: each merge records a drift entry
#   off       — explicit opt-out: nothing is recorded
#   (unset)   — on by default: recording happens, same as sync
#
# The per-merge doc-sync rewrite that `sync` used to switch on (.rite/doc-sync.md)
# was retired 2026-10-21 — it committed raw model output into orrery's README.
#
# Public API:
#   record_doc_mode <sync|changelog|off>              — write to .rite/config + export
#   ensure_doc_mode                                   — no-op (permanent)
#   run_align_docs_switch [--enable|--disable|doc...] — audit entry point

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
# _run_align_docs_passes [doc ...]
#
# Internal helper: run restructure assessment, assertion audit, then the
# closing reconcile when the functions are available and stdin is an
# interactive terminal. Optional doc name args are forwarded to all three
# unchanged.
# ---------------------------------------------------------------------------
_run_align_docs_passes() {
  if declare -f docs_run_restructure_assessment >/dev/null 2>&1; then
    if [ "${_RITE_FORCE_TTY:-0}" = "1" ] || [ -t 0 ]; then
      docs_run_restructure_assessment "$@"
    else
      if declare -f print_info >/dev/null 2>&1; then
        print_info "Restructure assessment skipped (not an interactive terminal — run 'rite align-docs' interactively)."
      fi
    fi
  fi
  if declare -f docs_run_assertion_audit >/dev/null 2>&1; then
    if [ "${_RITE_FORCE_TTY:-0}" = "1" ] || [ -t 0 ]; then
      docs_run_assertion_audit "$@"
    else
      if declare -f print_info >/dev/null 2>&1; then
        print_info "Assertion audit skipped (not an interactive terminal — run 'rite align-docs' interactively)."
      fi
    fi
  fi
  # Offer pending drift entries through the approval loop after the audit.
  # Runs in every mode (unset, off, sync) — the reconcile path is mode-free.
  # Skipped in non-interactive runs; mode is never altered.
  # Doc name args scope it to the docs this run audited. Skipped when the
  # operator quit the findings review to resume later (_DOCS_AUDIT_STOPPED) —
  # reconciling half the findings now would edit the doc under the other half.
  if declare -f docs_reconcile_drift >/dev/null 2>&1; then
    if [ "${_DOCS_AUDIT_STOPPED:-false}" != "true" ]; then
      if [ "${_RITE_FORCE_TTY:-0}" = "1" ] || [ -t 0 ]; then
        docs_reconcile_drift "$@" || true
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# run_align_docs_switch [--enable | --disable | doc ...]
#
# The audit entry point and on/off switch for doc drift tracking.
# Called by `rite align-docs`.
#
# Behaviour:
#   --enable    Record sync; print confirmation. Works without a terminal.
#               Extra args after --enable are rejected with exit 1.
#   --disable   Record off; print confirmation. Works without a terminal.
#               Extra args after --disable are rejected with exit 1.
#   doc [...]   Resolve named docs (exits 1 on unknown/ambiguous), then run
#               both audit passes scoped to those docs. Never changes the mode.
#   (no args)   Run both audit passes over all docs. Never changes the mode.
#               Works in every mode (unset, off, sync) without prompting.
# ---------------------------------------------------------------------------
run_align_docs_switch() {
  local _first_arg="${1:-}"

  if [ "$_first_arg" = "--disable" ]; then
    if [ $# -gt 1 ]; then
      echo "Error: 'rite align-docs --disable' does not accept doc names." >&2
      echo "  Usage: rite align-docs --disable" >&2
      return 1
    fi
    record_doc_mode "off"
    if declare -f print_info >/dev/null 2>&1; then
      print_info "Doc drift tracking disabled. Run 'rite align-docs --enable' to re-enable."
    else
      echo "  Doc drift tracking disabled. Run 'rite align-docs --enable' to re-enable." >&2
    fi
    return 0
  fi

  if [ "$_first_arg" = "--enable" ]; then
    if [ $# -gt 1 ]; then
      echo "Error: 'rite align-docs --enable' does not accept doc names." >&2
      echo "  Usage: rite align-docs --enable" >&2
      return 1
    fi
    record_doc_mode "sync"
    if declare -f print_success >/dev/null 2>&1; then
      print_success "Doc drift tracking enabled."
    else
      echo "  Doc drift tracking enabled." >&2
    fi
    return 0
  fi

  if [ -n "$_first_arg" ] && [ "${_first_arg#--}" != "$_first_arg" ]; then
    echo "Error: unknown argument '${_first_arg}'. Usage: rite align-docs [--enable | --disable | doc ...]" >&2
    return 1
  fi

  # No mode changes: resolve any named docs, then run both audit passes.
  if [ $# -gt 0 ] && declare -f docs_resolve_doc_scope >/dev/null 2>&1; then
    local _rads_resolved
    _rads_resolved="$(docs_resolve_doc_scope "$@")" || return 1
    _run_align_docs_passes "$_rads_resolved"
  else
    _run_align_docs_passes "$@"
  fi
}
