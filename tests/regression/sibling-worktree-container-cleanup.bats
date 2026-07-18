#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/stale-branch.sh, lib/core/workflow-runner.sh
#
# Regression for #980: two worktree-removal sites did `git worktree remove`
# without cleaning the now-empty container dir left under RITE_WORKTREE_DIR —
# the residue that rmdir_empty_worktree_container() exists to remove. Four other
# sites already called the helper; these two siblings were missed (PR #1001 was
# abandoned). Assert both now call it, and that workflow-runner sources the
# helper (it is not export -f'd).

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  STALE="${RITE_REPO_ROOT}/lib/utils/stale-branch.sh"
  RUNNER="${RITE_REPO_ROOT}/lib/core/workflow-runner.sh"
}

# Extract a shell function body by name (awk: from `name()` to the first
# column-0 `}`), so an assertion targets the intended function, not the file.
_func_body() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\)" { in_fn=1 }
    in_fn { print }
    in_fn && /^}$/ { exit }
  ' "$2"
}

@test "#980: _stale_close_and_cleanup calls rmdir_empty_worktree_container" {
  _body=$(_func_body "_stale_close_and_cleanup" "$STALE")
  [ -n "$_body" ]
  echo "$_body" | grep -q "rmdir_empty_worktree_container" || {
    echo "FAIL: _stale_close_and_cleanup does not clean the empty worktree container" >&2
    return 1
  }
}

@test "#980: the stale-branch cleanup call sits after the worktree remove" {
  _body=$(_func_body "_stale_close_and_cleanup" "$STALE")
  _rm_ln=$(echo "$_body" | grep -n "git worktree remove" | head -1 | cut -d: -f1)
  _cleanup_ln=$(echo "$_body" | grep -n "rmdir_empty_worktree_container" | head -1 | cut -d: -f1)
  [ -n "$_rm_ln" ] && [ -n "$_cleanup_ln" ]
  [ "$_cleanup_ln" -gt "$_rm_ln" ]
}

@test "#980: handle_closed_issue calls rmdir_empty_worktree_container" {
  _body=$(_func_body "handle_closed_issue" "$RUNNER")
  [ -n "$_body" ]
  echo "$_body" | grep -q "rmdir_empty_worktree_container" || {
    echo "FAIL: handle_closed_issue does not clean the empty worktree container" >&2
    return 1
  }
}

@test "#980: workflow-runner.sh sources git-helpers.sh (helper is not export -f'd)" {
  grep -qE 'source .*utils/git-helpers\.sh' "$RUNNER" || {
    echo "FAIL: workflow-runner.sh must source git-helpers.sh so rmdir_empty_worktree_container is defined" >&2
    return 1
  }
}

@test "behavioral: rmdir_empty_worktree_container removes an empty container child" {
  # Wire-up check: the helper (as both sites call it) removes an empty dir that
  # is a direct child of RITE_WORKTREE_DIR, and leaves non-empty/foreign dirs.
  # shellcheck source=/dev/null
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "${RITE_REPO_ROOT}/lib/utils/git-helpers.sh" 2>/dev/null || \
    source "${RITE_REPO_ROOT}/lib/utils/git-helpers.sh"
  _wtdir=$(mktemp -d)
  mkdir -p "$_wtdir/gone-wt"          # emptied worktree container
  mkdir -p "$_wtdir/keep-wt/leftover" # non-empty → must survive
  rmdir_empty_worktree_container "$_wtdir/gone-wt" "$_wtdir"
  rmdir_empty_worktree_container "$_wtdir/keep-wt" "$_wtdir"
  run test -d "$_wtdir/gone-wt"; _gone=$status
  run test -d "$_wtdir/keep-wt"; _keep=$status
  rm -rf "$_wtdir"
  [ "$_gone" -ne 0 ]   # gone-wt removed
  [ "$_keep" -eq 0 ]   # keep-wt survived
}
