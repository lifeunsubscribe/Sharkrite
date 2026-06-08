#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Regression test for: draft-PR creation produces chaotic output on failure
#
# Bug history:
#   The "Creating Draft PR for Tracking" block in claude-workflow.sh had two
#   silent-cascade bugs that combined to produce confusing output (doubled
#   "fatal: not a git repository" + misleading "Remote branch diverged"
#   warning after the fatal):
#
#   1. `git commit --allow-empty` exit code was ignored. The output was then
#      run through two sed substitutions ('s/] .*/]/' and 's/^[^]]*] //')
#      that both no-op on a fatal-style line lacking '[branch hash]'. The
#      same fatal line was then echoed twice — once bare, once tab-indented.
#
#   2. Any `git push` failure was assumed to be a non-fast-forward divergence,
#      so the code printed "Remote branch diverged — force pushing to sync"
#      and tried force-with-lease / force. Auth, network, missing-remote
#      failures all hit the force-push path silently.
#
# This test asserts:
#   - The push-classification regex matches real non-fast-forward git errors.
#   - The push-classification regex does NOT match unrelated failures (no
#     remote, network, auth) — those must take the fail-loud branch.
#   - The commit-failure branch and push-failure branch are both structurally
#     present in the source.

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT
  CLAUDE_WORKFLOW="${RITE_REPO_ROOT}/lib/core/claude-workflow.sh"
  export CLAUDE_WORKFLOW
}

# ---------------------------------------------------------------------------
# Behavioral: the push-classify regex matches real non-fast-forward errors
#
# These are the verbatim git error patterns we want to catch and recover
# from via force-push. The recovery path is legitimate when the failure is
# genuine divergence (e.g., undo reset the remote branch back to main).
# ---------------------------------------------------------------------------
@test "push-classify regex matches real non-fast-forward git error" {
  # Real git output for a non-fast-forward push (from `git push origin main`
  # when remote has commits the local branch doesn't):
  local push_output=" ! [rejected]        main -> main (non-fast-forward)
error: failed to push some refs to 'origin'
hint: Updates were rejected because the tip of your current branch is behind
hint: its remote counterpart."
  echo "$push_output" | grep -qE "non-fast-forward|fetch first|\(non-fast-forward\)|\(fetch first\)"
  [ "$?" -eq 0 ]
}

@test "push-classify regex matches 'fetch first' git error" {
  # Real git output when remote has new commits and local hasn't fetched:
  local push_output=" ! [rejected]        main -> main (fetch first)
error: failed to push some refs to 'origin'
hint: Updates were rejected because the remote contains work that you do not"
  echo "$push_output" | grep -qE "non-fast-forward|fetch first|\(non-fast-forward\)|\(fetch first\)"
  [ "$?" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Behavioral: the push-classify regex does NOT match unrelated failures
#
# Each of these is a real push failure that the OLD code silently force-pushed
# through. The new code falls into the "git push failed:" branch and exits
# with a clear error instead.
# ---------------------------------------------------------------------------
@test "push-classify regex does NOT match 'no such remote' failure" {
  local push_output="fatal: 'origin' does not appear to be a git repository
fatal: Could not read from remote repository."
  run bash -c "echo \"$push_output\" | grep -qE \"non-fast-forward|fetch first|\\(non-fast-forward\\)|\\(fetch first\\)\""
  [ "$status" -ne 0 ]
}

@test "push-classify regex does NOT match auth failure" {
  local push_output="remote: Permission to org/repo.git denied to user.
fatal: unable to access 'https://github.com/org/repo.git/': The requested URL returned error: 403"
  run bash -c "echo \"$push_output\" | grep -qE \"non-fast-forward|fetch first|\\(non-fast-forward\\)|\\(fetch first\\)\""
  [ "$status" -ne 0 ]
}

@test "push-classify regex does NOT match network failure" {
  local push_output="fatal: unable to access 'https://github.com/org/repo.git/': Could not resolve host: github.com"
  run bash -c "echo \"$push_output\" | grep -qE \"non-fast-forward|fetch first|\\(non-fast-forward\\)|\\(fetch first\\)\""
  [ "$status" -ne 0 ]
}

@test "push-classify regex does NOT match 'not a git repository' failure" {
  # The scenario the user reported: doubled 'fatal:' lines because git commit
  # failed first AND nothing checked that exit code. With the new guard the
  # commit branch returns 1 before we ever reach push, but this still asserts
  # that the push branch wouldn't have mistreated this output as divergence.
  local push_output="fatal: not a git repository (or any of the parent directories): .git"
  run bash -c "echo \"$push_output\" | grep -qE \"non-fast-forward|fetch first|\\(non-fast-forward\\)|\\(fetch first\\)\""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Structural: the commit-failure branch exists and prints a useful error
# ---------------------------------------------------------------------------
@test "claude-workflow.sh: commit-failure branch prints 'git commit failed'" {
  run grep -F 'git commit failed:' "$CLAUDE_WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "claude-workflow.sh: commit-failure branch returns non-zero (does not fall through)" {
  # The fail-loud guard must return so the workflow doesn't cascade into the
  # push/PR phase with no commit. Easiest structural marker: the new
  # "git commit failed:" print is followed (within 5 lines) by a return.
  local body
  body=$(awk '/git commit failed:/,/return 1/' "$CLAUDE_WORKFLOW" | head -10)
  [[ "$body" == *"return 1"* ]]
}

# ---------------------------------------------------------------------------
# Structural: the push-failure non-divergence branch exists
# ---------------------------------------------------------------------------
@test "claude-workflow.sh: push-failure branch prints 'git push failed'" {
  run grep -F 'git push failed:' "$CLAUDE_WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "claude-workflow.sh: push-failure branch is gated by elif (only non-divergence falls through)" {
  # The push handler is now if/elif/else — non-divergence failures don't
  # silently take the force-push path. The elif must reference one of the
  # known divergence keywords; without it, the new "git push failed" else
  # branch is unreachable.
  run grep -F 'elif echo "$push_output"' "$CLAUDE_WORKFLOW"
  [ "$status" -eq 0 ]
}
