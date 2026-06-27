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
