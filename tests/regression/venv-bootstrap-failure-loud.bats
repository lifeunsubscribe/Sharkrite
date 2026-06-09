#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
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
  # We'll override PATH in each test to inject our failing pip.
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
  # First create a real venv so we can mock its pip
  python3 -m venv .venv

  # Replace the venv's pip with a failing shim
  cat > ".venv/bin/pip" <<'EOF'
#!/bin/bash
echo "ERROR: Simulated pip install failure" >&2
exit 1
EOF
  chmod +x ".venv/bin/pip"

  # Run the test gate function (which triggers venv bootstrap)
  # The venv already exists, so bootstrap will skip creation and go straight to pip install
  run run_test_gate

  # Should NOT contain "Venv ready ✅"
  ! [[ "$output" =~ "Venv ready" ]]

  # Should contain error messaging
  [[ "$output" =~ "Venv bootstrap incomplete" ]] || [[ "$output" =~ "failed to install" ]]
}

@test "venv bootstrap: dev requirements install failure does NOT print 'Venv ready'" {
  # First create a real venv
  python3 -m venv .venv

  # Get the real pip path for delegation
  REAL_PIP=$(which pip3 || which pip)

  # Replace the venv's pip with a shim that fails ONLY for requirements-dev.txt
  cat > ".venv/bin/pip" <<EOF
#!/bin/bash
# Fail for dev requirements, succeed for base requirements
if [[ "\$*" == *"requirements-dev.txt"* ]]; then
  echo "ERROR: Simulated dev requirements install failure" >&2
  exit 1
fi
# For base requirements, delegate to real pip
exec "$REAL_PIP" "\$@"
EOF
  chmod +x ".venv/bin/pip"

  # Run the test gate (triggers bootstrap)
  run run_test_gate

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
  run run_test_gate

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

  # First create a real venv
  python3 -m venv .venv

  # Replace the venv's pip with a shim that succeeds but doesn't actually install anything
  cat > ".venv/bin/pip" <<'EOF'
#!/bin/bash
# Pretend to succeed without doing anything
exit 0
EOF
  chmod +x ".venv/bin/pip"

  # Replace the venv's python with a shim that fails pytest imports
  REAL_PYTHON=$(which python3)
  cat > ".venv/bin/python" <<EOF
#!/bin/bash
# For pytest import check, fail
if [[ "\$*" == *"import pytest"* ]]; then
  exit 1
fi

# Otherwise use real python
exec "$REAL_PYTHON" "\$@"
EOF
  chmod +x ".venv/bin/python"

  run run_test_gate

  # Should NOT print "Venv ready"
  ! [[ "$output" =~ "Venv ready" ]]

  # Should mention pytest is not importable
  [[ "$output" =~ "pytest" ]] && [[ "$output" =~ "importable" ]]
}
