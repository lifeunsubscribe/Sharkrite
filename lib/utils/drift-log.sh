#!/bin/bash
# lib/utils/drift-log.sh
#
# Format library for the sharkrite doc drift log.
#
# In changelog mode (RITE_DOC_MODE=changelog), sharkrite does not edit user
# prose directly. Instead, each merge appends a structured, machine-parseable
# entry to docs/sharkrite-drift-log.md in the target repo. The file is tracked
# in git (not gitignored) so humans see it alongside their other docs.
#
# Burn-down semantics: entries are removed as their docs are reconciled — by
# `rite docs` (#1045) or by hand. The file is deleted when the last entry
# burns down.
#
# Entry format (see RITE_MARKER_DOC_DRIFT in lib/utils/markers.sh):
#
#   <!-- sharkrite-doc-drift pr:N issue:N recorded:ISO8601 -->
#   **Changed files**: lib/core/foo.sh, lib/utils/bar.sh
#   **Implicated docs**:
#   - docs/architecture/behavioral-design.md — "Gate Block-on-Any"
#   - README.md — "Usage"
#   **Suspected inaccuracy**: <one line>
#   <!-- /sharkrite-doc-drift -->
#
# Public API:
#   drift_log_path         — echo the absolute path to docs/sharkrite-drift-log.md
#   drift_log_append       — append one entry (auto-bootstraps header on first write)
#   drift_log_entry_count  — count delimited blocks in the file
#
# All functions are re-source safe. Sentinel: drift_log_append.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing).
# Sentinel: drift_log_append — stable, defined only by this file.
if declare -f drift_log_append >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Bootstrap: ensure RITE_PROJECT_ROOT is available.
# In production, config.sh is loaded first via assess-documentation.sh.
# The guard here makes this file sourceable standalone (re-source safety test).
# ---------------------------------------------------------------------------
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _DRIFT_LOG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_DRIFT_LOG_SELF_DIR/config.sh"
fi

# ---------------------------------------------------------------------------
# drift_log_path
#
# Echo the absolute path to the drift log in the current checkout.
# Resolved against git rev-parse --show-toplevel so the path lands in the
# feature worktree when the script is cd'd there (assess-documentation.sh:88).
# ---------------------------------------------------------------------------
drift_log_path() {
  local repo_root
  # Fall back to RITE_PROJECT_ROOT if git is unavailable (e.g. test stubs).
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "${RITE_PROJECT_ROOT:-.}")"
  echo "${repo_root}/docs/sharkrite-drift-log.md"
}

# ---------------------------------------------------------------------------
# _drift_log_bootstrap LOG_PATH
#
# Create docs/sharkrite-drift-log.md with an explanatory header if it does
# not yet exist. Called by drift_log_append on first write. Mirrors the
# conventions.md bootstrap in update_conventions_from_marker (assess-documentation.sh:703).
#
# Internal helper — not part of the public API.
# ---------------------------------------------------------------------------
_drift_log_bootstrap() {
  local log_path="$1"

  mkdir -p "$(dirname "$log_path")"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: marker constant must expand
  cat > "$log_path" <<EOF
# Sharkrite Drift Log

**Auto-appended by sharkrite in changelog mode — do not hand-edit entries.**

Each entry records a merge where sharkrite detected that documentation may
need updating. Entries are machine-parseable blocks delimited by
\`<!-- sharkrite-doc-drift pr:N ... -->\` markers.

**Burn-down semantics:** Remove an entry after you have verified or updated
the implicated documentation. Delete this file when the last entry burns down.
\`rite docs\` (#1045) can also drive burn-down automatically.

---
EOF

  # Print one info line (mirrors the conventions bootstrap print_info style).
  if declare -f print_info >/dev/null 2>&1; then
    print_info "Created docs/sharkrite-drift-log.md (first drift entry triggered bootstrap)"
  fi
}

# ---------------------------------------------------------------------------
# drift_log_append PR_NUMBER ISSUE_NUMBER CHANGED_FILES_ONE_PER_LINE
#                 IMPLICATED_DOCS_LIST SUSPECTED_INACCURACY
#
# Append one machine-parseable drift entry to the log.
#
# Arguments:
#   $1  PR number (integer)
#   $2  Issue number (integer or "-" when absent)
#   $3  Newline-separated list of changed files (non-docs)
#   $4  Formatted implicated-docs list — each line "- path — section" or
#       empty string when there are zero implicated docs
#   $5  One-line suspected inaccuracy (or deterministic fallback text)
#
# Behaviour:
#   - Auto-bootstraps the file (and its parent dir) on first write.
#   - Appends the entry block after the existing content.
#   - Never aborts on error: all internal error paths print a warning and
#     return 0 (same contract as reconcile_tag_index).
# ---------------------------------------------------------------------------
drift_log_append() {
  local pr_number="$1"
  local issue_number="$2"
  local changed_files="$3"
  local implicated_docs="$4"
  local suspected_inaccuracy="$5"

  local log_path
  log_path="$(drift_log_path)" || {
    if declare -f print_warning >/dev/null 2>&1; then
      print_warning "drift-log: could not resolve log path — skipping append"
    fi
    return 0
  }

  # Auto-bootstrap on first write.
  if [ ! -f "$log_path" ]; then
    _drift_log_bootstrap "$log_path" || {
      if declare -f print_warning >/dev/null 2>&1; then
        print_warning "drift-log: bootstrap failed — skipping append"
      fi
      return 0
    }
  fi

  # Timestamp (BSD date and GNU date both accept this format).
  local recorded_ts
  recorded_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Format changed_files as comma-separated (compact for the header line).
  local changed_files_inline
  # Replace newlines with ", " using parameter expansion loop (bash 3.2 safe,
  # no tr dependency — tr is an external command and might be stripped in stubs).
  changed_files_inline=""
  local _cf_line
  while IFS= read -r _cf_line || [ -n "$_cf_line" ]; do
    [ -z "$_cf_line" ] && continue
    if [ -z "$changed_files_inline" ]; then
      changed_files_inline="$_cf_line"
    else
      changed_files_inline="${changed_files_inline}, ${_cf_line}"
    fi
  done <<EOF_CF
$changed_files
EOF_CF

  # Format implicated docs block.
  # Each line is already "- path — section"; emit as-is.
  # If empty, this field will be "  (none detected)" — but caller already
  # skips the append when there are zero implicated docs, so this is a
  # defensive fallback only.
  local implicated_docs_block
  if [ -n "$implicated_docs" ]; then
    implicated_docs_block="$implicated_docs"
  else
    implicated_docs_block="  (none detected)"
  fi

  # Append the entry block.
  # The marker constant is expanded via RITE_MARKER_DOC_DRIFT (sourced from
  # markers.sh, which assess-documentation.sh always loads before this library).
  # The fallback literal is required for standalone sourcing in tests where
  # markers.sh may not be loaded first. drift-log.sh is listed in the Rule 19
  # allowlist (lib/utils/drift-log.sh) so the literal does not violate lint.
  # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_DOC_DRIFT is an internal marker constant (defined in markers.sh), not a user config var; _RITE_ prefix cannot be used as RITE_MARKER_* is the canonical convention for all marker constants (see markers.sh); ledger is frozen per 2026-07-14 rule
  local _marker="${RITE_MARKER_DOC_DRIFT:-sharkrite-doc-drift}"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: marker + field vars must expand
  cat >> "$log_path" <<EOF

<!-- ${_marker} pr:${pr_number} issue:${issue_number} recorded:${recorded_ts} -->
**Changed files**: ${changed_files_inline}
**Implicated docs**:
${implicated_docs_block}
**Suspected inaccuracy**: ${suspected_inaccuracy}
<!-- /${_marker} -->
EOF
}

# ---------------------------------------------------------------------------
# drift_log_entry_count LOG_PATH
#
# Echo the number of delimited drift entries in the file.
# Returns 0 even when the file does not exist (echoes "0").
#
# The grep pattern MUST carry the pr:[0-9] format anchor per the
# BARE_MARKER_GREP rule (bare-prefix guard requirement).
# ---------------------------------------------------------------------------
drift_log_entry_count() {
  local log_path="${1:-}"
  if [ -z "$log_path" ]; then
    log_path="$(drift_log_path)" || { echo "0"; return 0; }
  fi

  if [ ! -f "$log_path" ]; then
    echo "0"
    return 0
  fi

  # Count opening delimiters only (each entry has exactly one opening marker
  # with pr:[0-9] anchor). The format anchor satisfies BARE_MARKER_GREP.
  # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_DOC_DRIFT is an internal marker constant (defined in markers.sh), not a user config var; _RITE_ prefix cannot be used as RITE_MARKER_* is the canonical convention for all marker constants (see markers.sh); ledger is frozen per 2026-07-14 rule
  local _marker="${RITE_MARKER_DOC_DRIFT:-sharkrite-doc-drift}"
  # grep -c returns exit 1 when count is 0 — || true is the correct idiom
  # (see CLAUDE.md "grep -c pattern").
  grep -c "<!-- ${_marker} pr:[0-9]" "$log_path" || true
}
