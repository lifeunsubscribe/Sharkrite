#!/bin/bash
# lib/utils/doc-consent.sh
#
# Doc-mode consent helpers.
#
# Tracks whether the user has consented to sharkrite updating files in docs/
# when code changes make them inaccurate.  Records the decision as
# RITE_DOC_MODE="sync|changelog" in .rite/config.
#
# Two activation modes (recorded in RITE_DOC_MODE):
#   sync      — yes consent; .rite/doc-sync.md is scaffolded (Layer 2 switch)
#   changelog — no consent; only drift changelog writes (cluster-B follow-on)
#
# Public API:
#   record_doc_mode <sync|changelog>   — write to .rite/config + export
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
# record_doc_mode <sync|changelog>
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
    sync|changelog) ;;
    *)
      echo "record_doc_mode: invalid mode '$mode' (must be sync or changelog)" >&2
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
#   - In supervised non-batch TTY runs: ask the consent question once and
#     record the answer.  Consent-yes also scaffolds .rite/doc-sync.md.
#   - In all other contexts (unsupervised, batch, non-TTY): set session-only
#     RITE_DOC_MODE=changelog and print ONE info line.  Never write config.
#
# Map building is NOT this hook's job — docs_map_ensure (#1032) self-heals
# missing maps when consumers need them.
# ---------------------------------------------------------------------------
ensure_doc_mode() {
  # No-op when mode is already recorded
  if [ -n "${RITE_DOC_MODE:-}" ]; then
    return 0
  fi

  local config_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/config"
  local doc_sync_file="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/doc-sync.md"
  local doc_sync_example="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/doc-sync.md.example"

  # Supervised + non-batch + TTY → ask once and record
  if [ "${WORKFLOW_MODE:-supervised}" = "supervised" ] \
     && [ "${BATCH_MODE:-false}" != "true" ] \
     && [ -t 0 ]; then

    echo ""
    echo "  Sharkrite can update files in docs/ when code changes make them inaccurate."
    read -p "  May sharkrite update files in docs/ when code changes make them inaccurate? [Y/n] " -n 1 -r
    echo

    if [[ ! ${REPLY:-Y} =~ ^[Nn]$ ]]; then
      # Yes: scaffold .rite/doc-sync.md if absent, record sync
      if [ ! -f "$doc_sync_file" ]; then
        if [ -f "$doc_sync_example" ]; then
          cp "$doc_sync_example" "$doc_sync_file"
        fi
      fi
      record_doc_mode "sync"
      if declare -f print_success >/dev/null 2>&1; then
        print_success "Doc mode: sync (docs/ will be kept accurate after merges)"
      else
        echo "  Doc mode recorded: sync"
      fi
    else
      # No: record changelog, no .rite/doc-sync.md scaffolded
      record_doc_mode "changelog"
      if declare -f print_info >/dev/null 2>&1; then
        print_info "Doc mode: changelog (drift notes only; re-run rite --init to change)"
      else
        echo "  Doc mode recorded: changelog"
      fi
    fi

    return 0
  fi

  # All other contexts (unsupervised, batch, non-TTY): session-only default.
  # Never write config — a later supervised run must still ask.
  export RITE_DOC_MODE=changelog
  if declare -f print_info >/dev/null 2>&1; then
    print_info "No docs consent recorded — using changelog mode this run; answer via rite --init or a supervised run"
  else
    echo "No docs consent recorded — using changelog mode this run; answer via rite --init or a supervised run" >&2
  fi
}
