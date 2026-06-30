#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/markers.sh
#
# Regression: RITE_MARKER_ISSUE_TAGS constant exists (tag-index read-path #403,
# S4-3). The constant must be defined so later wiring references it instead of
# the literal "sharkrite-issue-tags" (which the RAW_MARKER_LITERAL lint blocks).

setup() {
  MARKERS_SH="${BATS_TEST_DIRNAME}/../../lib/utils/markers.sh"
}

@test "RITE_MARKER_ISSUE_TAGS is defined with value sharkrite-issue-tags" {
  run bash -c "set -euo pipefail; source '$MARKERS_SH'; printf '%s' \"\$RITE_MARKER_ISSUE_TAGS\""
  [ "$status" -eq 0 ]
  [ "$output" = "sharkrite-issue-tags" ]
}

@test "markers.sh is re-source safe (sourced twice under set -euo pipefail)" {
  run bash -c "set -euo pipefail; source '$MARKERS_SH'; source '$MARKERS_SH'; printf '%s' \"\$RITE_MARKER_ISSUE_TAGS\""
  [ "$status" -eq 0 ]
  [ "$output" = "sharkrite-issue-tags" ]
}
