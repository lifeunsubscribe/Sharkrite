#!/bin/bash
# lib/utils/markers.sh
# Canonical constants for all sharkrite-* HTML comment markers.
#
# WHY: The same marker strings (e.g. "sharkrite-local-review") appeared as
# literals in ~20 files. Renaming any marker would require a codebase-wide
# search/replace with silent breakage risk. This file is the single source of
# truth. All reads and writes of a marker MUST use these constants.
#
# USAGE IN JQ FILTERS: jq filter strings are passed as bash variables so that
# bash expands the constants before jq sees the string:
#
#   _jq_filter="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))]"
#   gh_safe pr view "$PR_NUMBER" --json comments --jq "$_jq_filter"
#
# LINT: Rule 19 in tools/sharkrite-lint.sh rejects any sharkrite-[a-z] literal
# outside this file and test/fixture files.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f rite_markers_loaded >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Sentinel function — its presence is the idempotency signal used by the guard above.
rite_markers_loaded() { return 0; }

# ---------------------------------------------------------------------------
# Core workflow markers (embedded in GitHub PR/issue comment bodies)
# ---------------------------------------------------------------------------

# Review comment marker — sharkrite posts code reviews under this marker.
# Format in comment: <!-- sharkrite-local-review model:NAME timestamp:ISO -->
RITE_MARKER_REVIEW="sharkrite-local-review"

# Assessment comment marker — assessment results are posted under this marker.
# Format in comment: <!-- sharkrite-assessment -->
RITE_MARKER_ASSESSMENT="sharkrite-assessment"

# Follow-up issue link marker — posted as PR comment after creating a tech-debt issue.
# Format in comment: <!-- sharkrite-followup-issue:N -->
RITE_MARKER_FOLLOWUP="sharkrite-followup-issue"

# Parent PR reference marker — embedded in follow-up issue body to link back to the PR.
# Format in issue body: <!-- sharkrite-parent-pr:N -->
RITE_MARKER_PARENT_PR="sharkrite-parent-pr"

# Source issue reference marker — embedded in follow-up issue body to link back to origin issue.
# Format in issue body: <!-- sharkrite-source-issue:N -->
RITE_MARKER_SOURCE_ISSUE="sharkrite-source-issue"

# Structured review data marker — wraps the JSON block embedded in review comments.
# Format in comment: <!-- sharkrite-review-data ... -->
RITE_MARKER_REVIEW_DATA="sharkrite-review-data"

# ---------------------------------------------------------------------------
# PR description markers
# ---------------------------------------------------------------------------

# Scope warning marker — injected into PR body when files outside scope are modified.
# Format in PR body: <!-- sharkrite-scope-warning -->
RITE_MARKER_SCOPE_WARNING="sharkrite-scope-warning"

# Changes summary section markers — bracket the auto-generated diff summary in the PR description.
# Format: <!-- sharkrite-changes-summary --> ... <!-- /sharkrite-changes-summary -->
RITE_MARKER_CHANGES_SUMMARY="sharkrite-changes-summary"

# ---------------------------------------------------------------------------
# Git stash marker
# ---------------------------------------------------------------------------

# Stash message tag — all sharkrite-created git stashes include this tag.
# Format in stash message: [sharkrite-managed-stash]
RITE_MARKER_STASH="sharkrite-managed-stash"

# ---------------------------------------------------------------------------
# Auto-resolution marker
# ---------------------------------------------------------------------------

# Injected into the close comment when an issue auto-resolves (all checks pass on main).
# Format in close comment: <!-- sharkrite-auto-resolved -->
RITE_MARKER_AUTO_RESOLVED="sharkrite-auto-resolved"
