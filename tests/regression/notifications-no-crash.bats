#!/usr/bin/env bats
# Regression test for: notifications.sh send_email crashes under set -u when env vars unset
#
# Bug history (2026-06-06 — issue #313):
#   send_email() referenced $EMAIL_ADDRESS (a wrong name — config exports
#   EMAIL_NOTIFICATION_ADDRESS) AND $RITE_EMAIL_FROM as bare unguarded references.
#   Under set -u, when SLACK_WEBHOOK is unset send_slack() skips gracefully, but
#   send_email() then crashed with "EMAIL_ADDRESS: unbound variable".
#   PR #302 was reported as FAILED even though the merge had already completed
#   successfully — the crash was in the post-merge notifications phase.
#
# This test verifies:
#   1. send_email returns 0 with "not set" message when EMAIL_NOTIFICATION_ADDRESS is unset
#   2. send_email returns 0 with "not set" message when RITE_EMAIL_FROM is unset
#   3. send_email does NOT crash (no "unbound variable" errors) in any case
#   4. send_email sends correctly when all required vars are set (happy path)
#   5. EMAIL_NOTIFICATION_ADDRESS (correct name) is used, not EMAIL_ADDRESS (wrong name)

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  NOTIFICATIONS_SH="$PROJECT_ROOT/lib/utils/notifications.sh"

  # Reset notification vars to ensure test isolation
  unset EMAIL_NOTIFICATION_ADDRESS EMAIL_ADDRESS RITE_EMAIL_FROM SLACK_WEBHOOK
  unset RITE_SNS_TOPIC_ARN RITE_AWS_PROFILE _RITE_NOTIFICATIONS_LOADED

  # Disable gh_safe sourcing (not needed for send_email tests)
  export RITE_LIB_DIR=""
}

teardown() {
  unset EMAIL_NOTIFICATION_ADDRESS EMAIL_ADDRESS RITE_EMAIL_FROM SLACK_WEBHOOK
  unset RITE_SNS_TOPIC_ARN RITE_AWS_PROFILE _RITE_NOTIFICATIONS_LOADED
  unset RITE_LIB_DIR
}

# ---------------------------------------------------------------------------
# Core crash-prevention tests (the regression: no "unbound variable" errors)
# ---------------------------------------------------------------------------

@test "send_email: no crash when EMAIL_NOTIFICATION_ADDRESS is unset" {
  # This was the crash scenario from issue #313.
  # Previously: "EMAIL_ADDRESS: unbound variable" → exit 1
  # After fix: graceful skip → exit 0
  run bash -c "
    set -euo pipefail
    source '$NOTIFICATIONS_SH'
    send_email 'Test Subject' 'Test message'
  "

  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "unbound variable" ]]
}

@test "send_email: returns 0 with skip message when EMAIL_NOTIFICATION_ADDRESS is unset" {
  run bash -c "
    set -euo pipefail
    source '$NOTIFICATIONS_SH'
    send_email 'Test Subject' 'Test message'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "EMAIL_NOTIFICATION_ADDRESS not set" ]]
}

@test "send_email: returns 0 with skip message when RITE_EMAIL_FROM is unset" {
  run bash -c "
    set -euo pipefail
    export EMAIL_NOTIFICATION_ADDRESS='test@example.com'
    source '$NOTIFICATIONS_SH'
    send_email 'Test Subject' 'Test message'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "RITE_EMAIL_FROM not set" ]]
  [[ ! "$output" =~ "unbound variable" ]]
}

@test "send_email: does NOT crash under set -u with no env vars exported at all" {
  # Worst case: completely clean environment — no SLACK_WEBHOOK, no EMAIL vars, nothing
  run bash -c "
    set -euo pipefail
    source '$NOTIFICATIONS_SH'
    send_email 'Subject' 'Body'
    echo 'REACHED_END'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "REACHED_END" ]]
}

# ---------------------------------------------------------------------------
# Correct variable name test: EMAIL_NOTIFICATION_ADDRESS, not EMAIL_ADDRESS
# ---------------------------------------------------------------------------

@test "send_email: uses EMAIL_NOTIFICATION_ADDRESS (not EMAIL_ADDRESS) as the check" {
  # If the OLD wrong name were still used, setting EMAIL_NOTIFICATION_ADDRESS would
  # be ignored (the check would still see the module alias as unset).
  # After the fix: setting EMAIL_NOTIFICATION_ADDRESS makes the check pass, but
  # RITE_EMAIL_FROM is still missing so it prints the RITE_EMAIL_FROM skip message.
  run bash -c "
    set -euo pipefail
    export EMAIL_NOTIFICATION_ADDRESS='recipient@example.com'
    source '$NOTIFICATIONS_SH'
    send_email 'Test' 'Body'
  "

  # Should reach RITE_EMAIL_FROM check (not stop at EMAIL_NOTIFICATION_ADDRESS)
  [ "$status" -eq 0 ]
  [[ "$output" =~ "RITE_EMAIL_FROM not set" ]]
  # Must NOT show EMAIL_NOTIFICATION_ADDRESS skip (we set it)
  [[ ! "$output" =~ "EMAIL_NOTIFICATION_ADDRESS not set" ]]
}

@test "send_email: setting EMAIL_ADDRESS (wrong old name) does NOT satisfy the check" {
  # Verify the fix: only EMAIL_NOTIFICATION_ADDRESS (correct name) is checked.
  # Setting the wrong name EMAIL_ADDRESS should not bypass the skip.
  run bash -c "
    set -euo pipefail
    export EMAIL_ADDRESS='wrong@example.com'
    source '$NOTIFICATIONS_SH'
    send_email 'Test' 'Body'
  "

  [ "$status" -eq 0 ]
  # Should print the EMAIL_NOTIFICATION_ADDRESS not-set message, not proceed
  [[ "$output" =~ "EMAIL_NOTIFICATION_ADDRESS not set" ]]
}

# ---------------------------------------------------------------------------
# Happy path: all vars set → reaches AWS SES call
# (AWS CLI itself may not be available; we just verify send_email doesn't
#  crash BEFORE the aws command — the aws call itself may fail gracefully)
# ---------------------------------------------------------------------------

@test "send_email: with all vars set, no 'unbound variable' crash before AWS call" {
  run bash -c "
    set -euo pipefail
    export EMAIL_NOTIFICATION_ADDRESS='recipient@example.com'
    export RITE_EMAIL_FROM='sender@example.com'
    source '$NOTIFICATIONS_SH'
    # Stub aws to return success
    aws() { echo 'aws-stub: \$*'; return 0; }
    export -f aws
    send_email 'Hello' 'World'
    echo 'REACHED_END'
  "

  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "unbound variable" ]]
  [[ "$output" =~ "REACHED_END" ]]
  # Should print success
  [[ "$output" =~ "Email sent to recipient@example.com" ]]
}

@test "send_email: with urgent flag, adds URGENT prefix to subject" {
  run bash -c "
    set -euo pipefail
    export EMAIL_NOTIFICATION_ADDRESS='r@example.com'
    export RITE_EMAIL_FROM='s@example.com'
    source '$NOTIFICATIONS_SH'
    aws() {
      # Capture the --subject arg to verify urgency prefix
      while [ \$# -gt 0 ]; do
        if [ \"\$1\" = '--subject' ]; then echo \"SUBJECT:\$2\"; fi
        shift
      done
      return 0
    }
    export -f aws
    send_email 'My Subject' 'Body' 'urgent'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "URGENT" ]]
}

# ---------------------------------------------------------------------------
# send_notification_all: integration — all channels skip gracefully when unset
# ---------------------------------------------------------------------------

@test "send_notification_all: no crash when all notification channels are unset" {
  run bash -c "
    set -euo pipefail
    source '$NOTIFICATIONS_SH'
    send_notification_all 'Test message' 'normal'
    echo 'REACHED_END'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "REACHED_END" ]]
  [[ ! "$output" =~ "unbound variable" ]]
}
