#!/bin/bash
# tools/lint-autofix.sh — deterministic pre-gate auto-fixer for the SAFE,
# mechanical, recurring lint violations.
#
# Purpose: a dev session keeps reintroducing the same few mechanical lint trips;
# rather than discover them via a full gate → fix-loop → full gate round-trip,
# correct them in place right after implementation. ONLY behavior-preserving,
# idempotent, unambiguous rewrites live here — each mirrors a sharkrite-lint rule
# and applies that rule's documented fix. Risky/semantic violations are NOT
# auto-fixed; they stay detect-only (the gate catches them).
#
# Rules auto-fixed (the safe subset, chosen from real recurrence data):
#   GREP_C_ECHO_ZERO   the grep-count "echo zero" double-count fallback → `|| true`   (all shell files)
#   JQ_DEFAULT_BRACE   `${VAR:-{}}`                  → `${VAR:-"{}"}` (all shell files)
#   BARE_VAR_REFERENCE bare `$EMAIL_*` etc.          → `${EMAIL_*:-}` (lib/utils/*.sh — the rule's scope)
#
# Design constraints (operator requirement): fast, resource-light, SILENT, and
# it MUST NOT hang. It only touches files passed to it (targeted — the caller
# passes the dev session's changed files, never a full-repo scan), uses no LLM
# and no network, writes a file only when its content actually changes (so
# unchanged files keep their mtime), and is idempotent. The orchestrator runs it
# under run_with_timeout as a hard backstop.
#
# Usage:
#   tools/lint-autofix.sh <file> [file...]      # fix specific files
#   tools/lint-autofix.sh --changed [base]      # fix changed shell files vs base (default origin/main)
# Emits one diag line: [diag] LINT_AUTOFIX fixed=N files=<csv>. Always exits 0.

set -euo pipefail

# Re-source guard (function-sentinel).
if declare -f autofix_file >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source portable_sed_i's sibling deps via BASH_SOURCE-derived path (works in
# every mode; no RITE_LIB_DIR dependency).
_AUTOFIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_AUTOFIX_LIB="$_AUTOFIX_DIR/../lib"
# logging.sh provides _diag; degrade to a no-op if unavailable (e.g. standalone).
if [ -f "$_AUTOFIX_LIB/utils/logging.sh" ]; then
  # shellcheck source=/dev/null
  source "$_AUTOFIX_LIB/utils/logging.sh" 2>/dev/null || true
fi
declare -f _diag >/dev/null 2>&1 || _diag() { :; }

# ---------------------------------------------------------------------------
# autofix_file <file>
# Applies the safe rewrites to ONE file, in place, only if content changes.
# Echoes "1" if the file was changed, "0" otherwise. Never errors out the caller.
# ---------------------------------------------------------------------------
autofix_file() {
  local _f="$1"
  [ -f "$_f" ] || { echo 0; return 0; }

  # Shell files only (by extension or bash/sh shebang).
  case "$_f" in
    *.sh|*.bash) ;;
    *)
      head -1 "$_f" 2>/dev/null | grep -qE '^#!.*(bash|sh)( |$)' || { echo 0; return 0; }
      ;;
  esac

  # BARE_VAR_REFERENCE mirrors the lint rule's scope (lib/utils/*.sh only).
  local _do_barevar=0
  case "$_f" in */lib/utils/*.sh|lib/utils/*.sh) _do_barevar=1 ;; esac

  local _tmp
  _tmp=$(mktemp "${TMPDIR:-/tmp}/rite_autofix_XXXXXX") || { echo 0; return 0; }

  # Build the sed program. Each clause mirrors a lint rule's documented fix and
  # is idempotent (re-running matches nothing). BARE_VAR clauses are appended
  # only for in-scope files (longest family prefixes first so RITE_* wins).
  # GREP_C_ECHO_ZERO: on grep-count lines, a trailing echo-zero fallback becomes
  # `|| true`. Three clauses cover the quoted form, the bare form before a `)`
  # (the common cmd-substitution case), and the bare form at end-of-line. The
  # `(…)` capture preserves the leading `||` + spacing and any trailing `)`.
  local _sed_args=(
    -E
    -e '/grep -c/ s/(\|\|[[:space:]]*)echo[[:space:]]+"0"/\1true/g'
    -e '/grep -c/ s/(\|\|[[:space:]]*)echo[[:space:]]+0([[:space:]]*\))/\1true\2/g'
    -e '/grep -c/ s/(\|\|[[:space:]]*)echo[[:space:]]+0[[:space:]]*$/\1true/g'
    -e 's/:-\{\}\}/:-"{}"}/g'
  )
  if [ "$_do_barevar" = "1" ]; then
    _sed_args+=(
      -e 's/\$(RITE_EMAIL_[A-Z0-9_]+)/${\1:-}/g'
      -e 's/\$(RITE_SNS_[A-Z0-9_]+)/${\1:-}/g'
      -e 's/\$(EMAIL_[A-Z0-9_]+)/${\1:-}/g'
      -e 's/\$(SLACK_[A-Z0-9_]+)/${\1:-}/g'
      -e 's/\$(AWS_[A-Z0-9_]+)/${\1:-}/g'
      -e 's/\$(SNS_[A-Z0-9_]+)/${\1:-}/g'
    )
  fi

  if ! sed "${_sed_args[@]}" "$_f" > "$_tmp" 2>/dev/null; then
    rm -f "$_tmp"; echo 0; return 0
  fi

  if cmp -s "$_tmp" "$_f"; then
    rm -f "$_tmp"; echo 0; return 0      # no change → don't touch the file
  fi

  # Content changed — write back, preserving the original file's perms/inode.
  cat "$_tmp" > "$_f"
  rm -f "$_tmp"
  echo 1
}

# ---------------------------------------------------------------------------
# autofix_run <file...>
# Runs autofix_file over a list, tallies, emits one diag line. Always exits 0.
# ---------------------------------------------------------------------------
autofix_run() {
  local _fixed=0 _fixed_files="" _f _r
  for _f in "$@"; do
    [ -n "$_f" ] || continue
    _r=$(autofix_file "$_f" || echo 0)
    if [ "$_r" = "1" ]; then
      _fixed=$((_fixed + 1))
      _fixed_files="${_fixed_files}${_fixed_files:+,}$_f"
    fi
  done
  _diag "LINT_AUTOFIX fixed=${_fixed} files=${_fixed_files:-none}"
  echo "$_fixed"
  return 0
}

# ---------------------------------------------------------------------------
# Functions-only guard (tests source the functions without the body running).
# ---------------------------------------------------------------------------
if [ "${RITE_SOURCE_FUNCTIONS_ONLY:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi

# --- executable body ---
_files=()
if [ "${1:-}" = "--changed" ]; then
  _base="${2:-origin/main}"
  while IFS= read -r _line; do
    [ -n "$_line" ] && _files+=("$_line")
  done < <(git diff --name-only --diff-filter=ACMR "$_base"...HEAD 2>/dev/null \
             | grep -E '\.(sh|bash)$|^bin/' || true)
else
  _files=("$@")
fi

[ "${#_files[@]}" -gt 0 ] || { _diag "LINT_AUTOFIX fixed=0 files=none"; exit 0; }
autofix_run "${_files[@]}" >/dev/null
exit 0
