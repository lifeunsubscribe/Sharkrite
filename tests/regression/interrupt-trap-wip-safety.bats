#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Regression: the interrupt handler (cleanup_on_interrupt) must never auto-commit
# and PUSH work-in-progress onto a shared default branch, and the trap must not
# arm when the file is merely sourced for its functions.
#
# Live incident 2026-06-24: a test sourced claude-workflow.sh under
# RITE_SOURCE_FUNCTIONS_ONLY=1; the file armed `trap cleanup_on_interrupt TERM`
# unconditionally; gtimeout then killed the (hung) subshell while it was on
# `main`; the trap ran `git add -A && git commit -m "WIP…" && git push` and
# pushed unfinished work to origin/main. Two guards prevent recurrence:
#   1. _wip_commit_allowed: WIP auto-commit/push is for feature branches only —
#      never main/master/detached HEAD.
#   2. the INT/TERM/HUP trap is armed only for real execution, not when sourced
#      with RITE_SOURCE_FUNCTIONS_ONLY=1.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  WF="${RITE_LIB_DIR}/core/claude-workflow.sh"
}

# Source functions-only in a clean subshell and run a snippet.
_in_wf() {
  run env RITE_LIB_DIR="$RITE_LIB_DIR" RITE_SOURCE_FUNCTIONS_ONLY=1 \
    bash -c 'source "$RITE_LIB_DIR/core/claude-workflow.sh"; '"$1" </dev/null
}

# ---------------------------------------------------------------------------
# _wip_commit_allowed — feature branches only
# ---------------------------------------------------------------------------

@test "_wip_commit_allowed: rejects main" {
  _in_wf '_wip_commit_allowed main && echo ALLOW || echo DENY'
  [ "$status" -eq 0 ]
  [ "$output" = "DENY" ]
}

@test "_wip_commit_allowed: rejects master" {
  _in_wf '_wip_commit_allowed master && echo ALLOW || echo DENY'
  [ "$output" = "DENY" ]
}

@test "_wip_commit_allowed: rejects empty branch (detached HEAD)" {
  _in_wf '_wip_commit_allowed "" && echo ALLOW || echo DENY'
  [ "$output" = "DENY" ]
}

@test "_wip_commit_allowed: allows a feature branch" {
  _in_wf '_wip_commit_allowed feat/add-thing-123 && echo ALLOW || echo DENY'
  [ "$output" = "ALLOW" ]
}

@test "_wip_commit_allowed: allows a fix/ branch" {
  _in_wf '_wip_commit_allowed fix/699-regression && echo ALLOW || echo DENY'
  [ "$output" = "ALLOW" ]
}

# ---------------------------------------------------------------------------
# Trap arming
# ---------------------------------------------------------------------------

@test "interrupt trap is NOT armed when sourced functions-only" {
  _in_wf 'trap -p TERM INT HUP'
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "cleanup_on_interrupt"
}

@test "structural: the trap arming is guarded by RITE_SOURCE_FUNCTIONS_ONLY" {
  # The `trap cleanup_on_interrupt` line must sit inside a
  # RITE_SOURCE_FUNCTIONS_ONLY != 1 guard (within ~6 lines above it).
  _trap_line=$(grep -n 'trap cleanup_on_interrupt' "$WF" | head -1 | cut -d: -f1)
  [ -n "$_trap_line" ]
  _guard_window=$(sed -n "$((_trap_line - 6)),${_trap_line}p" "$WF")
  echo "$_guard_window" | grep -q 'RITE_SOURCE_FUNCTIONS_ONLY'
}

# ---------------------------------------------------------------------------
# Structural: cleanup_on_interrupt gates the WIP commit on _wip_commit_allowed
# ---------------------------------------------------------------------------

@test "structural: cleanup_on_interrupt checks _wip_commit_allowed before committing" {
  _fn=$(awk '/^cleanup_on_interrupt[(][)] \{/{f=1} f{print} f&&/^}/{exit}' "$WF")
  _guard_line=$(printf '%s\n' "$_fn" | grep -n '_wip_commit_allowed' | head -1 | cut -d: -f1)
  _commit_line=$(printf '%s\n' "$_fn" | grep -n 'git commit -m' | head -1 | cut -d: -f1)
  [ -n "$_guard_line" ]
  [ -n "$_commit_line" ]
  [ "$_guard_line" -lt "$_commit_line" ]
}

# ---------------------------------------------------------------------------
# Consolidated salvage prompt (#1128): n aborts, y commits+pushes together,
# e edits message before committing. Behavioral tests run cleanup_on_interrupt
# in a real git feature-branch worktree with piped stdin.
# ---------------------------------------------------------------------------

# Set up a minimal git repo on a feature branch with one uncommitted file.
# Returns repo path in $BATS_TEST_TMPDIR/wip-repo.
_setup_wip_repo() {
  local _repo="$BATS_TEST_TMPDIR/wip-repo"
  mkdir -p "$_repo"
  (
    cd "$_repo"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    # Initial commit on main so we can branch
    echo "init" > init.txt
    git add init.txt
    git commit -q -m "init"
    git checkout -q -b feat/test-wip
    # Uncommitted change
    echo "wip" > wip.txt
  )
  echo "$_repo"
}

# Call cleanup_on_interrupt in the wip repo with given stdin.
# Args: $1 = stdin string, $2 = repo path
_run_salvage() {
  local _stdin="$1"
  local _repo="$2"
  run env \
    RITE_LIB_DIR="$RITE_LIB_DIR" \
    RITE_SOURCE_FUNCTIONS_ONLY=1 \
    RITE_LOG_FILE=/dev/null \
    bash -c "
      cd '$_repo'
      source \"\$RITE_LIB_DIR/core/claude-workflow.sh\"
      AUTO_MODE=false
      cleanup_on_interrupt
    " <<< "$_stdin"
}

@test "salvage n: no commit created" {
  _repo=$(_setup_wip_repo)
  _run_salvage "n" "$_repo"
  [ "$status" -eq 0 ]
  # No commits beyond the initial one
  _count=$(git -C "$_repo" log --oneline feat/test-wip | wc -l | tr -d ' ')
  [ "$_count" -eq 1 ]
}

@test "salvage y: creates a commit" {
  _repo=$(_setup_wip_repo)
  _run_salvage "y" "$_repo"
  [ "$status" -eq 0 ]
  # A WIP commit was created (push may fail without remote — that's ok)
  _last=$(git -C "$_repo" log --oneline feat/test-wip | head -1)
  echo "$_last" | grep -q "WIP:"
}

@test "salvage e then y: commits with edited message" {
  _repo=$(_setup_wip_repo)
  # e = edit, custom message, then y to confirm
  _run_salvage $'e\ncustom wip message\ny' "$_repo"
  [ "$status" -eq 0 ]
  _last=$(git -C "$_repo" log --oneline feat/test-wip | head -1)
  echo "$_last" | grep -q "custom wip message"
}

@test "salvage e with empty edit keeps original WIP message" {
  _repo=$(_setup_wip_repo)
  # e = edit with empty message (keep original), then y
  _run_salvage $'e\n\ny' "$_repo"
  [ "$status" -eq 0 ]
  _last=$(git -C "$_repo" log --oneline feat/test-wip | head -1)
  echo "$_last" | grep -q "WIP:"
}
