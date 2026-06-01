#!/usr/bin/env bats
# Regression test for: Bump RITE_ASSESSMENT_TIMEOUT default from 120s to 300s
#
# Verifies:
#   1. The default is 300 (not the old 120) — so a 200s assessment no longer
#      times out when RITE_ASSESSMENT_TIMEOUT is unset.
#   2. The user-facing hint message suggests 600s (the next reasonable step).
#
# Related issue: #136 / #137
# Live failure: rite-22-23-...-20260531-143852.log line 590
#   "Assessment timed out after 120s — Try increasing timeout: export RITE_ASSESSMENT_TIMEOUT=300"

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
}

# ---------------------------------------------------------------------------
# Default value
# ---------------------------------------------------------------------------

@test "RITE_ASSESSMENT_TIMEOUT default is 300 (not 120)" {
  run bash -c "
    unset RITE_ASSESSMENT_TIMEOUT
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    echo \"\${RITE_ASSESSMENT_TIMEOUT}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "300" ]
}

@test "RITE_ASSESSMENT_TIMEOUT default is NOT 120 (regression guard)" {
  run bash -c "
    unset RITE_ASSESSMENT_TIMEOUT
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    echo \"\${RITE_ASSESSMENT_TIMEOUT}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" != "120" ]
}

@test "RITE_ASSESSMENT_TIMEOUT can be overridden by env" {
  run bash -c "
    export RITE_ASSESSMENT_TIMEOUT=600
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    echo \"\${RITE_ASSESSMENT_TIMEOUT}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "600" ]
}

# ---------------------------------------------------------------------------
# Hint message
# ---------------------------------------------------------------------------

@test "assess-review-issues.sh timeout hint suggests 600s (not 300s)" {
  # The old hint was "export RITE_ASSESSMENT_TIMEOUT=300" — after the bump it
  # should tell users to try 600 (the next step above the new 300 default).
  run grep -n "RITE_ASSESSMENT_TIMEOUT=" "${RITE_LIB_DIR}/core/assess-review-issues.sh"
  [ "$status" -eq 0 ]
  # Hint line should contain 600
  echo "$output" | grep -q "600"
}

@test "assess-review-issues.sh timeout hint does NOT suggest 300s" {
  # 300 is now the default — suggesting it as a fix would be circular.
  # The hint should point to a higher value (600).
  _hint_line=$(grep "Try increasing timeout" "${RITE_LIB_DIR}/core/assess-review-issues.sh" || true)
  # Should NOT contain =300 in the hint
  [[ "$_hint_line" != *"=300"* ]]
}
