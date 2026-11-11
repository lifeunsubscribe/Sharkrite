#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/core/assess-review-issues.sh
#
# Regression tests for runbook-conformant follow-up body content (issue #1551).
#
# Both assess-and-resolve.sh (per-finding rollup) and assess-review-issues.sh
# (ACTIONABLE_LATER per-item) previously shipped placeholder strings in generated
# follow-up bodies: "Determine from the finding above" in Files to Modify, TODO
# comments in Verification Commands, and "explicitly deferred with justification"
# as the Done Definition fallback.
#
# After issue #1551 these are replaced with concrete content derived from the
# assessment's structured fields (Location, Suggested Fix, Verification from #1546).
#
# Tests:
#   1.  _resolve_done_def: MEDIUM/LOW fallback is now a bounded sentence
#   2.  _resolve_done_def: CRITICAL sentence unchanged (backward-compat)
#   3.  _resolve_done_def: HIGH sentence unchanged (backward-compat)
#   4.  Structural: 'TODO: add verification command' fallback present in both builders (location-less case)
#   5.  Structural: 'explicitly deferred with justification' absent
#   6.  Structural: 'Determine from the finding above' absent
#   7.  Structural: assess-and-resolve.sh embeds _f_suggested_fix in acceptance criterion
#   8.  Structural: assess-review-issues.sh embeds ITEM_SUGGESTED_FIX in acceptance criterion
#   9.  Structural: assess-and-resolve.sh Files to Modify seeded from _loc_path_safe
#  10.  Structural: assess-review-issues.sh Files to Modify seeded from _loc_path_safe
#  11.  Structural: backward-compat — explicit "not specified" note when location absent
#  12.  assess-and-resolve.sh acceptance criterion line no longer has trailing prose
#  13.  _resolve_done_def: accepts empty severity without crashing
#  14.  _resolve_location_path: file:line input sets _loc_path_safe and _loc_line
#  15.  _resolve_location_path: unsafe chars in path yield empty _loc_path_safe
#  16.  _resolve_location_path: empty input yields empty _loc_path_safe and _loc_line
#  17.  _resolve_location_path: plain file path (no line) sets _loc_path_safe with empty _loc_line
#  18.  Structural: _resolve_location_path defined in assess-and-resolve.sh (single source)

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export ASSESS_RESOLVE_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
  export ASSESS_REVIEW_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"

  [ -f "$ASSESS_RESOLVE_SCRIPT" ] || {
    echo "setup: ASSESS_RESOLVE_SCRIPT not found at $ASSESS_RESOLVE_SCRIPT" >&2
    false
  }
  [ -f "$ASSESS_REVIEW_SCRIPT" ] || {
    echo "setup: ASSESS_REVIEW_SCRIPT not found at $ASSESS_REVIEW_SCRIPT" >&2
    false
  }
}

teardown() {
  teardown_test_tmpdir
}

# ─── Tests 1-3: _resolve_done_def unit tests (behavioral) ─────────────────────

@test "_resolve_done_def: MEDIUM returns bounded sentence referencing acceptance criteria" {
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: assess-and-resolve.sh uses _RITE_ASSESS_AND_RESOLVE_LOADED env-var guard which is set after sourcing; no same-name function stubs defined before source here
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail

  run _resolve_done_def "MEDIUM"
  [ "$status" -eq 0 ]
  # Must reference "acceptance criteria" and not contain the old unbounded phrase
  [[ "$output" == *"acceptance criteria"* ]] || {
    echo "FAIL: MEDIUM done def should reference 'acceptance criteria', got: '$output'"
    false
  }
  [[ "$output" != *"explicitly deferred with justification"* ]] || {
    echo "FAIL: MEDIUM done def still contains 'explicitly deferred with justification'"
    false
  }
}

@test "_resolve_done_def: CRITICAL sentence is bounded (backward-compat)" {
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail

  run _resolve_done_def "CRITICAL"
  [ "$status" -eq 0 ]
  [ -n "$output" ] || { echo "FAIL: empty output for CRITICAL"; false; }
  [[ "$output" == *"CRITICAL"* ]] || {
    echo "FAIL: CRITICAL done def should reference severity, got: '$output'"
    false
  }
}

@test "_resolve_done_def: HIGH sentence is bounded (backward-compat)" {
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail

  run _resolve_done_def "HIGH"
  [ "$status" -eq 0 ]
  [ -n "$output" ] || { echo "FAIL: empty output for HIGH"; false; }
  [[ "$output" == *"HIGH"* ]] || {
    echo "FAIL: HIGH done def should reference severity, got: '$output'"
    false
  }
}

@test "_resolve_done_def: empty severity defaults gracefully (no crash)" {
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail

  run _resolve_done_def ""
  [ "$status" -eq 0 ]
  [ -n "$output" ] || { echo "FAIL: empty output for empty severity"; false; }
}

# ─── Tests 4-6: Placeholder string absence (structural) ───────────────────────

@test "lib/core/: 'TODO: add verification command' fallback present in both builders (location-less case)" {
  # The TODO placeholder is the correct fallback when Location is absent or unrecognized.
  # Asserting presence documents the contract: implementers see work-needed markers,
  # not silent omissions (per CLAUDE.md follow-up issue template).
  grep -q 'TODO: add verification command for this finding' "$ASSESS_RESOLVE_SCRIPT" || {
    echo "FAIL: location-less TODO fallback missing in $ASSESS_RESOLVE_SCRIPT"
    false
  }
  grep -q 'TODO: add verification command for this finding' "$ASSESS_REVIEW_SCRIPT" || {
    echo "FAIL: location-less TODO fallback missing in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

@test "lib/core/: 'explicitly deferred with justification' absent from both builders" {
  run grep -rn 'explicitly deferred with justification' \
    "$ASSESS_RESOLVE_SCRIPT" "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: 'explicitly deferred with justification' still present (runbook anti-example):"
    echo "$output"
    false
  }
}

@test "lib/core/: 'Determine from the finding above' placeholder absent from both builders" {
  run grep -rn 'Determine from the finding above' \
    "$ASSESS_RESOLVE_SCRIPT" "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: 'Determine from the finding above' still present:"
    echo "$output"
    false
  }
}

# ─── Tests 7-8: Suggested Fix embedded in acceptance criterion (structural) ───

@test "assess-and-resolve.sh: acceptance criterion block embeds _f_suggested_fix" {
  grep -qF '_f_suggested_fix' "$ASSESS_RESOLVE_SCRIPT" || {
    echo "FAIL: _f_suggested_fix not referenced in $ASSESS_RESOLVE_SCRIPT"
    false
  }
  # Verify it appears in the acceptance-criterion building block (not just in
  # the Description section where it always appeared).
  grep -qF '**Fix:** ${_f_suggested_fix}' "$ASSESS_RESOLVE_SCRIPT" || {
    echo "FAIL: acceptance criterion does not embed '**Fix:** \${_f_suggested_fix}' in $ASSESS_RESOLVE_SCRIPT"
    false
  }
}

@test "assess-review-issues.sh: acceptance criterion block embeds ITEM_SUGGESTED_FIX" {
  grep -qF 'ITEM_SUGGESTED_FIX' "$ASSESS_REVIEW_SCRIPT" || {
    echo "FAIL: ITEM_SUGGESTED_FIX not referenced in $ASSESS_REVIEW_SCRIPT"
    false
  }
  grep -qF '**Fix:** ${ITEM_SUGGESTED_FIX}' "$ASSESS_REVIEW_SCRIPT" || {
    echo "FAIL: acceptance criterion does not embed '**Fix:** \${ITEM_SUGGESTED_FIX}' in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Tests 9-11: Files to Modify seeded from location (structural) ────────────

@test "assess-and-resolve.sh: Files to Modify uses _loc_path_safe (location-seeded)" {
  grep -qF '_loc_path_safe' "$ASSESS_RESOLVE_SCRIPT" || {
    echo "FAIL: _loc_path_safe not referenced in $ASSESS_RESOLVE_SCRIPT"
    false
  }
  grep -qF '_files_to_modify' "$ASSESS_RESOLVE_SCRIPT" || {
    echo "FAIL: _files_to_modify not referenced in $ASSESS_RESOLVE_SCRIPT"
    false
  }
  # The _claude_context_section must reference _files_to_modify, not the placeholder
  grep -qF '${_files_to_modify}' "$ASSESS_RESOLVE_SCRIPT" || {
    echo "FAIL: _claude_context_section does not use '\${_files_to_modify}' in $ASSESS_RESOLVE_SCRIPT"
    false
  }
}

@test "assess-review-issues.sh: Files to Modify uses _loc_path_safe (location-seeded)" {
  grep -qF '_loc_path_safe' "$ASSESS_REVIEW_SCRIPT" || {
    echo "FAIL: _loc_path_safe not referenced in $ASSESS_REVIEW_SCRIPT"
    false
  }
  grep -qF '_files_to_modify' "$ASSESS_REVIEW_SCRIPT" || {
    echo "FAIL: _files_to_modify not referenced in $ASSESS_REVIEW_SCRIPT"
    false
  }
  grep -qF '${_files_to_modify}' "$ASSESS_REVIEW_SCRIPT" || {
    echo "FAIL: _claude_context_section does not use '\${_files_to_modify}' in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

@test "assess-and-resolve.sh: backward-compat — explicit 'not specified' note when location absent" {
  # When no Location field is present, Files to Modify must state so explicitly
  # rather than emitting an empty section or a placeholder.
  grep -qF '_Location not specified in assessment_' "$ASSESS_RESOLVE_SCRIPT" || {
    echo "FAIL: fallback 'not specified' note missing from $ASSESS_RESOLVE_SCRIPT"
    false
  }
}

@test "assess-review-issues.sh: backward-compat — explicit 'not specified' note when location absent" {
  grep -qF '_Location not specified in assessment_' "$ASSESS_REVIEW_SCRIPT" || {
    echo "FAIL: fallback 'not specified' note missing from $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 12: Acceptance criteria line no longer has trailing prose ───────────

@test "assess-and-resolve.sh: acceptance criteria body line has no trailing ': see Description' suffix" {
  run grep -F '${_acceptance_criterion}: see Description' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: trailing ': see Description above for details' still appended to acceptance criterion"
    echo "$output"
    false
  }
}

# ─── Tests 14-18: _resolve_location_path unit tests ──────────────────────────

@test "_resolve_location_path: file:line input sets _loc_path_safe and _loc_line" {
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: assess-and-resolve.sh uses _RITE_ASSESS_AND_RESOLVE_LOADED env-var guard; no same-name function stubs defined before source here
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail

  _resolve_location_path "lib/core/assess-and-resolve.sh:375"
  [ "$_loc_path_safe" = "lib/core/assess-and-resolve.sh" ] || {
    echo "FAIL: expected _loc_path_safe='lib/core/assess-and-resolve.sh', got '$_loc_path_safe'"
    false
  }
  [ "$_loc_line" = "375" ] || {
    echo "FAIL: expected _loc_line='375', got '$_loc_line'"
    false
  }
}

@test "_resolve_location_path: unsafe chars in path yield empty _loc_path_safe" {
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail

  _resolve_location_path "lib/core/evil'; rm -rf /:1"
  [ -z "$_loc_path_safe" ] || {
    echo "FAIL: unsafe path should yield empty _loc_path_safe, got '$_loc_path_safe'"
    false
  }
}

@test "_resolve_location_path: empty input yields empty _loc_path_safe and _loc_line" {
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail

  _resolve_location_path ""
  [ -z "$_loc_path_safe" ] || {
    echo "FAIL: empty input should yield empty _loc_path_safe, got '$_loc_path_safe'"
    false
  }
  [ -z "$_loc_line" ] || {
    echo "FAIL: empty input should yield empty _loc_line, got '$_loc_line'"
    false
  }
}

@test "_resolve_location_path: plain file path (no line number) sets _loc_path_safe with empty _loc_line" {
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail

  _resolve_location_path "lib/core/assess-and-resolve.sh"
  [ "$_loc_path_safe" = "lib/core/assess-and-resolve.sh" ] || {
    echo "FAIL: expected _loc_path_safe='lib/core/assess-and-resolve.sh', got '$_loc_path_safe'"
    false
  }
  [ -z "$_loc_line" ] || {
    echo "FAIL: plain path should yield empty _loc_line, got '$_loc_line'"
    false
  }
}

@test "_resolve_location_path: defined in assess-and-resolve.sh (single source of truth)" {
  grep -qF '_resolve_location_path()' "$ASSESS_RESOLVE_SCRIPT" || {
    echo "FAIL: _resolve_location_path not defined in $ASSESS_RESOLVE_SCRIPT"
    false
  }
  # Must NOT be defined in assess-review-issues.sh — that file calls the shared helper
  run grep -F '_resolve_location_path()' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: _resolve_location_path defined in $ASSESS_REVIEW_SCRIPT — it should only call the shared helper from assess-and-resolve.sh"
    echo "$output"
    false
  }
}
