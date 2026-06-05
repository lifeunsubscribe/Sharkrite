#!/usr/bin/env bats
# Regression test for: notifications.sh send_email unbound variable crash
#
# Bug history (2026-06-04, issue #313):
#   notifications.sh:91 used bare `$EMAIL_ADDRESS` inside send_email(). The
#   config.sh exports `EMAIL_NOTIFICATION_ADDRESS`, not `EMAIL_ADDRESS`, so the
#   two never matched. Additionally, top-level variable assignments in a sourced
#   lib file are not inherited when the function is called from an exported-function
#   context (subprocess). Under set -u, bare $EMAIL_ADDRESS crashed immediately.
#
#   Live failure: PR #302 merged successfully but the notifications phase crashed
#   afterward, causing the batch reporter to mark it as "failed" (exit 1).
#
# This test verifies:
#   1. send_email returns 0 with a clear message when EMAIL_NOTIFICATION_ADDRESS unset
#   2. send_email returns 0 with a clear message when RITE_EMAIL_FROM unset
#   3. send_email returns 0 with a success message when all vars set (AWS stubbed)
#   4. No "unbound variable" errors in any case

setup() {
  # Absolute path to the file under test
  NOTIFICATIONS_SH="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/lib/utils/notifications.sh"

  # Scratch dir for test artifacts
  export RITE_TEST_ROOT="${BATS_TEST_TMPDIR}/notifications-test"
  mkdir -p "$RITE_TEST_ROOT"

  # Minimal stub for gh_safe so sourcing notifications.sh doesn't fail when
  # gh-retry.sh is unavailable. Export it so it's available in subshells.
  gh_safe() { true; }
  export -f gh_safe
}

teardown() {
  rm -rf "$RITE_TEST_ROOT"
}

# ---------------------------------------------------------------------------
# Helper: run send_email in a fresh subshell with controlled env
# ---------------------------------------------------------------------------

_run_send_email() {
  # Usage: _run_send_email [VAR=value ...] subject message [urgency]
  # Runs send_email in a subshell that sources notifications.sh.
  # Extra VAR=value pairs are exported into the subshell environment.
  # Captures output in $output and exit status in $status (via bats `run`).
  local env_vars=()
  while [[ "$1" == *"="* ]]; do
    env_vars+=("$1")
    shift
  done
  local subject="$1"
  local message="$2"
  local urgency="${3:-normal}"

  # Write a small driver script so we get a clean environment
  local driver="$RITE_TEST_ROOT/driver-$BATS_TEST_NUMBER.sh"
  {
    printf '#!/bin/bash\nset -euo pipefail\n'
    # Export any extra vars from the test (only if non-empty)
    if [ "${#env_vars[@]}" -gt 0 ]; then
      printf 'export %s\n' "${env_vars[@]}"
    fi
    printf 'gh_safe() { true; }\nexport -f gh_safe\n'
    printf 'aws() {\n  echo "aws-called: $*"\n  return 0\n}\nexport -f aws\n'
    printf 'source "%s"\n' "$NOTIFICATIONS_SH"
    printf 'send_email "%s" "%s" "%s"\n' "$subject" "$message" "$urgency"
  } > "$driver"
  chmod +x "$driver"
  run bash "$driver"
}

# ---------------------------------------------------------------------------
# Test 1: No env vars set — must skip gracefully, return 0
# ---------------------------------------------------------------------------

@test "send_email: no env vars set — skips with EMAIL_NOTIFICATION_ADDRESS message, exit 0" {
  _run_send_email "Test Subject" "Test message body"

  # Must exit 0 (graceful skip, not crash)
  [ "$status" -eq 0 ]

  # Must print the right skip message
  [[ "$output" == *"EMAIL_NOTIFICATION_ADDRESS not set, skipping email"* ]]

  # Must NOT print "unbound variable"
  [[ "$output" != *"unbound variable"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: EMAIL_NOTIFICATION_ADDRESS set but RITE_EMAIL_FROM unset — skip gracefully
# ---------------------------------------------------------------------------

@test "send_email: EMAIL_NOTIFICATION_ADDRESS set, RITE_EMAIL_FROM unset — skips gracefully, exit 0" {
  _run_send_email \
    "EMAIL_NOTIFICATION_ADDRESS=test@example.com" \
    "Test Subject" "Test message body"

  [ "$status" -eq 0 ]
  [[ "$output" == *"RITE_EMAIL_FROM not set, skipping email"* ]]
  [[ "$output" != *"unbound variable"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: All vars set — aws stubbed to succeed — must send and return 0
# ---------------------------------------------------------------------------

@test "send_email: all vars set, aws stubbed to succeed — returns 0 with success message" {
  _run_send_email \
    "EMAIL_NOTIFICATION_ADDRESS=recipient@example.com" \
    "RITE_EMAIL_FROM=noreply@example.com" \
    "Test Subject" "Test message body"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Email sent to recipient@example.com"* ]]
  [[ "$output" != *"unbound variable"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: Urgent flag prepends subject prefix
# ---------------------------------------------------------------------------

@test "send_email: urgent flag — subject prefixed with URGENT" {
  _run_send_email \
    "EMAIL_NOTIFICATION_ADDRESS=recipient@example.com" \
    "RITE_EMAIL_FROM=noreply@example.com" \
    "Test Subject" "Test message body" "urgent"

  [ "$status" -eq 0 ]
  # The aws call should have received the urgent-prefixed subject
  [[ "$output" == *"URGENT: Test Subject"* ]] || [[ "$output" == *"aws-called:"*"URGENT"* ]]
  [[ "$output" != *"unbound variable"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: send_notification_all doesn't crash with no env vars (full-stack path)
# ---------------------------------------------------------------------------

@test "send_notification_all: no env vars — completes without crash, exit 0" {
  local driver="$RITE_TEST_ROOT/driver-full-$BATS_TEST_NUMBER.sh"
  cat > "$driver" <<'DRIVER'
#!/bin/bash
set -euo pipefail
gh_safe() { true; }
export -f gh_safe
aws() { return 0; }
export -f aws
DRIVER
  # Append the source path after heredoc to avoid quoting issues
  echo "source \"$NOTIFICATIONS_SH\"" >> "$driver"
  echo 'send_notification_all "Workflow completed for issue #42" "normal"' >> "$driver"
  chmod +x "$driver"

  run bash "$driver"

  # Full-stack call must not crash
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
}

# ---------------------------------------------------------------------------
# Test 6: Confirm fix — the variable name mismatch is resolved
# ---------------------------------------------------------------------------

@test "notifications.sh: references EMAIL_NOTIFICATION_ADDRESS not EMAIL_ADDRESS in send_email" {
  # Verify the source file does NOT use the old wrong variable name inside send_email()
  # Extract the send_email function body and check it doesn't contain bare $EMAIL_ADDRESS
  run bash -c "
    # Extract lines between send_email() and the closing }
    awk '/^send_email\(\)/{ found=1 } found{ print } found && /^\}$/{ exit }' \"$NOTIFICATIONS_SH\"
  "
  [ "$status" -eq 0 ]

  # The function body must reference EMAIL_NOTIFICATION_ADDRESS (correct)
  [[ "$output" == *"EMAIL_NOTIFICATION_ADDRESS"* ]]

  # The function body must NOT contain the old wrong bare \$EMAIL_ADDRESS reference
  # (it's OK for it to appear in a comment, but not as a live variable reference)
  local bare_ref_lines
  bare_ref_lines=$(echo "$output" | grep -v '^\s*#' | grep '\$EMAIL_ADDRESS[^_]' || true)
  [ -z "$bare_ref_lines" ]
}
