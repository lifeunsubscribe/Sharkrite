#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-review-issues.sh
# Regression: wording findings on a docs-only issue were classified
# ACTIONABLE_NOW and drove the fix loop.
#
# Live (freshup #573, 2026-11-12b): a docs-only issue drew five wording
# findings; the assessor read each as an unmet acceptance criterion (the
# document IS the deliverable) and the run spent two fix + review rounds on
# phrasing. Doc drift is meant to be logged cheaply during development and
# applied later in an approved documentation pass — not to interrupt the run.
#
# STRUCTURAL: classification is the model's job, so these assert the prompt in
# assess-review-issues.sh carries the documentation-prose rule in BOTH places
# the NOW bar is stated (a rule stated once is overridden by the other, #495).

load '../helpers/setup.bash'

setup() {
  export ASSESS_REVIEW_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"
  [ -f "$ASSESS_REVIEW_SCRIPT" ]
}

# Print the prompt text between two section headings.
_section() {
  awk -v s="$1" -v e="$2" '$0 ~ s {on=1} on && $0 ~ e {exit} on' "$ASSESS_REVIEW_SCRIPT"
}

@test "categorization section: doc prose is NOW only when absent or factually wrong" {
  run _section '^THREE-STATE CATEGORIZATION:' '^OUTPUT FORMAT:'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOCUMENTATION PROSE"* ]]
  [[ "$output" == *"ABSENT"* ]]
  [[ "$output" == *"FACTUALLY WRONG"* ]]
  [[ "$output" == *"NEVER ACTIONABLE_NOW"* ]]
  # The docs-only case is named explicitly: it is the one that misfired.
  [[ "$output" == *"docs-only"* ]]
}

@test "decision criteria: restate the doc-prose rule next to the NOW bar" {
  run _section '^DECISION CRITERIA:' '^ACTIONABLE_LATER \(defer to tech-debt\)'
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT NOW (DOCUMENTATION PROSE)"* ]]
  [[ "$output" == *"ABSENT"* ]]
  [[ "$output" == *"FACTUALLY WRONG"* ]]
}

@test "doc-prose rule keeps a misleading-text finding trackable (LATER), polish DISMISSED" {
  run _section '^THREE-STATE CATEGORIZATION:' '^OUTPUT FORMAT:'
  [[ "$output" == *"would do"* ]]
  [[ "$output" == *"otherwise DISMISSED"* ]]
}
