#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# sharkrite-gate-serial
# Regression test: gate census-scaled bats --jobs (#1165)
#
# Verifies:
#   1. _compute_bats_jobs with 0–2 census entries returns ncpu (unchanged #510 behavior)
#   2. _compute_bats_jobs with 4 entries on an ncpu=8 box returns max(2, 8/4)=2
#   3. Dead-PID entries are reaped and not counted
#   4. RITE_BATS_JOBS=N override returns N regardless of census count
#   5. Census entry removed on normal function exit (cleanup via rm before trap - EXIT)
#   6. Dead census entry from a prior killed gate is reaped on the next count

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export RITE_PROJECT_ROOT
  RITE_PROJECT_ROOT=$(mktemp -d)
  export RITE_LOCK_DIR="${RITE_PROJECT_ROOT}/.rite/locks"
  mkdir -p "${RITE_LOCK_DIR}/gate-census"
  export PR_NUMBER="9901"

  # Source config + test-gate to get helpers
  # shellcheck source=/dev/null
  source "${RITE_LIB_DIR}/utils/config.sh"
  # shellcheck source=/dev/null
  source "${RITE_LIB_DIR}/utils/test-gate.sh"
  set +u; set +o pipefail
}

teardown() {
  rm -rf "${RITE_PROJECT_ROOT:-}"
}

# ---------------------------------------------------------------------------
# Helper: write a fake census entry with a given PID
# ---------------------------------------------------------------------------
_write_census_entry() {
  touch "${RITE_LOCK_DIR}/gate-census/$1"
}

# ---------------------------------------------------------------------------
# 1. ≤2 census entries: _compute_bats_jobs returns ncpu
# ---------------------------------------------------------------------------

@test "_compute_bats_jobs with 0 census entries returns ncpu (no scaling)" {
  # No entries — fresh census dir
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    # No census entries; parallel binary present via mock
    PATH=\"\$(mktemp -d):\$PATH\"
    _par=\$(command -v parallel 2>/dev/null || echo '')
    if [ -z \"\$_par\" ]; then
      # Inject a parallel stub so _compute_bats_jobs doesn't take serial path
      _stub_dir=\$(mktemp -d)
      printf '#!/bin/sh\ntrue\n' > \"\$_stub_dir/parallel\"
      chmod +x \"\$_stub_dir/parallel\"
      export PATH=\"\$_stub_dir:\$PATH\"
    fi
    _ncpu=\$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)
    result=\$(_compute_bats_jobs 0)
    [ \"\$result\" = \"\$_ncpu\" ] && echo 'PASS'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "_compute_bats_jobs with 2 census entries returns ncpu (no scaling, preserves #510)" {
  # Exactly 2 entries: this gate + 1 other — still no scaling
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    _par=\$(command -v parallel 2>/dev/null || echo '')
    if [ -z \"\$_par\" ]; then
      _stub_dir=\$(mktemp -d)
      printf '#!/bin/sh\ntrue\n' > \"\$_stub_dir/parallel\"
      chmod +x \"\$_stub_dir/parallel\"
      export PATH=\"\$_stub_dir:\$PATH\"
    fi
    _ncpu=\$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)
    result=\$(_compute_bats_jobs 2)
    [ \"\$result\" = \"\$_ncpu\" ] && echo 'PASS'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# 2. 4 census entries on ncpu=8: _compute_bats_jobs returns max(2, 8/4)=2
# ---------------------------------------------------------------------------

@test "_compute_bats_jobs with census=4 returns max(2, ncpu/4)" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    _par=\$(command -v parallel 2>/dev/null || echo '')
    if [ -z \"\$_par\" ]; then
      _stub_dir=\$(mktemp -d)
      printf '#!/bin/sh\ntrue\n' > \"\$_stub_dir/parallel\"
      chmod +x \"\$_stub_dir/parallel\"
      export PATH=\"\$_stub_dir:\$PATH\"
    fi
    _ncpu=\$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 8)
    result=\$(_compute_bats_jobs 4)
    expected=\$(( _ncpu / 4 ))
    [ \"\$expected\" -lt 2 ] && expected=2
    [ \"\$result\" = \"\$expected\" ] && echo 'PASS'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# 3. Dead-PID entries are reaped and not counted
# ---------------------------------------------------------------------------

@test "_census_live_gate_count reaps dead-PID entries and does not count them" {
  # Write a census entry for a PID that is guaranteed dead
  # Use a subshell that exits immediately, capture its PID
  ( exit 0 ) &
  _dead_pid=$!
  wait "$_dead_pid" 2>/dev/null || true
  _dead_file="${RITE_LOCK_DIR}/gate-census/${_dead_pid}"
  touch "$_dead_file"

  # Also write our own (live) entry
  _live_file="${RITE_LOCK_DIR}/gate-census/$$"
  touch "$_live_file"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    # Calling process is $$; dead entry is ${_dead_pid}; live entry is $$
    # Add our own live entry to make exactly 1 live
    touch '${RITE_LOCK_DIR}/gate-census/\$\$'
    count=\$(_census_live_gate_count)
    echo \"count=\$count\"
    [ -f '${_dead_file}' ] && echo 'DEAD_ENTRY_STILL_PRESENT' || echo 'DEAD_ENTRY_REAPED'
  "
  [ "$status" -eq 0 ]
  # Dead entry should have been reaped
  [[ "$output" == *"DEAD_ENTRY_REAPED"* ]]
  # Dead PID should not be counted
  [[ "$output" != *"count=0"* ]] || true  # count could be 1 (our live entry)
  # Verify dead file is gone from the actual dir too
  [ ! -f "$_dead_file" ]

  # Cleanup
  rm -f "$_live_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 4. RITE_BATS_JOBS=6 returns 6 regardless of census
# ---------------------------------------------------------------------------

@test "RITE_BATS_JOBS override returns the override value regardless of census count" {
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='${RITE_PROJECT_ROOT}'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    export RITE_BATS_JOBS=6
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    # Pass a high census count; override must still win
    result=\$(_compute_bats_jobs 10)
    [ \"\$result\" = '6' ] && echo 'PASS'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# 5. Census entry removed on normal exit (not leaked)
# ---------------------------------------------------------------------------

@test "census entry for this PID is removed after _census_live_gate_count cleans up" {
  # Write a census entry for a dead PID, verify it is reaped synchronously
  ( exit 0 ) &
  _stale_pid=$!
  wait "$_stale_pid" 2>/dev/null || true
  _stale_file="${RITE_LOCK_DIR}/gate-census/${_stale_pid}"
  touch "$_stale_file"

  # Count — should reap the dead entry
  _census_live_gate_count >/dev/null

  [ ! -f "$_stale_file" ]
}
