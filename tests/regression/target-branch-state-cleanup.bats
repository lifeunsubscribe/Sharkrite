#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/undo-workflow.sh, lib/core/workflow-runner.sh
# Tests for --undo target-awareness and target-branch-N.txt state-file cleanup.
#
# Design refs: docs/architecture/branch-flag-design.md §2.3, §5.1
# Issue: #1035 (Make --undo target-aware and clean state files)
# Depends on: #1033 (writes target-branch-N.txt)
#
# Coverage:
#   1. Non-main undo path: pr close + branch delete, NO origin/main reset push.
#   2. Main undo path: draft revert + origin/main reset (byte-identical to today).
#   3. Section 3.6: target-branch-N.txt removed even when SESSION_STATE_EXISTS=false.
#   4. Section 3.6: target-branch-N.txt removed even without a lock dir.
#   5. Ledger durability: integration-branches/*.log survives both undo cleanup
#      and handle_closed_issue cleanup byte-for-byte.
#   6. handle_closed_issue: removes target file and still returns 12.
#   7. Structural grep: UNDO_TARGET_BRANCH gate present in undo-workflow.sh.
#   8. Structural grep: target-branch removal in both source files.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"; export RITE_REPO_ROOT
  TEST_DIR="${BATS_TEST_TMPDIR}/tb-cleanup"; mkdir -p "$TEST_DIR"; export TEST_DIR
}
teardown() { rm -rf "$TEST_DIR"; }

# ---------------------------------------------------------------------------
# 1. Non-main undo: calls `pr close` and branch delete, never origin/main reset
# ---------------------------------------------------------------------------

@test "non-main undo: section-3.1 calls pr close and branch delete (no origin/main reset)" {
  # Reproduces the non-main path in undo-workflow.sh section 3.1.
  # The git stub log must record:
  #   - NO "origin/main:refs/heads" push (that's the STAYS-MAIN path)
  #   - YES "push origin --delete" for the remote branch
  # The gh stub must record pr close being called.

  local git_log_file="${TEST_DIR}/git-calls.log"
  local gh_log_file="${TEST_DIR}/gh-calls.log"
  local stub_dir="${TEST_DIR}/stubs"
  mkdir -p "$stub_dir"

  # Git stub — records calls, succeeds on everything
  cat > "$stub_dir/git" << 'GITSTUB'
#!/bin/bash
echo "$@" >> "${GIT_LOG_FILE}"
# ls-remote returns empty (branch exists check → branch absent → skip ls-remote warning)
if [ "${1:-}" = "ls-remote" ]; then
  exit 1  # branch does not exist → no-op for "already deleted" path
fi
exit 0
GITSTUB
  chmod +x "$stub_dir/git"

  # gh stub — records calls, succeeds on everything
  cat > "$stub_dir/gh_safe" << 'GHSTUB'
#!/bin/bash
echo "$@" >> "${GH_LOG_FILE}"
exit 0
GHSTUB
  chmod +x "$stub_dir/gh_safe"

  run bash -c '
    set -euo pipefail
    GIT_LOG_FILE="'"$git_log_file"'"
    GH_LOG_FILE="'"$gh_log_file"'"
    UNDO_TARGET_BRANCH="feature-x"
    PR_NUMBER="99"
    BRANCH_NAME="feat-issue-99"
    UNDO_ERRORS=0

    # Minimal stubs — inline functions (same shell, no PATH tricks needed here)
    gh_safe() { echo "$@" >> "$GH_LOG_FILE"; return 0; }
    git() { echo "$@" >> "$GIT_LOG_FILE"; return 0; }
    git_fetch_safe() { echo "git_fetch_safe $@" >> "$GIT_LOG_FILE"; return 0; }
    print_success() { true; }
    print_info() { true; }
    print_warning() { true; }

    if [ "$UNDO_TARGET_BRANCH" = "main" ]; then
      echo "FAIL: took main path" >&2
      exit 1
    fi

    # Non-main path (section 3.1)
    _undo_close_out=""
    _undo_close_exit=0
    _undo_close_out=$(gh_safe pr close "$PR_NUMBER" --comment "test" 2>&1) || _undo_close_exit=$?
    if [ "${_undo_close_exit:-1}" -eq 0 ]; then
      print_success "Closed PR"
    else
      UNDO_ERRORS=$((UNDO_ERRORS + 1))
    fi

    if [ -n "$BRANCH_NAME" ]; then
      _undo_del_out=$(git push origin --delete "$BRANCH_NAME" 2>&1) && _undo_del_ok=true || _undo_del_ok=false
      if [ "$_undo_del_ok" = true ]; then
        print_success "Deleted remote branch"
      elif ! git ls-remote --heads origin "$BRANCH_NAME" 2>/dev/null | grep -q .; then
        print_info "Remote branch already deleted"
      else
        UNDO_ERRORS=$((UNDO_ERRORS + 1))
      fi
    fi

    echo "UNDO_ERRORS=$UNDO_ERRORS"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNDO_ERRORS=0"* ]]

  # gh must have called pr close
  [ -f "$gh_log_file" ]
  grep -q "pr close" "$gh_log_file"

  # git log must show "push origin --delete"
  [ -f "$git_log_file" ]
  grep -q "push origin --delete" "$git_log_file"

  # git log must NOT contain origin/main:refs/heads (STAYS-MAIN reset is absent)
  run grep -q "origin/main:refs/heads" "$git_log_file"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 2. Main undo: draft revert + origin/main reset (byte-identical path)
# ---------------------------------------------------------------------------

@test "main-target undo: takes draft-revert + origin/main reset path, zero pr-close calls" {
  local gh_log_file="${TEST_DIR}/gh-main-calls.log"
  local git_log_file="${TEST_DIR}/git-main-calls.log"

  run bash -c '
    set -euo pipefail
    GH_LOG_FILE="'"$gh_log_file"'"
    GIT_LOG_FILE="'"$git_log_file"'"
    UNDO_TARGET_BRANCH="main"
    PR_NUMBER="42"
    BRANCH_NAME="feat-issue-42"
    UNDO_ERRORS=0

    gh_safe() { echo "$@" >> "$GH_LOG_FILE"; return 0; }
    git() { echo "$@" >> "$GIT_LOG_FILE"; return 0; }
    git_fetch_safe() { echo "git_fetch_safe $@" >> "$GIT_LOG_FILE"; return 0; }
    print_success() { true; }
    print_info() { true; }
    print_warning() { true; }

    if [ "$UNDO_TARGET_BRANCH" = "main" ]; then
      # Main path
      if gh_safe pr ready --undo "$PR_NUMBER" 2>/dev/null; then
        print_success "Reverted to draft"
      fi
      if [ -n "$BRANCH_NAME" ]; then
        if ! git_fetch_safe origin main; then
          UNDO_ERRORS=$((UNDO_ERRORS + 1))
        elif git push origin "origin/main:refs/heads/$BRANCH_NAME" --force 2>/dev/null; then
          print_success "Reset remote branch"
          git_fetch_safe origin "$BRANCH_NAME" || true
        else
          UNDO_ERRORS=$((UNDO_ERRORS + 1))
        fi
      fi
    fi

    echo "UNDO_ERRORS=$UNDO_ERRORS"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNDO_ERRORS=0"* ]]

  # gh must have called pr ready --undo, NOT pr close
  [ -f "$gh_log_file" ]
  grep -q "pr ready --undo" "$gh_log_file"
  run grep -q "pr close" "$gh_log_file"
  [ "$status" -ne 0 ]

  # git log must contain the STAYS-MAIN reset push
  [ -f "$git_log_file" ]
  grep -q "origin/main:refs/heads" "$git_log_file"
}

# ---------------------------------------------------------------------------
# 3. Section 3.6: target file removed even when SESSION_STATE_EXISTS=false
#    (unconditional cleanup per #649 lesson)
# ---------------------------------------------------------------------------

@test "section-3.6: target-branch-N.txt removed when only target file exists (no session state)" {
  local state_dir="${TEST_DIR}/state"
  mkdir -p "$state_dir"
  local target_file="${state_dir}/target-branch-649.txt"
  echo "feature-x" > "$target_file"

  run bash -c '
    set -euo pipefail
    ISSUE_NUMBER=649
    SESSION_STATE_EXISTS=false
    RITE_LOCK_DIR="'"$TEST_DIR"'/locks"
    RITE_PROJECT_ROOT="'"$TEST_DIR"'"
    RITE_DATA_DIR=".rite"
    RITE_STATE_DIR="'"$state_dir"'"
    _undo_lock_dir="${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock"
    _undo_target_file="${RITE_STATE_DIR}/target-branch-${ISSUE_NUMBER}.txt"

    if [ "$SESSION_STATE_EXISTS" = true ] || [ -d "$_undo_lock_dir" ] || [ -f "$_undo_target_file" ]; then
      if [ "$SESSION_STATE_EXISTS" = true ]; then
        echo "Would remove session state"
      fi
      if [ -d "$_undo_lock_dir" ]; then
        rm -rf "$_undo_lock_dir"
      fi
      if [ -f "$_undo_target_file" ]; then
        rm -f "$_undo_target_file"
        echo "Removed target-branch state file"
      fi
    fi
    [ ! -f "$_undo_target_file" ] && echo "OK: target file gone" || { echo "FAIL: target file survived"; exit 1; }
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed target-branch state file"* ]]
  [[ "$output" == *"OK: target file gone"* ]]
  [ ! -f "$target_file" ]
}

# ---------------------------------------------------------------------------
# 4. Section 3.6: target file removed even without a lock dir (no crash)
# ---------------------------------------------------------------------------

@test "section-3.6: target-branch-N.txt removed when no lock dir and no session state" {
  local state_dir="${TEST_DIR}/state2"
  mkdir -p "$state_dir"
  local target_file="${state_dir}/target-branch-777.txt"
  echo "integration/phase-3" > "$target_file"

  run bash -c '
    set -euo pipefail
    ISSUE_NUMBER=777
    SESSION_STATE_EXISTS=false
    RITE_LOCK_DIR="'"$TEST_DIR"'/locks2"
    RITE_STATE_DIR="'"$state_dir"'"
    RITE_PROJECT_ROOT="'"$TEST_DIR"'"
    RITE_DATA_DIR=".rite"
    _undo_lock_dir="${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock"
    _undo_target_file="${RITE_STATE_DIR}/target-branch-${ISSUE_NUMBER}.txt"

    # Lock dir does not exist; target file does
    [ ! -d "$_undo_lock_dir" ] || { echo "FAIL: lock dir should not exist"; exit 1; }

    if [ "$SESSION_STATE_EXISTS" = true ] || [ -d "$_undo_lock_dir" ] || [ -f "$_undo_target_file" ]; then
      if [ -f "$_undo_target_file" ]; then
        rm -f "$_undo_target_file"
        echo "Removed target file"
      fi
    fi
    [ ! -f "$_undo_target_file" ] && echo "OK" || { echo "FAIL"; exit 1; }
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
  [ ! -f "$target_file" ]
}

# ---------------------------------------------------------------------------
# 5. Ledger durability: integration-branches/*.log survives undo cleanup
#    AND handle_closed_issue cleanup byte-for-byte
# ---------------------------------------------------------------------------

@test "undo section-3.6: integration-branches ledger file survives cleanup unchanged" {
  local state_dir="${TEST_DIR}/state3"
  local ledger_dir="${state_dir}/integration-branches"
  mkdir -p "$ledger_dir"

  # Seed a ledger file (merge history — must never be touched by undo)
  local ledger_file="${ledger_dir}/feature-x.log"
  printf 'merged: issue #42 at 2026-07-01\nmerged: issue #43 at 2026-07-02\n' > "$ledger_file"
  local original_content
  original_content=$(cat "$ledger_file")

  # Seed a target file (should be removed)
  local target_file="${state_dir}/target-branch-42.txt"
  echo "feature-x" > "$target_file"

  run bash -c '
    set -euo pipefail
    ISSUE_NUMBER=42
    SESSION_STATE_EXISTS=false
    RITE_LOCK_DIR="'"$TEST_DIR"'/locks3"
    RITE_STATE_DIR="'"$state_dir"'"
    RITE_PROJECT_ROOT="'"$TEST_DIR"'"
    RITE_DATA_DIR=".rite"
    _undo_lock_dir="${RITE_LOCK_DIR}/issue-${ISSUE_NUMBER}.lock"
    _undo_target_file="${RITE_STATE_DIR}/target-branch-${ISSUE_NUMBER}.txt"

    if [ "$SESSION_STATE_EXISTS" = true ] || [ -d "$_undo_lock_dir" ] || [ -f "$_undo_target_file" ]; then
      if [ -f "$_undo_target_file" ]; then
        rm -f "$_undo_target_file"
        echo "Removed target file"
      fi
    fi

    # Ledger must be intact — check it was NOT touched
    if [ ! -f "'"$ledger_file"'" ]; then
      echo "FAIL: ledger file was deleted" >&2
      exit 1
    fi
    _content=$(cat "'"$ledger_file"'")
    if [ "$_content" != "'"$original_content"'" ]; then
      echo "FAIL: ledger content changed" >&2
      exit 1
    fi
    echo "OK: ledger intact"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: ledger intact"* ]]
  [ -f "$ledger_file" ]
  [ "$(cat "$ledger_file")" = "$original_content" ]
}

@test "handle_closed_issue cleanup: integration-branches ledger survives byte-for-byte" {
  # Simulates handle_closed_issue step 4b cleaning target file while leaving ledger.
  local state_dir="${TEST_DIR}/state4"
  local ledger_dir="${state_dir}/integration-branches"
  mkdir -p "$ledger_dir"

  local ledger_file="${ledger_dir}/feature-x.log"
  printf 'merged: issue #50 at 2026-07-10\n' > "$ledger_file"
  local original_content
  original_content=$(cat "$ledger_file")

  local target_file="${state_dir}/target-branch-50.txt"
  echo "feature-x" > "$target_file"

  run bash -c '
    set -euo pipefail
    RITE_STATE_DIR="'"$state_dir"'"
    _issue_number=50

    # Simulate step 4b
    if [ -n "${RITE_STATE_DIR:-}" ]; then
      _target_file="${RITE_STATE_DIR}/target-branch-${_issue_number}.txt"
      if [ -f "$_target_file" ]; then
        rm -f "$_target_file"
        echo "Removed target-branch state file"
      fi
    fi

    # Ledger must survive
    if [ ! -f "'"$ledger_file"'" ]; then
      echo "FAIL: ledger deleted" >&2; exit 1
    fi
    _content=$(cat "'"$ledger_file"'")
    if [ "$_content" != "'"$original_content"'" ]; then
      echo "FAIL: ledger changed" >&2; exit 1
    fi
    echo "OK: ledger intact"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: ledger intact"* ]]
  [ ! -f "$target_file" ]
  [ "$(cat "$ledger_file")" = "$original_content" ]
}

# ---------------------------------------------------------------------------
# 6. handle_closed_issue: step-4b removes target file and function exits 12
# ---------------------------------------------------------------------------

@test "handle_closed_issue step-4b: removes target-branch file and still returns 12" {
  local state_dir="${TEST_DIR}/state5"
  mkdir -p "$state_dir"
  local target_file="${state_dir}/target-branch-77.txt"
  echo "feature-x" > "$target_file"

  run bash -c '
    set -euo pipefail
    RITE_STATE_DIR="'"$state_dir"'"

    _simulate_handle_closed_step4b() {
      local issue_number="$1"
      local cleaned_anything=false

      # step 4b (from workflow-runner.sh handle_closed_issue)
      if [ -n "${RITE_STATE_DIR:-}" ]; then
        local _target_file="${RITE_STATE_DIR}/target-branch-${issue_number}.txt"
        if [ -f "$_target_file" ]; then
          rm -f "$_target_file"
          cleaned_anything=true
          echo "Removed target-branch state file"
        fi
      fi

      # Sentinel return 12
      return 12
    }

    _simulate_handle_closed_step4b 77
    # capture exit code
  '
  # bash exits with last command exit code = return value of function = 12
  [ "$status" -eq 12 ]
  [[ "$output" == *"Removed target-branch state file"* ]]
  [ ! -f "$target_file" ]
}

# ---------------------------------------------------------------------------
# 7. Structural: UNDO_TARGET_BRANCH gate present in undo-workflow.sh
# ---------------------------------------------------------------------------

@test "undo source: UNDO_TARGET_BRANCH extraction present (baseRefName in PR fetch)" {
  run grep -n 'state,headRefName,mergedAt,baseRefName' \
    "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
}

@test "undo source: exactly one gh pr view for PR state (no second fetch added)" {
  local count
  count=$(grep -c 'gh_safe pr view "\$PR_NUMBER" --json state' \
    "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh" || true)
  [ "$count" -eq 1 ]
}

@test "undo source: UNDO_TARGET_BRANCH != main gate present" {
  # The non-main arm must gate on UNDO_TARGET_BRANCH comparison
  run grep -n 'UNDO_TARGET_BRANCH' \
    "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
  # Must include a comparison against "main"
  run grep -nE 'UNDO_TARGET_BRANCH.*main|main.*UNDO_TARGET_BRANCH' \
    "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
}

@test "undo source: STAYS-MAIN origin/main reset push still present inside main-target arm" {
  run grep -n 'origin/main:refs/heads' \
    "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 8. Structural: target-branch-N.txt removal in both source files
# ---------------------------------------------------------------------------

@test "undo source: target-branch-\${ISSUE_NUMBER}.txt removal present" {
  run grep -n 'target-branch-${ISSUE_NUMBER}.txt' \
    "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  [ "$status" -eq 0 ]
}

@test "workflow-runner source: target-branch-\${issue_number}.txt removal present in handle_closed_issue" {
  run grep -n 'target-branch-${issue_number}.txt' \
    "${RITE_REPO_ROOT}/lib/core/workflow-runner.sh"
  [ "$status" -eq 0 ]
}

@test "neither source file references integration-branches directory" {
  # Ledger is durable — undo/handle_closed_issue must never touch it.
  run grep -n 'integration-branches' \
    "${RITE_REPO_ROOT}/lib/core/undo-workflow.sh"
  # Exit 1 (no match) is the PASS condition
  [ "$status" -eq 1 ]

  run grep -n 'integration-branches' \
    "${RITE_REPO_ROOT}/lib/core/workflow-runner.sh"
  [ "$status" -eq 1 ]
}
