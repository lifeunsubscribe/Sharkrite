#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/core/assess-review-issues.sh
#
# Runbook conformance tests for follow-up issue body builders (issue #909).
#
# Both assess-and-resolve.sh (per-finding loop) and assess-review-issues.sh
# (ACTIONABLE_LATER loop) build follow-up issue bodies inline. This suite pins
# the structural contract: every required runbook section must be present in
# the generated body, and shared helper functions must produce consistent output
# across both paths.
#
# Tests:
#   1. _resolve_time_estimate: Fix Effort strings → Fibonacci estimates
#   2. _resolve_time_estimate: empty/unknown effort → empty string (caller provides default)
#   3. assess-and-resolve.sh body builder: all required runbook sections present
#   4. assess-and-resolve.sh Claude Context: Files to Read / Files to Modify split
#   5. assess-and-resolve.sh Time Estimate: present and mapped from Fix Effort
#   6. assess-and-resolve.sh: old 'Files to read before starting:' format is gone
#   7. assess-review-issues.sh: awk extractor emits Fix Effort line
#   8. assess-review-issues.sh body builder: all required runbook sections present (structural)
#   9. assess-review-issues.sh Claude Context: Files to Read / Files to Modify split (structural)
#  10. assess-review-issues.sh Time Estimate: section emitted (structural)

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

# ─── Tests 1-2: _resolve_time_estimate unit tests ─────────────────────────────

@test "_resolve_time_estimate: Fix Effort '<10min' maps to '30min'" {
  # Source only the function definitions (no program body) from assess-and-resolve.sh.
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail  # restore bats error handling after strict-mode source

  run _resolve_time_estimate "<10min"
  [ "$status" -eq 0 ] || { echo "FAIL: _resolve_time_estimate exited $status"; false; }
  [ "$output" = "30min" ] || {
    echo "FAIL: expected '30min', got '$output'"
    false
  }
}

@test "_resolve_time_estimate: Fix Effort '<1hr' maps to '1hr'" {
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail

  run _resolve_time_estimate "<1hr"
  [ "$status" -eq 0 ]
  [ "$output" = "1hr" ] || {
    echo "FAIL: expected '1hr', got '$output'"
    false
  }
}

@test "_resolve_time_estimate: Fix Effort '>1hr' maps to '2hr'" {
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail

  run _resolve_time_estimate ">1hr"
  [ "$status" -eq 0 ]
  [ "$output" = "2hr" ] || {
    echo "FAIL: expected '2hr', got '$output'"
    false
  }
}

@test "_resolve_time_estimate: empty effort → empty string (caller supplies default '30min')" {
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$ASSESS_RESOLVE_SCRIPT"
  set +u; set +o pipefail

  run _resolve_time_estimate ""
  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "FAIL: expected empty string for unknown effort, got '$output'"
    false
  }
}

# ─── Tests 3-6: assess-and-resolve.sh body builder structural pins ─────────────
#
# Structural: assert that the source text of the builder contains the required
# section headers. The builder is a shell heredoc that lives in a function body —
# exercise the real per-finding loop text via a grep on the source file.
# (Behavioral coverage lives in assess-review-issues-richbody-followup.bats and
#  in the integration suite; these pins catch section removal during refactors.)

@test "assess-and-resolve.sh body builder: all required runbook sections present in source" {
  for _section in \
    '## Description' \
    '## Time Estimate' \
    '## Claude Context' \
    '## Acceptance Criteria' \
    '## Verification Commands' \
    '## Done Definition' \
    '## Scope Boundary' \
    '**Dependencies**'; do
    grep -qF "$_section" "$ASSESS_RESOLVE_SCRIPT" || {
      echo "FAIL: '$_section' not found in $ASSESS_RESOLVE_SCRIPT"
      false
    }
  done
}

@test "assess-and-resolve.sh Claude Context: 'Files to Read:' present in body builder" {
  grep -qF 'Files to Read:' "$ASSESS_RESOLVE_SCRIPT" || {
    echo "FAIL: 'Files to Read:' not found in $ASSESS_RESOLVE_SCRIPT"
    false
  }
}

@test "assess-and-resolve.sh Claude Context: 'Files to Modify:' present in body builder" {
  grep -qF 'Files to Modify:' "$ASSESS_RESOLVE_SCRIPT" || {
    echo "FAIL: 'Files to Modify:' not found in $ASSESS_RESOLVE_SCRIPT"
    false
  }
}

@test "assess-and-resolve.sh: old 'Files to read before starting:' format removed" {
  run grep -F 'Files to read before starting:' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: old 'Files to read before starting:' still present — must use split format"
    echo "$output"
    false
  }
}

@test "assess-and-resolve.sh Time Estimate: uses _resolve_time_estimate helper" {
  # The shared helper must be called, not inline-cased, so both paths stay in sync.
  grep -qF '_resolve_time_estimate' "$ASSESS_RESOLVE_SCRIPT" || {
    echo "FAIL: _resolve_time_estimate not called in $ASSESS_RESOLVE_SCRIPT"
    false
  }
}

# ─── Tests 7-10: assess-review-issues.sh structural pins ─────────────────────

@test "assess-review-issues.sh awk extractor: emits Fix Effort lines to the parser" {
  grep -qF '**Fix Effort:**' "$ASSESS_REVIEW_SCRIPT" || {
    echo "FAIL: Fix Effort not extracted in awk block of $ASSESS_REVIEW_SCRIPT"
    false
  }
}

@test "assess-review-issues.sh body builder: all required runbook sections present in source" {
  for _section in \
    '## Description' \
    '## Time Estimate' \
    '## Claude Context' \
    '## Acceptance Criteria' \
    '## Verification Commands' \
    '## Done Definition' \
    '## Scope Boundary' \
    '**Dependencies**'; do
    grep -qF "$_section" "$ASSESS_REVIEW_SCRIPT" || {
      echo "FAIL: '$_section' not found in $ASSESS_REVIEW_SCRIPT"
      false
    }
  done
}

@test "assess-review-issues.sh Claude Context: 'Files to Read:' / 'Files to Modify:' split present" {
  grep -qF 'Files to Read:' "$ASSESS_REVIEW_SCRIPT" || {
    echo "FAIL: 'Files to Read:' not found in $ASSESS_REVIEW_SCRIPT"
    false
  }
  grep -qF 'Files to Modify:' "$ASSESS_REVIEW_SCRIPT" || {
    echo "FAIL: 'Files to Modify:' not found in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

@test "assess-review-issues.sh: old 'Files to read before starting:' format removed" {
  run grep -F 'Files to read before starting:' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: old 'Files to read before starting:' still present — must use split format"
    echo "$output"
    false
  }
}

@test "assess-review-issues.sh Time Estimate: uses _resolve_time_estimate helper" {
  grep -qF '_resolve_time_estimate' "$ASSESS_REVIEW_SCRIPT" || {
    echo "FAIL: _resolve_time_estimate not called in $ASSESS_REVIEW_SCRIPT"
    false
  }
}

# ─── Tests 11-14: dep-guard-visible Dependencies format (issue #954) ──────────
#
# The batch dep-guard greps ^(\*\*)?Dependencies(\*\*)?\s*: to find dependencies.
# A "## Dependencies" markdown header is NOT matched by this pattern (no colon),
# so any After: #N on a continuation line is invisible to the guard — the batch
# runner may process a follow-up before its parent (ordering defect).
#
# These pins enforce that both builders use the labeled format **Dependencies**:
# (detected by the guard) and have removed the invisible ## Dependencies header.

@test "assess-and-resolve.sh: follow-up body uses dep-guard-visible '**Dependencies**:' format" {
  # The issue body heredoc must contain the bold-label format so the batch
  # dep-guard (^(\*\*)?Dependencies(\*\*)?\s*:) can detect the dependency edge.
  grep -qF '**Dependencies**: After:' "$ASSESS_RESOLVE_SCRIPT" || {
    echo "FAIL: '**Dependencies**: After:' not found in $ASSESS_RESOLVE_SCRIPT"
    echo "Follow-up bodies must use the bold-label format so the batch dep-guard"
    echo "can detect 'After: #N' dependency edges (issue #954)."
    false
  }
}

@test "assess-and-resolve.sh: follow-up body does NOT use invisible '## Dependencies' markdown header" {
  # A bare '## Dependencies' header in the issue body heredoc is NOT detected by
  # the batch dep-guard grep, making the After: #N dependency invisible to ordering.
  # The builder must use '**Dependencies**: After: #N' on a single line instead.
  run grep -F '## Dependencies' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: '## Dependencies' markdown header still present in $ASSESS_RESOLVE_SCRIPT"
    echo "The batch dep-guard cannot detect this format — use '**Dependencies**: After: #N' instead."
    echo "$output"
    false
  }
}

@test "assess-review-issues.sh: follow-up body uses dep-guard-visible '**Dependencies**:' format" {
  # Same constraint as assess-and-resolve.sh — the ACTIONABLE_LATER path must also
  # emit the labeled format so the batch dep-guard detects the After: #N edge.
  grep -qF '**Dependencies**: After:' "$ASSESS_REVIEW_SCRIPT" || {
    echo "FAIL: '**Dependencies**: After:' not found in $ASSESS_REVIEW_SCRIPT"
    echo "Follow-up bodies must use the bold-label format so the batch dep-guard"
    echo "can detect 'After: #N' dependency edges (issue #954)."
    false
  }
}

@test "assess-review-issues.sh: follow-up body does NOT use invisible '## Dependencies' markdown header" {
  # A bare '## Dependencies' header in the issue body heredoc is NOT detected by
  # the batch dep-guard grep, making the After: #N dependency invisible to ordering.
  run grep -F '## Dependencies' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "FAIL: '## Dependencies' markdown header still present in $ASSESS_REVIEW_SCRIPT"
    echo "The batch dep-guard cannot detect this format — use '**Dependencies**: After: #N' instead."
    echo "$output"
    false
  }
}
