#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# The gate sets a per-test bats timeout (BATS_TEST_TIMEOUT) so ONE hung test
# can't stall the whole gate until the ~30-min outer backstop
# (RITE_GATE_WAIT_TIMEOUT, #654). Live trigger (2026-06-26): a self-exec'ing
# python3 wrapper made venv-bootstrap-failure-loud.bats hang, wedging the gate
# for 30 min on a single test. bats kills the test via a pkill/ps countdown — no
# GNU `timeout` command — so this works on macOS too.

setup() { export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"; }

@test "structural: gate exports BATS_TEST_TIMEOUT with a RITE override default" {
  grep -qE 'export BATS_TEST_TIMEOUT="\$\{RITE_BATS_TEST_TIMEOUT:-[0-9]+\}"' \
    "${RITE_LIB_DIR}/utils/test-gate.sh"
}

@test "structural: the timeout is exported BEFORE the first bats invocation" {
  # Must precede the bats calls so the (cd ... bats ...) subshells inherit it.
  _timeout_ln=$(grep -nE 'export BATS_TEST_TIMEOUT=' "${RITE_LIB_DIR}/utils/test-gate.sh" | head -1 | cut -d: -f1)
  # Match the real invocation string (only in actual `bats` calls, never comments).
  _first_bats_ln=$(grep -nE '\-\-report-formatter tap --output' "${RITE_LIB_DIR}/utils/test-gate.sh" | head -1 | cut -d: -f1)
  [ -n "$_timeout_ln" ]
  [ -n "$_first_bats_ln" ]
  [ "$_timeout_ln" -lt "$_first_bats_ln" ]
}

@test "behavioral: BATS_TEST_TIMEOUT actually kills a hung test on this bats" {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  _d=$(mktemp -d)
  cat > "$_d/h.bats" <<'EOF'
#!/usr/bin/env bats
@test "ok" { true; }
@test "hang" { sleep 999; }
EOF
  _start=$(date +%s)
  run env BATS_TEST_TIMEOUT=2 bats "$_d/h.bats"
  _elapsed=$(( $(date +%s) - _start ))
  rm -rf "$_d"
  # Killed fast (not the 999s sleep), and bats reported the per-test timeout.
  [ "$_elapsed" -lt 30 ]
  [[ "$output" == *"timeout after 2s"* ]]
}
