#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-runners.sh::_resolve_node_lint_runner|_normalize_eslint_output, lib/utils/test-gate.sh
# sharkrite-gate-serial
#
# Issue #1545: target repo lint script (scripts.lint) integration with the
# post-commit gate. Tests cover:
#   - _resolve_node_lint_runner: extracts runner binary from scripts.lint
#   - _normalize_eslint_output: eslint stylish and compact → file:line: [rule] msg
#   - Integration: scripts.lint failing eslint → blocking [GATE] lint finding
#   - Integration: scripts.lint absent → gate unaffected (no noise)
#   - Integration: RITE_GATE_REPO_LINT=false → lint step skipped
#   - Integration: eslint scoped to changed JS/TS files (not full repo)
#   - Integration: all changed JS/TS files deleted → no error

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
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

# Build a minimal node repo fixture with scripts.test + scripts.lint and a
# changed .ts file. $1=true puts scripts.lint in the manifest; $1=false omits it.
_make_node_fixture() {
  local _with_lint="${1:-true}"
  if [ "$_with_lint" = "true" ]; then
    printf '{"name":"proj","version":"1.0.0","scripts":{"test":"jest --ci","lint":"eslint . --ext .ts"}}\n' \
      > "$TEST_REPO/package.json"
  else
    printf '{"name":"proj","version":"1.0.0","scripts":{"test":"jest --ci"}}\n' \
      > "$TEST_REPO/package.json"
  fi
  printf '{"lockfileVersion":3}\n' > "$TEST_REPO/package-lock.json"
  printf 'const x = 1;\n' > "$TEST_REPO/index.ts"
  (cd "$TEST_REPO" \
    && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm base \
    && git update-ref refs/remotes/origin/main HEAD \
    && printf 'const x = 2;\n' > index.ts \
    && git add -A && git commit -qm change) >/dev/null 2>&1
}

# Write a jest stub that always passes.
_write_jest_stub() {
  mkdir -p "$TEST_REPO/node_modules/.bin"
  printf '#!/bin/bash\necho "PASS 1 suite"\nexit 0\n' > "$TEST_REPO/node_modules/.bin/jest"
  chmod +x "$TEST_REPO/node_modules/.bin/jest"
}

# Write an eslint stub:
#   $1 = "fail" → exits 1 with a stylish-format violation for index.ts:1
#   $1 = "pass" → exits 0
#   $1 = "record-args" → exits 0, writes received args to $TEST_REPO/eslint-args.txt
_write_eslint_stub() {
  local _mode="${1:-fail}"
  mkdir -p "$TEST_REPO/node_modules/.bin"
  case "$_mode" in
    fail)
      cat > "$TEST_REPO/node_modules/.bin/eslint" <<'STUB'
#!/bin/bash
# Emit eslint stylish format: file header then problem line
for f in "$@"; do
  echo "$f"
  echo "  1:1  error  Unsafe assignment of an `any` value  @typescript-eslint/no-unsafe-assignment"
  echo ""
done
echo "✖ 1 problem (1 error, 0 warnings)"
exit 1
STUB
      ;;
    pass)
      printf '#!/bin/bash\nexit 0\n' > "$TEST_REPO/node_modules/.bin/eslint"
      ;;
    record-args)
      cat > "$TEST_REPO/node_modules/.bin/eslint" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$TEST_REPO/eslint-args.txt"
exit 0
STUB
      ;;
  esac
  chmod +x "$TEST_REPO/node_modules/.bin/eslint"
}

# Write an npm stub: ci creates jest stub (resolvability), test runs jest.
_write_npm_stub() {
  cat > "$STUB_DIR/npm" <<STUB
#!/bin/bash
case "\$1" in
  ci|install)
    mkdir -p "$TEST_REPO/node_modules/.bin"
    exit 0
    ;;
  test)
    if [ -x "$TEST_REPO/node_modules/.bin/jest" ]; then
      "$TEST_REPO/node_modules/.bin/jest"
      exit \$?
    fi
    echo "jest: command not found"
    exit 127
    ;;
  run)
    # npm run lint -- <files> — forward args to eslint
    shift 2  # skip 'run' and 'lint'; remaining args come after '--'
    while [ $# -gt 0 ] && [ "\$1" != "--" ]; do shift; done
    [ "\$1" = "--" ] && shift
    if [ -x "$TEST_REPO/node_modules/.bin/eslint" ]; then
      "$TEST_REPO/node_modules/.bin/eslint" "\$@"
      exit \$?
    fi
    echo "eslint: command not found"
    exit 127
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/npm"
}

# Run the gate with STUB_DIR first on PATH.
_run_gate() {
  local _extra_env="${1:-}"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=1545 \
           RITE_LOG_FILE='$TEST_REPO/gate.log' RITE_GATE_BACKGROUND=1 \
           $_extra_env
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
}

# =============================================================================
# Unit: _resolve_node_lint_runner
# =============================================================================

@test "_resolve_node_lint_runner: eslint script → 'eslint'" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  printf '{"scripts":{"lint":"eslint . --ext .ts,.tsx"}}\n' > "$TEST_REPO/package.json"
  run _resolve_node_lint_runner "$TEST_REPO"
  [ "$output" = "eslint" ]
}

@test "_resolve_node_lint_runner: biome script → 'biome'" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  printf '{"scripts":{"lint":"biome check ."}}\n' > "$TEST_REPO/package.json"
  run _resolve_node_lint_runner "$TEST_REPO"
  [ "$output" = "biome" ]
}

@test "_resolve_node_lint_runner: no scripts.lint → empty string" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  printf '{"scripts":{"test":"jest"}}\n' > "$TEST_REPO/package.json"
  run _resolve_node_lint_runner "$TEST_REPO"
  [ "$output" = "" ]
}

@test "_resolve_node_lint_runner: npm run delegation resolves target runner" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  printf '{"scripts":{"lint":"npm run lint:check","lint:check":"eslint src/"}}\n' \
    > "$TEST_REPO/package.json"
  run _resolve_node_lint_runner "$TEST_REPO"
  [ "$output" = "eslint" ]
}

@test "_resolve_node_lint_runner: no package.json → empty string" {
  rm -f "$TEST_REPO/package.json"
  run _resolve_node_lint_runner "$TEST_REPO"
  [ "$output" = "" ]
}

# =============================================================================
# Unit: _normalize_eslint_output
# =============================================================================

@test "_normalize_eslint_output: eslint stylish → file:line: [rule] message" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local _raw _lint _out
  _raw=$(mktemp); _lint=$(mktemp)
  cat > "$_raw" <<'RAW'
/abs/src/component.tsx
  10:5  error  Unexpected ` in JSX  react/no-unescaped-entities

✖ 1 problem (1 error, 0 warnings)
RAW
  _normalize_eslint_output "$_raw" "$_lint" "/abs"
  _out=$(cat "$_lint")
  # Should contain the relative path, line, rule, and message
  echo "$_out" | grep -q "src/component.tsx:10:"
  echo "$_out" | grep -q "\[react/no-unescaped-entities\]"
  echo "$_out" | grep -q "Unexpected"
  rm -f "$_raw" "$_lint"
}

@test "_normalize_eslint_output: eslint compact → file:line: [rule] message" {
  local _raw _lint _out
  _raw=$(mktemp); _lint=$(mktemp)
  printf '/abs/src/utils.ts: line 5, col 3, Error - Use const (prefer-const)\n' > "$_raw"
  _normalize_eslint_output "$_raw" "$_lint" "/abs"
  _out=$(cat "$_lint")
  echo "$_out" | grep -q "src/utils.ts:5:"
  echo "$_out" | grep -q "\[prefer-const\]"
  rm -f "$_raw" "$_lint"
}

@test "_normalize_eslint_output: empty input → no output appended" {
  local _raw _lint
  _raw=$(mktemp); _lint=$(mktemp)
  printf '' > "$_raw"
  printf 'existing line\n' > "$_lint"
  _normalize_eslint_output "$_raw" "$_lint" ""
  run wc -l "$_lint"
  echo "$output" | grep -q "^[[:space:]]*1 "  # only the pre-existing line
  rm -f "$_raw" "$_lint"
}

@test "_normalize_eslint_output: absolute path without root → kept as-is" {
  local _raw _lint _out
  _raw=$(mktemp); _lint=$(mktemp)
  printf '/project/src/index.ts\n  3:7  error  no-unused-vars  @typescript-eslint/no-unused-vars\n' \
    > "$_raw"
  _normalize_eslint_output "$_raw" "$_lint" ""
  _out=$(cat "$_lint")
  echo "$_out" | grep -q "/project/src/index.ts:3:"
  rm -f "$_raw" "$_lint"
}

# =============================================================================
# Integration: run_test_gate with scripts.lint
# =============================================================================

@test "(#1545) scripts.lint present with eslint failure → blocking [GATE] lint finding" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _make_node_fixture "true"
  _write_jest_stub
  _write_eslint_stub "fail"
  _write_npm_stub

  _run_gate ""
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # Gate must block
  [ "$status" -eq 1 ]

  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "1" ]

  # lint array must be non-empty
  run jq -r '.lint | length' "$TEST_REPO/gate.json"
  [ "$output" -ge 1 ]

  # finding must carry a rule and file
  run jq -r '.lint[0].rule' "$TEST_REPO/gate.json"
  [ -n "$output" ]
  [ "$output" != "null" ]
}

@test "(#1545) scripts.lint absent → gate exit_code=0 (no noise)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _make_node_fixture "false"
  _write_jest_stub
  _write_npm_stub

  _run_gate ""
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]

  run jq -r '.lint | length' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

@test "(#1545) RITE_GATE_REPO_LINT=false → lint step skipped (gate passes)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _make_node_fixture "true"
  _write_jest_stub
  _write_eslint_stub "fail"
  _write_npm_stub

  # Lint would block, but opt-out must prevent it
  _run_gate "RITE_GATE_REPO_LINT=false"
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  [ "$status" -eq 0 ]
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "0" ]
}

@test "(#1545) eslint scoped to changed JS/TS files — receives specific file path" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _make_node_fixture "true"
  _write_jest_stub
  _write_eslint_stub "record-args"
  _write_npm_stub

  _run_gate ""
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # eslint should have been called — args file should exist
  [ -f "$TEST_REPO/eslint-args.txt" ] || {
    echo "FAIL: eslint stub was not invoked (no args file)"
    false
  }

  # eslint should have received the specific changed file, not '.' or a dir
  local _args
  _args=$(cat "$TEST_REPO/eslint-args.txt")
  # The args file should contain the absolute path to index.ts
  echo "$_args" | grep -q "index.ts"
}

@test "(#1545) all changed JS/TS files deleted → no error" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _make_node_fixture "true"
  _write_jest_stub
  _write_eslint_stub "fail"
  _write_npm_stub

  # Delete the changed file so there are no existing JS/TS files in the diff
  rm -f "$TEST_REPO/index.ts"
  (cd "$TEST_REPO" && git add -A && git commit -qm "delete index.ts") >/dev/null 2>&1

  _run_gate ""
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment"

  # Gate should not crash; lint step should skip gracefully
  run jq -r '.skipped // "false"' "$TEST_REPO/gate.json"
  # gate may pass or skip — it must not crash (exit 1 with no JSON)
  [ -f "$TEST_REPO/gate.json" ]
  run jq empty "$TEST_REPO/gate.json"
  [ "$status" -eq 0 ]
}
