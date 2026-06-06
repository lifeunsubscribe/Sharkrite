#!/usr/bin/env bats
# Regression test: notifications.sh subshell state survival
#
# Live failure (2026-06-04): PRs #355/#356/#358 merged cleanly, but Phase 5
# (notifications) crashed with `EMAIL_ADDRESS: unbound variable`. The batch
# processor saw the non-zero exit and marked the merged issues as failed,
# which cascaded into dep_failed skips for #351/#352/#353.
#
# Root cause: notifications.sh exports its functions via `export -f`, but the
# locals they read (EMAIL_ADDRESS, RITE_EMAIL_FROM, etc.) are NOT exported.
# When a subshell inherits the exported functions and re-sources the file,
# the re-source guard short-circuits and the env→local mapping is skipped,
# leaving the functions referencing unbound variables under `set -u`.
#
# Fix: env→local mapping moved above the re-source guard so it runs on every
# source. The `${VAR:-default}` form makes re-evaluation idempotent.

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT
  NOTIFICATIONS="$RITE_REPO_ROOT/lib/utils/notifications.sh"
}

@test "send_email does not crash in a subshell when env vars are unset" {
  # Simulate the production failure: parent sources notifications.sh, exports
  # functions, then spawns a subshell with NONE of the email vars set.
  run bash -c '
    set -euo pipefail
    unset EMAIL_NOTIFICATION_ADDRESS EMAIL_ADDRESS RITE_EMAIL_FROM
    source "'"$NOTIFICATIONS"'"
    # Subshell re-source path — this is what crashed in production
    (
      set -euo pipefail
      source "'"$NOTIFICATIONS"'"
      send_email "subject" "body" "normal"
    )
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"EMAIL_NOTIFICATION_ADDRESS not set, skipping email"* ]]
}

@test "send_email picks up EMAIL_NOTIFICATION_ADDRESS set before source" {
  # Negative-side check: when the env var IS exported, the mapping still works
  # after the env-mapping-above-guard move.
  run bash -c '
    set -euo pipefail
    export EMAIL_NOTIFICATION_ADDRESS="test@example.com"
    unset RITE_EMAIL_FROM
    source "'"$NOTIFICATIONS"'"
    # Force re-source path to confirm idempotent mapping
    source "'"$NOTIFICATIONS"'"
    # RITE_EMAIL_FROM is empty so send_email should warn and skip (not crash)
    send_email "subject" "body" "normal"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"RITE_EMAIL_FROM not set, skipping email"* ]]
}

@test "subshell can call send_notification_all without env vars set" {
  # End-to-end of the production failure path: workflow-runner.sh calls
  # send_notification_all from a context where the email vars are unset.
  # Must complete with 0 and emit the skip warnings, not crash.
  run bash -c '
    set -euo pipefail
    unset EMAIL_NOTIFICATION_ADDRESS EMAIL_ADDRESS RITE_EMAIL_FROM SLACK_WEBHOOK
    source "'"$NOTIFICATIONS"'"
    (
      set -euo pipefail
      source "'"$NOTIFICATIONS"'"
      send_notification_all "test message" "normal"
    )
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"SLACK_WEBHOOK not set"* ]]
  [[ "$output" == *"EMAIL_NOTIFICATION_ADDRESS not set"* ]]
}
