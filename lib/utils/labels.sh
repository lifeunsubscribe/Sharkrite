#!/bin/bash
# lib/utils/labels.sh
# GitHub label utilities
#
# Requires: gh CLI authenticated

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f ensure_labels_exist >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source gh retry wrapper if not already loaded
_LABELS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f gh_safe >/dev/null 2>&1; then
  source "$_LABELS_DIR/gh-retry.sh"
fi

# ensure_labels_exist LABELS_CSV
#
# Creates any labels in the comma-separated list that don't already exist
# in the current repo. Safe to call multiple times — skips existing labels.
ensure_labels_exist() {
  local labels_csv="$1"
  local existing
  existing=$(gh_safe label list --limit 200 --json name --jq '.[].name' || true)
  existing="${existing:-}"

  local label
  IFS=',' read -ra label_arr <<< "$labels_csv"
  for label in "${label_arr[@]}"; do
    # Trim leading/trailing whitespace only. The previous form
    # "${label// /}" stripped ALL spaces, so multi-word labels like
    # "Medium Priority" became "MediumPriority" — creating orphan labels
    # that didn't match what gh issue create asked for downstream.
    label="${label#"${label%%[![:space:]]*}"}"
    label="${label%"${label##*[![:space:]]}"}"
    [ -z "$label" ] && continue
    if ! echo "$existing" | grep -qxF "$label"; then
      # gh_safe handles retry on 429/5xx; || true allows "already exists" failures
      # (label may race-create between list and create — harmless to skip)
      case "$label" in
        tech-debt)        gh_safe label create "$label" --color "E4E669" --description "Technical debt to address" || true ;;
        review-follow-up) gh_safe label create "$label" --color "0075ca" --description "Follow-up from code review" || true ;;
        priority-high)    gh_safe label create "$label" --color "B60205" --description "Fix soon — blocks dogfooding or amplifies risk" || true ;;
        priority-medium)  gh_safe label create "$label" --color "FBCA04" --description "Important but not blocking" || true ;;
        priority-low)     gh_safe label create "$label" --color "CCCCCC" --description "Hygiene / nice-to-have" || true ;;
        from-review)      gh_safe label create "$label" --color "BFD4F2" --description "Identified during code review" || true ;;
        automated)        gh_safe label create "$label" --color "ededed" --description "Automatically created by Sharkrite" || true ;;
        *)                gh_safe label create "$label" --color "ededed" || true ;;
      esac
    fi
  done
}
