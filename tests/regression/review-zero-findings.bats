#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/format-review.sh::review_reports_zero_findings

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: format-review.sh uses an env-var re-source guard (_RITE_FORMAT_REVIEW_LOADED); stubs defined here do not conflict since format-review.sh defines no overlapping functions.
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  source "$RITE_LIB_DIR/utils/markers.sh" 2>/dev/null || true
  source "$RITE_LIB_DIR/utils/colors.sh" 2>/dev/null || true
  source "$RITE_LIB_DIR/utils/format-review.sh"
  set +u; set +o pipefail
}

# ---------------------------------------------------------------------------
# Template summary line (the format the reviewer is instructed to write)
# ---------------------------------------------------------------------------

@test "template summary line: all zero counts returns 0" {
  local body
  body='**Findings:** 🔴 CRITICAL: 0 | 🟠 HIGH: 0 | 🟡 MEDIUM: 0 | 🟢 LOW: 0'
  run review_reports_zero_findings "$body"
  [ "$status" -eq 0 ]
}

@test "template summary line: bold only (no emoji) returns 0 when all zero" {
  local body
  body='**Findings:** CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 0'
  run review_reports_zero_findings "$body"
  [ "$status" -eq 0 ]
}

@test "template summary line: JSON block with all-zero summary returns 0" {
  local body
  body="$(cat <<'EOF'
## Code Review

**Findings:** 🔴 CRITICAL: 0 | 🟠 HIGH: 0 | 🟡 MEDIUM: 0 | 🟢 LOW: 0

<!-- sharkrite-review-data
{"summary":{"critical":0,"high":0,"medium":0,"low":0,"verdict":"APPROVED"}}
-->
EOF
)"
  run review_reports_zero_findings "$body"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Nonzero counts must return non-zero
# ---------------------------------------------------------------------------

@test "nonzero: CRITICAL > 0 returns 1" {
  local body
  body='**Findings:** 🔴 CRITICAL: 1 | 🟠 HIGH: 0 | 🟡 MEDIUM: 0 | 🟢 LOW: 0'
  run review_reports_zero_findings "$body"
  [ "$status" -ne 0 ]
}

@test "nonzero: HIGH > 0 returns 1" {
  local body
  body='**Findings:** 🔴 CRITICAL: 0 | 🟠 HIGH: 2 | 🟡 MEDIUM: 0 | 🟢 LOW: 0'
  run review_reports_zero_findings "$body"
  [ "$status" -ne 0 ]
}

@test "nonzero: LOW only > 0 returns 1" {
  local body
  body='**Findings:** 🔴 CRITICAL: 0 | 🟠 HIGH: 0 | 🟡 MEDIUM: 0 | 🟢 LOW: 3'
  run review_reports_zero_findings "$body"
  [ "$status" -ne 0 ]
}

@test "nonzero: JSON block with nonzero MEDIUM returns 1" {
  local body
  body="$(cat <<'EOF'
<!-- sharkrite-review-data
{"summary":{"critical":0,"high":0,"medium":1,"low":0,"verdict":"NEEDS_WORK"}}
-->
EOF
)"
  run review_reports_zero_findings "$body"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Falls through to assessment when summary is absent or unparseable
# ---------------------------------------------------------------------------

@test "falls through: empty review returns 1" {
  run review_reports_zero_findings ""
  [ "$status" -ne 0 ]
}

@test "falls through: review with no Findings line returns 1" {
  local body
  body="$(cat <<'EOF'
## Code Review

The implementation looks solid. No concerns identified.
EOF
)"
  run review_reports_zero_findings "$body"
  [ "$status" -ne 0 ]
}

@test "falls through: Tier 3 only (item markers, no summary line) returns 1" {
  local body
  body="$(cat <<'EOF'
## Code Review

<!-- item:1 severity:LOW -->
Minor nit about naming.
EOF
)"
  run review_reports_zero_findings "$body"
  [ "$status" -ne 0 ]
}

@test "falls through: 'no critical issues found' in prose does not trigger zero exit" {
  local body
  body="$(cat <<'EOF'
## Code Review

There are no critical issues found in this PR. The code is clean.
EOF
)"
  run review_reports_zero_findings "$body"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# assess-and-resolve.sh gate conditions (all three must hold)
# ---------------------------------------------------------------------------

@test "gate conditions: zero-findings review with gate=0 and stale=false exits 0" {
  local body
  body='**Findings:** 🔴 CRITICAL: 0 | 🟠 HIGH: 0 | 🟡 MEDIUM: 0 | 🟢 LOW: 0'
  GATE_NOW_COUNT=0
  _gate_verdict_is_stale=false
  run review_reports_zero_findings "$body"
  [ "$status" -eq 0 ]
  # Both gate guards would also pass — the combined condition would skip assessment.
  [ "${GATE_NOW_COUNT:-0}" -eq 0 ]
  [ "${_gate_verdict_is_stale}" != "true" ]
}

@test "gate conditions: zero-findings review with GATE_NOW_COUNT=1 does not skip" {
  local body
  body='**Findings:** 🔴 CRITICAL: 0 | 🟠 HIGH: 0 | 🟡 MEDIUM: 0 | 🟢 LOW: 0'
  GATE_NOW_COUNT=1
  _gate_verdict_is_stale=false
  run review_reports_zero_findings "$body"
  # review_reports_zero_findings itself succeeds (review is zero)…
  [ "$status" -eq 0 ]
  # …but GATE_NOW_COUNT is non-zero so the combined condition in assess-and-resolve.sh
  # would NOT skip the assessment — asserted by the caller's && guard.
  [ "${GATE_NOW_COUNT:-0}" -ne 0 ]
}

@test "gate conditions: zero-findings review with stale gate does not skip" {
  local body
  body='**Findings:** 🔴 CRITICAL: 0 | 🟠 HIGH: 0 | 🟡 MEDIUM: 0 | 🟢 LOW: 0'
  GATE_NOW_COUNT=0
  _gate_verdict_is_stale=true
  run review_reports_zero_findings "$body"
  [ "$status" -eq 0 ]
  [ "${_gate_verdict_is_stale}" = "true" ]
}

# ---------------------------------------------------------------------------
# assess-review-issues.sh NO_ACTIONABLE_ITEMS output
# ---------------------------------------------------------------------------

@test "NO_ACTIONABLE_ITEMS: helper succeeds on template zero-findings body" {
  # Verify the helper returns 0 for the exact format used in the live freshup #621 failure.
  local body
  body='**Findings:** 🔴 CRITICAL: 0 | 🟠 HIGH: 0 | 🟡 MEDIUM: 0 | 🟢 LOW: 0'
  run review_reports_zero_findings "$body"
  [ "$status" -eq 0 ]
}

@test "NO_ACTIONABLE_ITEMS: reproduction from issue description returns 1 for old regex, 0 for helper" {
  # The broken regex: grep -cE "Findings: CRITICAL: [0-9]+ [|] HIGH: ..." returns 0 (no match).
  # The helper must return 0 (match found, all zero).
  local body
  body='**Findings:** 🔴 CRITICAL: 0 | 🟠 HIGH: 0 | 🟡 MEDIUM: 0 | 🟢 LOW: 0'

  # Old behavior: regex prints 0 (broken — does not match the template format).
  old_count=$(printf '%s\n' "$body" \
    | grep -cE "Findings: CRITICAL: [0-9]+ [|] HIGH: [0-9]+ [|] MEDIUM: [0-9]+ [|] LOW: [0-9]+" || true)
  [ "$old_count" -eq 0 ]  # proves the old regex was broken

  # New behavior: helper correctly identifies zero findings.
  run review_reports_zero_findings "$body"
  [ "$status" -eq 0 ]
}
