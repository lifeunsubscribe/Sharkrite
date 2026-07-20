#!/bin/bash
# lib/utils/integration-ledger.sh
# Per-branch integration ledger: one tab-separated line per merged issue.
#
# Each entry records the durable issue↔SHA binding that squash-merge subjects
# cannot carry (subjects are "<PR title> (#PRNUM)" — issue number is absent).
# This file is the only persistent record that later powers --status,
# --promote (full and single-issue), post-promotion comments, and audit trails.
#
# Line format (key=value, tab-separated, greppable and forward-compatible):
#   issue=42	pr=97	sha=<40-hex>	merged_at=2026-07-07T04:12:33Z	promoted=false
#
# Ledger file location: $RITE_STATE_DIR/integration-branches/<branch>.log
# Branch names may contain '/' (e.g. release/1.2), so the ledger file can
# live in a nested subdirectory.  append() creates the parent dir on demand.
#
# Locking: every file mutation wraps in lock_acquire/lock_release from
# lib/utils/lock.sh, keyed per ledger file.  flock(1) is unavailable on macOS
# so lock.sh is the portable equivalent.  A promote's mark_promoted rewrite
# racing a concurrent batch merge-append cannot drop an appended line.
#
# Public API:
#   integration_ledger_append  <branch> <issue_num> <pr_num> <sha>
#   integration_ledger_entries <branch>
#   integration_ledger_mark_promoted <branch> <issue_num>

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing).
# Function-sentinel guard (not env-var guard) so bats pre-source stubs for
# any downstream caller are preserved — lint Rule 34 (BATS_PRE_SOURCE_STUB_OVERWRITE).
if declare -f integration_ledger_append >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if not already bootstrapped (provides RITE_LIB_DIR, RITE_STATE_DIR)
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _IL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_IL_SCRIPT_DIR/config.sh"
fi

# Source the shared lock primitive (lock_acquire, lock_release)
if ! declare -f lock_acquire >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/lock.sh"
fi

# ---------------------------------------------------------------------------
# _integration_ledger_path <branch>
#
# Returns the absolute path to the ledger file for <branch>.
# Exported as a helper for consumers — not part of the public API.
# ---------------------------------------------------------------------------
_integration_ledger_path() {
  local branch="$1"
  echo "${RITE_STATE_DIR:-}/integration-branches/${branch}.log"
}

# ---------------------------------------------------------------------------
# integration_ledger_append <branch> <issue_num> <pr_num> <sha>
#
# Appends one ledger entry for a just-merged issue.  Skips (with a warning)
# when RITE_STATE_DIR is unset — callers in test harnesses without config
# are protected from creating files in unexpected places.
#
# Locking: acquires a per-file lock (30s timeout) before append.
# ---------------------------------------------------------------------------
integration_ledger_append() {
  local branch="$1"
  local issue_num="$2"
  local pr_num="$3"
  local sha="$4"

  if [ -z "${RITE_STATE_DIR:-}" ]; then
    echo "integration_ledger_append: RITE_STATE_DIR is unset — skipping ledger write" >&2
    return 0
  fi

  local ledger_file
  ledger_file=$(_integration_ledger_path "$branch")

  # Create the ledger file's parent directory on demand.
  # Branch names may contain '/', so mkdir -p of dirname is required.
  mkdir -p "$(dirname "$ledger_file")"

  # UTC ISO 8601 timestamp — portable to BSD (macOS) and GNU (Linux)
  local merged_at
  merged_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local lock_path="${ledger_file}.lock"

  # Acquire per-file lock (30s timeout) to prevent concurrent append+rewrite races
  if ! lock_acquire "$lock_path" 30; then
    echo "integration_ledger_append: could not acquire lock for '$ledger_file' (timeout 30s)" >&2
    return 1
  fi

  # Trap ensures the lock is released even if printf fails under set -e.
  # shellcheck disable=SC2064
  trap "lock_release '$lock_path'" RETURN

  # Append the ledger entry (tab-separated key=value fields)
  printf 'issue=%s\tpr=%s\tsha=%s\tmerged_at=%s\tpromoted=false\n' \
    "$issue_num" "$pr_num" "$sha" "$merged_at" >> "$ledger_file"

  lock_release "$lock_path"
  trap - RETURN
}

# ---------------------------------------------------------------------------
# integration_ledger_entries <branch>
#
# Prints all ledger lines for <branch> to stdout.
# Prints nothing (exit 0) if the ledger file does not exist.
# ---------------------------------------------------------------------------
integration_ledger_entries() {
  local branch="$1"
  local ledger_file
  ledger_file=$(_integration_ledger_path "$branch")

  if [ -f "$ledger_file" ]; then
    cat "$ledger_file"
  fi
}

# ---------------------------------------------------------------------------
# integration_ledger_mark_promoted <branch> <issue_num>
#
# Flips promoted=false → promoted=true for the given issue in <branch>'s ledger.
# Uses a temp-file rewrite (NOT sed -i — BSD/GNU divergence, lint rule).
# Acquires per-file lock to prevent racing with concurrent ledger appends.
# Exits 0 even if the issue had no matching entry (idempotent for callers).
# ---------------------------------------------------------------------------
integration_ledger_mark_promoted() {
  local branch="$1"
  local issue_num="$2"

  if [ -z "${RITE_STATE_DIR:-}" ]; then
    echo "integration_ledger_mark_promoted: RITE_STATE_DIR is unset — skipping" >&2
    return 0
  fi

  local ledger_file
  ledger_file=$(_integration_ledger_path "$branch")

  # Nothing to do if the ledger doesn't exist yet
  [ -f "$ledger_file" ] || return 0

  local lock_path="${ledger_file}.lock"

  if ! lock_acquire "$lock_path" 30; then
    echo "integration_ledger_mark_promoted: could not acquire lock for '$ledger_file' (timeout 30s)" >&2
    return 1
  fi

  # Temp-file rewrite: read each line; flip promoted=false on the matching issue line.
  # NOT sed -i: BSD sed requires sed -i '' and GNU requires sed -i; portable = temp file.
  local tmp_file
  tmp_file="${ledger_file}.tmp.$$"

  # Trap ensures the lock is released even if the rewrite fails under set -e.
  # Also cleans up the temp file on unexpected exit.
  # shellcheck disable=SC2064
  trap "rm -f '${tmp_file}'; lock_release '$lock_path'" RETURN

  while IFS= read -r line; do
    # Match the exact issue field at the start of a tab-separated record
    case "$line" in
      issue="${issue_num}"$'\t'*)
        # Flip promoted=false → promoted=true on this line only
        printf '%s\n' "${line/promoted=false/promoted=true}"
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done < "$ledger_file" > "$tmp_file"

  mv "$tmp_file" "$ledger_file"

  lock_release "$lock_path"
  trap - RETURN
}
