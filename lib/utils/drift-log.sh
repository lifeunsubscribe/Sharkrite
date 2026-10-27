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
#   drift_log_path          — echo the absolute path to docs/sharkrite-drift-log.md
#   drift_log_relpath       — repo-relative form of drift_log_path
#   drift_log_append        — append or accumulate-in-place one structured entry
#   drift_log_entry_count   — count entries (per-doc, per-branch, or total)
#   drift_log_remove_entry  — remove exactly one (doc, branch, assertion) entry
#   drift_log_clear_doc     — remove all entries for a doc across all branches
#   drift_log_union_merge   — deterministic union-merge of a conflicted drift log
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

# Source lock.sh for lock_acquire/lock_release (concurrent-append safety, #706).
if ! declare -f lock_acquire >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/lock.sh"
fi

# ---------------------------------------------------------------------------
# drift_log_path
#
# Echo the absolute path to the drift log in the current checkout.
# Resolved against git rev-parse --show-toplevel so the path lands in the
# feature worktree when the script is cd'd there (assess-documentation.sh:88).
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# drift_log_relpath
#
# The drift log's repo-RELATIVE path. drift_log_path returns an absolute path,
# but callers matching against `git diff --name-only` / `git status --porcelain`
# output need the relative form.
#
# Lives here because drift-log.sh owns the format AND the location, and because
# it is the one file Rule 19 (RAW_MARKER_LITERAL) allowlists for the literal —
# so every other caller can match the path without embedding a "sharkrite-*"
# string of its own.
# ---------------------------------------------------------------------------
drift_log_relpath() {
  echo "docs/sharkrite-drift-log.md"
}

# ---------------------------------------------------------------------------
# _drift_entry_path DOC BRANCH
#
# Returns the absolute path to the structured entry file for a (doc, branch)
# pair.  Doc path '/' chars are replaced with '--' in the filename portion so
# all doc entries for a branch live flat in one subdirectory.  Branch slashes
# (e.g. release/1.2) are preserved in the path; mkdir -p handles them.
#
# Internal helper — not part of the public API.
# ---------------------------------------------------------------------------
_drift_entry_path() {
  local doc="$1"
  local branch="$2"
  local doc_slug
  doc_slug="${doc//\//--}"
  echo "${RITE_STATE_DIR:-}/doc-drift/${branch}/${doc_slug}.log"
}

# Space-separated list of valid KIND values for drift_log_append.
_DRIFT_VALID_KINDS="addition refinement contradiction test-scope reference-missing"

# ---------------------------------------------------------------------------
# _drift_kind_valid KIND
#
# Returns 0 when KIND is one of the valid values, 1 otherwise.
# Internal helper.
# ---------------------------------------------------------------------------
_drift_kind_valid() {
  local kind="$1"
  local k
  for k in $_DRIFT_VALID_KINDS; do
    [ "$k" = "$kind" ] && return 0
  done
  return 1
}

drift_log_path() {
  local repo_root
  # Fall back to RITE_PROJECT_ROOT if git is unavailable (e.g. test stubs).
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "${RITE_PROJECT_ROOT:-.}")"
  echo "${repo_root}/docs/sharkrite-drift-log.md"
}

# ---------------------------------------------------------------------------
# _drift_log_append_legacy PR ISSUE CHANGED_FILES IMPLICATED_DOCS INACCURACY
#
# Legacy 5-arg compat shim. Appends a markdown-block entry to
# docs/sharkrite-drift-log.md (the flat human-readable file that callers in
# assess-documentation.sh and docs-command.sh write and rite docs reconciles).
#
# Format:
#   <!-- sharkrite-doc-drift pr:N issue:N recorded:ISO8601Z -->
#   **Changed files**: CHANGED_FILES
#   **Implicated docs**:
#   IMPLICATED_DOCS
#   **Suspected inaccuracy**: INACCURACY
#   <!-- /sharkrite-doc-drift -->
#
# Callers that still pass 5 args are routed here automatically by
# drift_log_append; no caller migration required.
# ---------------------------------------------------------------------------
_drift_log_append_legacy() {
  local pr="$1"
  local issue="$2"
  local changed_files="$3"
  local implicated_docs="$4"
  local inaccuracy="$5"

  local log_path
  log_path="$(drift_log_path 2>/dev/null)" || return 0
  [ -n "$log_path" ] || return 0

  mkdir -p "$(dirname "$log_path")" 2>/dev/null || return 0

  if [ ! -f "$log_path" ]; then
    _drift_log_bootstrap "$log_path"
  fi

  local recorded
  recorded="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  {
    printf '\n<!-- sharkrite-doc-drift pr:%s issue:%s recorded:%s -->\n' \
      "$pr" "$issue" "$recorded"
    printf '**Changed files**: %s\n' "$changed_files"
    printf '**Implicated docs**:\n%s\n' "$implicated_docs"
    printf '**Suspected inaccuracy**: %s\n' "$inaccuracy"
    printf '<!-- /sharkrite-doc-drift -->\n'
  } >> "$log_path"
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
# drift_log_append DOC BRANCH PR ISSUE ASSERTION KIND EVIDENCE
#
# Append or accumulate-in-place one structured drift entry.
#
# Arguments:
#   $1  DOC       — repo-relative path of the implicated doc
#   $2  BRANCH    — integration branch, or 'main'
#   $3  PR        — PR number that triggered the drift
#   $4  ISSUE     — issue number (integer or '-' when absent)
#   $5  ASSERTION — doc assertion text whose evidence changed ('' if unknown)
#   $6  KIND      — one of: addition refinement contradiction test-scope
#                   reference-missing  (invalid → non-zero + stderr)
#   $7  EVIDENCE  — changed paths, test names, or grep pattern that fired
#
# Entry file: $RITE_STATE_DIR/doc-drift/<branch>/<doc-slug>.log
# Format: tab-separated key=value, one line per (doc, assertion) pair.
#
# Accumulate-in-place: a repeat hit for the same (doc, assertion) appends
# the PR to the existing entry's comma-separated pr= list — no duplicate
# lines.  (conventions-catalog rule.)
#
# Locking: acquires per-file lock_acquire/lock_release from lock.sh (#706).
#
# Returns 0 on success; 1 + stderr for invalid KIND.  Never aborts for
# other errors — skips with a warning (same contract as reconcile_tag_index).
# ---------------------------------------------------------------------------
drift_log_append() {
  # Legacy compat: 5-arg callers (assess-documentation.sh, docs-command.sh) use
  # drift_log_append PR ISSUE CHANGED_FILES IMPLICATED_DOCS INACCURACY and write
  # markdown blocks to docs/sharkrite-drift-log.md.  Route them to the shim.
  if [ $# -eq 5 ]; then
    _drift_log_append_legacy "$@"
    return
  fi

  local doc="$1"
  local branch="$2"
  local pr="$3"
  local issue="$4"
  local assertion="$5"
  local kind="$6"
  local evidence="$7"

  # KIND validation — callers must pass a known value.
  if ! _drift_kind_valid "$kind"; then
    printf 'drift_log_append: invalid kind "%s"; valid: %s\n' \
      "$kind" "$_DRIFT_VALID_KINDS" >&2
    return 1
  fi

  if [ -z "${RITE_STATE_DIR:-}" ]; then
    if declare -f print_warning >/dev/null 2>&1; then
      print_warning "drift-log: RITE_STATE_DIR unset — skipping append"
    fi
    return 0
  fi

  # Normalize free-text fields: strip tabs (shift TSV columns), newlines
  # (inflate entry count), and backslashes (awk assignment-arg escape
  # processing corrupts the match key — stored value keeps the literal \
  # but awk sees a control char, so keys never match → duplicate append).
  local assertion_norm evidence_norm
  assertion_norm="${assertion//$'\t'/ }"
  assertion_norm="${assertion_norm//$'\n'/ }"
  assertion_norm="${assertion_norm//\\/}"
  evidence_norm="${evidence//$'\t'/ }"
  evidence_norm="${evidence_norm//$'\n'/ }"
  evidence_norm="${evidence_norm//\\/}"

  local entry_file
  entry_file="$(_drift_entry_path "$doc" "$branch")"

  mkdir -p "$(dirname "$entry_file")" || {
    printf 'drift_log_append: mkdir failed for "%s" — skipping\n' \
      "$(dirname "$entry_file")" >&2
    return 0
  }

  local recorded
  recorded="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local lock_path="${entry_file}.lock"

  if ! lock_acquire "$lock_path" 30; then
    printf 'drift_log_append: could not acquire lock for "%s" within 30s\n' \
      "$entry_file" >&2
    return 0
  fi

  # Trap ensures lock is released even when the function exits early under set -e.
  # shellcheck disable=SC2064
  trap "lock_release '$lock_path'" RETURN

  local _dla_found=0
  local _dla_tmp
  _dla_tmp="${entry_file}.tmp.$$"

  if [ -f "$entry_file" ]; then
    # Accumulate-in-place: scan the file for a line whose doc= and assertion=
    # fields match.  awk rewrites the file appending the new PR to that line's
    # pr= field (skipped when PR already present) and exits 0; exits 1 when no
    # matching line was found; exits >1 on I/O error (skip to avoid duplicate).
    local _dla_awk_exit=0
    awk -F'\t' 'BEGIN{OFS="\t"; matched=0}
    {
      hasdoc=0; hasassert=0; prfldidx=0
      for (i=1; i<=NF; i++) {
        if ($i == "doc=" _doc)                hasdoc=1
        if ($i == "assertion=" _assertion)    hasassert=1
        if (substr($i, 1, 3) == "pr=")        prfldidx=i
      }
      if (hasdoc && hasassert && prfldidx > 0) {
        _prnums = substr($prfldidx, 4)
        _check  = "," _prnums ","
        if (index(_check, "," _newpr ",") == 0) {
          $prfldidx = $prfldidx "," _newpr
        }
        matched=1
      }
      print
    }
    END { exit (matched ? 0 : 1) }
    ' _doc="$doc" _assertion="$assertion_norm" _newpr="$pr" \
      "$entry_file" > "$_dla_tmp" || _dla_awk_exit=$?

    if [ "$_dla_awk_exit" -eq 0 ]; then
      _dla_found=1
      mv "$_dla_tmp" "$entry_file"
    elif [ "$_dla_awk_exit" -eq 1 ]; then
      rm -f "$_dla_tmp"
      # _dla_found stays 0; new entry appended below
    else
      rm -f "$_dla_tmp"
      printf 'drift_log_append: awk error (exit %s) for "%s" — skipping\n' \
        "$_dla_awk_exit" "$entry_file" >&2
      lock_release "$lock_path"
      trap - RETURN
      return 0
    fi
  fi

  if [ "$_dla_found" -eq 0 ]; then
    printf 'doc=%s\tbranch=%s\tpr=%s\tissue=%s\tassertion=%s\tkind=%s\tevidence=%s\trecorded=%s\n' \
      "$doc" "$branch" "$pr" "$issue" "$assertion_norm" "$kind" "$evidence_norm" "$recorded" \
      >> "$entry_file" || {
      printf 'drift_log_append: write failed for "%s" — skipping\n' "$entry_file" >&2
      lock_release "$lock_path"
      trap - RETURN
      return 0
    }
  fi

  lock_release "$lock_path"
  trap - RETURN
}

# ---------------------------------------------------------------------------
# drift_log_entry_count [LOG_PATH | --doc DOC | --branch BRANCH | --total]
#
# Echo the number of drift entries.  Three calling modes:
#
#   drift_log_entry_count FILE_PATH          — legacy: count delimited blocks
#                                              in the given flat-log file
#   drift_log_entry_count [--total]          — total entries across all docs
#                                              and branches in the new store
#   drift_log_entry_count --doc DOC          — entries for this doc, all branches
#   drift_log_entry_count --branch BRANCH    — entries for this branch, all docs
#   drift_log_entry_count --doc D --branch B — entries in the specific (doc,branch) file
#
# Existing callers that pass a FILE_PATH (non-'--' first arg) keep working.
# Returns 0 even when nothing exists (echoes "0").
# ---------------------------------------------------------------------------
drift_log_entry_count() {
  # Legacy mode: single non-flag arg → file path to legacy flat log.
  if [ $# -eq 1 ] && [ "${1#--}" = "$1" ]; then
    local log_path="$1"
    if [ ! -f "$log_path" ]; then
      echo "0"; return 0
    fi
    # Count opening delimiters only.  Format anchor satisfies BARE_MARKER_GREP.
    # grep -c returns exit 1 when count is 0 — || true is correct (CLAUDE.md).
    # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_DOC_DRIFT is an internal marker constant (defined in markers.sh), not a user config var; _RITE_ prefix cannot be used as RITE_MARKER_* is the canonical convention for all marker constants (see markers.sh); ledger is frozen per 2026-07-14 rule
    local _marker="${RITE_MARKER_DOC_DRIFT:-sharkrite-doc-drift}"
    grep -c "<!-- ${_marker} pr:[0-9]" "$log_path" || true
    return 0
  fi

  # New mode: parse --doc / --branch flags.
  local _dlc_doc="" _dlc_branch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --doc)    _dlc_doc="$2";    shift 2 ;;
      --branch) _dlc_branch="$2"; shift 2 ;;
      --total)  shift ;;
      *)        shift ;;
    esac
  done

  if [ -z "${RITE_STATE_DIR:-}" ]; then
    echo "0"; return 0
  fi

  local drift_base="${RITE_STATE_DIR}/doc-drift"

  # Count lines in a single entry file (each non-empty line = one entry).
  # Anchored to ^doc= so free-text evidence fields containing "doc=" do not
  # inflate the count.
  _dlc_count_file() {
    local _f="$1"
    [ -f "$_f" ] || { echo "0"; return; }
    grep -c '^doc=' "$_f" || true
  }

  # Sum entry counts across all .log files under a given directory.
  _dlc_sum_dir() {
    local _dir="$1"
    local _pat="$2"
    local _total=0 _f _fc
    [ -d "$_dir" ] || { echo "0"; return; }
    while IFS= read -r _f; do
      [ -f "$_f" ] || continue
      _fc="$(grep -c '^doc=' "$_f" || true)"
      _total=$((_total + _fc))
    done < <(find "$_dir" -name "$_pat" 2>/dev/null || true)
    echo "$_total"
  }

  if [ -n "$_dlc_doc" ] && [ -n "$_dlc_branch" ]; then
    # Specific (doc, branch) file.
    local entry_file
    entry_file="$(_drift_entry_path "$_dlc_doc" "$_dlc_branch")"
    _dlc_count_file "$entry_file"
    return 0
  fi

  if [ -n "$_dlc_branch" ]; then
    # All docs for this branch.
    _dlc_sum_dir "${drift_base}/${_dlc_branch}" "*.log"
    return 0
  fi

  if [ -n "$_dlc_doc" ]; then
    # This doc across all branches — search by slug filename.
    local doc_slug="${_dlc_doc//\//--}"
    _dlc_sum_dir "$drift_base" "${doc_slug}.log"
    return 0
  fi

  # Total: all entries across the entire store.
  _dlc_sum_dir "$drift_base" "*.log"
}

# ---------------------------------------------------------------------------
# drift_log_remove_entry DOC BRANCH ASSERTION
#
# Remove exactly the (DOC, BRANCH, ASSERTION) entry from the structured
# entry store.  Acquires the per-file lock (same as drift_log_append).
# No-op when the file does not exist or no matching entry is found.
# Returns 0 always — a missing entry or file is not an error.
# ---------------------------------------------------------------------------
drift_log_remove_entry() {
  local doc="$1"
  local branch="$2"
  local assertion="$3"

  if [ -z "${RITE_STATE_DIR:-}" ]; then
    return 0
  fi

  # Normalize assertion (same transforms as drift_log_append so the key matches)
  local assertion_norm="${assertion//$'\t'/ }"
  assertion_norm="${assertion_norm//$'\n'/ }"
  assertion_norm="${assertion_norm//\\/}"

  local entry_file
  entry_file="$(_drift_entry_path "$doc" "$branch")"
  [ -f "$entry_file" ] || return 0

  local lock_path="${entry_file}.lock"
  if ! lock_acquire "$lock_path" 30; then
    printf 'drift_log_remove_entry: could not acquire lock for "%s" within 30s\n' \
      "$entry_file" >&2
    return 0
  fi

  # Trap ensures lock is released even under set -e.
  # shellcheck disable=SC2064
  trap "lock_release '$lock_path'" RETURN

  local _dlre_tmp="${entry_file}.tmp.$$"
  local _dlre_awk_exit=0
  # Rewrite file omitting the one line where both doc= and assertion= match.
  awk -F'\t' '
    {
      hasdoc=0; hasassert=0
      for (i=1; i<=NF; i++) {
        if ($i == "doc=" _doc)             hasdoc=1
        if ($i == "assertion=" _assertion) hasassert=1
      }
      if (hasdoc && hasassert) next
      print
    }
  ' _doc="$doc" _assertion="$assertion_norm" \
    "$entry_file" > "$_dlre_tmp" || _dlre_awk_exit=$?

  if [ "$_dlre_awk_exit" -ne 0 ]; then
    rm -f "$_dlre_tmp"
    lock_release "$lock_path"
    trap - RETURN
    return 0
  fi

  mv "$_dlre_tmp" "$entry_file"

  # Delete file when all entries drained
  local _dlre_remaining
  _dlre_remaining="$(grep -c '^doc=' "$entry_file" || true)"
  [ "$_dlre_remaining" -eq 0 ] && rm -f "$entry_file"

  lock_release "$lock_path"
  trap - RETURN
}

# ---------------------------------------------------------------------------
# drift_log_clear_doc DOC
#
# Remove all drift entries for DOC across every branch in the structured store.
# This is the "consumed or cleared" operation: after rite align-docs audits a
# doc, the audit has re-verified it and any prior drift observations are
# superseded.
#
# Per-branch entry files live at:
#   ${RITE_STATE_DIR}/doc-drift/<branch>/<doc-slug>.log
#
# Discovery: iterates branch directories explicitly and constructs the exact
# entry path — no glob pattern in find -name (prevents false matches on paths
# containing [, ], ?, * characters — #345 class requirement).
#
# Locking: acquires per-file lock_acquire/lock_release (same protocol as
# drift_log_append/#706) before each rm to prevent a racing appender from
# resurrecting cleared state.  The .lock file itself is never removed — it is
# a live ln(1) lock file managed by lock_acquire/lock_release.
#
# Returns 0 always — missing files or RITE_STATE_DIR are not errors.
# ---------------------------------------------------------------------------
drift_log_clear_doc() {
  local _dlcd_doc="$1"

  [ -z "${RITE_STATE_DIR:-}" ] && return 0

  local _dlcd_slug="${_dlcd_doc//\//--}"
  local _dlcd_base="${RITE_STATE_DIR}/doc-drift"

  [ -d "$_dlcd_base" ] || return 0

  local _dlcd_branch_dir _dlcd_f _dlcd_lock
  while IFS= read -r _dlcd_branch_dir; do
    [ -d "$_dlcd_branch_dir" ] || continue
    _dlcd_f="${_dlcd_branch_dir}/${_dlcd_slug}.log"
    [ -f "$_dlcd_f" ] || continue
    _dlcd_lock="${_dlcd_f}.lock"
    if lock_acquire "$_dlcd_lock" 30; then
      rm -f "$_dlcd_f"
      lock_release "$_dlcd_lock"
    else
      printf 'drift_log_clear_doc: could not acquire lock for "%s" within 30s — skipping\n' \
        "$_dlcd_f" >&2
    fi
  done < <(find "$_dlcd_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)

  return 0
}

# ===========================================================================
# ADR DRIFT LOG — separate namespace for architectural observations at promote
#
# ADR entries live in ${RITE_STATE_DIR}/doc-drift-adr/<doc-slug>.log.
# No branch dimension: ADR observations are global (the ADR describes the
# whole product; promote sees only one branch's slice and must never edit it).
#
# Cleared only on reconcile (docs_reconcile_adr_drift in docs-command.sh) or
# when the ADR itself is audited via `rite align-docs`.
#
# Public API (same naming pattern as the regular drift-log API above):
#   adr_drift_log_append        — accumulate-in-place one ADR observation
#   adr_drift_log_entry_count   — count entries (per-doc or total)
#   adr_drift_log_remove_entry  — remove exactly one (doc, assertion) entry
# ===========================================================================

# ---------------------------------------------------------------------------
# _adr_drift_entry_path DOC
#
# Returns the absolute path to the ADR drift entry file for DOC.
# Stored in a separate namespace (doc-drift-adr/) with no branch dimension.
# Internal helper — not part of the public API.
# ---------------------------------------------------------------------------
_adr_drift_entry_path() {
  local _adep_doc="$1"
  local _adep_slug
  _adep_slug="${_adep_doc//\//--}"
  echo "${RITE_STATE_DIR:-}/doc-drift-adr/${_adep_slug}.log"
}

# ---------------------------------------------------------------------------
# adr_drift_log_append DOC PR ISSUE ASSERTION KIND EVIDENCE
#
# Append or accumulate-in-place one ADR drift entry.
# Reuses the same entry schema and lock protocol as drift_log_append but
# writes to the ADR namespace (doc-drift-adr/) with no branch field.
#
# Arguments:
#   $1  DOC       — repo-relative path of the implicated ADR doc
#   $2  PR        — promotion PR number (or '-')
#   $3  ISSUE     — issue number or '-'
#   $4  ASSERTION — the architectural observation (one sentence, < 120 chars)
#   $5  KIND      — one of: addition refinement contradiction test-scope
#                   reference-missing
#   $6  EVIDENCE  — changed paths or grep pattern that fired
#
# Returns 0 on success; 1 + stderr for invalid KIND.
# ---------------------------------------------------------------------------
adr_drift_log_append() {
  local _adla_doc="$1"
  local _adla_pr="$2"
  local _adla_issue="$3"
  local _adla_assertion="$4"
  local _adla_kind="$5"
  local _adla_evidence="$6"

  if ! _drift_kind_valid "$_adla_kind"; then
    printf 'adr_drift_log_append: invalid kind "%s"; valid: %s\n' \
      "$_adla_kind" "$_DRIFT_VALID_KINDS" >&2
    return 1
  fi

  if [ -z "${RITE_STATE_DIR:-}" ]; then
    if declare -f print_warning >/dev/null 2>&1; then
      print_warning "adr-drift-log: RITE_STATE_DIR unset — skipping append"
    fi
    return 0
  fi

  # Normalize free-text fields (same transforms as drift_log_append)
  local _adla_assertion_norm _adla_evidence_norm
  _adla_assertion_norm="${_adla_assertion//$'\t'/ }"
  _adla_assertion_norm="${_adla_assertion_norm//$'\n'/ }"
  _adla_assertion_norm="${_adla_assertion_norm//\\/}"
  _adla_evidence_norm="${_adla_evidence//$'\t'/ }"
  _adla_evidence_norm="${_adla_evidence_norm//$'\n'/ }"
  _adla_evidence_norm="${_adla_evidence_norm//\\/}"

  local _adla_entry_file
  _adla_entry_file="$(_adr_drift_entry_path "$_adla_doc")"

  mkdir -p "$(dirname "$_adla_entry_file")" || {
    printf 'adr_drift_log_append: mkdir failed for "%s" — skipping\n' \
      "$(dirname "$_adla_entry_file")" >&2
    return 0
  }

  local _adla_recorded
  _adla_recorded="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local _adla_lock_path="${_adla_entry_file}.lock"
  if ! lock_acquire "$_adla_lock_path" 30; then
    printf 'adr_drift_log_append: could not acquire lock for "%s" within 30s\n' \
      "$_adla_entry_file" >&2
    return 0
  fi
  # shellcheck disable=SC2064
  trap "lock_release '$_adla_lock_path'" RETURN

  local _adla_found=0
  local _adla_tmp="${_adla_entry_file}.tmp.$$"

  if [ -f "$_adla_entry_file" ]; then
    local _adla_awk_exit=0
    awk -F'\t' 'BEGIN{OFS="\t"; matched=0}
    {
      hasdoc=0; hasassert=0; prfldidx=0
      for (i=1; i<=NF; i++) {
        if ($i == "doc=" _doc)                hasdoc=1
        if ($i == "assertion=" _assertion)    hasassert=1
        if (substr($i, 1, 3) == "pr=")        prfldidx=i
      }
      if (hasdoc && hasassert && prfldidx > 0) {
        _prnums = substr($prfldidx, 4)
        _check  = "," _prnums ","
        if (index(_check, "," _newpr ",") == 0) {
          $prfldidx = $prfldidx "," _newpr
        }
        matched=1
      }
      print
    }
    END { exit (matched ? 0 : 1) }
    ' _doc="$_adla_doc" _assertion="$_adla_assertion_norm" _newpr="$_adla_pr" \
      "$_adla_entry_file" > "$_adla_tmp" || _adla_awk_exit=$?

    if [ "$_adla_awk_exit" -eq 0 ]; then
      _adla_found=1
      mv "$_adla_tmp" "$_adla_entry_file"
    elif [ "$_adla_awk_exit" -eq 1 ]; then
      rm -f "$_adla_tmp"
    else
      rm -f "$_adla_tmp"
      lock_release "$_adla_lock_path"
      trap - RETURN
      return 0
    fi
  fi

  if [ "$_adla_found" -eq 0 ]; then
    printf 'doc=%s\tpr=%s\tissue=%s\tassertion=%s\tkind=%s\tevidence=%s\trecorded=%s\n' \
      "$_adla_doc" "$_adla_pr" "$_adla_issue" \
      "$_adla_assertion_norm" "$_adla_kind" "$_adla_evidence_norm" "$_adla_recorded" \
      >> "$_adla_entry_file" || {
      lock_release "$_adla_lock_path"
      trap - RETURN
      return 0
    }
  fi

  lock_release "$_adla_lock_path"
  trap - RETURN
}

# ---------------------------------------------------------------------------
# adr_drift_log_entry_count [--doc DOC | --total]
#
# Count ADR drift entries in the doc-drift-adr/ namespace.
# Returns 0 even when nothing exists (echoes "0").
# ---------------------------------------------------------------------------
adr_drift_log_entry_count() {
  if [ -z "${RITE_STATE_DIR:-}" ]; then
    echo "0"; return 0
  fi

  local _adlc_doc=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --doc)   _adlc_doc="$2"; shift 2 ;;
      --total) shift ;;
      *)       shift ;;
    esac
  done

  local _adlc_base="${RITE_STATE_DIR}/doc-drift-adr"

  if [ -n "$_adlc_doc" ]; then
    local _adlc_entry
    _adlc_entry="$(_adr_drift_entry_path "$_adlc_doc")"
    [ -f "$_adlc_entry" ] || { echo "0"; return 0; }
    grep -c '^doc=' "$_adlc_entry" || true
    return 0
  fi

  [ -d "$_adlc_base" ] || { echo "0"; return 0; }
  local _adlc_total=0 _adlc_f _adlc_fc
  while IFS= read -r _adlc_f; do
    [ -f "$_adlc_f" ] || continue
    _adlc_fc="$(grep -c '^doc=' "$_adlc_f" || true)"
    _adlc_total=$((_adlc_total + _adlc_fc))
  done < <(find "$_adlc_base" -name '*.log' -type f 2>/dev/null || true)
  echo "$_adlc_total"
}

# ---------------------------------------------------------------------------
# adr_drift_log_remove_entry DOC ASSERTION
#
# Remove exactly the (DOC, ASSERTION) entry from the ADR drift store.
# No-op when the file does not exist or no matching entry is found.
# Returns 0 always.
# ---------------------------------------------------------------------------
adr_drift_log_remove_entry() {
  local _adlre_doc="$1"
  local _adlre_assertion="$2"

  [ -z "${RITE_STATE_DIR:-}" ] && return 0

  local _adlre_norm="${_adlre_assertion//$'\t'/ }"
  _adlre_norm="${_adlre_norm//$'\n'/ }"
  _adlre_norm="${_adlre_norm//\\/}"

  local _adlre_entry_file
  _adlre_entry_file="$(_adr_drift_entry_path "$_adlre_doc")"
  [ -f "$_adlre_entry_file" ] || return 0

  local _adlre_lock_path="${_adlre_entry_file}.lock"
  if ! lock_acquire "$_adlre_lock_path" 30; then
    return 0
  fi
  # shellcheck disable=SC2064
  trap "lock_release '$_adlre_lock_path'" RETURN

  local _adlre_tmp="${_adlre_entry_file}.tmp.$$"
  local _adlre_awk_exit=0
  awk -F'\t' '
    {
      hasdoc=0; hasassert=0
      for (i=1; i<=NF; i++) {
        if ($i == "doc=" _doc)             hasdoc=1
        if ($i == "assertion=" _assertion) hasassert=1
      }
      if (hasdoc && hasassert) next
      print
    }
  ' _doc="$_adlre_doc" _assertion="$_adlre_norm" \
    "$_adlre_entry_file" > "$_adlre_tmp" || _adlre_awk_exit=$?

  if [ "$_adlre_awk_exit" -ne 0 ]; then
    rm -f "$_adlre_tmp"
    lock_release "$_adlre_lock_path"
    trap - RETURN
    return 0
  fi

  mv "$_adlre_tmp" "$_adlre_entry_file"

  local _adlre_remaining
  _adlre_remaining="$(grep -c '^doc=' "$_adlre_entry_file" || true)"
  [ "${_adlre_remaining:-0}" -eq 0 ] && rm -f "$_adlre_entry_file"

  lock_release "$_adlre_lock_path"
  trap - RETURN
}

# ---------------------------------------------------------------------------
# migrate_legacy_drift_log
#
# Convert docs/sharkrite-drift-log.md legacy markdown entries into per-doc/
# per-branch schema entries in the structured store (RITE_STATE_DIR/doc-drift/).
#
# Idempotent: no-op when RITE_STATE_DIR/drift/legacy-archive.md exists.
# Silent no-op when the legacy file does not exist or RITE_STATE_DIR is unset.
#
# Parsing (best-effort):
#   Parseable block: one drift_log_append call per implicated doc with
#     branch=main, kind=contradiction, evidence=changed_files.
#   Unparseable block (no doc list extracted): one catch-all entry with
#     doc=.rite/state/drift/legacy-archive.md, kind=reference-missing,
#     assertion naming the block's recorded timestamp.
#
# After conversion: copies legacy file to RITE_STATE_DIR/drift/legacy-archive.md
# and removes docs/sharkrite-drift-log.md so migration never re-runs.
# ---------------------------------------------------------------------------
migrate_legacy_drift_log() {
  [ -z "${RITE_STATE_DIR:-}" ] && return 0

  local _mld_legacy_path
  _mld_legacy_path="$(drift_log_path 2>/dev/null || true)"
  [ -n "$_mld_legacy_path" ] || return 0
  [ -f "$_mld_legacy_path" ] || return 0

  local _mld_archive_dir="${RITE_STATE_DIR}/drift"
  local _mld_archive_path="${_mld_archive_dir}/legacy-archive.md"

  # Idempotence guard: migration already ran on a prior align-docs run.
  # If the legacy file was git-restored, stage its deletion again before returning.
  if [ -f "$_mld_archive_path" ]; then
    if [ -f "$_mld_legacy_path" ]; then
      git -C "${RITE_PROJECT_ROOT:-.}" rm -f -- "$_mld_legacy_path" >/dev/null 2>&1 \
        || rm -f "$_mld_legacy_path"
    fi
    return 0
  fi

  mkdir -p "$_mld_archive_dir" || return 0

  # Parse all legacy blocks with awk.
  # Output: one line per (block, doc) with fields separated by \001 (SOH):
  #   pr \001 issue \001 ts \001 changed \001 docpath \001 inaccuracy
  # Unparseable blocks (no doc list) emit __CATCHALL__ as docpath.
  local _mld_entries
  _mld_entries="$(awk '
    BEGIN { pr=""; issue=""; ts=""; changed=""; inaccuracy=""; doclist=""; inblock=0; indocs=0 }

    /^<!-- sharkrite-doc-drift pr:[0-9]/ {
      line = $0
      if (match(line, /pr:[0-9]+/))           pr    = substr(line, RSTART+3, RLENGTH-3)
      else                                     pr    = "-"
      if (match(line, /issue:[0-9]+/))         issue = substr(line, RSTART+6, RLENGTH-6)
      else                                     issue = "-"
      if (match(line, /recorded:[0-9TZ:+-]+/)) ts    = substr(line, RSTART+9, RLENGTH-9)
      else                                     ts    = "unknown"
      inblock=1; indocs=0; changed=""; inaccuracy=""; doclist=""
      next
    }

    inblock && /^\*\*Changed files\*\*:/ {
      idx = index($0, ": ")
      changed = (idx > 0) ? substr($0, idx+2) : ""
      indocs=0; next
    }

    inblock && /^\*\*Implicated docs\*\*:/ {
      indocs=1; next
    }

    inblock && indocs && /^- / {
      line = substr($0, 3)
      # doc path is the first space-delimited token (paths never contain spaces)
      if (match(line, /^[^ ]+/)) {
        docpath = substr(line, RSTART, RLENGTH)
        doclist = doclist (length(doclist) > 0 ? "|" : "") docpath
      }
      next
    }

    inblock && indocs && !/^- / { indocs=0 }

    inblock && /^\*\*Suspected inaccuracy\*\*:/ {
      idx = index($0, ": ")
      inaccuracy = (idx > 0) ? substr($0, idx+2) : ""
      indocs=0; next
    }

    inblock && length(inaccuracy) > 0 && !/^<!-- / && !/^\*\*[A-Za-z]/ && length($0) > 0 {
      if (length(inaccuracy) < 500) inaccuracy = inaccuracy " " $0
      next
    }

    inblock && /^<!-- \/sharkrite-doc-drift -->/ {
      if (length(doclist) > 0) {
        n = split(doclist, docs, "|")
        for (i=1; i<=n; i++) {
          print pr "\001" issue "\001" ts "\001" changed "\001" docs[i] "\001" inaccuracy
        }
      } else {
        print pr "\001" issue "\001" ts "\001" changed "\001__CATCHALL__\001" inaccuracy
      }
      inblock=0; next
    }
  ' "$_mld_legacy_path" || true)"

  local _mld_archive_path_rel="${_mld_archive_path#${RITE_PROJECT_ROOT:-}/}"
  local _mld_count=0

  while IFS=$'\001' read -r _mld_pr _mld_issue _mld_ts _mld_changed _mld_doc _mld_inaccuracy \
    || [ -n "${_mld_pr:-}" ]; do
    [ -n "${_mld_pr:-}" ] || continue

    _mld_count=$((_mld_count + 1))
    if [ "$_mld_doc" = "__CATCHALL__" ]; then
      drift_log_append \
        "$_mld_archive_path_rel" "main" "$_mld_pr" "$_mld_issue" \
        "legacy block (recorded:${_mld_ts}) — see legacy-archive.md" \
        "reference-missing" \
        "legacy:${_mld_changed:-unknown}" || true
    else
      drift_log_append \
        "$_mld_doc" "main" "$_mld_pr" "$_mld_issue" \
        "${_mld_inaccuracy:-legacy entry (recorded:${_mld_ts})}" \
        "contradiction" \
        "${_mld_changed:-unknown}" || true
    fi
  done <<< "$_mld_entries"

  # Archive and remove legacy file so this migration never re-runs.
  # git rm stages the deletion so the commit picks it up; fallback rm -f
  # handles untracked files (e.g. in tests or non-git contexts).
  cp "$_mld_legacy_path" "$_mld_archive_path" || return 0
  git -C "${RITE_PROJECT_ROOT:-.}" rm -f -- "$_mld_legacy_path" >/dev/null 2>&1 \
    || rm -f "$_mld_legacy_path"

  if declare -f print_info >/dev/null 2>&1; then
    if [ "$_mld_count" -gt 0 ]; then
      print_info "Migrated legacy drift log (${_mld_count} entries) — archived at ${_mld_archive_path_rel}"
    else
      print_info "Legacy drift log empty — archived at ${_mld_archive_path_rel}"
    fi
  fi
  return 0
}

# ===================================================================
# PUBLIC: drift_log_union_merge <log_path>
# ===================================================================
#
# Resolve a merge-conflicted drift log deterministically, in place.
#
# A drift log is append-only and its entries are independent: each is a
# self-delimited block carrying its own `recorded:` ISO8601 timestamp, and
# burn-down removes whole blocks. So a conflict here has exactly one correct
# resolution — the union of both sides, ordered by `recorded:` — and it needs
# no judgment and no LLM call. Two of the three conflicts observed in
# dogfooding logs were this file (#1231 pr:1299, #1143 pr:1312), each costing
# a 60-274s provider session to reach the answer computed here.
#
# Entries come from git's STAGE BLOBS (`git show :2:` ours, `:3:` theirs), not
# from the conflicted working-tree file. That is the whole correctness
# argument: each stage is a complete, well-formed drift log, whereas the
# conflicted file is not safely parseable. When both sides append at the same
# spot, git emits a line-level hunk and DEDUPLICATES the shared closing
# delimiter:
#
#   <<<<<<< HEAD
#   <!-- sharkrite-doc-drift pr:1304 ... -->
#   **Changed files**: ...
#   =======
#   <!-- sharkrite-doc-drift pr:1312 ... -->
#   **Changed files**: ...
#   >>>>>>> side
#   <!-- /sharkrite-doc-drift -->      <-- ONE closer for TWO entries
#
# Stripping markers from that yields two openers and one closer — structurally
# damaged, and an earlier version of this function silently dropped the first
# entry. Losing an append-only entry is the worst outcome available here, so
# the working-tree file is never parsed for content.
#
# Dedupe is on the whole block, so an entry on both sides appears once. Two
# DIFFERENT entries sharing a timestamp both survive, in ours-then-theirs
# order (`sort -s` is stable).
#
# Returns:
#   0 = file rewritten with the merged union (no conflict markers remain)
#   1 = not safely mergeable; caller should fall back to the LLM resolver
#       (no conflict stages — not a real merge conflict; either stage
#       unreadable; or zero entries found across both sides, meaning the
#       conflict is in the header prose rather than in entries)
drift_log_union_merge() {
  local _dlm_path="${1:-}"
  [ -n "$_dlm_path" ] || return 1
  [ -f "$_dlm_path" ] || return 1

  # Both conflict stages must exist. If they do not, this is not an
  # ours/theirs content conflict and we have nothing authoritative to union.
  local _dlm_ours _dlm_theirs
  _dlm_ours=$(mktemp) || return 1
  _dlm_theirs=$(mktemp) || { rm -f "$_dlm_ours"; return 1; }
  if ! git show ":2:${_dlm_path}" > "$_dlm_ours" 2>/dev/null \
     || ! git show ":3:${_dlm_path}" > "$_dlm_theirs" 2>/dev/null; then
    rm -f "$_dlm_ours" "$_dlm_theirs"
    return 1
  fi

  # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_DOC_DRIFT is an internal marker constant (defined in markers.sh), not a user config var; _RITE_ prefix cannot be used as RITE_MARKER_* is the canonical convention for all marker constants (see markers.sh); ledger is frozen per 2026-07-14 rule
  local _dlm_marker="${RITE_MARKER_DOC_DRIFT:-sharkrite-doc-drift}"

  # Extract entry blocks from one well-formed log: "<ts>\x01<block lines...>",
  # one entry per output line, \x01 standing in for newline.
  _dlm_extract() {
    awk -v m="$2" '
      index($0, "<!-- " m " pr:") == 1 {
        inblk = 1; buf = $0
        ts = $0
        if (match(ts, /recorded:[^ ]+/)) { ts = substr(ts, RSTART + 9, RLENGTH - 9) } else { ts = "0000" }
        next
      }
      inblk && index($0, "<!-- /" m " -->") == 1 {
        printf "%s\x01%s\x01%s\n", ts, buf, $0
        inblk = 0; buf = ""; next
      }
      inblk { buf = buf "\x01" $0; next }
    ' "$1" 2>/dev/null || true
  }

  local _dlm_blocks
  _dlm_blocks=$(
    _dlm_extract "$_dlm_ours" "$_dlm_marker"
    _dlm_extract "$_dlm_theirs" "$_dlm_marker"
  )
  rm -f "$_dlm_ours" "$_dlm_theirs"

  # No entries on either side → the conflict is not about entries.
  [ -n "${_dlm_blocks:-}" ] || return 1

  local _dlm_sorted
  _dlm_sorted=$(printf '%s\n' "$_dlm_blocks" | sort -s -t $'\x01' -k1,1 | cut -d $'\x01' -f2- || true)
  [ -n "${_dlm_sorted:-}" ] || return 1

  local _dlm_tmp
  _dlm_tmp=$(mktemp) || return 1

  # Regenerate the canonical header rather than salvaging it from the
  # conflicted file: it is fixed boilerplate, identical on both sides, and
  # reusing _drift_log_bootstrap keeps one definition of it.
  _drift_log_bootstrap "$_dlm_tmp" >/dev/null 2>&1 || {
    rm -f "$_dlm_tmp"
    return 1
  }

  local _dlm_seen
  _dlm_seen=$(mktemp) || { rm -f "$_dlm_tmp"; return 1; }
  local _dlm_line _dlm_count=0
  while IFS= read -r _dlm_line; do
    [ -n "$_dlm_line" ] || continue
    if grep -qxF "$_dlm_line" "$_dlm_seen" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$_dlm_line" >> "$_dlm_seen"
    printf '\n' >> "$_dlm_tmp"
    printf '%s' "$_dlm_line" | tr '\001' '\n' >> "$_dlm_tmp"
    printf '\n' >> "$_dlm_tmp"
    _dlm_count=$((_dlm_count + 1))
  done <<< "$_dlm_sorted"
  rm -f "$_dlm_seen"

  if [ "$_dlm_count" -eq 0 ]; then
    rm -f "$_dlm_tmp"
    return 1
  fi

  cat "$_dlm_tmp" > "$_dlm_path" || { rm -f "$_dlm_tmp"; return 1; }
  rm -f "$_dlm_tmp"

  if declare -f print_info >/dev/null 2>&1; then
    print_info "Drift log merged deterministically: ${_dlm_count} entry(ies), union ordered by recorded:" >&2
  fi
  return 0
}
