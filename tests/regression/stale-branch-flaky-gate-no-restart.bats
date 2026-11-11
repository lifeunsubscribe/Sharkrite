#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/stale-branch.sh::check_stale_branch|_stale_rebase_onto_main, lib/utils/post-merge-verify.sh
#
# End-to-end pin for the 2026-11-11 rite 1737 incident (#1742): a post-rebase
# gate that is red only under parallel load must NOT trigger the stale-branch
# close-and-restart. Drives the REAL check_stale_branch → _stale_rebase_onto_main
# → verify_post_merge → _pmv_serial_rerun_clears chain against a real git
# fixture; only run_test_gate (the parallel gate) and gh_safe are stubbed. The
# serial re-run executes real bats on the worktree's test files.
#
#   flake:      parallel gate red on a test that passes alone → exit 0, PR kept,
#               no STALE_REBASE_CONFLICT_RESTART, FLAKE_CLEARED diag
#   persistent: parallel gate red on a test that fails alone  → exit 11, restart
#               diag (the existing contract for a genuine semantic conflict)

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  export RITE_REBASE_CONFLICT_RESTART_MAX=0
  setup_test_tmpdir
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")
  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_WORKTREE_DIR="$RITE_PROJECT_ROOT/.rite/worktrees"
  export RITE_STATE_DIR="$RITE_PROJECT_ROOT/.rite/state"
  mkdir -p "$RITE_WORKTREE_DIR" "$RITE_STATE_DIR"
  cd "$FIXTURE_REPO"

  # Make the fixture a "sharkrite repo" (Makefile with shellcheck:/lint:) that
  # carries one passing and one failing bats file. printf, not heredocs: bats
  # preprocesses any source line starting with @test, heredoc bodies included.
  printf 'shellcheck:\n\t@true\nlint:\n\t@true\n' > Makefile
  mkdir -p tests
  printf '#!/usr/bin/env bats\n@test "flaky under load" { true; }\n' > tests/flaky.bats
  printf '#!/usr/bin/env bats\n@test "genuinely broken" { false; }\n' > tests/broken.bats
  git add Makefile tests && git commit -qm "sharkrite-shaped fixture" && git push -q origin main

  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  set +u; set +o pipefail
  DIAG="$RITE_TEST_TMPDIR/diag.log"; : > "$DIAG"
  _diag() { echo "$*" >> "$DIAG"; }
  gh_safe() { return 0; }
}

teardown() { teardown_test_tmpdir; }

# Feature branch 3 behind main, clean rebase; worktree at $WT; BRANCH set.
_behind_branch() {
  BRANCH="fix/flaky-gate-$$"
  git checkout -qb "$BRANCH" main
  echo "feature" > feature.txt; git add feature.txt; git commit -qm "feature work"
  git push -qu origin "$BRANCH"
  git checkout -q main
  local i; for i in 1 2 3; do echo "$i" > "main-$i.txt"; git add "main-$i.txt"; git commit -qm "main $i"; done
  git push -q origin main
  WT="$RITE_WORKTREE_DIR/issue-77"
  git worktree add -q "$WT" "$BRANCH"
}

@test "flaky post-rebase gate: branch is rebased and KEPT — no close-and-restart (exit 0)" {
  _behind_branch
  # Parallel gate reports the flaky test red; the serial re-run (real bats) clears it.
  run_test_gate() {
    printf '{"lint":[],"tests":[{"file":"bats","test_name":"flaky under load","reason":"assertion failed"}],"exit_code":1}' > "$1"
    return 1
  }
  local rc=0
  check_stale_branch "$WT" 9001 77 "auto" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ]
  [ -d "$WT" ]
  [ -f "$WT/main-3.txt" ] && [ -f "$WT/feature.txt" ]
  git -C "$FIXTURE_REPO" show-ref --verify --quiet "refs/heads/$BRANCH"
  ! grep -q "STALE_REBASE_CONFLICT_RESTART" "$DIAG"
  grep -q "POST_MERGE_VERIFY_FLAKE_CLEARED files=1" "$DIAG"
}

@test "persistent post-rebase failure: still closes and restarts (exit 11) — contract unchanged" {
  _behind_branch
  run_test_gate() {
    printf '{"lint":[],"tests":[{"file":"bats","test_name":"genuinely broken","reason":"assertion failed"}],"exit_code":1}' > "$1"
    return 1
  }
  local rc=0
  check_stale_branch "$WT" 9002 78 "auto" 2>/dev/null || rc=$?
  [ "$rc" -eq 11 ]
  grep -q "POST_MERGE_VERIFY_FLAKE_PERSISTENT reason=still_failing" "$DIAG"
  grep -q "STALE_REBASE_CONFLICT_RESTART issue=78" "$DIAG"
}
