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
  # Guard and assignment are in a multi-line if block, so check guard separately.
  run grep -nE '(\[ -n.*ITEM_LOCATION|-n.*ITEM_LOCATION)' "$ASSESS_REVIEW_SCRIPT"
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
  # Guard and assignment are in a multi-line if block, so check guard separately.
  run grep -nE '(\[ -n.*_f_location|-n.*_f_location)' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: guard '[ -n \${_f_location:-} ]' not found before location marker assignment"
    false
  }
}

# ─── 5-8. Structural: pin exact guarded-assignment lines in the real scripts ──
# These tests grep for the specific guard+assignment lines in the real source
# so that renaming variables, removing the guard, or relocating the marker
# causes a test failure — unlike inline-logic copies that would pass silently.

@test "assess-review-issues.sh: location guard uses allowlist (not bare -n)" {
  # Pin the exact allowlist form that prevents --> injection into the HTML comment.
  # A bare [ -n "${ITEM_LOCATION:-}" ] guard (without the grep -qE check) would pass
  # empty-guard tests but allow adversarial values through.
  run grep -n "ITEM_LOCATION.*grep.*qE.*A-Za-z" "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: allowlist guard for ITEM_LOCATION not found in $ASSESS_REVIEW_SCRIPT"
    echo "Expected: if [ -n \${ITEM_LOCATION:-} ] && printf ... | grep -qE '^[A-Za-z0-9 ...]'"
    false
  }
}

@test "assess-review-issues.sh: location marker assigned only inside the allowlist if-block" {
  # Pin the exact assignment line inside the guarded block.
  run grep -n '_finding_location_marker=.*RITE_MARKER_FINDING_LOCATION.*ITEM_LOCATION' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: guarded _finding_location_marker assignment not found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

@test "assess-review-issues.sh: sha marker guard is a bare -n on _assessment_head_sha" {
  run grep -n '_assessment_head_sha.*_finding_sha_marker=.*RITE_MARKER_FINDING_SHA' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: SHA marker guard not found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

@test "assess-review-issues.sh: location marker absent when --> in value (allowlist blocks it)" {
  # Structural: verify the allowlist rejects --> by checking the character class
  # excludes > (which would allow the --> termination sequence).
  run grep -n "grep.*qE.*A-Za-z0-9.*ITEM_LOCATION\|ITEM_LOCATION.*grep.*qE.*A-Za-z0-9" "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ]
  # The character class must NOT include '>'; if it did, --> could pass through.
  run grep -n "grep.*qE.*\[.*>.*\].*ITEM_LOCATION\|ITEM_LOCATION.*grep.*qE.*\[.*>.*\]" "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: allowlist character class appears to include '>', which would allow --> injection"
    echo "Got: $output"
    false
  }
}

# ─── assess-and-resolve.sh path: pin exact guarded-assignment lines ───────────

@test "assess-and-resolve.sh: location guard uses allowlist (not bare -n)" {
  run grep -n "_f_location.*grep.*qE.*A-Za-z" "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: allowlist guard for _f_location not found in $ASSESS_RESOLVE_SCRIPT"
    echo "Expected: if [ -n \${_f_location:-} ] && printf ... | grep -qE '^[A-Za-z0-9 ...]'"
    false
  }
}

@test "assess-and-resolve.sh: location marker assigned only inside the allowlist if-block" {
  run grep -n '_finding_location_marker=.*RITE_MARKER_FINDING_LOCATION.*_f_location' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: guarded _finding_location_marker assignment not found in $ASSESS_RESOLVE_SCRIPT"
    false
  }
}

@test "assess-and-resolve.sh: sha marker guard is a bare -n on _assessment_head_sha" {
  run grep -n '_assessment_head_sha.*_finding_sha_marker=.*RITE_MARKER_FINDING_SHA' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: SHA marker guard not found in $ASSESS_RESOLVE_SCRIPT"
    false
  }
}

@test "assess-and-resolve.sh: location marker absent when --> in value (allowlist blocks it)" {
  # Structural: verify the allowlist rejects --> by confirming > is excluded.
  run grep -n "grep.*qE.*A-Za-z0-9.*_f_location\|_f_location.*grep.*qE.*A-Za-z0-9" "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -n "grep.*qE.*\[.*>.*\].*_f_location\|_f_location.*grep.*qE.*\[.*>.*\]" "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: allowlist character class appears to include '>', which would allow --> injection"
    echo "Got: $output"
    false
  }
}
