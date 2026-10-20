#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/merge-pr.sh
#
# merge-pr.sh's CONFLICTING bail path must attempt resolution before aborting
# (#1339).
#
# stale-branch.sh and mid-run-rebase.sh both call attempt_claude_merge_resolution
# on their conflict paths. merge-pr.sh did its own `git merge`, and on failure
# called `git merge --abort` and gave up — so the deterministic drift-log union
# merge (#1319), which lives inside the resolver, was unreachable from here.
#
# Live: #1221 and #1203 failed three runs in a row on
# "CONFLICT (content): Merge conflict in docs/sharkrite-drift-log.md" — the exact
# shape #1319 resolves without a provider call.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SUT="$RITE_REPO_ROOT/lib/core/merge-pr.sh"
}

@test "merge-pr.sh sources conflict-resolver.sh when present" {
  grep -q 'utils/conflict-resolver.sh' "$SUT"
  # Guarded with -f so a trimmed install still loads merge-pr.sh.
  grep -q 'if \[ -f "\$RITE_LIB_DIR/utils/conflict-resolver.sh" \]' "$SUT"
}

@test "the CONFLICTING path calls the resolver before aborting" {
  local _region
  _region=$(sed -n '/Attempting to merge \$PR_BASE into feature branch/,/could not be auto-resolved/p' "$SUT")
  [ -n "$_region" ]
  echo "$_region" | grep -q 'attempt_claude_merge_resolution'
  # And completes the stage+commit handoff the resolver cannot do itself.
  echo "$_region" | grep -q 'commit_resolved_conflicts'
}

@test "the resolver call is guarded by declare -f" {
  # conflict-resolver.sh is optional; calling it unguarded would break a
  # trimmed install.
  grep -q 'declare -f attempt_claude_merge_resolution' "$SUT"
}

@test "usage cap (exit 5) propagates instead of being masked as a merge failure" {
  # A cap during resolution is batch-blocking. Collapsing it into
  # VALIDATION_FAILED would let the batch keep burning its queue against a
  # dead quota — the exact cascade exit 5 exists to prevent.
  local _region
  _region=$(sed -n '/Attempting conflict resolution before giving up/,/could not be auto-resolved/p' "$SUT")
  [ -n "$_region" ]
  echo "$_region" | grep -qE '_mpr_resolver_exit.*-eq 5'
  echo "$_region" | grep -qE 'exit 5'
}

@test "abort still happens when resolution does not succeed" {
  # The fallback must be preserved: an unresolvable conflict still aborts the
  # merge and fails validation rather than proceeding.
  local _region
  _region=$(sed -n '/Attempting conflict resolution before giving up/,/^    fi$/p' "$SUT")
  echo "$_region" | grep -q 'git merge --abort'
  echo "$_region" | grep -q 'VALIDATION_FAILED=true'
}

@test "resolution success re-checks mergeable state rather than assuming it" {
  local _region
  _region=$(sed -n '/Conflicts resolved and pushed/,/could not be auto-resolved/p' "$SUT")
  echo "$_region" | grep -q 'pr view "\$PR_NUMBER" --json mergeable'
}
