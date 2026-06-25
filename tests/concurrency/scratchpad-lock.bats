#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/scratchpad-lock.sh, lib/utils/scratchpad-manager.sh
# tests/concurrency/scratchpad-lock.bats - Scratchpad concurrent write and lock tests
#
# Tests that:
# 1. Concurrent writes via log_encountered_issue() don't lose data (locking works)
# 2. A SIGKILL'd lock holder's lock is reclaimed by the next waiter within 5s
# 8. SIGKILL'd holder on mkdir path is reclaimed deterministically (issue #151)
#    — Test 2 only exercises the mkdir stale-reclaim path on systems without flock;
#      Test 8 forces the mkdir path via RITE_SCRATCHPAD_LOCK_STRATEGY=mkdir so the
#      kill -0 stale-reclaim code is always covered regardless of flock availability.
#
# Issue #19: Harden scratchpad lock — fix TOCTOU, timeout, propagate to all writers.
# Issue #151: SIGKILL reclaim test does not exercise mkdir stale-reclaim path on CI.

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  # Skip on bash 3.2 (macOS system bash). Moved from setup_file() — skip inside
  # setup_file() requires bats >=1.5.0; skip inside setup() is universally supported.
  # Barrier sync + subshell spawning relies on bash 4+ performance:
  # bash 3.2 startup is 50-150ms per subshell vs ~10ms for bash 4+, so
  # concurrent subshells can't reliably reach the barrier within the timeout
  # on a busy macOS dev machine, producing false failures unrelated to the
  # scratchpad locking behavior under test.
  # On Homebrew bash 4+ (macOS) and Linux CI (bash 4+ default), tests run fully.
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    skip "Concurrency tests require bash 4+ (detected bash ${BASH_VERSION}). Install via: brew install bash"
  fi

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
  local pid_file="$BARRIER_DIR/${barrier_name}.$BASHPID"

  # Mark this process as arrived
  if ! touch "$pid_file"; then
    echo "ERROR: Failed to create barrier pid file: $pid_file" >&2
    return 1
  fi

  # Busy-wait until all processes arrive.
  # 100 iterations × 0.1s = 10s. Bumped from 5s to give bash 4+ subshells
  # enough headroom on a loaded macOS dev machine.
  local count=0
  local timeout=0
  while [ "$count" -lt "$expected_count" ] && [ "$timeout" -lt 100 ]; do
    count=$(find "$BARRIER_DIR" -name "${barrier_name}.*" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -lt "$expected_count" ]; then
      sleep 0.1
      timeout=$((timeout + 1))
    fi
  done

  if [ "$timeout" -ge 100 ]; then
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

  # Spawn a process that acquires the lock and holds it indefinitely.
  # IMPORTANT: spawn as an independent child process (not a ( ) & subshell) so
  # that $$ inside the holder equals its real PID and equals the PID the source
  # records in the lock dir. Inside a ( ) & subshell, $$ is the BATS test-process
  # PID, so `echo $$ > holder_pid_file` would record the bats PID and
  # `kill -KILL` would SIGKILL the bats runner itself.
  "${BASH}" -c 'set -uo pipefail; source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"; acquire_scratchpad_lock; echo $$ > "'"$holder_pid_file"'"; touch "'"$lock_acquired_file"'"; sleep 60' &
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

# ---------------------------------------------------------------------------
# Test 6: RETURN-trap releases lock on invalid-category path
#
# The *)  branch in log_encountered_issue warns and remaps the bad category to
# "code-smell", then continues to completion (no early return).  The RETURN
# trap must still fire when the function returns so the lock is left free.
#
# Acceptance criterion (issue #149): calling log_encountered_issue with an
# unrecognised category must:
#   (a) succeed (exit 0),
#   (b) write the entry remapped to "code-smell", and
#   (c) release the scratchpad lock so that a subsequent caller can acquire it
#       without timing out.
#
# Design: force the mkdir lock strategy (via RITE_SCRATCHPAD_LOCK_STRATEGY=mkdir)
# so that lock state is visible as a filesystem directory.  log_encountered_issue
# is called directly in the test shell — not inside a ( subshell ) — so the only
# thing that can remove the lock directory after the function returns is the
# RETURN trap calling release_scratchpad_lock.  If the trap did not fire, the
# directory persists and the follow-up assertions fail.
#
# Why this matters: on the flock fast-path the kernel releases the lock when a
# subshell exits, regardless of whether the RETURN trap fired.  Running
# log_encountered_issue in a subshell therefore passes trivially even if the
# trap is broken.  The mkdir + same-shell approach closes that loophole.
#
# Why not PATH hiding: prepending an empty directory to PATH does not prevent
# command -v flock from finding flock in other PATH entries.  The env-var
# override is the only reliable way to force the mkdir path on systems where
# flock is installed.
# ---------------------------------------------------------------------------
@test "log_encountered_issue: RETURN trap releases lock on invalid-category path" {
  local lockfile="${SCRATCHPAD_FILE}.lock"
  local followup_result="$RITE_TEST_TMPDIR/followup_result"

  # Force the mkdir lock strategy via environment variable so that lock state
  # is observable as a filesystem directory: it exists while the lock is held
  # and is removed by release_scratchpad_lock when the RETURN trap fires.
  # This is more reliable than PATH manipulation, which does not prevent
  # command -v flock from finding flock elsewhere in the PATH.
  export RITE_SCRATCHPAD_LOCK_STRATEGY="mkdir"

  # Source the libraries in the current test shell so we can call
  # log_encountered_issue as a direct function invocation (not a subshell).
  # Calling it in a subshell would allow subshell-exit to release the lock
  # independently of the trap, masking a missing RETURN trap.
  source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
  source "$RITE_LIB_DIR/utils/scratchpad-manager.sh"

  # Verify the strategy override was honoured: acquire + immediately release,
  # then confirm the lock path is a directory (mkdir path) not a plain file
  # (flock path).  Catches misconfiguration before the real test assertion.
  acquire_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_STRATEGY}" = "mkdir" ] || {
    echo "FAIL: expected mkdir strategy, got '${_SCRATCHPAD_LOCK_STRATEGY}'" >&2
    release_scratchpad_lock
    return 1
  }
  release_scratchpad_lock

  # Call log_encountered_issue with an unrecognised category.
  # Redirect stderr to suppress the "Unknown category" warning.
  # This is a direct function call in the current shell — the RETURN trap
  # fires here, not a subshell-exit side-effect.
  log_encountered_issue \
    "src/example.ts" "42" \
    "not-a-valid-category" \
    "Test entry via invalid category" \
    "lock-release verification" \
    "Ensure lock released on invalid-category path" \
    "Lock is free after function returns" 2>/dev/null

  # (a) Function must succeed — BATS would have failed on non-zero exit already
  #     because the test body runs with implicit errexit.

  # (b) Verify the entry was written with the remapped category "code-smell".
  # Assert both the category field AND the description to confirm remap happened.
  grep -q '| code-smell | Test entry via invalid category' "$SCRATCHPAD_FILE" || {
    echo "FAIL: entry with remapped category 'code-smell' not found in scratchpad" >&2
    cat "$SCRATCHPAD_FILE" >&2
    return 1
  }

  # (c) Primary assertion: the lock directory must be absent immediately after
  # the function returned.  On the mkdir path the directory persists until
  # release_scratchpad_lock removes it.  If the RETURN trap did not fire, the
  # directory is still present here and the test fails.
  [ ! -d "$lockfile" ] || {
    echo "FAIL: lock directory still exists after log_encountered_issue returned" >&2
    echo "      RETURN trap did not fire — lock was never released" >&2
    ls -la "$lockfile" >&2
    return 1
  }

  # Belt-and-suspenders: a concurrent process must also be able to acquire the
  # lock immediately (confirms the lock state is correct from an external PoV).
  (
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    export RITE_SCRATCHPAD_LOCK_TIMEOUT=3  # Fast fail — don't wait 30s if stuck
    if acquire_scratchpad_lock; then
      release_scratchpad_lock
      echo "acquired" > "$followup_result"
    else
      echo "blocked" > "$followup_result"
    fi
  )

  [ -f "$followup_result" ] || {
    echo "FAIL: follow-up acquire subprocess did not write result" >&2
    return 1
  }
  local followup_outcome
  followup_outcome=$(cat "$followup_result")
  [ "$followup_outcome" = "acquired" ] || {
    echo "FAIL: follow-up caller could not acquire lock after invalid-category path" >&2
    echo "      RETURN trap likely did not fire — lock was not released" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 7: RETURN-trap releases lock on early-return duplicate-detection path
#
# When log_encountered_issue detects a duplicate file:line it executes
# `return 0` inside the function after the lock is already held.  The RETURN
# trap (`trap 'release_scratchpad_lock' RETURN`) must fire on this early-return
# path, releasing the lock so that subsequent callers are not blocked.
#
# Acceptance criterion (issue #149): a second call to log_encountered_issue
# with the same file:line (duplicate) must leave the lock free for a
# concurrent caller that arrives immediately afterward.
#
# Design: force the mkdir lock strategy (via RITE_SCRATCHPAD_LOCK_STRATEGY=mkdir)
# so that lock state is visible as a filesystem directory.  The duplicate call
# is made directly in the test shell — not inside a ( subshell ) — so the only
# thing that can remove the lock directory after the function returns is the
# RETURN trap calling release_scratchpad_lock.  If the trap did not fire on the
# early-return path, the directory persists and the test fails.
#
# Why this matters: on the flock fast-path the kernel releases the lock when a
# subshell exits, regardless of whether the RETURN trap fired.  Running the
# duplicate call in a subshell therefore passes trivially even if the trap is
# absent on the early-return path.  The mkdir + same-shell approach closes that
# loophole.
#
# Why not PATH hiding: prepending an empty directory to PATH does not prevent
# command -v flock from finding flock in other PATH entries.  The env-var
# override is the only reliable way to force the mkdir path on systems where
# flock is installed.
# ---------------------------------------------------------------------------
@test "log_encountered_issue: RETURN trap releases lock on duplicate early-return path" {
  local lockfile="${SCRATCHPAD_FILE}.lock"
  local third_result="$RITE_TEST_TMPDIR/third_result"

  # Force the mkdir lock strategy via environment variable so that lock state
  # is observable as a filesystem directory.  PATH manipulation is insufficient
  # because command -v flock still finds flock elsewhere in the PATH even when
  # an empty directory is prepended.
  export RITE_SCRATCHPAD_LOCK_STRATEGY="mkdir"

  # Source the libraries in the current test shell.  Both calls to
  # log_encountered_issue below will be direct function invocations.
  source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
  source "$RITE_LIB_DIR/utils/scratchpad-manager.sh"

  # Verify the strategy override was honoured before proceeding.
  acquire_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_STRATEGY}" = "mkdir" ] || {
    echo "FAIL: expected mkdir strategy, got '${_SCRATCHPAD_LOCK_STRATEGY}'" >&2
    release_scratchpad_lock
    return 1
  }
  release_scratchpad_lock

  # First call — seeds the scratchpad with a known entry.
  # Run in a subshell so that its lock state is isolated from the test shell;
  # we only care about the RETURN trap for the duplicate (second) call below.
  (
    log_encountered_issue \
      "src/dup-test.ts" "99" \
      "code-smell" \
      "Original entry for duplicate test" \
      "dup-test-feature" \
      "Fix original" \
      "Original present" 2>/dev/null
  )

  # Verify first call wrote the entry
  grep -q "src/dup-test.ts:99" "$SCRATCHPAD_FILE" || {
    echo "FAIL: first log_encountered_issue call did not write the entry" >&2
    cat "$SCRATCHPAD_FILE" >&2
    return 1
  }

  # Sanity check: no leftover lock directory before the duplicate call.
  [ ! -d "$lockfile" ] || {
    echo "FAIL: lock directory unexpectedly present before duplicate call" >&2
    return 1
  }

  # Second call with the same file:line — triggers duplicate detection return 0
  # inside the function after acquire_scratchpad_lock + trap RETURN have fired.
  # This is a direct function call in the current test shell.  The RETURN trap
  # is the only mechanism that can remove the lock directory on return.
  log_encountered_issue \
    "src/dup-test.ts" "99" \
    "code-smell" \
    "Duplicate entry — should be skipped" \
    "dup-test-feature" \
    "Fix dup" \
    "Dup handled" 2>/dev/null

  # Primary assertion: the lock directory must be absent immediately after the
  # duplicate call returned via the early-return path.  If the RETURN trap did
  # not fire, the directory is still present and the test fails.
  [ ! -d "$lockfile" ] || {
    echo "FAIL: lock directory still exists after duplicate log_encountered_issue returned" >&2
    echo "      RETURN trap did not fire on the early-return (duplicate) path" >&2
    ls -la "$lockfile" >&2
    return 1
  }

  # Verify the scratchpad still has only one entry for this file:line
  local entry_count
  entry_count=$(grep -c "src/dup-test.ts:99" "$SCRATCHPAD_FILE" || true)
  [ "$entry_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 entry for src/dup-test.ts:99, found $entry_count" >&2
    return 1
  }

  # Belt-and-suspenders: a concurrent process must also be able to acquire the
  # lock immediately (confirms the lock state is correct from an external PoV).
  (
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    export RITE_SCRATCHPAD_LOCK_TIMEOUT=3  # Fast fail if lock is stuck
    if acquire_scratchpad_lock; then
      release_scratchpad_lock
      echo "acquired" > "$third_result"
    else
      echo "blocked" > "$third_result"
    fi
  )

  [ -f "$third_result" ] || {
    echo "FAIL: third-caller subprocess did not write result" >&2
    return 1
  }
  local third_outcome
  third_outcome=$(cat "$third_result")
  [ "$third_outcome" = "acquired" ] || {
    echo "FAIL: third caller could not acquire lock — RETURN trap did not release it on duplicate early-return path" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 8: SIGKILL reclaim via mkdir stale-reclaim path (deterministic)
#
# Problem with Test 2 ("SIGKILL'd lock holder - next process reclaims lock
# within 5s"): on CI machines where flock(1) is available, the holder acquires
# the lock via flock, and when it is SIGKILLed the kernel releases the flock
# automatically.  The waiter then acquires the lock immediately — without ever
# entering the mkdir stale-reclaim code (kill -0 check → rm -rf → mkdir retry
# at lines 128-157 of scratchpad-lock.sh).  Test 2 passes trivially on those
# machines while leaving the riskiest hand-rolled reclaim code uncovered.
#
# This test closes the gap by forcing RITE_SCRATCHPAD_LOCK_STRATEGY=mkdir in
# both the holder and the waiter.  With the mkdir path:
#   - The holder creates a lock directory and writes its PID file.
#   - After SIGKILL, the lock directory persists (no kernel cleanup).
#   - The waiter sees mkdir fail (EEXIST), reads the PID from the directory,
#     runs kill -0 and finds the holder dead, removes the directory, and
#     retries mkdir — this is the stale-reclaim path we need to cover.
#
# Acceptance criterion (issue #151):
#   - Waiter acquires the lock within 5 seconds of the SIGKILL.
#   - The "reclaiming stale lock" diagnostic message is printed to stderr,
#     confirming the stale-reclaim code path was exercised (not just a fast
#     no-contention acquire).
#
# Why RITE_SCRATCHPAD_LOCK_STRATEGY=mkdir and not PATH manipulation:
#   PATH manipulation (prepending an empty directory) does not reliably hide
#   flock because `command -v flock` still finds flock elsewhere in PATH.
#   The env-var override is the only reliable mechanism and is already used
#   in Tests 6 and 7 for the same reason.
# ---------------------------------------------------------------------------
@test "SIGKILL'd lock holder - waiter exercises mkdir stale-reclaim path (deterministic)" {
  local lock_acquired_file="$RITE_TEST_TMPDIR/lock_acquired"
  local holder_pid_file="$RITE_TEST_TMPDIR/holder_pid"
  local reclaim_result_file="$RITE_TEST_TMPDIR/reclaim_result"
  local reclaim_stderr_file="$RITE_TEST_TMPDIR/reclaim_stderr"

  # Force the mkdir lock strategy in both holder and waiter so that the lock
  # state is a directory that persists after SIGKILL (unlike flock, where the
  # kernel releases the lock on process death without leaving anything behind).
  export RITE_SCRATCHPAD_LOCK_STRATEGY="mkdir"

  # Spawn a holder that acquires the lock via the mkdir path and holds it.
  # It writes its PID to a file and signals readiness, then sleeps until killed.
  #
  # IMPORTANT: spawn as an independent child process (not a ( ) & subshell) so
  # that $$ inside the holder equals its real PID and equals the PID the source
  # records in the lock dir's pid file. Inside a ( ) & subshell, $$ is the BATS
  # test-process PID, so `echo $$ > holder_pid_file` would record the bats PID,
  # `kill -KILL` would SIGKILL the bats runner itself, and the lock-dir pid would
  # point at a still-alive process so the waiter's kill -0 reclaim never fires.
  # RITE_SCRATCHPAD_LOCK_STRATEGY=mkdir is already exported above so the child
  # inherits it; the explicit re-export inside -c is belt-and-suspenders.
  "${BASH}" -c 'set -uo pipefail; export RITE_SCRATCHPAD_LOCK_STRATEGY=mkdir; source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"; acquire_scratchpad_lock; [ "$_SCRATCHPAD_LOCK_STRATEGY" = mkdir ] || { echo "FAIL: holder did not use mkdir strategy (got $_SCRATCHPAD_LOCK_STRATEGY)" >&2; exit 1; }; echo $$ > "'"$holder_pid_file"'"; touch "'"$lock_acquired_file"'"; sleep 60' &
  local holder_bgpid=$!

  # Wait up to 5s for the holder to acquire the lock and signal readiness
  local wait_count=0
  while [ ! -f "$lock_acquired_file" ] && [ "$wait_count" -lt 50 ]; do
    sleep 0.1
    wait_count=$((wait_count + 1))
  done

  [ -f "$lock_acquired_file" ] || {
    echo "FAIL: holder never acquired the lock (mkdir strategy)" >&2
    kill "$holder_bgpid" 2>/dev/null || true
    return 1
  }

  local holder_pid
  holder_pid=$(cat "$holder_pid_file")
  local lockfile="${SCRATCHPAD_FILE}.lock"

  # Precondition: the lock directory must exist (confirms mkdir path was used)
  [ -d "$lockfile" ] || {
    echo "FAIL: lock directory does not exist — holder did not use mkdir path" >&2
    kill "$holder_bgpid" 2>/dev/null || true
    return 1
  }

  # Precondition: the PID file inside the lock directory must exist
  [ -f "$lockfile/pid" ] || {
    echo "FAIL: PID file missing inside lock directory after holder acquired" >&2
    kill "$holder_bgpid" 2>/dev/null || true
    return 1
  }

  # SIGKILL the holder — the lock directory persists (no kernel cleanup on the
  # mkdir path, unlike flock where the kernel releases the lock automatically)
  kill -KILL "$holder_pid" 2>/dev/null || true
  wait "$holder_bgpid" 2>/dev/null || true

  # Confirm the lock directory is still present after the SIGKILL.
  # This is the key precondition that ensures the waiter must go through the
  # stale-reclaim code path rather than acquiring an already-released lock.
  [ -d "$lockfile" ] || {
    echo "FAIL: lock directory disappeared after SIGKILL — mkdir path not in use" >&2
    return 1
  }

  # Time the waiter acquire attempt
  local start_time
  start_time=$(date +%s)

  # Spawn the waiter in a background subshell with the same mkdir strategy forced.
  # The waiter must: see mkdir fail (EEXIST) → read PID → kill -0 fails →
  # rm -rf lock dir → retry mkdir → succeed.  Capture stderr to verify
  # the diagnostic message was printed (confirms reclaim code ran).
  # Run in background so we can impose a hard timeout — a reclaim regression
  # would otherwise cause an indefinite CI hang rather than a bounded failure.
  (
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    if acquire_scratchpad_lock; then
      echo "success" > "$reclaim_result_file"
      release_scratchpad_lock
    else
      echo "failure" > "$reclaim_result_file"
    fi
  ) 2>"$reclaim_stderr_file" &
  local waiter_bgpid=$!

  # Poll for the result file with a 10-second hard timeout.
  # 10s is 2× the 5s acceptance criterion — gives ample headroom on slow CI
  # machines while guaranteeing the test never hangs indefinitely.
  local poll_count=0
  while [ ! -f "$reclaim_result_file" ] && [ "$poll_count" -lt 100 ]; do
    sleep 0.1
    poll_count=$((poll_count + 1))
  done

  # If the waiter is still running past the timeout, kill it and fail fast.
  if [ ! -f "$reclaim_result_file" ]; then
    kill "$waiter_bgpid" 2>/dev/null || true
    wait "$waiter_bgpid" 2>/dev/null || true
    echo "FAIL: waiter did not complete within 10s — possible reclaim loop hang" >&2
    return 1
  fi

  wait "$waiter_bgpid" 2>/dev/null || true

  local end_time
  end_time=$(date +%s)
  local elapsed=$((end_time - start_time))

  # Assertion 1: waiter must have succeeded
  [ -f "$reclaim_result_file" ] || {
    echo "FAIL: waiter did not produce a result file" >&2
    return 1
  }
  local result
  result=$(cat "$reclaim_result_file")
  [ "$result" = "success" ] || {
    echo "FAIL: waiter failed to acquire lock after holder was SIGKILL'd (mkdir path)" >&2
    return 1
  }

  # Assertion 2: reclaim must complete within 5 seconds
  # The kill -0 check on a dead PID returns immediately, so the reclaim should
  # be near-instant.  5 seconds is generous headroom for slow CI machines.
  [ "$elapsed" -le 5 ] || {
    echo "FAIL: mkdir stale-reclaim took ${elapsed}s (expected <= 5s)" >&2
    return 1
  }

  # Assertion 3: the diagnostic "reclaiming stale lock" message must appear in
  # stderr.  This is the definitive proof that the stale-reclaim code path was
  # exercised (as opposed to a fast acquire on an already-released lock).
  [ -f "$reclaim_stderr_file" ] || {
    echo "FAIL: waiter stderr capture file missing" >&2
    return 1
  }
  grep -qi "reclaiming stale lock" "$reclaim_stderr_file" || {
    echo "FAIL: 'reclaiming stale lock' message not found in waiter stderr" >&2
    echo "      stderr was: $(cat "$reclaim_stderr_file")" >&2
    echo "      The mkdir stale-reclaim code path was not exercised." >&2
    return 1
  }

  # Clean up the exported strategy override so it doesn't bleed into subsequent
  # tests (bats provides process-per-test isolation, but explicit teardown is
  # clearer and guards against any future in-process test runner changes).
  unset RITE_SCRATCHPAD_LOCK_STRATEGY
}

# ---------------------------------------------------------------------------
# Test 9: Re-entrancy guard — nested acquire on mkdir path does not drop lock
#
# Verifies that a second call to acquire_scratchpad_lock() while the lock is
# already held (same shell, same process) increments the depth counter and
# returns 0 WITHOUT re-entering the mkdir machinery.  A matching inner release
# decrements the counter but does NOT remove the lock directory.  Only the
# outermost release (depth 1→0) removes the directory.
#
# Acceptance criteria (issue #150):
#   (a) Second acquire returns 0 (_SCRATCHPAD_LOCK_DEPTH becomes 2)
#   (b) Lock directory still exists after the inner release
#   (c) _SCRATCHPAD_LOCK_HELD is still "true" after the inner release
#   (d) Outer release (depth 1→0) removes the lock directory
#   (e) A concurrent process can acquire after the outer release
# ---------------------------------------------------------------------------
@test "re-entrancy guard: nested acquire/release on mkdir path preserves outer lock" {
  local lockfile="${SCRATCHPAD_FILE}.lock"
  local followup_result="$RITE_TEST_TMPDIR/followup_result"

  # Force the mkdir lock strategy so that lock state is observable as a directory.
  export RITE_SCRATCHPAD_LOCK_STRATEGY="mkdir"

  source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"

  # Outer acquire (depth 0→1)
  acquire_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_HELD}" = "true" ] || {
    echo "FAIL: outer acquire did not set _SCRATCHPAD_LOCK_HELD=true" >&2
    return 1
  }
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 1 ] || {
    echo "FAIL: expected depth=1 after outer acquire, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2
    return 1
  }
  [ -d "$lockfile" ] || {
    echo "FAIL: lock directory missing after outer acquire" >&2
    return 1
  }

  # Inner acquire (re-entrant, depth 1→2) — must not re-enter mkdir machinery
  acquire_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 2 ] || {
    echo "FAIL: expected depth=2 after inner acquire, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2
    return 1
  }
  # (a) lock directory must still be present (mkdir path not re-entered)
  [ -d "$lockfile" ] || {
    echo "FAIL: lock directory missing after inner acquire — mkdir machinery re-entered" >&2
    return 1
  }

  # Inner release (depth 2→1) — must NOT remove the lock directory
  release_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 1 ] || {
    echo "FAIL: expected depth=1 after inner release, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2
    return 1
  }
  # (b) lock directory must still exist: inner release must not drop the outer lock
  [ -d "$lockfile" ] || {
    echo "FAIL: lock directory removed by inner release — outer lock dropped prematurely" >&2
    return 1
  }
  # (c) _SCRATCHPAD_LOCK_HELD must still be true
  [ "${_SCRATCHPAD_LOCK_HELD}" = "true" ] || {
    echo "FAIL: _SCRATCHPAD_LOCK_HELD became false after inner release — outer lock state lost" >&2
    return 1
  }

  # Outer release (depth 1→0) — must remove the lock directory
  release_scratchpad_lock
  # (d) lock directory must be gone now
  [ ! -d "$lockfile" ] || {
    echo "FAIL: lock directory still present after outer release" >&2
    ls -la "$lockfile" >&2
    return 1
  }
  [ "${_SCRATCHPAD_LOCK_HELD}" = "false" ] || {
    echo "FAIL: _SCRATCHPAD_LOCK_HELD not reset to false after outer release" >&2
    return 1
  }
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 0 ] || {
    echo "FAIL: expected depth=0 after outer release, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2
    return 1
  }

  # (e) A subsequent caller must be able to acquire immediately
  (
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    export RITE_SCRATCHPAD_LOCK_TIMEOUT=3
    if acquire_scratchpad_lock; then
      release_scratchpad_lock
      echo "acquired" > "$followup_result"
    else
      echo "blocked" > "$followup_result"
    fi
  )

  [ -f "$followup_result" ] || {
    echo "FAIL: follow-up subprocess did not write result" >&2
    return 1
  }
  local followup_outcome
  followup_outcome=$(cat "$followup_result")
  [ "$followup_outcome" = "acquired" ] || {
    echo "FAIL: follow-up caller could not acquire lock after re-entrant acquire/release cycle" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 10: Re-entrancy guard — depth-3 nesting on mkdir path
#
# Exercises three levels of nesting to confirm the depth counter arithmetic
# is correct at each step: 0→1→2→3 on acquire, 3→2→1→0 on release.
# The lock directory must be present through all inner releases and absent
# only after the outermost release.
# ---------------------------------------------------------------------------
@test "re-entrancy guard: depth-3 nesting on mkdir path — lock held until outermost release" {
  local lockfile="${SCRATCHPAD_FILE}.lock"

  export RITE_SCRATCHPAD_LOCK_STRATEGY="mkdir"
  source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"

  # Depth 0→1
  acquire_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 1 ] || { echo "FAIL: depth should be 1, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2; return 1; }

  # Depth 1→2
  acquire_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 2 ] || { echo "FAIL: depth should be 2, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2; return 1; }

  # Depth 2→3
  acquire_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 3 ] || { echo "FAIL: depth should be 3, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2; return 1; }
  [ -d "$lockfile" ] || { echo "FAIL: lock dir missing at depth 3" >&2; return 1; }

  # Release depth 3→2
  release_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 2 ] || { echo "FAIL: depth should be 2 after first release, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2; return 1; }
  [ -d "$lockfile" ] || { echo "FAIL: lock dir removed at depth 2 (should still be held)" >&2; return 1; }

  # Release depth 2→1
  release_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 1 ] || { echo "FAIL: depth should be 1 after second release, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2; return 1; }
  [ -d "$lockfile" ] || { echo "FAIL: lock dir removed at depth 1 (should still be held)" >&2; return 1; }
  [ "${_SCRATCHPAD_LOCK_HELD}" = "true" ] || { echo "FAIL: held should still be true at depth 1" >&2; return 1; }

  # Release depth 1→0 — this is the outermost, must release
  release_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 0 ] || { echo "FAIL: depth should be 0 after outermost release, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2; return 1; }
  [ ! -d "$lockfile" ] || { echo "FAIL: lock dir still present after outermost release" >&2; return 1; }
  [ "${_SCRATCHPAD_LOCK_HELD}" = "false" ] || { echo "FAIL: held should be false after outermost release" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Test 10: Re-entrancy guard — nested acquire on flock fast-path does not
#          re-open the file descriptor or drop the outer lock
#
# The flock fast-path is the subject of issue #150. Tests 8 and 9 cover the
# mkdir path; this test exercises the same nesting logic on the flock path to
# ensure the guard works regardless of which strategy is selected at runtime.
#
# Acceptance criteria (issue #150, flock path):
#   (a) Second acquire returns 0 (_SCRATCHPAD_LOCK_DEPTH becomes 2)
#   (b) _SCRATCHPAD_LOCK_STRATEGY remains "flock" — flock path did not switch
#   (c) Inner release decrements depth to 1 but does NOT close FD 200
#   (d) Outer release (depth 1→0) closes FD 200 and resets held/strategy/depth
#   (e) A concurrent process (separate subshell, fresh flock) can acquire after
#       the outer release
#
# Why not mkdir override: this test intentionally does NOT set
# RITE_SCRATCHPAD_LOCK_STRATEGY=mkdir. It only runs when flock(1) is available;
# if flock is absent the test is skipped.
# ---------------------------------------------------------------------------
@test "re-entrancy guard: nested acquire/release on flock fast-path preserves outer lock" {
  local lockfile="${SCRATCHPAD_FILE}.lock"
  local followup_result="$RITE_TEST_TMPDIR/followup_result"

  # Skip if flock(1) is not available on this system
  command -v flock >/dev/null 2>&1 || skip "flock(1) not available on this system"

  # Do NOT set RITE_SCRATCHPAD_LOCK_STRATEGY — let acquire choose flock naturally.
  unset RITE_SCRATCHPAD_LOCK_STRATEGY

  source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"

  # Outer acquire (depth 0→1, flock path)
  acquire_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_HELD}" = "true" ] || {
    echo "FAIL: outer acquire did not set _SCRATCHPAD_LOCK_HELD=true" >&2
    return 1
  }
  [ "${_SCRATCHPAD_LOCK_STRATEGY}" = "flock" ] || {
    echo "FAIL: expected flock strategy, got '${_SCRATCHPAD_LOCK_STRATEGY}'" >&2
    release_scratchpad_lock
    return 1
  }
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 1 ] || {
    echo "FAIL: expected depth=1 after outer acquire, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2
    release_scratchpad_lock
    return 1
  }

  # (a) Inner acquire (re-entrant, depth 1→2) — must NOT re-open FD 200
  acquire_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 2 ] || {
    echo "FAIL: expected depth=2 after inner acquire, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2
    release_scratchpad_lock
    release_scratchpad_lock
    return 1
  }
  # (b) Strategy must still be flock — the fast-path code must not have been re-entered
  [ "${_SCRATCHPAD_LOCK_STRATEGY}" = "flock" ] || {
    echo "FAIL: strategy changed after inner acquire — flock fast-path was re-entered" >&2
    release_scratchpad_lock
    release_scratchpad_lock
    return 1
  }

  # (c) Inner release (depth 2→1) — decrements counter, must NOT close the fd
  release_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 1 ] || {
    echo "FAIL: expected depth=1 after inner release, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2
    release_scratchpad_lock
    return 1
  }
  [ "${_SCRATCHPAD_LOCK_HELD}" = "true" ] || {
    echo "FAIL: _SCRATCHPAD_LOCK_HELD became false after inner release" >&2
    release_scratchpad_lock
    return 1
  }
  # Verify the outer lock is still held: a concurrent subshell must NOT be able to
  # acquire the flock lock while the outer caller still holds it.
  local inner_release_probe="$RITE_TEST_TMPDIR/inner_release_probe"
  (
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    # 5s timeout: long enough for a legitimate acquire to succeed on slow CI
    # (distinguishes "blocked because lock is held" from "timed out on slow system")
    export RITE_SCRATCHPAD_LOCK_TIMEOUT=5
    if acquire_scratchpad_lock 2>/dev/null; then
      release_scratchpad_lock
      echo "acquired" > "$inner_release_probe"
    else
      echo "blocked" > "$inner_release_probe"
    fi
  )
  [ -f "$inner_release_probe" ] || {
    echo "FAIL: inner-release probe subprocess did not write result" >&2
    release_scratchpad_lock
    return 1
  }
  local inner_probe_outcome
  inner_probe_outcome=$(cat "$inner_release_probe")
  [ "$inner_probe_outcome" = "blocked" ] || {
    echo "FAIL: concurrent process acquired the lock after inner release — outer lock was dropped prematurely" >&2
    release_scratchpad_lock
    return 1
  }

  # (d) Outer release (depth 1→0) — closes FD 200, resets all state
  release_scratchpad_lock
  [ "${_SCRATCHPAD_LOCK_HELD}" = "false" ] || {
    echo "FAIL: _SCRATCHPAD_LOCK_HELD not reset to false after outer release" >&2
    return 1
  }
  [ "${_SCRATCHPAD_LOCK_DEPTH}" -eq 0 ] || {
    echo "FAIL: expected depth=0 after outer release, got ${_SCRATCHPAD_LOCK_DEPTH}" >&2
    return 1
  }
  [ "${_SCRATCHPAD_LOCK_STRATEGY}" = "" ] || {
    echo "FAIL: _SCRATCHPAD_LOCK_STRATEGY not cleared after outer release, got '${_SCRATCHPAD_LOCK_STRATEGY}'" >&2
    return 1
  }

  # (e) A subsequent caller must now be able to acquire the flock lock
  (
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    export RITE_SCRATCHPAD_LOCK_TIMEOUT=3
    if acquire_scratchpad_lock; then
      release_scratchpad_lock
      echo "acquired" > "$followup_result"
    else
      echo "blocked" > "$followup_result"
    fi
  )

  [ -f "$followup_result" ] || {
    echo "FAIL: follow-up subprocess did not write result" >&2
    return 1
  }
  local followup_outcome
  followup_outcome=$(cat "$followup_result")
  [ "$followup_outcome" = "acquired" ] || {
    echo "FAIL: follow-up caller could not acquire flock lock after re-entrant acquire/release cycle" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 11: Trap-fired release at depth > 1 — OS lock is released on abnormal exit
#
# Regression test for the HIGH bug identified in review: the trap handler
# installed by _setup_scratchpad_lock_trap called release_scratchpad_lock()
# directly, which only decrements the depth counter by 1.  If a process exits
# abnormally while holding the lock at depth > 1 (nested acquires), the depth
# counter would be decremented to 1 but the OS-level lock would NOT be released,
# leaving the lock held until it timed out (30s default).
#
# Fix: _scratchpad_lock_trap_release() resets _SCRATCHPAD_LOCK_DEPTH to 1
# before calling release_scratchpad_lock(), ensuring the OS-level release
# always occurs on abnormal exit regardless of nesting depth.
#
# Acceptance criteria:
#   (a) A subprocess acquires at depth 2 (nested) then exits abnormally (exit 1)
#   (b) After the subprocess exits, a new caller can acquire within 3 seconds
#       (the lock was released by the trap handler, not left blocking the timeout)
#
# Design: tested on both mkdir and flock paths (the depth-reset fix applies to
# both). Each sub-case spawns a subprocess that installs the trap and then
# acquires at depth 2 before exiting, so the trap fires with depth=2.
# ---------------------------------------------------------------------------
@test "trap-fired release at depth > 1: OS lock released on abnormal exit (mkdir path)" {
  local lockfile="${SCRATCHPAD_FILE}.lock"
  local followup_result="$RITE_TEST_TMPDIR/followup_result_mkdir"

  # Force mkdir path so lock state is observable as a directory.
  export RITE_SCRATCHPAD_LOCK_STRATEGY="mkdir"

  # Spawn a subprocess that:
  #   1. acquires at depth 1 (outer)
  #   2. installs the trap
  #   3. acquires at depth 2 (inner/nested)
  #   4. exits abnormally (simulates crash) without calling release_scratchpad_lock
  (
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    acquire_scratchpad_lock          # depth 1
    _setup_scratchpad_lock_trap      # installs _scratchpad_lock_trap_release on EXIT
    acquire_scratchpad_lock          # depth 2 (re-entrant)
    # Exit without explicit release — trap fires here
    exit 1
  ) || true  # subprocess exits 1; that's expected

  # (a) After the subprocess exits, the lock must be free.
  # The trap handler must have reset depth to 1 and then released the OS lock.
  # If the old (broken) behavior is present, the mkdir lock directory still exists.
  [ ! -d "$lockfile" ] || {
    echo "FAIL: lock directory still present after trapped abnormal exit at depth 2" >&2
    echo "      _scratchpad_lock_trap_release did not reset depth before releasing" >&2
    ls -la "$lockfile" >&2
    return 1
  }

  # (b) A new caller must be able to acquire immediately (not wait up to 30s for timeout).
  (
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    export RITE_SCRATCHPAD_LOCK_TIMEOUT=3  # Fail fast — should not need to wait
    if acquire_scratchpad_lock; then
      release_scratchpad_lock
      echo "acquired" > "$followup_result"
    else
      echo "blocked" > "$followup_result"
    fi
  )

  [ -f "$followup_result" ] || {
    echo "FAIL: follow-up subprocess did not write result" >&2
    return 1
  }
  local followup_outcome
  followup_outcome=$(cat "$followup_result")
  [ "$followup_outcome" = "acquired" ] || {
    echo "FAIL: follow-up caller blocked after trapped abnormal exit at depth 2 (mkdir path)" >&2
    echo "      Trap handler did not release the OS lock — depth was not reset to 1 before release" >&2
    return 1
  }
}

@test "trap-fired release at depth > 1: OS lock released on abnormal exit (flock path)" {
  local followup_result="$RITE_TEST_TMPDIR/followup_result_flock"

  # Skip if flock(1) is not available on this system
  command -v flock >/dev/null 2>&1 || skip "flock(1) not available on this system"

  # Do NOT set RITE_SCRATCHPAD_LOCK_STRATEGY — let acquire choose flock naturally.
  unset RITE_SCRATCHPAD_LOCK_STRATEGY

  # Spawn a subprocess that acquires at depth 2 then exits abnormally.
  # On the flock path the kernel releases the flock automatically when the
  # process exits (fd is closed), so the trap is not strictly necessary for
  # the OS-level release on flock.  However, the trap must still reset
  # _SCRATCHPAD_LOCK_DEPTH so that if the same shell reuses the variables
  # (e.g. in a test loop) the state is consistent.  More importantly, the
  # trap must not error out or leave the variables in an inconsistent state.
  (
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    acquire_scratchpad_lock          # depth 1
    _setup_scratchpad_lock_trap      # installs trap
    acquire_scratchpad_lock          # depth 2 (re-entrant)
    exit 1                           # abnormal exit — trap fires
  ) || true

  # (b) A new caller must be able to acquire immediately.
  # On the flock path the kernel released the lock on process exit.
  # This confirms no fd-level or state-level issue survives the trap.
  (
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    export RITE_SCRATCHPAD_LOCK_TIMEOUT=3
    if acquire_scratchpad_lock; then
      release_scratchpad_lock
      echo "acquired" > "$followup_result"
    else
      echo "blocked" > "$followup_result"
    fi
  )

  [ -f "$followup_result" ] || {
    echo "FAIL: follow-up subprocess did not write result" >&2
    return 1
  }
  local followup_outcome
  followup_outcome=$(cat "$followup_result")
  [ "$followup_outcome" = "acquired" ] || {
    echo "FAIL: follow-up caller blocked after trapped abnormal exit at depth 2 (flock path)" >&2
    return 1
  }
}
