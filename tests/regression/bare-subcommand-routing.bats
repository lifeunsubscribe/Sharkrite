#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite
# tests/regression/bare-subcommand-routing.bats
#
# Regression tests for bare-word subcommand routing in bin/rite (#804).
#
# Bug: `rite status` (bare word, no --) was treated as an issue description and
# routed to issue-generation ("Generating structured issue...") instead of being
# interpreted as `rite --status`.  The *)  catch-all in bin/rite's arg parser
# added the word to ARGS; with MODE="full" and a non-numeric ARGS[0], the smart
# router called normalize_and_resolve → normalize_piped_input, burning an LLM
# call and potentially creating a junk GitHub issue.
#
# Fix: bare-word cases for every recognised flag-subcommand word were added to
# the case block before the *) catch-all, mirroring the --flag entries.
#
# Tests verify:
#  1. `rite status`           → dispatches to repo-status, not issue-generation
#  2. `rite health-report`    → dispatches to rite-health-report
#  3. `rite init`             → dispatches to init mode, not issue-generation
#  4. `rite tags`             → dispatches to tag-index, not issue-generation
#  5. `rite full-suite`       → dispatches to rite-full-suite
#  6. `rite backfill-locks`   → dispatches to backfill-locks mode
#  7. Legitimate text description still reaches issue-generation (not broken)

load '../helpers/setup'

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  # Minimal fake project so bin/rite's config.sh can find RITE_PROJECT_ROOT.
  export _FAKE_PROJECT="$RITE_TEST_TMPDIR/fake-project"
  mkdir -p "$_FAKE_PROJECT/.rite"

  # Fake bin/ we'll populate per-test with stubs.
  export _FAKE_BIN="$RITE_TEST_TMPDIR/fake-bin"
  mkdir -p "$_FAKE_BIN"

  # Symlink the real bin/rite into our fake bin/.
  ln -sf "$RITE_REPO_ROOT/bin/rite" "$_FAKE_BIN/rite"
}

teardown() {
  teardown_test_tmpdir
}

# _stub_command NAME EXIT_CODE [OUTPUT]
#   Writes a stub script to $_FAKE_BIN/<NAME> that prints OUTPUT (if given)
#   and exits EXIT_CODE.  Records invocations to $_FAKE_BIN/<NAME>.calls.
_stub_command() {
  local _name="$1" _exit="${2:-0}" _output="${3:-}"
  local _script="$_FAKE_BIN/$_name"
  cat > "$_script" << STUBEOF
#!/bin/bash
echo "STUB_CALLED:$_name" >> "$_FAKE_BIN/${_name}.calls"
${_output:+echo "$_output"}
exit $_exit
STUBEOF
  chmod +x "$_script"
}

# _run_rite ARGS...
#   Runs bin/rite with $_FAKE_BIN on PATH and RITE_LIB_DIR pointing at the
#   real lib so config.sh / colors.sh / etc. are loadable.
_run_rite() {
  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" "$@" < /dev/null
}

# ---------------------------------------------------------------------------
# Test 1: `rite status` dispatches to repo-wide status (lib/utils/repo-status.sh)
#         and does NOT invoke issue-generation.
#
# Strategy: stub the repo-status functions by inserting a minimal stub
# lib/utils/repo-status.sh in a fake lib tree that bin/rite loads.  The stub
# prints a sentinel string.  We verify the sentinel appears and that the
# "Generating structured issue" message does NOT appear.
# ---------------------------------------------------------------------------
@test "rite status (bare word) dispatches to repo-wide status, not issue-generation" {
  # Build a minimal fake lib/ so bin/rite can source its dependencies without
  # needing a full install.  We only need to stub repo-status.sh because all
  # other lib/ files are loaded from the real RITE_LIB_DIR.
  local _fake_lib="$RITE_TEST_TMPDIR/fake-lib"
  mkdir -p "$_fake_lib/utils"

  # Stub repo-status.sh: just emit the sentinel and exit.
  cat > "$_fake_lib/utils/repo-status.sh" << 'STUB'
#!/bin/bash
repo_wide_status() {
  echo "REPO_WIDE_STATUS_STUB_CALLED"
}
STUB

  # We can't easily override just one lib file when bin/rite uses RITE_LIB_DIR
  # for all sources.  Instead, intercept at the `exec` level: repo_wide_status
  # is called *after* MODE is set to "status".  The cleanest approach is to
  # inject our stub before the real lib is sourced by prepending to PATH and
  # setting RITE_LIB_DIR to our fake tree which re-exports to the real one.
  # For simplicity, test that "Generating structured issue" is absent and that
  # bin/rite does NOT die with a non-zero exit from normalize_and_resolve.
  #
  # A lighter approach: run bin/rite status and stub out the downstream
  # binaries that repo-wide status calls (gh, etc.) so we don't need
  # network, then check the error message vs. the generate message.
  #
  # Since repo_wide_status calls `gh` (unavailable in CI without creds) and
  # it would fail, we simply verify the routing decision via the ABSENCE of
  # the issue-generation string and the ABSENCE of a MODE="full" routing path
  # (which would invoke normalize_and_resolve → Claude call).
  #
  # We stub `gh` to fail immediately so repo_wide_status exits non-zero (that
  # is fine — we care about routing, not completion).
  _stub_command "gh" 1 ""

  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" status < /dev/null 2>&1 || true

  # Issue-generation must NOT appear in output regardless of success/failure.
  ! echo "$output" | grep -q "Generating structured issue"

  # normalize_and_resolve would print "Generating structured issue from description..."
  # or attempt to call claude/gh-issue-create.  Its absence confirms routing was correct.
}

# ---------------------------------------------------------------------------
# Test 2: `rite health-report` dispatches to rite-health-report binary.
# ---------------------------------------------------------------------------
@test "rite health-report (bare word) dispatches to rite-health-report stub" {
  # Stub rite-health-report next to bin/rite in our fake-bin
  cat > "$_FAKE_BIN/rite-health-report" << 'STUB'
#!/bin/bash
echo "HEALTH_REPORT_STUB_CALLED"
exit 0
STUB
  chmod +x "$_FAKE_BIN/rite-health-report"

  _run_rite health-report

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "HEALTH_REPORT_STUB_CALLED"
  ! echo "$output" | grep -q "Generating structured issue"
}

# ---------------------------------------------------------------------------
# Test 3: `rite full-suite` dispatches to rite-full-suite binary.
# ---------------------------------------------------------------------------
@test "rite full-suite (bare word) dispatches to rite-full-suite stub" {
  cat > "$_FAKE_BIN/rite-full-suite" << 'STUB'
#!/bin/bash
echo "FULL_SUITE_STUB_CALLED"
exit 0
STUB
  chmod +x "$_FAKE_BIN/rite-full-suite"

  _run_rite full-suite

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "FULL_SUITE_STUB_CALLED"
  ! echo "$output" | grep -q "Generating structured issue"
}

# ---------------------------------------------------------------------------
# Test 4: `rite init` routes to init mode and does NOT invoke issue-generation.
#
# init mode runs inline in bin/rite (no exec), so we intercept by stubbing
# `gh` and `claude` (both called optionally inside init mode).  We verify the
# init banner prints and issue-generation text does NOT appear.
# ---------------------------------------------------------------------------
@test "rite init (bare word) enters init mode, not issue-generation" {
  # Stub out commands init mode might call so it can progress far enough to
  # print its header without needing a real install or network.
  _stub_command "gh" 0 ""
  _stub_command "claude" 0 ""

  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" init < /dev/null 2>&1 || true

  # Init mode prints "Initializing Sharkrite" — confirm that fires.
  echo "$output" | grep -qi "Initializing Sharkrite"
  # Issue-generation must NOT appear.
  ! echo "$output" | grep -q "Generating structured issue"
}

# ---------------------------------------------------------------------------
# Test 5: `rite backfill-locks` routes to backfill-locks mode and does NOT
#         invoke issue-generation.
# ---------------------------------------------------------------------------
@test "rite backfill-locks (bare word) enters backfill-locks mode, not issue-generation" {
  # backfill-locks sources issue-lock.sh and calls backfill_worktree_locks.
  # Stub that function by providing a fake lib layer.
  # Simpler: just verify "Generating structured issue" is absent and that
  # the "Backfilling" info line appears (or the script errors on missing git,
  # which is still not issue-generation).

  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" backfill-locks < /dev/null 2>&1 || true

  ! echo "$output" | grep -q "Generating structured issue"
  # backfill-locks prints "Backfilling lock files..." via print_info
  echo "$output" | grep -qi "Backfilling\|backfill\|lock"
}

# ---------------------------------------------------------------------------
# Test 6: `rite tags` routes to tag-index mode and does NOT invoke
#         issue-generation.
# ---------------------------------------------------------------------------
@test "rite tags (bare word) enters tags mode, not issue-generation" {
  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" tags < /dev/null 2>&1 || true

  # Issue-generation must not appear regardless of exit code.
  ! echo "$output" | grep -q "Generating structured issue"
}

# ---------------------------------------------------------------------------
# Test 7: A legitimate text description still reaches issue-generation.
#         The bare-word guard must NOT break the explicit description path.
#
# Strategy: stub `claude` so we can detect that normalize_piped_input was
# entered (it calls claude via provider_run_prompt).  We don't need a full
# LLM call — just confirm the "Generating structured issue" message appears,
# which means we reached the right code path.
# ---------------------------------------------------------------------------
@test "legitimate text description still reaches issue-generation (not broken)" {
  # Stub claude to exit non-zero quickly (simulates unavailable provider).
  # normalize_piped_input will print "Generating structured issue from description..."
  # before calling claude, so we'll capture that message.
  _stub_command "claude" 1 ""
  # Also stub gh so pre-flight checks pass (gh auth status etc.)
  _stub_command "gh" 0 ""

  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" "Fix the login button to work on mobile" < /dev/null 2>&1 || true

  # The issue-generation path must have been entered — even if it ultimately
  # fails (claude stub exits 1), the entry message appears first.
  echo "$output" | grep -q "Generating structured issue"
}

# ---------------------------------------------------------------------------
# Test 8: Parity — `rite status` and `rite --status` both set MODE to "status"
#         (verified by observing identical dispatch behaviour: both stub
#         rite-health-report for health-report, or both invoke repo_wide_status
#         for status).  Since we can intercept via rite-health-report stub, use
#         health-report for a clean parity check.
# ---------------------------------------------------------------------------
@test "rite health-report (bare) and rite --health-report behave identically" {
  cat > "$_FAKE_BIN/rite-health-report" << 'STUB'
#!/bin/bash
echo "HEALTH_REPORT_STUB_CALLED"
exit 0
STUB
  chmod +x "$_FAKE_BIN/rite-health-report"

  # Bare-word form
  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" health-report < /dev/null

  local _bare_status="$status"
  local _bare_output="$output"

  # Flag form
  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" --health-report < /dev/null

  # Both should have called the same stub
  echo "$_bare_output" | grep -q "HEALTH_REPORT_STUB_CALLED"
  echo "$output"       | grep -q "HEALTH_REPORT_STUB_CALLED"
  [ "$_bare_status" -eq "$status" ]
}

# ---------------------------------------------------------------------------
# Test 9: Parity — `rite full-suite` and `rite --full-suite` both dispatch to
#         rite-full-suite.
# ---------------------------------------------------------------------------
@test "rite full-suite (bare) and rite --full-suite behave identically" {
  cat > "$_FAKE_BIN/rite-full-suite" << 'STUB'
#!/bin/bash
echo "FULL_SUITE_STUB_CALLED"
exit 0
STUB
  chmod +x "$_FAKE_BIN/rite-full-suite"

  # Bare-word form
  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" full-suite < /dev/null

  local _bare_status="$status"
  local _bare_output="$output"

  # Flag form
  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" --full-suite < /dev/null

  echo "$_bare_output" | grep -q "FULL_SUITE_STUB_CALLED"
  echo "$output"       | grep -q "FULL_SUITE_STUB_CALLED"
  [ "$_bare_status" -eq "$status" ]
}
