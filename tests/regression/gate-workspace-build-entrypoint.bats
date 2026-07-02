#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# Issue #822: Build workspace packages in node gate bootstrap.
#
# A workspace package whose package.json `main` / `exports` field points at a
# compiled artifact (e.g. `"main": "./dist/index.js"`) will have that path
# absent from a fresh worktree — dist/ is gitignored and nothing ever built
# it.  The gate must detect the missing entry point and run
# `npm run build -w <pkg>` before `npm test` so imports resolve.
#
# Live incident: LeadFlow 2026-06-30→07-01, 411 consecutive gate failures with
# `Failed to resolve import "@leadflow/shared"`.  The root cause was:
#   - shared/package.json → "main": "./dist/index.js"
#   - shared/dist/ was absent (gitignored, never built in the worktree)
#   - jest (the test runner) WAS resolvable → the #818 runner-resolvability
#     check returned 0 ("all good") → bootstrap was SKIPPED
#   - npm test ran, imports failed → 411 consecutive red gate runs
#
# The fix: `_node_workspace_has_missing_entry_points` detects the absent dist/,
# and `_node_build_workspace_packages` runs the build before npm test.
# The #818 bootstrap decision also now treats "runners resolvable but entry
# point missing" as bootstrap-needed (not a skip).
#
# Uses the same fixture/stub harness as gate-node-workspaces.bats.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"; export STUB_DIR
  # Marker: touched by the npm stub's ci/install subcommand.
  BOOTSTRAP_MARKER="$TEST_REPO/bootstrap-was-invoked"; export BOOTSTRAP_MARKER
  # Marker: touched by the npm stub's "run build" subcommand.
  BUILD_MARKER="$TEST_REPO/build-was-invoked"; export BUILD_MARKER

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# Give the fixture a git history so the diff-base resolves.
_init_git() {
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && printf 'export const x = 2;\n' > index.js \
     && git add -A && git commit -qm change) >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# A workspaces monorepo with:
#   - root: delegates test to workspaces
#   - packages/shared: has main→./dist/index.js, a build script, NO dist/ yet
#   - packages/api:    has test runner jest, imports shared
#
# This is the LeadFlow topology that produced the 411-failure outage.
_make_dist_entry_workspaces_repo() {
  printf '%s\n' '{"name":"mono","version":"1.0.0","private":true,"workspaces":["packages/*"],"scripts":{"test":"npm run test --workspaces --if-present"}}' \
    > "$TEST_REPO/package.json"
  printf '{"lockfileVersion":3}\n' > "$TEST_REPO/package-lock.json"
  printf 'export const x = 1;\n' > "$TEST_REPO/index.js"

  # packages/shared: entry point is a compiled artifact; dist/ is absent.
  mkdir -p "$TEST_REPO/packages/shared/src"
  printf '%s\n' '{"name":"@mono/shared","version":"1.0.0","main":"./dist/index.js","scripts":{"build":"echo built && mkdir -p dist && echo '\''export const y = 1;'\'' > dist/index.js","test":"echo no tests in shared"}}' \
    > "$TEST_REPO/packages/shared/package.json"
  printf 'export const y = 1;\n' > "$TEST_REPO/packages/shared/src/index.ts"

  # packages/api: test runner is jest; needs @mono/shared import to resolve.
  mkdir -p "$TEST_REPO/packages/api"
  printf '%s\n' '{"name":"@mono/api","version":"1.0.0","scripts":{"test":"jest --ci"}}' \
    > "$TEST_REPO/packages/api/package.json"
  printf 'export const z = 1;\n' > "$TEST_REPO/packages/api/index.js"
}

# A workspaces monorepo where ALL workspace entry points already exist on disk.
# Verifies the "no redundant build" path.
_make_dist_entry_workspaces_repo_built() {
  _make_dist_entry_workspaces_repo
  # Pre-create the dist/ so the gate detects "entry point exists".
  mkdir -p "$TEST_REPO/packages/shared/dist"
  printf 'export const y = 1;\n' > "$TEST_REPO/packages/shared/dist/index.js"
}

# Place an npm stub with full build + ci + test behaviour.
#   $1 = "build-succeeds" | "build-fails" | "noop"
#
# The stub records which subcommands were invoked via the BUILD_MARKER /
# BOOTSTRAP_MARKER so tests can assert which paths ran without side-effects.
_write_npm_stub() {
  local _build_behaviour="$1"
  cat > "$STUB_DIR/npm" <<STUB
#!/bin/bash
case "\$1" in
  ci|install)
    touch "$BOOTSTRAP_MARKER"
    mkdir -p "$TEST_REPO/node_modules/.bin"
    # Always create jest so the runner is resolvable after install.
    printf '#!/bin/bash\necho "PASS all api tests"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
    chmod +x "$TEST_REPO/node_modules/.bin/jest"
    exit 0
    ;;
  run)
    # Intercept: npm run build -w <pkg>
    if [ "\$2" = "build" ]; then
      touch "$BUILD_MARKER"
      if [ "$_build_behaviour" = "build-succeeds" ]; then
        # Simulate a successful build: create the dist entry point.
        mkdir -p "$TEST_REPO/packages/shared/dist"
        printf 'export const y = 1;\n' > "$TEST_REPO/packages/shared/dist/index.js"
        echo "built @mono/shared successfully"
        exit 0
      elif [ "$_build_behaviour" = "build-fails" ]; then
        echo "ERROR: tsc compilation failed" >&2
        exit 1
      fi
    fi
    exit 0
    ;;
  test)
    # Delegate to jest if resolvable; otherwise exit 127.
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

# Run the gate against the fixture.
_run_gate() {
  : > "$TEST_REPO/diag.log"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=822 RITE_LOG_FILE='$TEST_REPO/diag.log' RITE_GATE_BACKGROUND=1
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
}

# ---------------------------------------------------------------------------
# AC #1 + Done Definition: dist-entry workspace → bootstrap + build → green
#
# Core regression: a workspaces monorepo where:
#   - The workspace runner (jest) is already resolvable
#   - BUT a workspace package's main points at ./dist/index.js which does
#     not exist on disk
# The gate must detect the missing entry point, run the build, then let
# npm test pass.  This is the exact false-negative that caused 411 failures.
# ---------------------------------------------------------------------------
@test "(#822) dist-entry workspace, runner resolvable, dist/ absent → build RUNS, gate passes" {
  _make_dist_entry_workspaces_repo
  _init_git
  # Pre-install jest so the runner IS resolvable (no #818 bootstrap trigger).
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS all api tests"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"

  _write_npm_stub "build-succeeds"

  # Preconditions: runner is resolvable, but dist/ is absent.
  [ -x "$TEST_REPO/node_modules/.bin/jest" ]           # runner resolvable
  [ ! -e "$TEST_REPO/packages/shared/dist/index.js" ]  # entry point absent

  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # The build MUST have been invoked.
  [ -f "$BUILD_MARKER" ] || {
    echo "FAIL: build was NOT invoked despite dist/ being absent (#822 regression)"
    false
  }

  # Gate must pass: build succeeded, jest passes.
  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (gate pass), got $status"
    echo "--- output ---"; printf '%s\n' "${lines[@]}"
    false
  }
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# AC #2: runner resolvable + dist/ absent → treated as bootstrap-needed
#
# The resolvability check must NOT return "skip" when runners are resolvable
# but a compiled entry point is missing.  Specifically:
#   _node_workspace_has_missing_entry_points returns 0 → _node_needs_bootstrap
# This prevents the false-negative of stale worktrees skipping forever.
# ---------------------------------------------------------------------------
@test "(#822) dist-entry workspace, runner resolvable, dist/ absent → bootstrap decision is 'needed' not 'skip'" {
  _make_dist_entry_workspaces_repo
  # Pre-install jest to ensure runner is resolvable.
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS all api tests"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"

  # Unit-test: _node_workspace_has_missing_entry_points must return 0 (needs build).
  run _node_workspace_has_missing_entry_points "$TEST_REPO"
  [ "$status" -eq 0 ] || {
    echo "FAIL: _node_workspace_has_missing_entry_points returned 1 (no missing entry points found)"
    echo "      but packages/shared/dist/index.js is absent — should have detected it"
    false
  }
}

# ---------------------------------------------------------------------------
# AC #3: no build when all entry points exist (no redundant builds on healthy worktrees)
# ---------------------------------------------------------------------------
@test "(#822) dist-entry workspace, dist/ already present → build NOT invoked" {
  _make_dist_entry_workspaces_repo_built
  _init_git
  # jest is resolvable.
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS all api tests"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"

  _write_npm_stub "noop"

  # Preconditions: both runner and entry point exist.
  [ -x "$TEST_REPO/node_modules/.bin/jest" ]
  [ -e "$TEST_REPO/packages/shared/dist/index.js" ]

  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # No build and no install should have been triggered.
  [ ! -f "$BUILD_MARKER" ] || {
    echo "FAIL: build was invoked redundantly despite dist/index.js already existing"
    false
  }
  [ ! -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: bootstrap was invoked redundantly despite runner and entry point present"
    false
  }

  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# AC #3 (unit): _node_workspace_has_missing_entry_points returns 1 when all
# entry points exist.
# ---------------------------------------------------------------------------
@test "(#822) _node_workspace_has_missing_entry_points returns 1 when dist/ exists" {
  _make_dist_entry_workspaces_repo_built

  run _node_workspace_has_missing_entry_points "$TEST_REPO"
  [ "$status" -eq 1 ] || {
    echo "FAIL: _node_workspace_has_missing_entry_points returned 0 (missing entry points)"
    echo "      but packages/shared/dist/index.js is already present — should have returned 1"
    false
  }
}

# ---------------------------------------------------------------------------
# AC #4: build failure is loud and lands as a [GATE]-visible finding
#
# When npm run build fails, the gate must:
#   - exit non-zero (block the merge)
#   - emit a diag line with reason=workspace_build_failed
#   - never be a silent pass or skip
# ---------------------------------------------------------------------------
@test "(#822) workspace build failure is loud: gate blocks, diag emitted, not a silent pass" {
  _make_dist_entry_workspaces_repo
  _init_git
  # jest is resolvable (runner not the issue here).
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS all api tests"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"

  _write_npm_stub "build-fails"

  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # Build was attempted.
  [ -f "$BUILD_MARKER" ] || {
    echo "FAIL: build was not attempted for a package with missing dist/"
    false
  }

  # Gate must block (exit 1).
  [ "$status" -eq 1 ] || {
    echo "FAIL: expected gate to block (exit 1) on build failure, got $status"
    false
  }
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "1" ] || {
    echo "FAIL: gate.json exit_code should be 1, got $output"
    false
  }

  # Must NOT be a skip.
  run jq -r '.skipped // "false"' "$TEST_REPO/gate.json"
  [ "$output" != "true" ] || {
    echo "FAIL: gate.json skipped=true — build failure must never produce a skip"
    false
  }

  # Diag must record the build failure reason.
  run grep -q "reason=workspace_build_failed" "$TEST_REPO/diag.log"
  [ "$status" -eq 0 ] || {
    echo "FAIL: expected diag reason=workspace_build_failed in diag.log"
    echo "--- diag.log ---"; cat "$TEST_REPO/diag.log"
    false
  }
}

# ---------------------------------------------------------------------------
# Interaction with #818: when runner is NOT resolvable AND dist/ is absent,
# install + build both run (install first, then build after).
# ---------------------------------------------------------------------------
@test "(#822+#818) runner unresolvable + dist/ absent → install runs, then build runs, gate passes" {
  _make_dist_entry_workspaces_repo
  _init_git
  # No node_modules at all — runner not resolvable (the #818 scenario).
  [ ! -d "$TEST_REPO/node_modules" ] || rm -rf "$TEST_REPO/node_modules"

  _write_npm_stub "build-succeeds"

  _run_gate
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # Both install and build must have run.
  [ -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: bootstrap (npm ci/install) was not invoked despite runner being absent"
    false
  }
  [ -f "$BUILD_MARKER" ] || {
    echo "FAIL: build was not invoked despite dist/index.js being absent"
    false
  }

  # Gate passes after install + build.
  [ "$status" -eq 0 ] || {
    echo "FAIL: expected gate to pass (exit 0), got $status"
    echo "--- output ---"; printf '%s\n' "${lines[@]}"
    false
  }
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Stale tsconfig.tsbuildinfo handling: if the file exists it is removed before
# the build, so tsc --build does not produce a no-op build.
# ---------------------------------------------------------------------------
@test "(#822) stale tsconfig.tsbuildinfo is removed before build to prevent no-op" {
  _make_dist_entry_workspaces_repo
  # Place a stale tsbuildinfo (the only signal tsc uses to decide if a rebuild
  # is needed when dist/ has been deleted).
  printf '{}' > "$TEST_REPO/packages/shared/tsconfig.tsbuildinfo"
  printf '{}' > "$TEST_REPO/tsconfig.tsbuildinfo"

  # Pre-install jest (runner is resolvable so #818 bootstrap doesn't fire;
  # only the #822 build path runs).
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"

  # Use the unit-level function directly (no need to run the full gate).
  # _node_build_workspace_packages removes the tsbuildinfo before calling npm run build.
  SINK=$(mktemp); export SINK
  # Stub npm run build to just record invocation.
  mkdir -p "$TEST_REPO/stub2"
  printf '#!/bin/bash\ntouch "%s"\nexit 0\n' "$BUILD_MARKER" > "$TEST_REPO/stub2/npm"
  chmod +x "$TEST_REPO/stub2/npm"

  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    _diag() { true; }
    PATH='$TEST_REPO/stub2':\$PATH _node_build_workspace_packages '$TEST_REPO' '$SINK'
  " </dev/null
  rm -f "${SINK:-}"

  # After the function runs the stale files must be gone.
  [ ! -f "$TEST_REPO/packages/shared/tsconfig.tsbuildinfo" ] || {
    echo "FAIL: stale packages/shared/tsconfig.tsbuildinfo was not removed before build"
    false
  }
  [ ! -f "$TEST_REPO/tsconfig.tsbuildinfo" ] || {
    echo "FAIL: stale root tsconfig.tsbuildinfo was not removed before build"
    false
  }
}

# ---------------------------------------------------------------------------
# Non-workspaces single-package repo: no change to existing #807/#818 behaviour.
# A single-package repo with a `build` script and a present main field must NOT
# trigger the workspace build path.
# ---------------------------------------------------------------------------
@test "(#822) single-package (non-workspaces) repo → workspace build path NOT invoked" {
  printf '%s\n' '{"name":"single","version":"1.0.0","main":"./dist/index.js","scripts":{"test":"jest --ci","build":"tsc"}}' \
    > "$TEST_REPO/package.json"
  printf '{"lockfileVersion":3}\n' > "$TEST_REPO/package-lock.json"
  printf 'export const x = 1;\n' > "$TEST_REPO/index.js"

  # Unit test: _node_workspace_has_missing_entry_points on a non-workspaces repo.
  run _node_workspace_has_missing_entry_points "$TEST_REPO"
  # Should return 1 — no workspaces[] → no workspace packages to check.
  [ "$status" -eq 1 ] || {
    echo "FAIL: _node_workspace_has_missing_entry_points returned 0 for a non-workspaces repo"
    false
  }
}
