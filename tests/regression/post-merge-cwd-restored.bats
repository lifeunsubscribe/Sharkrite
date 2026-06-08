#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/core/merge-pr.sh
# Regression test: phase_merge_pr restores cwd after worktree removal
# Issue #295
#
# Bug: workflow-runner.sh::phase_merge_pr() calls merge-pr.sh which removes the
# feature-branch worktree.  Control returns to workflow-runner.sh, whose cwd is
# still set to the (now-deleted) $WORKTREE_PATH from `cd "$WORKTREE_PATH"` near
# the top of run_workflow().  The first `gh_safe pr view` call in phase_completion
# triggers gh's internal git probe, which resolves the (deleted) cwd:
#   "fatal: Unable to read current working directory: No such file or directory"
# → exit 1 → issue reported as failed despite the PR being successfully merged.
#
# Fix (both options, defense-in-depth):
# Option A: phase_merge_pr() restores cwd to $RITE_PROJECT_ROOT at the very end
#           of the function, before `return 0`.
# Option B: phase_completion() starts with a defensive cd to $RITE_PROJECT_ROOT.
#
# Tests:
# 1. Static check: phase_merge_pr contains the cwd-restore cd before `return 0`
# 2. Static check: phase_completion contains the defensive cd guard at its start
# 3. Static check: the Option A cd in phase_merge_pr is AFTER the STASHED_UNRELATED_WORK block
# 4. Behavioral: a subprocess started in a removed directory that mimics
#    phase_completion's pattern (cd $ROOT then gh call) succeeds.
# 5. Behavioral: the same subprocess WITHOUT the cd fails with the fatal error
#    (proves the fixture faithfully reproduces the original bug).

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  # Create a real git repo to serve as the main repo / RITE_PROJECT_ROOT
  _MAIN_REPO="$RITE_TEST_TMPDIR/main-repo"
  git init --quiet "$_MAIN_REPO"
  git -C "$_MAIN_REPO" config user.email "test@example.com"
  git -C "$_MAIN_REPO" config user.name "Test"
  echo "# repo" > "$_MAIN_REPO/README.md"
  git -C "$_MAIN_REPO" add README.md
  git -C "$_MAIN_REPO" commit -m "init" --quiet

  export RITE_PROJECT_ROOT="$_MAIN_REPO"

  # Create a sibling directory to simulate the feature-branch worktree that gets
  # removed by merge-pr.sh.
  _FAKE_WORKTREE="$RITE_TEST_TMPDIR/fake-worktree"
  mkdir -p "$_FAKE_WORKTREE"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Test 1: Static check — phase_merge_pr contains the cwd-restore line
# ---------------------------------------------------------------------------

@test "phase_merge_pr: contains cd RITE_PROJECT_ROOT restore before return 0" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ -f "$_wfr" ]

  # Extract the body of phase_merge_pr (from its opening brace to the matching
  # closing brace).  We look for the canonical cd-restore pattern.
  # awk strategy: start printing at "^phase_merge_pr()", stop at the next
  # top-level "^}" (brace at column 0 followed by end-of-line).
  _fn_body=$(awk '
    /^phase_merge_pr\(\)/ { in_fn=1; depth=0 }
    in_fn {
      # count brace depth
      for (i=1; i<=length($0); i++) {
        c = substr($0,i,1)
        if (c == "{") depth++
        else if (c == "}") {
          depth--
          if (depth == 0) { print; in_fn=0; next }
        }
      }
      print
    }
  ' "$_wfr")

  [ -n "$_fn_body" ]

  # Must contain a cd to RITE_PROJECT_ROOT (the cwd-restore line).
  # Use literal grep to avoid BSD grep ERE quirks with {? patterns.
  echo "$_fn_body" | grep -q 'cd "$RITE_PROJECT_ROOT"'
}

# ---------------------------------------------------------------------------
# Test 2: Static check — phase_completion starts with defensive cd
# ---------------------------------------------------------------------------

@test "phase_completion: contains defensive cd RITE_PROJECT_ROOT before first gh_safe call" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ -f "$_wfr" ]

  # Extract the body of phase_completion.
  _fn_body=$(awk '
    /^phase_completion\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c = substr($0,i,1)
        if (c == "{") depth++
        else if (c == "}") {
          depth--
          if (depth == 0) { print; in_fn=0; next }
        }
      }
      print
    }
  ' "$_wfr")

  [ -n "$_fn_body" ]

  # Find the line numbers of the cd guard and the first gh_safe call.
  # Use a simple literal grep (no special regex) to avoid BSD grep ERE quirks.
  _cd_line=$(echo "$_fn_body" | grep -n 'cd "$RITE_PROJECT_ROOT"' | head -1 | cut -d: -f1 || true)
  _gh_line=$(echo "$_fn_body" | grep -n 'gh_safe' | head -1 | cut -d: -f1 || true)

  # Both must exist.
  [ -n "$_cd_line" ]
  [ -n "$_gh_line" ]

  # The cd must precede the first gh_safe call.
  [ "$_cd_line" -lt "$_gh_line" ]
}

# ---------------------------------------------------------------------------
# Test 3: Static check — Option A cd is AFTER the STASHED_UNRELATED_WORK block
# ---------------------------------------------------------------------------

@test "phase_merge_pr: cwd-restore cd is after STASHED_UNRELATED_WORK block" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ -f "$_wfr" ]

  # Find line numbers relative to file for the stash block and the restore cd.
  # Strategy: within phase_merge_pr's body, locate STASHED_UNRELATED_WORK and
  # the cd-restore, then compare positions.
  _fn_body=$(awk '
    /^phase_merge_pr\(\)/ { in_fn=1; depth=0; lineno=0 }
    in_fn {
      lineno++
      for (i=1; i<=length($0); i++) {
        c = substr($0,i,1)
        if (c == "{") depth++
        else if (c == "}") {
          depth--
          if (depth == 0) { print lineno": "$0; in_fn=0; next }
        }
      }
      print lineno": "$0
    }
  ' "$_wfr")

  _stash_line=$(echo "$_fn_body" | grep 'STASHED_UNRELATED_WORK' | tail -1 | cut -d: -f1 || true)
  _cd_restore_line=$(echo "$_fn_body" | grep 'cd "$RITE_PROJECT_ROOT"' | tail -1 | cut -d: -f1 || true)

  # Both markers must exist.
  [ -n "$_stash_line" ]
  [ -n "$_cd_restore_line" ]

  # The cwd-restore cd must come after the last reference to STASHED_UNRELATED_WORK.
  [ "$_cd_restore_line" -gt "$_stash_line" ]
}

# ---------------------------------------------------------------------------
# Test 4: Behavioral — subprocess mimicking phase_completion WITH cd guard
#         succeeds even when started from a removed directory.
# ---------------------------------------------------------------------------

@test "post-merge cwd: subprocess with cd guard runs git successfully after worktree removal" {
  _script=$(mktemp "$RITE_TEST_TMPDIR/script-with-guard.XXXXXX")
  chmod +x "$_script"
  cat > "$_script" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
# Simulate Option B: defensive cd at start of phase_completion.
cd "${RITE_PROJECT_ROOT}"
# Simulate what gh triggers internally: git rev-parse to find the repo root.
git rev-parse --show-toplevel
SCRIPT

  _log=$(mktemp "$RITE_TEST_TMPDIR/log.XXXXXX")

  # Launch from inside the fake worktree, remove it, then wait for the subprocess.
  # Note: run the subprocess synchronously in a subshell that cd's into the
  # (soon-to-be-deleted) worktree first, then remove the dir before the script
  # reaches the git call.  Use a signal file to make the race deterministic.
  _signal_file="$RITE_TEST_TMPDIR/signal-guard"
  cat > "$_script" <<SCRIPT2
#!/bin/bash
set -euo pipefail
while [ ! -f "${_signal_file}" ]; do sleep 0.01; done
cd "${RITE_PROJECT_ROOT}"
git rev-parse --show-toplevel
SCRIPT2

  (cd "$_FAKE_WORKTREE" && "$_script" > "$_log" 2>&1) &
  _pid=$!

  rm -rf "$_FAKE_WORKTREE"
  touch "$_signal_file"

  _exit_code=0
  wait "$_pid" || _exit_code=$?

  [ "$_exit_code" -eq 0 ]
  [[ "$(cat "$_log")" == *"$RITE_PROJECT_ROOT"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: Behavioral — subprocess WITHOUT cd guard fails with the fatal error
#         (proves the fixture faithfully reproduces the original bug).
# ---------------------------------------------------------------------------

@test "post-merge cwd: subprocess without cd guard fails git after worktree removal" {
  # Recreate the fake worktree (each test has isolated setup/teardown).
  mkdir -p "$_FAKE_WORKTREE"

  _script2=$(mktemp "$RITE_TEST_TMPDIR/script-no-guard.XXXXXX")
  _signal_file2="$RITE_TEST_TMPDIR/ready-signal2"
  chmod +x "$_script2"
  # Use interpolation for the signal file path (not heredoc so it expands).
  cat > "$_script2" <<SCRIPT2
#!/bin/bash
# Wait until the parent signals the worktree has been removed.
while [ ! -f "${_signal_file2}" ]; do sleep 0.01; done
# Probe git WITHOUT cd-ing to a safe directory — reproduces the original bug.
git rev-parse --show-toplevel
SCRIPT2

  _log2=$(mktemp "$RITE_TEST_TMPDIR/log2.XXXXXX")

  (cd "$_FAKE_WORKTREE" && "$_script2") > "$_log2" 2>&1 &
  _pid2=$!

  # Remove the worktree, then signal the subprocess.
  rm -rf "$_FAKE_WORKTREE"
  touch "$_signal_file2"

  _exit_code2=0
  wait "$_pid2" || _exit_code2=$?

  [ "$_exit_code2" -ne 0 ]

  # Must see one of the two forms of the fatal cwd error.
  [[ "$(cat "$_log2")" == *"Unable to read current working directory"* ]] || \
    [[ "$(cat "$_log2")" == *"No such file or directory"* ]]
}
