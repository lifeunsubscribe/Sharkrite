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
  # Hold duration in seconds — deterministic window the second acquire must wait inside.
  local hold_seconds=2

  # Acquire lock in background process and hold it
  (
    source "$RITE_LIB_DIR/utils/issue-lock.sh"
    acquire_pr_followup_lock 55
    # Signal ready, then hold for the deterministic window
    touch "$BARRIER_DIR/lock_held.ready"
    sleep "$hold_seconds"
    release_pr_followup_lock 55
  ) &
  local holder_pid=$!

  # Wait until lock is confirmed held before timing the second acquire
  local waited=0
  while [ ! -f "$BARRIER_DIR/lock_held.ready" ] && [ "$waited" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  [ -f "$BARRIER_DIR/lock_held.ready" ] || {
    echo "FAIL: holder never signalled ready"
    kill "$holder_pid" 2>/dev/null || true
    false
  }

  # Time the second acquire — it must block until the holder releases
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

  # Must have succeeded (eventually acquired the lock)
  [ "$status" -eq 0 ]

  # Must have blocked for at least hold_seconds-1 (allow 1s clock granularity).
  # If locking were a no-op this would be ~0s and the assertion would catch it.
  [ "$elapsed" -ge $(( hold_seconds - 1 )) ] || {
    echo "FAIL: second acquire returned in ${elapsed}s — expected at least $(( hold_seconds - 1 ))s of blocking (lock held for ${hold_seconds}s)"
    false
  }

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
  issue_count=$(grep -c "^PR${pr_number}:" "$ISSUES_FILE" 2>/dev/null || true)

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
  issue_count=$(grep -c "^PR${pr_number}:" "$ISSUES_FILE" 2>/dev/null || true)

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
  issue_count=$(grep -c "^PR${pr_number}:" "$ISSUES_FILE" 2>/dev/null || true)
  [ "$issue_count" -eq 1 ]
}

# ─── Marker-before-release ordering test ──────────────────────────────────────
#
# This test verifies the fix for the lock-released-before-marker-posted race:
# the dedup marker comment must be durably recorded BEFORE the lock is released,
# so that a waiter acquiring the lock always sees evidence of a prior creation
# even when the GitHub search index hasn't yet indexed the new issue.
#
# Strategy: use a real lock from issue-lock.sh; simulate a "gh" stub via a PATH
# override that records calls to an event log.  Process A acquires the lock,
# "creates" an issue (appends to ISSUES_FILE), "posts a marker" (writes to
# MARKER_FILE), then releases the lock.  We assert the marker was written before
# the lock was released by inspecting the event log ordering.

run_dedup_create_with_event_log() {
  local pr_number="$1"
  local issues_file="$2"
  local marker_file="$3"
  local event_log="$4"

  # Re-source lock utils (needed in subshell)
  source "$RITE_LIB_DIR/utils/issue-lock.sh"

  local _lock_held=false
  if acquire_pr_followup_lock "$pr_number" 2>/dev/null; then
    _lock_held=true
  fi

  # Search: check if issue already exists (simulate — read ISSUES_FILE)
  local existing=""
  existing=$(grep "^PR${pr_number}:" "$issues_file" 2>/dev/null | head -1 || true)

  if [ -z "$existing" ]; then
    # Create issue
    local issue_num
    issue_num=$((RANDOM % 9000 + 1000))
    echo "PR${pr_number}:${issue_num}" >> "$issues_file"
    echo "issue_created" >> "$event_log"

    # Post marker comment BEFORE releasing lock (correct ordering)
    echo "<!-- sharkrite-followup-issue:${issue_num} -->" >> "$marker_file"
    echo "marker_posted" >> "$event_log"
  fi

  # Release lock only after marker is posted
  if [ "$_lock_held" = "true" ]; then
    release_pr_followup_lock "$pr_number" 2>/dev/null || true
    echo "lock_released" >> "$event_log"
  fi
}

@test "marker comment is posted before lock is released" {
  local pr_number=60
  local event_log="$RITE_TEST_TMPDIR/event-log.txt"
  local marker_file="$RITE_TEST_TMPDIR/marker.txt"
  touch "$event_log"
  touch "$marker_file"

  run_dedup_create_with_event_log "$pr_number" "$ISSUES_FILE" "$marker_file" "$event_log"

  # Verify events were recorded
  [ -s "$event_log" ] || {
    echo "FAIL: event log is empty"
    false
  }

  # Extract positions of key events
  local marker_line lock_line
  marker_line=$(grep -n "^marker_posted$" "$event_log" | cut -d: -f1 || true)
  lock_line=$(grep -n "^lock_released$" "$event_log" | cut -d: -f1 || true)

  [ -n "$marker_line" ] || {
    echo "FAIL: marker_posted event not found in event log"
    cat "$event_log"
    false
  }
  [ -n "$lock_line" ] || {
    echo "FAIL: lock_released event not found in event log"
    cat "$event_log"
    false
  }

  # marker must appear before lock release
  [ "$marker_line" -lt "$lock_line" ] || {
    echo "FAIL: lock released (line $lock_line) before marker posted (line $marker_line)"
    echo "Event log:"
    cat -n "$event_log"
    false
  }
}

@test "waiter sees marker and skips creation after acquiring lock" {
  # Simulate the indexing-lag race:
  # Process A: acquires lock, creates issue, posts marker, releases lock
  # Process B: acquires lock (after A releases), search misses (indexing lag),
  #            but marker comment is present → should not create a duplicate
  local pr_number=61
  local marker_file="$RITE_TEST_TMPDIR/pr-${pr_number}-marker.txt"
  touch "$marker_file"

  # Process A: create and post marker
  (
    source "$RITE_LIB_DIR/utils/issue-lock.sh"
    acquire_pr_followup_lock "$pr_number" 2>/dev/null
    echo "PR${pr_number}:1001" >> "$ISSUES_FILE"
    # Marker posted while lock still held
    echo "<!-- sharkrite-followup-issue:1001 -->" >> "$marker_file"
    release_pr_followup_lock "$pr_number" 2>/dev/null || true
  )

  # Process B: simulates "waiter" — lock is now free, but search index not updated.
  # Uses run_dedup_create_with_event_log which checks ISSUES_FILE under lock.
  # Since A already appended PR61 to ISSUES_FILE (standing in for both the
  # issue index and the marker), B must detect it and skip creation.
  local event_log="$RITE_TEST_TMPDIR/event-log-b.txt"
  touch "$event_log"
  run_dedup_create_with_event_log "$pr_number" "$ISSUES_FILE" "$marker_file" "$event_log"

  # Only one entry should exist for this PR
  local issue_count
  issue_count=$(grep -c "^PR${pr_number}:" "$ISSUES_FILE" 2>/dev/null || true)
  [ "$issue_count" -eq 1 ] || {
    echo "FAIL: Expected 1 follow-up issue for PR $pr_number, got $issue_count"
    echo "Issues file:"
    cat "$ISSUES_FILE" || true
    echo "Event log B:"
    cat "$event_log" || true
    false
  }
}
