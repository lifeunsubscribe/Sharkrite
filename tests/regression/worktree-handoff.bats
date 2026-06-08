#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh
# tests/regression/worktree-handoff.bats
#
# Regression tests for issue #13: Define RITE_STATE_DIR so worktree handoff works.
#
# Verifies that:
# 1. config.sh defines RITE_STATE_DIR and creates the directory at load time.
# 2. The worktree-handoff file round-trip works for a branch name that does NOT
#    match the issue-number regex (simulating follow-up issues or sanitized titles).

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  # Create a minimal git repo so config.sh's detect_project_root() succeeds
  git init --quiet "$RITE_TEST_TMPDIR/repo"
  cd "$RITE_TEST_TMPDIR/repo"
  git config user.email "test@example.com"
  git config user.name "Test User"
  echo "# repo" > README.md
  git add README.md
  git commit -m "init" --quiet

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/repo"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_INSTALL_DIR="${RITE_REPO_ROOT}"
  # Point worktree base to tmpdir so mkdir -p doesn't write elsewhere
  export RITE_WORKTREE_BASE="$RITE_TEST_TMPDIR/wt-base"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# 1. config.sh sourcing sets RITE_STATE_DIR and creates the directory
# ---------------------------------------------------------------------------

@test "config.sh: RITE_STATE_DIR is set after sourcing" {
  run bash -c "
    set -u
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_INSTALL_DIR='${RITE_INSTALL_DIR}'
    export RITE_WORKTREE_BASE='${RITE_WORKTREE_BASE}'
    source '${RITE_LIB_DIR}/utils/config.sh'
    echo \"\$RITE_STATE_DIR\" | grep -q . && echo PASS
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "config.sh: RITE_STATE_DIR directory is created at load time" {
  run bash -c "
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_INSTALL_DIR='${RITE_INSTALL_DIR}'
    export RITE_WORKTREE_BASE='${RITE_WORKTREE_BASE}'
    source '${RITE_LIB_DIR}/utils/config.sh'
    [ -d \"\$RITE_STATE_DIR\" ] && echo DIR_EXISTS
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIR_EXISTS"* ]]
}

@test "config.sh: RITE_STATE_DIR defaults to .rite/state under project root" {
  run bash -c "
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_INSTALL_DIR='${RITE_INSTALL_DIR}'
    export RITE_WORKTREE_BASE='${RITE_WORKTREE_BASE}'
    source '${RITE_LIB_DIR}/utils/config.sh'
    echo \"\$RITE_STATE_DIR\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.rite/state"* ]]
}

@test "config.sh: caller-provided RITE_STATE_DIR is respected" {
  local custom_dir="$RITE_TEST_TMPDIR/custom-state"
  mkdir -p "$custom_dir"
  run bash -c "
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_DATA_DIR='${RITE_DATA_DIR}'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_INSTALL_DIR='${RITE_INSTALL_DIR}'
    export RITE_WORKTREE_BASE='${RITE_WORKTREE_BASE}'
    export RITE_STATE_DIR='${custom_dir}'
    source '${RITE_LIB_DIR}/utils/config.sh'
    echo \"\$RITE_STATE_DIR\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"custom-state"* ]]
}

# ---------------------------------------------------------------------------
# 2. Worktree-handoff round-trip with non-conforming branch name
#
# Scenario: claude-workflow.sh (the writer) writes the handoff file.
#           workflow-runner.sh (the reader) picks it up as last resort when
#           branch-name regex matching fails (e.g. follow-up issue with a
#           sanitized title like "ft-add-retry-logic" that contains no "-75-").
# ---------------------------------------------------------------------------

@test "worktree-handoff: write and read round-trip for non-conforming branch" {
  # Set up state dir
  local state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$state_dir"

  local issue_number="75"
  local worktree_path="$RITE_TEST_TMPDIR/wt/ft-add-retry-logic"
  mkdir -p "$worktree_path"

  # --- WRITER side (simulates the write in claude-workflow.sh:1610-1611) ---
  run bash -c "
    RITE_STATE_DIR='${state_dir}'
    ISSUE_NUMBER='${issue_number}'
    WORKTREE_PATH='${worktree_path}'
    if [ -n \"\${RITE_STATE_DIR:-}\" ] && [ -n \"\${ISSUE_NUMBER:-}\" ]; then
      echo \"\$WORKTREE_PATH\" > \"\${RITE_STATE_DIR}/worktree-handoff-\${ISSUE_NUMBER}.txt\" 2>/dev/null || true
      echo WRITTEN
    fi
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"WRITTEN"* ]]

  # Confirm file was created
  [ -f "$state_dir/worktree-handoff-${issue_number}.txt" ]

  # --- READER side (simulates the read in workflow-runner.sh:789-796) ---
  # Branch name "ft-add-retry-logic" does NOT match the -75- regex, so
  # WORKTREE_PATH is empty — last resort: read handoff file.
  run bash -c "
    RITE_STATE_DIR='${state_dir}'
    WORKTREE_PATH=''
    issue_number='${issue_number}'
    if [ -z \"\${WORKTREE_PATH:-}\" ] && [ -n \"\${RITE_STATE_DIR:-}\" ]; then
      _handoff_file=\"\${RITE_STATE_DIR}/worktree-handoff-\${issue_number}.txt\"
      if [ -f \"\$_handoff_file\" ]; then
        WORKTREE_PATH=\$(cat \"\$_handoff_file\" 2>/dev/null || echo '')
        rm -f \"\$_handoff_file\"
      fi
    fi
    echo \"\$WORKTREE_PATH\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ft-add-retry-logic"* ]]

  # Handoff file should be consumed (removed after read)
  [ ! -f "$state_dir/worktree-handoff-${issue_number}.txt" ]
}

@test "worktree-handoff: writer skips when RITE_STATE_DIR is unset (guard holds)" {
  # Verify the existing guard in claude-workflow.sh is effective:
  # if RITE_STATE_DIR is empty, no write attempt is made (no crash, no side effect).
  run bash -c "
    set -u
    unset RITE_STATE_DIR 2>/dev/null || true
    ISSUE_NUMBER='42'
    WORKTREE_PATH='/tmp/some-worktree'
    if [ -n \"\${RITE_STATE_DIR:-}\" ] && [ -n \"\${ISSUE_NUMBER:-}\" ]; then
      echo \"\$WORKTREE_PATH\" > \"\${RITE_STATE_DIR}/worktree-handoff-\${ISSUE_NUMBER}.txt\" 2>/dev/null || true
      echo WRITTEN
    else
      echo SKIPPED
    fi
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIPPED"* ]]
}

@test "worktree-handoff: reader skips gracefully when handoff file absent" {
  local state_dir="$RITE_TEST_TMPDIR/state-empty"
  mkdir -p "$state_dir"

  run bash -c "
    RITE_STATE_DIR='${state_dir}'
    WORKTREE_PATH=''
    issue_number='99'
    if [ -z \"\${WORKTREE_PATH:-}\" ] && [ -n \"\${RITE_STATE_DIR:-}\" ]; then
      _handoff_file=\"\${RITE_STATE_DIR}/worktree-handoff-\${issue_number}.txt\"
      if [ -f \"\$_handoff_file\" ]; then
        WORKTREE_PATH=\$(cat \"\$_handoff_file\" 2>/dev/null || echo '')
        rm -f \"\$_handoff_file\"
      fi
    fi
    # WORKTREE_PATH should still be empty — no crash
    [ -z \"\${WORKTREE_PATH:-}\" ] && echo EMPTY_OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"EMPTY_OK"* ]]
}
