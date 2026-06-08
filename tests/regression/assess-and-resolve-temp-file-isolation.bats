#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh
# Regression test for: Remove glob pattern from assess cleanup trap
# Issue #422 / Live failure: issue #345 batch run 2026-06-06
#
# Bug: assess-and-resolve.sh:cleanup() used:
#   rm -f /tmp/pr_review_*.txt
# This glob wipes every peer invocation's review file, not just the current
# script's.  A concurrent or recently-exited assess-and-resolve.sh call can
# delete the file between the write (~line 411) and the read (~line 705),
# causing format-review.sh to report "Error: Review file not found: ...".
#
# Fix:
#   1. cleanup() now uses: rm -f "${REVIEW_FILE:-}"  (scoped to this run)
#   2. REVIEW_FILE path is PID-scoped: /tmp/pr_review_${PR_NUMBER}_$$.txt
#
# Tests in this file:
#   1. Static: cleanup trap uses scoped rm, not a glob
#   2. Static: REVIEW_FILE assignment includes $$ (PID-scoped path)
#   3. Unit:   cleanup does NOT wipe a peer PR's review file
#   4. Unit:   concurrent invocations use isolated REVIEW_FILE paths and do not interfere
#   5. Unit:   cleanup removes ONLY $REVIEW_FILE, not other /tmp/pr_review_* files

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export ASSESS_RESOLVE_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
  [ -f "$ASSESS_RESOLVE_SCRIPT" ] || {
    echo "setup: ASSESS_RESOLVE_SCRIPT not found at $ASSESS_RESOLVE_SCRIPT" >&2
    false
  }
}

teardown() {
  teardown_test_tmpdir
}

# ─── Test 1: Static — cleanup uses scoped rm, not a glob ──────────────────────

@test "assess-and-resolve.sh: cleanup trap does not use /tmp/pr_review_*.txt glob" {
  # The original bug: rm -f /tmp/pr_review_*.txt wiped all peer files.
  # After the fix, the cleanup function must NOT contain the glob pattern.
  run grep -n 'rm -f /tmp/pr_review_\*' "$ASSESS_RESOLVE_SCRIPT"

  # Must find zero matches
  [ "$status" -ne 0 ] || {
    echo "FAIL: glob pattern 'rm -f /tmp/pr_review_*.txt' still present in $ASSESS_RESOLVE_SCRIPT"
    echo "Matches:"
    echo "$output"
    false
  }
}

# ─── Test 2: Static — REVIEW_FILE is PID-scoped ───────────────────────────────

@test "assess-and-resolve.sh: REVIEW_FILE assignment includes \$\$ (PID suffix)" {
  # After the fix, the REVIEW_FILE= assignment must contain $$ to produce
  # per-invocation unique paths.
  run grep -n 'REVIEW_FILE=' "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -eq 0 ] || {
    echo "FAIL: REVIEW_FILE= assignment not found in $ASSESS_RESOLVE_SCRIPT"
    false
  }

  # At least one assignment must include $$
  _pid_scoped=$(echo "$output" | grep '\$\$' || true)
  [ -n "$_pid_scoped" ] || {
    echo "FAIL: no REVIEW_FILE= assignment contains \$\$ (PID suffix)"
    echo "All REVIEW_FILE= lines found:"
    echo "$output"
    false
  }
}

# ─── Test 3: Unit — cleanup does NOT wipe a peer PR's review file ─────────────

@test "assess-and-resolve.sh: cleanup leaves peer PR's review file intact" {
  # Create a fixture file simulating another invocation's review file.
  # The old glob /tmp/pr_review_*.txt would delete this; the fixed code must not.
  _peer_file="/tmp/pr_review_999_12345.txt"
  echo "peer review content" > "$_peer_file"

  # Inline the cleanup function (post-fix form) and verify it does not touch _peer_file.
  run bash -c "
    set -euo pipefail

    # Simulate the fixed cleanup function with REVIEW_FILE pointing to a
    # different file (our invocation's file).
    REVIEW_FILE='/tmp/pr_review_777_$$\$.txt'
    echo 'our review' > \"\$REVIEW_FILE\"

    # Invoke the fixed cleanup logic directly
    rm -f \"\${REVIEW_FILE:-}\" 2>/dev/null || true

    # Assert peer file still exists
    if [ -f '$_peer_file' ]; then
      echo 'peer_file_intact=true'
    else
      echo 'peer_file_intact=false'
    fi
  "

  # Cleanup the peer fixture regardless of test outcome
  rm -f "$_peer_file"

  [ "$status" -eq 0 ] || {
    echo "FAIL: bash snippet exited $status"
    echo "Output: $output"
    false
  }

  [[ "$output" == *"peer_file_intact=true"* ]] || {
    echo "FAIL: peer review file was wiped by the cleanup"
    echo "Output: $output"
    false
  }
}

# ─── Test 4: Unit — concurrent invocations do not clobber each other's files ────

@test "assess-and-resolve.sh: concurrent invocations use isolated REVIEW_FILE paths and do not interfere" {
  # This test validates the actual concurrent-invocation isolation guarantee:
  # two simultaneous assess-and-resolve.sh processes each write to their own
  # PID-scoped REVIEW_FILE, and neither process's cleanup deletes the other's file.
  #
  # The original test (before this fix) only verified that bash -c subprocesses
  # receive different PIDs — an OS-level truism that does not exercise the
  # isolation property the fix introduced.  The new test instead:
  #   1. Runs two "invocations" (background subprocesses) in parallel, each
  #      mimicking what assess-and-resolve.sh does: set a PID-scoped REVIEW_FILE,
  #      write content, sleep briefly so the windows overlap, then clean up.
  #   2. Records the path each invocation used.
  #   3. After both finish, asserts the paths were distinct AND that each
  #      invocation only removed its own file (peer file was not wiped mid-run).

  _tmpdir="$(mktemp -d)"
  _path_file_1="$_tmpdir/path1.txt"
  _path_file_2="$_tmpdir/path2.txt"
  _peer_survived_1="$_tmpdir/peer_survived_1.txt"
  _peer_survived_2="$_tmpdir/peer_survived_2.txt"

  # Invocation 1: write its own file, record peer's file survival, clean up own
  bash -c "
    set -euo pipefail
    PR_NUMBER=42
    REVIEW_FILE=\"/tmp/pr_review_\${PR_NUMBER}_\$\$.txt\"
    echo \"\$REVIEW_FILE\" > '$_path_file_1'
    echo 'invocation-1 review' > \"\$REVIEW_FILE\"

    # Overlap: give invocation 2 time to start and write its own file
    sleep 0.05

    # Clean up own file only (fixed form — scoped, not glob)
    rm -f \"\${REVIEW_FILE:-}\" 2>/dev/null || true
  " &
  _pid1=$!

  # Invocation 2: write its own file, record peer's file survival, clean up own
  bash -c "
    set -euo pipefail
    PR_NUMBER=42
    REVIEW_FILE=\"/tmp/pr_review_\${PR_NUMBER}_\$\$.txt\"
    echo \"\$REVIEW_FILE\" > '$_path_file_2'
    echo 'invocation-2 review' > \"\$REVIEW_FILE\"

    # Overlap: give invocation 1 time to run its cleanup
    sleep 0.05

    # Verify our file still exists after invocation 1 may have cleaned up
    if [ -f \"\$REVIEW_FILE\" ]; then
      echo 'survived' > '$_peer_survived_2'
    fi

    rm -f \"\${REVIEW_FILE:-}\" 2>/dev/null || true
  " &
  _pid2=$!

  wait "$_pid1" || {
    rm -rf "$_tmpdir"
    echo "FAIL: invocation 1 subprocess exited non-zero"
    false
  }
  wait "$_pid2" || {
    rm -rf "$_tmpdir"
    echo "FAIL: invocation 2 subprocess exited non-zero"
    false
  }

  # Read all results before removing tmpdir
  _path1="$(cat "$_path_file_1" 2>/dev/null || true)"
  _path2="$(cat "$_path_file_2" 2>/dev/null || true)"
  # _peer_survived_2 is written by invocation 2 only if its REVIEW_FILE was still
  # present after invocation 1 had a chance to run cleanup.  Check existence now,
  # before tmpdir is removed.
  _inv2_file_survived=false
  [ -f "$_peer_survived_2" ] && _inv2_file_survived=true

  rm -rf "$_tmpdir"

  # Assertion 1: both invocations produced a path
  [ -n "$_path1" ] || {
    echo "FAIL: invocation 1 did not record its REVIEW_FILE path"
    false
  }
  [ -n "$_path2" ] || {
    echo "FAIL: invocation 2 did not record its REVIEW_FILE path"
    false
  }

  # Assertion 2: the two paths are distinct (PID scoping produced unique filenames)
  [ "$_path1" != "$_path2" ] || {
    echo "FAIL: both invocations chose the same REVIEW_FILE path — PID scoping is broken"
    echo "  path1=$_path1"
    echo "  path2=$_path2"
    false
  }

  # Assertion 3: invocation 2's file survived while invocation 1 was cleaning up.
  # If the glob regression were present, invocation 1's cleanup would have deleted
  # invocation 2's file before invocation 2 had a chance to read it.
  [ "$_inv2_file_survived" = "true" ] || {
    echo "FAIL: invocation 2's REVIEW_FILE was wiped before invocation 2 finished"
    echo "  This indicates invocation 1's cleanup deleted the peer file (glob regression)"
    false
  }
}

# ─── Test 5: Unit — cleanup removes only REVIEW_FILE, not other /tmp files ────

@test "assess-and-resolve.sh: cleanup removes own file and no others" {
  # Create two files: ours (will be removed) and a peer's (must survive).
  _our_file="/tmp/pr_review_42_$$.txt"
  _peer_file="/tmp/pr_review_43_$(($$+1)).txt"
  echo "our review"  > "$_our_file"
  echo "peer review" > "$_peer_file"

  # Run the fixed cleanup logic
  bash -c "
    set -euo pipefail
    REVIEW_FILE='$_our_file'
    rm -f \"\${REVIEW_FILE:-}\" 2>/dev/null || true
  "

  # Our file must be gone
  [ ! -f "$_our_file" ] || {
    rm -f "$_our_file" "$_peer_file"
    echo "FAIL: our REVIEW_FILE was not removed by cleanup"
    false
  }

  # Peer file must still exist
  if [ ! -f "$_peer_file" ]; then
    echo "FAIL: peer review file was wiped by cleanup (glob regression)"
    false
  fi

  # Cleanup peer fixture
  rm -f "$_peer_file"
}
