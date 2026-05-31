#!/usr/bin/env bats
# tests/concurrency/scratchpad-lock.bats - Scratchpad concurrent write and lock tests
#
# Tests that:
# 1. Concurrent writes via log_encountered_issue() don't lose data (locking works)
# 2. A SIGKILL'd lock holder's lock is reclaimed by the next waiter within 5s
#
# Issue #19: Harden scratchpad lock — fix TOCTOU, timeout, propagate to all writers.

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  setup_test_tmpdir

  # Set up environment for scratchpad
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export SCRATCHPAD_FILE="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/scratch.md"

  mkdir -p "$RITE_PROJECT_ROOT/$RITE_DATA_DIR"

  # Create initial scratchpad structure
  cat > "$SCRATCHPAD_FILE" <<'EOF'
# Scratchpad

## Encountered Issues (Needs Triage)

_Issues discovered during development that need follow-up._

---

## Recent Security Findings (Last 5 PRs)

_Security issues found in recent PR reviews. Sharkrite updates this automatically._

---

## Completed Work Archive

_Last 20 PRs — auto-cleaned_

EOF

  # Create barrier directory for synchronization
  export BARRIER_DIR="$RITE_TEST_TMPDIR/barriers"
  mkdir -p "$BARRIER_DIR"
}

teardown() {
  teardown_test_tmpdir
}

# Barrier synchronization helper — all processes wait here until N arrive
wait_at_barrier() {
  local barrier_name="$1"
  local expected_count="$2"
  local pid_file="$BARRIER_DIR/${barrier_name}.$$"

  # Mark this process as arrived
  if ! touch "$pid_file"; then
    echo "ERROR: Failed to create barrier pid file: $pid_file" >&2
    return 1
  fi

  # Busy-wait until all processes arrive
  local count=0
  local timeout=0
  while [ "$count" -lt "$expected_count" ] && [ "$timeout" -lt 50 ]; do
    count=$(find "$BARRIER_DIR" -name "${barrier_name}.*" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -lt "$expected_count" ]; then
      sleep 0.1
      timeout=$((timeout + 1))
    fi
  done

  if [ "$timeout" -ge 50 ]; then
    echo "ERROR: Barrier timeout waiting for $expected_count processes (got $count)" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test 1: 3 parallel log_encountered_issue calls — all 3 entries survive
#
# Acceptance criterion: "3 parallel processes calling log_encountered_issue with
# different file:line; all 3 entries survive in the final file"
# ---------------------------------------------------------------------------
@test "3 parallel log_encountered_issue calls - all entries survive (no data loss)" {
  local num_processes=3
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  # Hard precondition: scratchpad must exist before spawning processes.
  # log_encountered_issue() silently returns 0 on a missing scratchpad.
  [ -f "$SCRATCHPAD_FILE" ] || {
    echo "FAIL: scratchpad not initialized before spawning concurrent processes" >&2
    return 1
  }

  # Spawn 3 processes that each call the real log_encountered_issue() concurrently
  for i in $(seq 1 $num_processes); do
    (
      # Re-source in each subshell so functions are available
      source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
      source "$RITE_LIB_DIR/utils/scratchpad-manager.sh"

      # Synchronize all processes to start at the same time
      wait_at_barrier "parallel_log_test" "$num_processes" || exit 1

      # Call with distinct file:line so dedup logic doesn't suppress any
      log_encountered_issue \
        "src/component${i}.ts" "${i}00" \
        "test-failure" \
        "Concurrent write test entry ${i}" \
        "concurrent-test-${i}" \
        "Fix for concurrent entry ${i}" \
        "All concurrent entries present in scratchpad"

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  # Wait for all background processes
  wait

  # Verify all processes exited successfully
  for i in $(seq 1 $num_processes); do
    [ -f "$exit_codes_dir/process_${i}.exit" ] || {
      echo "FAIL: process $i did not produce an exit code file" >&2
      return 1
    }
    local exit_code
    exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
    [ "$exit_code" -eq 0 ] || {
      echo "FAIL: process $i exited with code $exit_code" >&2
      return 1
    }
  done

  # Hard assertion: ALL 3 entries must be present.
  # Under the old unguarded implementation, concurrent mv operations would lose
  # entries. With the scratchpad lock, each write is serialised so all survive.
  local actual_count
  actual_count=$(grep -c "Concurrent write test entry" "$SCRATCHPAD_FILE" || true)

  [ "$actual_count" -eq "$num_processes" ] || {
    echo "FAIL: expected $num_processes entries, found $actual_count" >&2
    echo "Scratchpad contents:" >&2
    cat "$SCRATCHPAD_FILE" >&2
    return 1
  }

  # Also verify distinct file:line entries — each entry is unique (dedup didn't fire)
  for i in $(seq 1 $num_processes); do
    grep -q "src/component${i}.ts:${i}00" "$SCRATCHPAD_FILE" || {
      echo "FAIL: entry for component${i}.ts:${i}00 not found" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# Test 2: SIGKILL lock holder — next waiter reclaims within 5 seconds
#
# Acceptance criterion: "send SIGKILL to a process holding the lock;
# next process reclaims within 5s"
# ---------------------------------------------------------------------------
@test "SIGKILL'd lock holder - next process reclaims lock within 5s" {
  local lock_acquired_file="$RITE_TEST_TMPDIR/lock_acquired"
  local holder_pid_file="$RITE_TEST_TMPDIR/holder_pid"
  local reclaim_result_file="$RITE_TEST_TMPDIR/reclaim_result"

  # Spawn a process that acquires the lock and holds it indefinitely
  (
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    acquire_scratchpad_lock
    # Signal that we have the lock
    echo $$ > "$holder_pid_file"
    touch "$lock_acquired_file"
    # Hold the lock until SIGKILLed
    sleep 60
  ) &
  local holder_bgpid=$!

  # Wait up to 5s for the holder to acquire the lock
  local wait_count=0
  while [ ! -f "$lock_acquired_file" ] && [ "$wait_count" -lt 50 ]; do
    sleep 0.1
    wait_count=$((wait_count + 1))
  done

  [ -f "$lock_acquired_file" ] || {
    echo "FAIL: holder process never acquired the lock" >&2
    kill "$holder_bgpid" 2>/dev/null || true
    return 1
  }

  local holder_pid
  holder_pid=$(cat "$holder_pid_file")

  # SIGKILL the holder — leaves lock dir behind (no graceful cleanup)
  kill -KILL "$holder_pid" 2>/dev/null || true
  wait "$holder_bgpid" 2>/dev/null || true

  local lockfile="${SCRATCHPAD_FILE}.lock"

  # On the mkdir path: lock dir persists after SIGKILL (no kernel cleanup).
  # On the flock path: kernel releases the flock automatically on process death,
  # so the waiter acquires it immediately without needing stale reclaim.
  # Either way, the next acquire_scratchpad_lock call must succeed within 5s.

  # Now spawn a waiter — it should reclaim the stale lock and succeed within 5s
  local start_time
  start_time=$(date +%s)

  (
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    # Reclaim should succeed quickly (dead holder detected by kill -0 check on mkdir path,
    # or instant acquire on flock path where kernel already released the lock)
    if acquire_scratchpad_lock; then
      echo "success" > "$reclaim_result_file"
      release_scratchpad_lock
    else
      echo "failure" > "$reclaim_result_file"
    fi
  )

  local end_time
  end_time=$(date +%s)
  local elapsed=$((end_time - start_time))

  # Verify reclaim succeeded
  [ -f "$reclaim_result_file" ] || {
    echo "FAIL: waiter did not produce a result file" >&2
    return 1
  }

  local result
  result=$(cat "$reclaim_result_file")
  [ "$result" = "success" ] || {
    echo "FAIL: waiter failed to acquire lock after holder was SIGKILL'd" >&2
    return 1
  }

  # Verify reclaim happened within 5 seconds
  [ "$elapsed" -le 5 ] || {
    echo "FAIL: reclaim took ${elapsed}s (expected <= 5s)" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 3: Timeout exits 1 — never proceeds without the lock
#
# Verifies the key behavioral fix: the old code `break`'d and continued into
# the critical section without holding the lock. The new code exits 1.
# ---------------------------------------------------------------------------
@test "lock timeout exits 1 - never proceeds without holding the lock" {
  local lockfile="${SCRATCHPAD_FILE}.lock"
  local holder_pid_file="$RITE_TEST_TMPDIR/holder_pid"
  local holder_ready="$RITE_TEST_TMPDIR/holder_ready"

  # Spawn a live holder that keeps the lock
  (
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    acquire_scratchpad_lock
    touch "$holder_ready"
    echo $$ > "$holder_pid_file"
    sleep 60  # Hold the lock
  ) &
  local holder_bgpid=$!

  # Wait for holder to get the lock
  local wait_count=0
  while [ ! -f "$holder_ready" ] && [ "$wait_count" -lt 50 ]; do
    sleep 0.1
    wait_count=$((wait_count + 1))
  done
  [ -f "$holder_ready" ] || {
    echo "FAIL: holder never acquired lock" >&2
    kill "$holder_bgpid" 2>/dev/null || true
    return 1
  }

  # Attempt to acquire lock with a very short timeout
  # The waiter should exit 1, NOT proceed without the lock
  local waiter_exit=0
  (
    export RITE_SCRATCHPAD_LOCK_TIMEOUT=2  # 2s timeout for test speed
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    acquire_scratchpad_lock
  ) || waiter_exit=$?

  # Clean up holder
  kill "$holder_bgpid" 2>/dev/null || true
  wait "$holder_bgpid" 2>/dev/null || true

  # The waiter MUST have exited non-zero (it couldn't acquire the lock)
  [ "$waiter_exit" -ne 0 ] || {
    echo "FAIL: waiter should have exited non-zero on timeout, got exit code 0" >&2
    echo "      This means the old 'proceed anyway' behavior is still present" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 4: update_scratchpad_from_pr acquires lock (scratchpad-manager integration)
# ---------------------------------------------------------------------------
@test "concurrent security findings updates - structure preserved after locking" {
  local num_processes=3
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  # Create mock gh command that returns review data
  export PATH="$RITE_TEST_TMPDIR/mock-bin:$PATH"
  mkdir -p "$RITE_TEST_TMPDIR/mock-bin"

  cat > "$RITE_TEST_TMPDIR/mock-bin/gh" <<'GHEOF'
#!/bin/bash
# Mock gh that returns security findings based on PR number
echo "[CRITICAL] SQL injection in user input (PR $$)"
GHEOF
  chmod +x "$RITE_TEST_TMPDIR/mock-bin/gh"

  # Spawn N processes that each update security findings concurrently
  for i in $(seq 1 $num_processes); do
    (
      source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
      source "$RITE_LIB_DIR/utils/scratchpad-manager.sh"
      wait_at_barrier "security_lock_test" "$num_processes" || exit 1

      update_scratchpad_from_pr "$((100 + i))" "Test PR $i" 2>/dev/null
      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  wait

  # Verify all processes completed
  for i in $(seq 1 $num_processes); do
    [ -f "$exit_codes_dir/process_${i}.exit" ]
  done

  # Verify scratchpad structure is intact — locking should prevent corruption
  grep -q "## Encountered Issues" "$SCRATCHPAD_FILE" || {
    echo "FAIL: ## Encountered Issues section missing after concurrent updates" >&2
    return 1
  }
  grep -q "## Recent Security Findings" "$SCRATCHPAD_FILE" || {
    echo "FAIL: ## Recent Security Findings section missing after concurrent updates" >&2
    return 1
  }
  grep -q "## Completed Work Archive" "$SCRATCHPAD_FILE" || {
    echo "FAIL: ## Completed Work Archive section missing after concurrent updates" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 5: init_scratchpad race — file created exactly once
# ---------------------------------------------------------------------------
@test "concurrent init_scratchpad calls - scratchpad header appears exactly once" {
  rm -f "$SCRATCHPAD_FILE"

  local num_processes=5
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  for i in $(seq 1 $num_processes); do
    (
      source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
      source "$RITE_LIB_DIR/utils/scratchpad-manager.sh"
      wait_at_barrier "init_test" "$num_processes" || exit 1

      init_scratchpad
      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  wait

  # Verify all processes exited successfully
  for i in $(seq 1 $num_processes); do
    [ -f "$exit_codes_dir/process_${i}.exit" ]
    local exit_code
    exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
    [ "$exit_code" -eq 0 ]
  done

  # Verify scratchpad exists and is valid
  [ -f "$SCRATCHPAD_FILE" ]
  # The header must appear exactly once — two concurrent writes would produce duplicates
  local header_count
  header_count=$(grep -c "^## Encountered Issues" "$SCRATCHPAD_FILE" || true)
  [ "$header_count" -eq 1 ]
}
