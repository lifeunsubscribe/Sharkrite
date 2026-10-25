#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/review-helper.sh::build_prior_decisions_ledger, lib/core/assess-review-issues.sh, lib/core/local-review.sh
#
# build_prior_decisions_ledger: the settled DISMISSED / ACTIONABLE_LATER
# findings on a PR, with the assessor's reasoning, newest classification wins.
# It moved from assess-review-issues.sh (a script with a top-level body, not
# sourceable) to review-helper.sh so local-review.sh can hand the same ledger
# to the reviewer on fix-review passes — before that the reviewer never saw
# the decisions and could re-raise a settled finding every round.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  # shellcheck disable=SC1090
  source "${RITE_LIB_DIR}/utils/review-helper.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  # gh_safe stub, defined AFTER the source (review-helper.sh uses an env-var
  # re-source guard, so a pre-source stub would be overwritten — Rule 34).
  # Answers `gh pr view N --json comments --jq <filter>` by running the real
  # jq filter over $GH_FIXTURE, exactly as gh would.
  export GH_FIXTURE="$RITE_TEST_TMPDIR/comments.json"
  gh_safe() {
    local jqf=""
    while [ $# -gt 0 ]; do
      case "$1" in --jq) jqf="$2"; shift 2 ;; *) shift ;; esac
    done
    jq "$jqf" "$GH_FIXTURE"
  }
  export -f gh_safe
}

teardown() {
  teardown_test_tmpdir
}

# _assessment <createdAt> <body-after-separator...>
# An assessment comment: marker, a "---" separator, then the classified items.
_assessment() {
  local ts="$1"; shift
  local body
  body=$(printf '<!-- sharkrite-assessment pr:7 iteration:1 timestamp:%s commit:abc -->\n\n---\n%s' "$ts" "$*")
  jq -n --arg b "$body" --arg t "$ts" '{body:$b, createdAt:$t}'
}

_fixture() {
  jq -n '[inputs]' | jq '{comments: .}' > "$GH_FIXTURE"
}

@test "no assessment comments → empty ledger" {
  jq -n '{comments: [{body: "<!-- sharkrite-local-review commit:abc -->\n## Review", createdAt: "2026-10-24T01:00:00Z"}]}' > "$GH_FIXTURE"
  run build_prior_decisions_ledger 7
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "DISMISSED and ACTIONABLE_LATER items carry their reasoning; ACTIONABLE_NOW is excluded" {
  _assessment "2026-10-24T01:00:00Z" "$(cat <<'EOF'
### Unquoted var in loop - ACTIONABLE_NOW
**Reasoning:** Real bug.

### Add logging to helper - DISMISSED
**Reasoning:** Cosmetic; the helper already prints on failure.

### Index on lookups table - ACTIONABLE_LATER
**Reasoning:** Out of scope for this PR; real but separate.
EOF
)" | _fixture
  run build_prior_decisions_ledger 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"### Add logging to helper - DISMISSED"* ]]
  [[ "$output" == *"**Reasoning:** Cosmetic; the helper already prints on failure."* ]]
  [[ "$output" == *"### Index on lookups table - ACTIONABLE_LATER"* ]]
  [[ "$output" == *"**Reasoning:** Out of scope for this PR; real but separate."* ]]
  [[ "$output" != *"Unquoted var in loop"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^### ')" -eq 2 ]
}

@test "same title across iterations: the newest classification wins, once" {
  {
    _assessment "2026-10-24T01:00:00Z" "$(printf '### Index on lookups table - ACTIONABLE_LATER\n**Reasoning:** Defer.')"
    _assessment "2026-10-24T02:00:00Z" "$(printf '### Index on lookups table - DISMISSED\n**Reasoning:** Table has 12 rows; no index needed.')"
  } | _fixture
  run build_prior_decisions_ledger 7
  [ "$(printf '%s\n' "$output" | grep -c '^### Index on lookups table')" -eq 1 ]
  [[ "$output" == *"### Index on lookups table - DISMISSED"* ]]
  [[ "$output" == *"Table has 12 rows"* ]]
  [[ "$output" != *"**Reasoning:** Defer."* ]]
}

@test "review comments without the assessment marker are ignored" {
  {
    jq -n '{body: "<!-- sharkrite-local-review commit:abc -->\n---\n### Looks like a finding - DISMISSED\n**Reasoning:** from a review, not an assessment", createdAt: "2026-10-24T01:00:00Z"}'
    _assessment "2026-10-24T02:00:00Z" "$(printf '### Real one - DISMISSED\n**Reasoning:** settled.')"
  } | _fixture
  run build_prior_decisions_ledger 7
  [[ "$output" == *"### Real one - DISMISSED"* ]]
  [[ "$output" != *"Looks like a finding"* ]]
}

@test "the function lives in review-helper.sh and is exported; assess-review-issues.sh sources it" {
  grep -q '^build_prior_decisions_ledger()' "$RITE_LIB_DIR/utils/review-helper.sh"
  grep -q '^export -f build_prior_decisions_ledger' "$RITE_LIB_DIR/utils/review-helper.sh"
  run grep -c '^build_prior_decisions_ledger()' "$RITE_LIB_DIR/core/assess-review-issues.sh"
  [ "$output" = "0" ]
  grep -q 'source "$RITE_LIB_DIR/utils/review-helper.sh"' "$RITE_LIB_DIR/core/assess-review-issues.sh"
}
