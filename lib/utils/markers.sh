#!/bin/bash
# lib/utils/markers.sh — Canonical marker string constants for Sharkrite
#
# All sharkrite-* marker strings are defined here as readonly constants.
# No other file may use sharkrite-* string literals; import this module instead.
#
# Usage:
#   source "$RITE_LIB_DIR/utils/markers.sh"
#   gh pr view ... --jq "select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))"
#
# Marker format conventions:
#   HTML comment markers: <!-- MARKER [attributes...] -->
#   Body-text markers (search/grep):  MARKER:N  (no angle brackets)
#   Stash tag:                        [MARKER]  (square brackets, git stash format)
#
# ADDING A NEW MARKER:
#   1. Define it here with a readonly variable (RITE_MARKER_*)
#   2. Add it to the ALLOWLIST at the bottom of this file
#   3. Source markers.sh in every file that reads or writes the marker
#   4. Update tests/regression/marker-round-trip.bats with a round-trip test

set -euo pipefail

# Guard against double-sourcing (readonly declarations fail on re-assignment)
[ -n "${_RITE_MARKERS_LOADED:-}" ] && return 0
readonly _RITE_MARKERS_LOADED=1

# =============================================================================
# PR comment markers (HTML comment format)
# =============================================================================

# Written by local-review.sh, read by assess-and-resolve.sh, pr-detection.sh,
# repo-status.sh, review-assessment.sh, workflow-runner.sh, merge-pr.sh,
# assess-documentation.sh.
readonly RITE_MARKER_REVIEW="sharkrite-local-review"

# Written by assess-review-issues.sh, read by assess-and-resolve.sh,
# workflow-runner.sh, claude-workflow.sh, merge-pr.sh, divergence-handler.sh,
# repo-status.sh.
readonly RITE_MARKER_ASSESSMENT="sharkrite-assessment"

# Written inside review comments by local-review.sh (structured JSON block),
# read by assess-and-resolve.sh and assess-documentation.sh.
readonly RITE_MARKER_REVIEW_DATA="sharkrite-review-data"

# =============================================================================
# Issue body markers (body-text format, no angle brackets)
# Written into GitHub issue bodies; searched via gh issue list --search
# =============================================================================

# Written into follow-up issue bodies (source: assess-and-resolve.sh,
# assess-review-issues.sh); used to search for follow-up issues by origin.
readonly RITE_MARKER_SOURCE_ISSUE="sharkrite-source-issue"

# Written into follow-up issue bodies to link back to the parent PR
# (assess-and-resolve.sh). Read by batch-process-issues.sh, claude-workflow.sh,
# undo-workflow.sh.
readonly RITE_MARKER_PARENT_PR="sharkrite-parent-pr"

# =============================================================================
# PR comment markers (body-text/hybrid format)
# Posted as PR comment bodies; also searched via grep on comment text
# =============================================================================

# Written as a PR comment after follow-up issues are created
# (assess-and-resolve.sh). Read by workflow-runner.sh, merge-pr.sh,
# undo-workflow.sh to discover follow-up issue numbers.
readonly RITE_MARKER_FOLLOWUP_ISSUE="sharkrite-followup-issue"

# =============================================================================
# PR description markers (HTML comment delimiters, paired open/close)
# =============================================================================

# Paired markers wrapping the auto-generated changes summary section in PR
# bodies (pr-summary.sh). Opening tag; closing tag uses /sharkrite-changes-summary.
readonly RITE_MARKER_CHANGES_SUMMARY="sharkrite-changes-summary"

# =============================================================================
# Workflow state markers (miscellaneous)
# =============================================================================

# Written as a PR comment by workflow-runner.sh when a conflict is
# auto-resolved during the stale-branch update path.
readonly RITE_MARKER_AUTO_RESOLVED="sharkrite-auto-resolved"

# =============================================================================
# Git stash tag (square-bracket format, not an HTML comment)
# =============================================================================

# Tag embedded in git stash messages by stash-manager.sh to distinguish
# sharkrite-managed stashes from user-created stashes.
# Format in stash list: "[sharkrite-managed-stash] <message>"
readonly RITE_MARKER_STASH="sharkrite-managed-stash"

# Convenience: stash tag with surrounding brackets (the full search string)
readonly RITE_MARKER_STASH_TAG="[${RITE_MARKER_STASH}]"

# =============================================================================
# ALLOWLIST — used by the lint rule (Rule 13: LITERAL_MARKER_STRING)
# Any sharkrite-[a-z-]+ literal NOT in this file triggers a violation.
# =============================================================================
# The lint rule enforces that the only place sharkrite-* strings may appear as
# literals is this file itself.  All other files must use the constants above.
