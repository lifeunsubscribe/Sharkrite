#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# sharkrite-gate-serial — flaked under --jobs 8 (2026-07 audit: process-group/signal,
# concurrent-write, and timeout-race tests need the serial group)
#
# Regression test: concurrent shellcheck + lint and bats --jobs N support.
#
# Two performance changes verified here:
#   1. shellcheck and custom lint launch concurrently inside the gate
#      (background + wait), reading only source files so the race is safe.
#   2. bats invocations gain --jobs N when GNU parallel (or rush) is available
#      or RITE_BATS_JOBS is set explicitly. File-level parallelism only;
#      within-file tests remain serial (bats-core default).

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  # Mock _diag — logging.sh side effects aren't needed for these tests.
  _diag() { true; }
  export -f _diag 2>/dev/null || true
}

teardown() {
  unset RITE_BATS_JOBS
}

# ---------------------------------------------------------------------------
# _compute_bats_jobs: env override + auto-detection
# ---------------------------------------------------------------------------

@test "_compute_bats_jobs: explicit RITE_BATS_JOBS=4 → returns 4" {
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  export RITE_BATS_JOBS=4
  run _compute_bats_jobs
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

@test "_compute_bats_jobs: RITE_BATS_JOBS=1 → returns 1 (force serial)" {
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  export RITE_BATS_JOBS=1
  run _compute_bats_jobs
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "_compute_bats_jobs: garbage RITE_BATS_JOBS → falls through to auto" {
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  export RITE_BATS_JOBS="not-a-number"
  run _compute_bats_jobs
  [ "$status" -eq 0 ]
  # Falls through: returns 1 (no parallel) or a CPU count. Either way, numeric.
  [[ "$output" =~ ^[1-9][0-9]*$ ]] || { echo "non-numeric output: '$output'" >&2; return 1; }
}

@test "_compute_bats_jobs: no parallel binary on PATH → returns 1" {
  # Hide both parallel and rush by shadowing them with an empty PATH overlay
  # that only contains the few binaries _compute_bats_jobs actually calls.
  # We need: sysctl/nproc, echo (builtin), command (builtin).
  _shadow_dir="${BATS_TEST_TMPDIR}/no-parallel-bin"
  mkdir -p "$_shadow_dir"
  # Symlink real sysctl into the shadow dir so ncpu detection still works
  if [ -x /usr/sbin/sysctl ]; then ln -sf /usr/sbin/sysctl "$_shadow_dir/sysctl"; fi
  if [ -x /usr/bin/nproc ]; then ln -sf /usr/bin/nproc "$_shadow_dir/nproc"; fi

  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  unset RITE_BATS_JOBS
  PATH="$_shadow_dir" run _compute_bats_jobs
  [ "$status" -eq 0 ]
  [ "$output" = "1" ] || { echo "expected 1 (no parallel binary); got: '$output'" >&2; return 1; }
}

@test "_compute_bats_jobs: scales with ncpu, no cap" {
  # Stub `parallel` and an `nproc` returning 16 in a shadow PATH. Earlier
  # versions capped the result at 4 to protect shared boxes; benchmarking
  # showed the cap left cores idle even under concurrent batches, so the
  # default is now ncpu. Users on shared infra can pin a lower value via
  # RITE_BATS_JOBS=N.
  _shadow_dir="${BATS_TEST_TMPDIR}/parallel-stub"
  mkdir -p "$_shadow_dir"
  cat > "$_shadow_dir/parallel" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat > "$_shadow_dir/nproc" <<'EOF'
#!/bin/sh
echo 16
EOF
  cat > "$_shadow_dir/sysctl" <<'EOF'
#!/bin/sh
echo 16
EOF
  chmod +x "$_shadow_dir/parallel" "$_shadow_dir/nproc" "$_shadow_dir/sysctl"

  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  unset RITE_BATS_JOBS
  PATH="$_shadow_dir:$PATH" run _compute_bats_jobs
  [ "$status" -eq 0 ]
  [ "$output" = "16" ] || { echo "expected ncpu (16); got: '$output'" >&2; return 1; }
}

@test "_compute_bats_jobs: small box (2 cores) returns 2" {
  # Regression: the no-cap default must still return the actual ncpu on
  # small boxes (don't accidentally floor at some higher value).
  _shadow_dir="${BATS_TEST_TMPDIR}/parallel-stub-small"
  mkdir -p "$_shadow_dir"
  cat > "$_shadow_dir/parallel" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat > "$_shadow_dir/nproc" <<'EOF'
#!/bin/sh
echo 2
EOF
  cat > "$_shadow_dir/sysctl" <<'EOF'
#!/bin/sh
echo 2
EOF
  chmod +x "$_shadow_dir/parallel" "$_shadow_dir/nproc" "$_shadow_dir/sysctl"

  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  unset RITE_BATS_JOBS
  PATH="$_shadow_dir:$PATH" run _compute_bats_jobs
  [ "$status" -eq 0 ]
  [ "$output" = "2" ] || { echo "expected ncpu (2); got: '$output'" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Structural assertions on the concurrency wiring in test-gate.sh
# ---------------------------------------------------------------------------

@test "shellcheck and lint are launched with & (background)" {
  # The shellcheck invocation must end with & and the (optional) lint launch
  # must also end with & — that's how the wait below them races them.
  _bg_launches=$(grep -nE 'echo .* > "\$_(sc|lint)_exit_file"; \} &$' "$PROJECT_ROOT/lib/utils/test-gate.sh" | wc -l | tr -d ' ')
  [ "$_bg_launches" -ge 2 ] || {
    echo "expected at least 2 background launches for shellcheck+lint; got $_bg_launches" >&2
    grep -n 'echo .* > "\$_\(sc\|lint\)_exit_file"' "$PROJECT_ROOT/lib/utils/test-gate.sh" >&2
    return 1
  }
}

@test "concurrent gate waits for both shellcheck and lint pids" {
  # Both _sc_pid and _lint_pid must be waited on — otherwise the gate
  # would race past completion and parse incomplete output files.
  grep -q 'wait "$_sc_pid"' "$PROJECT_ROOT/lib/utils/test-gate.sh" \
    || { echo "missing wait \$_sc_pid" >&2; return 1; }
  grep -q 'wait "$_lint_pid"' "$PROJECT_ROOT/lib/utils/test-gate.sh" \
    || { echo "missing wait \$_lint_pid" >&2; return 1; }
}

@test "raw output files use PID suffix (collision-safe under concurrent gates)" {
  # Per-invocation temp files MUST include $$ so two simultaneous gate runs
  # (e.g. dev session + post-commit gate) don't write to the same file.
  grep -q 'rite_gate_sc_raw_.*_\$\$' "$PROJECT_ROOT/lib/utils/test-gate.sh" \
    || { echo "shellcheck raw temp file missing \$\$ suffix" >&2; return 1; }
  grep -q 'rite_gate_lint_raw_.*_\$\$' "$PROJECT_ROOT/lib/utils/test-gate.sh" \
    || { echo "lint raw temp file missing \$\$ suffix" >&2; return 1; }
}

@test "EXIT trap cleans up the new raw-individual temp files" {
  # If the gate crashes mid-run, the trap must remove the per-job raw files
  # too — otherwise we leak /tmp/rite_gate_*_raw_*.txt across runs.
  _trap_line=$(grep -E '^\s+rm -f .*_lint_raw_file.*_sc_raw_individual' "$PROJECT_ROOT/lib/utils/test-gate.sh" || true)
  [ -n "$_trap_line" ] || {
    echo "EXIT trap does not include _sc_raw_individual/_lint_raw_individual" >&2
    grep -n "rm -f.*_lint_raw_file" "$PROJECT_ROOT/lib/utils/test-gate.sh" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Structural assertions on bats --jobs N wiring
# ---------------------------------------------------------------------------

@test "bats invocation includes --jobs args when configured" {
  # _bats_jobs_args must be expanded into BOTH the full-suite invocation
  # (bats -r tests/) and the targeted-list invocation. Empty-array-safe
  # idiom: ${arr[@]+"${arr[@]}"}
  _full_hit=$(grep -c 'bats "${_bats_jobs_args\[@\]+"${_bats_jobs_args\[@\]}"}" -r tests/' "$PROJECT_ROOT/lib/utils/test-gate.sh" || true)
  _targ_hit=$(grep -c 'bats "${_bats_jobs_args\[@\]+"${_bats_jobs_args\[@\]}"}" "${_parallel_files\[@\]}"' "$PROJECT_ROOT/lib/utils/test-gate.sh" || true)
  [ "$_full_hit" -ge 1 ] || { echo "full-suite bats invocation missing --jobs expansion" >&2; return 1; }
  [ "$_targ_hit" -ge 1 ] || { echo "parallel-group bats invocation missing --jobs expansion" >&2; return 1; }
}

@test "_compute_bats_jobs is called before constructing _bats_jobs_args" {
  # The call must be present and must precede the bats invocations.
  _call_line=$(grep -n '_bats_jobs=$(_compute_bats_jobs)' "$PROJECT_ROOT/lib/utils/test-gate.sh" | head -1 | cut -d: -f1 || true)
  _first_bats_line=$(grep -n 'bats "${_bats_jobs_args' "$PROJECT_ROOT/lib/utils/test-gate.sh" | head -1 | cut -d: -f1 || true)
  [ -n "$_call_line" ] || { echo "missing _compute_bats_jobs call" >&2; return 1; }
  [ -n "$_first_bats_line" ] || { echo "missing bats invocation with --jobs" >&2; return 1; }
  [ "$_call_line" -lt "$_first_bats_line" ] || {
    echo "_compute_bats_jobs called AFTER first bats invocation (lines: call=$_call_line bats=$_first_bats_line)" >&2
    return 1
  }
}
