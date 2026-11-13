#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/timeout.sh::run_with_timeout|_rite_list_descendants
# sharkrite-gate-serial — process-tree/timing test
#
# run_with_timeout must not leave the command's descendants alive after the
# command itself has exited. gtimeout kills only its direct child; a grandchild
# holding the stdout pipe kept `| tee` waiting for 99 minutes past a 540s fix
# timeout (freshup #551, 2026-11-12). The sweep tracks descendants while the
# command lives and kills survivors afterwards.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "${RITE_LIB_DIR}/utils/timeout.sh"
  set +u; set +o pipefail
  ensure_timeout_cmd
  if [ -z "${RITE_TIMEOUT_CMD:-}" ]; then
    skip "No timeout command available (install coreutils)"
  fi
  MARK="${BATS_TEST_TMPDIR}/marker-$$"
}

@test "timeout kills the command AND its orphaned grandchild; the pipe closes promptly" {
  # The command spawns a background grandchild that holds stdout for 60s, then hangs.
  local _start _elapsed _rc=0
  _start=$(date +%s)
  run_with_timeout 2 bash -c "sleep 60 & echo \$! > '$MARK'; sleep 60" | cat >/dev/null
  _rc=${PIPESTATUS[0]}
  _elapsed=$(( $(date +%s) - _start ))
  [ "$_rc" -eq 124 ]
  # Without the sweep the pipeline waits for the 60s grandchild; with it, seconds.
  [ "$_elapsed" -lt 20 ]
  local _gc; _gc=$(cat "$MARK")
  sleep 1.5
  ! kill -0 "$_gc" 2>/dev/null
}

@test "normal exit with a leaked background child: child is swept, exit code preserved" {
  local _rc=0
  run_with_timeout 30 bash -c "sleep 60 & echo \$! > '$MARK'; exit 3" | cat >/dev/null
  _rc=${PIPESTATUS[0]}
  [ "$_rc" -eq 3 ]
  local _gc; _gc=$(cat "$MARK")
  sleep 1.5
  ! kill -0 "$_gc" 2>/dev/null
}

@test "fast command returns its exit code and stdout unchanged" {
  local _out
  _out=$(run_with_timeout 10 bash -c 'echo hello; exit 0')
  [ "$_out" = "hello" ]
  run run_with_timeout 10 bash -c 'exit 7'
  [ "$status" -eq 7 ]
}
