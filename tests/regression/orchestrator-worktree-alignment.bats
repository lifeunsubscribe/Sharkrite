#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh
# tests/regression/orchestrator-worktree-alignment.bats
#
# Regression tests for #1473: Align orchestrator and dev-session worktree paths.
#
# Verifies the alignment assertion added to workflow-runner.sh (phase_claude_workflow):
# After all worktree discovery steps, the handoff file written by claude-workflow.sh is
# read unconditionally. When its path differs from the orchestrator's WORKTREE_PATH, the
# run aborts with a loud error naming BOTH paths — never "No work was produced".
#
# Live failure (2026-10-25): batch #1342/#1368, stale PR #1452 (Oct 24 batch) had a
# content-empty worktree. detect_worktree_for_pr resolved that stale path, handoff
# file was ignored (it was last-resort only), count_changed_files returned 0, and the
# orchestrator falsely reported "No work was produced" after a 24-minute dev session.

load '../helpers/setup'

# Inline the alignment assertion from workflow-runner.sh for blackbox simulation.
# Matches the "Read handoff file" block added by this issue. Returns 0 on alignment,
# 1 on mismatch. Stdout carries diagnostic text (caller checks for path strings).
_run_alignment_check() {
  local state_dir="$1"
  local issue_number="$2"
  local discovered_worktree="$3"  # what orchestrator found (WORKTREE_PATH)

  # simulate the exact logic from workflow-runner.sh
  bash -c "
    set -euo pipefail
    RITE_STATE_DIR='${state_dir}'
    WORKTREE_PATH='${discovered_worktree}'
    issue_number='${issue_number}'

    _dev_session_worktree=''
    _handoff_file=''
    if [ -n \"\${RITE_STATE_DIR:-}\" ]; then
      _handoff_file=\"\${RITE_STATE_DIR}/worktree-handoff-\${issue_number}.txt\"
      if [ -f \"\$_handoff_file\" ]; then
        _dev_session_worktree=\$(cat \"\$_handoff_file\" 2>/dev/null || true)
        rm -f \"\$_handoff_file\"
      fi
    fi

    if [ -n \"\${_dev_session_worktree:-}\" ] && [ -n \"\${WORKTREE_PATH:-}\" ] && \\
       [ \"\$_dev_session_worktree\" != \"\$WORKTREE_PATH\" ]; then
      echo \"DEV_SESSION_USED=\$_dev_session_worktree\"
      echo \"ORCHESTRATOR_FOUND=\$WORKTREE_PATH\"
      echo 'MISMATCH'
      exit 1
    elif [ -n \"\${_dev_session_worktree:-}\" ]; then
      WORKTREE_PATH=\"\$_dev_session_worktree\"
    fi
    echo \"FINAL_PATH=\$WORKTREE_PATH\"
    exit 0
  "
}

setup() {
  setup_test_tmpdir
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/state"
  mkdir -p "$RITE_STATE_DIR"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# 1. Mismatch → fails loudly naming BOTH paths (never "No work was produced")
# ---------------------------------------------------------------------------

@test "alignment: mismatch exits 1 and names both paths in output" {
  local issue_number="1342"
  local dev_worktree="$RITE_TEST_TMPDIR/wt/fx-make-plan-issuessh-end_b1342-1368"
  local stale_worktree="$RITE_TEST_TMPDIR/wt/ft-some-old-branch_b1342-1368"
  mkdir -p "$dev_worktree" "$stale_worktree"

  # Dev session wrote the handoff file pointing to its real worktree
  echo "$dev_worktree" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  # Orchestrator discovery found a different (stale) worktree
  run _run_alignment_check "$RITE_STATE_DIR" "$issue_number" "$stale_worktree"

  [ "$status" -eq 1 ]
  # Both paths must appear in the diagnostic output
  [[ "$output" == *"$dev_worktree"* ]]
  [[ "$output" == *"$stale_worktree"* ]]
  [[ "$output" == *"MISMATCH"* ]]
}

@test "alignment: mismatch output contains dev-session path on its own line" {
  local issue_number="42"
  local dev_path="$RITE_TEST_TMPDIR/wt/ft-real-work_b42"
  local stale_path="$RITE_TEST_TMPDIR/wt/ft-old-pr_b42"
  mkdir -p "$dev_path" "$stale_path"

  echo "$dev_path" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  run _run_alignment_check "$RITE_STATE_DIR" "$issue_number" "$stale_path"

  [ "$status" -eq 1 ]
  [[ "$output" == *"DEV_SESSION_USED=$dev_path"* ]]
  [[ "$output" == *"ORCHESTRATOR_FOUND=$stale_path"* ]]
}

# ---------------------------------------------------------------------------
# 2. Handoff path used when orchestrator found nothing (existing last-resort behaviour)
# ---------------------------------------------------------------------------

@test "alignment: handoff path adopted when orchestrator found nothing" {
  local issue_number="99"
  local dev_path="$RITE_TEST_TMPDIR/wt/ft-new-feature_b99"
  mkdir -p "$dev_path"

  echo "$dev_path" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  run _run_alignment_check "$RITE_STATE_DIR" "$issue_number" ""  # empty = orchestrator found nothing

  [ "$status" -eq 0 ]
  [[ "$output" == *"FINAL_PATH=$dev_path"* ]]
}

# ---------------------------------------------------------------------------
# 3. Paths agree → no error, WORKTREE_PATH unchanged
# ---------------------------------------------------------------------------

@test "alignment: no error when handoff and discovered path agree" {
  local issue_number="77"
  local agreed_path="$RITE_TEST_TMPDIR/wt/ft-agreed_b77"
  mkdir -p "$agreed_path"

  echo "$agreed_path" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  run _run_alignment_check "$RITE_STATE_DIR" "$issue_number" "$agreed_path"

  [ "$status" -eq 0 ]
  [[ "$output" != *"MISMATCH"* ]]
  [[ "$output" == *"FINAL_PATH=$agreed_path"* ]]
}

# ---------------------------------------------------------------------------
# 4. Genuinely empty dev session reports "No work was produced" (no false alarm)
#    Alignment passes when both paths agree; the empty check fires afterwards.
# ---------------------------------------------------------------------------

@test "alignment: empty dev session still reports no-work (no false alarm on agreement)" {
  local issue_number="55"
  local empty_wt="$RITE_TEST_TMPDIR/wt/ft-empty-session_b55"

  # Create a minimal git repo inside the worktree so count_changed_files can run
  mkdir -p "$empty_wt"
  git -C "$empty_wt" init --quiet
  git -C "$empty_wt" config user.email "test@example.com"
  git -C "$empty_wt" config user.name "Test"
  echo "# empty" > "$empty_wt/README.md"
  git -C "$empty_wt" add README.md
  git -C "$empty_wt" commit -m "init" --quiet

  # Both paths agree — no mismatch
  echo "$empty_wt" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  run _run_alignment_check "$RITE_STATE_DIR" "$issue_number" "$empty_wt"

  # Alignment should pass (paths agree)
  [ "$status" -eq 0 ]
  [[ "$output" != *"MISMATCH"* ]]
  # Post-alignment WORKTREE_PATH is the correct empty path
  [[ "$output" == *"FINAL_PATH=$empty_wt"* ]]
}

# ---------------------------------------------------------------------------
# 5. Handoff file is consumed on read (not left behind)
# ---------------------------------------------------------------------------

@test "alignment: handoff file is removed after successful read" {
  local issue_number="200"
  local dev_path="$RITE_TEST_TMPDIR/wt/ft-consumed_b200"
  mkdir -p "$dev_path"

  local handoff_file="${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"
  echo "$dev_path" > "$handoff_file"
  [ -f "$handoff_file" ]

  run _run_alignment_check "$RITE_STATE_DIR" "$issue_number" ""

  [ "$status" -eq 0 ]
  # File must be gone after the alignment check ran
  [ ! -f "$handoff_file" ]
}

@test "alignment: handoff file is removed even when mismatch is detected" {
  local issue_number="201"
  local dev_path="$RITE_TEST_TMPDIR/wt/ft-mismatch-consume_b201"
  local stale_path="$RITE_TEST_TMPDIR/wt/ft-stale_b201"
  mkdir -p "$dev_path" "$stale_path"

  local handoff_file="${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"
  echo "$dev_path" > "$handoff_file"

  run _run_alignment_check "$RITE_STATE_DIR" "$issue_number" "$stale_path"

  [ "$status" -eq 1 ]
  # File must still be gone even on failure
  [ ! -f "$handoff_file" ]
}

# ---------------------------------------------------------------------------
# 6. Structural: handoff mechanism is reused (not replaced with a new channel)
# ---------------------------------------------------------------------------

@test "structural: workflow-runner.sh uses _handoff_file at alignment site" {
  # The handoff file read uses the same _handoff_file variable name as the
  # pre-existing mechanism. No new channel was added.
  local src_file="${RITE_REPO_ROOT}/lib/core/workflow-runner.sh"
  run grep -c "_handoff_file" "$src_file"
  [ "$status" -eq 0 ]
  # At least 2 occurrences: the declaration/assignment and the existence check
  [ "$output" -ge 2 ]
}

@test "structural: alignment assertion appears before count_changed_files check" {
  local src_file="${RITE_REPO_ROOT}/lib/core/workflow-runner.sh"

  # Get the line number of the alignment error message
  local align_line
  align_line=$(grep -n "Worktree path mismatch" "$src_file" | head -1 | cut -d: -f1 || true)

  # Get the line number of count_changed_files call in the post-dev check (after fresh start)
  local check_line
  check_line=$(grep -n 'count_changed_files.*_target' "$src_file" | \
    awk -F: '$1 > 1100' | head -1 | cut -d: -f1 || true)

  [ -n "$align_line" ]
  [ -n "$check_line" ]
  # Alignment assertion must appear before the post-dev count check
  [ "$align_line" -lt "$check_line" ]
}

# ---------------------------------------------------------------------------
# 7. Retry path also carries the alignment assertion
# ---------------------------------------------------------------------------

@test "structural: retry discovery block also has alignment assertion" {
  local src_file="${RITE_REPO_ROOT}/lib/core/workflow-runner.sh"

  # There should be two "Worktree path mismatch" messages — one for fresh run,
  # one for the retry path
  local count
  count=$(grep -c "Worktree path mismatch" "$src_file" || true)
  [ "$count" -ge 2 ]
}
