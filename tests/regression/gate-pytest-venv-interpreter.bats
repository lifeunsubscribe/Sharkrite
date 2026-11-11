#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-runners.sh::_resolve_pytest_python, lib/utils/test-gate.sh, lib/utils/post-merge-verify.sh
#
# Regression tests for the gate's pytest interpreter choice.
#
# Live failure (freshup batch 2026-11-11): _provision_pytest_testmon resolved
# the project venv and installed testmon into it, then the gate ran a bare
# `python3 -m pytest`. Homebrew's python3 has no pytest, so all 16 gate runs
# were `skipped:missing_deps` and two red PRs merged (#529, #534).
#
# Contract: `_resolve_pytest_python <root>` picks, in order,
#   _RITE_PYTEST_VENV_PYTHON → <root>/.venv|venv|env → $RITE_PROJECT_ROOT/.venv
#   → python3 → python
# and neither test-gate.sh nor post-merge-verify.sh runs `python3 -m pytest`
# without going through it.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  FIXTURE_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/venv-resolve.XXXXXX")"
  source "$RITE_LIB_DIR/utils/gate-runners.sh"
  set +u; set +o pipefail
}

teardown() { rm -rf "${FIXTURE_DIR:-}"; }

_mk_python() { mkdir -p "$(dirname "$1")"; printf '#!/bin/bash\nexit 0\n' > "$1"; chmod +x "$1"; }

@test "resolver: _RITE_PYTEST_VENV_PYTHON wins when set and executable" {
  _mk_python "$FIXTURE_DIR/provisioned/bin/python"
  _mk_python "$FIXTURE_DIR/proj/.venv/bin/python"
  _RITE_PYTEST_VENV_PYTHON="$FIXTURE_DIR/provisioned/bin/python"
  run _resolve_pytest_python "$FIXTURE_DIR/proj"
  [ "$output" = "$FIXTURE_DIR/provisioned/bin/python" ]
}

@test "resolver: stale _RITE_PYTEST_VENV_PYTHON (not executable) is ignored" {
  _mk_python "$FIXTURE_DIR/proj/.venv/bin/python"
  _RITE_PYTEST_VENV_PYTHON="$FIXTURE_DIR/gone/bin/python"
  run _resolve_pytest_python "$FIXTURE_DIR/proj"
  [ "$output" = "$FIXTURE_DIR/proj/.venv/bin/python" ]
}

@test "resolver: project .venv, then venv, then env" {
  _RITE_PYTEST_VENV_PYTHON=""
  _mk_python "$FIXTURE_DIR/a/venv/bin/python"
  _mk_python "$FIXTURE_DIR/a/env/bin/python"
  run _resolve_pytest_python "$FIXTURE_DIR/a"
  [ "$output" = "$FIXTURE_DIR/a/venv/bin/python" ]
  _mk_python "$FIXTURE_DIR/a/.venv/bin/python"
  run _resolve_pytest_python "$FIXTURE_DIR/a"
  [ "$output" = "$FIXTURE_DIR/a/.venv/bin/python" ]
}

@test "resolver: worktree without venv falls back to RITE_PROJECT_ROOT/.venv (the live shape)" {
  _RITE_PYTEST_VENV_PYTHON=""
  mkdir -p "$FIXTURE_DIR/worktree"
  _mk_python "$FIXTURE_DIR/primary/.venv/bin/python"
  RITE_PROJECT_ROOT="$FIXTURE_DIR/primary"
  run _resolve_pytest_python "$FIXTURE_DIR/worktree"
  [ "$output" = "$FIXTURE_DIR/primary/.venv/bin/python" ]
}

@test "resolver: no venv anywhere falls back to python3" {
  _RITE_PYTEST_VENV_PYTHON=""
  RITE_PROJECT_ROOT="$FIXTURE_DIR/nothing"
  mkdir -p "$FIXTURE_DIR/empty"
  run _resolve_pytest_python "$FIXTURE_DIR/empty"
  [ "$output" = "python3" ] || [ "$output" = "python" ]
}

@test "test-gate.sh has no bare 'python3 -m pytest' invocation" {
  run grep -nE '^[^#]*\bpython3 -m pytest' "$RITE_LIB_DIR/utils/test-gate.sh"
  [ "$status" -ne 0 ]
}

@test "test-gate.sh pytest block calls _resolve_pytest_python" {
  grep -q '_resolve_pytest_python "\$project_root"' "$RITE_LIB_DIR/utils/test-gate.sh"
}

@test "post-merge-verify.sh prefers the shared resolver" {
  grep -q '_resolve_pytest_python "\$worktree_path"' "$RITE_LIB_DIR/utils/post-merge-verify.sh"
}
