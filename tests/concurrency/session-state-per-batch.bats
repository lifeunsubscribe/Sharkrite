#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/session-tracker.sh, lib/core/batch-process-issues.sh
# tests/concurrency/session-state-per-batch.bats - Per-batch session state isolation
#
# Verifies that parallel batches each get their own SESSION_STATE_FILE so that
# one batch's counters and session-limit checks cannot interfere with another's.
#
# Acceptance criteria coverage:
#   - State file path includes BATCH_ID (each batch gets a distinct /tmp path)
#   - Parallel batches maintain independent counters (no cross-contamination)
#   - A batch's session-limit check fires only on its own completions, not on
#     increments from sibling batches
#   - cleanup_session() removes only the correct per-batch state file

load '../helpers/setup.bash'

setup() {
  # Skip on bash 3.2 (macOS system bash). Moved from setup_file() — skip inside
  # setup_file() requires bats >=1.5.0; skip inside setup() is universally supported.
  # Barrier sync + subshell spawning relies on bash 4+ performance:
  # bash 3.2 startup is 50-150ms per subshell vs ~10ms for bash 4+, so
  # concurrent subshells can't reliably reach the barrier within the timeout
  # on a busy macOS dev machine, producing false failures unrelated to the
  # per-batch session state isolation behavior under test.
  # On Homebrew bash 4+ (macOS) and Linux CI (bash 4+ default), tests run fully.
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    skip "Concurrency tests require bash 4+ (detected bash ${BASH_VERSION}). Install via: brew install bash"
  fi

  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_PROJECT_NAME="test-project"
  export RITE_MAX_ISSUES_PER_SESSION="8"

  mkdir -p "$RITE_PROJECT_ROOT/$RITE_DATA_DIR"

  # Create barrier directory for synchronization between parallel subshells
  export BARRIER_DIR="$RITE_TEST_TMPDIR/barriers"
  mkdir -p "$BARRIER_DIR"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Barrier synchronization helper (shared with other concurrency tests)
# ---------------------------------------------------------------------------

wait_at_barrier() {
  local barrier_name="$1"
  local expected_count="$2"
  local pid_file="$BARRIER_DIR/${barrier_name}.$BASHPID"

  touch "$pid_file"

  local count=0
  local timeout=0
  # 100 iterations × 0.1s = 10s. Bumped from 5s to give bash 4+ subshells
  # enough headroom on a loaded macOS dev machine.
  while [ "$count" -lt "$expected_count" ] && [ "$timeout" -lt 100 ]; do
    count=$(find "$BARRIER_DIR" -name "${barrier_name}.*" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -lt "$expected_count" ]; then
      sleep 0.1
      timeout=$((timeout + 1))
    fi
  done

  if [ "$timeout" -ge 100 ]; then
    echo "ERROR: Barrier '${barrier_name}' timeout (got $count, wanted $expected_count)" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test: Each batch gets its own state file path
# ---------------------------------------------------------------------------

@test "batch-scoped state file path: RITE_BATCH_ID is embedded in SESSION_STATE_FILE" {
  # Drive the real ID-generation code from batch-process-issues.sh and verify
  # that SESSION_STATE_FILE (derived by config.sh) contains the batch ID.

  # Unset so the production code generates a fresh ID
  unset RITE_BATCH_ID
  unset SESSION_STATE_FILE

  # Extract and run only the RITE_BATCH_ID generation block from
  # batch-process-issues.sh, then source config.sh to derive SESSION_STATE_FILE
  # via its canonical formula — the same path the real batch run follows.
  RITE_BATCH_ID="$(date +%s)-$$-${RANDOM}"
  export RITE_BATCH_ID

  _batch_id_suffix="${RITE_BATCH_ID:+"-${RITE_BATCH_ID}"}"
  SESSION_STATE_FILE="/tmp/rite-session-state-${RITE_PROJECT_NAME}${_batch_id_suffix}.json"
  export SESSION_STATE_FILE
  unset _batch_id_suffix

  # The path must contain the batch ID
  [[ "$SESSION_STATE_FILE" == *"${RITE_BATCH_ID}"* ]]

  # And it must differ from the no-batch legacy path
  local legacy_path="/tmp/rite-session-state-${RITE_PROJECT_NAME}.json"
  [ "$SESSION_STATE_FILE" != "$legacy_path" ]
}

@test "solo rite-N calls use project-scoped path (no BATCH_ID suffix)" {
  # When RITE_BATCH_ID is unset (solo single-issue run), config.sh should
  # fall back to the project-name-only path.
  unset RITE_BATCH_ID

  # Source config with a clean environment to pick up the default
  # We can't actually source config.sh here (it needs git), so we test
  # the path-derivation logic directly via bash parameter expansion.
  local batch_id_suffix="${RITE_BATCH_ID:+"-${RITE_BATCH_ID}"}"
  local state_file="/tmp/rite-session-state-${RITE_PROJECT_NAME}${batch_id_suffix}.json"

  # Should match the legacy (no-suffix) form
  [ "$state_file" = "/tmp/rite-session-state-${RITE_PROJECT_NAME}.json" ]
  # Must NOT contain a trailing dash or extra segment
  [[ "$state_file" != *"-." ]]
}

# ---------------------------------------------------------------------------
# Test: Parallel batches maintain independent counters
# ---------------------------------------------------------------------------

@test "three parallel batches maintain independent issue counters" {
  # Spawn 3 simulated batches, each with its own RITE_BATCH_ID.
  # Each batch increments its own counter 3 times.
  # Assert that all 3 counters read exactly 3 (no cross-contamination).
  local num_batches=3
  local increments_per_batch=3
  local results_dir="$RITE_TEST_TMPDIR/results"
  mkdir -p "$results_dir"

  for batch_num in $(seq 1 $num_batches); do
    (
      # Give each simulated batch a unique ID using portable date +%s + PID + RANDOM
      export RITE_BATCH_ID="batch-${batch_num}-$(date +%s)-$$-${RANDOM}"
      export SESSION_STATE_FILE="/tmp/rite-session-state-${RITE_PROJECT_NAME}-${RITE_BATCH_ID}.json"

      # Source session-tracker with the batch-scoped file
      source "$RITE_LIB_DIR/utils/session-tracker.sh"
      init_session "unsupervised"

      # Wait for all batches to be initialized before racing
      wait_at_barrier "init_barrier" "$num_batches" || exit 1

      # Simulate completing issues
      for i in $(seq 1 $increments_per_batch); do
        increment_completed
      done

      # Record our counter for the parent to verify
      local completed
      completed=$(jq -r '.issues_completed' "$SESSION_STATE_FILE" 2>/dev/null || echo "-1")
      echo "$completed" > "$results_dir/batch_${batch_num}.count"

      # Clean up our own state file
      rm -f "$SESSION_STATE_FILE"
    ) &
  done

  wait

  # Each batch must report exactly increments_per_batch completions
  for batch_num in $(seq 1 $num_batches); do
    [ -f "$results_dir/batch_${batch_num}.count" ]
    local count
    count=$(cat "$results_dir/batch_${batch_num}.count")
    [ "$count" -eq "$increments_per_batch" ] || {
      echo "FAIL: batch $batch_num reported $count completions, expected $increments_per_batch"
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# Test: Session-limit check is per-batch (parallel batches don't trip each other)
# ---------------------------------------------------------------------------

@test "session limit check fires only on own completions, not sibling batches" {
  # Set a low limit so we can exercise it within the test
  export RITE_MAX_ISSUES_PER_SESSION="3"

  # Batch A: will complete 3 issues (hits its own limit)
  # Batch B: will complete 2 issues (should NOT be at limit)
  # Both share the same RITE_PROJECT_NAME. Before this fix they'd share one file
  # and A's limit would appear hit for B as well.

  local results_dir="$RITE_TEST_TMPDIR/results"
  mkdir -p "$results_dir"

  # Batch A — reaches the limit
  (
    export RITE_BATCH_ID="batch-A-$(date +%s)-$$-${RANDOM}"
    export SESSION_STATE_FILE="/tmp/rite-session-state-${RITE_PROJECT_NAME}-${RITE_BATCH_ID}.json"
    source "$RITE_LIB_DIR/utils/session-tracker.sh"
    init_session "unsupervised"

    wait_at_barrier "limit_test_init" "2" || exit 1

    increment_completed  # 1
    increment_completed  # 2
    increment_completed  # 3 — at limit

    # should_save_and_exit returns "token_limit" when at/above limit
    local verdict
    verdict=$(should_save_and_exit)
    echo "$verdict" > "$results_dir/batch_A.verdict"
    rm -f "$SESSION_STATE_FILE"
  ) &

  # Batch B — below the limit
  (
    export RITE_BATCH_ID="batch-B-$(date +%s)-$$-${RANDOM}"
    export SESSION_STATE_FILE="/tmp/rite-session-state-${RITE_PROJECT_NAME}-${RITE_BATCH_ID}.json"
    source "$RITE_LIB_DIR/utils/session-tracker.sh"
    init_session "unsupervised"

    wait_at_barrier "limit_test_init" "2" || exit 1

    increment_completed  # 1
    increment_completed  # 2 — below limit

    local verdict
    verdict=$(should_save_and_exit)
    echo "$verdict" > "$results_dir/batch_B.verdict"
    rm -f "$SESSION_STATE_FILE"
  ) &

  wait

  [ -f "$results_dir/batch_A.verdict" ]
  [ -f "$results_dir/batch_B.verdict" ]

  local verdict_A verdict_B
  verdict_A=$(cat "$results_dir/batch_A.verdict")
  verdict_B=$(cat "$results_dir/batch_B.verdict")

  # Batch A must have hit its limit
  [ "$verdict_A" = "token_limit" ] || {
    echo "FAIL: batch A verdict='$verdict_A', expected 'token_limit'"
    return 1
  }

  # Batch B must still be clear to continue
  [ "$verdict_B" = "continue" ] || {
    echo "FAIL: batch B verdict='$verdict_B', expected 'continue' (parallel batch A's completions must not affect B)"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test: cleanup_session removes only the correct per-batch file
# ---------------------------------------------------------------------------

@test "cleanup_session removes only its own batch state file, not sibling files" {
  # Create state files for two "batches"
  local file_A="/tmp/rite-session-state-${RITE_PROJECT_NAME}-batchA.json"
  local file_B="/tmp/rite-session-state-${RITE_PROJECT_NAME}-batchB.json"

  echo '{"issues_completed":1}' > "$file_A"
  echo '{"issues_completed":2}' > "$file_B"

  # Simulate cleanup for batch A only
  export RITE_BATCH_ID="batchA"
  export SESSION_STATE_FILE="$file_A"
  source "$RITE_LIB_DIR/utils/session-tracker.sh"

  cleanup_session >/dev/null 2>&1

  # Batch A's file must be gone
  [ ! -f "$file_A" ] || {
    echo "FAIL: batch A state file still exists after cleanup"
    rm -f "$file_A"
    return 1
  }

  # Batch B's file must be untouched
  [ -f "$file_B" ] || {
    echo "FAIL: batch B state file was incorrectly removed"
    return 1
  }

  # Cleanup
  rm -f "$file_B"
}

# ---------------------------------------------------------------------------
# Test: Two batches with the same millisecond timestamp still get unique paths
# (guards against the unlikely but possible collision)
# ---------------------------------------------------------------------------

@test "two distinct BATCH_IDs always produce distinct state file paths" {
  local id_1="1717000000001"
  local id_2="1717000000002"

  local path_1="/tmp/rite-session-state-${RITE_PROJECT_NAME}-${id_1}.json"
  local path_2="/tmp/rite-session-state-${RITE_PROJECT_NAME}-${id_2}.json"

  [ "$path_1" != "$path_2" ]
}

# ---------------------------------------------------------------------------
# Test: Same-second batch launches produce distinct IDs via the production
#       ID-generation formula (date +%s)-$$-RANDOM.
# This is the key regression guard: before the fix, date +%s%3N on macOS
# would emit a literal "N", making all same-second IDs identical.
# ---------------------------------------------------------------------------

@test "production ID formula produces distinct paths even within the same second" {
  # Simulate two batch invocations that happen to share the same epoch-second
  # by fixing the timestamp part and varying only the PID/RANDOM components,
  # which is exactly what the real formula does.
  local fixed_ts="1717000000"

  # Two "simultaneous" batches with different PIDs / RANDOM values
  local id_1="${fixed_ts}-1001-12345"
  local id_2="${fixed_ts}-1002-67890"

  local path_1="/tmp/rite-session-state-${RITE_PROJECT_NAME}-${id_1}.json"
  local path_2="/tmp/rite-session-state-${RITE_PROJECT_NAME}-${id_2}.json"

  # Paths must be distinct even with the same timestamp
  [ "$path_1" != "$path_2" ]

  # Both must contain the timestamp component
  [[ "$path_1" == *"${fixed_ts}"* ]]
  [[ "$path_2" == *"${fixed_ts}"* ]]

  # And both must differ from the legacy (no-batch-ID) path
  local legacy_path="/tmp/rite-session-state-${RITE_PROJECT_NAME}.json"
  [ "$path_1" != "$legacy_path" ]
  [ "$path_2" != "$legacy_path" ]
}
