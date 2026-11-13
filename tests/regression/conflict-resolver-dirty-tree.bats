#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/conflict-resolver.sh::attempt_claude_merge_resolution
#
# Live (freshup #549, 2026-11-12): the resolver's `git merge` was refused
# because the operator's uncommitted edits touched the conflicting file
# ("Your local changes ... would be overwritten by merge"), and the refusal was
# misread as an untracked add/add collision ("could not identify a stashed
# colliding path"). Auto mode then closed the PR and deleted the branch.
# Contract: a dirty-tree refusal is named as such; a clean tree resolves as before.

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  setup_test_tmpdir
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")
  export RITE_PROJECT_ROOT="$FIXTURE_REPO" RITE_DATA_DIR=".rite" RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_LOG_FILE="$RITE_TEST_TMPDIR/diag.log"; touch "$RITE_LOG_FILE"
  _diag() { printf '[diag] %s\n' "$*" >> "$RITE_LOG_FILE"; }
  unset RITE_VERBOSE
  cd "$FIXTURE_REPO"
}

teardown() { teardown_test_tmpdir; }

_setup_conflict() {
  printf 'base\n' > conflict.txt; git add conflict.txt; git commit -qm "base"; git push -q origin main
  git checkout -qb feat/dirty-tree main
  printf 'branch\n' > conflict.txt; git commit -qam "branch edit"
  git checkout -q main; printf 'main\n' > conflict.txt; git commit -qam "main edit"; git push -q origin main
  git checkout -q feat/dirty-tree
}

_stub_provider_resolving() {
  provider_run_agentic_session() { printf 'resolved\n' > conflict.txt; return 0; }
  load_provider() { return 0; }; provider_detect_cli() { return 0; }; provider_healthcheck() { return 0; }
}

@test "dirty conflicting file: the merge refusal is named as uncommitted changes, not as an add/add collision" {
  _setup_conflict
  printf 'branch\noperator WIP\n' > conflict.txt    # dirty, tracked, overlaps the incoming change
  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"; set +u; set +o pipefail
  _stub_provider_resolving
  run attempt_claude_merge_resolution --branch-name feat/dirty-tree --issue-number 1 --merge-target origin/main
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes in the working tree"* ]]
  [[ "$output" != *"could not identify a stashed colliding path"* ]]
  grep -q "operator WIP" conflict.txt      # nothing was destroyed
}

@test "clean tree: the resolver resolves the conflict as before" {
  _setup_conflict
  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"; set +u; set +o pipefail
  _stub_provider_resolving
  run attempt_claude_merge_resolution --branch-name feat/dirty-tree --issue-number 1 --merge-target origin/main
  [ "$status" -eq 0 ]
  [ "$(cat conflict.txt)" = "resolved" ]
}
