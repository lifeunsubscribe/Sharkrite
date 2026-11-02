#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/markers.sh, lib/core/assess-review-issues.sh, lib/core/assess-and-resolve.sh
# Regression tests for finding provenance markers in follow-up issue bodies (#1547).
#
# Verifies:
#   1. RITE_MARKER_FINDING_LOCATION and RITE_MARKER_FINDING_SHA defined in markers.sh
#   2. assess-review-issues.sh embeds both markers near the parent-pr marker
#   3. assess-and-resolve.sh embeds both markers near the parent-pr marker
#   4. Both sites guard against empty location (bare-prefix guard contract)
#   5. Behavioral: body with location → both markers present with correct values
#   6. Behavioral: body without location → location marker absent, sha present
#   7. Behavioral: body without sha (git unavailable) → sha marker absent

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export RITE_REPO_ROOT
  export MARKERS_SCRIPT="${RITE_REPO_ROOT}/lib/utils/markers.sh"
  export ASSESS_REVIEW_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"
  export ASSESS_RESOLVE_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ─── 1. Marker definitions in markers.sh ──────────────────────────────────────

@test "markers.sh: RITE_MARKER_FINDING_LOCATION is defined" {
  run grep -n 'RITE_MARKER_FINDING_LOCATION=' "$MARKERS_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: RITE_MARKER_FINDING_LOCATION not defined in $MARKERS_SCRIPT"
    false
  }
  [[ "$output" == *"sharkrite-finding-location"* ]] || {
    echo "FAIL: expected value 'sharkrite-finding-location' not found"
    echo "Got: $output"
    false
  }
}

@test "markers.sh: RITE_MARKER_FINDING_SHA is defined" {
  run grep -n 'RITE_MARKER_FINDING_SHA=' "$MARKERS_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: RITE_MARKER_FINDING_SHA not defined in $MARKERS_SCRIPT"
    false
  }
  [[ "$output" == *"sharkrite-finding-sha"* ]] || {
    echo "FAIL: expected value 'sharkrite-finding-sha' not found"
    echo "Got: $output"
    false
  }
}

# ─── 2. assess-review-issues.sh embeds both markers ──────────────────────────

@test "assess-review-issues.sh: embeds RITE_MARKER_FINDING_LOCATION in follow-up body" {
  run grep -n 'RITE_MARKER_FINDING_LOCATION' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: RITE_MARKER_FINDING_LOCATION not referenced in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

@test "assess-review-issues.sh: embeds RITE_MARKER_FINDING_SHA in follow-up body" {
  run grep -n 'RITE_MARKER_FINDING_SHA' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: RITE_MARKER_FINDING_SHA not referenced in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── 3. assess-and-resolve.sh embeds both markers ────────────────────────────

@test "assess-and-resolve.sh: embeds RITE_MARKER_FINDING_LOCATION in follow-up body" {
  run grep -n 'RITE_MARKER_FINDING_LOCATION' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: RITE_MARKER_FINDING_LOCATION not referenced in $ASSESS_RESOLVE_SCRIPT"
    false
  }
}

@test "assess-and-resolve.sh: embeds RITE_MARKER_FINDING_SHA in follow-up body" {
  run grep -n 'RITE_MARKER_FINDING_SHA' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: RITE_MARKER_FINDING_SHA not referenced in $ASSESS_RESOLVE_SCRIPT"
    false
  }
}

# ─── 4. Empty-location guard at both creation sites ──────────────────────────

@test "assess-review-issues.sh: location marker gated on non-empty ITEM_LOCATION" {
  # The guard must test ITEM_LOCATION before emitting the location marker so
  # an assessment without a Location field never emits a bare-prefix marker.
  run grep -n 'ITEM_LOCATION' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ]

  # Verify the guard form: the line setting _finding_location_marker must
  # require a non-empty ITEM_LOCATION before interpolating the marker value.
  run grep -n '_finding_location_marker.*RITE_MARKER_FINDING_LOCATION' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: _finding_location_marker assignment not found in $ASSESS_REVIEW_SCRIPT"
    false
  }
  # The assignment must be guarded (conditional: -n or [ ]), not unconditional.
  run grep -nE '(\[ -n.*ITEM_LOCATION|\-n.*ITEM_LOCATION).*_finding_location_marker' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: guard '[ -n \${ITEM_LOCATION:-} ]' not found before location marker assignment"
    false
  }
}

@test "assess-and-resolve.sh: location marker gated on non-empty _f_location" {
  run grep -n '_finding_location_marker.*RITE_MARKER_FINDING_LOCATION' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: _finding_location_marker assignment not found in $ASSESS_RESOLVE_SCRIPT"
    false
  }
  run grep -nE '(\[ -n.*_f_location|\-n.*_f_location).*_finding_location_marker' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: guard '[ -n \${_f_location:-} ]' not found before location marker assignment"
    false
  }
}

# ─── 5-7. Behavioral: inline guard logic ─────────────────────────────────────
# These tests replicate the exact guard logic from both creation sites to verify
# the empty/non-empty behavior without running the full scripts.

@test "behavioral: with location and sha — both markers appear in body" {
  RITE_MARKER_FINDING_LOCATION="sharkrite-finding-location"
  RITE_MARKER_FINDING_SHA="sharkrite-finding-sha"
  RITE_MARKER_PARENT_PR="sharkrite-parent-pr"
  RITE_MARKER_SOURCE_ISSUE="sharkrite-source-issue"

  ITEM_LOCATION="lib/core/foo.sh:42"
  _assessment_head_sha="abc1234"
  PR_NUMBER="99"
  SOURCE_ISSUE_MARKER="<!-- ${RITE_MARKER_SOURCE_ISSUE}:10 -->"

  # Exact logic from assess-review-issues.sh body builder
  _finding_location_marker=""
  [ -n "${ITEM_LOCATION:-}" ] && _finding_location_marker="<!-- ${RITE_MARKER_FINDING_LOCATION}:${ITEM_LOCATION} -->"
  _finding_sha_marker=""
  [ -n "${_assessment_head_sha:-}" ] && _finding_sha_marker="<!-- ${RITE_MARKER_FINDING_SHA}:${_assessment_head_sha} -->"
  ISSUE_BODY="${SOURCE_ISSUE_MARKER}<!-- ${RITE_MARKER_PARENT_PR}:${PR_NUMBER} -->${_finding_location_marker}${_finding_sha_marker}"

  [[ "$ISSUE_BODY" == *"<!-- sharkrite-finding-location:lib/core/foo.sh:42 -->"* ]] || {
    echo "FAIL: location marker not found in body"
    echo "Body: $ISSUE_BODY"
    false
  }
  [[ "$ISSUE_BODY" == *"<!-- sharkrite-finding-sha:abc1234 -->"* ]] || {
    echo "FAIL: sha marker not found in body"
    echo "Body: $ISSUE_BODY"
    false
  }
}

@test "behavioral: without location — location marker absent, sha marker present" {
  RITE_MARKER_FINDING_LOCATION="sharkrite-finding-location"
  RITE_MARKER_FINDING_SHA="sharkrite-finding-sha"
  RITE_MARKER_PARENT_PR="sharkrite-parent-pr"
  RITE_MARKER_SOURCE_ISSUE="sharkrite-source-issue"

  # No location field (assessment omitted it)
  ITEM_LOCATION=""
  _assessment_head_sha="def5678"
  PR_NUMBER="99"
  SOURCE_ISSUE_MARKER="<!-- ${RITE_MARKER_SOURCE_ISSUE}:10 -->"

  # Exact logic from assess-review-issues.sh body builder
  _finding_location_marker=""
  [ -n "${ITEM_LOCATION:-}" ] && _finding_location_marker="<!-- ${RITE_MARKER_FINDING_LOCATION}:${ITEM_LOCATION} -->"
  _finding_sha_marker=""
  [ -n "${_assessment_head_sha:-}" ] && _finding_sha_marker="<!-- ${RITE_MARKER_FINDING_SHA}:${_assessment_head_sha} -->"
  ISSUE_BODY="${SOURCE_ISSUE_MARKER}<!-- ${RITE_MARKER_PARENT_PR}:${PR_NUMBER} -->${_finding_location_marker}${_finding_sha_marker}"

  # Location marker must be absent entirely (bare-prefix guard)
  [[ "$ISSUE_BODY" != *"sharkrite-finding-location"* ]] || {
    echo "FAIL: location marker present when ITEM_LOCATION is empty"
    echo "Body: $ISSUE_BODY"
    false
  }
  # SHA marker must still be present
  [[ "$ISSUE_BODY" == *"<!-- sharkrite-finding-sha:def5678 -->"* ]] || {
    echo "FAIL: sha marker absent even when sha is available"
    echo "Body: $ISSUE_BODY"
    false
  }
}

@test "behavioral: without sha (git unavailable) — sha marker absent" {
  RITE_MARKER_FINDING_LOCATION="sharkrite-finding-location"
  RITE_MARKER_FINDING_SHA="sharkrite-finding-sha"
  RITE_MARKER_PARENT_PR="sharkrite-parent-pr"
  RITE_MARKER_SOURCE_ISSUE="sharkrite-source-issue"

  ITEM_LOCATION="lib/utils/bar.sh:10"
  _assessment_head_sha=""  # git failed — empty
  PR_NUMBER="99"
  SOURCE_ISSUE_MARKER="<!-- ${RITE_MARKER_SOURCE_ISSUE}:10 -->"

  # Exact logic from assess-review-issues.sh body builder
  _finding_location_marker=""
  [ -n "${ITEM_LOCATION:-}" ] && _finding_location_marker="<!-- ${RITE_MARKER_FINDING_LOCATION}:${ITEM_LOCATION} -->"
  _finding_sha_marker=""
  [ -n "${_assessment_head_sha:-}" ] && _finding_sha_marker="<!-- ${RITE_MARKER_FINDING_SHA}:${_assessment_head_sha} -->"
  ISSUE_BODY="${SOURCE_ISSUE_MARKER}<!-- ${RITE_MARKER_PARENT_PR}:${PR_NUMBER} -->${_finding_location_marker}${_finding_sha_marker}"

  # SHA marker must be absent when sha is empty
  [[ "$ISSUE_BODY" != *"sharkrite-finding-sha"* ]] || {
    echo "FAIL: sha marker emitted with empty value"
    echo "Body: $ISSUE_BODY"
    false
  }
  # Location marker must still be present
  [[ "$ISSUE_BODY" == *"<!-- sharkrite-finding-location:lib/utils/bar.sh:10 -->"* ]] || {
    echo "FAIL: location marker absent when location is available"
    echo "Body: $ISSUE_BODY"
    false
  }
}

# ─── assess-and-resolve.sh path also exercises correct variable names ─────────

@test "behavioral (assess-and-resolve path): with _f_location and sha — both markers present" {
  RITE_MARKER_FINDING_LOCATION="sharkrite-finding-location"
  RITE_MARKER_FINDING_SHA="sharkrite-finding-sha"
  RITE_MARKER_PARENT_PR="sharkrite-parent-pr"
  RITE_MARKER_SOURCE_ISSUE="sharkrite-source-issue"

  _f_location="lib/core/assess-and-resolve.sh:2505"
  _assessment_head_sha="fa987bc"
  PR_NUMBER="200"
  SOURCE_ISSUE_MARKER="<!-- ${RITE_MARKER_SOURCE_ISSUE}:50 -->"

  # Exact logic from assess-and-resolve.sh body builder
  _finding_location_marker=""
  [ -n "${_f_location:-}" ] && _finding_location_marker="<!-- ${RITE_MARKER_FINDING_LOCATION}:${_f_location} -->"
  _finding_sha_marker=""
  [ -n "${_assessment_head_sha:-}" ] && _finding_sha_marker="<!-- ${RITE_MARKER_FINDING_SHA}:${_assessment_head_sha} -->"
  FOLLOWUP_BODY="${SOURCE_ISSUE_MARKER}<!-- ${RITE_MARKER_PARENT_PR}:${PR_NUMBER} -->${_finding_location_marker}${_finding_sha_marker}"

  [[ "$FOLLOWUP_BODY" == *"<!-- sharkrite-finding-location:lib/core/assess-and-resolve.sh:2505 -->"* ]] || {
    echo "FAIL: location marker not found in assess-and-resolve path body"
    echo "Body: $FOLLOWUP_BODY"
    false
  }
  [[ "$FOLLOWUP_BODY" == *"<!-- sharkrite-finding-sha:fa987bc -->"* ]] || {
    echo "FAIL: sha marker not found in assess-and-resolve path body"
    echo "Body: $FOLLOWUP_BODY"
    false
  }
}
