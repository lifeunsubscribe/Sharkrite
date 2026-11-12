#!/usr/bin/env bats
# sharkrite-gate-serial
# sharkrite-test-covers: lib/utils/test-gate.sh::run_test_gate
# Regression: serial lane strips BATS_TEST_TIMEOUT so a failing test does not
# wait out the full per-test ceiling.  bats-core 1.13 stalls the full ceiling
# after a failing test without --jobs (measured 2026-11-11); issue #1749.

# Empty-tree SHA — used as RITE_TEST_GATE_DIFF_BASE so all committed files
# appear as "changed" in git diff, triggering selection of our serial fixture.
_EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  _diag() { true; }
  export -f _diag 2>/dev/null || true

  _PROJ=$(mktemp -d)
  mkdir -p "$_PROJ/tests/regression" "$_PROJ/lib"

  # Minimal Makefile — sharkrite detection requires shellcheck: + lint: targets
  # (tabs, not spaces, for Makefile recipes)
  printf '.PHONY: shellcheck lint\nshellcheck:\n\t@true\nlint:\n\t@true\n' \
    > "$_PROJ/Makefile"

  # Source file that the covers header points to — must be in the diff
  touch "$_PROJ/lib/fake.sh"

  export _PROJ
}

teardown() {
  rm -rf "${_PROJ:-}"
}

# ---------------------------------------------------------------------------
# Helper: commit all files so git diff base → HEAD shows them as changed
# ---------------------------------------------------------------------------
_proj_git_commit() {
  (cd "$_PROJ" \
    && git init -q \
    && git config user.email "test@test.com" \
    && git config user.name "Test" \
    && git add . \
    && git commit -q -m "init")
}

# ---------------------------------------------------------------------------
# 1. Failing test in serial lane completes without BATS_TEST_TIMEOUT stall
# ---------------------------------------------------------------------------

@test "serial lane: failing test does not stall for BATS_TEST_TIMEOUT" {
  command -v bats >/dev/null 2>&1 || skip "bats not available"
  command -v make >/dev/null 2>&1 || skip "make not available"
  command -v git  >/dev/null 2>&1 || skip "git not available"

  # Serial-marked bats file with one failing test
  printf '%s\n%s\n%s\n%s\n' \
    '#!/usr/bin/env bats' \
    '# sharkrite-gate-serial' \
    '# sharkrite-test-covers: lib/fake.sh' \
    '@test "deliberate fail" { false; }' \
    > "$_PROJ/tests/regression/serial-failing.bats"

  _proj_git_commit

  _gate_out="$_PROJ/gate.json"
  _start=$SECONDS

  # RITE_BATS_TEST_TIMEOUT=10 → gate exports BATS_TEST_TIMEOUT=10 for the
  # parallel lane.  Without the fix the serial lane inherits it and stalls 10s.
  # With the fix the serial lane unsets it and the test exits immediately.
  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='${_PROJ}'
    export PR_NUMBER='0'
    export RITE_BATS_TEST_TIMEOUT='10'
    export RITE_TEST_GATE_DIFF_BASE='${_EMPTY_TREE}'
    export RITE_GATE_BATS_TIMEOUT='60'
    export RITE_GATE_FLAKE_RETRY='false'
    RITE_LOG_FILE=''
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    run_test_gate '${_gate_out}' '${_PROJ}'
  " 2>/dev/null
  _elapsed=$(( SECONDS - _start ))

  # Gate must report failure (the test fails)
  [ "$status" -ne 0 ]
  # Must finish well before RITE_BATS_TEST_TIMEOUT=10s — if the stall were
  # present the run would take ≥10s; with the fix it finishes in <3s.
  [ "$_elapsed" -lt 5 ]
}

# ---------------------------------------------------------------------------
# 2. Genuinely hung test in serial lane is still killed by _bats_watchdog
# ---------------------------------------------------------------------------

@test "serial lane: hung test is killed by whole-lane watchdog" {
  command -v bats >/dev/null 2>&1 || skip "bats not available"
  command -v make >/dev/null 2>&1 || skip "make not available"
  command -v git  >/dev/null 2>&1 || skip "git not available"
  # The whole-lane kill relies on gtimeout/timeout
  command -v gtimeout >/dev/null 2>&1 || command -v timeout >/dev/null 2>&1 \
    || skip "no timeout command available — whole-lane watchdog inactive"

  # Serial-marked bats file with a test that hangs
  printf '%s\n%s\n%s\n%s\n' \
    '#!/usr/bin/env bats' \
    '# sharkrite-gate-serial' \
    '# sharkrite-test-covers: lib/fake.sh' \
    '@test "hang forever" { sleep 9999; }' \
    > "$_PROJ/tests/regression/serial-hanging.bats"

  _proj_git_commit

  _gate_out="$_PROJ/gate.json"
  _start=$SECONDS

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_PROJECT_ROOT='${_PROJ}'
    export PR_NUMBER='0'
    export RITE_BATS_TEST_TIMEOUT='10'
    export RITE_TEST_GATE_DIFF_BASE='${_EMPTY_TREE}'
    export RITE_GATE_BATS_TIMEOUT='5'
    export RITE_GATE_FLAKE_RETRY='false'
    RITE_LOG_FILE=''
    _diag() { true; }
    export -f _diag 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    source '${RITE_LIB_DIR}/utils/test-gate.sh'
    run_test_gate '${_gate_out}' '${_PROJ}'
  " 2>/dev/null
  _elapsed=$(( SECONDS - _start ))

  # Gate must report failure (watchdog killed the serial bats before it finished)
  [ "$status" -ne 0 ]
  # Must complete within reasonable time: watchdog fires at 5s, allow 10s total
  [ "$_elapsed" -lt 15 ]
}

# ---------------------------------------------------------------------------
# 3. Structural: _ser_bats_sandbox unsets BATS_TEST_TIMEOUT in serial lane
# ---------------------------------------------------------------------------

@test "serial lane: _ser_bats_sandbox unsets BATS_TEST_TIMEOUT in source" {
  run grep -n 'BATS_TEST_TIMEOUT.*_ser_bats_sandbox\|_ser_bats_sandbox.*BATS_TEST_TIMEOUT' \
    "${RITE_LIB_DIR}/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BATS_TEST_TIMEOUT"* ]]
}
