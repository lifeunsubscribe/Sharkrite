#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Test suite for issue #68: Add auto-commit or fail-loud guard before PR phase
#
# Verifies that when Claude dev session ends with uncommitted changes (files written
# but not committed), the guard auto-commits them to salvage the work.

setup() {
  # Source utils for color codes and print functions
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "${RITE_LIB_DIR}/utils/config.sh"
  source "${RITE_LIB_DIR}/utils/logging.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  # Create a mock git repository
  export TEST_REPO=$(mktemp -d)
  cd "$TEST_REPO" || exit 1

  # Initialize git repo with origin/main
  git init --quiet
  git config user.email "test@example.com"
  git config user.name "Test User"

  # Create initial commit on main
  echo "# Test Repo" > README.md
  git add README.md
  git commit -m "Initial commit" --quiet

  # Simulate origin/main (worktree workflows use origin/main as base)
  git branch -M main
  git remote add origin "file://${TEST_REPO}/.git"
  git fetch origin --quiet
  git branch --set-upstream-to=origin/main main

  # Create feature branch with init commit
  git checkout -b "feat/test-issue-42" --quiet
  git commit --allow-empty -m "chore: initialize work on #42 Test Issue" --quiet

  # Mock environment variables
  export ISSUE_NUMBER=42
  export AUTO_MODE=true
  export RITE_ORCHESTRATED=false
  export RITE_DATA_DIR=".rite"

  # Guard: ensure _diag writes to RITE_LOG_FILE (not stderr).
  # Without this, a caller environment with RITE_VERBOSE=true routes diag
  # output to stderr (captured by bats 'run' in $output) instead of the
  # log file, causing the "logs diagnostic on auto-commit" assertion to
  # fail even though the implementation is correct.  Pattern matches
  # conflict-resolver-diag.bats, followup-lock-timeout-diag.bats, etc.
  unset RITE_VERBOSE

  # Source the function we're testing.
  # RITE_SOURCE_FUNCTIONS_ONLY=1 loads only function definitions without executing
  # the main program body (arg parsing, worktree navigation, Claude dev session).
  # Without this, sourcing launches a real Claude Code session (issue #469).
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "${RITE_LIB_DIR}/core/claude-workflow.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  cd /
  rm -rf "$TEST_REPO"
}

@test "check_dev_session_output: auto-commits uncommitted modified files" {
  # Simulate Claude writing files but not committing them
  echo "function foo() { return 42; }" > lib.js
  git add lib.js
  # Don't commit - this simulates Claude staging but not committing

  # Run the guard
  run check_dev_session_output

  # Should succeed (exit 0)
  [ "$status" -eq 0 ]

  # Should have created an auto-commit
  COMMITS_AHEAD=$(git rev-list --count origin/main..HEAD)
  [ "$COMMITS_AHEAD" -eq 2 ]  # init commit + auto-commit

  # Auto-commit should have the right message
  LAST_COMMIT_MSG=$(git log -1 --format=%s)
  [[ "$LAST_COMMIT_MSG" == *"auto-commit dev session output"* ]]

  # File should be committed
  git diff --quiet HEAD -- lib.js
}

@test "check_dev_session_output: auto-commits untracked files" {
  # Simulate Claude writing new files but not adding/committing them
  mkdir -p src
  echo "export const VERSION = '1.0.0';" > src/version.js
  echo "console.log('test');" > src/index.js
  # Files are untracked (not added)

  # Run the guard
  run check_dev_session_output

  # Should succeed
  [ "$status" -eq 0 ]

  # Should have auto-committed
  COMMITS_AHEAD=$(git rev-list --count origin/main..HEAD)
  [ "$COMMITS_AHEAD" -eq 2 ]

  # Files should be committed
  git diff --quiet HEAD -- src/version.js
  git diff --quiet HEAD -- src/index.js
}

@test "check_dev_session_output: auto-commit excludes .gitignore changes" {
  # .gitignore must be TRACKED for the exclusion to be observable — production
  # scenario is ensure_symlinks_gitignored() appending to a committed .gitignore.
  # (An untracked .gitignore shows no diff vs HEAD whether it was committed or
  # excluded, making the assertion below vacuous.)
  # Amend into the branch-init commit rather than adding a new commit — a
  # second commit ahead of origin/main makes check_dev_session_output treat
  # the branch as already having real work and skip the auto-commit entirely.
  echo "node_modules" > .gitignore
  git add .gitignore
  git commit --amend --no-edit --quiet

  # Simulate sharkrite's .gitignore modification + real code changes
  echo ".rite" >> .gitignore
  echo "function bar() { return 'test'; }" > utils.js

  # Run the guard
  run check_dev_session_output

  # Should succeed
  [ "$status" -eq 0 ]

  # utils.js should be committed
  git diff --quiet HEAD -- utils.js

  # The .gitignore modification must remain uncommitted (decisive because the
  # file is tracked: a swept-up modification would zero this diff)...
  ! git diff --quiet HEAD -- .gitignore

  # ...and the auto-commit itself must not contain .gitignore. (Can't use
  # ls-tree here: .gitignore is legitimately in the tree from the setup
  # commit; we only care that THIS commit didn't touch it.)
  ! git log -1 --format= --name-only | grep -qx '.gitignore'
}

@test "check_dev_session_output: auto-commit excludes worktree symlinks" {
  # Simulate worktree symlinks being present (shouldn't happen but guard should handle)
  ln -s /some/path/.rite .rite
  ln -s /some/path/.claude .claude
  echo "const config = {};" > config.js

  # Add them (simulate accidental staging)
  git add .rite .claude config.js 2>/dev/null || true

  # Run the guard
  run check_dev_session_output

  # Should succeed
  [ "$status" -eq 0 ]

  # config.js should be committed
  git diff --quiet HEAD -- config.js

  # Symlinks should NOT be in the commit
  ! git ls-tree HEAD | grep -q '.rite'
  ! git ls-tree HEAD | grep -q '.claude'
}

@test "check_dev_session_output: logs diagnostic on auto-commit" {
  # Create log file
  export RITE_LOG_FILE=$(mktemp)

  # Simulate uncommitted changes
  echo "test" > file.txt

  # Run the guard
  run check_dev_session_output

  # Should succeed
  [ "$status" -eq 0 ]

  # Diagnostic log should contain AUTO_COMMIT entry
  grep -q "\[diag\].*AUTO_COMMIT" "$RITE_LOG_FILE"
  grep -q "issue=42" "$RITE_LOG_FILE"
  grep -q "reason=dev_session_uncommitted" "$RITE_LOG_FILE"

  # Clean up
  rm -f "$RITE_LOG_FILE"
}

@test "check_dev_session_output: prints user-friendly messages on auto-commit" {
  # Simulate uncommitted changes
  echo "test" > file.txt

  # Run the guard and capture output
  run check_dev_session_output

  # Should succeed
  [ "$status" -eq 0 ]

  # Output should inform user about auto-commit (info-level, single
  # condensed result line — no warning-level framing for a recovered
  # condition; see "no loud benign warnings")
  [[ "$output" =~ "Auto-committing" ]]
  [[ "$output" =~ "workflow proceeding normally" ]]
  [[ "$output" =~ "verify completeness in PR review" ]]
  [[ ! "$output" =~ "ended without committing" ]]
}

@test "check_dev_session_output: no action when real commits exist" {
  # Simulate Claude making a proper commit
  echo "const VERSION = '2.0.0';" > version.js
  git add version.js
  git commit -m "feat: add version constant" --quiet

  # Run the guard
  run check_dev_session_output

  # Should succeed with no output (silent success)
  [ "$status" -eq 0 ]

  # Should not create additional commits
  COMMITS_AHEAD=$(git rev-list --count origin/main..HEAD)
  [ "$COMMITS_AHEAD" -eq 2 ]  # init + real commit (no auto-commit)
}

# ===========================================================================
# _regen_lockfiles_if_needed tests (issue #804)
# These tests share the git-repo setup from the suite above.  They stub npm
# via a PATH-isolated stub dir so the real npm binary is never invoked.
# Per the test runbook: hide a binary by stripping PATH, not by function.
# ===========================================================================

# Helper: build a stub dir with an npm script that succeeds and creates
# package-lock.json, then re-export PATH to include it.
_setup_npm_stub_success() {
  local stub_dir="$TEST_REPO/stub-npm-ok"
  mkdir -p "$stub_dir"
  printf '#!/bin/sh\n# npm stub: succeeds and writes package-lock.json\n# Accept --package-lock-only and --silent flags silently.\ndir=$(pwd)\nprintf '"'"'{"lockfileVersion":3}\n'"'"' > "$dir/package-lock.json"\nexit 0\n' > "$stub_dir/npm"
  chmod +x "$stub_dir/npm"
  export PATH="$stub_dir:$PATH"
}

# Helper: build a stub dir with an npm script that always fails.
_setup_npm_stub_fail() {
  local stub_dir="$TEST_REPO/stub-npm-fail"
  mkdir -p "$stub_dir"
  printf '#!/bin/sh\n# npm stub: always fails\necho "npm ERR! simulated failure" >&2\nexit 1\n' > "$stub_dir/npm"
  chmod +x "$stub_dir/npm"
  export PATH="$stub_dir:$PATH"
}

@test "_regen_lockfiles_if_needed: no-op when no package.json staged" {
  # Stage a regular file — not package.json
  echo "console.log('hi');" > index.js
  git add index.js

  _setup_npm_stub_success

  run _regen_lockfiles_if_needed

  [ "$status" -eq 0 ]
  # npm stub must NOT have been called (no package-lock.json created at all)
  [ ! -f "$TEST_REPO/package-lock.json" ]
}

@test "_regen_lockfiles_if_needed: regenerates root package-lock.json when package.json staged" {
  # Stage a package.json change at the root
  printf '{"name":"test","version":"1.0.0","dependencies":{}}\n' > package.json
  git add package.json

  _setup_npm_stub_success

  run _regen_lockfiles_if_needed

  [ "$status" -eq 0 ]
  # package-lock.json must have been created and staged
  [ -f "$TEST_REPO/package-lock.json" ]
  # It must be staged
  git diff --cached --name-only | grep -q "package-lock.json"
}

@test "_regen_lockfiles_if_needed: regenerates sub-package lockfile in monorepo" {
  # Stage a package.json change in a subdirectory (e.g. api/)
  mkdir -p api
  printf '{"name":"api","version":"1.0.0","dependencies":{}}\n' > api/package.json
  git add api/package.json

  _setup_npm_stub_success

  run _regen_lockfiles_if_needed

  [ "$status" -eq 0 ]
  # package-lock.json must have been created in api/
  [ -f "$TEST_REPO/api/package-lock.json" ]
  git diff --cached --name-only | grep -q "api/package-lock.json"
}

@test "_regen_lockfiles_if_needed: surfaces failure when npm install fails" {
  # Stage a package.json change
  printf '{"name":"test","version":"1.0.0"}\n' > package.json
  git add package.json

  _setup_npm_stub_fail

  run _regen_lockfiles_if_needed

  # Must fail (non-zero exit) so the commit is aborted
  [ "$status" -ne 0 ]
  # Error message must mention npm install failure
  [[ "$output" =~ "npm install failed" ]]
}

@test "_regen_lockfiles_if_needed: warns and skips when npm not on PATH" {
  # Stage a package.json change
  printf '{"name":"test","version":"1.0.0"}\n' > package.json
  git add package.json

  # Remove npm from PATH entirely
  export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "npm" | paste -sd ':' -)
  # Ensure npm truly absent (use a minimal PATH)
  export PATH="/usr/bin:/bin"

  run _regen_lockfiles_if_needed

  # Must succeed (non-Node repos unaffected — don't block the commit)
  [ "$status" -eq 0 ]
  # Warning must mention npm not found
  [[ "$output" =~ "npm not found" ]]
}
