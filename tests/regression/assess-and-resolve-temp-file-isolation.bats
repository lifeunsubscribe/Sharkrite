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
  # Negative-control design — the cleanup rm command is extracted from the real
  # assess-and-resolve.sh cleanup() function and injected into both invocations.
  # This means if the production cleanup() is changed back to the buggy glob form
  #   rm -f /tmp/pr_review_*.txt
  # invocation 1's cleanup (running while both files coexist) WILL wipe invocation
  # 2's file, and Assertion 3 WILL fail — exactly the regression detection required.
  # When the production cleanup uses the fixed scoped form
  #   rm -f "${REVIEW_FILE:-}"
  # invocation 2's file survives and Assertion 3 passes.
  #
  # Barrier-file synchronization ensures the overlap window is deterministic:
  #   - invocation 2 signals "ready" once its REVIEW_FILE is written
  #   - invocation 1 waits for that signal before running its cleanup
  #   - this guarantees both files coexist when invocation 1's cleanup runs,
  #     so a glob would always wipe invocation 2's file (no timing window)
  #
  # Assertions:
  #   1. Both invocations produced a path
  #   2. The two paths are distinct (PID scoping)
  #   3. Invocation 2's file survived invocation 1's cleanup (no glob wipe)
  #   4. Invocation 2's own file was removed by its own cleanup (cleanup ran)

  _tmpdir="$(mktemp -d)"
  # Ensure _tmpdir is removed on any exit from this test (assertion failures, etc.)
  trap 'rm -rf "${_tmpdir:-}"' RETURN

  _path_file_1="$_tmpdir/path1.txt"
  _path_file_2="$_tmpdir/path2.txt"
  _peer_survived_1="$_tmpdir/peer_survived_1.txt"
  _peer_survived_2="$_tmpdir/peer_survived_2.txt"
  # Barrier: invocation 2 touches this file once its REVIEW_FILE is written;
  # invocation 1 polls for it before running cleanup.
  _barrier="$_tmpdir/inv2_ready.barrier"
  # Invocation-1-done marker: invocation 2 polls for this before checking survival.
  _inv1_done="$_tmpdir/inv1_done.marker"

  # Extract the rm -f line from the production cleanup() function.
  # If that line is changed back to a glob, the extracted command uses the glob.
  # awk: start printing inside cleanup(), stop at the closing brace.
  # head -1 so we get only the rm line, not the lock-release boilerplate.
  _cleanup_rm_file="$_tmpdir/cleanup_rm.sh"
  awk '/^cleanup\(\)/{inside=1} inside && /rm -f /{print; exit}' \
    "$ASSESS_RESOLVE_SCRIPT" > "$_cleanup_rm_file"
  [ -s "$_cleanup_rm_file" ] || {
    echo "FAIL: could not extract rm -f line from cleanup() in $ASSESS_RESOLVE_SCRIPT"
    false
  }

  # Invocation 1: writes its file, waits for invocation 2's barrier (guaranteeing
  # overlap), then runs the production cleanup rm, then signals done.
  bash -c "
    set -euo pipefail
    PR_NUMBER=42
    REVIEW_FILE=\"/tmp/pr_review_\${PR_NUMBER}_\$\$.txt\"
    echo \"\$REVIEW_FILE\" > '$_path_file_1'
    echo 'invocation-1 review' > \"\$REVIEW_FILE\"

    # Wait (barrier) until invocation 2 has written its own REVIEW_FILE
    _waited=0
    until [ -f '$_barrier' ]; do
      sleep 0.01
      _waited=\$((_waited + 1))
      [ \"\$_waited\" -lt 200 ] || { echo 'barrier timeout' >&2; exit 1; }
    done

    # Run the production cleanup rm — extracted from assess-and-resolve.sh.
    # If the production code reverts to rm -f /tmp/pr_review_42_*.txt (glob),
    # this will wipe invocation 2's file and Assertion 3 below will fail.
    . '$_cleanup_rm_file'

    touch '$_inv1_done'
  " &
  _pid1=$!

  # Invocation 2: writes its file, signals the barrier, waits for invocation 1's
  # cleanup to complete, checks its own file's survival, then cleans up.
  bash -c "
    set -euo pipefail
    PR_NUMBER=42
    REVIEW_FILE=\"/tmp/pr_review_\${PR_NUMBER}_\$\$.txt\"
    echo \"\$REVIEW_FILE\" > '$_path_file_2'
    echo 'invocation-2 review' > \"\$REVIEW_FILE\"

    # Signal invocation 1 that our file is now on disk
    touch '$_barrier'

    # Wait for invocation 1 to finish its cleanup before we check survival
    _waited=0
    until [ -f '$_inv1_done' ]; do
      sleep 0.01
      _waited=\$((_waited + 1))
      [ \"\$_waited\" -lt 200 ] || { echo 'inv1-done timeout' >&2; exit 1; }
    done

    # Check if our file survived invocation 1's cleanup
    if [ -f \"\$REVIEW_FILE\" ]; then
      echo 'survived' > '$_peer_survived_2'
    fi

    # Check if invocation 1's file was removed by its own cleanup (symmetric)
    _inv1_path=\"\$(cat '$_path_file_1' 2>/dev/null || true)\"
    if [ -n \"\$_inv1_path\" ] && [ ! -f \"\$_inv1_path\" ]; then
      echo 'removed' > '$_peer_survived_1'
    fi

    # Run own cleanup (fixed scoped form)
    rm -f \"\${REVIEW_FILE:-}\" 2>/dev/null || true
  " &
  _pid2=$!

  wait "$_pid1" || {
    echo "FAIL: invocation 1 subprocess exited non-zero"
    false
  }
  wait "$_pid2" || {
    echo "FAIL: invocation 2 subprocess exited non-zero"
    false
  }

  # Read all results before trap removes tmpdir
  _path1="$(cat "$_path_file_1" 2>/dev/null || true)"
  _path2="$(cat "$_path_file_2" 2>/dev/null || true)"
  _inv2_file_survived=false
  [ -f "$_peer_survived_2" ] && _inv2_file_survived=true
  _inv1_file_removed=false
  [ -f "$_peer_survived_1" ] && _inv1_file_removed=true

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

  # Assertion 3: invocation 2's file survived invocation 1's cleanup.
  # Invocation 1 ran the PRODUCTION rm line extracted from cleanup() in
  # assess-and-resolve.sh.  If that line is a glob (rm -f /tmp/pr_review_42_*.txt),
  # it WILL have wiped invocation 2's file (barrier guaranteed overlap) and this
  # assertion WILL fail.  It can only pass when the production cleanup uses the
  # scoped rm -f "${REVIEW_FILE:-}" form.
  [ "$_inv2_file_survived" = "true" ] || {
    echo "FAIL: invocation 2's REVIEW_FILE was wiped before invocation 2 finished"
    echo "  Invocation 1 ran the production cleanup rm from assess-and-resolve.sh"
    echo "  This indicates the production cleanup() reverted to a glob (regression present)"
    echo "  Expected: rm -f \"\${REVIEW_FILE:-}\"  (scoped, not a glob)"
    echo "  path1=$_path1  path2=$_path2"
    false
  }

  # Assertion 4 (symmetric): invocation 1's own file was removed by its cleanup.
  # The scoped rm correctly removes the current invocation's file even though
  # it does not touch peer files.
  [ "$_inv1_file_removed" = "true" ] || {
    echo "FAIL: invocation 1's REVIEW_FILE was NOT removed by its own cleanup"
    echo "  Expected the scoped rm to remove its own file"
    echo "  path1=$_path1"
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
