#!/usr/bin/env bats
# Tests for Rule 22: BARE_VAR_REFERENCE
#
# Verifies that the lint rule correctly flags bare $VAR references for optional
# config-style environment variables in lib/utils/*.sh files, and correctly
# passes files that use the ${VAR:-} safe-default form or suppression comments.
#
# Fixture injection:
#   Fixtures are written to lib/utils/test-fixtures-temp-r22/ so that Rule 22's
#   find command (which scans lib/utils/ directly) picks them up. The
#   test-fixtures-temp pattern is excluded from all other lint rules via the
#   main scan's "! -path" predicate. Fixtures are removed in teardown().
#
# Bug context (issue #313):
#   notifications.sh used bare $EMAIL_ADDRESS inside send_email(). When the
#   function was called from a subshell (via export -f), top-level variable
#   assignments were not in scope, causing "unbound variable" crashes under set -u.

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  # Fixture directory — must live under lib/utils/ so Rule 22's find command
  # picks it up. Rule 22 builds UTILS_FILES by scanning lib/utils/ directly;
  # RITE_LINT_EXTRA_DIRS only affects the main SHELL_FILES list and has no
  # effect on UTILS_FILES. The test-fixtures-temp pattern ensures the main
  # scan's exclusion predicate (! -path "*/test-fixtures-temp*") keeps these
  # fixtures out of all other lint rules.
  FIXTURE_DIR="${PROJECT_ROOT}/lib/utils/test-fixtures-temp-r22"
  mkdir -p "$FIXTURE_DIR"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

# Helper: write a fixture to lib/utils/test-fixtures-temp-r22/ and run lint.
_run_lint_with_fixture() {
  local name="$1"
  local content="$2"
  printf '%s\n' "$content" > "$FIXTURE_DIR/${name}.sh"
  run bash "$LINT_SCRIPT"
}

# ---------------------------------------------------------------------------
# Should FIRE (violations) — bare $VAR for config-style vars
# ---------------------------------------------------------------------------

@test "rule fires: bare \$EMAIL_ADDRESS reference (wrong name + unsafe)" {
  _run_lint_with_fixture "bad-email-address" '#!/bin/bash
set -euo pipefail
if declare -f check_email >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
check_email() {
  if [ -z "$EMAIL_ADDRESS" ]; then
    echo "not set"
  fi
}'

  [[ "$output" == *"BARE_VAR_REFERENCE"* ]]
  [[ "$output" == *"bad-email-address"* ]]
}

@test "rule fires: bare \$SLACK_WEBHOOK reference inside function" {
  _run_lint_with_fixture "bad-slack-webhook" '#!/bin/bash
set -euo pipefail
if declare -f check_slack >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
check_slack() {
  curl -X POST "$SLACK_WEBHOOK" -d "{}"
}'

  [[ "$output" == *"BARE_VAR_REFERENCE"* ]]
  [[ "$output" == *"bad-slack-webhook"* ]]
}

@test "rule fires: bare \$RITE_EMAIL_FROM reference" {
  _run_lint_with_fixture "bad-rite-email-from" '#!/bin/bash
set -euo pipefail
if declare -f check_from >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
check_from() {
  aws ses send-email --from "$RITE_EMAIL_FROM" --to "x@y.com"
}'

  [[ "$output" == *"BARE_VAR_REFERENCE"* ]]
  [[ "$output" == *"bad-rite-email-from"* ]]
}

@test "rule fires: bare \$AWS_PROFILE reference" {
  _run_lint_with_fixture "bad-aws-profile" '#!/bin/bash
set -euo pipefail
if declare -f check_aws >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
check_aws() {
  aws sts get-caller-identity --profile "$AWS_PROFILE"
}'

  [[ "$output" == *"BARE_VAR_REFERENCE"* ]]
  [[ "$output" == *"bad-aws-profile"* ]]
}

# ---------------------------------------------------------------------------
# Should PASS — safe ${VAR:-} form or suppression comment
# ---------------------------------------------------------------------------

@test "rule passes: \${EMAIL_NOTIFICATION_ADDRESS:-} safe form" {
  _run_lint_with_fixture "good-email-notification" '#!/bin/bash
set -euo pipefail
if declare -f check_email >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
check_email() {
  if [ -z "${EMAIL_NOTIFICATION_ADDRESS:-}" ]; then
    echo "not set"
    return 0
  fi
  echo "sending to ${EMAIL_NOTIFICATION_ADDRESS:-}"
}'

  local r22_lines
  r22_lines=$(echo "$output" | grep "BARE_VAR_REFERENCE" || true)
  [[ "$r22_lines" != *"good-email-notification"* ]]
}

@test "rule passes: \${RITE_EMAIL_FROM:-} safe form" {
  _run_lint_with_fixture "good-rite-email-from" '#!/bin/bash
set -euo pipefail
if declare -f check_from >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
check_from() {
  if [ -z "${RITE_EMAIL_FROM:-}" ]; then
    return 0
  fi
  aws ses send-email --from "${RITE_EMAIL_FROM:-}" --to "x@y.com"
}'

  local r22_lines
  r22_lines=$(echo "$output" | grep "BARE_VAR_REFERENCE" || true)
  [[ "$r22_lines" != *"good-rite-email-from"* ]]
}

@test "rule passes: \${AWS_PROFILE:-default} safe form with default value" {
  _run_lint_with_fixture "good-aws-profile-default" '#!/bin/bash
set -euo pipefail
if declare -f check_aws >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
check_aws() {
  aws sts get-caller-identity --profile "${AWS_PROFILE:-default}"
}'

  local r22_lines
  r22_lines=$(echo "$output" | grep "BARE_VAR_REFERENCE" || true)
  [[ "$r22_lines" != *"good-aws-profile-default"* ]]
}

@test "rule passes: suppression comment on preceding line" {
  _run_lint_with_fixture "good-suppressed" '#!/bin/bash
set -euo pipefail
if declare -f check_suppressed >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
check_suppressed() {
  # sharkrite-lint disable BARE_VAR_REFERENCE - guard-checked with ${:-} on preceding line; safe here
  if [ -z "$SLACK_WEBHOOK" ]; then
    return 0
  fi
}'

  local r22_lines
  r22_lines=$(echo "$output" | grep "BARE_VAR_REFERENCE" || true)
  [[ "$r22_lines" != *"good-suppressed"* ]]
}

@test "rule passes: bare reference in a comment line is not flagged" {
  _run_lint_with_fixture "good-comment-only" '#!/bin/bash
set -euo pipefail
if declare -f check_comment >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
# Docs: config.sh exports EMAIL_NOTIFICATION_ADDRESS not EMAIL_ADDRESS
check_comment() {
  echo "no bare refs here"
}'

  local r22_lines
  r22_lines=$(echo "$output" | grep "BARE_VAR_REFERENCE" || true)
  [[ "$r22_lines" != *"good-comment-only"* ]]
}

# ---------------------------------------------------------------------------
# Codebase sweep: notifications.sh after fix must pass Rule 22
# ---------------------------------------------------------------------------

@test "codebase: notifications.sh post-fix passes BARE_VAR_REFERENCE rule" {
  # After the fix in issue #313, running lint against the real codebase must
  # produce zero Rule 22 violations in notifications.sh. If this test fails,
  # a bare config-var reference was re-introduced (or the fix was reverted).
  rm -rf "$FIXTURE_DIR"        # ensure fixture dir is gone before scanning

  run bash "$LINT_SCRIPT"

  local r22_violations
  r22_violations=$(echo "$output" | grep "BARE_VAR_REFERENCE" | grep "notifications.sh" || true)

  if [ -n "$r22_violations" ]; then
    echo "BARE_VAR_REFERENCE violations in notifications.sh:" >&3
    echo "$r22_violations" >&3
    false
  fi
}

@test "lint rule BARE_VAR_REFERENCE is defined in sharkrite-lint.sh" {
  run grep -q "BARE_VAR_REFERENCE" "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}
