#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/integration-sync.sh, bin/rite
# tests/regression/sync-integration-branch.bats
#
# Regression tests for `rite --sync <branch>` (integration-sync.sh, #1035).
#
# Test strategy: structural greps for the invariant contracts (no rebase,
# no force-push, resolver availability-guard), plus behavioral bin/rite
# dispatch tests using the dry-run flag and the bare-word alias.
#
# We do NOT test the live git merge path (requires a real git repo with
# remote state) — that is a network integration test. We test:
#   1. Arg validation (missing branch, "main" refusal)
#   2. Dry-run routing via --dry-run flag
#   3. Bare-word alias routing (rite sync <branch> == rite --sync <branch>)
#   4. Design-contract greps (no rebase, no force-push, resolver guard,
#      diag INTEGRATION_SYNC present)

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  # Minimal fake project so bin/rite's config.sh can find RITE_PROJECT_ROOT.
  export _FAKE_PROJECT="$RITE_TEST_TMPDIR/fake-project"
  mkdir -p "$_FAKE_PROJECT/.rite"

  # Fake bin/ directory populated per-test with stubs.
  export _FAKE_BIN="$RITE_TEST_TMPDIR/fake-bin"
  mkdir -p "$_FAKE_BIN"

  # Symlink the real bin/rite into our fake bin/.
  ln -sf "$RITE_REPO_ROOT/bin/rite" "$_FAKE_BIN/rite"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# _run_rite ARGS...
#   Runs bin/rite under a minimal environment: RITE_LIB_DIR from the real lib,
#   RITE_PROJECT_ROOT from a fake project dir, logging off.
# ---------------------------------------------------------------------------
_run_rite() {
  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" "$@" < /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Test 1: Missing branch arg is rejected with usage message.
# ---------------------------------------------------------------------------
@test "--sync with no branch arg exits non-zero and prints usage" {
  _run_rite --sync || true

  # Must exit non-zero
  [ "$status" -ne 0 ]

  # Must print something about --sync and branch requirement
  echo "$output" | grep -qi "\-\-sync"
}

# ---------------------------------------------------------------------------
# Test 2: --sync main is refused.
# ---------------------------------------------------------------------------
@test "--sync main is refused with explanatory error" {
  _run_rite --sync main || true

  [ "$status" -ne 0 ]
  # Error must mention that syncing main is not allowed / meaningless
  echo "$output" | grep -qi "main"
}

# ---------------------------------------------------------------------------
# Test 3: --dry-run --sync <branch> prints a sync execution plan (no side effects).
# ---------------------------------------------------------------------------
@test "--dry-run --sync demo-branch prints integration-sync plan" {
  _run_rite --dry-run --sync demo-branch

  [ "$status" -eq 0 ]
  # Dry-run plan must mention the integration-sync function and branch name
  echo "$output" | grep -qi "integration.sync\|sync_integration_branch"
  echo "$output" | grep -q "demo-branch"
}

# ---------------------------------------------------------------------------
# Test 4: Bare-word alias `rite sync <branch>` produces the same dry-run plan
#         as the flag form `rite --sync <branch>`.
# ---------------------------------------------------------------------------
@test "bare-word 'sync <branch>' produces same dry-run plan as '--sync <branch>'" {
  # Capture flag form
  _run_rite --dry-run --sync parity-branch
  local _flag_output="$output"
  local _flag_status="$status"

  # Capture bare-word form
  _run_rite --dry-run sync parity-branch
  local _bare_output="$output"
  local _bare_status="$status"

  # Both must succeed
  [ "$_flag_status" -eq 0 ]
  [ "$_bare_status" -eq 0 ]

  # Both must mention the same branch name and the same function
  echo "$_flag_output" | grep -q "parity-branch"
  echo "$_bare_output" | grep -q "parity-branch"
  echo "$_flag_output" | grep -qi "integration.sync\|sync_integration_branch"
  echo "$_bare_output" | grep -qi "integration.sync\|sync_integration_branch"
}

# ---------------------------------------------------------------------------
# Test 5: Bare-word `rite sync` (no branch) exits non-zero.
# ---------------------------------------------------------------------------
@test "bare-word 'sync' with no branch arg exits non-zero" {
  _run_rite sync || true

  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "sync"
}

# ---------------------------------------------------------------------------
# Test 6: No rebase anywhere in integration-sync.sh (design contract).
# ---------------------------------------------------------------------------
@test "integration-sync.sh contains no 'git rebase' call" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  # grep exits 1 on no match; we want no match → invert
  ! grep -n 'git rebase' "$_lib"
}

# ---------------------------------------------------------------------------
# Test 7: No force push in integration-sync.sh (design contract).
# ---------------------------------------------------------------------------
@test "integration-sync.sh contains no force-push option" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  ! grep -nE 'force-with-lease|push (-f|--force)' "$_lib"
}

# ---------------------------------------------------------------------------
# Test 8: Resolver is availability-guarded (declare -f pattern, stale-branch style).
# ---------------------------------------------------------------------------
@test "integration-sync.sh guards resolver with 'declare -f attempt_claude_merge_resolution'" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  grep -q 'declare -f attempt_claude_merge_resolution' "$_lib"
}

# ---------------------------------------------------------------------------
# Test 9: INTEGRATION_SYNC diag line is emitted (grep for _diag call).
# ---------------------------------------------------------------------------
@test "integration-sync.sh emits INTEGRATION_SYNC diag line via _diag" {
  local _lib="$RITE_REPO_ROOT/lib/utils/integration-sync.sh"
  [ -f "$_lib" ]
  grep -q 'INTEGRATION_SYNC' "$_lib"
}

# ---------------------------------------------------------------------------
# Test 10: --help includes --sync verb.
# ---------------------------------------------------------------------------
@test "--help output includes --sync verb" {
  _run_rite --help || true

  echo "$output" | grep -q -- '--sync'
}
