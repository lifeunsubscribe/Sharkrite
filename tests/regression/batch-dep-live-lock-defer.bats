#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh, lib/utils/issue-lock.sh
# tests/regression/batch-dep-live-lock-defer.bats
#
# Regression test: when an open dep issue holds a live issue-lock in another
# concurrent batch session, the dependent issue should defer to the end of the
# queue (bounded by the existing _DEFER_COUNT anti-cycle cap) rather than
# skipping immediately with dep_failed.
#
# Live-lock liveness check: RITE_LOCK_DIR/issue-N.lock/pid exists +
# kill -0 succeeds + pid != $$ (not our own session).
#
# Tests in this file:
#   BEHAVIORAL (live-lock defer logic):
#    1. Dep open + live lock held by another PID → deferred (not skipped)
#    2. Dep open + no lock file → skip (existing behavior unchanged)
#    3. Dep open + stale lock (dead PID) → skip (existing behavior unchanged)
#    4. Cap exhausted + live lock → skip (cap overrides live-lock defer)
#    5. Dep open + live lock is our own PID → skip (not a foreign session)
#
#   STRUCTURAL (invariants in the batch source file):
#    6. _DEP_LIVE_LOCK variable initialized alongside other DEP_ vars
#    7. Live-lock check references RITE_LOCK_DIR/issue-${dep_num}.lock/pid
#    8. Live-lock defer sets DEP_IN_QUEUE=true and _DEP_LIVE_LOCK=true
#    9. Live-lock path uses the same _DEFER_COUNT cap as queue-later path

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"

# =============================================================================
# Helper: build a minimal script that exercises the open-dep decision block
# with a configurable lock directory, simulating live-lock and no-lock cases.
#
# Args (positional):
#   $1  LOCK_DIR      path for RITE_LOCK_DIR
#   $2  (unused — reserved for future expansion)
#   $3  (unused — reserved for future expansion)
#   $4  DEFER_COUNT   pre-existing defer count for ISSUE_NUM (default 0)
#   $5  UNIQUE_COUNT  _UNIQUE_ISSUE_COUNT value (default 3)
# =============================================================================
_build_live_lock_script() {
  local _script="$BATS_TEST_TMPDIR/test-live-lock-defer.sh"

  # Extract _check_dep_queued_later from the batch file
  local _fn_body
  _fn_body=$(awk '
    /_check_dep_queued_later[(][)]/ { in_fn=1 }
    in_fn { print }
    in_fn && /^}$/ { exit }
  ' "$BATCH_PROCESSOR" || true)

  cat > "$_script" <<SCRIPT_EOF
#!/usr/bin/env bash
set -euo pipefail

RITE_LOCK_DIR="${1:-$BATS_TEST_TMPDIR/locks}"

${_fn_body}

declare -A ISSUE_STATUS
declare -A _DEFER_COUNT
_UNIQUE_ISSUE_COUNT="${5:-3}"
_DEFER_COUNT[2]="${4:-0}"
ISSUE_LIST=(2 3 4)   # dep #1 is NOT later in queue (forces live-lock path)
_batch_qi=1

ISSUE_NUM=2
DEP_FAILED=false
DEP_IN_QUEUE=false
DEP_IN_QUEUE_NUM=""
_DEP_LIVE_LOCK=false

dep_issue_state="OPEN"
if [ "\$dep_issue_state" = "OPEN" ]; then
  _check_dep_queued_later 1 "\$ISSUE_NUM" "\$_batch_qi"
  # Live-lock check (mirrors batch-process-issues.sh logic)
  if [ "\$DEP_IN_QUEUE" = false ]; then
    _live_lock_defer_count="\${_DEFER_COUNT[\$ISSUE_NUM]:-0}"
    _live_lock_max="\${_UNIQUE_ISSUE_COUNT:-\${#ISSUE_LIST[@]}}"
    if [ "\$_live_lock_defer_count" -lt "\$_live_lock_max" ]; then
      _dep_pid_file="\${RITE_LOCK_DIR}/issue-1.lock/pid"
      if [ -f "\$_dep_pid_file" ]; then
        _dep_lock_pid=\$(cat "\$_dep_pid_file" 2>/dev/null || true)
        if [ -n "\$_dep_lock_pid" ] && [ "\$_dep_lock_pid" != "\$\$" ] && kill -0 "\$_dep_lock_pid" 2>/dev/null; then
          DEP_IN_QUEUE=true
          DEP_IN_QUEUE_NUM=1
          _DEP_LIVE_LOCK=true
        fi
      fi
    fi
  fi
  if [ "\$DEP_IN_QUEUE" = false ]; then
    DEP_FAILED=true
  fi
fi

if [ "\$DEP_IN_QUEUE" = true ]; then
  _DEFER_COUNT[\$ISSUE_NUM]=\$(( \${_DEFER_COUNT[\$ISSUE_NUM]:-0} + 1 ))
  if [ "\${_DEP_LIVE_LOCK:-false}" = true ]; then
    echo "LIVE_LOCK_DEFERRED: issue \$ISSUE_NUM (defer #\${_DEFER_COUNT[\$ISSUE_NUM]})"
  else
    echo "QUEUE_DEFERRED: issue \$ISSUE_NUM"
  fi
  ISSUE_LIST+=("\$ISSUE_NUM")
  ISSUE_STATUS["\$ISSUE_NUM"]="deferred_for_dep"
  echo "STATUS:deferred_for_dep"
elif [ "\$DEP_FAILED" = true ]; then
  echo "SKIPPED: issue \$ISSUE_NUM (dep_failed)"
  ISSUE_STATUS["\$ISSUE_NUM"]="dep_failed"
  echo "STATUS:dep_failed"
else
  echo "PROCEEDED: issue \$ISSUE_NUM"
fi
SCRIPT_EOF
  chmod +x "$_script"
  echo "$_script"
}

teardown() {
  # Kill any background sleep spawned as a foreign session holder
  kill "${_foreign_pid:-}" 2>/dev/null || true
}

# =============================================================================
# BEHAVIORAL
# =============================================================================

@test "behavioral: dep open + live lock held by another PID → deferred (not skipped)" {
  # Set up a fake lock dir with a live PID (use a background sleep as the holder)
  _lock_dir="$BATS_TEST_TMPDIR/locks-live"
  mkdir -p "$_lock_dir/issue-1.lock"
  # Start a background sleep as the foreign session holder; close fd 3 so an
  # early assertion failure doesn't let the orphan stall bats' output stream.
  sleep 60 3>&- &
  _foreign_pid=$!
  echo "$_foreign_pid" > "$_lock_dir/issue-1.lock/pid"

  _script=$(_build_live_lock_script "$_lock_dir")
  run bash "$_script"

  # Clean up the background sleep
  kill "$_foreign_pid" 2>/dev/null || true

  [ "$status" -eq 0 ] || {
    echo "Script failed with status $status: $output" >&2
    return 1
  }
  echo "$output" | grep -q "LIVE_LOCK_DEFERRED: issue 2" || {
    echo "FAIL: issue #2 should be LIVE_LOCK_DEFERRED when dep #1 holds a live lock" >&2
    echo "Output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "SKIPPED" || {
    echo "FAIL: issue #2 must NOT be skipped when dep has a live lock" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "STATUS:deferred_for_dep" || {
    echo "FAIL: ISSUE_STATUS must be 'deferred_for_dep' for live-lock deferred issue" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: dep open + no lock file → skip (existing behavior unchanged)" {
  # No lock dir or pid file — should skip with dep_failed
  _lock_dir="$BATS_TEST_TMPDIR/locks-empty"
  mkdir -p "$_lock_dir"

  _script=$(_build_live_lock_script "$_lock_dir")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed with status $status: $output" >&2
    return 1
  }
  echo "$output" | grep -q "SKIPPED: issue 2" || {
    echo "FAIL: issue #2 should be SKIPPED when dep has no lock file" >&2
    echo "Output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "DEFERRED" || {
    echo "FAIL: issue #2 must NOT be deferred when dep has no lock" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: dep open + stale lock (dead PID) → skip (existing behavior unchanged)" {
  # Write a pid file with a dead PID — kill -0 should fail → no deferral
  _lock_dir="$BATS_TEST_TMPDIR/locks-stale"
  mkdir -p "$_lock_dir/issue-1.lock"
  # PID 99999 is almost certainly not running (and if it is, kill -0 won't hurt it)
  # Use a PID that is definitely not alive: start/kill a process and use that PID
  sleep 1 &
  _dead_pid=$!
  wait "$_dead_pid" 2>/dev/null || true
  echo "$_dead_pid" > "$_lock_dir/issue-1.lock/pid"

  _script=$(_build_live_lock_script "$_lock_dir")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed with status $status: $output" >&2
    return 1
  }
  echo "$output" | grep -q "SKIPPED: issue 2" || {
    echo "FAIL: issue #2 should be SKIPPED when dep's lock PID is dead" >&2
    echo "Output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "LIVE_LOCK_DEFERRED" || {
    echo "FAIL: dead-PID lock must NOT trigger live-lock deferral" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: cap exhausted + live lock → skip (cap overrides live-lock defer)" {
  # When _DEFER_COUNT[ISSUE_NUM] >= _UNIQUE_ISSUE_COUNT, the live-lock check
  # must not fire — the cap is the hard termination point for all defer paths.
  _lock_dir="$BATS_TEST_TMPDIR/locks-cap"
  mkdir -p "$_lock_dir/issue-1.lock"
  sleep 60 3>&- &
  _foreign_pid=$!
  echo "$_foreign_pid" > "$_lock_dir/issue-1.lock/pid"

  # DEFER_COUNT=3 >= UNIQUE_COUNT=3 → cap exhausted
  _script=$(_build_live_lock_script "$_lock_dir" "" "" "3" "3")
  run bash "$_script"

  kill "$_foreign_pid" 2>/dev/null || true

  [ "$status" -eq 0 ] || {
    echo "Script failed with status $status: $output" >&2
    return 1
  }
  echo "$output" | grep -q "SKIPPED: issue 2" || {
    echo "FAIL: issue #2 should be SKIPPED when defer cap is exhausted (even with live lock)" >&2
    echo "      Cap prevents infinite deferral when the foreign session stalls" >&2
    echo "Output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "DEFERRED" || {
    echo "FAIL: issue must NOT be deferred when cap is exhausted" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: dep live lock is our own PID → skip (not a foreign session)" {
  # kill -0 $$ always succeeds; the guard $pid != $$ prevents self-deferral.
  # This matters if this batch process somehow holds the dep lock itself.
  _lock_dir="$BATS_TEST_TMPDIR/locks-self"
  mkdir -p "$_lock_dir/issue-1.lock"
  # The script writes its own $$ into the lock at startup, so the pid != $$
  # guard rejects it. We build a self-contained script rather than using
  # _build_live_lock_script, because the latter's $$ (test shell) differs from
  # the spawned script's $$.
  _self_pid_script="$BATS_TEST_TMPDIR/test-self-pid.sh"
  cat > "$_self_pid_script" <<SELF_EOF
#!/usr/bin/env bash
set -euo pipefail
RITE_LOCK_DIR="$_lock_dir"
# Overwrite lock with our own PID (simulates our session holding the dep lock)
echo \$\$ > "\$RITE_LOCK_DIR/issue-1.lock/pid"

$(awk '
  /_check_dep_queued_later[(][)]/ { in_fn=1 }
  in_fn { print }
  in_fn && /^}$/ { exit }
' "$BATCH_PROCESSOR")

declare -A ISSUE_STATUS
declare -A _DEFER_COUNT
_UNIQUE_ISSUE_COUNT=3
ISSUE_LIST=(2 3 4)
_batch_qi=1
ISSUE_NUM=2
DEP_FAILED=false
DEP_IN_QUEUE=false
DEP_IN_QUEUE_NUM=""
_DEP_LIVE_LOCK=false

dep_issue_state="OPEN"
if [ "\$dep_issue_state" = "OPEN" ]; then
  _check_dep_queued_later 1 "\$ISSUE_NUM" "\$_batch_qi"
  if [ "\$DEP_IN_QUEUE" = false ]; then
    _live_lock_defer_count="\${_DEFER_COUNT[\$ISSUE_NUM]:-0}"
    _live_lock_max="\${_UNIQUE_ISSUE_COUNT:-\${#ISSUE_LIST[@]}}"
    if [ "\$_live_lock_defer_count" -lt "\$_live_lock_max" ]; then
      _dep_pid_file="\${RITE_LOCK_DIR}/issue-1.lock/pid"
      if [ -f "\$_dep_pid_file" ]; then
        _dep_lock_pid=\$(cat "\$_dep_pid_file" 2>/dev/null || true)
        if [ -n "\$_dep_lock_pid" ] && [ "\$_dep_lock_pid" != "\$\$" ] && kill -0 "\$_dep_lock_pid" 2>/dev/null; then
          DEP_IN_QUEUE=true
          _DEP_LIVE_LOCK=true
        fi
      fi
    fi
  fi
  [ "\$DEP_IN_QUEUE" = false ] && DEP_FAILED=true
fi

if [ "\$DEP_IN_QUEUE" = true ]; then
  echo "LIVE_LOCK_DEFERRED: issue \$ISSUE_NUM"
elif [ "\$DEP_FAILED" = true ]; then
  echo "SKIPPED: issue \$ISSUE_NUM (self-held lock)"
fi
SELF_EOF
  chmod +x "$_self_pid_script"
  run bash "$_self_pid_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed with status $status: $output" >&2
    return 1
  }
  echo "$output" | grep -q "SKIPPED: issue 2" || {
    echo "FAIL: issue #2 should be SKIPPED when lock pid == script's own \$\$" >&2
    echo "      Self-held lock must not trigger live-lock deferral" >&2
    echo "Output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "LIVE_LOCK_DEFERRED" || {
    echo "FAIL: self-held lock must NOT trigger live-lock deferral" >&2
    echo "Output: $output" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL
# =============================================================================

@test "structural: _DEP_LIVE_LOCK=false initialized alongside other DEP_ vars" {
  # The live-lock flag must be reset each iteration so a prior iteration's true
  # value does not bleed into the next issue's dep check.
  grep -q '_DEP_LIVE_LOCK=false' "$BATCH_PROCESSOR" || {
    echo "FAIL: '_DEP_LIVE_LOCK=false' initialization not found in $BATCH_PROCESSOR" >&2
    return 1
  }
}

@test "structural: live-lock check references RITE_LOCK_DIR/issue-\${dep_num}.lock/pid" {
  grep -q 'RITE_LOCK_DIR.*issue-.*lock/pid\|issue-.*dep_num.*lock/pid' "$BATCH_PROCESSOR" || {
    grep -q '_dep_pid_file.*RITE_LOCK_DIR' "$BATCH_PROCESSOR" || {
      echo "FAIL: live-lock pid file path using RITE_LOCK_DIR not found in $BATCH_PROCESSOR" >&2
      return 1
    }
  }
}

@test "structural: live-lock defer sets DEP_IN_QUEUE=true and _DEP_LIVE_LOCK=true" {
  grep -q '_DEP_LIVE_LOCK=true' "$BATCH_PROCESSOR" || {
    echo "FAIL: '_DEP_LIVE_LOCK=true' assignment not found — live-lock path missing" >&2
    return 1
  }
}

@test "structural: live-lock path uses same _DEFER_COUNT cap as queue-later path" {
  # Both defer paths must check the same cap vars: _live_lock_defer_count from
  # _DEFER_COUNT and _live_lock_max from _UNIQUE_ISSUE_COUNT.
  grep -q '_live_lock_defer_count\|_live_lock_max' "$BATCH_PROCESSOR" || {
    echo "FAIL: live-lock cap variables not found in $BATCH_PROCESSOR" >&2
    echo "      The cap must reuse _DEFER_COUNT / _UNIQUE_ISSUE_COUNT to prevent infinite deferral" >&2
    return 1
  }
}

@test "structural: live-lock path reads RITE_LIVE_LOCK_DEFER_WAIT for the wait duration" {
  # The live-lock defer must sleep for RITE_LIVE_LOCK_DEFER_WAIT seconds
  # (default 30) after re-queuing. Without this wait, small batches exhaust
  # all defer slots immediately — the re-appended issue is reached in the next
  # iteration with no wall-clock buffer for the foreign session to progress.
  grep -q 'RITE_LIVE_LOCK_DEFER_WAIT' "$BATCH_PROCESSOR" || {
    echo "FAIL: RITE_LIVE_LOCK_DEFER_WAIT not referenced in $BATCH_PROCESSOR" >&2
    echo "      The live-lock defer path must sleep to buffer small-batch re-queues" >&2
    return 1
  }
}

@test "structural: live-lock defer path contains a sleep call" {
  # The live-lock branch (guarded by _DEP_LIVE_LOCK=true) must contain a sleep
  # call. The queue-later branch omits it (natural issue-processing time provides
  # the buffer there). This structural check prevents the sleep from being silently
  # removed in a future refactor, which would restore the silent no-op in small batches.
  awk '/_DEP_LIVE_LOCK.*true/{found=1} found && /^[[:space:]]*sleep[[:space:]]/{print; exit} found && /ISSUE_LIST.*\+.*ISSUE_NUM/{exit}' \
    "$BATCH_PROCESSOR" | grep -qE '^[[:space:]]*sleep[[:space:]]' || {
    echo "FAIL: no sleep call found in the _DEP_LIVE_LOCK=true branch in $BATCH_PROCESSOR" >&2
    echo "      Removing the sleep restores the silent no-op in small batches (issue #1220)" >&2
    return 1
  }
}
