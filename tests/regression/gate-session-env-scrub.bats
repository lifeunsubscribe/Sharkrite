#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
#
# Regression: session-behavioral RITE_* vars must not bleed into bats tests
# spawned by the gate (_GATE_BATS_SCRUB_VARS deny-list, #1186).
#
# Incidents that motivated this:
#   - RITE_TEST_GATE_SKIP_TRIGGERS=true (post-merge-verify): broke 3 lint-selection
#     tests across 5 slots (#1182).
#   - RITE_TARGET_BRANCH=supervised-ux (--branch session): broke both
#     _docs_apply_approved tests across 3 retries (#1049, PR #1179).
#
# A lint rule cannot catch this class: the broken tests contain zero references
# to the triggering variable. Prevention is a runtime boundary at the one
# choke point where the gate spawns bats (_bats_sandbox, all 7 invocations).
#
# Out of scope: rite --full-suite runs from an operator shell, not a workflow
# session — lower exposure, deliberately not covered here.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
}

# ---------------------------------------------------------------------------
# Structural: deny-list is present in _bats_sandbox
# ---------------------------------------------------------------------------

@test "structural: _bats_sandbox scrubs all _GATE_BATS_SCRUB_VARS session vars" {
  _def=$(sed -n '/_bats_sandbox=(env -u/,/)/p' "${RITE_LIB_DIR}/utils/test-gate.sh")
  [ -n "$_def" ]
  for _var in RITE_TARGET_BRANCH RITE_TEST_GATE_SKIP_TRIGGERS \
      RITE_STALE_BRANCH_THRESHOLD RITE_STALE_BRANCH_HARD_RESTART_THRESHOLD \
      RITE_ACCEPT_RED_MAIN; do
    echo "$_def" | grep -q -- "-u $_var" || {
      echo "FAIL: _bats_sandbox deny-list missing -u $_var (_GATE_BATS_SCRUB_VARS)" >&2
      return 1
    }
  done
}

@test "structural: structural RITE_* vars are NOT scrubbed" {
  # RITE_REPO_ROOT, RITE_LIB_DIR, RITE_PROJECT_ROOT must pass through so
  # Rule 35 suppressions and setup.bash loaders work inside tests.
  _def=$(sed -n '/_bats_sandbox=(env -u/,/)/p' "${RITE_LIB_DIR}/utils/test-gate.sh")
  [ -n "$_def" ]
  for _var in RITE_REPO_ROOT RITE_LIB_DIR RITE_PROJECT_ROOT; do
    echo "$_def" | grep -q -- "-u $_var" && {
      echo "FAIL: _bats_sandbox must not scrub structural var $_var" >&2
      return 1
    }
  done
}

@test "structural: _bats_sandbox is used at both the main and flake-retry invocation sites" {
  # The main path (6 bats calls) and the flake-retry (1 call) must all use
  # _bats_sandbox — a single definition covers both because _gate_flake_retry_pass
  # is called from within run_test_gate where _bats_sandbox is defined as a local
  # (bash dynamic scoping).
  _uses=$(grep -c '"${_bats_sandbox\[@\]}"' "${RITE_LIB_DIR}/utils/test-gate.sh")
  # 6 main + 1 flake-retry = 7 minimum
  [ "${_uses:-0}" -ge 7 ] || {
    echo "FAIL: expected ≥7 _bats_sandbox uses (6 main + 1 flake-retry), got ${_uses}" >&2
    return 1
  }
}

@test "structural: _GATE_BATS_SCRUB_VARS deny-list comment names the canonical constant" {
  # The constant name serves as the grep anchor for behavioral-design.md cross-refs.
  grep -q "_GATE_BATS_SCRUB_VARS" "${RITE_LIB_DIR}/utils/test-gate.sh"
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
  run env RITE_TARGET_BRANCH=should-not-leak \
      env -u RITE_TARGET_BRANCH \
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
  run env RITE_REPO_ROOT=/tmp/fake-repo-root \
      env -u RITE_TARGET_BRANCH \
      bats "$_d/passthrough-probe.bats" < /dev/null
  rm -rf "$_d"
  [ "$status" -eq 0 ]
}
