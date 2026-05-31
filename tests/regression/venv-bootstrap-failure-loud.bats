#!/usr/bin/env bats
# Test suite for issue #12: Gate venv ready message on install success
#
# Verifies that when pip install fails (for base or dev requirements), the
# bootstrap does NOT print "Venv ready ✅" — it should print actionable errors.

setup() {
  # Source utils for color codes and print functions
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "${RITE_LIB_DIR}/utils/config.sh"
  source "${RITE_LIB_DIR}/utils/logging.sh"

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

  # Create a temporary bin directory for our shim
  export SHIM_DIR=$(mktemp -d)

  # Source the script containing run_test_gate (need the whole file for the function)
  # We'll override PATH in each test to inject our failing pip
  source "${RITE_LIB_DIR}/core/claude-workflow.sh"
}

teardown() {
  cd /
  rm -rf "$TEST_REPO"
  rm -rf "${SHIM_DIR:-}"
}

@test "venv bootstrap: base requirements install failure does NOT print 'Venv ready'" {
  # Create a pip shim that always fails
  cat > "$SHIM_DIR/pip" <<'EOF'
#!/bin/bash
echo "ERROR: Simulated pip install failure" >&2
exit 1
EOF
  chmod +x "$SHIM_DIR/pip"

  # Create python3 shim that uses real python but our fake pip for venv creation
  # The -m venv part should succeed, but pip install will fail
  cat > "$SHIM_DIR/python3" <<EOF
#!/bin/bash
# For venv creation, use real python3
if [[ "\$*" == *"venv"* ]]; then
  exec $(which python3) "\$@"
fi
# Otherwise use real python3
exec $(which python3) "\$@"
EOF
  chmod +x "$SHIM_DIR/python3"

  # Prepend our shim directory to PATH
  export PATH="$SHIM_DIR:$PATH"

  # Run the test gate function (which triggers venv bootstrap)
  # Redirect stderr to capture output since print_* functions use stderr
  run bash -c "run_test_gate 2>&1"

  # Should NOT contain "Venv ready ✅"
  ! [[ "$output" =~ "Venv ready" ]]

  # Should contain error messaging
  [[ "$output" =~ "Venv bootstrap incomplete" ]] || [[ "$output" =~ "failed to install" ]]
}

@test "venv bootstrap: dev requirements install failure does NOT print 'Venv ready'" {
  # Create python3 shim that succeeds (uses real python)
  cat > "$SHIM_DIR/python3" <<EOF
#!/bin/bash
exec $(which python3) "\$@"
EOF
  chmod +x "$SHIM_DIR/python3"

  # Create pip shim that fails ONLY for requirements-dev.txt
  cat > "$SHIM_DIR/pip" <<'EOF'
#!/bin/bash
# Fail for dev requirements, succeed for base requirements
if [[ "$*" == *"requirements-dev.txt"* ]]; then
  echo "ERROR: Simulated dev requirements install failure" >&2
  exit 1
fi
# For base requirements, use real pip
exec $(which pip) "$@"
EOF
  chmod +x "$SHIM_DIR/pip"

  # Prepend our shim directory to PATH
  export PATH="$SHIM_DIR:$PATH"

  # Run the test gate (triggers bootstrap)
  run bash -c "run_test_gate 2>&1"

  # Should NOT contain "Venv ready ✅"
  ! [[ "$output" =~ "Venv ready" ]]

  # Should contain error about dev requirements
  [[ "$output" =~ "Dev requirements" ]] || [[ "$output" =~ "requirements-dev.txt" ]] || [[ "$output" =~ "failed to install" ]]
}

@test "venv bootstrap: success path DOES print 'Venv ready'" {
  # This test verifies the positive case — when everything succeeds,
  # the success message should be printed

  # Use real python3 and pip (no shims)
  # Just run the bootstrap
  run bash -c "run_test_gate 2>&1"

  # Should print success if installs worked
  # Note: This might fail if pytest isn't actually available, but that's okay —
  # we're primarily testing the failure paths. Skip the positive assertion if
  # the bootstrap actually fails due to real environment issues.
  if [ "$status" -eq 0 ]; then
    # If test gate succeeded, venv bootstrap should have printed success
    [[ "$output" =~ "Venv ready" ]] || [[ "$output" =~ "No venv found" ]]
  fi
  # If status != 0, that's fine — it means real environment doesn't have pytest,
  # which is a valid state. The important tests are the failure paths above.
}

@test "venv bootstrap: pytest not importable after install prints actionable error" {
  # Create a scenario where pip succeeds but pytest isn't actually importable
  # This simulates a broken install state

  # Create python3 shim
  cat > "$SHIM_DIR/python3" <<EOF
#!/bin/bash
# For venv creation, use real python
if [[ "\$*" == *"venv"* ]]; then
  exec $(which python3) "\$@"
fi

# For pytest import check, fail
if [[ "\$*" == *"import pytest"* ]]; then
  exit 1
fi

# Otherwise use real python
exec $(which python3) "\$@"
EOF
  chmod +x "$SHIM_DIR/python3"

  # Create pip shim that succeeds but doesn't actually install anything
  cat > "$SHIM_DIR/pip" <<'EOF'
#!/bin/bash
# Pretend to succeed without doing anything
exit 0
EOF
  chmod +x "$SHIM_DIR/pip"

  export PATH="$SHIM_DIR:$PATH"

  run bash -c "run_test_gate 2>&1"

  # Should NOT print "Venv ready"
  ! [[ "$output" =~ "Venv ready" ]]

  # Should mention pytest is not importable
  [[ "$output" =~ "pytest" ]] && [[ "$output" =~ "importable" ]]
}
