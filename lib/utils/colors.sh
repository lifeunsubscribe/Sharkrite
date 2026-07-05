#!/bin/bash
# lib/utils/colors.sh - Terminal color definitions and print helpers

set -euo pipefail

# Re-source guard — variable-based (not function-sentinel) because this file
# `export -f`s its functions; see blocker-rules.sh for the full rationale and
# tests/regression/blocker-rules-stale-inherited-functions.bats for the trap.
# Do NOT export _RITE_COLORS_LOADED — subprocesses must re-source.
if [ "${_RITE_COLORS_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_COLORS_LOADED=true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

print_header() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}" >&2; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_status() { echo -e "${BLUE}$1${NC}"; }
print_step() { echo -e "${CYAN}▶  $1${NC}"; }

# Strip ANSI escape sequences (for log files).
# Uses perl with autoflush ($|=1) instead of sed. sed block-buffers when
# writing to a file, so on process exit unflushed data is lost — truncating
# logs mid-line. perl autoflush writes every line immediately.
strip_ansi() {
  perl -pe 'BEGIN { $| = 1 } s/\e\[[0-9;]*[a-zA-Z]//g'
}

# Indent + prettify `git push` porcelain for nested workflow output. Reads the
# push transcript on stdin and rewrites each line:
#   "To <url>"                 -> "   To <url>"                (base indent)
#   "<sha>..<sha> <l> -> <r>"  -> "      <sha>..<sha> <l>"     (deeper indent)
#                                 "         -> <r>"            (ref target on its own line)
# Splitting on " -> " keeps the long branch->branch mapping from running off the
# right edge. awk (POSIX index/substr) stays portable across BSD/GNU.
format_git_push_output() {
  awk '
    { _l=$0; sub(/^[ \t]+/, "", _l)
      _p=index(_l, " -> ")
      if (_p>0)
        printf "      %s\n         -> %s\n", substr(_l,1,_p-1), substr(_l,_p+4)
      else
        printf "   %s\n", _l
    }'
}

# Export for use in subshells
export RED GREEN YELLOW BLUE MAGENTA CYAN BOLD DIM NC
export -f print_header print_success print_error print_warning print_info print_status print_step strip_ansi format_git_push_output 2>/dev/null || true
