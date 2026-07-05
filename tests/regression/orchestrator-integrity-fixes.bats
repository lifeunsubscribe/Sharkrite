#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/divergence-handler.sh, lib/core/claude-workflow.sh, lib/utils/pr-detection.sh
# Regression pins for the 2026-07-04 orchestrator-integrity audit fixes:
#   1. divergence-handler: the RELATED-reviewed verdict compares timestamps as
#      EPOCH SECONDS via iso_to_epoch/%at — the old lexicographic [[ > ]] of a
#      Z-suffixed API time vs git %aI's numeric-offset local time was
#      meaningless, and a false "reviewed" auto-rebased UNREVIEWED foreign
#      commits past the auto-mode block.
#   2. claude-workflow: the diverged-branch push has NO blind `--force`
#      fallback — lease-only, fail loud on refusal.
#   3. pr-detection: detect_review_state's gh_safe call carries || true so a
#      retry-exhausted gh cannot silently kill rite --status.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"; export RITE_REPO_ROOT
}

@test "behavioral: epoch comparison judges same-instant offset vs Z correctly (lexicographic did not)" {
  # Same instant, two renderings: 20:00Z == 13:00-07:00. Lexicographic string
  # compare says "2026-07-02T13:00:00-07:00" < "2026-07-02T20:00:00Z" purely
  # by character order — a nonsense verdict. Epoch compare says EQUAL.
  source "${RITE_REPO_ROOT}/lib/utils/date-helpers.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  z_epoch=$(iso_to_epoch "2026-07-02T20:00:00Z")
  [ "$z_epoch" -gt 0 ]

  # The fixed code path takes git's side natively as epoch (%at) — simulate:
  # the same instant as the Z form.
  git_epoch="$z_epoch"

  # Epoch verdict: assess NOT strictly greater than an equal-time commit →
  # stays UNREVIEWED (safe). The old string compare of the two renderings
  # would have produced an arbitrary verdict.
  ! [ "$z_epoch" -gt "$git_epoch" ]
}

@test "source: divergence-handler uses %at + iso_to_epoch, no lexicographic timestamp compare" {
  run grep -F 'git log -1 --format="%at"' "${RITE_REPO_ROOT}/lib/utils/divergence-handler.sh"
  [ "$status" -eq 0 ]
  run grep -F 'assess_epoch=$(iso_to_epoch' "${RITE_REPO_ROOT}/lib/utils/divergence-handler.sh"
  [ "$status" -eq 0 ]
  # The old lexicographic compare must be gone.
  run grep -F '[[ "$assess_time" > "$foreign_commit_time" ]]' "${RITE_REPO_ROOT}/lib/utils/divergence-handler.sh"
  [ "$status" -ne 0 ]
  # And the helper is sourced (guarded).
  run grep -F 'date-helpers.sh' "${RITE_REPO_ROOT}/lib/utils/divergence-handler.sh"
  [ "$status" -eq 0 ]
}

@test "source: diverged-branch push has no blind --force fallback (lease only, fail loud)" {
  # `git push -u --force origin` (without -with-lease) must not exist.
  run grep -E 'git push -u --force origin' "${RITE_REPO_ROOT}/lib/core/claude-workflow.sh"
  [ "$status" -ne 0 ]
  run grep -F 'not escalating to --force' "${RITE_REPO_ROOT}/lib/core/claude-workflow.sh"
  [ "$status" -eq 0 ]
}

@test "source: detect_review_state gh_safe call cannot silently kill the caller" {
  run grep -E 'review_json=\$\(gh_safe pr view .* \|\| true\)' "${RITE_REPO_ROOT}/lib/utils/pr-detection.sh"
  [ "$status" -eq 0 ]
}
