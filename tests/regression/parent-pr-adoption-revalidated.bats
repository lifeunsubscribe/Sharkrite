#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh::_revalidate_parent_adoption|phase_create_pr
# tests/regression/parent-pr-adoption-revalidated.bats
#
# A follow-up issue carrying `sharkrite-parent-pr:N` ADOPTS its parent PR's
# branch and worktree instead of opening a competing PR. That decision is made
# once, at workflow start, from the parent's state at that moment — and nothing
# holds the parent still. Another process can merge it mid-run, and the
# parent's own cleanup then deletes the branch and removes the worktree out
# from under the live follow-up.
#
# Live: issue #1382 adopted PR #1379 at 22:29:40Z. #1379 merged at 22:33:45Z,
# four minutes into the follow-up's run. At 22:36:31Z phase_create_pr died with
#
#     ❌ Local review failed
#     ❌ create-pr.sh failed with exit code: 1
#
# and the follow-up's work was gone with the worktree. The adoption had been
# correct when made; it was never re-checked.
#
# _revalidate_parent_adoption runs at the top of phase_create_pr, before the
# worktree is touched. A parent that is no longer OPEN means: detach and open
# our own PR (worktree survived), or fail with a clear re-run message (it did
# not). An unreadable state keeps the adoption — an API blip is not evidence
# the parent died.
#
# Tests in this file:
#   1. no adoption → no-op, no gh call
#   2. parent still OPEN → adoption kept, PR_NUMBER untouched
#   3. parent MERGED, worktree present → detached: PR_NUMBER cleared, mode=ignore, diag emitted, exit 0
#   4. parent MERGED, worktree gone → exit 1 with the re-run message
#   5. unreadable state → adoption kept, exit 0
#   6. structural: phase_create_pr re-validates before cd "$WORKTREE_PATH"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"

setup() {
  [ -f "$RUNNER" ] || { echo "FATAL: $RUNNER not found" >&2; return 1; }
  _tmpdir=$(mktemp -d)
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# Drive the helper with a scripted parent state. $1=state ("" = unreadable),
# $2=mode, $3=worktree path ("" = unset). Prints the resulting globals.
_drive() {
  run bash -c "
    set -uo pipefail
    _CALLS='$_tmpdir/calls'; : > \"\$_CALLS\"
    gh_safe() { echo \"\$*\" >> \"\$_CALLS\"; [ -n '$1' ] && printf '%s\n' '$1'; return 0; }
    print_warning() { echo \"WARN: \$*\"; }
    print_error()   { echo \"ERR: \$*\"; }
    print_info()    { echo \"INFO: \$*\"; }
    _diag()         { echo \"DIAG: \$*\"; }
    $(sed -n '/^_revalidate_parent_adoption()/,/^}/p' "$RUNNER")
    PARENT_ATTACHMENT_MODE='$2'
    PARENT_PR_NUMBER='1379'
    PR_NUMBER='1379'
    CURRENT_PR='1379'
    WORKTREE_PATH='$3'
    _rc=0
    _revalidate_parent_adoption 1382 || _rc=\$?
    echo \"rc=\$_rc pr=\${PR_NUMBER:-} cur=\${CURRENT_PR:-} mode=\$PARENT_ATTACHMENT_MODE gh_calls=\$(wc -l < \"\$_CALLS\" | tr -d ' ')\"
  "
}

@test "no adoption: no-op and no gh call" {
  _drive "OPEN" "none" "$_tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'rc=0 pr=1379 cur=1379 mode=none gh_calls=0' || {
    echo "FAIL: expected untouched state and zero gh calls; got: $output" >&2
    return 1
  }
}

@test "parent still OPEN: adoption kept, PR_NUMBER untouched" {
  _drive "OPEN" "adopt" "$_tmpdir"
  echo "$output" | grep -q 'rc=0 pr=1379 cur=1379 mode=adopt' || {
    echo "FAIL: an open parent must keep the adoption; got: $output" >&2
    return 1
  }
}

@test "parent MERGED with worktree present: detaches and continues" {
  # The #1382 shape, but caught before the worktree was lost.
  _drive "MERGED" "adopt" "$_tmpdir"
  echo "$output" | grep -q 'rc=0 pr= cur= mode=ignore' || {
    echo "FAIL: expected detach (PR cleared, mode=ignore, exit 0); got: $output" >&2
    return 1
  }
  echo "$output" | grep -q 'DIAG: PARENT_ADOPTION_DROPPED issue=1382 parent_pr=1379 state=MERGED' || {
    echo "FAIL: detach must be diagnosable; got: $output" >&2
    return 1
  }
  echo "$output" | grep -q 'will open its own PR' || {
    echo "FAIL: operator must be told the follow-up detached; got: $output" >&2
    return 1
  }
}

@test "parent MERGED with worktree gone: fails clearly with a re-run message" {
  # The #1382 outcome as it actually happened — nothing left to detach onto.
  _drive "MERGED" "adopt" "$_tmpdir/does-not-exist"
  echo "$output" | grep -q 'rc=1' || {
    echo "FAIL: a lost worktree must fail, not limp into create-pr; got: $output" >&2
    return 1
  }
  echo "$output" | grep -q 'rite 1382' || {
    echo "FAIL: the message must give the exact re-run command; got: $output" >&2
    return 1
  }
  echo "$output" | grep -q 'worktree was removed' || {
    echo "FAIL: the message must say what happened; got: $output" >&2
    return 1
  }
}

@test "unreadable parent state: adoption kept (an API blip is not a death)" {
  _drive "" "adopt" "$_tmpdir"
  echo "$output" | grep -q 'rc=0 pr=1379 cur=1379 mode=adopt' || {
    echo "FAIL: unreadable state must not fragment the PR; got: $output" >&2
    return 1
  }
}

@test "structural: phase_create_pr re-validates before entering the worktree" {
  # The call must precede the cd — a removed worktree would otherwise kill the
  # phase under set -e before the clear message is ever printed.
  _body=$(sed -n '/^phase_create_pr()/,/^}/p' "$RUNNER")
  _call=$(printf '%s\n' "$_body" | grep -n '_revalidate_parent_adoption "\$issue_number"' | head -1 | cut -d: -f1)
  _cd=$(printf '%s\n' "$_body" | grep -n 'cd "\$WORKTREE_PATH"' | head -1 | cut -d: -f1)

  [ -n "$_call" ] || { echo "FAIL: phase_create_pr never calls _revalidate_parent_adoption" >&2; return 1; }
  [ -n "$_cd" ]   || { echo "FAIL: could not find cd \"\$WORKTREE_PATH\" in phase_create_pr" >&2; return 1; }
  [ "$_call" -lt "$_cd" ] || {
    echo "FAIL: re-validation (line $_call) must precede cd into the worktree (line $_cd)" >&2
    return 1
  }
}
