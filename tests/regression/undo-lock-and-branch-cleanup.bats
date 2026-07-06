#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/undo-workflow.sh
# Regression: `rite --undo N` must comprehensively clean its artifacts.
#
# Live gaps (#649): after `rite --undo 649`, two orphans survived —
#   1. the per-issue lock dir .rite/locks/issue-649.lock (undo's state-cleanup
#      block was gated on SESSION_STATE_EXISTS, but a run that dies early leaves
#      the lock with NO session-state file), and
#   2. the remote branch (the delete swallowed errors with `2>/dev/null` and
#      reported "already deleted or not found" while the branch still existed).
#
# undo-workflow.sh is a top-level script (runs on source), so these mirror the
# existing snippet-extraction pattern (see undo-workflow-bash-3-2-compat.bats)
# plus structural assertions that tie the behaviour to the real source.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"; export RITE_REPO_ROOT
  TEST_DIR="${BATS_TEST_TMPDIR}/undo-cleanup"; mkdir -p "$TEST_DIR"; export TEST_DIR
}
teardown() { rm -rf "$TEST_DIR"; }

@test "undo removes the issue lock dir even with NO session-state file (#649)" {
  # Reproduces the section-3.6 cleanup decision: the lock is cleaned when present,
  # independent of SESSION_STATE_EXISTS.
  run bash -c '
    set -euo pipefail
    ISSUE_NUMBER=649
    SESSION_STATE_EXISTS=false                       # run died early — no state file
    RITE_LOCK_DIR="'"$TEST_DIR"'/locks"
    _undo_lock_dir="${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock"
    mkdir -p "$_undo_lock_dir"; echo 12345 > "$_undo_lock_dir/pid"   # orphan lock

    if [ "$SESSION_STATE_EXISTS" = true ] || [ -d "$_undo_lock_dir" ]; then
      if [ -d "$_undo_lock_dir" ]; then rm -rf "$_undo_lock_dir"; fi
    fi

    [ -d "$_undo_lock_dir" ] && { echo "FAIL: lock survived"; exit 1; }
    echo "OK"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "undo source: lock cleanup is reachable when session state is absent" {
  # Guard against a regression that re-gates the lock removal solely under the
  # session-state-file check (the original #649 gap).
  run grep -E 'SESSION_STATE_EXISTS" = true \] \|\| \[ -d "\$_undo_lock_dir"' \
    "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
  run grep -E 'rm -rf "\$_undo_lock_dir"' "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
}

@test "undo source: remote-branch delete verifies the result (no silent swallow)" {
  # The delete must re-check existence and warn loudly on failure, not report
  # "already deleted" while the branch survives.
  run grep -E 'git ls-remote --heads origin "\$BRANCH_NAME"' \
    "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
  run grep -E 'Failed to delete remote branch' "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
}

@test "undo excludes the issue being undone from FOLLOWUP_ISSUES (never closes the main issue)" {
  # Reproduces the section-1.2 filter. The main issue must never be swept into
  # the follow-up close loop — that would close it, and undo must leave the issue
  # OPEN so it can be re-run from scratch (live incident: `rite --undo 821`
  # closed #821, so the next batch skipped it as already-closed).
  run bash -c '
    set -euo pipefail
    ISSUE_NUMBER=821
    FOLLOWUP_ISSUES=(821 900 901)   # main issue erroneously swept in with real follow-ups

    if [ ${#FOLLOWUP_ISSUES[@]} -gt 0 ]; then
      _fu_kept=()
      for _fu in "${FOLLOWUP_ISSUES[@]}"; do
        [ "$_fu" = "$ISSUE_NUMBER" ] && continue
        _fu_kept+=("$_fu")
      done
      FOLLOWUP_ISSUES=("${_fu_kept[@]+"${_fu_kept[@]}"}")
    fi
    printf "%s\n" "${FOLLOWUP_ISSUES[@]+"${FOLLOWUP_ISSUES[@]}"}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"821"* ]] || { echo "FAIL: main issue 821 still in FOLLOWUP_ISSUES"; false; }
  { [[ "$output" == *"900"* ]] && [[ "$output" == *"901"* ]]; } || { echo "FAIL: real follow-ups dropped: $output"; false; }
}

@test "undo FOLLOWUP_ISSUES filter is bash-3.2 safe when it empties the array" {
  # If the only follow-up candidate IS the main issue, the filter empties the
  # array; the "${arr[@]+...}" idiom must not trip set -u on bash 3.2.
  run bash -c '
    set -euo pipefail
    ISSUE_NUMBER=821
    FOLLOWUP_ISSUES=(821)

    if [ ${#FOLLOWUP_ISSUES[@]} -gt 0 ]; then
      _fu_kept=()
      for _fu in "${FOLLOWUP_ISSUES[@]}"; do
        [ "$_fu" = "$ISSUE_NUMBER" ] && continue
        _fu_kept+=("$_fu")
      done
      FOLLOWUP_ISSUES=("${_fu_kept[@]+"${_fu_kept[@]}"}")
    fi
    echo "count=${#FOLLOWUP_ISSUES[@]}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"count=0"* ]]
}

@test "undo source: the issue being undone is filtered out of FOLLOWUP_ISSUES" {
  # Structural guard tying the behaviour above to the real source.
  run grep -E '\[ "\$_fu" = "\$ISSUE_NUMBER" \] && continue' \
    "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Empty container dir cleanup after worktree removal (#972)
# ---------------------------------------------------------------------------

@test "undo: rmdir empty container dir after worktree removal" {
  # Behavioural fixture test: after removing the worktree, its now-empty parent
  # container dir (which is inside RITE_WORKTREE_DIR) must be removed.
  run bash -c '
    set -euo pipefail
    RITE_WORKTREE_DIR="'"$TEST_DIR"'/sh-wt"
    container="${RITE_WORKTREE_DIR}"
    wt_path="${container}/issue-972-fix"

    mkdir -p "$wt_path"                        # simulate an existing worktree dir
    rm -rf "$wt_path"                          # simulate git worktree remove

    # Apply the cleanup logic from undo-workflow.sh
    _wt_container=$(dirname "$wt_path")
    case "$_wt_container" in "$RITE_WORKTREE_DIR"*)
      rmdir "$_wt_container" 2>/dev/null || true ;;
    esac

    [ -d "$container" ] && { echo "FAIL: empty container survived"; exit 1; }
    echo "OK"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "undo: non-empty container dir is NOT removed after worktree removal" {
  # Guard: rmdir silently fails when the container still has sibling worktrees.
  run bash -c '
    set -euo pipefail
    RITE_WORKTREE_DIR="'"$TEST_DIR"'/sh-wt"
    container="${RITE_WORKTREE_DIR}"
    wt_path="${container}/issue-972-fix"
    sibling="${container}/issue-100-sibling"   # another worktree still present

    mkdir -p "$wt_path" "$sibling"
    rm -rf "$wt_path"                          # simulate git worktree remove

    _wt_container=$(dirname "$wt_path")
    case "$_wt_container" in "$RITE_WORKTREE_DIR"*)
      rmdir "$_wt_container" 2>/dev/null || true ;;
    esac

    [ -d "$container" ] || { echo "FAIL: non-empty container was removed"; exit 1; }
    echo "OK"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "undo source: rmdir empty container pattern present after git worktree remove" {
  # Structural pin: the rmdir guard must appear after the worktree remove in the source.
  local src="${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  local remove_line rmdir_line
  remove_line=$(grep -n "git worktree remove.*WORKTREE_PATH.*--force" "$src" | head -1 | cut -d: -f1)
  rmdir_line=$(grep -n 'rmdir.*_wt_container.*2>/dev/null' "$src" | head -1 | cut -d: -f1)
  [ -n "$remove_line" ] || { echo "FAIL: git worktree remove not found in undo-workflow.sh"; return 1; }
  [ -n "$rmdir_line" ]  || { echo "FAIL: rmdir guard not found in undo-workflow.sh"; return 1; }
  [ "$rmdir_line" -gt "$remove_line" ] || {
    echo "FAIL: rmdir (line $rmdir_line) must come after git worktree remove (line $remove_line)"
    return 1
  }
}
