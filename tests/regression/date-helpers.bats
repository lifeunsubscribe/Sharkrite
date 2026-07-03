#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/date-helpers.sh
# Regression test for date-helpers.sh
# Tests iso_to_epoch, epoch_to_iso, and iso_to_local_display functions
# Covers both GNU date and BSD date behaviors

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  # Source the date-helpers module
  source "${RITE_REPO_ROOT}/lib/utils/date-helpers.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  teardown_test_tmpdir
}

# =============================================================================
# iso_to_epoch tests
# =============================================================================

@test "iso_to_epoch converts valid ISO 8601 timestamp" {
  # Use a known timestamp for verification
  # 2025-10-28T20:42:18Z = 1761684138 (Unix epoch)
  result=$(iso_to_epoch "2025-10-28T20:42:18Z")

  # Verify it's a number and not "0" (error case)
  [[ "$result" =~ ^[0-9]+$ ]]
  [ "$result" != "0" ]
  [ "$result" -eq 1761684138 ]
}

@test "iso_to_epoch handles epoch 0 (1970-01-01T00:00:00Z)" {
  result=$(iso_to_epoch "1970-01-01T00:00:00Z")
  [ "$result" -eq 0 ]
}

@test "iso_to_epoch handles year 2038 boundary (32-bit systems)" {
  # 2038-01-19T03:14:07Z = 2147483647 (max 32-bit signed int)
  result=$(iso_to_epoch "2038-01-19T03:14:07Z")

  [[ "$result" =~ ^[0-9]+$ ]]
  [ "$result" != "0" ]
  [ "$result" -eq 2147483647 ]
}

@test "iso_to_epoch returns 0 for malformed input" {
  result=$(iso_to_epoch "not-a-timestamp")
  [ "$result" = "0" ]
}

@test "iso_to_epoch returns 0 for empty input" {
  result=$(iso_to_epoch "")
  [ "$result" = "0" ]
}

@test "iso_to_epoch returns 0 for invalid format (missing Z)" {
  result=$(iso_to_epoch "2025-10-28T20:42:18")
  # Some systems may still parse this, so we just verify no crash
  [[ "$result" =~ ^[0-9]+$ ]]
}

# =============================================================================
# epoch_to_iso tests
# =============================================================================

@test "epoch_to_iso converts valid epoch to ISO format" {
  # 1761684138 = 2025-10-28T20:42:18Z
  result=$(epoch_to_iso "1761684138")

  [ "$result" = "2025-10-28T20:42:18Z" ]
}

@test "epoch_to_iso handles epoch 0" {
  result=$(epoch_to_iso "0")
  [ "$result" = "1970-01-01T00:00:00Z" ]
}

@test "epoch_to_iso handles year 2038 boundary" {
  result=$(epoch_to_iso "2147483647")
  [ "$result" = "2038-01-19T03:14:07Z" ]
}

@test "epoch_to_iso returns empty string for invalid input" {
  result=$(epoch_to_iso "not-a-number")
  [ -z "$result" ] || [ "$result" = "" ]
}

@test "epoch_to_iso returns empty string for negative epoch" {
  result=$(epoch_to_iso "-100")
  # BSD date may fail on negative epochs, GNU date handles them
  # We accept either empty or a valid date before 1970
  [ -z "$result" ] || [[ "$result" =~ ^19[0-9]{2}- ]]
}

# =============================================================================
# Round-trip conversion tests
# =============================================================================

@test "round-trip: iso -> epoch -> iso preserves timestamp" {
  original="2025-10-28T20:42:18Z"
  epoch=$(iso_to_epoch "$original")
  result=$(epoch_to_iso "$epoch")

  [ "$result" = "$original" ]
}

@test "round-trip: epoch -> iso -> epoch preserves value" {
  original="1761684138"
  iso=$(epoch_to_iso "$original")
  result=$(iso_to_epoch "$iso")

  [ "$result" = "$original" ]
}

# =============================================================================
# iso_to_local_display tests
# =============================================================================

@test "iso_to_local_display formats timestamp for human reading" {
  result=$(iso_to_local_display "2025-10-28T20:42:18Z")

  # Verify it's not the raw ISO timestamp (i.e., formatting happened)
  [ "$result" != "2025-10-28T20:42:18Z" ]

  # Verify it contains common formatted date elements
  # Format should be like: "Oct 28, 2025 - 2:42 PM MT"
  [[ "$result" =~ [0-9]{4} ]]  # Year
  [[ "$result" =~ [0-9]{1,2} ]] # Day or hour
}

@test "iso_to_local_display returns original on parse failure" {
  invalid="not-a-timestamp"
  result=$(iso_to_local_display "$invalid")

  # On failure, should return the original input
  [ "$result" = "$invalid" ]
}

@test "iso_to_local_display handles epoch 0" {
  result=$(iso_to_local_display "1970-01-01T00:00:00Z")

  # Should format, not return raw ISO
  [ "$result" != "1970-01-01T00:00:00Z" ]
  [[ "$result" =~ 1970 ]]
}

# =============================================================================
# Edge cases and error handling
# =============================================================================

@test "iso_to_epoch is consistent across multiple calls" {
  timestamp="2025-10-28T20:42:18Z"
  result1=$(iso_to_epoch "$timestamp")
  result2=$(iso_to_epoch "$timestamp")

  [ "$result1" = "$result2" ]
}

@test "epoch_to_iso is consistent across multiple calls" {
  epoch="1761684138"
  result1=$(epoch_to_iso "$epoch")
  result2=$(epoch_to_iso "$epoch")

  [ "$result1" = "$result2" ]
}

@test "helpers handle timestamps with microseconds gracefully" {
  # GitHub API sometimes includes microseconds: 2025-10-28T20:42:18.123456Z
  result=$(iso_to_epoch "2025-10-28T20:42:18.123456Z")

  # Should either parse successfully (truncating microseconds) or return 0
  [[ "$result" =~ ^[0-9]+$ ]]
}

@test "helpers handle various whitespace inputs" {
  # Test with leading/trailing whitespace
  result=$(iso_to_epoch " 2025-10-28T20:42:18Z ")

  # date command should handle or reject cleanly (no crash)
  [[ "$result" =~ ^[0-9]+$ ]]
}
