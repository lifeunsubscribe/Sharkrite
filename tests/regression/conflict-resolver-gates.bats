#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/conflict-resolver.sh
# tests/regression/conflict-resolver-gates.bats
#
# Verifies the two post-resolution viability gates added in issue #1603:
#
#   Check 3 (syntax): every resolved *.sh / bin/* file must pass bash -n
#   Check 4 (test-count): every resolved *.bats file must have an @test count
#     that is NOT strictly lower than BOTH index parents.
#
# These tests call _cr_check_resolution_gates() directly (extracted helper).
# The function requires a git repo in a conflicted-merge state so that
# git cat-file -e :2:file and git show :2:file / :3:file resolve correctly.
#
# Root cause for Checks 3+4: PR #1328 (2026-10-25) produced a bats resolution
# whose sharkrite-extract markers didn't exist in local-review.sh.  Zero
# markers, no unmerged paths — Checks 1+2 passed.  Four tests silently stopped
# asserting anything.  Main red for a week (fixed in #1593).

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Git fixture helpers
# ---------------------------------------------------------------------------

# _make_conflict_repo: creates a minimal git repo with two conflicting files
# in a mid-merge state.  After this call:
#   REPO         — path to the repo
#   CONFLICT_SH  — the .sh file name (relative)
#   CONFLICT_BATS — the .bats file name (relative)
#
# Index state after setup:
#   :1:helper.sh   = base (unused by gates)
#   :2:helper.sh   = main/ours  version
#   :3:helper.sh   = side/theirs version
#   :2:tests.bats  = 4 @test blocks (ours)
#   :3:tests.bats  = 4 @test blocks (theirs)
#
# The working tree has raw conflict markers — each test writes its own
# resolution before calling the gate.
_make_conflict_repo() {
  REPO="$RITE_TEST_TMPDIR/gaterepo"
  CONFLICT_SH="helper.sh"
  CONFLICT_BATS="tests.bats"

  mkdir -p "$REPO"
  cd "$REPO" || return 1
  git init -q
  git config user.email t@t
  git config user.name t

  # Base commit shared by both sides
  printf '#!/bin/bash\nbase_fn() { echo base; }\n' > helper.sh
  printf '#!/usr/bin/env bats\n@test "base 1" { true; }\n@test "base 2" { true; }\n@test "base 3" { true; }\n' > tests.bats
  printf 'initial\n' > readme.md
  git add helper.sh tests.bats readme.md
  git commit -qm base
  git branch -M main

  # Side branch: add a function to helper.sh, one more @test to tests.bats
  git checkout -qb side
  printf '#!/bin/bash\nbase_fn() { echo base; }\nside_fn() { echo side; }\n' > helper.sh
  printf '#!/usr/bin/env bats\n@test "base 1" { true; }\n@test "base 2" { true; }\n@test "base 3" { true; }\n@test "side test 4" { true; }\n' > tests.bats
  printf 'side doc\n' > readme.md
  git add helper.sh tests.bats readme.md
  git commit -qm "side changes"

  # Main: different conflicting change to same files (creates 3-way conflict)
  git checkout -q main
  printf '#!/bin/bash\nbase_fn() { echo base; }\nmain_fn() { echo main; }\n' > helper.sh
  printf '#!/usr/bin/env bats\n@test "base 1" { true; }\n@test "base 2" { true; }\n@test "base 3" { true; }\n@test "main test 4" { true; }\n' > tests.bats
  printf 'main doc\n' > readme.md
  git add helper.sh tests.bats readme.md
  git commit -qm "main changes"

  # Merge side into main — creates conflicts in helper.sh and tests.bats.
  # readme.md conflicts too (all three ancestors rewrite the same line).
  git merge --no-edit side >/dev/null 2>&1 || true
  # Stage 2 = ours (main): 4 @test blocks  Stage 3 = theirs (side): 4 @test blocks
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"

  # Provide _diag so the CONFLICT_RESOLVE_GATE line is captured in DIAG_LOG
  DIAG_LOG="$RITE_TEST_TMPDIR/gate-diag.log"
  export RITE_LOG_FILE="$DIAG_LOG"
  touch "$DIAG_LOG"
  unset RITE_VERBOSE

  # Define _diag before sourcing — conflict-resolver.sh guards with declare -f
  _diag() { [ -n "${RITE_LOG_FILE:-}" ] && echo "[diag] $*" >> "$RITE_LOG_FILE"; }

  # Source conflict-resolver.sh to get _cr_check_resolution_gates
  # gh_safe must be defined first so the conditional source of gh-retry.sh is skipped
  gh_safe() { :; }
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: conflict-resolver.sh uses a function-sentinel guard (declare -f attempt_claude_merge_resolution); pre-source _diag and gh_safe stubs are preserved on source.
  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"
  set +u; set +o pipefail
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Check 3: Syntax gate
# ---------------------------------------------------------------------------

@test "syntax gate: rejects resolved .sh file with parse error, reports file name" {
  _make_conflict_repo
  cd "$REPO"

  # Write a valid resolution for tests.bats so only helper.sh triggers the gate
  printf '#!/usr/bin/env bats\n@test "merged 1" { true; }\n@test "merged 2" { true; }\n@test "merged 3" { true; }\n@test "merged 4" { true; }\n' > tests.bats

  # Write a syntactically invalid resolution to helper.sh
  printf '#!/bin/bash\nif [\n' > helper.sh

  local exit_code=0
  local combined
  combined=$(_cr_check_resolution_gates "helper.sh
tests.bats" 2>&1) || exit_code=$?

  [ "$exit_code" -ne 0 ]
  echo "$combined" | grep -q "helper.sh"
}

@test "syntax gate: accepts resolved .sh file with valid syntax" {
  _make_conflict_repo
  cd "$REPO"

  printf '#!/bin/bash\nbase_fn() { echo base; }\nside_fn() { echo side; }\nmain_fn() { echo main; }\n' > helper.sh

  local exit_code=0
  _cr_check_resolution_gates "helper.sh" 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "syntax gate: bash -n error message is forwarded to stderr" {
  _make_conflict_repo
  cd "$REPO"

  printf '#!/bin/bash\nfor x in\n' > helper.sh

  local err_out
  err_out=$(_cr_check_resolution_gates "helper.sh" 2>&1 >/dev/null) || true
  # bash -n emits something like "helper.sh: line 2: syntax error near unexpected token"
  echo "$err_out" | grep -qiE 'syntax error|parse error|unexpected'
}

# ---------------------------------------------------------------------------
# Check 4: Test-count gate
# ---------------------------------------------------------------------------

@test "test-count gate: rejects resolution with count strictly below both parents" {
  _make_conflict_repo
  cd "$REPO"

  # Write a valid .sh resolution so it doesn't trigger the syntax gate
  printf '#!/bin/bash\nbase_fn() { echo base; }\nside_fn() { echo side; }\nmain_fn() { echo main; }\n' > helper.sh

  # Stage 2 and stage 3 each have 4 @test blocks.  Write only 2 — below both.
  printf '#!/usr/bin/env bats\n@test "merged 1" { true; }\n@test "merged 2" { true; }\n' > tests.bats

  local exit_code=0
  local combined
  combined=$(_cr_check_resolution_gates "helper.sh
tests.bats" 2>&1) || exit_code=$?

  [ "$exit_code" -ne 0 ]
  echo "$combined" | grep -q "tests.bats"
}

@test "test-count gate: accepts resolution with count equal to lower parent" {
  _make_conflict_repo
  cd "$REPO"

  printf '#!/bin/bash\nbase_fn() { echo base; }\nside_fn() { echo side; }\nmain_fn() { echo main; }\n' > helper.sh

  # Both parents have 4 @test blocks.  Write 4 — equal to both → pass.
  printf '#!/usr/bin/env bats\n@test "merged 1" { true; }\n@test "merged 2" { true; }\n@test "merged 3" { true; }\n@test "merged 4" { true; }\n' > tests.bats

  local exit_code=0
  _cr_check_resolution_gates "helper.sh
tests.bats" 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "test-count gate: accepts resolution below one parent when above the other" {
  # Scenario: ours has 5 @test, theirs has 3 @test, merged has 4 @test.
  # 4 < 5 (ours) but 4 >= 3 (theirs) → not strictly below both → pass.
  REPO="$RITE_TEST_TMPDIR/asymrepo"
  mkdir -p "$REPO"
  cd "$REPO"
  git init -q
  git config user.email t@t
  git config user.name t

  # Base: 3 tests
  printf '#!/usr/bin/env bats\n@test "t1" { true; }\n@test "t2" { true; }\n@test "t3" { true; }\n' > suite.bats
  git add suite.bats && git commit -qm base
  git branch -M main

  # Side (theirs): removes one test → 2, adds a different one → stays 3
  git checkout -qb side
  printf '#!/usr/bin/env bats\n@test "t1" { true; }\n@test "t2" { true; }\n@test "t3-side" { true; }\n' > suite.bats
  git add suite.bats && git commit -qm "side"

  # Main (ours): adds two new tests → 5
  git checkout -q main
  printf '#!/usr/bin/env bats\n@test "t1" { true; }\n@test "t2" { true; }\n@test "t3" { true; }\n@test "t4" { true; }\n@test "t5" { true; }\n' > suite.bats
  git add suite.bats && git commit -qm "main"

  # Merge creates conflict; ours=5 @test, theirs=3 @test
  git merge --no-edit side >/dev/null 2>&1 || true

  # Resolution: 4 @test — below ours (5) but NOT below theirs (3) → pass
  printf '#!/usr/bin/env bats\n@test "t1" { true; }\n@test "t2" { true; }\n@test "t3" { true; }\n@test "t4" { true; }\n' > suite.bats

  local exit_code=0
  _cr_check_resolution_gates "suite.bats" 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "test-count gate: bats file on only one parent — no false failure" {
  # Scenario: a modify/delete conflict — side (theirs) modifies the bats file,
  # ours deletes it.  This produces stage 3 present and stage 2 absent, which
  # exercises the has_theirs=true, has_ours=false path.  The gate must skip the
  # comparison and pass — a one-sided file is not an invented deletion.
  REPO="$RITE_TEST_TMPDIR/oneparentrepo"
  mkdir -p "$REPO"
  cd "$REPO"
  git init -q
  git config user.email t@t
  git config user.name t

  # Base: bats file exists on both sides initially
  printf '#!/usr/bin/env bats\n@test "t1" { true; }\n@test "t2" { true; }\n' > shared.bats
  printf 'placeholder\n' > readme.md
  git add shared.bats readme.md && git commit -qm base
  git branch -M main

  # Side (theirs): modifies the bats file (adds a test)
  git checkout -qb side
  printf '#!/usr/bin/env bats\n@test "t1" { true; }\n@test "t2" { true; }\n@test "t3-side" { true; }\n' > shared.bats
  git add shared.bats && git commit -qm "side modifies bats"

  # Main (ours): deletes the bats file — produces modify/delete conflict on merge
  git checkout -q main
  git rm -q shared.bats
  git commit -qm "main deletes bats"

  # Merge creates modify/delete conflict: stage 3 present (theirs), stage 2 absent (ours)
  git merge --no-edit side >/dev/null 2>&1 || true

  # Resolution: write a resolved version (ours chose to keep the file)
  printf '#!/usr/bin/env bats\n@test "t1" { true; }\n@test "t2" { true; }\n@test "t3-side" { true; }\n' > shared.bats
  git add shared.bats

  local exit_code=0
  _cr_check_resolution_gates "shared.bats" 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "test-count gate: deleted .bats file (count=0) is rejected when both parents had tests" {
  _make_conflict_repo
  cd "$REPO"

  # Write a valid .sh resolution so it doesn't trigger the syntax gate
  printf '#!/bin/bash\nbase_fn() { echo base; }\nside_fn() { echo side; }\nmain_fn() { echo main; }\n' > helper.sh

  # Delete the .bats file — count=0, strictly below both parents (each had 4)
  rm -f tests.bats

  local exit_code=0
  local combined
  combined=$(_cr_check_resolution_gates "helper.sh
tests.bats" 2>&1) || exit_code=$?

  [ "$exit_code" -ne 0 ]
  echo "$combined" | grep -q "tests.bats"
}

# ---------------------------------------------------------------------------
# Non-shell, non-bats files are unaffected
# ---------------------------------------------------------------------------

@test "non-shell non-bats file: no gate, no output, accepted silently" {
  _make_conflict_repo
  cd "$REPO"

  # Write a plain text resolution
  printf 'merged doc content\n' > readme.md

  local exit_code=0
  local combined
  combined=$(_cr_check_resolution_gates "readme.md" 2>&1) || exit_code=$?
  [ "$exit_code" -eq 0 ]
  [ -z "$combined" ]
}

# ---------------------------------------------------------------------------
# Diag line
# ---------------------------------------------------------------------------

@test "diag: CONFLICT_RESOLVE_GATE outcome=passed emitted for clean resolution" {
  _make_conflict_repo
  cd "$REPO"

  printf '#!/bin/bash\nbase_fn() { echo base; }\nside_fn() { echo side; }\nmain_fn() { echo main; }\n' > helper.sh
  printf '#!/usr/bin/env bats\n@test "merged 1" { true; }\n@test "merged 2" { true; }\n@test "merged 3" { true; }\n@test "merged 4" { true; }\n' > tests.bats

  _cr_check_resolution_gates "helper.sh
tests.bats" 2>/dev/null

  grep -q "CONFLICT_RESOLVE_GATE outcome=passed" "$DIAG_LOG"
  grep -q "syntax=0" "$DIAG_LOG"
  grep -q "testcount=0" "$DIAG_LOG"
}

@test "diag: CONFLICT_RESOLVE_GATE outcome=failed emitted when gate rejects" {
  _make_conflict_repo
  cd "$REPO"

  # Syntax error in helper.sh
  printf '#!/bin/bash\nif [\n' > helper.sh
  printf '#!/usr/bin/env bats\n@test "merged 1" { true; }\n' > tests.bats

  _cr_check_resolution_gates "helper.sh
tests.bats" 2>/dev/null || true

  grep -q "CONFLICT_RESOLVE_GATE outcome=failed" "$DIAG_LOG"
  grep -q "syntax=1" "$DIAG_LOG"
}

# ---------------------------------------------------------------------------
# Structural: verify the gates are wired into conflict-resolver.sh
# ---------------------------------------------------------------------------

@test "structural: conflict-resolver.sh contains bash -n check" {
  grep -q 'bash -n' "${RITE_REPO_ROOT}/lib/utils/conflict-resolver.sh"
}

@test "structural: CONFLICT_RESOLVE_GATE diag is emitted in conflict-resolver.sh" {
  grep -q 'CONFLICT_RESOLVE_GATE' "${RITE_REPO_ROOT}/lib/utils/conflict-resolver.sh"
}

@test "structural: Check 3 and Check 4 precede commit_resolved_conflicts" {
  local sut="${RITE_REPO_ROOT}/lib/utils/conflict-resolver.sh"
  local gate_line commit_line
  gate_line=$(awk '/CONFLICT_RESOLVE_GATE/{print NR; exit}' "$sut")
  commit_line=$(awk '/^commit_resolved_conflicts\(\)/{print NR; exit}' "$sut")
  [ -n "$gate_line" ] && [ -n "$commit_line" ]
  [ "$gate_line" -lt "$commit_line" ]
}
