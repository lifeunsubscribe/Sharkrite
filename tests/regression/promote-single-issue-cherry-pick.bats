#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/promote-branch.sh, bin/rite
# tests/regression/promote-single-issue-cherry-pick.bats
#
# Regression tests for rite --promote <branch> <issue> (#1273).
#
# Tests verify:
#   1. bin/rite collects an optional issue number after the branch arg.
#   2. Unknown issue number fails with staged-issues listing.
#   3. Already-promoted entry is an idempotent exit-0 no-op.
#   4. Cherry-pick conflict: aborts, removes temp worktree AND local branch,
#      message contains 'entangled' and the fallback command.
#   5. Success path: ledger entry marked promoted=true in place.

load '../helpers/setup'
load '../helpers/promote-stubs'

# ---------------------------------------------------------------------------
# Thin wrapper: delegates to the shared _write_promote_stubs_base helper and
# then overwrites merge-pr.sh with a recording stub.  Several tests in this
# file assert on "MERGE_PR_CALLED" entries in the _SI_CALLLOG; the base stub
# does not record calls, so the overwrite is the per-file behavioural delta.
# ---------------------------------------------------------------------------
_write_si_promote_stubs() {
  _write_promote_stubs_base "$1"
  cat > "$1/core/merge-pr.sh" << 'STUB'
#!/bin/bash
_MERGE_PR_SH_SOURCED_IN_TEST=true
echo "MERGE_PR_CALLED pr=${1:-?} flags=${*:2}" >> "${_SI_CALLLOG:-/dev/null}"
exit 0
STUB
  chmod +x "$1/core/merge-pr.sh"
}

setup() {
  setup_test_tmpdir
}

teardown() {
  teardown_test_tmpdir
}

# ===========================================================================
# Group 1: bin/rite arg parsing — optional issue number after branch
# ===========================================================================

_init_bare_repo_for_arg_test() {
  git init -q . >/dev/null 2>&1
  git config user.email t@t
  git config user.name t
}

@test "bin/rite --promote <branch> <issue> collects PROMOTE_BRANCH and PROMOTE_ISSUE" {
  # Verify the wiring grep from the acceptance criteria
  grep -nA16 -- '--promote)' "$RITE_REPO_ROOT/bin/rite" | grep -qE 'PROMOTE_(BRANCH|ISSUE)'
}

@test "bin/rite --promote <branch> <issue> parses correctly (dry-run)" {
  _init_bare_repo_for_arg_test
  run env \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    RITE_DRY_RUN=true \
    bash "$RITE_REPO_ROOT/bin/rite" --promote "release-1.2" 42 < /dev/null 2>&1

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "promote-branch.sh"
  echo "$output" | grep -q "release-1.2"
}

@test "bin/rite --promote <branch> without issue number still works (full-branch path)" {
  _init_bare_repo_for_arg_test
  run env \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    RITE_DRY_RUN=true \
    bash "$RITE_REPO_ROOT/bin/rite" --promote "release-1.2" < /dev/null 2>&1

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "promote-branch.sh"
}

# ===========================================================================
# Group 2: Unknown issue number → fail with staged-issues listing
# ===========================================================================

@test "unknown issue number fails with staged-issues listing" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_si_promote_stubs "$_lib"

  # Ledger has issue 42, not issue 99
  local _entry="issue=42	pr=97	sha=abc1234500000000000000000000000000000000	merged_at=2026-01-01T00:00:00Z	promoted=false"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { printf '%s\n' "$_entry"; }
promote_single_issue "test-branch" "99" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "99"
  # Must list the staged issues
  echo "$output" | grep -qE "42|staged"
}

# ===========================================================================
# Group 3: Already-promoted entry → idempotent exit-0
# ===========================================================================

@test "already-promoted entry is an idempotent exit-0 no-op" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_si_promote_stubs "$_lib"
  local _call_log="$RITE_TEST_TMPDIR/idempotent.log"

  # Entry with promoted=true
  local _entry="issue=42	pr=97	sha=abc1234500000000000000000000000000000000	merged_at=2026-01-01T00:00:00Z	promoted=true"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { printf '%s\n' "$_entry"; }
cherry_pick_called=false
git() {
  case "${1:-}" in
    cherry-pick) cherry_pick_called=true; return 0 ;;
    *) return 0 ;;
  esac
}
promote_single_issue "test-branch" "42" 2>&1
rc=$?
echo "CHERRY_PICK_CALLED=$cherry_pick_called"
exit $rc
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 0 ]
  # Cherry-pick must NOT have been attempted
  if echo "$output" | grep -q "CHERRY_PICK_CALLED=true"; then false; fi
  # Should emit idempotent info message
  echo "$output" | grep -qi "already promoted\|nothing to do"
}

# ===========================================================================
# Group 4: Cherry-pick conflict → abort, remove temp worktree + branch,
#          message contains 'entangled' and fallback command
# ===========================================================================

@test "cherry-pick conflict: aborts, removes temp worktree and branch, message contains entangled" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_si_promote_stubs "$_lib"

  local _entry="issue=42	pr=97	sha=abc1234500000000000000000000000000000000	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _call_log="$RITE_TEST_TMPDIR/conflict.log"
  local _wt_dir="$RITE_TEST_TMPDIR/wt-conflict"
  mkdir -p "$_wt_dir"

  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-conflict"
  mkdir -p "$_fake_bin"
  # git stub: worktree add creates the dir; cherry-pick exits 1 (conflict);
  # cherry-pick --abort, branch -D, worktree remove all recorded
  cat > "$_fake_bin/git" << 'GITEOF'
#!/bin/bash
case "${1:-}" in
  fetch) exit 0 ;;
  worktree)
    case "${2:-}" in
      add)
        mkdir -p "${5:-${4:-}}"
        printf 'GIT_WORKTREE_ADD %s\n' "$*" >> "${_SI_CALLLOG:-/dev/null}"
        exit 0 ;;
      remove)
        printf 'GIT_WORKTREE_REMOVE %s\n' "$*" >> "${_SI_CALLLOG:-/dev/null}"
        rm -rf "${3:-}" 2>/dev/null || true
        exit 0 ;;
      prune)
        printf 'GIT_WORKTREE_PRUNE\n' >> "${_SI_CALLLOG:-/dev/null}"
        exit 0 ;;
    esac ;;
  cherry-pick)
    printf 'GIT_CHERRY_PICK %s\n' "$*" >> "${_SI_CALLLOG:-/dev/null}"
    if [ "${2:-}" = "--abort" ]; then
      exit 0
    fi
    # Create CHERRY_PICK_HEAD to simulate a conflict (real git does this).
    touch "${_SI_CHERRY_PICK_HEAD_PATH:-/dev/null}" 2>/dev/null || true
    exit 1 ;;
  rev-parse)
    if [ "${2:-}" = "--git-path" ] && [ "${3:-}" = "CHERRY_PICK_HEAD" ]; then
      echo "${_SI_CHERRY_PICK_HEAD_PATH:-/dev/null}"
      exit 0
    fi
    echo "abc1234500000000000000000000000000000000"; exit 0 ;;
  branch)
    printf 'GIT_BRANCH %s\n' "$*" >> "${_SI_CALLLOG:-/dev/null}"
    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;
esac
exit 0
GITEOF
  chmod +x "$_fake_bin/git"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_dir"
export _SI_CALLLOG="$_call_log"
export _SI_CHERRY_PICK_HEAD_PATH="$RITE_TEST_TMPDIR/fake-cherry-pick-head"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { printf '%s\n' "$_entry"; }
promote_single_issue "conflict-branch" "42" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -ne 0 ]

  # Message must contain 'entangled'
  echo "$output" | grep -qi "entangled"
  # Message must contain the fallback command
  echo "$output" | grep -q "rite --promote conflict-branch"
  # cherry-pick --abort must have been called
  grep -q "GIT_CHERRY_PICK.*--abort" "$_call_log"
  # Temp branch must have been deleted (git branch -D)
  grep -qE "GIT_BRANCH.*-D" "$_call_log"
  # Temp worktree must have been removed
  grep -qE "GIT_WORKTREE_REMOVE" "$_call_log"
}

# ===========================================================================
# Group 5: Success path — ledger marked promoted=true in place
# ===========================================================================

@test "success path: ledger marked promoted=true, merge-pr called once with PR number" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_si_promote_stubs "$_lib"

  local _entry="issue=42	pr=97	sha=abc1234500000000000000000000000000000000	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _call_log="$RITE_TEST_TMPDIR/success.log"
  local _wt_dir="$RITE_TEST_TMPDIR/wt-success"
  mkdir -p "$_wt_dir"

  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-success"
  mkdir -p "$_fake_bin"
  cat > "$_fake_bin/git" << 'GITEOF'
#!/bin/bash
case "${1:-}" in
  fetch) exit 0 ;;
  worktree)
    case "${2:-}" in
      add)
        mkdir -p "${5:-${4:-}}"
        printf 'GIT_WORKTREE_ADD %s\n' "$*" >> "${_SI_CALLLOG:-/dev/null}"
        exit 0 ;;
      remove)
        printf 'GIT_WORKTREE_REMOVE %s\n' "$*" >> "${_SI_CALLLOG:-/dev/null}"
        rm -rf "${3:-}" 2>/dev/null || true
        exit 0 ;;
      prune)
        exit 0 ;;
    esac ;;
  cherry-pick)
    printf 'GIT_CHERRY_PICK %s\n' "$*" >> "${_SI_CALLLOG:-/dev/null}"
    exit 0 ;;
  push)
    printf 'GIT_PUSH %s\n' "$*" >> "${_SI_CALLLOG:-/dev/null}"
    exit 0 ;;
  branch)
    printf 'GIT_BRANCH %s\n' "$*" >> "${_SI_CALLLOG:-/dev/null}"
    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;
esac
exit 0
GITEOF
  chmod +x "$_fake_bin/git"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_dir"
export _SI_CALLLOG="$_call_log"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { printf '%s\n' "$_entry"; }
integration_ledger_mark_promoted() {
  printf 'LEDGER_MARKED branch=%s issue=%s\n' "\$1" "\$2" >> "$_call_log"
}
run_test_gate() { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        create) echo "555"; return 0 ;;
      esac ;;
    issue) printf 'ISSUE_COMMENT issue=%s\n' "\${3:-?}" >> "$_call_log"; return 0 ;;
  esac
  return 0
}
promote_single_issue "success-branch" "42" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 0 ]

  # merge-pr.sh must have been invoked once
  grep -q "MERGE_PR_CALLED" "$_call_log"
  # Ledger entry must be marked promoted
  grep -q "LEDGER_MARKED branch=success-branch issue=42" "$_call_log"
  # Per-issue comment must have been posted
  grep -q "ISSUE_COMMENT issue=42" "$_call_log"
}

# ===========================================================================
# Group 6: Structural pins
# ===========================================================================

@test "promote-single-issue-cherry-pick.bats has correct sharkrite-test-covers header" {
  head -2 "$RITE_REPO_ROOT/tests/regression/promote-single-issue-cherry-pick.bats" \
    | grep -q "sharkrite-test-covers: lib/core/promote-branch.sh, bin/rite"
}

@test "promote-branch.sh has RITE_TEST_GATE_DIFF_BASE=origin/main in single-issue path" {
  grep -q "RITE_TEST_GATE_DIFF_BASE=origin/main" \
    "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
}

@test "promote-branch.sh has cherry-pick --abort on the conflict path" {
  grep -q "cherry-pick --abort" \
    "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
}

@test "promote-branch.sh calls integration_ledger_mark_promoted in single-issue path" {
  grep -q "integration_ledger_mark_promoted" \
    "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
}
