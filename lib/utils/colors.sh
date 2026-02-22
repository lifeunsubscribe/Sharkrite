#!/bin/bash
# lib/utils/colors.sh - Terminal color definitions and print helpers

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
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

# Export for use in subshells
export RED GREEN YELLOW BLUE MAGENTA CYAN DIM NC
export -f print_header print_success print_error print_warning print_info print_status print_step strip_ansi 2>/dev/null || true
