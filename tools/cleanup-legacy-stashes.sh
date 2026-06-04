#!/bin/bash
# tools/cleanup-legacy-stashes.sh
# One-time cleanup tool for legacy sharkrite stashes (created before marker system).
#
# This script identifies and removes stashes created by sharkrite before the
# [sharkrite-managed-stash] marker was introduced. It recognizes stashes by
# their message patterns (e.g., "Auto-stash before...", "stale-branch: auto-stash...").
#
# Usage:
#   ./tools/cleanup-legacy-stashes.sh            # Preview mode (dry run)
#   ./tools/cleanup-legacy-stashes.sh --execute  # Actually drop stashes
#   ./tools/cleanup-legacy-stashes.sh --repo /path/to/repo  # Target specific repo

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_info() {
  echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
  echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
  echo -e "${RED}✗${NC} $1"
}

# Source marker constants (tools/ is one level up from lib/utils/)
_cleanup_stashes_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_cleanup_stashes_dir/../lib/utils/markers.sh"

# Parse arguments
DRY_RUN=true
TARGET_REPO="."

while [ $# -gt 0 ]; do
  case "$1" in
    --execute)
      DRY_RUN=false
      shift
      ;;
    --repo)
      TARGET_REPO="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--execute] [--repo /path/to/repo]"
      exit 1
      ;;
  esac
done

# Verify we're in a git repo
if ! git -C "$TARGET_REPO" rev-parse --git-dir >/dev/null 2>&1; then
  print_error "Not a git repository: $TARGET_REPO"
  exit 1
fi

print_header "Sharkrite Legacy Stash Cleanup"

if [ "$DRY_RUN" = true ]; then
  print_warning "DRY RUN MODE - no stashes will be dropped"
  echo ""
fi

# Legacy stash patterns created by sharkrite (before marker system)
# These patterns match stash messages from the old code
LEGACY_PATTERNS=(
  "Auto-stash before worktree cleanup:"
  "Auto-stash unrelated work before issue"
  "Auto-stash unrelated changes before issue"
  "stale-branch: auto-stash before"
  "divergence-handler: auto-stash before"
  "rescue-"
)

# Get all stashes
all_stashes=$(git -C "$TARGET_REPO" stash list 2>/dev/null || echo "")

if [ -z "$all_stashes" ]; then
  print_info "No stashes found in repository"
  exit 0
fi

total_stashes=$(echo "$all_stashes" | wc -l | tr -d ' ')
print_info "Total stashes in repository: $total_stashes"
echo ""

# Identify legacy sharkrite stashes
legacy_stashes=()
user_stashes=()

while IFS= read -r stash_line; do
  is_legacy=false

  # Check if this matches any legacy pattern
  for pattern in "${LEGACY_PATTERNS[@]}"; do
    if echo "$stash_line" | grep -qF "$pattern"; then
      is_legacy=true
      break
    fi
  done

  # Also exclude already-marked stashes
  if echo "$stash_line" | grep -qF "[${RITE_MARKER_STASH}]"; then
    is_legacy=false
  fi

  if [ "$is_legacy" = true ]; then
    legacy_stashes+=("$stash_line")
  else
    user_stashes+=("$stash_line")
  fi
done <<< "$all_stashes"

legacy_count=${#legacy_stashes[@]}
user_count=${#user_stashes[@]}

print_header "Analysis Results"
echo "Legacy sharkrite stashes: $legacy_count"
echo "User/other stashes: $user_count"
echo ""

if [ "$legacy_count" -eq 0 ]; then
  print_success "No legacy sharkrite stashes found!"
  exit 0
fi

print_warning "Found $legacy_count legacy sharkrite stash(es):"
echo ""

for stash_line in "${legacy_stashes[@]}"; do
  stash_ref=$(echo "$stash_line" | cut -d':' -f1)
  stash_msg=$(echo "$stash_line" | cut -d':' -f2-)

  # Get age
  stash_epoch=$(git -C "$TARGET_REPO" log -1 --format=%ct "$stash_ref" 2>/dev/null || echo "0")
  if [ "$stash_epoch" != "0" ]; then
    current_epoch=$(date +%s)
    age_days=$(( (current_epoch - stash_epoch) / 86400 ))
    echo "  $stash_ref ($age_days days old):$stash_msg"
  else
    echo "  $stash_ref (age unknown):$stash_msg"
  fi
done

echo ""

if [ "$DRY_RUN" = true ]; then
  print_info "To actually remove these stashes, run:"
  echo "  $0 --execute --repo \"$TARGET_REPO\""
  exit 0
fi

# Execute mode - drop the stashes
print_warning "Dropping $legacy_count legacy stash(es)..."
echo ""

dropped_count=0
failed_count=0

# Drop in reverse order (highest index first) to avoid shifting indices
for (( i=${#legacy_stashes[@]}-1; i>=0; i-- )); do
  stash_line="${legacy_stashes[$i]}"
  stash_ref=$(echo "$stash_line" | cut -d':' -f1)

  if git -C "$TARGET_REPO" stash drop "$stash_ref" 2>/dev/null; then
    dropped_count=$((dropped_count + 1))
    print_success "Dropped: $stash_ref"
  else
    failed_count=$((failed_count + 1))
    print_error "Failed to drop: $stash_ref"
  fi
done

echo ""
print_header "Cleanup Complete"
echo "Dropped: $dropped_count"
if [ "$failed_count" -gt 0 ]; then
  echo "Failed: $failed_count"
fi
echo "Remaining stashes: $user_count"
