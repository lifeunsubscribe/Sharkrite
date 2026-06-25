#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Test suite for issue #12: Gate venv ready message on install success
#
# Verifies that when pip install fails (for base or dev requirements), the
# bootstrap does NOT print "Venv ready ✅" — it should print actionable errors.
#
# All pip installs in these tests use shims — no real network access, no
# unbounded hangs. (issue #599: real pip install hung 78 min in CI)

setup() {
  # Source utils for color codes and print functions
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "${RITE_LIB_DIR}/utils/config.sh"
  source "${RITE_LIB_DIR}/utils/logging.sh"
  # Isolate from the developer's local (gitignored) .rite/config, which sets
  # RITE_TEST_CMD to a bats wrapper. Without this, _run_dev_test_gate uses that
  # override and never enters the venv-bootstrap path these tests exercise.
  unset RITE_TEST_CMD

  # Create a mock Python project
  export TEST_REPO=$(mktemp -d)
  cd "$TEST_REPO" || exit 1

  # Initialize git repo
  git init --quiet
  git config user.email "test@example.com"
  git config user.name "Test User"

  # Create Python project structure
  mkdir -p tests
  touch pytest.ini
  echo "pytest>=7.0" > requirements.txt
  echo "pytest-cov>=4.0" > requirements-dev.txt

  # Create initial commit
  git add .
  git commit -m "Initial commit" --quiet

  # Mock environment variables
  export AUTO_MODE=true
  export RITE_ORCHESTRATED=false
  export RITE_TEST_GATE_SKIP=false

  # Create a temporary bin directory for our shims.
  # Tests that need to intercept the bootstrap (no pre-existing venv) add
  # SHIM_DIR to the front of PATH and place a python3 shim here that creates
  # a fake venv with a controlled pip shim — avoiding any real pip network call.
  export SHIM_DIR=$(mktemp -d)

  # Source the script containing _run_dev_test_gate (need the whole file for the function).
  # RITE_SOURCE_FUNCTIONS_ONLY=1 loads only function definitions without executing
  # the main program body (arg parsing, worktree navigation, Claude dev session).
  # Without this, sourcing launches a real Claude Code session (issue #469).
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "${RITE_LIB_DIR}/core/claude-workflow.sh"
}

teardown() {
  cd /
  rm -rf "$TEST_REPO"
  rm -rf "${SHIM_DIR:-}"
}

@test "venv bootstrap: base requirements install failure does NOT print 'Venv ready'" {
  # Exercise the venv bootstrap path (no pre-existing venv) with a pip shim
  # that fails immediately — no real network call, no unbounded install (issue #599).
  #
  # We intercept `python3 -m venv .venv` via a shim in SHIM_DIR so we can inject
  # a broken pip into the fake venv before _run_dev_test_gate tries to use it.
  REAL_PYTHON3=$(which python3)

  # python3 shim: when called as -m venv, build a fake venv with a broken pip
  cat > "$SHIM_DIR/python3" <<SHIMEOF
#!/bin/bash
if [[ "\$*" == *"-m venv"* ]]; then
  # Create minimal venv structure expected by the bootstrap
  mkdir -p .venv/bin
  # Broken pip: fails immediately — simulates base requirements install failure
  cat > .venv/bin/pip <<'PIPEOF'
#!/bin/bash
echo "ERROR: Simulated pip install failure" >&2
exit 1
PIPEOF
  chmod +x .venv/bin/pip
  # python shim: fail pytest import, pass everything else to real python
  cat > .venv/bin/python <<PYEOF
#!/bin/bash
if [[ "\\\$*" == *"import pytest"* ]]; then exit 1; fi
exec "$REAL_PYTHON3" "\\\$@"
PYEOF
  chmod +x .venv/bin/python
  exit 0
fi
exec "$REAL_PYTHON3" "\$@"
SHIMEOF
  chmod +x "$SHIM_DIR/python3"
  export PATH="$SHIM_DIR:$PATH"

  # _run_dev_test_gate is the function defined in claude-workflow.sh that runs
  # tests during Phase 1 dev sessions. It differs from run_test_gate() in
  # test-gate.sh (no args, no JSON output, has auto-fix loop). We source
  # claude-workflow.sh above with RITE_SOURCE_FUNCTIONS_ONLY=1 — so
  # _run_dev_test_gate is in scope here; run_test_gate is not (BW01 fix).
  run _run_dev_test_gate

  # Should NOT contain "Venv ready ✅"
  ! [[ "$output" =~ "Venv ready" ]]

  # Should contain error messaging about the bootstrap failure
  [[ "$output" =~ "Venv bootstrap incomplete" ]] || [[ "$output" =~ "failed to install" ]]
}

@test "venv bootstrap: dev requirements install failure does NOT print 'Venv ready'" {
  # Exercise the venv bootstrap path with a pip shim that succeeds for base
  # requirements but fails for dev requirements — no real network call (issue #599).
  REAL_PYTHON3=$(which python3)

  # python3 shim: build a fake venv with a pip that fails only on requirements-dev.txt
  cat > "$SHIM_DIR/python3" <<SHIMEOF
#!/bin/bash
if [[ "\$*" == *"-m venv"* ]]; then
  mkdir -p .venv/bin
  # Pip shim: succeed for base, fail for dev
  cat > .venv/bin/pip <<'PIPEOF'
#!/bin/bash
if [[ "\$*" == *"requirements-dev.txt"* ]]; then
  echo "ERROR: Simulated dev requirements install failure" >&2
  exit 1
fi
exit 0
PIPEOF
  chmod +x .venv/bin/pip
  # python shim: fail pytest import, pass everything else to real python
  cat > .venv/bin/python <<PYEOF
#!/bin/bash
if [[ "\\\$*" == *"import pytest"* ]]; then exit 1; fi
exec "$REAL_PYTHON3" "\\\$@"
PYEOF
  chmod +x .venv/bin/python
  exit 0
fi
exec "$REAL_PYTHON3" "\$@"
SHIMEOF
  chmod +x "$SHIM_DIR/python3"
  export PATH="$SHIM_DIR:$PATH"

  # Run the dev test gate (triggers bootstrap — no venv exists yet)
  run _run_dev_test_gate

  # Should NOT contain "Venv ready ✅"
  ! [[ "$output" =~ "Venv ready" ]]

  # Should contain error about dev requirements
  [[ "$output" =~ "Dev requirements" ]] || [[ "$output" =~ "requirements-dev.txt" ]] || [[ "$output" =~ "failed to install" ]]
}

@test "venv bootstrap: success path DOES print 'Venv ready'" {
  # This test verifies the positive case — when everything succeeds,
  # the success message should be printed.
  #
  # We use a mock pip that succeeds instantly AND a mock python that accepts
  # "import pytest" so we don't depend on real network access or a real pip install.
  # Without mocks, a real pip install here could hang indefinitely (issue #599).
  REAL_PYTHON3=$(which python3)

  # python3 shim: build a fake venv with a pip and python that both succeed
  cat > "$SHIM_DIR/python3" <<SHIMEOF
#!/bin/bash
if [[ "\$*" == *"-m venv"* ]]; then
  mkdir -p .venv/bin
  # Pip shim: succeeds without doing anything
  cat > .venv/bin/pip <<'PIPEOF'
#!/bin/bash
exit 0
PIPEOF
  chmod +x .venv/bin/pip
  # python shim: accept pytest import check, pass other calls to real python
  cat > .venv/bin/python <<PYEOF
#!/bin/bash
if [[ "\\\$*" == *"import pytest"* ]]; then exit 0; fi
exec "$REAL_PYTHON3" "\\\$@"
PYEOF
  chmod +x .venv/bin/python
  exit 0
fi
exec "$REAL_PYTHON3" "\$@"
SHIMEOF
  chmod +x "$SHIM_DIR/python3"
  export PATH="$SHIM_DIR:$PATH"

  run _run_dev_test_gate

  # Should print success — pip shim and pytest import check both pass
  [[ "$output" =~ "Venv ready" ]]
}

@test "venv bootstrap: hanging pip is killed by timeout and returns promptly" {
  # Verifies the core fix for issue #599: a wedged pip install cannot hang the
  # gate indefinitely when timeout/gtimeout is available.
  #
  # Strategy: set RITE_PIP_INSTALL_TIMEOUT=1 and inject a pip shim that sleeps
  # 30 seconds.  run_with_timeout should kill it before it completes.
  # Skip if neither timeout nor gtimeout is on PATH — the bounding protection is a
  # no-op without the binary (the gate runs pip directly). The behavior on a
  # coreutils-less host is covered by the separate
  # "venv bootstrap: no timeout command prints 'no time cap' warning" test below.
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    skip "timeout/gtimeout not available — bounding test requires the binary"
  fi

  # Ensure timeout.sh has resolved RITE_TIMEOUT_CMD so run_with_timeout uses it.
  # (The setup() sources config.sh which may or may not source timeout.sh.)
  source "${RITE_LIB_DIR}/utils/timeout.sh"
  ensure_timeout_cmd
  export RITE_TIMEOUT_CMD

  REAL_PYTHON3=$(which python3)
  export RITE_PIP_INSTALL_TIMEOUT=1

  # python3 shim: build a fake venv whose pip sleeps 30 seconds (simulates wedge)
  cat > "$SHIM_DIR/python3" <<SHIMEOF
#!/bin/bash
if [[ "\$*" == *"-m venv"* ]]; then
  mkdir -p .venv/bin
  # Pip shim: sleeps 30 s — far longer than the 1-second cap
  cat > .venv/bin/pip <<'PIPEOF'
#!/bin/bash
sleep 30
exit 0
PIPEOF
  chmod +x .venv/bin/pip
  cat > .venv/bin/python <<PYEOF
#!/bin/bash
if [[ "\\\$*" == *"import pytest"* ]]; then exit 1; fi
exec "$REAL_PYTHON3" "\\\$@"
PYEOF
  chmod +x .venv/bin/python
  exit 0
fi
exec "$REAL_PYTHON3" "\$@"
SHIMEOF
  chmod +x "$SHIM_DIR/python3"
  export PATH="$SHIM_DIR:$PATH"

  # Run and measure elapsed time — should return well under 30 seconds
  _start=$(date +%s)
  run _run_dev_test_gate
  _end=$(date +%s)
  _elapsed=$(( _end - _start ))

  # The gate must return within 10 seconds (generous budget around the 1-second cap)
  [ "$_elapsed" -lt 10 ] || {
    echo "FAIL: gate took ${_elapsed}s — expected < 10s (pip shim was not killed)" >&2
    false
  }

  # Should NOT claim the venv is ready (timeout exit is a failure)
  ! [[ "$output" =~ "Venv ready" ]]
}

@test "venv bootstrap: pytest not importable after install prints actionable error" {
  # Create a scenario where pip succeeds but pytest isn't actually importable.
  # This simulates a broken install state (pip exited 0 but didn't install pytest).
  # No real pip network call — all shims (issue #599).
  REAL_PYTHON3=$(which python3)

  # python3 shim: build a fake venv with succeeding pip but failing pytest import
  cat > "$SHIM_DIR/python3" <<SHIMEOF
#!/bin/bash
if [[ "\$*" == *"-m venv"* ]]; then
  mkdir -p .venv/bin
  # Pip shim: pretends to succeed without installing anything
  cat > .venv/bin/pip <<'PIPEOF'
#!/bin/bash
exit 0
PIPEOF
  chmod +x .venv/bin/pip
  # python shim: fail pytest import check to simulate missing module
  cat > .venv/bin/python <<PYEOF
#!/bin/bash
if [[ "\\\$*" == *"import pytest"* ]]; then exit 1; fi
exec "$REAL_PYTHON3" "\\\$@"
PYEOF
  chmod +x .venv/bin/python
  exit 0
fi
exec "$REAL_PYTHON3" "\$@"
SHIMEOF
  chmod +x "$SHIM_DIR/python3"
  export PATH="$SHIM_DIR:$PATH"

  run _run_dev_test_gate

  # Should NOT print "Venv ready"
  ! [[ "$output" =~ "Venv ready" ]]

  # Should mention pytest is not importable
  [[ "$output" =~ "pytest" ]] && [[ "$output" =~ "importable" ]]
}

@test "venv bootstrap: no timeout command prints 'no time cap' warning" {
  # Verifies that when RITE_TIMEOUT_CMD is empty (no timeout/gtimeout binary),
  # the bootstrap emits a clear warning that pip has no time cap (issue #599).
  #
  # This is the counterpart to the "hanging pip is killed by timeout" test above:
  # that test verifies the bounding behavior when the binary IS available;
  # this test verifies the warning behavior when it IS NOT.
  #
  # We use a fast-succeeding pip shim so the bootstrap completes quickly —
  # we only care that the warning fires, not whether the venv is usable.
  REAL_PYTHON3=$(which python3)

  # Force RITE_TIMEOUT_CMD to empty to simulate a coreutils-less host.
  # Reset the session sentinel so this test is isolated from prior runs.
  export RITE_TIMEOUT_CMD=""
  _RITE_PIP_TIMEOUT_WARNED=false

  # python3 shim: build a fake venv with a succeeding pip shim
  cat > "$SHIM_DIR/python3" <<SHIMEOF
#!/bin/bash
if [[ "\$*" == *"-m venv"* ]]; then
  mkdir -p .venv/bin
  # Pip shim: exits 0 immediately — no network, no hang
  cat > .venv/bin/pip <<'PIPEOF'
#!/bin/bash
exit 0
PIPEOF
  chmod +x .venv/bin/pip
  # python shim: accept pytest import so bootstrap completes
  cat > .venv/bin/python <<PYEOF
#!/bin/bash
if [[ "\\\$*" == *"import pytest"* ]]; then exit 0; fi
exec "$REAL_PYTHON3" "\\\$@"
PYEOF
  chmod +x .venv/bin/python
  exit 0
fi
exec "$REAL_PYTHON3" "\$@"
SHIMEOF
  chmod +x "$SHIM_DIR/python3"
  export PATH="$SHIM_DIR:$PATH"

  run _run_dev_test_gate

  # Must contain the no-time-cap warning introduced for issue #599
  [[ "$output" =~ "no time cap" ]]
}
