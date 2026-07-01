#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# Issue #818: the node gate doesn't ensure WORKSPACE runners are installed in an
# npm-workspaces monorepo.
#
# #807 gates the bootstrap on RUNNER RESOLVABILITY, but it extracts the runner
# from the ROOT package.json `test` script and checks the ROOT node_modules/.bin.
# For an npm-WORKSPACES monorepo whose root test is
# `npm run test --workspaces --if-present`, the runner extraction yields `npm`
# (a delegator, or bails), so it hits the "root .bin non-empty → resolvable"
# heuristic and SKIPS the bootstrap. The workspace packages' runners (jest in a
# sub-package) are therefore never ensured installed → `jest: command not found`
# (127) → runner_unavailable persists even with #807 live.
#
# The fix makes the resolvability/bootstrap WORKSPACE-AWARE: when the root
# package.json has a non-empty `.workspaces` (or the test script contains
# `--workspaces`), do NOT trust the root-.bin heuristic — bootstrap unless every
# workspace runner can be positively confirmed to resolve (in the workspace .bin,
# the hoisted root .bin, or on PATH). Single-package repos keep the exact #807
# behaviour (no regression).
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

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# Give the fixture a git history so the diff-base resolves (the gate diffs
# origin/main...HEAD to decide whether source was touched).
_init_git() {
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && printf 'export const x = 2;\n' > index.js \
     && git add -A && git commit -qm change) >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Fixture builders.
# ---------------------------------------------------------------------------

# A workspaces monorepo: root package.json declares `workspaces` + a delegating
# test script, plus one workspace `packages/api` whose test runner is `jest`.
_make_workspaces_repo() {
  printf '%s\n' '{"name":"mono","version":"1.0.0","private":true,"workspaces":["packages/*"],"scripts":{"test":"npm run test --workspaces --if-present"}}' > "$TEST_REPO/package.json"
  printf '{"lockfileVersion":3}\n' > "$TEST_REPO/package-lock.json"
  printf 'export const x = 1;\n' > "$TEST_REPO/index.js"
  mkdir -p "$TEST_REPO/packages/api"
  printf '%s\n' '{"name":"api","version":"1.0.0","scripts":{"test":"jest --ci"}}' > "$TEST_REPO/packages/api/package.json"
  printf 'export const y = 1;\n' > "$TEST_REPO/packages/api/index.js"
}

# A single-package (non-workspaces) repo whose test runner is `jest`.
_make_single_package_repo() {
  printf '%s\n' '{"name":"single","version":"1.0.0","scripts":{"test":"jest --ci"}}' > "$TEST_REPO/package.json"
  printf '{"lockfileVersion":3}\n' > "$TEST_REPO/package-lock.json"
  printf 'export const x = 1;\n' > "$TEST_REPO/index.js"
}

# Put a non-jest binary in root node_modules/.bin so the "root .bin non-empty"
# heuristic WOULD fire (this is the trap #818 falls into). jest itself is absent.
_seed_root_bin_without_jest() {
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\nexit 0\n' > "$TEST_REPO/node_modules/.bin/some-other-tool"
  chmod +x "$TEST_REPO/node_modules/.bin/some-other-tool"
}

# Helper: write an `npm` stub.
#   $1 = behaviour of `ci`/`install`:
#         "installs-jest" → touch marker AND create root node_modules/.bin/jest
#                           (resolves the runner — simulates a successful hoisted
#                           workspace install)
#         "noop"          → touch marker but DON'T create jest (install
#                           "succeeds" but the runner is still missing afterward)
# The `test` subcommand resolves jest from root node_modules/.bin/jest if present
# and runs it; otherwise it emits "command not found" and exits 127 (real npm
# behaviour when the runner binary is absent — the per-workspace test delegation
# would 127 the same way).
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
_run_gate() {
  : > "$TEST_REPO/diag.log"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=818 RITE_LOG_FILE='$TEST_REPO/diag.log' RITE_GATE_BACKGROUND=1
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
}

# ---------------------------------------------------------------------------
# Core #818 regression: a workspaces monorepo where a workspace's runner (jest)
# is NOT resolvable — absent from BOTH the workspace .bin and the root .bin —
# but the root .bin is non-empty (has some-other-tool). The old #807 root-.bin
# heuristic would report "resolvable" and SKIP the bootstrap. The fix must detect
# the workspaces monorepo, find the workspace runner unresolvable, and RUN the
# bootstrap → jest becomes resolvable → outcome=passed.
# ---------------------------------------------------------------------------
@test "(#818) workspaces monorepo, workspace runner unresolvable, root .bin non-empty → bootstrap RUNS" {
  _make_workspaces_repo
  _init_git
  _seed_root_bin_without_jest        # root .bin non-empty but jest ABSENT
  _write_npm_stub "installs-jest"

  # Preconditions that fooled #807: the root-.bin heuristic WOULD fire.
  [ -n "$(ls -A "$TEST_REPO/node_modules/.bin" 2>/dev/null)" ]   # root .bin non-empty
  [ ! -x "$TEST_REPO/node_modules/.bin/jest" ]                    # runner absent
  [ ! -x "$TEST_REPO/packages/api/node_modules/.bin/jest" ]      # workspace .bin absent

  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # The whole point of #818: the bootstrap MUST run despite the non-empty root .bin.
  [ -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: bootstrap was SKIPPED for a workspaces monorepo with an unresolvable workspace runner (#818 regression)"
    false
  }

  # After bootstrap jest is resolvable, so npm test passes → gate green.
  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# No #807 regression: a SINGLE-package repo (no `workspaces`) with the runner
# already resolvable → NO redundant install (bootstrap skipped).
# ---------------------------------------------------------------------------
@test "(#818) single-package repo, runner resolvable → install NOT re-run (no #807 regression)" {
  _make_single_package_repo
  _init_git
  # Real node_modules/.bin with jest present BEFORE the gate runs.
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS all tests"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"
  _write_npm_stub "noop"   # if ci/install ran it'd touch the marker — it must not

  [ -x "$TEST_REPO/node_modules/.bin/jest" ]   # precondition: resolvable

  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # Bootstrap must NOT have run — single package, runner already resolvable.
  [ ! -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: install was re-run for a single-package repo whose runner was already resolvable (#807 regression)"
    false
  }

  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# No redundant install: a workspaces monorepo where ALL workspace runners DO
# resolve (jest present in the workspace's own node_modules/.bin) → bootstrap
# skipped even though it's a workspaces repo.
# ---------------------------------------------------------------------------
@test "(#818) workspaces monorepo, all workspace runners resolve → install NOT re-run" {
  _make_workspaces_repo
  _init_git
  # jest resolvable in the workspace's OWN .bin (not root) — the gate must find it.
  mkdir -p "$TEST_REPO/packages/api/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS all tests"\nexit 0\n' > "$TEST_REPO/packages/api/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/packages/api/node_modules/.bin/jest"
  # Also hoist to root so the root npm-test delegator finds it and passes.
  mkdir -p "$TEST_REPO/node_modules/.bin"
  cp "$TEST_REPO/packages/api/node_modules/.bin/jest" "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"
  _write_npm_stub "noop"   # any ci/install would touch the marker — it must not

  [ -x "$TEST_REPO/packages/api/node_modules/.bin/jest" ]   # workspace runner resolvable

  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # Bootstrap must NOT have run — every workspace runner already resolves.
  [ ! -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: redundant install for a workspaces monorepo whose runners all resolve"
    false
  }

  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# After a bootstrap that STILL leaves the workspace runner missing (devDep
# genuinely absent from the lockfile) → npm test exits 127 → the existing #784
# 127 hard-block fires (outcome=failed, never a silent pass). No new block path.
# ---------------------------------------------------------------------------
@test "(#818) workspaces bootstrap runs but runner still missing → 127 hard-block fires" {
  _make_workspaces_repo
  _init_git
  _seed_root_bin_without_jest
  _write_npm_stub "noop"   # ci/install "succeeds" but never creates jest

  [ ! -x "$TEST_REPO/node_modules/.bin/jest" ]

  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # Bootstrap was attempted (workspace runner unresolvable → we tried to install).
  [ -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: bootstrap should have been attempted for an unresolvable workspace runner"
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
