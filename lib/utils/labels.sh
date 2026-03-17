#!/bin/bash
# lib/utils/labels.sh
# GitHub label utilities
#
# Requires: gh CLI authenticated

# ensure_labels_exist LABELS_CSV
#
# Creates any labels in the comma-separated list that don't already exist
# in the current repo. Safe to call multiple times — skips existing labels.
ensure_labels_exist() {
  local labels_csv="$1"
  local existing
  existing=$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null || echo "")

  local label
  IFS=',' read -ra label_arr <<< "$labels_csv"
  for label in "${label_arr[@]}"; do
    label="${label// /}"  # trim spaces
    [ -z "$label" ] && continue
    if ! echo "$existing" | grep -qxF "$label"; then
      case "$label" in
        tech-debt)        gh label create "$label" --color "E4E669" --description "Technical debt to address" 2>/dev/null || true ;;
        review-follow-up) gh label create "$label" --color "0075ca" --description "Follow-up from code review" 2>/dev/null || true ;;
        "High Priority")  gh label create "$label" --color "FBCA04" --description "High priority item" 2>/dev/null || true ;;
        "Medium Priority")gh label create "$label" --color "0E8A16" --description "Medium priority item" 2>/dev/null || true ;;
        from-review)      gh label create "$label" --color "BFD4F2" --description "Identified during code review" 2>/dev/null || true ;;
        automated)        gh label create "$label" --color "ededed" --description "Automatically created by Sharkrite" 2>/dev/null || true ;;
        *)                gh label create "$label" --color "ededed" 2>/dev/null || true ;;
      esac
    fi
  done
}
