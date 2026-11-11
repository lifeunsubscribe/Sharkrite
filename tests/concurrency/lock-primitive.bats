#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/lock.sh
# sharkrite-gate-serial — spawns competing processes; under the full suite's parallel group these starve past BATS_TEST_TIMEOUT (false red main, #916 preflight)
# Correctness tests for the shared atomic lock primitive (issue #706):
#   - mutual exclusion under distinct-PID contention (zero lost increments — the
#     regression the old mkdir-fallback lost under heavy load),
#   - crash recovery (a SIGKILL'd holder's stale lock is reclaimed),
#   - basic acquire / release / held-pid semantics.
#
# Most tests use distinct-PID (separate `bash -c`) processes: subshells share $$,
# which would defeat the PID-based liveness/identity the primitive relies on. One
# test deliberately uses subshells to verify the BASHPID fix (issue #1597): before
# the fix, subshells' shared $$ caused live-lock steals; after, BASHPID gives each
# subshell a unique PID so the primitive's self-ownership check behaves correctly.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  LOCKDIR=$(mktemp -d); export LOCKDIR
  LIB="${RITE_LIB_DIR}/utils/lock.sh"; export LIB
}

teardown() { rm -rf "${LOCKDIR:-}"; }

@test "lock_acquire creates the lock; lock_release removes it" {
  run bash -c '
    source "$LIB"
    lock_acquire "$LOCKDIR/a.lock" 5 || exit 1
    [ -e "$LOCKDIR/a.lock" ] || exit 2
    lock_release "$LOCKDIR/a.lock"
    [ -e "$LOCKDIR/a.lock" ] && exit 3
    exit 0
  '
  [ "$status" -eq 0 ]
}

@test "lock_held_pid reports the live holder, nothing once released" {
  run bash -c '
    source "$LIB"
    lock_acquire "$LOCKDIR/h.lock" 5 || exit 1
    [ "$(lock_held_pid "$LOCKDIR/h.lock")" = "$$" ] || exit 2
    lock_release "$LOCKDIR/h.lock"
    [ -n "$(lock_held_pid "$LOCKDIR/h.lock")" ] && exit 3
    exit 0
  '
  [ "$status" -eq 0 ]
}

@test "mutual exclusion: 30 distinct-PID processes, zero lost increments" {
  local lock="$LOCKDIR/m.lock" counter="$LOCKDIR/counter"
  echo 0 > "$counter"
  local i pids=()
  for i in $(seq 1 30); do
    LIB="$LIB" LK="$lock" CT="$counter" bash -c '
      source "$LIB"
      lock_acquire "$LK" 30 || exit 7
      c=$(cat "$CT"); sleep 0.002; echo $((c + 1)) > "$CT"   # widened critical section
      lock_release "$LK"
    ' &
    pids+=($!)
  done
  local p
  for p in "${pids[@]}"; do wait "$p" || true; done
  # A correct mutex serializes all 30 read-modify-writes: exactly 30, none lost.
  [ "$(cat "$counter")" -eq 30 ]
}

@test "subshell contention: BASHPID tokens are distinct, not shared \$\$" {
  # Regresses the $$ → BASHPID fix (issue #1597). In ( ) & subshells, $$ equals
  # the parent PID for all workers; the "is this my own lock?" check in
  # lock_acquire would fire for every waiter — allowing live-lock steals and lost
  # increments. BASHPID is the actual subprocess PID, unique per subshell.
  # Runs only on bash 4+ where BASHPID differs from $$ in subshells; on bash 3.2
  # the ${BASHPID:-$$} fallback gives the same behaviour as the pre-fix code and
  # cannot distinguish subshell PIDs — skip rather than produce a false red.
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    skip "BASHPID requires bash 4+; \$\$ fallback on bash 3.2 cannot distinguish subshell PIDs"
  fi
  local lock="$LOCKDIR/sub.lock" counter="$LOCKDIR/counter"
  echo 0 > "$counter"
  local i _pids=()
  for i in $(seq 1 10); do
    (
      source "$LIB"
      lock_acquire "$lock" 15 || exit 7
      c=$(cat "$counter"); sleep 0.002; echo $((c + 1)) > "$counter"
      lock_release "$lock"
    ) &
    _pids+=($!)
  done
  wait "${_pids[@]+"${_pids[@]}"}" || true
  [ "$(cat "$counter")" -eq 10 ]
}

@test "crash recovery: a SIGKILL'd holder's stale lock is reclaimed" {
  local lock="$LOCKDIR/c.lock"
  LIB="$LIB" LK="$lock" RDY="$LOCKDIR/ready" bash -c '
    source "$LIB"; lock_acquire "$LK" 10 && { : > "$RDY"; exec sleep 300; }
  ' &
  local holder=$!
  local i
  for i in $(seq 1 50); do [ -f "$LOCKDIR/ready" ] && break; sleep 0.1; done
  kill -9 "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  # The next acquirer must reclaim the stale lock the dead holder left behind.
  run bash -c '
    source "$LIB"
    lock_acquire "'"$lock"'" 15 || exit 1
    lock_release "'"$lock"'"
    exit 0
  '
  [ "$status" -eq 0 ]
}
