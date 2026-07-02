#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, lib/utils/post-merge-verify.sh
# npm ci/install through a symlinked node_modules DESTROYS the symlink TARGET
# (the main checkout's node_modules): npm's pre-reify rm step readdirs THROUGH
# the link and recursively deletes each entry of the target, then replaces the
# link with a real dir. rite worktrees have exactly that layout —
# claude-workflow.sh symlinks worktree node_modules → main's to save disk — so
# every gate bootstrap (and post-merge dep reinstall) emptied main's
# node_modules.
#
# Fix: _node_desymlink_node_modules (test-gate.sh) removes the LINK (plain rm,
# never rm -rf) inside the bootstrap branch, strictly BEFORE npm ci/install;
# the same 2-line guard is inlined in post-merge-verify.sh's Node
# dep-reinstall branch. npm then builds a worktree-local real dir and main's
# node_modules survives. Repos that never bootstrap keep the symlink (and the
# disk-space benefit) untouched.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"; export STUB_DIR
  # Marker the npm stub touches when its `ci`/`install` subcommand runs.
  BOOTSTRAP_MARKER="$TEST_REPO/bootstrap-was-invoked"; export BOOTSTRAP_MARKER
  # Marker the npm stub touches if node_modules is STILL a symlink when
  # ci/install runs — proves de-symlink-before-install ordering when absent.
  SYMLINK_MARKER="$TEST_REPO/symlink-still-present"; export SYMLINK_MARKER

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# --- unit-test fixtures -----------------------------------------------------

# "Main checkout" node_modules with a sentinel file — the protected target.
_make_main_nm() {
  MAIN_NM="$TEST_REPO/main/node_modules"
  mkdir -p "$MAIN_NM/somepkg"
  echo sentinel > "$MAIN_NM/somepkg/sentinel.txt"
}

# Worktree dir the helper operates on.
_make_wt() {
  WT="$TEST_REPO/wt"
  mkdir -p "$WT"
}

# Run the helper in a FRESH strict-mode shell — asserts it is safe under
# `set -euo pipefail` with _gate_raw_sink unset (unit-call context).
_run_desymlink() {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    _node_desymlink_node_modules '$1'
  " </dev/null
}

@test "unit: symlinked node_modules — link removed, target sentinel survives" {
  _make_main_nm
  _make_wt
  ln -s "$MAIN_NM" "$WT/node_modules"

  _run_desymlink "$WT"
  [ "$status" -eq 0 ]
  [ ! -L "$WT/node_modules" ]
  [ ! -e "$WT/node_modules" ]
  # The load-bearing assertion: the symlink TARGET is untouched.
  [ -f "$MAIN_NM/somepkg/sentinel.txt" ]
}

@test "unit: real-dir node_modules is untouched (no-op)" {
  _make_wt
  mkdir -p "$WT/node_modules/pkg"
  echo keep > "$WT/node_modules/pkg/file.txt"

  _run_desymlink "$WT"
  [ "$status" -eq 0 ]
  [ -d "$WT/node_modules" ]
  [ ! -L "$WT/node_modules" ]
  [ -f "$WT/node_modules/pkg/file.txt" ]
}

@test "unit: absent node_modules exits 0 under set -euo pipefail" {
  _make_wt
  [ ! -e "$WT/node_modules" ]

  _run_desymlink "$WT"
  [ "$status" -eq 0 ]
  [ ! -e "$WT/node_modules" ]
}

@test "unit: dangling symlink removed without error" {
  _make_wt
  ln -s "$TEST_REPO/does-not-exist" "$WT/node_modules"
  [ -L "$WT/node_modules" ]

  _run_desymlink "$WT"
  [ "$status" -eq 0 ]
  [ ! -L "$WT/node_modules" ]
  [ ! -e "$WT/node_modules" ]
}

@test "unit: backend/node_modules symlink variant also de-symlinked" {
  _make_main_nm
  _make_wt
  mkdir -p "$WT/backend"
  ln -s "$MAIN_NM" "$WT/node_modules"
  ln -s "$MAIN_NM" "$WT/backend/node_modules"

  _run_desymlink "$WT"
  [ "$status" -eq 0 ]
  [ ! -L "$WT/node_modules" ]
  [ ! -L "$WT/backend/node_modules" ]
  [ -f "$MAIN_NM/somepkg/sentinel.txt" ]
}

# --- integration fixtures (modeled on gate-node-runner-resolvability.bats) ---

# Non-Sharkrite node repo in $1: package.json + lockfile (bootstrap chooses
# `npm ci`), a source change so the diff-base resolves. Deliberately NO
# Makefile / tests/ / pytest.ini so the manifest ladder picks the npm branch.
_make_node_fixture() {
  local _dir="$1"
  printf '{"name":"fix","version":"1.0.0","scripts":{"test":"jest --ci"}}\n' > "$_dir/package.json"
  printf '{"lockfileVersion":3}\n' > "$_dir/package-lock.json"
  printf 'export const x = 1;\n' > "$_dir/index.js"
  (cd "$_dir" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && printf 'export const x = 2;\n' > index.js \
     && git add -A && git commit -qm change) >/dev/null 2>&1
}

# "Main" node_modules dir with the protected sentinel, devDep-less .bin (no
# jest), symlinked as $1/node_modules — the exact claude-workflow.sh layout.
_make_symlinked_devdepless_node_modules() {
  local _wt="$1"
  MAIN_NM="$TEST_REPO/main-node_modules"
  mkdir -p "$MAIN_NM/.bin" "$MAIN_NM/somepkg"
  echo sentinel > "$MAIN_NM/somepkg/sentinel.txt"
  printf '#!/bin/bash\nexit 0\n' > "$MAIN_NM/.bin/some-other-tool"
  chmod +x "$MAIN_NM/.bin/some-other-tool"
  ln -s "$MAIN_NM" "$_wt/node_modules"
}

# npm stub for $1 (the fixture dir). ci/install: records whether node_modules
# was STILL a symlink at invocation time (ordering proof), touches the
# bootstrap marker, installs a passing jest into a (real) node_modules/.bin.
# test: runs node_modules/.bin/jest, or exits 127 when absent (real npm
# behaviour for a missing runner).
_write_npm_stub() {
  local _wt="$1"
  cat > "$STUB_DIR/npm" <<STUB
#!/bin/bash
case "\$1" in
  ci|install)
    if [ -L "$_wt/node_modules" ]; then
      touch "$SYMLINK_MARKER"
    fi
    touch "$BOOTSTRAP_MARKER"
    mkdir -p "$_wt/node_modules/.bin"
    printf '#!/bin/bash\necho "PASS all tests"\nexit 0\n' > "$_wt/node_modules/.bin/jest"
    chmod +x "$_wt/node_modules/.bin/jest"
    exit 0
    ;;
  test)
    if [ -x "$_wt/node_modules/.bin/jest" ]; then
      "$_wt/node_modules/.bin/jest"
      exit \$?
    fi
    printf '%s\n' "sh: jest: command not found"
    exit 127
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/npm"
}

@test "integration: gate bootstrap de-symlinks BEFORE npm ci — target survives" {
  _make_node_fixture "$TEST_REPO"
  _make_symlinked_devdepless_node_modules "$TEST_REPO"
  _write_npm_stub "$TEST_REPO"

  # Preconditions: symlinked node_modules, runner unresolvable → bootstrap fires.
  [ -L "$TEST_REPO/node_modules" ]
  [ ! -x "$TEST_REPO/node_modules/.bin/jest" ]

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=1 RITE_LOG_FILE='$TEST_REPO/diag.log' RITE_GATE_BACKGROUND=1
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # Bootstrap ran (the #807 behaviour is preserved)...
  [ -f "$BOOTSTRAP_MARKER" ]
  # ...but the symlink was gone BEFORE npm ci was invoked (ordering proof).
  [ ! -f "$SYMLINK_MARKER" ] || {
    echo "FAIL: node_modules was still a symlink when npm ci ran — main's node_modules would be destroyed"
    false
  }
  # The protected target survived and the worktree got its own real dir.
  [ -f "$MAIN_NM/somepkg/sentinel.txt" ]
  [ -d "$TEST_REPO/node_modules" ]
  [ ! -L "$TEST_REPO/node_modules" ]

  # Gate still goes green: jest resolvable after bootstrap.
  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

@test "post-merge-verify: Node dep reinstall de-symlinks first — target survives" {
  PMV_WT="$TEST_REPO/pmv"; mkdir -p "$PMV_WT"
  # Non-Sharkrite node repo. Second commit changes package.json so the
  # dep-reinstall branch fires. NO origin/main ref → the no-overlap skip
  # falls through to verification (merge-base fails → verify anyway).
  printf '{"name":"fix","version":"1.0.0","scripts":{"test":"jest --ci"}}\n' > "$PMV_WT/package.json"
  printf '{"lockfileVersion":3}\n' > "$PMV_WT/package-lock.json"
  (cd "$PMV_WT" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && printf '{"name":"fix","version":"1.0.1","scripts":{"test":"jest --ci"}}\n' > package.json \
     && git add -A && git commit -qm merge) >/dev/null 2>&1

  _make_symlinked_devdepless_node_modules "$PMV_WT"
  _write_npm_stub "$PMV_WT"

  [ -L "$PMV_WT/node_modules" ]

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' RITE_LOG_FILE='$TEST_REPO/pmv-diag.log'
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/post-merge-verify.sh'
    PATH='$STUB_DIR':\$PATH verify_post_merge '$PMV_WT'
  " </dev/null

  # Reinstall branch actually ran (not a vacuous pass)...
  [ -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: dep-reinstall branch never ran — test proved nothing"
    false
  }
  # ...with the symlink already removed when npm ci was invoked.
  [ ! -f "$SYMLINK_MARKER" ] || {
    echo "FAIL: node_modules was still a symlink when npm ci ran in post-merge-verify"
    false
  }
  [ -f "$MAIN_NM/somepkg/sentinel.txt" ]
  [ ! -L "$PMV_WT/node_modules" ]

  # Verification itself passed (stubbed jest is green).
  [ "$status" -eq 0 ]
}
