#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-runners.sh::_provision_pytest_testmon
# Regression tests for #1127: auto-provision pytest-testmon into the repo venv
# for per-cycle scoped gating.
#
# Tests exercise _provision_pytest_testmon directly using stub venv/pip/python
# binaries — no real network access, no real pip install.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  FIXTURE_DIR=$(mktemp -d); export FIXTURE_DIR
  # Pin RITE_PROJECT_ROOT to the empty fixture dir so no-venv tests are
  # deterministic regardless of whether the sharkrite repo has its own .venv.
  unset RITE_PROJECT_ROOT
  export RITE_PROJECT_ROOT="$FIXTURE_DIR"

  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
  # Re-define _diag after last source — rule §2: re-stub after sourcing.
  _diag() { true; }
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests; keep -e for bats failure detection
}

teardown() { rm -rf "${FIXTURE_DIR:-}"; }

# Helper: create a venv stub at <project_root>/<venv_name>/bin/ with controlled
# pip and python binaries.  pip creates a marker file on successful install so
# the python stub can return 0 for "import testmon" after a successful install.
# $1=project_root  $2=venv_name  $3=pip_exit_code
_make_venv_stub() {
  local _pr="$1" _name="$2" _pip_exit="$3"
  local _bin="$_pr/$_name/bin"
  local _marker="$_pr/testmon-installed.marker"
  mkdir -p "$_bin"

  # pip stub: records args, creates marker on success
  printf '#!/bin/bash\necho "pip $*" >> "%s/pip-calls.log"\n[ %d -eq 0 ] && touch "%s"\nexit %d\n' \
    "$_pr" "$_pip_exit" "$_marker" "$_pip_exit" > "$_bin/pip"
  chmod +x "$_bin/pip"

  # python stub: on "import testmon", return 0 only if marker exists
  printf '#!/bin/bash\nif echo "$*" | grep -q "import testmon"; then\n  [ -f "%s" ]; exit $?\nfi\nexit 0\n' \
    "$_marker" > "$_bin/python"
  chmod +x "$_bin/python"
}

@test "venv without testmon: pip invoked and provision returns 0 after successful install" {
  # Fixture venv without testmon (probe fails before install); pip succeeds;
  # re-probe passes because marker was created by pip stub.
  _make_venv_stub "$FIXTURE_DIR" ".venv" 0

  run _provision_pytest_testmon "$FIXTURE_DIR" /dev/null

  [ "$status" -eq 0 ]
  # pip was called with pytest-testmon
  grep -q "pytest-testmon" "$FIXTURE_DIR/pip-calls.log"
}

@test "no venv: no pip call and provision returns 1" {
  # No venv at all — no .venv, venv, or env directory.
  mkdir -p "$FIXTURE_DIR"
  rm -f "$FIXTURE_DIR/pip-calls.log"

  run _provision_pytest_testmon "$FIXTURE_DIR" /dev/null

  [ "$status" -eq 1 ]
  [ ! -f "$FIXTURE_DIR/pip-calls.log" ]
}

@test "pip failure: provision returns 1, gate outcome unaffected" {
  # Venv exists but pip exits non-zero; marker not created so re-probe also fails.
  _make_venv_stub "$FIXTURE_DIR" ".venv" 1

  run _provision_pytest_testmon "$FIXTURE_DIR" /dev/null

  [ "$status" -eq 1 ]
  # pip was still attempted (best-effort)
  grep -q "pytest-testmon" "$FIXTURE_DIR/pip-calls.log"
}

@test "testmon already installed: no pip call and provision returns 0" {
  # Pre-create the marker so the first probe succeeds; pip must not be invoked.
  _make_venv_stub "$FIXTURE_DIR" ".venv" 0
  touch "$FIXTURE_DIR/testmon-installed.marker"

  run _provision_pytest_testmon "$FIXTURE_DIR" /dev/null

  [ "$status" -eq 0 ]
  [ ! -f "$FIXTURE_DIR/pip-calls.log" ]
}

@test "no requirements file written by provision" {
  # _provision_pytest_testmon must never create or modify requirements*.txt.
  _make_venv_stub "$FIXTURE_DIR" ".venv" 0
  printf 'pytest>=7.0\n' > "$FIXTURE_DIR/requirements.txt"
  _before=$(wc -c < "$FIXTURE_DIR/requirements.txt")

  _provision_pytest_testmon "$FIXTURE_DIR" /dev/null || true

  _after=$(wc -c < "$FIXTURE_DIR/requirements.txt")
  [ "$_before" -eq "$_after" ]
  _req_count=$(find "$FIXTURE_DIR" -name "requirements*.txt" | wc -l || true)
  [ "$_req_count" -eq 1 ]
}

@test "venv detection: venv/ directory (second in order) is found when .venv/ absent" {
  _make_venv_stub "$FIXTURE_DIR" "venv" 0

  run _provision_pytest_testmon "$FIXTURE_DIR" /dev/null

  [ "$status" -eq 0 ]
}
