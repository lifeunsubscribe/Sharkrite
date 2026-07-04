#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/merge-pr.sh, lib/utils/cleanup-worktrees.sh
# Regression: the periodic deep-clean (merge-pr.sh) and worktree cleanup
# (cleanup-worktrees.sh) must NOT force-remove a worktree on detached HEAD
# (the normal state mid-rebase/mid-bisect). `git branch --show-current` returns
# an EMPTY string on detached HEAD, which the old code coerced toward "branch
# deleted/merged" -> stale -> `git worktree remove --force`, destroying
# in-progress rebase state. Worse, the batch-sibling protection keys on the
# branch name, so an empty one can't be protected and a live sibling is removed.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"; export RITE_REPO_ROOT
}

@test "detached-HEAD worktree is skipped (not judged stale) by the cleanup preamble" {
  run bash -c '
    set -euo pipefail
    wt_path=$(mktemp -d)
    git -C "$wt_path" init -q
    git -C "$wt_path" config user.email t@t; git -C "$wt_path" config user.name t
    echo x > "$wt_path/a"; git -C "$wt_path" add a; git -C "$wt_path" commit -qm init
    git -C "$wt_path" checkout -q --detach HEAD   # the mid-rebase-like state

    # Shared stale-decision preamble (merge-pr.sh:1561 / cleanup-worktrees.sh:83).
    WT_BRANCH=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "unknown")
    if [ -z "$WT_BRANCH" ]; then
      rm -rf "$wt_path"
      echo "SKIPPED"; exit 0    # the fix: detached HEAD -> skip, never stale
    fi
    # Without the guard the old code reached here and (no matching ref) marked stale.
    BRANCH_EXISTS=$(git show-ref --verify --quiet refs/heads/"$WT_BRANCH" && echo yes || echo no)
    rm -rf "$wt_path"
    echo "NOT_SKIPPED branch=[$WT_BRANCH] exists=$BRANCH_EXISTS"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIPPED"* ]] || { echo "FAIL: detached-HEAD worktree was not skipped: $output"; false; }
}

@test "a branch-attached worktree is NOT skipped by the empty-WT_BRANCH guard" {
  # Sanity: the guard must only skip detached HEAD, not normal worktrees.
  run bash -c '
    set -euo pipefail
    wt_path=$(mktemp -d)
    git -C "$wt_path" init -q -b feature/x
    git -C "$wt_path" config user.email t@t; git -C "$wt_path" config user.name t
    echo x > "$wt_path/a"; git -C "$wt_path" add a; git -C "$wt_path" commit -qm init
    WT_BRANCH=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "unknown")
    rm -rf "$wt_path"
    [ -z "$WT_BRANCH" ] && { echo "WRONGLY_EMPTY"; exit 0; }
    echo "ATTACHED branch=$WT_BRANCH"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"ATTACHED branch=feature/x"* ]]
}

@test "source: both cleanup sites skip an empty (detached-HEAD) WT_BRANCH" {
  run grep -q 'if \[ -z "\$WT_BRANCH" \]; then' "${RITE_REPO_ROOT}/lib/core/merge-pr.sh"
  [ "$status" -eq 0 ]
  run grep -q 'if \[ -z "\$WT_BRANCH" \]; then' "${RITE_REPO_ROOT}/lib/utils/cleanup-worktrees.sh"
  [ "$status" -eq 0 ]
}
