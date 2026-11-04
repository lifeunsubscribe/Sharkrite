#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/36-undocumented-rite-var-read-in-lib.sh, tools/sharkrite-lint.sh
# Regression test for Rule 36 ledger isolation.
#
# Verifies that running the Rule 36 lint fragment does NOT mutate the tracked
# ledger or config examples on disk, and that RITE_CLAUDE_TIMEOUT_PROMPT
# (the regressed variable from issue #1605) passes Rule 36 without violation.
#
# Motivation (issue #1605): a macOS-only CI failure for RITE_CLAUDE_TIMEOUT_PROMPT
# suggested possible allowlist corruption — either during the lint run itself or
# from a bats test that left the ledger in a modified state. This test makes the
# invariant checkable: the ledger must be byte-identical after any lint execution.

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"
  LEDGER="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/lint-rules/36-undocumented-rite-var.ledger"
  PROJ_CONF="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/config/project.conf.example"
  RITE_CONF="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/config/rite.conf.example"

  # Capture checksums before any lint run (computed once per test via setup()).
  LEDGER_BEFORE=$(md5 -q "$LEDGER" 2>/dev/null || md5sum "$LEDGER" | awk '{print $1}')
  PROJ_CONF_BEFORE=$(md5 -q "$PROJ_CONF" 2>/dev/null || md5sum "$PROJ_CONF" | awk '{print $1}')
  RITE_CONF_BEFORE=$(md5 -q "$RITE_CONF" 2>/dev/null || md5sum "$RITE_CONF" | awk '{print $1}')
}

@test "ledger is byte-identical after running Rule 36 in isolation" {
  SHARKRITE_LINT_ONLY=36 run bash "$LINT_SCRIPT"
  # exit status may be 0 or 1 depending on violations — only file identity matters
  local after
  after=$(md5 -q "$LEDGER" 2>/dev/null || md5sum "$LEDGER" | awk '{print $1}')
  [ "$LEDGER_BEFORE" = "$after" ]
}

@test "project.conf.example is byte-identical after running Rule 36 in isolation" {
  SHARKRITE_LINT_ONLY=36 run bash "$LINT_SCRIPT"
  local after
  after=$(md5 -q "$PROJ_CONF" 2>/dev/null || md5sum "$PROJ_CONF" | awk '{print $1}')
  [ "$PROJ_CONF_BEFORE" = "$after" ]
}

@test "rite.conf.example is byte-identical after running Rule 36 in isolation" {
  SHARKRITE_LINT_ONLY=36 run bash "$LINT_SCRIPT"
  local after
  after=$(md5 -q "$RITE_CONF" 2>/dev/null || md5sum "$RITE_CONF" | awk '{print $1}')
  [ "$RITE_CONF_BEFORE" = "$after" ]
}

@test "ledger contains RITE_CLAUDE_TIMEOUT_PROMPT (the regressed var)" {
  grep -qxF "RITE_CLAUDE_TIMEOUT_PROMPT" "$LEDGER"
}

@test "RITE_CLAUDE_TIMEOUT_PROMPT passes Rule 36 in isolation (the regressed case)" {
  # Plant a fixture that reads RITE_CLAUDE_TIMEOUT_PROMPT in a lib/ path.
  # Rule 36 must NOT fire for it since the var is in the ledger.
  local fixture_dir="${BATS_TEST_TMPDIR}/r36-isolation/lib/utils"
  mkdir -p "$fixture_dir"
  cat > "$fixture_dir/timeout-consumer.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${_RITE_R36_ISOL_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_R36_ISOL_LOADED=true
consume_timeout() {
  local t="${RITE_CLAUDE_TIMEOUT_PROMPT:-600}"
  echo "$t"
}
EOF

  RITE_LINT_EXTRA_DIRS="${BATS_TEST_TMPDIR}/r36-isolation/lib/utils" \
    SHARKRITE_LINT_ONLY=36 run bash "$LINT_SCRIPT"

  local violations
  violations=$(echo "$output" | grep "UNDOCUMENTED_RITE_VAR" | grep "timeout-consumer" || true)
  [ -z "$violations" ]
}
