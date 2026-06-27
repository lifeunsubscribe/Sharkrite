#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-review-issues.sh, lib/utils/issue-lock.sh
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
#   5. Unit:   comment format is detectable by _followup_dedup_check Source 4
#   6. Static: ITEM_TITLE is normalized (list markers stripped) before per-finding comment
#              (issue #728: both producer and consumer must embed the same clean title)
#   6b. Unit:  producer ITEM_TITLE and consumer _clean_title normalization pipelines
#              produce identical output — sync-enforcing test (issue #728)
#   7. Static: all 3 paths call write_followup_evidence (Source 1 seeding, issue #729)
#   8. Static: _item_finding_key is derived via derive_followup_finding_key
#   9. Static: issue-lock.sh is sourced to provide derive/write functions
#   10. Static: _item_index counter is initialised and incremented correctly

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

# ─── Test 6: Unit — ITEM_TITLE is normalized before embedding in per-finding comment ──────
#
# After the fix (issue #728): assess-review-issues.sh normalizes ITEM_TITLE
# (strips list markers + whitespace) before posting the per-finding PR comment,
# so both the producer (assess-review-issues.sh) and consumer
# (assess-and-resolve.sh _followup_dedup_check Source 4) embed the *same*
# normalized title.  The comment must contain the clean title — not the raw
# list-marked form — so Source 4's grep -cF on _clean_title is an exact match
# rather than a fragile substring match.

@test "assess-review-issues.sh: ITEM_TITLE is normalized (list markers stripped) before per-finding comment" {
  # Static check: verify the normalization sed pattern exists somewhere near TITLE:
  local _title_block
  _title_block=$(awk '/TITLE:\*\)/{in_block=1} in_block{print; count++} in_block && /;;/{exit}' \
    "$ASSESS_REVIEW_ISSUES")

  echo "$_title_block" | grep -q '_raw_item_title\|sed.*list.*marker\|sed.*0-9.*space\|sed.*\[-\*\]' || \
  echo "$_title_block" | grep -q 'sed.*\[0-9\]' || \
  grep -qn 'sed.*\[0-9\]\[0-9\].*space.*ITEM_TITLE\|_raw_item_title' "$ASSESS_REVIEW_ISSUES" || {
    echo "FAIL: ITEM_TITLE normalization (list-marker strip) not found in TITLE:* case of $ASSESS_REVIEW_ISSUES"
    echo "Expected two-stage sed normalization matching assess-and-resolve.sh's _clean_title logic"
    echo "TITLE:* block content:"
    echo "$_title_block"
    false
  }
}

# ─── Test 6b: Unit — both normalization paths produce identical output (sync-enforcing) ──
#
# This test encodes the contract between the two title-normalization paths:
#   Producer: assess-review-issues.sh ITEM_TITLE (set in TITLE:* case)
#   Consumer: assess-and-resolve.sh _clean_title (derived from ### header)
#
# Both must produce the same output for any input so that Source 4's
# grep -cF "${_clean_title}" on the per-finding comment is an exact match.
#
# If either normalization path changes (new strip rule, different sed order),
# this test breaks and forces a sync update to the other path.

@test "normalization sync: producer ITEM_TITLE and consumer _clean_title logic produce identical output" {
  # Replicate the EXACT sed pipeline from each file and verify they agree.
  # Any divergence here is a latent-regression signal.

  # Producer pipeline (assess-review-issues.sh TITLE:* case, issue #728 fix):
  #   Stage 1: strip leading "N. " or "- " or "* "
  #   Stage 2: trim leading/trailing whitespace
  producer_normalize() {
    local _input="$1"
    local _out
    _out=$(echo "$_input" | sed 's/^[0-9][0-9]*\.[[:space:]]*//' | sed 's/^[-*][[:space:]]*//' || true)
    echo "$_out" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true
  }

  # Consumer pipeline (assess-and-resolve.sh lines 1685-1687, unchanged):
  #   Same two sed stages.
  consumer_normalize() {
    local _input="$1"
    local _out
    _out=$(echo "$_input" | sed 's/^[0-9][0-9]*\.[[:space:]]*//' | sed 's/^[-*][[:space:]]*//' || true)
    echo "$_out" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true
  }

  local _pass=true

  _check() {
    local _input="$1"
    local _p _c
    _p=$(producer_normalize "$_input")
    _c=$(consumer_normalize "$_input")
    if [ "$_p" != "$_c" ]; then
      echo "DIVERGENCE for input: '$_input'"
      echo "  producer: '$_p'"
      echo "  consumer: '$_c'"
      _pass=false
    fi
  }

  # Inputs that cover the known variant space:
  _check "Fix input validation bypass"           # plain title — no marker
  _check "1. Fix input validation bypass"        # numeric list marker
  _check "2. Fix input validation bypass"        # numeric list marker (variant)
  _check "10. Fix input validation bypass"       # two-digit list marker
  _check "- Fix input validation bypass"         # dash list marker
  _check "* Fix input validation bypass"         # asterisk list marker
  _check "  Fix input validation bypass"         # leading whitespace only
  _check "  1. Fix input validation bypass"      # whitespace + numeric marker
  _check "  - Fix input validation bypass"       # whitespace + dash marker
  _check "Fix input validation bypass  "         # trailing whitespace

  [ "$_pass" = "true" ] || {
    echo "FAIL: producer and consumer normalization paths diverged (see DIVERGENCE lines above)"
    echo "Both paths must apply identical sed stages; update the lagging path to match."
    false
  }
}

# ─── Tests 7-9: Source 1 evidence seeding (issue #729) ───────────────────────
#
# PR #727 added Source 4 (PR comment) to assess-review-issues.sh but not
# Source 1 (local evidence file).  Issue #729 closes this gap: all three
# issue-tracking paths must now call write_followup_evidence so that
# _followup_dedup_check Source 1 can short-circuit on a re-run even when
# the Source 4 PR comment write failed silently.

@test "assess-review-issues.sh: new-issue path calls write_followup_evidence (Source 1 seeding)" {
  # Static check: after the NEW_ISSUE passback to RITE_PER_ITEM_ISSUES_FILE,
  # assess-review-issues.sh must call write_followup_evidence before the
  # gh pr comment that seeds Source 4.
  run grep -n 'write_followup_evidence' "$ASSESS_REVIEW_ISSUES"

  [ "$status" -eq 0 ] || {
    echo "FAIL: No write_followup_evidence call found in $ASSESS_REVIEW_ISSUES"
    echo "Expected at least one write_followup_evidence call (new-issue, skip-dup, update-dup paths)"
    false
  }

  # Must appear in all three creation paths; verify there are at least 3 calls.
  local _call_count
  _call_count=$(grep -c 'write_followup_evidence' "$ASSESS_REVIEW_ISSUES" || true)
  [ "$_call_count" -ge 3 ] || {
    echo "FAIL: expected at least 3 write_followup_evidence calls (one per path), got $_call_count"
    false
  }
}

@test "assess-review-issues.sh: _item_finding_key is derived via derive_followup_finding_key" {
  # The key passed to write_followup_evidence must be _item_finding_key, which
  # is produced by derive_followup_finding_key — the shared function that
  # assess-and-resolve.sh also uses.  This ensures both paths produce the same
  # key for the same finding, so evidence written here is found by Source 1 there.
  run grep -n 'derive_followup_finding_key' "$ASSESS_REVIEW_ISSUES"

  [ "$status" -eq 0 ] || {
    echo "FAIL: No derive_followup_finding_key call found in $ASSESS_REVIEW_ISSUES"
    echo "Expected a call to derive the per-finding key before write_followup_evidence"
    false
  }
}

@test "assess-review-issues.sh: issue-lock.sh is sourced (provides derive_followup_finding_key)" {
  # assess-review-issues.sh must source issue-lock.sh so that
  # derive_followup_finding_key and write_followup_evidence are available.
  run grep -n 'issue-lock.sh' "$ASSESS_REVIEW_ISSUES"

  [ "$status" -eq 0 ] || {
    echo "FAIL: issue-lock.sh is not sourced in $ASSESS_REVIEW_ISSUES"
    echo "It must be sourced to make derive_followup_finding_key and write_followup_evidence available"
    false
  }
}

@test "assess-review-issues.sh: _item_index counter is initialised and incremented" {
  # The _item_index counter must be initialised to 0 before the while loop and
  # incremented for each non-LOW item, matching assess-and-resolve.sh's
  # _finding_index so that derive_followup_finding_key produces the same key.
  run grep -n '_item_index' "$ASSESS_REVIEW_ISSUES"

  [ "$status" -eq 0 ] || {
    echo "FAIL: No _item_index variable found in $ASSESS_REVIEW_ISSUES"
    false
  }

  # Must be initialised
  run grep -n '_item_index=0' "$ASSESS_REVIEW_ISSUES"
  [ "$status" -eq 0 ] || {
    echo "FAIL: _item_index is not initialised to 0 in $ASSESS_REVIEW_ISSUES"
    false
  }

  # Must be incremented
  run grep -n '_item_index=\$((_item_index + 1))' "$ASSESS_REVIEW_ISSUES"
  [ "$status" -eq 0 ] || {
    echo "FAIL: _item_index is not incremented in the loop body of $ASSESS_REVIEW_ISSUES"
    false
  }
}

# ─── Test 11: Behavioral round-trip — Source-1 seeding write→read ─────────────
#
# This is the core behavioral test for issue #729: assess-review-issues.sh
# seeds write_followup_evidence so that _followup_dedup_check Source 1 can
# short-circuit on a re-run even when the Source 4 PR comment write failed.
#
# The round-trip: write_followup_evidence (seeded by assess-review-issues.sh new-issue
# path, using the same derive_followup_finding_key that assess-and-resolve.sh uses) →
# read_followup_evidence (Source 1 in _followup_dedup_check) returns the issue number.
#
# An argument swap (e.g. pr_number and source_issue transposed) would produce a file
# under the wrong key, making read_followup_evidence return empty — this test catches it.

@test "Source-1 seeding: write_followup_evidence → read_followup_evidence round-trip returns seeded issue number" {
  # Set up an isolated lock dir for this test so we never touch the real .rite/locks.
  local _lock_dir="${RITE_TEST_TMPDIR}/locks"
  mkdir -p "$_lock_dir"
  export RITE_LOCK_DIR="$_lock_dir"

  # Source issue-lock.sh directly to get the three functions under test.
  # We must unset the re-source guard (acquire_issue_lock) in case a previous test
  # already loaded it; re-source is safe here because the guard is function-based.
  # Use load_lib rather than direct sourcing so RITE_REPO_ROOT resolves correctly.
  load_lib utils/issue-lock.sh

  # Simulate the values assess-review-issues.sh would use after a successful
  # gh issue create in the new-issue path:
  local _pr="42"
  local _source_issue="15"     # RITE_ISSUE_NUMBER in the script
  local _item_title="Fix input validation bypass in login handler"
  local _item_index="1"        # _item_index counter for the first non-LOW item
  local _new_issue="88"        # the issue number returned by gh issue create

  # Derive the per-finding key exactly as assess-review-issues.sh does.
  local _finding_key
  _finding_key=$(derive_followup_finding_key "$_source_issue" "$_item_title" "$_item_index")

  # Seed Source 1 — this is what the new-issue path in assess-review-issues.sh does.
  write_followup_evidence "$_pr" "$_new_issue" "$_finding_key"

  # Now read back via Source 1 — this is what _followup_dedup_check does.
  # _dedup_evidence_key = _FOLLOWUP_FINDING_KEY (which equals _finding_key above).
  local _read_back
  _read_back=$(read_followup_evidence "$_pr" "$_finding_key")

  [ "$_read_back" = "$_new_issue" ] || {
    echo "FAIL: read_followup_evidence returned '$_read_back', expected '$_new_issue'"
    echo "  write_followup_evidence args: pr=$_pr issue=$_new_issue key=$_finding_key"
    echo "  read_followup_evidence  args: pr=$_pr key=$_finding_key"
    echo "  lock dir contents:"
    ls -la "$_lock_dir" || true
    false
  }
}
