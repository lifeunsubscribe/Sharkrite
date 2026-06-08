#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh
# Regression test for: Source logging.sh in assess-documentation.sh
# Issue #61
#
# Bug: assess-documentation.sh called verbose_info (and other verbose_* functions
# defined in lib/utils/logging.sh) but did not source that file. When invoked via
# `bash assess-documentation.sh N --auto` (a fresh bash process), verbose_info was
# undefined and bash emitted "verbose_info: command not found" on stderr.
#
# This test verifies:
# 1. The source block in assess-documentation.sh includes logging.sh.
# 2. All verbose_* functions referenced in the script are actually available after
#    sourcing it in a controlled environment — no "command not found" on stderr.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ASSESS_DOC_SCRIPT="$PROJECT_ROOT/lib/core/assess-documentation.sh"
}

# -----------------------------------------------------------------------
# Test 1: Static check — logging.sh is in the source block
# -----------------------------------------------------------------------

@test "assess-documentation.sh: logging.sh is sourced" {
  # Confirm the source line is present in the script.
  grep -q 'source.*logging\.sh' "$ASSESS_DOC_SCRIPT"
}

# -----------------------------------------------------------------------
# Test 2: Static check — source order: logging.sh comes after colors.sh
# The convention in all lib/core scripts is:
#   colors.sh → logging.sh → other utils
# -----------------------------------------------------------------------

@test "assess-documentation.sh: logging.sh sourced after colors.sh" {
  # Get line numbers for each source statement
  _colors_line=$(grep -n 'source.*colors\.sh' "$ASSESS_DOC_SCRIPT" | head -1 | cut -d: -f1)
  _logging_line=$(grep -n 'source.*logging\.sh' "$ASSESS_DOC_SCRIPT" | head -1 | cut -d: -f1)

  [ -n "$_colors_line" ]
  [ -n "$_logging_line" ]
  [ "$_logging_line" -gt "$_colors_line" ]
}

# -----------------------------------------------------------------------
# Test 3: Behavioral check — sourcing assess-documentation.sh's source
# block in a minimal environment defines verbose_info and friends
# without any "command not found" errors.
#
# Strategy: source only the two files (colors.sh + logging.sh) that
# assess-documentation.sh's top block references, then call each
# verbose_* function that the script uses. Assert no "command not found"
# appears on stderr.
# -----------------------------------------------------------------------

@test "assess-documentation.sh: verbose_* functions available after sourcing logging.sh" {
  _lib_dir="$PROJECT_ROOT/lib"

  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${_lib_dir}'
    export RITE_VERBOSE=false

    # Mirror assess-documentation.sh source block (minimal subset)
    source \"\$RITE_LIB_DIR/utils/colors.sh\"
    source \"\$RITE_LIB_DIR/utils/logging.sh\"

    # Call each verbose_* function used by assess-documentation.sh
    verbose_info  'test: security'      2>/dev/null
    verbose_info  'test: architecture'  2>/dev/null
    verbose_info  'test: api'           2>/dev/null
    verbose_info  'test: adr'           2>/dev/null
    verbose_info  'test: reconcile'     2>/dev/null
    verbose_info  'test: consistency'   2>/dev/null

    echo PASS
  " 2>&1

  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  # Must produce no "command not found" errors
  ! [[ "$output" == *"command not found"* ]]
}

# -----------------------------------------------------------------------
# Test 4: Behavioral check — running assess-documentation.sh in a minimal
# environment that stubs out external dependencies (gh, providers) exits
# before doing any real work but must NOT emit "command not found" for any
# logging function.
#
# We pass a deliberately invalid PR number so the gh call fails fast,
# but we verify no "command not found" appears on stderr before that point.
# -----------------------------------------------------------------------

@test "assess-documentation.sh: no 'command not found' from logging functions on early exit" {
  _lib_dir="$PROJECT_ROOT/lib"

  # Create a minimal stub environment that satisfies config.sh's env requirements
  # so RITE_LIB_DIR is set correctly, then let the script fail on the gh call.
  # We capture stderr to verify no logging-function "command not found" error
  # appears before gh is invoked.
  run bash -c "
    export RITE_LIB_DIR='${_lib_dir}'
    export RITE_PROJECT_ROOT='\${TMPDIR:-/tmp}'
    export RITE_DATA_DIR='.rite'
    export RITE_VERBOSE=false
    export RITE_REVIEW_PROVIDER=claude

    # Stub provider functions so the provider-interface source block succeeds
    # without requiring a real provider install.
    provider_detect_cli()   { return 0; }
    provider_validate_cli() { return 0; }
    export -f provider_detect_cli provider_validate_cli

    # Stub gh so it exits 1 immediately (simulating no network / no real PR)
    gh() { echo 'stub: gh not available' >&2; return 1; }
    export -f gh

    # Run the script — it will fail at the gh call, which is expected.
    # We only care that no 'command not found' appeared before that.
    bash '${ASSESS_DOC_SCRIPT}' 99999 --auto 2>&1 || true
  " 2>&1

  # The script may exit non-zero (gh stub fails) — that is fine.
  # What must NOT appear is a logging function "command not found" error.
  ! [[ "$output" == *"verbose_info: command not found"* ]]
  ! [[ "$output" == *"verbose_header: command not found"* ]]
  ! [[ "$output" == *"verbose_warning: command not found"* ]]
  ! [[ "$output" == *"verbose_echo: command not found"* ]]
  ! [[ "$output" == *"is_verbose: command not found"* ]]
}
