#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# Issue #807: worktree gate skips the node bootstrap when node_modules is a
# symlink — the test runner is never installed → runner_unavailable flood.
#
# #784 added a node_modules bootstrap, but it gated on `[ ! -d node_modules ]`.
# claude-workflow.sh symlinks the worktree's node_modules to main's, so `[ -d ]`
# is TRUE (follows the link) and the bootstrap SKIPPED even when main's
# node_modules lacked the devDep runner (jest) — exit 127 on every node issue.
#
# The fix gates the bootstrap on RUNNER RESOLVABILITY (is the test script's
# runner binary in node_modules/.bin or on PATH?), not node_modules existence.
# Install when the runner is NOT resolvable, even if node_modules "exists"
# (symlink); skip when it already resolves. After bootstrap, re-check — if still
# unresolvable, the existing #784 127 hard-block fires (no new block path).
#
# Uses the full run_test_gate harness against a NON-Sharkrite fixture repo
# (package.json only — no Makefile shellcheck:/lint: targets, no tests/ dir, no
# pytest.ini) so the npm branch is selected. `npm` is stubbed on PATH so each
# test controls the bootstrap + test-run outcome deterministically.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"; export STUB_DIR
  # Marker the npm stub touches when its `ci`/`install` subcommand runs.
  BOOTSTRAP_MARKER="$TEST_REPO/bootstrap-was-invoked"; export BOOTSTRAP_MARKER

  # Non-Sharkrite node repo: package.json + lockfile (so the bootstrap chooses
  # `npm ci`), a source file, and a git history so the diff-base resolves.
  # Deliberately NO Makefile, NO tests/ dir, NO pytest.ini — keeps the manifest
  # ladder on the package.json (npm) branch. Test script delegates to `jest`.
  printf '{"name":"fix","version":"1.0.0","scripts":{"test":"jest --ci"}}\n' > "$TEST_REPO/package.json"
  printf '{"lockfileVersion":3}\n' > "$TEST_REPO/package-lock.json"
  printf 'export const x = 1;\n' > "$TEST_REPO/index.js"
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && printf 'export const x = 2;\n' > index.js \
     && git add -A && git commit -qm change) >/dev/null 2>&1

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# Create a "main" node_modules dir whose .bin is devDep-less (no jest), then
# symlink the worktree's node_modules to it — exactly the claude-workflow.sh
# layout that fooled the old `[ -d ]` guard. Returns with TEST_REPO/node_modules
# a symlink to a real dir that lacks node_modules/.bin/jest.
_make_symlinked_devdepless_node_modules() {
  local _main_nm="$TEST_REPO/main-node_modules"
  mkdir -p "$_main_nm/.bin"
  # A non-jest binary so .bin is non-empty but the runner is still absent.
  printf '#!/bin/bash\nexit 0\n' > "$_main_nm/.bin/some-other-tool"
  chmod +x "$_main_nm/.bin/some-other-tool"
  ln -s "$_main_nm" "$TEST_REPO/node_modules"
}

# Helper: write an `npm` stub.
#   $1 = behaviour of `ci`/`install`:
#         "installs-jest" → touch marker AND create node_modules/.bin/jest
#                           (resolves the runner — simulates a successful install)
#         "noop"          → touch marker but DON'T create jest (install "succeeds"
#                           but the runner is still missing afterward)
# The `test` subcommand resolves jest from node_modules/.bin/jest if present and
# runs it; otherwise it emits "command not found" and exits 127 (real npm
# behaviour when the runner binary is absent).
_write_npm_stub() {
  local _ci_behaviour="$1"
  cat > "$STUB_DIR/npm" <<STUB
#!/bin/bash
case "\$1" in
  ci|install)
    touch "$BOOTSTRAP_MARKER"
    mkdir -p "$TEST_REPO/node_modules/.bin"
    if [ "$_ci_behaviour" = "installs-jest" ]; then
      printf '#!/bin/bash\necho "PASS all tests"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
      chmod +x "$TEST_REPO/node_modules/.bin/jest"
    fi
    exit 0
    ;;
  test)
    if [ -x "$TEST_REPO/node_modules/.bin/jest" ]; then
      "$TEST_REPO/node_modules/.bin/jest"
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

# Helper: run the gate against the fixture with STUB_DIR ahead on PATH.
# Captures _diag lines + bootstrap chatter to $TEST_REPO/diag.log.
_run_gate() {
  : > "$TEST_REPO/diag.log"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=807 RITE_LOG_FILE='$TEST_REPO/diag.log' RITE_GATE_BACKGROUND=1
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
}

# ---------------------------------------------------------------------------
# Core #807 regression: node_modules is a SYMLINK to a devDep-less main dir
# (jest ABSENT from .bin). The old `[ -d ]` guard followed the symlink and
# SKIPPED the bootstrap → runner missing → 127. The fix must detect the runner
# is unresolvable and RUN the bootstrap, making jest resolvable → outcome=passed.
# ---------------------------------------------------------------------------
@test "(#807) symlinked devDep-less node_modules → bootstrap RUNS (not skipped)" {
  _make_symlinked_devdepless_node_modules
  _write_npm_stub "installs-jest"

  # Preconditions: node_modules "exists" (symlink, so `[ -d ]` is TRUE) but the
  # runner is NOT resolvable — this is precisely what fooled the old guard.
  [ -d "$TEST_REPO/node_modules" ]          # symlink → -d is TRUE
  [ ! -x "$TEST_REPO/node_modules/.bin/jest" ]

  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # The whole point of #807: the bootstrap MUST run despite node_modules existing.
  [ -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: bootstrap was SKIPPED for a symlinked devDep-less node_modules (#807 regression)"
    false
  }

  # After bootstrap jest is resolvable, so npm test passes → gate green.
  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Runner already resolvable (jest present in node_modules/.bin) → NO redundant
# install. The bootstrap must be skipped (marker absent) and the gate passes.
# ---------------------------------------------------------------------------
@test "(#807) runner already resolvable → install NOT re-run" {
  # Real node_modules/.bin with jest present BEFORE the gate runs.
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS all tests"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"
  _write_npm_stub "noop"   # if ci/install ran it'd touch the marker — it must not

  [ -x "$TEST_REPO/node_modules/.bin/jest" ]   # precondition: resolvable

  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # Bootstrap must NOT have run — the runner was already resolvable.
  [ ! -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: install was re-run even though the runner was already resolvable"
    false
  }

  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Install runs but the runner is STILL missing afterward (e.g. devDep genuinely
# absent from the lockfile). The bootstrap runs, jest stays unresolvable, npm
# test exits 127 → the existing #784 127 hard-block fires (outcome=failed,
# never a silent pass). No new block path — the same hard-block is reused.
# ---------------------------------------------------------------------------
@test "(#807) bootstrap runs but runner still missing → 127 hard-block fires" {
  _make_symlinked_devdepless_node_modules
  _write_npm_stub "noop"   # ci/install "succeeds" but never creates jest

  [ ! -x "$TEST_REPO/node_modules/.bin/jest" ]

  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # Bootstrap still attempted (runner was unresolvable → we tried to install).
  [ -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: bootstrap should have been attempted for an unresolvable runner"
    false
  }

  # MUST block via the existing 127 hard-block — never a skip, never a pass.
  [ "$status" -eq 1 ] || {
    echo "FAIL: expected blocking (status 1), got status $status"
    false
  }
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "1" ]

  # Must NOT be a skip (a skip would fake-green the merge).
  run jq -r '.skipped // "false"' "$TEST_REPO/gate.json"
  [ "$output" != "true" ]

  # Reuses the #784 hard-block diagnostic — no new block path.
  run grep -q "TEST_GATE outcome=failed reason=runner_unavailable" "$TEST_REPO/diag.log"
  [ "$status" -eq 0 ] || {
    echo "FAIL: expected the existing #784 'runner_unavailable' hard-block diag"
    echo "--- diag.log ---"; cat "$TEST_REPO/diag.log"
    false
  }
}
