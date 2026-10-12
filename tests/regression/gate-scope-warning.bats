#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# sharkrite-gate-serial
# Regression: GATE_SCOPE_UNSCOPED warning fires for slow target-repo gate runs.
#
# A target repo (non-Sharkrite) runs its full test suite on every fix cycle —
# there is no scoped selection. When the suite exceeds RITE_GATE_SCOPE_WARN_SECONDS
# the gate emits a one-time print_warning and a [diag] GATE_SCOPE_UNSCOPED line.
# Sharkrite's own targeted-selection runs are exempt by construction (_is_sharkrite=true).
# Issue #1125.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TARGET_REPO=$(mktemp -d); export TARGET_REPO
  DIAG_LOG="$TARGET_REPO/diag.log"; export DIAG_LOG

  # Target repo: no Makefile with shellcheck/lint targets — gate detects non-Sharkrite.
  # Minimal git history so worktree-existence guard passes.
  (cd "$TARGET_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && touch README && git add -A && git commit -qm init) >/dev/null 2>&1

  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: test-gate.sh uses a function-sentinel guard (declare -f run_test_gate); pre-source stubs are preserved on source.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
  set +u; set +o pipefail
}

teardown() { rm -rf "${TARGET_REPO:-}"; }

# ---------------------------------------------------------------------------
# Helper: run the gate in a clean subprocess so _diag writes to our DIAG_LOG.
# $1 = extra env assignments (may be empty)
# $2 = RITE_TEST_COMMAND value
# ---------------------------------------------------------------------------
_run_target_gate() {
  local _extra="$1"
  local _test_cmd="$2"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=1125
    export RITE_LOG_FILE='$DIAG_LOG'
    export RITE_TEST_COMMAND='$_test_cmd'
    ${_extra:+$_extra}
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    run_test_gate '$TARGET_REPO/gate.json' '$TARGET_REPO'
  " </dev/null
}

# ---------------------------------------------------------------------------
# Test 1: slow unscoped run → warning printed + diag emitted once
# Use sleep 2 with a threshold of 1 so the duration reliably exceeds it.
# ---------------------------------------------------------------------------
@test "slow target-repo gate emits scope warning and GATE_SCOPE_UNSCOPED diag" {
  _run_target_gate "RITE_GATE_SCOPE_WARN_SECONDS=1" "sleep 2 && true"
  # Gate exits 0 (sleep 2 && true exits 0)
  [ "$status" -eq 0 ]
  # Warning appears in output (print_warning writes to stdout)
  [[ "$output" == *"full test suite every fix cycle"* ]]
  [[ "$output" == *"#975"* ]]
  # Diag line written to log
  [ -f "$DIAG_LOG" ]
  grep -q 'GATE_SCOPE_UNSCOPED' "$DIAG_LOG"
}

# ---------------------------------------------------------------------------
# Test 2: Sharkrite repo (targeted selection) never emits the warning
# _is_sharkrite=true → the check is skipped entirely regardless of duration.
# ---------------------------------------------------------------------------
@test "sharkrite targeted-selection run does not emit scope warning" {
  SHARKRITE_REPO=$(mktemp -d)
  STUB_DIR="$SHARKRITE_REPO/stub"; mkdir -p "$STUB_DIR"

  # Stub make: no-op shellcheck/lint targets (gate detects sharkrite by these)
  cat > "$STUB_DIR/make" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$STUB_DIR/make"

  # Stub bats: emit a passing TAP and exit 0
  cat > "$STUB_DIR/bats" <<'STUB'
#!/bin/bash
printf 'TAP version 13\n1..1\nok 1 smoke\n'
exit 0
STUB
  chmod +x "$STUB_DIR/bats"

  # Sharkrite Makefile: has shellcheck: and lint: targets
  cat > "$SHARKRITE_REPO/Makefile" <<'EOF'
.PHONY: shellcheck lint
shellcheck:
	@echo ok
lint:
	@echo ok
EOF
  mkdir -p "$SHARKRITE_REPO/tests/regression"
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/utils/stub.sh\n@test "smoke" { true; }\n' \
    > "$SHARKRITE_REPO/tests/regression/smoke.bats"
  mkdir -p "$SHARKRITE_REPO/lib/utils"
  printf '#!/bin/bash\nstub() { :; }\n' > "$SHARKRITE_REPO/lib/utils/stub.sh"
  (cd "$SHARKRITE_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && echo "# change" >> lib/utils/stub.sh \
     && git add -A && git commit -qm change) >/dev/null 2>&1

  SR_DIAG_LOG="$SHARKRITE_REPO/diag.log"

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=1125
    export RITE_LOG_FILE='$SR_DIAG_LOG'
    export RITE_GATE_SCOPE_WARN_SECONDS=0
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$SHARKRITE_REPO/gate.json' '$SHARKRITE_REPO'
  " </dev/null

  rm -rf "$SHARKRITE_REPO"

  # Gate exits 0 (stubs pass)
  [ "$status" -eq 0 ]
  # Warning must NOT appear
  [[ "$output" != *"full test suite every fix cycle"* ]]
  # Diag must NOT contain GATE_SCOPE_UNSCOPED
  if [ -f "$SR_DIAG_LOG" ]; then
    ! grep -q 'GATE_SCOPE_UNSCOPED' "$SR_DIAG_LOG"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: below-threshold run emits neither warning nor diag
# ---------------------------------------------------------------------------
@test "below-threshold target-repo gate emits no scope warning" {
  # Use a fast command (true) and a high threshold — duration will be 0 < 300
  _run_target_gate "RITE_GATE_SCOPE_WARN_SECONDS=300" "true"
  [ "$status" -eq 0 ]
  [[ "$output" != *"full test suite every fix cycle"* ]]
  if [ -f "$DIAG_LOG" ]; then
    ! grep -q 'GATE_SCOPE_UNSCOPED' "$DIAG_LOG"
  fi
}
