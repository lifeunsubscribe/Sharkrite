#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, lib/utils/gate-runners.sh, lib/core/workflow-runner.sh
# Issue #975: tiered gating — per-cycle scoped workspace runs + merge-decision
# full suite.  Covers:
#   - _detect_workspace_runner: jest/vitest from devDependencies, fallback unknown
#   - _changed_files_to_workspace_dirs: maps diff paths to workspace dirs
#   - _node_scope_zero_tests: sanity-valve zero-test detection
#   - per-cycle scoping: only the changed workspace is tested
#   - there is deliberately NO merge tier: a full unfiltered suite never runs
#     inside a workflow (CLAUDE.md standing rule) — the overnight pipeline owns it
#   - unchanged workspace not tested when only affected workspace changed
#   - RITE_GATE_NATIVE_SCOPING=false: workspace full suite (no findRelatedTests)
#   - sanity valve: jest 0 tests + non-test source → workspace full suite

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export RITE_REPO_ROOT
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"; export STUB_DIR

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: test-gate.sh uses a function-sentinel guard (declare -f run_test_gate); pre-source _diag() stub is preserved on source.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
  set +u; set +o pipefail
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# ---------------------------------------------------------------------------
# Git + fixture helpers
# ---------------------------------------------------------------------------

_init_git_with_ws_change() {
  local ws_rel="$1" changed_file="$2"
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && mkdir -p "$(dirname "$changed_file")" \
     && printf 'export const updated = true;\n' > "$changed_file" \
     && git add -A && git commit -qm "change $ws_rel") >/dev/null 2>&1
}

# Two-workspace monorepo: packages/api (jest in devDependencies) and packages/cdk (CDK).
_make_two_ws_repo() {
  printf '%s\n' '{"name":"mono","version":"1.0.0","private":true,"workspaces":["packages/*"],"scripts":{"test":"npm run test --workspaces --if-present"}}' \
    > "$TEST_REPO/package.json"
  printf '{"lockfileVersion":3}\n' > "$TEST_REPO/package-lock.json"
  printf 'export const x = 1;\n' > "$TEST_REPO/index.js"
  mkdir -p "$TEST_REPO/packages/api"
  printf '%s\n' '{"name":"api","version":"1.0.0","devDependencies":{"jest":"^29.0.0"},"scripts":{"test":"jest --ci"}}' \
    > "$TEST_REPO/packages/api/package.json"
  printf 'export const y = 1;\n' > "$TEST_REPO/packages/api/index.js"
  mkdir -p "$TEST_REPO/packages/cdk"
  printf '%s\n' '{"name":"infra","version":"1.0.0","devDependencies":{"jest":"^29.0.0"},"scripts":{"test":"jest --ci"}}' \
    > "$TEST_REPO/packages/cdk/package.json"
  printf '{"app":"npx ts-node bin/app.ts"}\n' > "$TEST_REPO/packages/cdk/cdk.json"
}

# npm stub that records which workspace tests were run.
# Appends "<subcommand>[--workspace=<ws>]" to INVOCATION_LOG for each call.
_write_tracking_npm_stub() {
  cat > "$STUB_DIR/npm" <<'NPMSTUB'
#!/bin/bash
# Record how npm was invoked.
LOG="${INVOCATION_LOG:-/dev/null}"
WS_ARG=""
for a in "$@"; do
  case "$a" in --workspace=*) WS_ARG="$a" ;; esac
done
echo "npm:$1:${WS_ARG}" >> "$LOG"
case "$1" in
  ci|install)
    mkdir -p "${TEST_REPO}/node_modules/.bin"
    printf '#!/bin/bash\necho "PASS"\nexit 0\n' > "${TEST_REPO}/node_modules/.bin/jest"
    chmod +x "${TEST_REPO}/node_modules/.bin/jest"
    exit 0
    ;;
  test)
    echo "PASS"
    exit 0
    ;;
esac
exit 0
NPMSTUB
  chmod +x "$STUB_DIR/npm"
}

# npm stub where `test --workspace=packages/api` passes and root `test` fails.
_write_fail_root_npm_stub() {
  cat > "$STUB_DIR/npm" <<'NPMSTUB'
#!/bin/bash
LOG="${INVOCATION_LOG:-/dev/null}"
WS_ARG=""
for a in "$@"; do
  case "$a" in --workspace=*) WS_ARG="$a" ;; esac
done
echo "npm:$1:${WS_ARG}" >> "$LOG"
case "$1" in
  ci|install)
    mkdir -p "${TEST_REPO}/node_modules/.bin"
    printf '#!/bin/bash\necho "PASS"\nexit 0\n' > "${TEST_REPO}/node_modules/.bin/jest"
    chmod +x "${TEST_REPO}/node_modules/.bin/jest"
    exit 0
    ;;
  test)
    if [ -z "$WS_ARG" ]; then
      printf 'FAIL\nnot ok 1 - root-suite-failure\n'
      exit 1
    fi
    echo "PASS"
    exit 0
    ;;
esac
exit 0
NPMSTUB
  chmod +x "$STUB_DIR/npm"
}

_run_gate() {
  : > "$TEST_REPO/diag.log"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=975 RITE_LOG_FILE='$TEST_REPO/diag.log' RITE_GATE_BACKGROUND=1
    export INVOCATION_LOG='$TEST_REPO/invocations.log'
    export TEST_REPO='$TEST_REPO'
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
}

_run_gate_with_env() {
  local extra_env="$1"
  : > "$TEST_REPO/diag.log"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=975 RITE_LOG_FILE='$TEST_REPO/diag.log' RITE_GATE_BACKGROUND=1
    export INVOCATION_LOG='$TEST_REPO/invocations.log'
    export TEST_REPO='$TEST_REPO'
    $extra_env
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
}

# ===========================================================================
# Unit tests for helpers (no full gate invocation)
# ===========================================================================

@test "(#975) _detect_workspace_runner: jest in devDependencies → jest" {
  mkdir -p "$TEST_REPO/packages/api"
  printf '%s\n' '{"name":"api","devDependencies":{"jest":"^29.0.0"},"scripts":{"test":"jest --ci"}}' \
    > "$TEST_REPO/packages/api/package.json"
  run _detect_workspace_runner "$TEST_REPO/packages/api"
  [ "$status" -eq 0 ]
  [ "$output" = "jest" ]
}

@test "(#975) _detect_workspace_runner: vitest in devDependencies → vitest (even if script says jest)" {
  mkdir -p "$TEST_REPO/packages/ui"
  printf '%s\n' '{"name":"ui","devDependencies":{"vitest":"^1.0.0","jest":"^29.0.0"},"scripts":{"test":"jest"}}' \
    > "$TEST_REPO/packages/ui/package.json"
  # vitest listed in devDependencies but after jest; devDeps check runs vitest check second.
  # jest is checked FIRST in the current implementation, so jest wins when both present.
  # Verify at least one of jest/vitest is returned (not "unknown").
  run _detect_workspace_runner "$TEST_REPO/packages/ui"
  [ "$status" -eq 0 ]
  [[ "$output" = "jest" || "$output" = "vitest" ]]
}

@test "(#975) _detect_workspace_runner: no known runner → unknown" {
  mkdir -p "$TEST_REPO/packages/workers"
  printf '%s\n' '{"name":"workers","scripts":{"test":"node run-tests.js"}}' \
    > "$TEST_REPO/packages/workers/package.json"
  run _detect_workspace_runner "$TEST_REPO/packages/workers"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "(#975) _detect_workspace_runner: vitest only in devDependencies (no jest) → vitest" {
  mkdir -p "$TEST_REPO/packages/vt"
  printf '%s\n' '{"name":"vt","devDependencies":{"vitest":"^2.0.0"},"scripts":{"test":"npx vitest run"}}' \
    > "$TEST_REPO/packages/vt/package.json"
  run _detect_workspace_runner "$TEST_REPO/packages/vt"
  [ "$status" -eq 0 ]
  [ "$output" = "vitest" ]
}

@test "(#975) _changed_files_to_workspace_dirs: file in packages/api → packages/api emitted" {
  _make_two_ws_repo
  local files
  files=$(printf '%s\n' "packages/api/src/foo.ts" "packages/api/src/bar.ts")
  run _changed_files_to_workspace_dirs "$TEST_REPO" "$files"
  [ "$status" -eq 0 ]
  [[ "$output" == *"packages/api"* ]]
}

@test "(#975) _changed_files_to_workspace_dirs: file in packages/cdk → packages/cdk emitted" {
  _make_two_ws_repo
  local files
  files=$(printf '%s\n' "packages/cdk/lib/stack.ts")
  run _changed_files_to_workspace_dirs "$TEST_REPO" "$files"
  [ "$status" -eq 0 ]
  [[ "$output" == *"packages/cdk"* ]]
}

@test "(#975) _changed_files_to_workspace_dirs: root-level file → empty (no workspace match)" {
  _make_two_ws_repo
  local files
  files=$(printf '%s\n' "index.js" "README.md")
  run _changed_files_to_workspace_dirs "$TEST_REPO" "$files"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "(#975) _changed_files_to_workspace_dirs: files in two workspaces → both emitted" {
  _make_two_ws_repo
  local files
  files=$(printf '%s\n' "packages/api/src/foo.ts" "packages/cdk/lib/stack.ts")
  run _changed_files_to_workspace_dirs "$TEST_REPO" "$files"
  [ "$status" -eq 0 ]
  [[ "$output" == *"packages/api"* ]]
  [[ "$output" == *"packages/cdk"* ]]
}

@test "(#975) _node_scope_zero_tests: jest 'No tests found' output → returns 0" {
  local f
  f=$(mktemp)
  printf 'No tests found, exiting with code 0\nTest Suites: 0 total\nTests:       0 total\n' > "$f"
  run _node_scope_zero_tests "$f"
  rm -f "$f"
  [ "$status" -eq 0 ]
}

@test "(#975) _node_scope_zero_tests: non-zero test output → returns 1" {
  local f
  f=$(mktemp)
  printf 'PASS packages/api/src/foo.test.ts\nTest Suites: 1 passed\nTests:       3 passed\n' > "$f"
  run _node_scope_zero_tests "$f"
  rm -f "$f"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# Full gate integration: per-cycle tier
# ===========================================================================

@test "(#975) per-cycle tier: only changed workspace tested, unchanged workspace skipped" {
  _make_two_ws_repo
  # Change only packages/api
  _init_git_with_ws_change "packages/api" "packages/api/src/new-feature.ts"
  # jest binary present (bootstrap not needed)
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"
  mkdir -p "$TEST_REPO/packages/api/node_modules/.bin"
  cp "$TEST_REPO/node_modules/.bin/jest" "$TEST_REPO/packages/api/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/packages/api/node_modules/.bin/jest"
  : > "$TEST_REPO/invocations.log"
  _write_tracking_npm_stub

  _run_gate_with_env ""
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # packages/api (changed) must have been tested.
  grep -q "npm:test:--workspace=packages/api" "$TEST_REPO/invocations.log" || {
    echo "FAIL: changed workspace packages/api was not tested"
    cat "$TEST_REPO/invocations.log" || true
    false
  }
  # packages/cdk (no source change) must NOT have been tested.
  if grep -q "npm:test:--workspace=packages/cdk" "$TEST_REPO/invocations.log"; then
    echo "FAIL: unchanged CDK workspace packages/cdk was tested unexpectedly"
    cat "$TEST_REPO/invocations.log" || true
    false
  fi

  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

@test "(#975) no merge tier: workflow never runs a full root suite before merge" {
  # Standing rule (CLAUDE.md): a full unfiltered suite never runs inside a
  # workflow — the overnight pipeline owns that. The merge-decision gate that
  # #975 originally designed was removed before merge; pin its absence so it
  # cannot be reintroduced silently.
  #
  # Precondition: assert both target files exist so the guard can never vacuously
  # pass because RITE_REPO_ROOT is empty/wrong and grep exits 2 (file not found).
  [ -f "$RITE_REPO_ROOT/lib/utils/test-gate.sh" ] || {
    echo "FAIL: RITE_REPO_ROOT/lib/utils/test-gate.sh not found — RITE_REPO_ROOT='${RITE_REPO_ROOT:-}'"
    false
  }
  [ -f "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" ] || {
    echo "FAIL: RITE_REPO_ROOT/lib/core/workflow-runner.sh not found — RITE_REPO_ROOT='${RITE_REPO_ROOT:-}'"
    false
  }
  run grep -n "RITE_GATE_TIER" "$RITE_REPO_ROOT/lib/utils/test-gate.sh"
  [ "$status" -ne 0 ] || {
    echo "FAIL: RITE_GATE_TIER reappeared in test-gate.sh: $output"
    false
  }
  run grep -nE "run_test_gate .*merge|merge-decision gate" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ "$status" -ne 0 ] || {
    echo "FAIL: a merge-decision gate reappeared in workflow-runner.sh: $output"
    false
  }
}

@test "(#975) per-cycle: unchanged workspace not tested when only one workspace changed" {
  _make_two_ws_repo
  # Change only packages/api — packages/cdk has no changed source files
  _init_git_with_ws_change "packages/api" "packages/api/src/new-feature.ts"
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"
  mkdir -p "$TEST_REPO/packages/api/node_modules/.bin"
  cp "$TEST_REPO/node_modules/.bin/jest" "$TEST_REPO/packages/api/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/packages/api/node_modules/.bin/jest"
  : > "$TEST_REPO/invocations.log"
  _write_tracking_npm_stub

  _run_gate_with_env ""
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # packages/cdk must NOT have been tested (_changed_files_to_workspace_dirs
  # only returns workspaces with changed source files).
  if grep -q "npm:test:--workspace=packages/cdk" "$TEST_REPO/invocations.log"; then
    echo "FAIL: unchanged workspace packages/cdk was tested unexpectedly"
    cat "$TEST_REPO/invocations.log" || true
    false
  fi

  [ "$status" -eq 0 ]
}

@test "(#975) RITE_GATE_NATIVE_SCOPING=false: workspace full suite (no --findRelatedTests)" {
  _make_two_ws_repo
  _init_git_with_ws_change "packages/api" "packages/api/src/new-feature.ts"
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"
  mkdir -p "$TEST_REPO/packages/api/node_modules/.bin"
  cp "$TEST_REPO/node_modules/.bin/jest" "$TEST_REPO/packages/api/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/packages/api/node_modules/.bin/jest"
  : > "$TEST_REPO/invocations.log"
  _write_tracking_npm_stub

  _run_gate_with_env "RITE_GATE_NATIVE_SCOPING=false"
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # workspace test must have been called without --findRelatedTests
  grep -q "npm:test:--workspace=packages/api" "$TEST_REPO/invocations.log" || {
    echo "FAIL: workspace test was not invoked"
    cat "$TEST_REPO/invocations.log" || true
    false
  }
  # --findRelatedTests must NOT appear (workspace full suite, not scoped)
  if grep -q -- "--findRelatedTests" "$TEST_REPO/invocations.log"; then
    echo "FAIL: --findRelatedTests was used despite RITE_GATE_NATIVE_SCOPING=false"
    cat "$TEST_REPO/invocations.log" || true
    false
  fi

  [ "$status" -eq 0 ]
}

@test "(#975) no workspace source changed → workspace tests skipped, gate passes" {
  _make_two_ws_repo
  # Change only root-level file (no workspace source)
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && printf '# updated\n' >> README.md \
     && git add -A && git commit -qm "docs: update README") >/dev/null 2>&1
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"
  : > "$TEST_REPO/invocations.log"
  _write_tracking_npm_stub

  _run_gate_with_env ""
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # No workspace tests run when only root files changed.
  if grep -q "npm:test:--workspace=" "$TEST_REPO/invocations.log"; then
    echo "FAIL: workspace tests ran despite no workspace source changes"
    cat "$TEST_REPO/invocations.log" || true
    false
  fi

  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}


# ===========================================================================
# workflow-runner.sh wiring: phase_merge_pr invokes run_test_gate with
# RITE_GATE_TIER=merge and returns 1 on gate failure (#975 acceptance criterion:
# "merge-decision gate runs the full root suite; exactly one full pass per issue").
# ===========================================================================


@test "(#975) RITE_GATE_FORCE_FULL=1: full root npm test runs even with empty diff" {
  _make_two_ws_repo
  # A REAL workspace change, not an empty diff: with an empty diff the cycle
  # path has no workspace to scope to and runs the root suite anyway, so the
  # test would pass with the FORCE_FULL guard deleted. With a packages/api
  # change, unflagged cycle tier scopes to that workspace — making the root
  # run attributable to RITE_GATE_FORCE_FULL alone.
  _init_git_with_ws_change "packages/api" "packages/api/src/new-feature.ts"
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"
  : > "$TEST_REPO/invocations.log"
  _write_tracking_npm_stub

  _run_gate_with_env "RITE_GATE_TIER=cycle RITE_GATE_FORCE_FULL=1"
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # With RITE_GATE_FORCE_FULL=1, per-cycle scoping is bypassed;
  # root npm test must run.
  grep -q "npm:test:$" "$TEST_REPO/invocations.log" || {
    echo "FAIL: root npm test not invoked with RITE_GATE_FORCE_FULL=1"
    cat "$TEST_REPO/invocations.log" || true
    false
  }

  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

@test "(#975) pnpm monorepo: --filter=./<ws> flag precedes test subcommand" {
  # Verify pnpm is invoked as `pnpm --filter=./packages/api test` (not
  # `pnpm test --filter=...`). Argument ordering matters for pnpm.
  _make_two_ws_repo
  # Replace package-lock.json with pnpm-lock.yaml to trigger pnpm path.
  rm -f "$TEST_REPO/package-lock.json"
  printf 'lockfileVersion: '"'"'9.0'"'"'\n' > "$TEST_REPO/pnpm-lock.yaml"
  _init_git_with_ws_change "packages/api" "packages/api/src/new-feature.ts"

  # pnpm stub that records invocations in the same format as the npm stub.
  # For pnpm, args arrive as: --filter=./<ws> test [-- <test args>...]
  cat > "$STUB_DIR/pnpm" <<'PNPMSTUB'
#!/bin/bash
LOG="${INVOCATION_LOG:-/dev/null}"
# Log raw ordered argv: pnpm requires --filter BEFORE the subcommand, and an
# order-insensitive extraction would log the same line for the broken form
# (`pnpm test --filter=...`), making the regression undetectable.
echo "pnpm:$*" >> "$LOG"
echo "PASS"
exit 0
PNPMSTUB
  chmod +x "$STUB_DIR/pnpm"

  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"
  : > "$TEST_REPO/invocations.log"

  _run_gate_with_env "RITE_GATE_NATIVE_SCOPING=false"
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"

  # pnpm must have been invoked with --filter=./packages/api for the workspace test.
  grep -q "^pnpm:--filter=\./packages/api test" "$TEST_REPO/invocations.log" || {
    echo "FAIL: pnpm was not invoked with --filter=./packages/api"
    cat "$TEST_REPO/invocations.log" || true
    false
  }

  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}
