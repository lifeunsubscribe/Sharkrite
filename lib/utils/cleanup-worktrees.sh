#!/bin/bash
# lib/utils/cleanup-worktrees.sh
# Manual worktree management tool
#
# NOTE: This script is for MANUAL use only. It is NOT called automatically.
#       Automated worktree cleanup runs during periodic deep clean in merge-pr.sh.
#
# Usage:
#   cleanup-worktrees.sh           # Interactive mode - review each worktree
#   cleanup-worktrees.sh --auto    # Auto mode - remove all stale worktrees

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

set -e

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

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

AUTO_MODE=false
if [[ "${1:-}" == "--auto" ]]; then
  AUTO_MODE=true
fi

MAIN_WORKTREE=$(git rev-parse --show-toplevel)
WORKTREE_BASE="$RITE_WORKTREE_DIR"

print_header "🌳 Worktree Cleanup Manager"

# Get all worktrees
EXISTING_WORKTREES=$(git worktree list --porcelain | grep -E "^worktree $WORKTREE_BASE" | sed 's/^worktree //' || echo "")

if [ -z "$EXISTING_WORKTREES" ]; then
  print_success "No worktrees to clean up!"
  exit 0
fi

echo "📁 Current worktrees:"
echo ""

STALE_WORKTREES=()
ACTIVE_WORKTREES=()

while IFS= read -r wt_path; do
  [ -z "$wt_path" ] && continue

  WT_BRANCH=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "unknown")
  UNCOMMITTED_COUNT=$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

  # Check if branch has been merged/deleted
  BRANCH_EXISTS=$(git show-ref --verify --quiet refs/heads/"$WT_BRANCH" && echo "yes" || echo "no")

  # Check last modification
  LAST_MODIFIED=$(find "$wt_path" -type f \( -name "*.ts" -o -name "*.js" \) 2>/dev/null | xargs stat -f "%m %N" 2>/dev/null | sort -rn | head -1 | awk '{print $1}')

  if [ -n "$LAST_MODIFIED" ]; then
    DAYS_OLD=$(( ( $(date +%s) - LAST_MODIFIED ) / 86400 ))
  else
    DAYS_OLD=999
  fi

  IS_STALE=false
  STALE_REASON=""

  # Determine if stale
  if [ "$BRANCH_EXISTS" = "no" ]; then
    IS_STALE=true
    STALE_REASON="Branch deleted/merged"
  elif [ "$UNCOMMITTED_COUNT" -eq 0 ] && [ "$DAYS_OLD" -gt 14 ]; then
    IS_STALE=true
    STALE_REASON="No activity for $DAYS_OLD days"
  fi

  if [ "$IS_STALE" = true ]; then
    STALE_WORKTREES+=("$wt_path|$WT_BRANCH|$STALE_REASON")
    echo "  🗑️  $(basename "$wt_path") ($WT_BRANCH) - $STALE_REASON"
  else
    ACTIVE_WORKTREES+=("$wt_path|$WT_BRANCH")
    STATUS="✓ Active"
    [ "$UNCOMMITTED_COUNT" -gt 0 ] && STATUS="⚠️  $UNCOMMITTED_COUNT uncommitted files"
    echo "  $STATUS $(basename "$wt_path") ($WT_BRANCH)"
  fi
done <<< "$EXISTING_WORKTREES"

echo ""
echo "Summary:"
echo "  Active: ${#ACTIVE_WORKTREES[@]}"
echo "  Stale: ${#STALE_WORKTREES[@]}"
echo ""

if [ ${#STALE_WORKTREES[@]} -eq 0 ]; then
  print_success "No stale worktrees to clean up!"
  exit 0
fi

# Cleanup options
if [ "$AUTO_MODE" = true ]; then
  print_warning "Auto mode: removing all stale worktrees"
  CLEANUP_CHOICE="all"
else
  echo "Cleanup options:"
  echo "  1. Remove all stale worktrees (${#STALE_WORKTREES[@]} total)"
  echo "  2. Review each one individually"
  echo "  3. Cancel"
  echo ""
  read -p "Choose [1/2/3]: " -n 1 -r
  echo

  case "$REPLY" in
    1)
      CLEANUP_CHOICE="all"
      ;;
    2)
      CLEANUP_CHOICE="individual"
      ;;
    *)
      print_info "Cancelled"
      exit 0
      ;;
  esac
fi

# Perform cleanup
REMOVED_COUNT=0

for entry in "${STALE_WORKTREES[@]}"; do
  IFS='|' read -r wt_path wt_branch reason <<< "$entry"

  SHOULD_REMOVE=false

  if [ "$CLEANUP_CHOICE" = "all" ]; then
    SHOULD_REMOVE=true
  else
    echo ""
    echo "Worktree: $(basename "$wt_path")"
    echo "Branch: $wt_branch"
    echo "Reason: $reason"
    read -p "Remove this worktree? (y/n) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] && SHOULD_REMOVE=true
  fi

  if [ "$SHOULD_REMOVE" = true ]; then
    # Check for uncommitted changes one more time
    UNCOMMITTED=$(git -C "$wt_path" status --porcelain 2>/dev/null || echo "")

    if [ -n "$UNCOMMITTED" ]; then
      print_warning "Found uncommitted changes in $wt_branch"
      git -C "$wt_path" stash push -m "Auto-stash before worktree cleanup: $wt_branch - $(date +%Y-%m-%d)"
      print_info "Changes stashed - recover with: git stash list"
    fi

    # Remove worktree
    git worktree remove "$wt_path" --force 2>/dev/null || git worktree remove "$wt_path"
    print_success "Removed: $(basename "$wt_path")"
    REMOVED_COUNT=$((REMOVED_COUNT + 1))
  fi
done

echo ""
print_header "🎉 Cleanup Complete"
echo "Removed: $REMOVED_COUNT worktree(s)"
echo "Remaining: ${#ACTIVE_WORKTREES[@]} active worktree(s)"
echo ""

if [ ${#ACTIVE_WORKTREES[@]} -gt 0 ]; then
  echo "Active worktrees:"
  for entry in "${ACTIVE_WORKTREES[@]}"; do
    IFS='|' read -r wt_path wt_branch <<< "$entry"
    echo "  • $wt_branch - $wt_path"
  done
  echo ""
fi

print_info "To see all worktrees: git worktree list"
