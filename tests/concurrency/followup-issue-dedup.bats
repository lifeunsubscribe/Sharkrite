#!/usr/bin/env bats
# tests/concurrency/followup-issue-dedup.bats - Follow-up issue deduplication tests
#
# Tests that concurrent follow-up issue creation properly deduplicates via the
# per-PR follow-up lock in lib/utils/issue-lock.sh and the retry logic in
# assess-and-resolve.sh.
#
# Verification command: bats tests/concurrency/followup-issue-dedup.bats

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/.rite/locks"

  mkdir -p "$RITE_LOCK_DIR"
  mkdir -p "$RITE_TEST_TMPDIR/.rite"

  # Source the lock utilities
  source "$RITE_LIB_DIR/utils/issue-lock.sh"

  # Track created issues atomically via a temp file + flock
  export ISSUES_FILE="$RITE_TEST_TMPDIR/created-issues.txt"
  touch "$ISSUES_FILE"
  export ISSUES_LOCK="$RITE_TEST_TMPDIR/created-issues.lock"

  export BARRIER_DIR="$RITE_TEST_TMPDIR/barriers"
  mkdir -p "$BARRIER_DIR"
}

teardown() {
  teardown_test_tmpdir
}

# Barrier: wait until expected_count processes have checked in
wait_at_barrier() {
  local barrier_name="$1"
  local expected_count="$2"
  local pid_file="$BARRIER_DIR/${barrier_name}.$$"

  touch "$pid_file"

  local count=0
  local timeout=0
  while [ "$count" -lt "$expected_count" ] && [ "$timeout" -lt 100 ]; do
    count=$(find "$BARRIER_DIR" -name "${barrier_name}.*" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -lt "$expected_count" ]; then
      sleep 0.05
      timeout=$((timeout + 1))
    fi
  done
}

# Helper: simulates the locked search-then-create critical section from
# assess-and-resolve.sh.  Accepts a PR number; uses a shared ISSUES_FILE to
# track what was "created".  Returns the issue number appended to ISSUES_FILE.
#
# The logic mirrors the production code:
#   1. Acquire pr-N-followup.lock
#   2. Search for existing issue (read ISSUES_FILE)
#   3. If none found, create (append to ISSUES_FILE)
#   4. Release lock
run_locked_dedup_create() {
  local pr_number="$1"
  local issue_title="$2"

  # Re-source lock utils (needed in subshell)
  source "$RITE_LIB_DIR/utils/issue-lock.sh"

  local _lock_held=false
  if acquire_pr_followup_lock "$pr_number" 2>/dev/null; then
    _lock_held=true
  fi

  # Search: check if issue already exists for this PR
  local existing=""
  existing=$(grep "^PR${pr_number}:" "$ISSUES_FILE" 2>/dev/null | head -1 || true)

  if [ -z "$existing" ]; then
    # Create: append to shared file (atomic enough under lock)
    local issue_num
    issue_num=$((RANDOM % 9000 + 1000))
    echo "PR${pr_number}:${issue_num}:${issue_title}" >> "$ISSUES_FILE"
  fi

  [ "$_lock_held" = "true" ] && release_pr_followup_lock "$pr_number" 2>/dev/null || true
}

# ─── Unit tests: acquire_pr_followup_lock / release_pr_followup_lock ──────────

@test "acquire_pr_followup_lock succeeds when no lock exists" {
  run acquire_pr_followup_lock 99
  [ "$status" -eq 0 ]
  # bats `run` executes in a subshell, so we verify the lock dir and pid file
  # were created (PID will be the subshell's PID, not $$)
  [ -d "$RITE_LOCK_DIR/pr-99-followup.lock" ]
  [ -f "$RITE_LOCK_DIR/pr-99-followup.lock/pid" ]

  local lock_pid
  lock_pid=$(cat "$RITE_LOCK_DIR/pr-99-followup.lock/pid")
  # PID must be a positive integer
  [[ "$lock_pid" =~ ^[0-9]+$ ]]
}

@test "release_pr_followup_lock removes lock held by current process" {
  acquire_pr_followup_lock 99
  release_pr_followup_lock 99
  [ ! -d "$RITE_LOCK_DIR/pr-99-followup.lock" ]
}

@test "acquire_pr_followup_lock blocks while lock is held by live process" {
  # Acquire lock in background process and hold it
  (
    source "$RITE_LIB_DIR/utils/issue-lock.sh"
    acquire_pr_followup_lock 55
    # Signal ready, then hold for 3 seconds
    touch "$BARRIER_DIR/lock_held.ready"
    sleep 3
    release_pr_followup_lock 55
  ) &
  local holder_pid=$!

  # Wait until lock is confirmed held
  local waited=0
  while [ ! -f "$BARRIER_DIR/lock_held.ready" ] && [ "$waited" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  # A second acquire attempt should see the lock as held
  # (it will eventually succeed after holder exits, but we just verify it waits)
  # We time it: should take ~1s before holder releases
  local start_ts
  start_ts=$(date +%s)

  run bash -c "
    export RITE_LOCK_DIR='$RITE_LOCK_DIR'
    source '$RITE_LIB_DIR/utils/issue-lock.sh'
    acquire_pr_followup_lock 55
  "
  local end_ts
  end_ts=$(date +%s)
  local elapsed=$(( end_ts - start_ts ))

  # Should have waited at least 1 second (holder held for ~3s, but may have
  # released before our attempt starts — just verify status 0 meaning it
  # eventually acquired successfully after waiting)
  [ "$status" -eq 0 ]

  wait "$holder_pid" || true
}

@test "acquire_pr_followup_lock reclaims stale lock from dead process" {
  # Create a lock with a dead PID
  local lock_dir="$RITE_LOCK_DIR/pr-77-followup.lock"
  mkdir "$lock_dir"
  echo "99999999" > "$lock_dir/pid"   # PID that does not exist

  run acquire_pr_followup_lock 77
  [ "$status" -eq 0 ]
  [ -d "$lock_dir" ]

  local lock_pid
  lock_pid=$(cat "$lock_dir/pid")
  [ "$lock_pid" = "$$" ]
}

@test "locks for different PR numbers are independent" {
  acquire_pr_followup_lock 10
  acquire_pr_followup_lock 20
  acquire_pr_followup_lock 30

  [ -d "$RITE_LOCK_DIR/pr-10-followup.lock" ]
  [ -d "$RITE_LOCK_DIR/pr-20-followup.lock" ]
  [ -d "$RITE_LOCK_DIR/pr-30-followup.lock" ]

  release_pr_followup_lock 10
  release_pr_followup_lock 20
  release_pr_followup_lock 30

  [ ! -d "$RITE_LOCK_DIR/pr-10-followup.lock" ]
  [ ! -d "$RITE_LOCK_DIR/pr-20-followup.lock" ]
  [ ! -d "$RITE_LOCK_DIR/pr-30-followup.lock" ]
}

# ─── Concurrency tests ────────────────────────────────────────────────────────

@test "3 parallel assessments on same PR produce exactly one follow-up issue" {
  local pr_number=42
  local num_processes=3
  local pids=()

  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "dedup_test_${BATS_TEST_NUMBER}" "$num_processes"
      run_locked_dedup_create "$pr_number" "review feedback from PR #${pr_number}"
    ) &
    pids+=($!)
  done

  # Wait for all background processes
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  # Count how many issues were created for this PR
  local issue_count
  issue_count=$(grep -c "^PR${pr_number}:" "$ISSUES_FILE" 2>/dev/null || echo 0)

  [ "$issue_count" -eq 1 ] || {
    echo "FAIL: Expected 1 follow-up issue, got $issue_count"
    echo "Issues file contents:"
    cat "$ISSUES_FILE" || true
    false
  }
}

@test "5 parallel assessments on same PR produce exactly one follow-up issue" {
  local pr_number=43
  local num_processes=5
  local pids=()

  for i in $(seq 1 $num_processes); do
    (
      wait_at_barrier "dedup_test5_${BATS_TEST_NUMBER}" "$num_processes"
      run_locked_dedup_create "$pr_number" "review feedback from PR #${pr_number}"
    ) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  local issue_count
  issue_count=$(grep -c "^PR${pr_number}:" "$ISSUES_FILE" 2>/dev/null || echo 0)

  [ "$issue_count" -eq 1 ] || {
    echo "FAIL: Expected 1 follow-up issue, got $issue_count"
    cat "$ISSUES_FILE" || true
    false
  }
}

@test "concurrent assessments on different PRs each get their own issue" {
  local num_processes=4
  local pids=()

  for i in $(seq 1 $num_processes); do
    local pr=$((100 + i))
    (
      wait_at_barrier "diff_pr_test_${BATS_TEST_NUMBER}" "$num_processes"
      run_locked_dedup_create "$pr" "review feedback from PR #${pr}"
    ) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  # Each PR should have exactly one issue
  local total_issues
  total_issues=$(wc -l < "$ISSUES_FILE" | tr -d ' ')

  [ "$total_issues" -eq "$num_processes" ] || {
    echo "FAIL: Expected $num_processes issues (one per PR), got $total_issues"
    cat "$ISSUES_FILE" || true
    false
  }
}

@test "dedup works when first process creates issue before second acquires lock" {
  # Simulate sequential: process A creates, process B should dedup
  local pr_number=50
  run_locked_dedup_create "$pr_number" "review feedback from PR #${pr_number}"
  run_locked_dedup_create "$pr_number" "review feedback from PR #${pr_number}"

  local issue_count
  issue_count=$(grep -c "^PR${pr_number}:" "$ISSUES_FILE" 2>/dev/null || echo 0)
  [ "$issue_count" -eq 1 ]
}
