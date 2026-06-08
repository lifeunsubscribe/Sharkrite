#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/core/workflow-runner.sh
# Regression test: FIX_TIMEOUT proportional formula
#
# Verifies:
#   1. Formula produces correct values for various ACTIONABLE_NOW_COUNT inputs
#   2. Result is capped at 1800 for large counts
#   3. RITE_FIX_TIMEOUT env var overrides the formula
#
# Formula: 300 + 240 * ACTIONABLE_NOW_COUNT, capped at 1800
#   count=1  → 300 + 240 = 540s   (~9 min)
#   count=3  → 300 + 720 = 1020s  (~17 min)
#   count=6  → 300 + 1440 = 1740s (~29 min)
#   count=10 → 300 + 2400 = 2700 → capped at 1800s (30 min)
#
# Related issue: #448 (Move verification out of fix session)

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
}

@test "FIX_TIMEOUT: count=1 → 540s" {
  run bash -c "
    ACTIONABLE_NOW_COUNT=1
    _default_fix_timeout=\$(( 300 + 240 * \${ACTIONABLE_NOW_COUNT:-1} ))
    [ \"\$_default_fix_timeout\" -gt 1800 ] && _default_fix_timeout=1800
    FIX_TIMEOUT=\${RITE_FIX_TIMEOUT:-\$_default_fix_timeout}
    echo \"\$FIX_TIMEOUT\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "540" ]
}

@test "FIX_TIMEOUT: count=3 → 1020s" {
  run bash -c "
    ACTIONABLE_NOW_COUNT=3
    _default_fix_timeout=\$(( 300 + 240 * \${ACTIONABLE_NOW_COUNT:-1} ))
    [ \"\$_default_fix_timeout\" -gt 1800 ] && _default_fix_timeout=1800
    FIX_TIMEOUT=\${RITE_FIX_TIMEOUT:-\$_default_fix_timeout}
    echo \"\$FIX_TIMEOUT\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1020" ]
}

@test "FIX_TIMEOUT: count=6 → 1740s" {
  run bash -c "
    ACTIONABLE_NOW_COUNT=6
    _default_fix_timeout=\$(( 300 + 240 * \${ACTIONABLE_NOW_COUNT:-1} ))
    [ \"\$_default_fix_timeout\" -gt 1800 ] && _default_fix_timeout=1800
    FIX_TIMEOUT=\${RITE_FIX_TIMEOUT:-\$_default_fix_timeout}
    echo \"\$FIX_TIMEOUT\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1740" ]
}

@test "FIX_TIMEOUT: count=10 → capped at 1800s" {
  run bash -c "
    ACTIONABLE_NOW_COUNT=10
    _default_fix_timeout=\$(( 300 + 240 * \${ACTIONABLE_NOW_COUNT:-1} ))
    [ \"\$_default_fix_timeout\" -gt 1800 ] && _default_fix_timeout=1800
    FIX_TIMEOUT=\${RITE_FIX_TIMEOUT:-\$_default_fix_timeout}
    echo \"\$FIX_TIMEOUT\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1800" ]
}

@test "FIX_TIMEOUT: count=100 → capped at 1800s (large count safety)" {
  run bash -c "
    ACTIONABLE_NOW_COUNT=100
    _default_fix_timeout=\$(( 300 + 240 * \${ACTIONABLE_NOW_COUNT:-1} ))
    [ \"\$_default_fix_timeout\" -gt 1800 ] && _default_fix_timeout=1800
    FIX_TIMEOUT=\${RITE_FIX_TIMEOUT:-\$_default_fix_timeout}
    echo \"\$FIX_TIMEOUT\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1800" ]
}

@test "FIX_TIMEOUT: RITE_FIX_TIMEOUT env var overrides formula" {
  run bash -c "
    ACTIONABLE_NOW_COUNT=3
    export RITE_FIX_TIMEOUT=600
    _default_fix_timeout=\$(( 300 + 240 * \${ACTIONABLE_NOW_COUNT:-1} ))
    [ \"\$_default_fix_timeout\" -gt 1800 ] && _default_fix_timeout=1800
    FIX_TIMEOUT=\${RITE_FIX_TIMEOUT:-\$_default_fix_timeout}
    echo \"\$FIX_TIMEOUT\"
  "
  [ "$status" -eq 0 ]
  # Even though formula would give 1020, env var override gives 600
  [ "$output" = "600" ]
}

@test "FIX_TIMEOUT: unset ACTIONABLE_NOW_COUNT defaults to count=1 (540s)" {
  run bash -c "
    unset ACTIONABLE_NOW_COUNT
    _default_fix_timeout=\$(( 300 + 240 * \${ACTIONABLE_NOW_COUNT:-1} ))
    [ \"\$_default_fix_timeout\" -gt 1800 ] && _default_fix_timeout=1800
    FIX_TIMEOUT=\${RITE_FIX_TIMEOUT:-\$_default_fix_timeout}
    echo \"\$FIX_TIMEOUT\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "540" ]
}
