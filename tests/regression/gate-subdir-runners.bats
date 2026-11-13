#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-runners.sh::_gate_dir_runner_kinds|_gate_runner_dirs|_gate_touched_runner_dirs|_gate_run_runner_dir|_link_worktree_toolchain, lib/utils/test-gate.sh::run_test_gate
# sharkrite-gate-serial
#
# Runner homes one level down (freshup 2026-11-12): package.json in frontend/,
# pytest at the root. The root-only detector ran 3h30m of pytest on eleven
# frontend-only PRs and never ran vitest; 8 of 11 branches reached merge with
# their own tests red. Contract under test:
#   - detection lists root + immediate-subdirectory homes with their kind
#   - a diff touches a subdirectory home by any file under it, and the root
#     only by files under no subdirectory home
#   - run_test_gate runs exactly the touched homes; a red subdirectory suite
#     blocks even when the root suite is green and untouched
#   - worktree toolchain: node_modules is cloned (a real dir), venv linked

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"; export STUB_DIR
  _diag() { echo "[diag] $*" >> "$TEST_REPO/diag.log"; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: test-gate.sh uses a function-sentinel guard (declare -f run_test_gate); the pre-source _diag stub survives.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
  set +u; set +o pipefail
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# Root pytest home (pytest.ini + fake .venv python that records its run and
# exits 0) and a frontend/ node home whose test script records its run and
# exits with $FRONTEND_EXIT (default 1 = red).
_make_two_home_fixture() {
  local _fe_exit="${1:-1}"
  mkdir -p "$TEST_REPO/backend" "$TEST_REPO/frontend/src" "$TEST_REPO/.venv/bin" "$TEST_REPO/node_modules"
  printf '[pytest]\n' > "$TEST_REPO/pytest.ini"
  printf 'x = 1\n' > "$TEST_REPO/backend/app.py"
  cat > "$TEST_REPO/.venv/bin/python" <<PY
#!/bin/bash
echo "PYTEST_RAN \$*" >> "$TEST_REPO/ran.log"
echo "===== 3 passed in 0.1s ====="
exit 0
PY
  chmod +x "$TEST_REPO/.venv/bin/python"
  printf '{"name":"fe","version":"1.0.0","scripts":{"test":"bash ./run-tests.sh"}}\n' > "$TEST_REPO/frontend/package.json"
  cat > "$TEST_REPO/frontend/run-tests.sh" <<SH
#!/bin/bash
echo "FRONTEND_RAN" >> "$TEST_REPO/ran.log"
echo "not ok 1 Recipes renders"
exit $_fe_exit
SH
  chmod +x "$TEST_REPO/frontend/run-tests.sh"
  printf 'export const a = 1;\n' > "$TEST_REPO/frontend/src/a.ts"
  # npm stub: `npm test` runs the package's test script from cwd.
  cat > "$STUB_DIR/npm" <<'STUB'
#!/bin/bash
case "$1" in
  test) script=$(jq -r '.scripts.test' package.json); exec bash -c "$script" ;;
  ci|install) exit 0 ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/npm"
  (cd "$TEST_REPO" \
    && git init -q && git config user.email t@t && git config user.name t \
    && printf 'node_modules\n.venv\nstub\nran.log\ndiag.log\ngate.*\n' > .gitignore \
    && git add -A && git commit -qm base \
    && git update-ref refs/remotes/origin/main HEAD) >/dev/null 2>&1
}

_commit_change() {
  (cd "$TEST_REPO" && printf '%s\n' "$2" >> "$1" && git add -A && git commit -qm change) >/dev/null 2>&1
}

_run_gate() {
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=1766 \
           RITE_LOG_FILE='$TEST_REPO/gate.log' RITE_GATE_BACKGROUND=1 \
           RITE_GATE_NATIVE_SCOPING=false ${1:-}
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    _diag() { echo \"[diag] \$*\" >> '$TEST_REPO/diag.log'; }
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
}

@test "detection: root pytest home and frontend node home, dependency/venv dirs excluded" {
  _make_two_home_fixture
  run _gate_runner_dirs "$TEST_REPO"
  [ "$output" = "$(printf 'pytest\t.\nnode\tfrontend')" ]
}

@test "touched: frontend-only diff touches only the node home; a backend file touches only the root" {
  _make_two_home_fixture
  run _gate_touched_runner_dirs "$TEST_REPO" "frontend/src/a.ts"
  [ "$output" = "$(printf 'node\tfrontend')" ]
  run _gate_touched_runner_dirs "$TEST_REPO" "backend/app.py"
  [ "$output" = "$(printf 'pytest\t.')" ]
  run _gate_touched_runner_dirs "$TEST_REPO" "$(printf 'backend/app.py\nfrontend/src/a.ts')"
  [ "$output" = "$(printf 'pytest\t.\nnode\tfrontend')" ]
}

@test "gate: frontend-only PR runs the frontend suite, not pytest, and a red frontend suite blocks" {
  _make_two_home_fixture 1
  _commit_change frontend/src/a.ts 'export const b = 2;'
  _run_gate
  [ -f "$TEST_REPO/ran.log" ]
  grep -q "FRONTEND_RAN" "$TEST_REPO/ran.log"
  ! grep -q "PYTEST_RAN" "$TEST_REPO/ran.log"
  [ "$(jq -r '.exit_code' "$TEST_REPO/gate.json")" != "0" ]
  grep -q "GATE_RUNNERS detected=.:pytest,frontend:node touched=frontend:node" "$TEST_REPO/diag.log"
}

@test "gate: backend-only PR runs pytest, not the frontend suite, and passes" {
  _make_two_home_fixture 1
  _commit_change backend/app.py 'y = 2'
  _run_gate
  grep -q "PYTEST_RAN" "$TEST_REPO/ran.log"
  ! grep -q "FRONTEND_RAN" "$TEST_REPO/ran.log"
  [ "$(jq -r '.exit_code' "$TEST_REPO/gate.json")" = "0" ]
}

@test "gate: a PR touching both homes runs both; green frontend + green pytest passes" {
  _make_two_home_fixture 0
  _commit_change backend/app.py 'y = 2'
  _commit_change frontend/src/a.ts 'export const b = 2;'
  _run_gate
  grep -q "PYTEST_RAN" "$TEST_REPO/ran.log"
  grep -q "FRONTEND_RAN" "$TEST_REPO/ran.log"
  [ "$(jq -r '.exit_code' "$TEST_REPO/gate.json")" = "0" ]
}

@test "gate: RITE_GATE_SUBDIR_RUNNERS=false restores root-only detection (pytest on a frontend diff)" {
  _make_two_home_fixture 1
  _commit_change frontend/src/a.ts 'export const b = 2;'
  _run_gate "RITE_GATE_SUBDIR_RUNNERS=false"
  grep -q "PYTEST_RAN" "$TEST_REPO/ran.log"
  ! grep -q "FRONTEND_RAN" "$TEST_REPO/ran.log"
}

@test "toolchain: node_modules is cloned as a real directory and the venv is linked" {
  _make_two_home_fixture 0
  mkdir -p "$TEST_REPO/frontend/node_modules/.bin"; echo x > "$TEST_REPO/frontend/node_modules/.bin/vitest"
  WT=$(mktemp -d); mkdir -p "$WT/frontend"
  cp "$TEST_REPO/pytest.ini" "$WT/"; cp "$TEST_REPO/frontend/package.json" "$WT/frontend/"
  run _link_worktree_toolchain "$TEST_REPO" "$WT"
  [ -d "$WT/frontend/node_modules" ]
  [ ! -L "$WT/frontend/node_modules" ]
  [ -f "$WT/frontend/node_modules/.bin/vitest" ]
  [ -L "$WT/.venv" ]
  [ "$(readlink "$WT/.venv")" = "$TEST_REPO/.venv" ]
  rm -rf "$WT"
}
