#!/usr/bin/env bats
# sharkrite-test-covers: tests/concurrency/*.bats
# Structural guard for issue #1690.
#
# A bare `wait` in a test that spawns workers waits for EVERY child of the test
# shell. When BATS_TEST_TIMEOUT is set (the gate sets 120 s, the nightly 300 s),
# bats keeps a watchdog child in that shell, so the bare `wait` blocks on the
# watchdog until the timeout fires and the test is killed — a test that passes
# in 300 ms plainly "hangs" for exactly the timeout. Live: #1552's gate reported
# two session-state-per-batch tests as `[timeout: 120s]` after #1659 routed the
# concurrency files into the serial lane. The fix is to collect `$!` after each
# spawn and `wait` on that list; this test keeps the bare form from returning.

setup() {
  CONCURRENCY_DIR="$(cd "${BATS_TEST_DIRNAME}/../concurrency" && pwd)"
}

@test "no bare wait in tests/concurrency/*.bats" {
  # Positive control: the sweep must actually look at files.
  local count
  count=$(find "$CONCURRENCY_DIR" -name '*.bats' | wc -l | tr -d ' ')
  [ "$count" -gt 0 ]

  local hits
  hits=$(grep -nE '^[[:space:]]*wait[[:space:]]*(#.*)?$' "$CONCURRENCY_DIR"/*.bats || true)
  if [ -n "$hits" ]; then
    echo "bare wait found (collect \$! after each spawn and wait on the PID list):" >&2
    echo "$hits" >&2
    return 1
  fi
}

@test "the sweep pattern catches a bare wait and ignores a PID-list wait" {
  local fixture="${BATS_TEST_TMPDIR}/fixture.bats"
  printf '%s\n' '  wait' '  wait "${_pids[@]+"${_pids[@]}"}" || true' '  wait $pid' '  wait  # trailing comment' > "$fixture"
  local n
  n=$(grep -cE '^[[:space:]]*wait[[:space:]]*(#.*)?$' "$fixture" || true)
  [ "$n" -eq 2 ]
}
