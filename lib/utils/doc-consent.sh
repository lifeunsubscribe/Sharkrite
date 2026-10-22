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
#   off       — asked and declined: nothing is recorded
#   (unset)   — never asked: nothing is recorded; a supervised run or
#               `rite docs` asks
#
# The per-merge doc-sync rewrite that `sync` used to switch on (.rite/doc-sync.md)
# was retired 2026-10-21 — it committed raw model output into orrery's README.
#
# Public API:
#   record_doc_mode <sync|changelog|off> — write to .rite/config + export
#   ensure_doc_mode                    — ask once in supervised non-batch TTY
#                                        runs; no-op when already recorded

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
# Behaviour:
#   - No-op when RITE_DOC_MODE is already set (recorded at init or by env).
#   - In supervised non-batch TTY runs: ask once (default no) and record
#     sync on yes, off on no.
#   - In all other contexts (unsupervised, batch, non-TTY): do nothing. Doc
#     tracking is opt-in; an unattended run must not opt the repo in. (It used
#     to default the session to changelog, which recorded a drift entry — and
#     made a model call — on every merge without consent: 74 unreviewed
#     entries in sharkrite's own drift log by 2026-10-21.)
#
# Map building is NOT this hook's job — docs_map_ensure (#1032) self-heals
# missing maps when consumers need them.
# ---------------------------------------------------------------------------
ensure_doc_mode() {
  # No-op when mode is already recorded
  if [ -n "${RITE_DOC_MODE:-}" ]; then
    return 0
  fi

  # Only a supervised, non-batch, interactive run may ask
  if [ "${WORKFLOW_MODE:-supervised}" != "supervised" ] \
     || [ "${BATCH_MODE:-false}" = "true" ] \
     || [ ! -t 0 ]; then
    return 0
  fi

  echo ""
  echo "  Sharkrite can track which docs a merge may have made inaccurate, and"
  echo "  'rite docs' then proposes fixes for your approval. Docs are never edited"
  echo "  automatically."
  read -p "  Track doc drift for this repo? [y/N] " -n 1 -r
  echo

  if [[ ${REPLY:-N} =~ ^[Yy]$ ]]; then
    record_doc_mode "sync"
    if declare -f print_success >/dev/null 2>&1; then
      print_success "Doc drift tracking on (review with 'rite docs')"
    else
      echo "  Doc mode recorded: sync"
    fi
  else
    record_doc_mode "off"
    if declare -f print_info >/dev/null 2>&1; then
      print_info "Doc drift tracking off (run 'rite docs' to turn it on)"
    else
      echo "  Doc mode recorded: off"
    fi
  fi
}
