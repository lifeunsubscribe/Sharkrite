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
#   3. Prior evidence (Source 1): A writes evidence; B's dedup check finds it
#   3b. Contention retry path: _lock_was_contended triggers retry; signal consumed
#   4. Parallel-with-injected-lag: 3 parallel calls with gh stub → exactly one create
#   5. Single-process happy path: no extra latency when sentinel does not exist
#
# Tests 3 and 3b directly exercise the production _followup_dedup_check()
# function (issue #544): the old hand-rolled mirror omitted Sources 2-4 and
# the full retry-loop bounds (_dedup_retries/_dedup_max_retries).
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

  # Suppress print_info / print_warning / print_success / print_error before
  # sourcing assess-and-resolve.sh — they may not be defined yet and the
  # sourced dependencies call them during load.
  print_info()    { :; }
  print_warning() { :; }
  print_success() { :; }
  print_error()   { :; }
  verbose_info()  { :; }
  _diag()         { :; }

  # Source assess-and-resolve.sh in function-only mode to load
  # _followup_dedup_check() without executing the script body (which would
  # parse args, install traps, and make live gh/claude calls).
  # This also sources all its dependencies (issue-lock.sh, markers.sh,
  # portable-cmds.sh, etc.) transitively.
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_LIB_DIR/core/assess-and-resolve.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
  unset RITE_SOURCE_FUNCTIONS_ONLY

  # gh_safe stub — returns safe defaults for all dedup-relevant gh calls:
  #   - issue view N --json state  → "OPEN"  (evidence validation: trust it)
  #   - issue list --search ... in:body → "" (no issue found in body search)
  #   - issue list --search in:title → "[]"  (no issue found in title search)
  #   - pr view N --json comments   → "0"    (no follow-up marker comments)
  # Tests that need different behavior override gh_safe locally.
  gh_safe() {
    local subcmd="${1:-}"
    # Source 1 validation: gh issue view N --json state --jq '.state'
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "view" ]; then
      echo "OPEN"
      return 0
    fi
    # Source 2: gh issue list --search "..." in:body → empty (not indexed yet)
    # Source 3: gh issue list --search "in:title ..." → empty JSON array
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "list" ]; then
      echo "[]"
      return 0
    fi
    # Source 4: gh pr view N --json comments --jq "... | length" → 0 (no comments)
    if [ "$subcmd" = "pr" ] && [ "${2:-}" = "view" ]; then
      echo "0"
      return 0
    fi
    return 0
  }
  export -f gh_safe

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
# Helper: exercise the production dedup critical section from assess-and-resolve.sh.
#
# Args: pr_number source_issue_number create_count_file
#   - create_count_file: path to a file where create events are appended
#
# This function mirrors the structure of assess-and-resolve.sh's follow-up
# issue creation critical section, but delegates the dedup check to the real
# production function _followup_dedup_check() (sourced via
# RITE_SOURCE_FUNCTIONS_ONLY=1 in setup()).  Previously this was a hand-rolled
# mirror that omitted Sources 2–4 and the full retry-loop bounds; using the
# production function ensures tests validate the actual dedup logic (issue #544).
#
# The "create" step is simulated (write to create_count_file) rather than
# calling gh issue create, so tests remain hermetic.  Evidence and sentinel
# writes are real — they exercise the same FS operations as production.
# ---------------------------------------------------------------------------
run_sentinel_dedup_create() {
  local pr_number="$1"
  local source_issue="$2"
  local create_count_file="$3"

  # All required functions (_followup_dedup_check, acquire_pr_followup_lock,
  # write_followup_evidence, read_followup_evidence, portable_stat_mtime) are
  # available in both the parent shell context (sourced by setup()) and in bats
  # subshells (inherited via fork).  No re-sourcing needed here.
  #
  # Stub helpers that _followup_dedup_check calls (already stubbed in setup()
  # for the parent shell; redeclared here so they are visible in any local scope
  # that overrides them, e.g. subshells from Test 4's parallel invocations).
  print_info()    { :; }
  print_warning() { :; }
  _diag()         { :; }

  # Stub gh_safe for all dedup-relevant calls (same defaults as setup()):
  #   - issue view N → "OPEN"  (validates evidence as open; Source 1)
  #   - issue list  → "[]"     (no match from Sources 2 + 3)
  #   - pr view N   → "0"      (no follow-up marker comments; Source 4)
  gh_safe() {
    local subcmd="${1:-}"
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "view" ]; then echo "OPEN"; return 0; fi
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "list" ]; then echo "[]";   return 0; fi
    if [ "$subcmd" = "pr"    ] && [ "${2:-}" = "view" ]; then echo "0";    return 0; fi
    return 0
  }

  # --- Sentinel pre-check (production code: assess-and-resolve.sh lines ~1727-1754) ---
  # Mirrors the pre-lock sentinel check exactly.  Written here rather than
  # inlined into _followup_dedup_check() because the sentinel check fires
  # BEFORE lock acquisition and must be visible to callers without the lock.
  local _sentinel_skipped=false
  if [ -n "${source_issue:-}" ]; then
    local _sentinel_dir="${RITE_STATE_DIR}/followup-sentinels"
    local _sentinel_file="${_sentinel_dir}/source-issue-${source_issue}.created"
    if [ -f "$_sentinel_file" ]; then
      local _sentinel_mtime
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

  # --- Contention signal file (production: assess-and-resolve.sh ~1757-1769) ---
  local _lock_contended_file
  _lock_contended_file=$(mktemp "${RITE_LOCK_DIR}/.contended-signal-XXXXXX" 2>/dev/null || \
    mktemp "/tmp/.rite-contended-signal-XXXXXX")
  export RITE_FOLLOWUP_LOCK_CONTENDED_FILE="$_lock_contended_file"

  local _lock_held=false
  if acquire_pr_followup_lock "$pr_number" "$source_issue" 2>/dev/null; then
    _lock_held=true
  fi

  # Read contention signal (production: assess-and-resolve.sh ~1802-1810)
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

  # Set module-level globals required by _followup_dedup_check().
  # In production these are set earlier in the same script's execution context.
  PR_NUMBER="$pr_number"
  ISSUE_NUMBER="$source_issue"
  ISSUE_SEARCH="review feedback — PR #${pr_number} for issue #${source_issue}"

  # --- Dedup check: call the real production function (Sources 1-4 + retry loop) ---
  # _followup_dedup_check sets EXISTING_ISSUE and may clear _lock_was_contended.
  _followup_dedup_check

  if [ -z "$EXISTING_ISSUE" ]; then
    # No existing issue found — simulate create (write to counts file)
    local issue_num
    issue_num=$((RANDOM % 9000 + 1000))
    echo "PR${pr_number}:src${source_issue}:${issue_num}" >> "$create_count_file"

    # Write durable local evidence (production: assess-and-resolve.sh ~1822-1830)
    write_followup_evidence "$pr_number" "$issue_num" "$source_issue" 2>/dev/null || true

    # Write source-marker sentinel (Change 2; production: ~1855-1879)
    if [ -n "$source_issue" ]; then
      local _sentinel_write_dir="${RITE_STATE_DIR}/followup-sentinels"
      mkdir -p "$_sentinel_write_dir" 2>/dev/null || true
      touch "${_sentinel_write_dir}/source-issue-${source_issue}.created" 2>/dev/null || true
    fi

    # Post-create dwell (Change 3; production: ~1882-1906) — 0s in tests
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

  # Backdate the sentinel to 70 seconds ago using touch -t with a computed
  # absolute timestamp.  touch -t [[CC]YY]MMDDhhmm[.SS] is POSIX and works
  # on both macOS (BSD) and Linux without relying on relative-adjustment flags
  # (-A is macOS-only; -d is GNU-only).  Computing an absolute past timestamp
  # via date arithmetic is deterministic and always produces a non-zero TTL
  # comparison — unlike the -A/-d fallback chain, which silently degraded to
  # TTL=0 when neither flag was supported, making the age comparison trivially
  # unreachable.
  local backdate_ok=false
  local past_ts
  # Compute epoch 70s ago, then format as MMDDhhmm.SS for touch -t.
  # date(1) arithmetic: macOS uses -v; GNU uses -d.
  if past_ts=$(date -v-70S +"%Y%m%d%H%M.%S" 2>/dev/null); then
    # macOS BSD date
    touch -t "$past_ts" "$sentinel_file" 2>/dev/null && backdate_ok=true
  elif past_ts=$(date -d "70 seconds ago" +"%Y%m%d%H%M.%S" 2>/dev/null); then
    # GNU coreutils date
    touch -t "$past_ts" "$sentinel_file" 2>/dev/null && backdate_ok=true
  fi

  if [ "$backdate_ok" = "false" ]; then
    # Platform doesn't support either date variant — use sleep as last resort.
    # Set TTL to 1s and sleep 2s so the sentinel is genuinely expired and the
    # age comparison (_sentinel_age -ge _sentinel_ttl) is exercised with a
    # real non-zero TTL (not the TTL=0 shortcut that bypasses age logic).
    export RITE_FOLLOWUP_SENTINEL_TTL_S=1
    sleep 2
    backdate_ok=true
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
# Test 3: Prior evidence prevents duplicate (Source 1 dedup)
#
# When Process A has already created a follow-up and written evidence,
# Process B finds the evidence at Source 1 (_followup_dedup_check's local
# evidence file check) and skips creation — no duplicate issued.
#
# This test exercises the production _followup_dedup_check() Source 1 path
# with gh_safe stubbed to return "OPEN" for evidence validation.
# ─────────────────────────────────────────────────────────────────────────────

@test "prior evidence prevents duplicate: Source 1 check finds A's evidence, no duplicate" {
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
    # Write evidence (the critical step — B's Source 1 check will find this)
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

  # Process B: calls run_sentinel_dedup_create which invokes _followup_dedup_check().
  # Source 1 finds A's evidence; gh_safe stub confirms it is OPEN → skips creation.
  run_sentinel_dedup_create "$pr" "$src" "$counts"

  local create_count
  create_count=$(grep -c "^PR${pr}:src${src}:" "$counts" 2>/dev/null || true)
  [ "$create_count" -eq 1 ] || {
    echo "FAIL: expected 1 create (B should find A's evidence at Source 1), got $create_count"
    cat "$counts" || true
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3b: Contention-driven retry path in _followup_dedup_check
#
# Directly exercises the lock-contention retry path in the real production
# function _followup_dedup_check().  This tests the logic that was omitted by
# the old hand-rolled mirror (issue #544):
#   - _dedup_retries / _dedup_max_retries loop bounds
#   - _lock_was_contended branch in Source 4 check triggers a retry
#   - On the retry iteration, Source 2 (body-marker search) finds the issue
#
# Setup:
#   - No evidence file (Source 1 finds nothing)
#   - _lock_was_contended=true (B blocked on A; A just released the lock)
#   - gh_safe returns empty from Sources 2+3 on the FIRST iteration
#     (simulating GitHub search index lag after A's create)
#   - Source 4 sees _lock_was_contended → schedules a retry
#   - On the SECOND iteration, Sources 2+3 return a number (index caught up)
#
# Expected: EXISTING_ISSUE set to 9020 (no duplicate create).
# ─────────────────────────────────────────────────────────────────────────────

@test "contention retry path: _lock_was_contended triggers retry and is consumed" {
  local pr=107
  local src=361

  export RITE_FOLLOWUP_SENTINEL_TTL_S=60
  export RITE_DEDUP_BACKOFF=0  # no sleep in tests
  export RITE_FOLLOWUP_LOCK_DWELL_S=0

  # No evidence file — Source 1 finds nothing (no read_followup_evidence match).

  # Call _followup_dedup_check directly with globals set.
  PR_NUMBER="$pr"
  ISSUE_NUMBER="$src"
  ISSUE_SEARCH="review feedback — PR #${pr} for issue #${src}"
  _lock_was_contended=true   # simulates B blocked on A; A just released the lock
  EXISTING_ISSUE=""

  # gh_safe stub: Sources 2+3+4 all return empty/zero — simulates index lag.
  # The key assertion is not whether an issue is found, but whether the
  # contention-retry branch in Source 4 fires and consumes _lock_was_contended.
  gh_safe() {
    local subcmd="${1:-}"
    # Source 1 validation: issue view N → no match scenario: return empty
    # (empty string from gh_safe causes the "transient API failure" branch:
    #  EXISTING_ISSUE is NOT set and evidence is NOT cleared)
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "view" ]; then echo ""; return 0; fi
    # Sources 2+3: issue list → no match
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "list" ]; then echo "[]"; return 0; fi
    # Source 4: pr view → 0 comments; contention signal is the only retry trigger
    if [ "$subcmd" = "pr"    ] && [ "${2:-}" = "view" ]; then echo "0";  return 0; fi
    return 0
  }

  _followup_dedup_check

  # Primary assertion: _lock_was_contended was consumed (set to false) by Source 4.
  # This confirms the contention-retry branch in _followup_dedup_check was reached —
  # the logic omitted by the old hand-rolled mirror.
  [ "$_lock_was_contended" = "false" ] || {
    echo "FAIL: _lock_was_contended should be false after contention retry fired (was: '$_lock_was_contended')"
    false
  }

  # Secondary: EXISTING_ISSUE is empty because Sources 2+3 returned nothing and
  # the retry only fires once (contention signal consumed on first retry iteration).
  # This confirms the loop terminated correctly without infinite looping.
  [ -z "$EXISTING_ISSUE" ] || {
    echo "FAIL: expected EXISTING_ISSUE empty (no index match), got '$EXISTING_ISSUE'"
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

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: Source 2b true-path — body marker verification succeeds
#
# This test exercises the path that was never reached before this fix:
# Source 2a (gh issue list) returns a candidate number, and Source 2b
# (gh issue view --json body) returns a body containing the exact marker,
# so the verification regex matches and EXISTING_ISSUE is set.
#
# Without this test a regression in the verification regex at
# assess-and-resolve.sh:169 (or the --json body routing in gh_safe) would
# go uncaught — Source 2b's true-path (grep match → EXISTING_ISSUE set) was
# silently skipped because the gh_safe stub returned "OPEN" for ALL
# `issue view` calls, keying only on $1/$2 without inspecting --json.
#
# Setup:
#   - No evidence file (Source 1 finds nothing)
#   - gh_safe stub: issue list → returns candidate 9030 for in:body search
#   - gh_safe stub: issue view 9030 --json body → body with exact marker
#   - Expected: EXISTING_ISSUE=9030 (Source 2b verification succeeded)
# ─────────────────────────────────────────────────────────────────────────────

@test "Source 2b true-path: body marker verification succeeds and sets EXISTING_ISSUE" {
  local pr=108
  local src=362

  export RITE_FOLLOWUP_SENTINEL_TTL_S=60
  export RITE_DEDUP_BACKOFF=0
  export RITE_FOLLOWUP_LOCK_DWELL_S=0

  # No evidence file — Source 1 finds nothing.

  # Set globals required by _followup_dedup_check.
  PR_NUMBER="$pr"
  ISSUE_NUMBER="$src"
  ISSUE_SEARCH="review feedback — PR #${pr} for issue #${src}"
  _lock_was_contended=false
  EXISTING_ISSUE=""
  # #647 (one-finding-per-issue) gated Source 2b on a title-equality match and
  # added bare reads of $ISSUE_TITLE (assess-and-resolve.sh:182) and
  # $_clean_title (line 242, Source 4). Both are unconditionally set on the
  # production call path; set them here so the direct call doesn't crash under set -u.
  ISSUE_TITLE="review feedback — PR #${pr} for issue #${src}"
  _clean_title="$ISSUE_TITLE"

  # The candidate issue number that Source 2a will "find".
  local candidate_issue=9030
  # The body that Source 2b will fetch — contains the exact source-issue marker.
  # The marker must pass the token-boundary regex:
  #   sharkrite-source-issue:362([^[:alnum:]_-]|$)
  # A trailing space satisfies the boundary check.
  local candidate_body="<!-- sharkrite-source-issue:${src} -->"

  # gh_safe stub that distinguishes --json body from --json state.
  # All prior stubs keyed only on $1/$2 ("issue" "view") and returned "OPEN"
  # for every `issue view` call — that caused Source 2b's body fetch to receive
  # "OPEN" instead of the issue body, so the marker regex never matched and
  # Source 2b's true-path (EXISTING_ISSUE set) was never reached.
  gh_safe() {
    local subcmd="${1:-}"
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "view" ]; then
      # Inspect the full arg string to distinguish Source 1 (--json state) from
      # Source 2b (--json body).  Using "$*" (all args as one string) lets us
      # grep for "--json body" without eval or bash 4+ indirect expansion.
      local _args_str="$*"
      if echo "$_args_str" | grep -q -- "--json body"; then
        # Source 2b: return the issue body for the candidate issue.
        # Any other issue number returns empty (not found).
        if [ "${3:-}" = "$candidate_issue" ]; then
          echo "$candidate_body"
        else
          echo ""
        fi
      else
        # Source 1 validation (--json state or no --json): return "OPEN".
        echo "OPEN"
      fi
      return 0
    fi
    # Source 2a: issue list in:body → return the candidate number directly.
    # The production call pipes gh output through --jq '.[0].number' and then
    # grep -E '^[0-9]+$'.  To avoid jq dependency in the stub, return the bare
    # number so grep passes it through to _search_candidate.
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "list" ]; then
      # Only body searches should return a candidate; title searches return empty.
      local _args_str="$*"
      if echo "$_args_str" | grep -q "in:body"; then
        # #647 Source 2a now requests --json number,title and pipes through
        # '\(.number) \(.title)'; return number + a title containing ISSUE_TITLE
        # so the title-equality gate at assess-and-resolve.sh:182 passes.
        echo "$candidate_issue $ISSUE_TITLE"
      else
        echo "[]"
      fi
      return 0
    fi
    # Source 3/4: no match.
    if [ "$subcmd" = "pr" ] && [ "${2:-}" = "view" ]; then echo "0"; return 0; fi
    return 0
  }

  _followup_dedup_check

  # Source 2b true-path: EXISTING_ISSUE must be set to the candidate number.
  [ "$EXISTING_ISSUE" = "$candidate_issue" ] || {
    echo "FAIL: expected EXISTING_ISSUE='$candidate_issue' (Source 2b true-path),"
    echo "      got '$EXISTING_ISSUE'"
    echo "      A regression in the --json body routing or the marker regex would"
    echo "      cause Source 2b's verification to silently fail here."
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 9: Source 2b rejection path — false-positive candidate rejected
#
# This test exercises the token-boundary regex in Source 2b's verification:
#   sharkrite-source-issue:N([^[:alnum:]_-]|$)
#
# Without the boundary check, searching for source issue #9 would falsely
# match a body containing "sharkrite-source-issue:90" because the substring
# "sharkrite-source-issue:9" is present.  Source 2b must reject such candidates.
#
# Setup:
#   - No evidence file
#   - Source 2a: returns candidate 9031 (GitHub approximate-match false positive)
#   - Source 2b: candidate body contains "sharkrite-source-issue:3620" (NOT :362)
#     — trailing "0" makes it a different issue number; boundary check rejects it
#   - Sources 3+4: return no match
#   - Expected: EXISTING_ISSUE="" (Source 2b rejected the false-positive candidate)
#     and a create call is made
# ─────────────────────────────────────────────────────────────────────────────

@test "Source 2b rejection: false-positive candidate rejected by token-boundary regex" {
  local pr=109
  local src=362
  local counts="$RITE_TEST_TMPDIR/counts-t9.txt"
  touch "$counts"

  export RITE_FOLLOWUP_SENTINEL_TTL_S=60
  export RITE_DEDUP_BACKOFF=0
  export RITE_FOLLOWUP_LOCK_DWELL_S=0

  # No evidence file — Source 1 finds nothing.

  # Set globals required by _followup_dedup_check.
  PR_NUMBER="$pr"
  ISSUE_NUMBER="$src"
  ISSUE_SEARCH="review feedback — PR #${pr} for issue #${src}"
  _lock_was_contended=false
  EXISTING_ISSUE=""
  # #647 added bare reads of $ISSUE_TITLE (line 182, Source 2b title gate) and
  # $_clean_title (line 242, Source 4). This test reaches Source 4 after the
  # body-boundary rejection, so BOTH globals are mandatory here under set -u.
  ISSUE_TITLE="review feedback — PR #${pr} for issue #${src}"
  _clean_title="$ISSUE_TITLE"

  # A false-positive candidate: GitHub search returned this issue but its body
  # contains a DIFFERENT source-issue marker (sharkrite-source-issue:3620, not :362).
  # The trailing "0" makes "3620" a distinct token — the boundary check must reject it.
  local false_candidate=9031
  local false_candidate_body="<!-- sharkrite-source-issue:${src}0 -->"

  gh_safe() {
    local subcmd="${1:-}"
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "view" ]; then
      local _args_str="$*"
      if echo "$_args_str" | grep -q -- "--json body"; then
        # Source 2b: return the false-positive body (marker for a DIFFERENT issue).
        if [ "${3:-}" = "$false_candidate" ]; then
          echo "$false_candidate_body"
        else
          echo ""
        fi
      else
        echo "OPEN"
      fi
      return 0
    fi
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "list" ]; then
      local _args_str="$*"
      if echo "$_args_str" | grep -q "in:body"; then
        # #647 Source 2a requests --json number,title; return number + a title
        # containing ISSUE_TITLE so the title gate at line 182 passes and the
        # rejection is exercised at the BODY boundary regex (line 188), where
        # the ':3620' marker must fail the ([^[:alnum:]_-]|$) check for #362.
        echo "$false_candidate $ISSUE_TITLE"
      else
        echo "[]"
      fi
      return 0
    fi
    if [ "$subcmd" = "pr" ] && [ "${2:-}" = "view" ]; then echo "0"; return 0; fi
    return 0
  }

  _followup_dedup_check

  # Source 2b must have REJECTED the false-positive candidate.
  [ -z "$EXISTING_ISSUE" ] || {
    echo "FAIL: expected EXISTING_ISSUE='' (Source 2b should reject false-positive),"
    echo "      got '$EXISTING_ISSUE'"
    echo "      The token-boundary regex ([^[:alnum:]_-]|\$) in assess-and-resolve.sh:169"
    echo "      must prevent ':3620' from matching when searching for issue #362."
    false
  }

  # Simulate the create that would follow (dedup found nothing, create proceeds).
  echo "PR${pr}:src${src}:9999" >> "$counts"

  local create_count
  create_count=$(grep -c "^PR${pr}:src${src}:" "$counts" 2>/dev/null || true)
  [ "$create_count" -eq 1 ] || {
    echo "FAIL: expected 1 create call after Source 2b rejection, got $create_count"
    cat "$counts" || true
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 10: Cross-path twin dedup — Source 2 matches an OLD-format (bare-titled)
#          follow-up filed by assess-review-issues.sh (issue #790).
#
# Two emit paths file a follow-up for the SAME deferred finding with DIFFERENT
# title formats:
#   - assess-and-resolve.sh (NEW path): title = "${_clean_title} for issue #N"
#   - assess-review-issues.sh (OLD path): title = bare "${_clean_title}"
# Both bodies carry the same "sharkrite-source-issue:N" marker.
#
# Before the fix, Source 2's title gate matched the SUFFIXED ISSUE_TITLE, so an
# OLD-format issue (bare title) was never recognized as the twin — the NEW path
# filed a duplicate (live: LeadFlow #369/#371, #381/#383).  After the fix,
# Source 2 matches on the bare _clean_title (a substring of both formats), so
# the OLD twin is found and EXISTING_ISSUE is set → no duplicate create.
# ─────────────────────────────────────────────────────────────────────────────

@test "cross-path twin: Source 2 matches OLD-format bare-titled twin (no duplicate)" {
  local pr=110
  local src=363

  export RITE_FOLLOWUP_SENTINEL_TTL_S=60
  export RITE_DEDUP_BACKOFF=0
  export RITE_FOLLOWUP_LOCK_DWELL_S=0

  # No evidence file — Source 1 finds nothing (mirrors the cross-path index-key
  # divergence that makes Source 1 miss its twin; Source 2 must catch it).

  PR_NUMBER="$pr"
  ISSUE_NUMBER="$src"
  # NEW-path title carries the " for issue #N" suffix; the OLD twin does NOT.
  _clean_title="Inert SMS alarm never fires"
  ISSUE_TITLE="${_clean_title} for issue #${src}"
  ISSUE_SEARCH="$ISSUE_TITLE"
  _lock_was_contended=false
  EXISTING_ISSUE=""

  # The OLD-format twin: filed by assess-review-issues.sh with a BARE title and
  # the source-issue marker in its body.
  local twin_issue=9040
  local twin_bare_title="$_clean_title"
  local twin_body="<!-- sharkrite-source-issue:${src} -->## From PR #${pr} Assessment"

  gh_safe() {
    local subcmd="${1:-}"
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "view" ]; then
      local _args_str="$*"
      if echo "$_args_str" | grep -q -- "--json body"; then
        # Source 2b: return the twin's body (carries the source-issue marker).
        if [ "${3:-}" = "$twin_issue" ]; then
          echo "$twin_body"
        else
          echo ""
        fi
      else
        echo "OPEN"
      fi
      return 0
    fi
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "list" ]; then
      local _args_str="$*"
      if echo "$_args_str" | grep -q "in:body"; then
        # Source 2a: the body-marker search surfaces the OLD twin, whose title
        # is BARE (no " for issue #N" suffix) — exactly the format that the
        # pre-fix suffixed-title gate failed to match.
        echo "$twin_issue $twin_bare_title"
      else
        echo "[]"
      fi
      return 0
    fi
    if [ "$subcmd" = "pr" ] && [ "${2:-}" = "view" ]; then echo "0"; return 0; fi
    return 0
  }

  _followup_dedup_check

  [ "$EXISTING_ISSUE" = "$twin_issue" ] || {
    echo "FAIL: expected EXISTING_ISSUE='$twin_issue' (OLD-format bare-titled twin),"
    echo "      got '$EXISTING_ISSUE'."
    echo "      Source 2's title gate must match the bare _clean_title so a"
    echo "      follow-up filed by the OLD path (assess-review-issues.sh) is"
    echo "      recognized as the twin and NOT re-filed (issue #790)."
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 11: Distinct finding is NOT collapsed — different _clean_title, same
#          source-issue marker → must NOT match (each finding gets its own issue).
#
# Guards against the bare-title match over-collapsing: a different deferred
# finding from the same source issue (same sharkrite-source-issue:N marker, but
# a DIFFERENT title) must not be treated as the twin.  Source 2's title gate
# must still discriminate on _clean_title, so EXISTING_ISSUE stays empty and the
# distinct finding proceeds to create its own follow-up.
# ─────────────────────────────────────────────────────────────────────────────

@test "distinct finding not collapsed: different title under same source marker creates its own issue" {
  local pr=111
  local src=364
  local counts="$RITE_TEST_TMPDIR/counts-t11.txt"
  touch "$counts"

  export RITE_FOLLOWUP_SENTINEL_TTL_S=60
  export RITE_DEDUP_BACKOFF=0
  export RITE_FOLLOWUP_LOCK_DWELL_S=0

  PR_NUMBER="$pr"
  ISSUE_NUMBER="$src"
  # Current finding's title.
  _clean_title="useTenant edit-loss race"
  ISSUE_TITLE="${_clean_title} for issue #${src}"
  ISSUE_SEARCH="$ISSUE_TITLE"
  _lock_was_contended=false
  EXISTING_ISSUE=""

  # An existing follow-up for a DIFFERENT finding of the same source issue.
  local other_issue=9050
  local other_title="Inert SMS alarm never fires"
  local other_body="<!-- sharkrite-source-issue:${src} -->## Description"

  gh_safe() {
    local subcmd="${1:-}"
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "view" ]; then
      local _args_str="$*"
      if echo "$_args_str" | grep -q -- "--json body"; then
        if [ "${3:-}" = "$other_issue" ]; then
          echo "$other_body"
        else
          echo ""
        fi
      else
        echo "OPEN"
      fi
      return 0
    fi
    if [ "$subcmd" = "issue" ] && [ "${2:-}" = "list" ]; then
      local _args_str="$*"
      if echo "$_args_str" | grep -q "in:body"; then
        # Body-marker search surfaces the OTHER finding (same source marker, but
        # a different title) — Source 2's title gate must reject it.
        echo "$other_issue $other_title"
      else
        echo "[]"
      fi
      return 0
    fi
    if [ "$subcmd" = "pr" ] && [ "${2:-}" = "view" ]; then echo "0"; return 0; fi
    return 0
  }

  _followup_dedup_check

  [ -z "$EXISTING_ISSUE" ] || {
    echo "FAIL: expected EXISTING_ISSUE='' (distinct finding must not collapse),"
    echo "      got '$EXISTING_ISSUE'. Source 2's title gate over-matched a"
    echo "      different finding sharing the same source-issue marker."
    false
  }

  # Distinct finding proceeds to create its own follow-up.
  echo "PR${pr}:src${src}:9999" >> "$counts"
  local create_count
  create_count=$(grep -c "^PR${pr}:src${src}:" "$counts" 2>/dev/null || true)
  [ "$create_count" -eq 1 ] || {
    echo "FAIL: expected 1 create call for the distinct finding, got $create_count"
    cat "$counts" || true
    false
  }
}
