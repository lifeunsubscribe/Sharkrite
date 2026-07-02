#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/scratchpad-lock.sh, lib/utils/scratchpad-manager.sh
# tests/regression/scratchpad-lock-degrade.bats — lock timeout degrades to skip
#
# Live failure (LeadFlow, 2026-07-01): acquire_scratchpad_lock's `exit 1` on
# timeout killed merge-pr.sh straight through `clear_encountered_issues || true`
# (`|| true` cannot catch `exit` from a same-shell function), converting a
# SUCCESSFULLY merged issue into a batch failure. The holder was a peer batch
# whose update_scratchpad_from_pr held the lock across a gh_safe network fetch
# (retry sleeps push holds past the 30s acquire timeout).
#
# Pins:
#   1. Timeout returns 1 (soft-fail) — a set -euo pipefail caller survives.
#   2. All writers degrade to skip on contention: warn, return 0, file untouched.
#   3. update_scratchpad_from_pr fetches BEFORE acquiring — lock never held
#      across network I/O.
#   4. Soft-fail resets lock state so a later acquire in the same shell works.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export SCRATCHPAD_FILE="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/scratch.md"
  # Force the mkdir strategy so lock state is observable as a directory and
  # the tests behave identically whether or not flock(1) is installed.
  export RITE_SCRATCHPAD_LOCK_STRATEGY=mkdir

  mkdir -p "$RITE_PROJECT_ROOT/$RITE_DATA_DIR"

  cat > "$SCRATCHPAD_FILE" <<'EOF'
# Scratchpad

## Current Work

_No active work — run `rite <issue>` to start_

---

## Encountered Issues (Needs Triage)

_Out-of-scope issues discovered during development._

- **2026-07-01** | `src/existing.ts:1` | code-smell | Existing entry | Affects: x | Fix: y | Done: z

---

## Recent Security Findings (Last 5 PRs)

_Security issues found in recent PR reviews. Sharkrite updates this automatically._

---

## Completed Work Archive

_Last 20 PRs — auto-cleaned_

EOF

  HOLDER_PID=""
}

teardown() {
  if [ -n "${HOLDER_PID:-}" ]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  teardown_test_tmpdir
}

# Hold the lock on behalf of a live process: a background sleep provides a
# PID that passes the kill -0 liveness check, so waiters cannot stale-reclaim
# and must run into their acquire timeout.
hold_lock_with_live_pid() {
  sleep 60 &
  HOLDER_PID=$!
  mkdir "$SCRATCHPAD_FILE.lock"
  echo "$HOLDER_PID" > "$SCRATCHPAD_FILE.lock/pid"
}

# ---------------------------------------------------------------------------
# Test 1: timeout returns 1 — does not exit the caller
#
# The old code called `exit 1` on timeout, which terminates a same-shell
# caller even at a `func || true` call site. The subshell below runs under
# set -euo pipefail exactly like merge-pr.sh; if acquire still exits instead
# of returning, "SURVIVED" never prints and the test fails.
# ---------------------------------------------------------------------------
@test "acquire timeout returns 1 - set -euo pipefail caller survives" {
  hold_lock_with_live_pid

  run env RITE_SCRATCHPAD_LOCK_TIMEOUT=2 "${BASH}" -c '
    set -euo pipefail
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    rc=0
    acquire_scratchpad_lock || rc=$?
    echo "rc=$rc"
    echo "SURVIVED"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"SURVIVED"* ]]
  # The message must name the skip semantics (warning, not a hard error)
  [[ "$output" == *"skip this advisory write"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: writers degrade to skip — return 0, warn, leave the file untouched
# ---------------------------------------------------------------------------
@test "writers degrade to skip on lock contention - return 0 and file unchanged" {
  hold_lock_with_live_pid
  cp "$SCRATCHPAD_FILE" "$RITE_TEST_TMPDIR/scratch.before"

  # gh_safe is stubbed BEFORE sourcing the manager so gh-retry.sh is skipped
  # and update_scratchpad_from_pr gets a non-empty review (reaches the lock).
  run env RITE_SCRATCHPAD_LOCK_TIMEOUT=2 "${BASH}" -c '
    set -euo pipefail
    gh_safe() { echo "stub review body"; }
    source "$RITE_LIB_DIR/utils/scratchpad-manager.sh"
    update_scratchpad_from_pr 123 "Test PR"
    clear_encountered_issues
    echo "WRITERS_DONE"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"WRITERS_DONE"* ]]
  [[ "$output" == *"skipping PR #123 findings update"* ]]
  [[ "$output" == *"skipping Encountered Issues clear"* ]]
  cmp -s "$SCRATCHPAD_FILE" "$RITE_TEST_TMPDIR/scratch.before" || {
    echo "FAIL: scratchpad was modified despite lock contention" >&2
    diff "$RITE_TEST_TMPDIR/scratch.before" "$SCRATCHPAD_FILE" >&2 || true
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 3: no network under lock — behavioral pin of fetch-before-acquire
#
# The writer's gh_safe stub sleeps 3s (simulated slow fetch). While it
# sleeps, the lock must be FREE: a probe acquire with a 1s timeout must
# succeed at t=1s. Under the old acquire-then-fetch ordering the probe
# times out and the test fails.
# ---------------------------------------------------------------------------
@test "update_scratchpad_from_pr fetches review before acquiring lock" {
  "${BASH}" -c '
    set -euo pipefail
    gh_safe() { sleep 3; echo "review body"; }
    source "$RITE_LIB_DIR/utils/scratchpad-manager.sh"
    update_scratchpad_from_pr 321 "Ordering PR"
  ' &
  local writer_pid=$!

  sleep 1

  local probe_rc=0
  env RITE_SCRATCHPAD_LOCK_TIMEOUT=1 "${BASH}" -c '
    set -euo pipefail
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    acquire_scratchpad_lock
    release_scratchpad_lock
  ' || probe_rc=$?

  wait "$writer_pid" || true

  [ "$probe_rc" -eq 0 ] || {
    echo "FAIL: lock was held during the network fetch (probe acquire failed)" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 4: soft-fail resets lock state — a later acquire in the same shell works
# ---------------------------------------------------------------------------
@test "timed-out acquire resets state - subsequent acquire succeeds" {
  hold_lock_with_live_pid

  run env RITE_SCRATCHPAD_LOCK_TIMEOUT=2 "${BASH}" -c '
    set -euo pipefail
    source "$RITE_LIB_DIR/utils/scratchpad-lock.sh"
    rc=0
    acquire_scratchpad_lock || rc=$?
    [ "$rc" -eq 1 ] || { echo "FAIL: expected rc=1, got $rc" >&2; exit 1; }
    [ "$_SCRATCHPAD_LOCK_HELD" = "false" ] || { echo "FAIL: HELD not reset" >&2; exit 1; }
    [ "$_SCRATCHPAD_LOCK_DEPTH" -eq 0 ] || { echo "FAIL: DEPTH not reset" >&2; exit 1; }
    # Free the lock (holder is a plain sleep; the dir was hand-made by the test)
    rm -rf "$SCRATCHPAD_FILE.lock"
    acquire_scratchpad_lock
    [ "$_SCRATCHPAD_LOCK_HELD" = "true" ] || { echo "FAIL: re-acquire did not set HELD" >&2; exit 1; }
    release_scratchpad_lock
    echo "STATE_OK"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"STATE_OK"* ]]
}
