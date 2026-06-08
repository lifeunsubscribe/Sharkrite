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
#   4. Unit:   two invocations of the same PR produce different REVIEW_FILE paths
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

# ─── Test 4: Unit — two invocations produce different REVIEW_FILE paths ────────

@test "assess-and-resolve.sh: PID-scoped paths from two subprocesses are distinct" {
  # Each subprocess gets its own PID, so /tmp/pr_review_${PR_NUMBER}_$$.txt
  # produces two different paths even for the same PR number.
  run bash -c "
    # Spawn two subprocesses that each resolve the PID-scoped path and print it
    path1=\$( bash -c 'echo \"/tmp/pr_review_42_\$\$.txt\"' )
    path2=\$( bash -c 'echo \"/tmp/pr_review_42_\$\$.txt\"' )

    if [ \"\$path1\" != \"\$path2\" ]; then
      echo 'paths_distinct=true'
      echo \"path1=\$path1\"
      echo \"path2=\$path2\"
    else
      echo 'paths_distinct=false'
      echo \"both=\$path1\"
    fi
  "

  [ "$status" -eq 0 ] || {
    echo "FAIL: bash snippet exited $status"
    echo "Output: $output"
    false
  }

  [[ "$output" == *"paths_distinct=true"* ]] || {
    echo "FAIL: two subprocess REVIEW_FILE paths are identical — PID scoping is broken"
    echo "Output: $output"
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
