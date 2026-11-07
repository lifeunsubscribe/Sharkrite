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
  # 0 = no violations, 1 = violations found; anything higher means the linter
  # failed to run (e.g. exit 127 = script not found) — files would be identical
  # trivially, so the checksum assertion would pass vacuously.
  [ "$status" -le 1 ]
  local after
  after=$(md5 -q "$LEDGER" 2>/dev/null || md5sum "$LEDGER" | awk '{print $1}')
  [ "$LEDGER_BEFORE" = "$after" ]
}

@test "project.conf.example is byte-identical after running Rule 36 in isolation" {
  SHARKRITE_LINT_ONLY=36 run bash "$LINT_SCRIPT"
  [ "$status" -le 1 ]
  local after
  after=$(md5 -q "$PROJ_CONF" 2>/dev/null || md5sum "$PROJ_CONF" | awk '{print $1}')
  [ "$PROJ_CONF_BEFORE" = "$after" ]
}

@test "rite.conf.example is byte-identical after running Rule 36 in isolation" {
  SHARKRITE_LINT_ONLY=36 run bash "$LINT_SCRIPT"
  [ "$status" -le 1 ]
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

  # Positive control: a deliberately undocumented var that MUST fire a violation.
  # Without this, the test passes vacuously if RITE_LINT_EXTRA_DIRS injection
  # or the */lib/*.sh filter regresses — the linter scans nothing, produces no
  # output, and [ -z "$violations" ] is satisfied without proving anything.
  cat > "$fixture_dir/undocumented-consumer.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
positive_control_fn() {
  echo "${RITE_UNDOCUMENTED_TEST_VAR_R36:-}"
}
EOF

  # Run with an adversarial locale to prove LC_ALL=C pins inside the linter hold.
  # If the sort -u calls lose their LC_ALL=C, a non-C collation can collapse
  # allowlist entries and produce false positives for ledgered vars like
  # RITE_CLAUDE_TIMEOUT_PROMPT — the original macOS-only CI failure (issue #1605).
  local _locale
  _locale=$(locale -a 2>/dev/null | grep -iE '^en_US\.(UTF-?8|utf8)$' | head -1 || true)
  if [ -z "$_locale" ]; then
    skip "en_US.UTF-8 locale not available — cannot test locale-pinning on this system"
  fi

  LC_ALL="$_locale" RITE_LINT_EXTRA_DIRS="${BATS_TEST_TMPDIR}/r36-isolation/lib/utils" \
    SHARKRITE_LINT_ONLY=36 run bash "$LINT_SCRIPT"

  # Positive control must fire (proves injection and filter are working).
  local positive
  positive=$(echo "$output" | grep "UNDOCUMENTED_RITE_VAR" | grep "undocumented-consumer" || true)
  [ -n "$positive" ]

  # Regressed var must NOT fire (it is in the ledger).
  local violations
  violations=$(echo "$output" | grep "UNDOCUMENTED_RITE_VAR" | grep "timeout-consumer" || true)
  [ -z "$violations" ]
}
