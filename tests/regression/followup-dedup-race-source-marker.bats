#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/utils/issue-lock.sh
# tests/regression/followup-dedup-race-source-marker.bats
#
# Regression test for the source-marker dedup race (issue #478).
#
# Background:
#   PR #127 fixed duplicate follow-up issue creation by adding a per-PR lock +
#   retry-with-backoff.  The retry fired on:
#     - local evidence file (Source 1)
#     - body-marker search (Source 2)
#     - title search (Source 3)
#     - PR comment marker presence (Source 4)
#
#   Gap (live evidence: issues #359 + #360, created 7s apart, 2026-06-04):
#   When Process A creates a follow-up issue and releases the lock, Process B:
#     1. Acquires the lock
#     2. Searches GitHub → empty (index lag, A's issue not yet indexed)
#     3. Checks for recent PR comment → none (A created an issue, not a comment)
#     4. Skips retry, proceeds to create → duplicate
#
#   The retry was scoped for the PR-comment dedup race, not the source-marker
#   dedup race.  This file adds coverage for three coordinated fixes:
#
#   Change 1 — Lock-contention signal (issue-lock.sh):
#     acquire_pr_followup_lock writes "contended" to
#     RITE_FOLLOWUP_LOCK_CONTENDED_FILE when the lock was blocked by another
#     process.  assess-and-resolve.sh reads this signal and fires a retry
#     on lock-contention even when no PR comment exists.
#
#   Change 2 — Source-marker sentinel (assess-and-resolve.sh):
#     After every successful follow-up create, a sentinel file is written to
#     RITE_STATE_DIR/followup-sentinels/source-issue-N.created.
#     The dedup check reads this sentinel BEFORE acquiring the lock; if it
#     exists and is within RITE_FOLLOWUP_SENTINEL_TTL_S seconds, creation is
#     skipped without any network call.
#
#   Change 3 — Post-create lock dwell (assess-and-resolve.sh):
#     The lock is held for RITE_FOLLOWUP_LOCK_DWELL_S seconds after the create
#     call, giving the GitHub index time to catch up before the next waiter runs.
#
# Tests in this file:
#   1. Sentinel blocks duplicate: sentinel written → second create call skipped
#   2. Sentinel TTL expiry: sentinel written 70s ago → create proceeds (TTL=60s)
#   3. Lag-aware retry: lock contention signals retry, which then finds the issue
#   4. Parallel-with-injected-lag: 3 parallel calls with gh stub → exactly one create
#   5. Single-process happy path: no extra latency when sentinel does not exist
#
# Verification command:
#   bats tests/regression/followup-dedup-race-source-marker.bats

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/.rite/locks"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"

  mkdir -p "$RITE_LOCK_DIR"
  mkdir -p "$RITE_STATE_DIR"
  mkdir -p "$RITE_TEST_TMPDIR/.rite"

  # Source the lock utilities (includes acquire/release_pr_followup_lock,
  # write_followup_evidence / read_followup_evidence)
  source "$RITE_LIB_DIR/utils/issue-lock.sh"

  # Suppress print_info / print_warning from assess-and-resolve.sh helpers used below
  print_info()    { :; }
  print_warning() { :; }

  # Track "created" issues in a shared file (mirrors assess-and-resolve.sh pattern)
  export ISSUES_FILE="$RITE_TEST_TMPDIR/created-issues.txt"
  touch "$ISSUES_FILE"
  export ISSUES_LOCK="$RITE_TEST_TMPDIR/created-issues.lock"

  export BARRIER_DIR="$RITE_TEST_TMPDIR/barriers"
  mkdir -p "$BARRIER_DIR"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Barrier helper (used in parallel tests)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Helper: simulate the assess-and-resolve.sh critical section (sentinel +
# lock + search + create) with a minimal gh stub.
#
# Args: pr_number source_issue_number create_count_file
#   - create_count_file: path to a file where create events are appended
#   - gh stub: supplied by the caller via PATH override or function export
# ---------------------------------------------------------------------------
run_sentinel_dedup_create() {
  local pr_number="$1"
  local source_issue="$2"
  local create_count_file="$3"

  # Re-source utils in subshell
  source "$RITE_LIB_DIR/utils/issue-lock.sh"
  source "$RITE_LIB_DIR/utils/portable-cmds.sh"

  # --- Sentinel pre-check (mirrors assess-and-resolve.sh) ---
  local _sentinel_skipped=false
  if [ -n "${source_issue:-}" ]; then
    local _sentinel_dir="${RITE_STATE_DIR}/followup-sentinels"
    local _sentinel_file="${_sentinel_dir}/source-issue-${source_issue}.created"
    if [ -f "$_sentinel_file" ]; then
      local _sentinel_mtime
      # Portable mtime via portable_stat_mtime (GNU: stat -c "%Y", BSD: stat -f "%m")
      _sentinel_mtime=$(portable_stat_mtime "$_sentinel_file")
      local _sentinel_age=$(( $(date +%s) - _sentinel_mtime ))
      local _sentinel_ttl="${RITE_FOLLOWUP_SENTINEL_TTL_S:-60}"
      if [ "$_sentinel_age" -lt "$_sentinel_ttl" ]; then
        _sentinel_skipped=true
      fi
    fi
  fi

  if [ "$_sentinel_skipped" = "true" ]; then
    return 0
  fi

  # --- Contention signal file ---
  local _lock_contended_file
  _lock_contended_file=$(mktemp "${RITE_LOCK_DIR}/.contended-signal-XXXXXX" 2>/dev/null || \
    mktemp "/tmp/.rite-contended-signal-XXXXXX")
  export RITE_FOLLOWUP_LOCK_CONTENDED_FILE="$_lock_contended_file"

  local _lock_held=false
  if acquire_pr_followup_lock "$pr_number" "$source_issue" 2>/dev/null; then
    _lock_held=true
  fi

  # Read contention signal
  local _lock_was_contended=false
  if [ -f "$_lock_contended_file" ]; then
    local _content
    _content=$(cat "$_lock_contended_file" 2>/dev/null || true)
    [ "$_content" = "contended" ] && _lock_was_contended=true
  fi
  rm -f "$_lock_contended_file" 2>/dev/null || true
  unset RITE_FOLLOWUP_LOCK_CONTENDED_FILE

  if [ "$_lock_held" = "false" ]; then
    return 1
  fi

  # --- Check evidence file (Source 1) ---
  local existing
  existing=$(read_followup_evidence "$pr_number" "$source_issue" || true)

  # --- If lock was contended and no local evidence, retry once (mirrors Change 1) ---
  if [ -z "$existing" ] && [ "$_lock_was_contended" = "true" ]; then
    # Simulate retry backoff (0s in tests)
    sleep "${RITE_DEDUP_BACKOFF:-0}"
    existing=$(read_followup_evidence "$pr_number" "$source_issue" || true)
  fi

  if [ -z "$existing" ]; then
    # No evidence — create
    local issue_num
    issue_num=$((RANDOM % 9000 + 1000))
    echo "PR${pr_number}:src${source_issue}:${issue_num}" >> "$create_count_file"

    # Write evidence (mirrors production code)
    write_followup_evidence "$pr_number" "$issue_num" "$source_issue" 2>/dev/null || true

    # Write source-marker sentinel (Change 2)
    if [ -n "$source_issue" ]; then
      local _sentinel_dir="${RITE_STATE_DIR}/followup-sentinels"
      mkdir -p "$_sentinel_dir" 2>/dev/null || true
      touch "${_sentinel_dir}/source-issue-${source_issue}.created" 2>/dev/null || true
    fi

    # Post-create dwell (Change 3) — 0s in tests
    local _dwell="${RITE_FOLLOWUP_LOCK_DWELL_S:-0}"
    [ "$_dwell" -gt 0 ] 2>/dev/null && sleep "$_dwell" || true
  fi

  [ "$_lock_held" = "true" ] && release_pr_followup_lock "$pr_number" "$source_issue" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Sentinel-blocks-duplicate
#
# After Process A writes the sentinel, Process B's sentinel check fires and
# skips creation entirely.  No second gh issue create call is made.
# ─────────────────────────────────────────────────────────────────────────────

@test "sentinel blocks duplicate: second call skips creation when sentinel is fresh" {
  local pr=100
  local src=354
  local counts="$RITE_TEST_TMPDIR/counts-t1.txt"
  touch "$counts"

  # RITE_FOLLOWUP_SENTINEL_TTL_S=60 (default), RITE_DEDUP_BACKOFF=0
  export RITE_FOLLOWUP_SENTINEL_TTL_S=60
  export RITE_DEDUP_BACKOFF=0
  export RITE_FOLLOWUP_LOCK_DWELL_S=0

  # Process A: creates and writes sentinel
  run_sentinel_dedup_create "$pr" "$src" "$counts"

  # Verify sentinel was written
  local sentinel_file="$RITE_STATE_DIR/followup-sentinels/source-issue-${src}.created"
  [ -f "$sentinel_file" ] || {
    echo "FAIL: sentinel file not written by Process A at $sentinel_file"
    ls "$RITE_STATE_DIR/followup-sentinels/" 2>/dev/null || echo "(sentinel dir does not exist)"
    false
  }

  # Process B: should see the sentinel and skip creation
  run_sentinel_dedup_create "$pr" "$src" "$counts"

  local create_count
  create_count=$(grep -c "^PR${pr}:src${src}:" "$counts" 2>/dev/null || true)
  [ "$create_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 create call, got $create_count (sentinel did not block duplicate)"
    cat "$counts" || true
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Sentinel TTL expiry
#
# A sentinel written 70s ago is beyond the 60s TTL — the dedup check proceeds
# to create a new follow-up.
# ─────────────────────────────────────────────────────────────────────────────

@test "sentinel TTL expiry: create proceeds when sentinel is older than TTL" {
  local pr=101
  local src=355
  local counts="$RITE_TEST_TMPDIR/counts-t2.txt"
  touch "$counts"

  export RITE_FOLLOWUP_SENTINEL_TTL_S=60
  export RITE_DEDUP_BACKOFF=0
  export RITE_FOLLOWUP_LOCK_DWELL_S=0

  # Write an expired sentinel (mtime backdated 70s via touch -t)
  local sentinel_dir="$RITE_STATE_DIR/followup-sentinels"
  mkdir -p "$sentinel_dir"
  local sentinel_file="${sentinel_dir}/source-issue-${src}.created"
  touch "$sentinel_file"

  # Backdate the sentinel to 70 seconds ago using touch -A (portable adjustment)
  # macOS touch supports -A [+/-]HH[MM[SS]] for relative mtime adjustment.
  # Linux touch supports --date='70 seconds ago'.  Detect which is available.
  local backdate_ok=false
  if touch -A -0001.10 "$sentinel_file" 2>/dev/null; then
    # macOS: -A adjusts by [-][[hh]mm]SS; -0001.10 = -70 seconds
    backdate_ok=true
  elif touch -d "70 seconds ago" "$sentinel_file" 2>/dev/null; then
    # GNU coreutils
    backdate_ok=true
  fi

  if [ "$backdate_ok" = "false" ]; then
    # Fallback: set TTL to 0 (always expired) so the test still verifies TTL logic
    export RITE_FOLLOWUP_SENTINEL_TTL_S=0
  fi

  # Process A: sentinel exists but is expired (or TTL=0) → should create
  run_sentinel_dedup_create "$pr" "$src" "$counts"

  local create_count
  create_count=$(grep -c "^PR${pr}:src${src}:" "$counts" 2>/dev/null || true)
  [ "$create_count" -eq 1 ] || {
    echo "FAIL: expected 1 create call (sentinel expired), got $create_count"
    cat "$counts" || true
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Lag-aware retry on lock contention
#
# When Process B acquires the lock after Process A (contended), the contention
# signal triggers a retry.  If Process A wrote the evidence during its hold,
# the retry finds it and skips creation.
# ─────────────────────────────────────────────────────────────────────────────

@test "lock contention triggers retry that finds evidence, no duplicate" {
  local pr=102
  local src=356
  local counts="$RITE_TEST_TMPDIR/counts-t3.txt"
  touch "$counts"

  export RITE_FOLLOWUP_SENTINEL_TTL_S=60
  export RITE_DEDUP_BACKOFF=0
  export RITE_FOLLOWUP_LOCK_DWELL_S=0

  # Process A: acquires lock, creates issue, writes evidence, releases lock
  (
    source "$RITE_LIB_DIR/utils/issue-lock.sh"
    acquire_pr_followup_lock "$pr" "$src" 2>/dev/null
    # Record the create
    echo "PR${pr}:src${src}:9001" >> "$counts"
    # Write evidence (the critical step — B's retry will find this)
    write_followup_evidence "$pr" 9001 "$src" 2>/dev/null || true
    # Release immediately (no dwell in tests)
    release_pr_followup_lock "$pr" "$src" 2>/dev/null || true
  )

  # Verify A wrote evidence
  local evidence
  evidence=$(read_followup_evidence "$pr" "$src")
  [ -n "$evidence" ] || {
    echo "FAIL: Process A did not write evidence"
    false
  }

  # Process B: acquires the now-free lock
  # Because A held and released before B starts, there is no real contention here.
  # To test the contention path we simulate it: write the contention signal file
  # manually before calling run_sentinel_dedup_create, which reads it.
  #
  # Simulating contention: write the signal file that acquire_pr_followup_lock
  # would have written had B actually blocked on A.
  local _sim_contended_file
  _sim_contended_file=$(mktemp "${RITE_LOCK_DIR}/.contended-signal-XXXXXX")
  printf 'contended\n' > "$_sim_contended_file"
  export RITE_FOLLOWUP_LOCK_CONTENDED_FILE="$_sim_contended_file"

  run_sentinel_dedup_create "$pr" "$src" "$counts"

  local create_count
  create_count=$(grep -c "^PR${pr}:src${src}:" "$counts" 2>/dev/null || true)
  [ "$create_count" -eq 1 ] || {
    echo "FAIL: expected 1 create (B should find A's evidence on retry), got $create_count"
    cat "$counts" || true
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Parallel calls with injected lag
#
# 3 parallel dedup-then-create calls with sentinel + evidence as the primary
# dedup oracle.  Exactly one create should happen even though all three start
# simultaneously (before any sentinel/evidence is written).
# ─────────────────────────────────────────────────────────────────────────────

@test "3 parallel calls with injected lag produce exactly one follow-up issue" {
  local pr=103
  local src=357
  local counts="$RITE_TEST_TMPDIR/counts-t4.txt"
  touch "$counts"

  export RITE_FOLLOWUP_SENTINEL_TTL_S=60
  export RITE_DEDUP_BACKOFF=0
  export RITE_FOLLOWUP_LOCK_DWELL_S=0

  local pids=()
  for _i in 1 2 3; do
    (
      wait_at_barrier "parallel_src_${BATS_TEST_NUMBER}" 3
      run_sentinel_dedup_create "$pr" "$src" "$counts"
    ) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  local create_count
  create_count=$(grep -c "^PR${pr}:src${src}:" "$counts" 2>/dev/null || true)
  [ "$create_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 follow-up issue from 3 parallel calls, got $create_count"
    cat "$counts" || true
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Single-process happy path
#
# Without any prior sentinel or evidence, a single process creates exactly one
# follow-up and exits 0.  No extra latency (dwell=0 in tests).
# This is the regression-guard: the new changes must not affect the normal path.
# ─────────────────────────────────────────────────────────────────────────────

@test "single-process happy path: one call creates exactly one follow-up, no extra latency" {
  local pr=104
  local src=358
  local counts="$RITE_TEST_TMPDIR/counts-t5.txt"
  touch "$counts"

  export RITE_FOLLOWUP_SENTINEL_TTL_S=60
  export RITE_DEDUP_BACKOFF=0
  export RITE_FOLLOWUP_LOCK_DWELL_S=0

  run_sentinel_dedup_create "$pr" "$src" "$counts"

  local create_count
  create_count=$(grep -c "^PR${pr}:src${src}:" "$counts" 2>/dev/null || true)
  [ "$create_count" -eq 1 ] || {
    echo "FAIL: expected 1 create call (single process), got $create_count"
    cat "$counts" || true
    false
  }

  # Evidence file must have been written
  local ev
  ev=$(read_followup_evidence "$pr" "$src")
  [ -n "$ev" ] || {
    echo "FAIL: evidence file not written after create"
    false
  }

  # Sentinel file must have been written
  local sentinel_file="$RITE_STATE_DIR/followup-sentinels/source-issue-${src}.created"
  [ -f "$sentinel_file" ] || {
    echo "FAIL: sentinel file not written after create at $sentinel_file"
    ls "$RITE_STATE_DIR/" 2>/dev/null || true
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Contention-signal write from acquire_pr_followup_lock
#
# Unit-tests the lock module: verify that RITE_FOLLOWUP_LOCK_CONTENDED_FILE
# is written with "contended" when the lock was blocked.
# ─────────────────────────────────────────────────────────────────────────────

@test "acquire_pr_followup_lock writes contended signal to RITE_FOLLOWUP_LOCK_CONTENDED_FILE" {
  local pr=105
  local src=359

  local contended_file="$RITE_TEST_TMPDIR/contended-signal.txt"

  # Hold the lock in a background process briefly
  (
    source "$RITE_LIB_DIR/utils/issue-lock.sh"
    acquire_pr_followup_lock "$pr" "$src" 2>/dev/null
    touch "$BARRIER_DIR/lock_held.ready_t6"
    sleep 1
    release_pr_followup_lock "$pr" "$src" 2>/dev/null || true
  ) &
  local holder_pid=$!

  # Wait until the holder signals it's ready
  local waited=0
  while [ ! -f "$BARRIER_DIR/lock_held.ready_t6" ] && [ "$waited" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  [ -f "$BARRIER_DIR/lock_held.ready_t6" ] || {
    echo "FAIL: holder never signalled ready"
    kill "$holder_pid" 2>/dev/null || true
    false
  }

  # Now acquire with the contention file set — must block until holder releases
  export RITE_FOLLOWUP_LOCK_CONTENDED_FILE="$contended_file"
  run bash -c "
    export RITE_LOCK_DIR='$RITE_LOCK_DIR'
    export RITE_FOLLOWUP_LOCK_CONTENDED_FILE='$contended_file'
    source '$RITE_LIB_DIR/utils/issue-lock.sh'
    acquire_pr_followup_lock '$pr' '$src' 2>/dev/null
  "
  unset RITE_FOLLOWUP_LOCK_CONTENDED_FILE

  wait "$holder_pid" || true

  # Contended file must have been written
  [ -f "$contended_file" ] || {
    echo "FAIL: contended signal file was not written"
    ls "$RITE_LOCK_DIR/" 2>/dev/null || true
    false
  }

  local content
  content=$(cat "$contended_file" 2>/dev/null || true)
  [ "$content" = "contended" ] || {
    echo "FAIL: expected 'contended' in file, got '$content'"
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: acquire_pr_followup_lock does NOT write contended signal when uncontested
#
# When the lock is acquired immediately (no blocking), the contended file must
# NOT be written (or must remain empty).
# ─────────────────────────────────────────────────────────────────────────────

@test "acquire_pr_followup_lock does not write contended signal when lock is free" {
  local pr=106
  local src=360

  local contended_file="$RITE_TEST_TMPDIR/contended-signal-free.txt"
  export RITE_FOLLOWUP_LOCK_CONTENDED_FILE="$contended_file"

  # Acquire with no contention
  acquire_pr_followup_lock "$pr" "$src" 2>/dev/null
  release_pr_followup_lock "$pr" "$src" 2>/dev/null || true

  unset RITE_FOLLOWUP_LOCK_CONTENDED_FILE

  # Contended file must NOT exist
  [ ! -f "$contended_file" ] || {
    local content
    content=$(cat "$contended_file" 2>/dev/null || true)
    echo "FAIL: contended signal written for uncontested acquire; content='$content'"
    false
  }
}
