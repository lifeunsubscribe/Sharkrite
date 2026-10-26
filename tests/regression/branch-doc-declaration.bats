#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite
# tests/regression/branch-doc-declaration.bats
#
# Regression tests for #1426: --doc <path> flag alongside --branch.
# Pins the four acceptance criteria:
#   1. Invalid --doc path (non-.md or nonexistent) → exit 1 with corrected command
#   2. Declaration persists at ${RITE_STATE_DIR}/declared-doc-<branch>.txt
#   3. --branch without --doc when tracking is on → exactly one warning line, no exit
#   4. --doc without --branch → usage error exit 1
#
# All bin/rite invocations carry < /dev/null on the run line
# (BATS_RITE_STDIN_GUARD: prevents the gate's --jobs 8 from
# SIGTTIN-stopping the process group).

load '../helpers/setup'

setup() {
  setup_test_tmpdir
  unset RITE_TARGET_BRANCH RITE_DOC_MODE RITE_LOG_FILE
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
  mkdir -p "$RITE_TEST_TMPDIR/.rite/state"
  # Provide a real .md file inside the repo for positive cases
  mkdir -p "$RITE_TEST_TMPDIR/docs/features"
  printf '# Feature doc\n' > "$RITE_TEST_TMPDIR/docs/features/foo.md"
  # Write a minimal .rite/config so config.sh finds a project
  printf '# .rite/config\n' > "$RITE_TEST_TMPDIR/.rite/config"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Acceptance criterion 1a: non-.md path → exit 1
# ---------------------------------------------------------------------------

@test "--doc: rejects non-.md path (exit 1, corrected command in output)" {
  run bash "$RITE_REPO_ROOT/bin/rite" --branch feat/my-feature --doc docs/features/foo.txt < /dev/null
  [ "$status" -eq 1 ]
  _cnt=$(echo "$output" | grep -cE 'must be a .md' || true)
  [ "$_cnt" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 1b: .md path that does not exist → exit 1
# ---------------------------------------------------------------------------

@test "--doc: rejects nonexistent file (exit 1, corrected command in output)" {
  run bash "$RITE_REPO_ROOT/bin/rite" --branch feat/my-feature --doc docs/features/missing.md < /dev/null
  [ "$status" -eq 1 ]
  _cnt=$(echo "$output" | grep -c 'not found' || true)
  [ "$_cnt" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 1c: existing .md outside repo root → exit 1
# ---------------------------------------------------------------------------

@test "--doc: rejects .md path outside repo root (exit 1)" {
  local _outside_file="$BATS_TEST_TMPDIR/outside.md"
  printf '# outside\n' > "$_outside_file"
  run bash "$RITE_REPO_ROOT/bin/rite" --branch feat/my-feature --doc "$_outside_file" < /dev/null
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 2: valid --doc persists to state file
# ---------------------------------------------------------------------------

@test "--doc: valid path persists to declared-doc-<branch>.txt in RITE_STATE_DIR" {
  run bash "$RITE_REPO_ROOT/bin/rite" --branch feat/my-feature --doc docs/features/foo.md --version < /dev/null
  [ "$status" -eq 0 ]
  local _state_file="$RITE_STATE_DIR/declared-doc-feat-my-feature.txt"
  [ -f "$_state_file" ]
  local _contents
  _contents=$(cat "$_state_file")
  [ "$_contents" = "docs/features/foo.md" ]
}

@test "--doc: branch name slashes replaced with dashes in state file name" {
  run bash "$RITE_REPO_ROOT/bin/rite" --branch feat/slash/safe --doc docs/features/foo.md --version < /dev/null
  [ "$status" -eq 0 ]
  [ -f "$RITE_STATE_DIR/declared-doc-feat-slash-safe.txt" ]
}

@test "--doc: state file survives re-invocation without --doc (file remains)" {
  # First run: write state file
  run bash "$RITE_REPO_ROOT/bin/rite" --branch feat/my-feature --doc docs/features/foo.md --version < /dev/null
  [ "$status" -eq 0 ]
  local _state_file="$RITE_STATE_DIR/declared-doc-feat-my-feature.txt"
  [ -f "$_state_file" ]
  # Second run without --doc: state file must still be present
  run bash "$RITE_REPO_ROOT/bin/rite" --branch feat/my-feature --version < /dev/null
  [ -f "$_state_file" ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 3: --branch without --doc, tracking on → one warning
# ---------------------------------------------------------------------------

@test "--branch without --doc with tracking on prints exactly one warning line" {
  run env RITE_DOC_MODE=sync bash "$RITE_REPO_ROOT/bin/rite" --branch feat/my-feature --version < /dev/null
  [ "$status" -eq 0 ]
  _cnt=$(echo "$output" | grep -c 'feature doc association missing' || true)
  [ "$_cnt" -eq 1 ]
}

@test "--branch without --doc with changelog tracking prints exactly one warning line" {
  run env RITE_DOC_MODE=changelog bash "$RITE_REPO_ROOT/bin/rite" --branch feat/my-feature --version < /dev/null
  [ "$status" -eq 0 ]
  _cnt=$(echo "$output" | grep -c 'feature doc association missing' || true)
  [ "$_cnt" -eq 1 ]
}

@test "--branch without --doc with tracking off prints no warning" {
  run env RITE_DOC_MODE=off bash "$RITE_REPO_ROOT/bin/rite" --branch feat/my-feature --version < /dev/null
  [ "$status" -eq 0 ]
  _cnt=$(echo "$output" | grep -c 'feature doc association missing' || true)
  [ "$_cnt" -eq 0 ]
}

@test "--branch without --doc with tracking unset prints no warning" {
  run bash "$RITE_REPO_ROOT/bin/rite" --branch feat/my-feature --version < /dev/null
  [ "$status" -eq 0 ]
  _cnt=$(echo "$output" | grep -c 'feature doc association missing' || true)
  [ "$_cnt" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 4: --doc without --branch → usage error exit 1
# ---------------------------------------------------------------------------

@test "--doc without --branch is a usage error (exit 1)" {
  run bash "$RITE_REPO_ROOT/bin/rite" --doc docs/features/foo.md < /dev/null
  [ "$status" -eq 1 ]
  _cnt=$(echo "$output" | grep -c 'requires --branch' || true)
  [ "$_cnt" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Help text: --doc appears in --help output
# ---------------------------------------------------------------------------

@test "--doc: appears in --help output" {
  run bash "$RITE_REPO_ROOT/bin/rite" --help < /dev/null
  [ "$status" -eq 0 ]
  _cnt=$(echo "$output" | grep -c -- '--doc <path>' || true)
  [ "$_cnt" -ge 1 ]
}
