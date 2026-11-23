#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, lib/utils/gate-verdict.sh, lib/utils/gate-runners.sh
#
# Regression: session-behavioral RITE_* vars must not bleed into bats tests
# spawned by the gate (_GATE_BATS_SCRUB_VARS deny-list, #1186).
#
# Incidents that motivated this:
#   - RITE_TEST_GATE_SKIP_TRIGGERS=true (post-merge-verify): broke 3 lint-selection
#     tests across 5 slots (#1182).
#   - RITE_TARGET_BRANCH=supervised-ux (--branch session): broke both
#     _docs_apply_approved tests across 3 retries (#1049, PR #1179).
#   - SESSION_STATE_FILE / RITE_BATCH_ID / BATCH_MODE (batch 1338, 2026-10-24):
#     #1333's gate ran tests that execute batch-process-issues.sh; they inherited
#     the live batch's session file, reset it in init_session and deleted it in
#     the _cleanup_batch_session EXIT trap. The batch's overall clock restarted
#     mid-run ("Duration: 3s", mode flipped to supervised, ~26 min dropped from
#     the session-hours cap).
#
# A lint rule cannot catch this class: the broken tests contain zero references
# to the triggering variable. Prevention is a runtime boundary at the one
# choke point where the gate spawns bats (_bats_sandbox, all 7 invocations).
#
# Out of scope: rite --full-suite runs from an operator shell, not a workflow
# session — lower exposure, deliberately not covered here.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  # Build _SANDBOX_ARGS by calling the shared helper in gate-runners.sh so
  # behavioral probes always test the actual deny-list.  Removing a var from
  # _bats_session_scrub_args would leave it set in the probe and fail.
  source "$RITE_LIB_DIR/utils/gate-runners.sh"
  _SANDBOX_ARGS=(env)
  while IFS= read -r _flag _var; do
    [ -n "${_var:-}" ] && _SANDBOX_ARGS+=("$_flag" "$_var")
  done < <(_bats_session_scrub_args)
}

# ---------------------------------------------------------------------------
# Structural: deny-list is present in _bats_sandbox
# ---------------------------------------------------------------------------

@test "structural: _bats_session_scrub_args scrubs all _GATE_BATS_SCRUB_VARS session vars" {
  # Verify the shared helper emits -u entries for every session-behavioral var.
  _scrub_output=$(_bats_session_scrub_args)
  [ -n "$_scrub_output" ]
  for _var in RITE_TARGET_BRANCH RITE_TEST_GATE_SKIP_TRIGGERS \
      RITE_STALE_BRANCH_THRESHOLD RITE_STALE_BRANCH_HARD_RESTART_THRESHOLD \
      RITE_ACCEPT_RED_MAIN \
      RITE_TEST_GATE_DIFF_BASE _RITE_PROVIDER_PREFLIGHT_OK \
      SESSION_STATE_FILE RITE_BATCH_ID BATCH_MODE SESSION_START_TIME; do
    grep -q -- "-u $_var" <<< "$_scrub_output" || {
      echo "FAIL: _bats_session_scrub_args deny-list missing -u $_var (_GATE_BATS_SCRUB_VARS)" >&2
      return 1
    }
  done
}

@test "structural: structural RITE_* vars are NOT in the scrub list" {
  # RITE_REPO_ROOT, RITE_LIB_DIR, RITE_PROJECT_ROOT must pass through so
  # Rule 35 suppressions and setup.bash loaders work inside tests.
  _scrub_output=$(_bats_session_scrub_args)
  for _var in RITE_REPO_ROOT RITE_LIB_DIR RITE_PROJECT_ROOT; do
    if grep -q -- "-u $_var" <<< "$_scrub_output"; then
      echo "FAIL: _bats_session_scrub_args must not scrub structural var $_var" >&2
      return 1
    fi
  done
}

@test "structural: _bats_sandbox is used at both the main and flake-retry invocation sites" {
  # The main path (4 _bats_sandbox + 2 _ser_bats_sandbox in test-gate.sh) and the
  # flake-retry (1 _fr_ser_sandbox invocation in gate-verdict.sh) must all use a sandbox.
  # Serial invocations use _ser_bats_sandbox in test-gate.sh and _fr_ser_sandbox in
  # gate-verdict.sh (both derived from _bats_sandbox, adds -u BATS_TEST_TIMEOUT).
  # _bats_sandbox is dynamically scoped from run_test_gate so _gate_flake_retry_pass
  # references it at construction time (line ~247 of gate-verdict.sh).
  _uses_main=$(grep -c '"${_bats_sandbox\[@\]}"' "${RITE_LIB_DIR}/utils/test-gate.sh" || true)
  _uses_ser=$(grep -c '"${_ser_bats_sandbox\[@\]}"' "${RITE_LIB_DIR}/utils/test-gate.sh" || true)
  # Flake-retry uses _fr_ser_sandbox (the local equivalent of _ser_bats_sandbox in
  # gate-verdict.sh) — check for its invocation rather than the bare _bats_sandbox[@] form.
  _uses_flake=$(grep -c '"${_fr_ser_sandbox\[@' "${RITE_LIB_DIR}/utils/gate-verdict.sh" || true)
  _uses=$(( ${_uses_main:-0} + ${_uses_ser:-0} + ${_uses_flake:-0} ))
  # 4 _bats_sandbox + 2 _ser_bats_sandbox + 1 _fr_ser_sandbox = 7 minimum
  [ "${_uses:-0}" -ge 7 ] || {
    echo "FAIL: expected ≥7 sandbox uses (4 _bats_sandbox + 2 _ser_bats_sandbox in test-gate.sh + 1 _fr_ser_sandbox in gate-verdict.sh), got ${_uses}" >&2
    return 1
  }
}

@test "structural: _GATE_BATS_SCRUB_VARS deny-list comment names the canonical constant" {
  # The constant name serves as the grep anchor for behavioral-design.md cross-refs.
  # Now lives in the _bats_session_scrub_args helper in gate-runners.sh.
  grep -q "_GATE_BATS_SCRUB_VARS" "${RITE_LIB_DIR}/utils/gate-runners.sh"
}

@test "structural: _bats_session_scrub_args helper is the shared owner of the scrub list" {
  # test-gate.sh must call the helper (not hardcode the list); otherwise
  # removing a var from the helper leaves it in test-gate.sh silently.
  grep -q "_bats_session_scrub_args" "${RITE_LIB_DIR}/utils/test-gate.sh"
  grep -q "_bats_session_scrub_args" "${RITE_LIB_DIR}/utils/post-merge-verify.sh"
}

@test "structural: test-gate uses a throwaway RITE_STATE_DIR for bats children" {
  # config.sh falls back to real .rite/state when RITE_STATE_DIR is unset;
  # a live gate run would let gated tests read/write the session's state files.
  grep -q "_bats_state_dir" "${RITE_LIB_DIR}/utils/test-gate.sh"
  grep -q "RITE_STATE_DIR" "${RITE_LIB_DIR}/utils/test-gate.sh"
}

# ---------------------------------------------------------------------------
# Behavioral: env scrub removes deny-listed vars, preserves allow-listed ones
# ---------------------------------------------------------------------------

@test "behavioral: RITE_TARGET_BRANCH is unset inside gate-scrubbed bats run" {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  _d=$(mktemp -d)
  cat > "$_d/session-env-probe.bats" <<'EOF'
@test "probe: RITE_TARGET_BRANCH is unset" {
  [ -z "${RITE_TARGET_BRANCH:-}" ]
}
EOF
  # _SANDBOX_ARGS was built from _bats_sandbox in test-gate.sh (setup()),
  # so removing -u RITE_TARGET_BRANCH from the sandbox fails this test.
  run env RITE_TARGET_BRANCH=should-not-leak \
      "${_SANDBOX_ARGS[@]}" \
      bats "$_d/session-env-probe.bats" < /dev/null
  rm -rf "$_d"
  [ "$status" -eq 0 ]
}

@test "behavioral: RITE_REPO_ROOT passes through the env scrub" {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  _d=$(mktemp -d)
  cat > "$_d/passthrough-probe.bats" <<'EOF'
@test "probe: RITE_REPO_ROOT is set" {
  [ -n "${RITE_REPO_ROOT:-}" ]
}
EOF
  # _SANDBOX_ARGS was built from _bats_sandbox in test-gate.sh; RITE_REPO_ROOT
  # must NOT appear in it, so the var passes through to the probe.
  run env RITE_REPO_ROOT=/tmp/fake-repo-root \
      "${_SANDBOX_ARGS[@]}" \
      bats "$_d/passthrough-probe.bats" < /dev/null
  rm -rf "$_d"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Behavioral: the live batch session cannot be reached from a gated test
# ---------------------------------------------------------------------------

@test "behavioral: batch session identity is unset inside gate-scrubbed bats run" {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  _d=$(mktemp -d)
  cat > "$_d/batch-env-probe.bats" <<'EOF'
@test "probe: batch session identity is unset" {
  [ -z "${SESSION_STATE_FILE:-}" ]
  [ -z "${RITE_BATCH_ID:-}" ]
  [ -z "${BATCH_MODE:-}" ]
  [ -z "${SESSION_START_TIME:-}" ]
}
EOF
  run env SESSION_STATE_FILE=/tmp/live-batch.json RITE_BATCH_ID=live-123 \
      BATCH_MODE=true SESSION_START_TIME=1 \
      "${_SANDBOX_ARGS[@]}" \
      bats "$_d/batch-env-probe.bats" < /dev/null
  rm -rf "$_d"
  [ "$status" -eq 0 ]
}

@test "behavioral: the provider preflight sentinel is unset inside gate-scrubbed bats run" {
  # The batch preflight exports _RITE_PROVIDER_PREFLIGHT_OK=true; a gated test
  # asserting healthcheck does NOT export it failed four gate rounds on #1640
  # (2026-11-12) because the gate's bats inherited the batch's own sentinel.
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  _d=$(mktemp -d)
  cat > "$_d/sentinel-probe.bats" <<'EOF'
@test "probe: preflight sentinel is unset" {
  [ -z "${_RITE_PROVIDER_PREFLIGHT_OK:-}" ]
}
EOF
  run env _RITE_PROVIDER_PREFLIGHT_OK=true "${_SANDBOX_ARGS[@]}" bats "$_d/sentinel-probe.bats" < /dev/null
  rm -rf "$_d"
  [ "$status" -eq 0 ]
}

@test "behavioral: a gated test doing what _cleanup_batch_session does leaves the live session file intact" {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  _d=$(mktemp -d)
  local live="$_d/rite-session-state-live.json"
  printf '{"start_time": 1, "mode": "batch-1338"}\n' > "$live"
  # The batch script's EXIT trap runs: rm -f "${SESSION_STATE_FILE:-}"
  cat > "$_d/cleanup-probe.bats" <<'EOF'
@test "probe: batch cleanup trap body" {
  rm -f "${SESSION_STATE_FILE:-}"
}
EOF
  run env SESSION_STATE_FILE="$live" RITE_BATCH_ID=live-123 BATCH_MODE=true \
      "${_SANDBOX_ARGS[@]}" \
      bats "$_d/cleanup-probe.bats" < /dev/null
  [ "$status" -eq 0 ]
  [ -f "$live" ]
  grep -q '"mode": "batch-1338"' "$live"
  rm -rf "$_d"
}

@test "behavioral: throwaway RITE_STATE_DIR isolates gated tests from the live session state" {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  _d=$(mktemp -d)
  _live_state=$(mktemp -d)
  printf 'tests/regression/some-test.bats\n' > "$_live_state/gate-prior-failing-pr99.list"
  # Probe: a bats test that reads RITE_STATE_DIR must see a fresh empty dir,
  # not the live session's state directory (which has a prior-failing list).
  cat > "$_d/state-isolation-probe.bats" <<'EOF'
@test "probe: state dir is private (no prior-failing list from live session)" {
  _flag="${RITE_STATE_DIR:-}/gate-prior-failing-pr99.list"
  [ ! -f "$_flag" ]
}
EOF
  # Build a sandbox with RITE_STATE_DIR set to a throwaway dir (mirrors what
  # run_test_gate does via _bats_sandbox+=(RITE_STATE_DIR="$_bats_state_dir")).
  _throwaway=$(mktemp -d)
  run env RITE_STATE_DIR="$_live_state" \
      "${_SANDBOX_ARGS[@]}" RITE_STATE_DIR="$_throwaway" \
      bats "$_d/state-isolation-probe.bats" < /dev/null
  rm -rf "$_d" "$_live_state" "$_throwaway"
  [ "$status" -eq 0 ]
}

@test "structural: bin/rite-full-suite applies _bats_session_scrub_args to all bats launches" {
  _fs="$RITE_LIB_DIR/../bin/rite-full-suite"
  [ -f "$_fs" ] || skip "bin/rite-full-suite not found"
  # Helper must be called in the script.
  grep -q "_bats_session_scrub_args" "$_fs"
  # Throwaway state dir must be present.
  grep -q "RITE_STATE_DIR" "$_fs"
  # Scrub env must appear in both the deadline-armed and the manual bats launch.
  _uses=$(grep -c '_bats_scrub_env\[@\]' "$_fs" || true)
  [ "${_uses:-0}" -ge 3 ] || {
    echo "FAIL: expected ≥3 _bats_scrub_env uses in bin/rite-full-suite (deadline, manual, serial), got ${_uses}" >&2
    return 1
  }
}
