#!/usr/bin/env bats
# sharkrite-test-covers: tools/*-lint.sh
# Tests for Rule 23: BARE_VAR_REFERENCE
#
# Verifies that the lint rule correctly flags bare $VAR references for optional
# config variables (EMAIL_*, SLACK_*, RITE_EMAIL_*, AWS_*) in lib/utils/*.sh,
# and passes on safe ${VAR:-} expansions and properly suppressed lines.
#
# Bug context (issue #313, 2026-06-06):
#   notifications.sh send_email() referenced $EMAIL_ADDRESS (bare, wrong name)
#   and $RITE_EMAIL_FROM (bare). Under set -u, these crashed the post-merge
#   notifications phase, causing PR #302 to be reported as failed even though
#   the merge had already completed successfully.
#
# Fixture injection:
#   Fixtures are written into BATS_TEST_TMPDIR and injected via
#   RITE_LINT_EXTRA_DIRS so the linter scans them without touching the
#   project's own lib/ tree. Each test creates a lib/utils/-structured dir
#   so the rule (scoped to lib/utils/*.sh) fires correctly.

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  # Fixture directory: mimic lib/utils/ structure so Rule 23 fires
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/bare-var-ref-fixtures/lib/utils"
  mkdir -p "$FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="${BATS_TEST_TMPDIR}/bare-var-ref-fixtures/lib/utils"
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR}/bare-var-ref-fixtures"
  unset RITE_LINT_EXTRA_DIRS
}

# Helper: write a fixture file and run lint, returning $output and $status.
_run_lint_with_fixture() {
  local name="$1"
  local content="$2"
  printf '%s\n' "$content" > "$FIXTURE_DIR/${name}.sh"
  run bash "$LINT_SCRIPT"
}

# ---------------------------------------------------------------------------
# Should FIRE (violations)
# ---------------------------------------------------------------------------

@test "rule fires: bare \$EMAIL_ADDRESS in lib/utils script" {
  _run_lint_with_fixture "bad-email-address" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_BAD_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_BAD_LOADED=true

send_email() {
  if [ -z "$EMAIL_ADDRESS" ]; then
    echo "skip"
    return 0
  fi
}'

  [[ "$output" == *"BARE_VAR_REFERENCE"* ]]
}

@test "rule fires: bare \$RITE_EMAIL_FROM in lib/utils script" {
  _run_lint_with_fixture "bad-rite-email-from" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_BAD2_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_BAD2_LOADED=true

send_email() {
  if [ -z "$RITE_EMAIL_FROM" ]; then
    echo "skip"
    return 0
  fi
}'

  [[ "$output" == *"BARE_VAR_REFERENCE"* ]]
}

@test "rule fires: bare \$SLACK_WEBHOOK in lib/utils script" {
  _run_lint_with_fixture "bad-slack-webhook" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_BAD3_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_BAD3_LOADED=true

send_slack() {
  curl -X POST "$SLACK_WEBHOOK" -d "hello"
}'

  [[ "$output" == *"BARE_VAR_REFERENCE"* ]]
}

@test "rule fires: bare \$AWS_PROFILE in lib/utils script" {
  _run_lint_with_fixture "bad-aws-profile" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_BAD4_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_BAD4_LOADED=true

do_aws() {
  aws --profile "$AWS_PROFILE" s3 ls
}'

  [[ "$output" == *"BARE_VAR_REFERENCE"* ]]
}

# ---------------------------------------------------------------------------
# Should PASS (no violations from this rule)
# ---------------------------------------------------------------------------

@test "rule passes: \${EMAIL_NOTIFICATION_ADDRESS:-} safe expansion" {
  _run_lint_with_fixture "good-email-safe" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_GOOD1_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_GOOD1_LOADED=true

send_email() {
  if [ -z "${EMAIL_NOTIFICATION_ADDRESS:-}" ]; then
    echo "EMAIL_NOTIFICATION_ADDRESS not set, skipping email"
    return 0
  fi
}'

  local r23_lines
  r23_lines=$(echo "$output" | grep "BARE_VAR_REFERENCE" || true)
  [[ "$r23_lines" != *"good-email-safe"* ]]
}

@test "rule passes: \${RITE_EMAIL_FROM:-} safe expansion" {
  _run_lint_with_fixture "good-rite-email-safe" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_GOOD2_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_GOOD2_LOADED=true

send_email() {
  if [ -z "${RITE_EMAIL_FROM:-}" ]; then
    echo "RITE_EMAIL_FROM not set, skipping email"
    return 0
  fi
}'

  local r23_lines
  r23_lines=$(echo "$output" | grep "BARE_VAR_REFERENCE" || true)
  [[ "$r23_lines" != *"good-rite-email-safe"* ]]
}

@test "rule passes: \${AWS_PROFILE:-default} safe expansion with default" {
  _run_lint_with_fixture "good-aws-default" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_GOOD3_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_GOOD3_LOADED=true

do_aws() {
  aws --profile "${AWS_PROFILE:-default}" s3 ls
}'

  local r23_lines
  r23_lines=$(echo "$output" | grep "BARE_VAR_REFERENCE" || true)
  [[ "$r23_lines" != *"good-aws-default"* ]]
}

@test "rule passes: suppression comment on preceding line" {
  _run_lint_with_fixture "good-suppressed" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_GOOD4_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_GOOD4_LOADED=true

SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

send_slack() {
  # sharkrite-lint disable BARE_VAR_REFERENCE - module-local alias initialized safely at module load
  if [ -z "$SLACK_WEBHOOK" ]; then
    echo "skip"
    return 0
  fi
}'

  local r23_lines
  r23_lines=$(echo "$output" | grep "BARE_VAR_REFERENCE" || true)
  [[ "$r23_lines" != *"good-suppressed"* ]]
}

@test "rule passes: comment-only line with var name (full-line comment)" {
  _run_lint_with_fixture "good-comment-only" '#!/bin/bash
set -euo pipefail

if [ "${_RITE_GOOD5_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_GOOD5_LOADED=true

# Uses EMAIL_NOTIFICATION_ADDRESS — set by config.sh
send_email() {
  echo "body"
}'

  local r23_lines
  r23_lines=$(echo "$output" | grep "BARE_VAR_REFERENCE" || true)
  [[ "$r23_lines" != *"good-comment-only"* ]]
}

# ---------------------------------------------------------------------------
# Codebase sweep: notifications.sh after the fix passes Rule 23
# ---------------------------------------------------------------------------

@test "codebase: notifications.sh has zero BARE_VAR_REFERENCE violations after fix" {
  # After the fix in issue #313, running lint against the real codebase must
  # produce zero Rule 23 violations. If this test fails, a bare config-var
  # reference was introduced in lib/utils/ without safe expansion.
  unset RITE_LINT_EXTRA_DIRS   # scan only the project tree, not fixtures

  run bash "$LINT_SCRIPT"

  local r23_violations
  r23_violations=$(echo "$output" | grep "BARE_VAR_REFERENCE" || true)

  if [ -n "$r23_violations" ]; then
    echo "BARE_VAR_REFERENCE violations found:" >&3
    echo "$r23_violations" >&3
    false
  fi
}

@test "lint rule BARE_VAR_REFERENCE is defined in sharkrite-lint.sh" {
  run grep -q "BARE_VAR_REFERENCE" "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}
