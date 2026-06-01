#!/usr/bin/env bats
# Regression test: cleanup phase emits no cwd error after worktree removal
# Issue #161
#
# Bug: assess-documentation.sh is launched as a background process (&) from
# merge-pr.sh while the parent shell is still cd'd into the feature-branch
# worktree.  The worktree is removed shortly after the fork.  When the claude
# CLI starts inside the background process it probes the cwd for git context;
# if the directory is already gone it emits:
#   "failed to run git: fatal: Unable to read current working directory"
# and exits 1, making the whole doc assessment appear to fail.
#
# Fix: assess-documentation.sh now cd's to $RITE_PROJECT_ROOT immediately
# after sourcing config, before any git-aware tool runs.
#
# Tests:
# 1. A subprocess spawned from a removed directory and given RITE_PROJECT_ROOT
#    can run `git rev-parse --show-toplevel` successfully after cd-ing there.
# 2. A subprocess spawned from a removed directory WITHOUT the cd guard fails
#    the git call (proving the fixture faithfully reproduces the bug).
# 3. Static check: assess-documentation.sh contains `cd "${RITE_PROJECT_ROOT}"`.

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  # Create a real git repo to serve as the "main worktree" / RITE_PROJECT_ROOT
  _MAIN_REPO="$RITE_TEST_TMPDIR/main-repo"
  git init --quiet "$_MAIN_REPO"
  git -C "$_MAIN_REPO" config user.email "test@example.com"
  git -C "$_MAIN_REPO" config user.name "Test"
  echo "# repo" > "$_MAIN_REPO/README.md"
  git -C "$_MAIN_REPO" add README.md
  git -C "$_MAIN_REPO" commit -m "init" --quiet

  export RITE_PROJECT_ROOT="$_MAIN_REPO"

  # Create a sibling directory to simulate a feature-branch worktree.
  # We will remove it before the test subprocess runs its git call.
  _FAKE_WORKTREE="$RITE_TEST_TMPDIR/fake-worktree"
  mkdir -p "$_FAKE_WORKTREE"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Test 1: subprocess that cd's to RITE_PROJECT_ROOT survives worktree removal
# ---------------------------------------------------------------------------

@test "cwd-guard: subprocess with cd guard runs git successfully after worktree removal" {
  # Write a minimal script that mimics the fixed assess-documentation.sh pattern:
  # it receives RITE_PROJECT_ROOT from the environment and cd's there before
  # calling git.
  _script=$(mktemp "$RITE_TEST_TMPDIR/script-with-guard.XXXXXX")
  chmod +x "$_script"
  cat > "$_script" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
# Simulate the fix: cd to project root before any git-aware tool runs.
cd "${RITE_PROJECT_ROOT}"
# Simulate what claude --print does on startup: probe git context.
git rev-parse --show-toplevel
SCRIPT

  _log=$(mktemp "$RITE_TEST_TMPDIR/log.XXXXXX")

  # Launch the script as a background process from inside the fake worktree.
  # This simulates assess-documentation.sh being spawned while the parent
  # shell is still in the worktree directory.
  (cd "$_FAKE_WORKTREE" && "$_script" > "$_log" 2>&1) &
  _pid=$!

  # Remove the fake worktree — the background process is already running from
  # it, simulating the race between worktree removal and the subprocess.
  rm -rf "$_FAKE_WORKTREE"

  # Wait for the subprocess to finish.
  run wait "$_pid"

  # The script should exit 0 (git call succeeded after cd to project root).
  [ "$status" -eq 0 ]

  # The git rev-parse output should be the project root.
  [[ "$(cat "$_log")" == *"$RITE_PROJECT_ROOT"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: reproduce the bug — subprocess WITHOUT the cd guard fails git call
# ---------------------------------------------------------------------------

@test "cwd-guard: subprocess without cd guard fails git after worktree removal" {
  _log=$(mktemp "$RITE_TEST_TMPDIR/log.XXXXXX")

  # Recreate the fake worktree (setup removes it in Test 1 if they share state,
  # but each test gets its own setup/teardown, so it still exists here).
  mkdir -p "$_FAKE_WORKTREE"

  # Write a script that cd's into the worktree dir first, then waits for a
  # "ready" signal file before calling git.  This makes the race deterministic:
  # parent removes the dir, creates the signal file, then the subprocess wakes
  # up and tries to run git from the (now-deleted) cwd.
  _script2=$(mktemp "$RITE_TEST_TMPDIR/script-no-guard.XXXXXX")
  _signal_file="$RITE_TEST_TMPDIR/ready-signal"
  chmod +x "$_script2"
  cat > "$_script2" <<SCRIPT2
#!/bin/bash
# Wait until the parent signals that the worktree has been removed.
while [ ! -f "${_signal_file}" ]; do sleep 0.01; done
# Now run git — cwd is gone.
git rev-parse --show-toplevel
SCRIPT2

  (cd "$_FAKE_WORKTREE" && "$_script2") > "$_log" 2>&1 &
  _pid=$!

  # Remove the worktree, then create the signal file so the subprocess wakes up.
  rm -rf "$_FAKE_WORKTREE"
  touch "$_signal_file"

  # Wait — expect failure.
  run wait "$_pid"

  # The git call should fail because the cwd is gone.
  # Exit code non-zero and the fatal message present.
  [ "$status" -ne 0 ]
  [[ "$(cat "$_log")" == *"Unable to read current working directory"* ]] || \
    [[ "$(cat "$_log")" == *"No such file or directory"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: static check — assess-documentation.sh contains the cd guard
# ---------------------------------------------------------------------------

@test "assess-documentation.sh: contains cd RITE_PROJECT_ROOT guard before git calls" {
  _assess_doc="$RITE_REPO_ROOT/lib/core/assess-documentation.sh"

  [ -f "$_assess_doc" ]

  # The script must contain a bare cd to RITE_PROJECT_ROOT (not inside a function,
  # since it must run at the top-level startup path).
  # We look for the exact pattern at top-level (before the first function definition).
  _top_level_section=$(awk '
    /^[a-z_]+\(\)/ { exit }   # stop at first function definition
    { print }
  ' "$_assess_doc")

  [ -n "$_top_level_section" ]

  # Must contain `cd "${RITE_PROJECT_ROOT}"` (or the unquoted variant).
  echo "$_top_level_section" | grep -qE 'cd "\$\{?RITE_PROJECT_ROOT\}?"'
}

# ---------------------------------------------------------------------------
# Test 4: static check — the cd guard appears BEFORE the first git-aware call
# ---------------------------------------------------------------------------

@test "assess-documentation.sh: cd guard precedes first provider_run or gh call" {
  _assess_doc="$RITE_REPO_ROOT/lib/core/assess-documentation.sh"

  [ -f "$_assess_doc" ]

  # Find line numbers of the cd guard and the first gh/provider call.
  _cd_line=$(grep -n 'cd "\${RITE_PROJECT_ROOT}"' "$_assess_doc" | head -1 | cut -d: -f1)
  _first_gh_line=$(grep -n '^gh pr \|^PR_DATA\|^PR_DIFF' "$_assess_doc" | head -1 | cut -d: -f1)

  # Both must exist.
  [ -n "$_cd_line" ]
  [ -n "$_first_gh_line" ]

  # The cd must come before the first gh/provider call.
  [ "$_cd_line" -lt "$_first_gh_line" ]
}
