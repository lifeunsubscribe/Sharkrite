#!/bin/bash
# lib/utils/labels.sh
# GitHub label utilities
#
# Requires: gh CLI authenticated

set -euo pipefail

if [ -n "${RITE_LIB_DIR:-}" ]; then
  source "$RITE_LIB_DIR/utils/gh-retry.sh"
fi

# ensure_labels_exist LABELS_CSV
#
# Creates any labels in the comma-separated list that don't already exist
# in the current repo. Safe to call multiple times — skips existing labels.
ensure_labels_exist() {
  local labels_csv="$1"
  local existing
  existing=$(gh_safe label list --limit 200 --json name --jq '.[].name' || echo "")

  local label
  IFS=',' read -ra label_arr <<< "$labels_csv"
  for label in "${label_arr[@]}"; do
    label="${label// /}"  # trim spaces
    [ -z "$label" ] && continue
    if ! echo "$existing" | grep -qxF "$label"; then
      case "$label" in
        tech-debt)        gh_safe label create "$label" --color "E4E669" --description "Technical debt to address" || true ;;
        review-follow-up) gh_safe label create "$label" --color "0075ca" --description "Follow-up from code review" || true ;;
        "High Priority")  gh_safe label create "$label" --color "FBCA04" --description "High priority item" || true ;;
        "Medium Priority")gh_safe label create "$label" --color "0E8A16" --description "Medium priority item" || true ;;
        from-review)      gh_safe label create "$label" --color "BFD4F2" --description "Identified during code review" || true ;;
        automated)        gh_safe label create "$label" --color "ededed" --description "Automatically created by Sharkrite" || true ;;
        *)                gh_safe label create "$label" --color "ededed" || true ;;
      esac
    fi
  done
}
