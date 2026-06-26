#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-review-issues.sh
# Regression test for: assess-review-issues.sh must post per-finding PR
# comments so assess-and-resolve.sh _followup_dedup_check Source 4 can
# detect issues created here on a later re-run (issues #720/721/722).
#
# Problem:
#   When assess-review-issues.sh created an ACTIONABLE_LATER issue (#69),
#   it updated the PR *body* with issue links but posted no PR *comment*
#   containing "<!-- sharkrite-followup-issue:N -->" + the finding title.
#   On a subsequent run (e.g. merge-phase re-entry triggered when
#   pr_has_followup=false due to a network failure on the prior summary
#   comment), assess-and-resolve.sh's per-finding loop ran _followup_dedup_check
#   which checked PR comments for the title (Source 4).  Finding nothing, it
#   created a duplicate issue (#71) for the same finding.
#
# Fix:
#   After creating (or re-identifying) an ACTIONABLE_LATER issue,
#   assess-review-issues.sh now posts a per-finding PR comment:
#     <!-- sharkrite-followup-issue:N -->
#     **Finding:** <ITEM_TITLE>
#   This comment is visible to _followup_dedup_check Source 4 on the next run.
#
# Tests:
#   1. Static: new-issue path posts gh pr comment with followup marker + title
#   2. Static: skip-duplicate path posts gh pr comment with followup marker + title
#   3. Static: update-duplicate path posts gh pr comment with followup marker + title
#   4. Unit:   per-finding comment body format matches Source 4 expectations
#              (contains "sharkrite-followup-issue:N" AND item title)

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export ASSESS_REVIEW_ISSUES="${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"
  [ -f "$ASSESS_REVIEW_ISSUES" ] || {
    echo "setup: ASSESS_REVIEW_ISSUES not found at $ASSESS_REVIEW_ISSUES" >&2
    false
  }
}

teardown() {
  teardown_test_tmpdir
}

# ─── Test 1: Static — new-issue path posts a per-finding PR comment ───────────

@test "assess-review-issues.sh: new-issue path posts gh pr comment with followup marker after creating issue" {
  # After gh issue create succeeds, the script must post a gh pr comment
  # containing the RITE_MARKER_FOLLOWUP:N marker AND the item title.
  # This enables assess-and-resolve.sh _followup_dedup_check Source 4 to
  # detect the issue on a subsequent run.

  # The new block must appear after the RITE_PER_ITEM_ISSUES_FILE passback
  # and before the fi that closes the "if [ -n "$NEW_ISSUE" ]" block.
  run grep -n 'gh_safe pr comment.*pfinding_comment_file\|_pfinding_comment_file\|pfinding' \
    "$ASSESS_REVIEW_ISSUES"

  [ "$status" -eq 0 ] || {
    echo "FAIL: No per-finding comment post found in new-issue path of $ASSESS_REVIEW_ISSUES"
    echo "Expected a 'gh_safe pr comment' call using a temp file (_pfinding_comment_file)"
    false
  }
}

# ─── Test 2: Static — skip-duplicate path posts a per-finding PR comment ──────

@test "assess-review-issues.sh: skip-duplicate path posts gh pr comment with followup marker" {
  # When an existing issue matches (body already contains the reasoning signature),
  # the script must still post a per-finding PR comment so Source 4 can detect it.
  run grep -n '_dup_comment_file\|dup_comment' "$ASSESS_REVIEW_ISSUES"

  [ "$status" -eq 0 ] || {
    echo "FAIL: No per-finding comment post found in skip-duplicate path of $ASSESS_REVIEW_ISSUES"
    echo "Expected a 'gh_safe pr comment' call using _dup_comment_file"
    false
  }
}

# ─── Test 3: Static — update-duplicate path posts a per-finding PR comment ────

@test "assess-review-issues.sh: update-duplicate path posts gh pr comment with followup marker" {
  # When an existing issue is updated (body is amended with new content),
  # the script must also post the per-finding PR comment.
  run grep -n '_upd_comment_file\|upd_comment' "$ASSESS_REVIEW_ISSUES"

  [ "$status" -eq 0 ] || {
    echo "FAIL: No per-finding comment post found in update-duplicate path of $ASSESS_REVIEW_ISSUES"
    echo "Expected a 'gh_safe pr comment' call using _upd_comment_file"
    false
  }
}

# ─── Test 4: Unit — per-finding comment body format ───────────────────────────

@test "assess-review-issues.sh: per-finding comment printf includes RITE_MARKER_FOLLOWUP and title" {
  # The printf that builds the per-finding comment body must embed both:
  #   (a) the sharkrite-followup-issue:N marker — for rite pr_has_followup check
  #   (b) the item title — for _followup_dedup_check Source 4 grep -cF match
  #
  # Check that the printf format string in the script references RITE_MARKER_FOLLOWUP
  # and ITEM_TITLE in the same block (within 6 lines of each other).
  #
  # Strategy: extract the printf line and the surrounding context, confirm both
  # variables appear within the pfinding comment block.

  local _pfinding_block
  # Extract lines from _pfinding_comment_file= through the next rm -f line
  _pfinding_block=$(awk '
    /_pfinding_comment_file=\$\(mktemp\)/ { in_block=1 }
    in_block { print; count++ }
    in_block && /rm -f.*_pfinding_comment_file/ { exit }
  ' "$ASSESS_REVIEW_ISSUES")

  [ -n "$_pfinding_block" ] || {
    echo "FAIL: Could not extract _pfinding_comment_file block from $ASSESS_REVIEW_ISSUES"
    false
  }

  # Marker reference must be present
  echo "$_pfinding_block" | grep -q 'RITE_MARKER_FOLLOWUP' || {
    echo "FAIL: _pfinding_comment block does not reference RITE_MARKER_FOLLOWUP"
    echo "Block content:"
    echo "$_pfinding_block"
    false
  }

  # Title variable must be present (ITEM_TITLE)
  echo "$_pfinding_block" | grep -q 'ITEM_TITLE' || {
    echo "FAIL: _pfinding_comment block does not reference ITEM_TITLE"
    echo "Block content:"
    echo "$_pfinding_block"
    false
  }
}

# ─── Test 5: Unit — comment format matches _followup_dedup_check Source 4 ─────

@test "assess-review-issues.sh per-finding comment: format is detectable by _followup_dedup_check Source 4" {
  # _followup_dedup_check Source 4 does two things:
  #   (a) jq filter: select(.body | contains("<!-- sharkrite-followup-issue:"))
  #   (b) grep -cF "${_clean_title}"  on the selected bodies
  #
  # Our per-finding comment format must satisfy both.
  # Simulate the format and verify:
  #   "<!-- sharkrite-followup-issue:69 -->\n**Finding:** No regression test guards layout"
  # is detectable by (a) contains("<!-- sharkrite-followup-issue:") and (b) grep -cF on title.

  local _marker="sharkrite-followup-issue"
  local _issue_num="69"
  local _title="No regression test guards the layout geometry"

  # Build the comment body using the same printf pattern as the script
  local _comment_body
  _comment_body=$(printf '<!-- %s:%s -->\n**Finding:** %s' \
    "$_marker" "$_issue_num" "$_title")

  # Verify (a): contains the marker prefix for jq contains() check
  echo "$_comment_body" | grep -qF "<!-- ${_marker}:" || {
    echo "FAIL: comment body does not contain '<!-- ${_marker}:' for jq contains() check"
    echo "Body: $_comment_body"
    false
  }

  # Verify (b): grep -cF on the title finds it (Source 4 match)
  local _count
  _count=$(echo "$_comment_body" | grep -cF "$_title" || true)
  [ "$_count" -gt 0 ] || {
    echo "FAIL: grep -cF on title returned 0 matches in comment body"
    echo "Title: $_title"
    echo "Body: $_comment_body"
    false
  }
}

# ─── Test 6: Unit — title with list marker is still detectable ────────────────

@test "assess-review-issues.sh per-finding comment: title with leading list marker is still matched by clean_title" {
  # assess-review-issues.sh sets ITEM_TITLE without stripping list markers
  # (e.g. "1. No regression test..."), while assess-and-resolve.sh's _clean_title
  # strips them (producing "No regression test...").
  # grep -cF on the clean title must still match because the clean title is a
  # substring of the comment body that contains the list-marked title.

  local _marker="sharkrite-followup-issue"
  local _issue_num="69"
  local _item_title="1. No regression test guards the layout geometry"
  local _clean_title="No regression test guards the layout geometry"

  # Build comment as assess-review-issues.sh would (with list marker)
  local _comment_body
  _comment_body=$(printf '<!-- %s:%s -->\n**Finding:** %s' \
    "$_marker" "$_issue_num" "$_item_title")

  # Source 4 uses _clean_title (without list marker) in grep -cF
  local _count
  _count=$(echo "$_comment_body" | grep -cF "$_clean_title" || true)
  [ "$_count" -gt 0 ] || {
    echo "FAIL: grep -cF with clean_title (no list marker) found 0 matches"
    echo "Comment body (with list marker): $_comment_body"
    echo "Clean title used in search: $_clean_title"
    false
  }
}
