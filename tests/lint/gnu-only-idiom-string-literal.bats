#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/39-gnu-only-idioms.sh, tools/sharkrite-lint.sh
# Rule 39F string-literal false-positive tests (#1504).
#
# Rule 39F fires when 'timeout N' appears in command position.  Before #1504 the
# check was naive: 'timeout' inside a quoted message string (e.g. printf "failed
# (timeout 30s)") matched the same token pattern and triggered a violation that
# no code change could honestly fix — the linter was describing string content,
# not a bare command invocation.  These tests pin the corrected behaviour.

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/string-literal-fixtures"
  mkdir -p "$FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
  unset RITE_LINT_EXTRA_DIRS
}

_run_lint() {
  local name="$1" content="$2"
  printf '%s\n' "$content" > "$FIXTURE_DIR/${name}.sh"
  SHARKRITE_LINT_ONLY=39 run bash "$LINT_SCRIPT"
}

# ===========================================================================
# 39F — false-positive cases: 'timeout' in string content must NOT fire
# ===========================================================================

@test "39F passes: printf with 'timeout Ns' inside double-quoted message string" {
  _run_lint "fp-printf-dq-timeout" '#!/usr/bin/env bash
set -euo pipefail
printf "failed to acquire lock (timeout 30s)\n" >&2'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"fp-printf-dq-timeout"* ]]
}

@test "39F passes: echo with 'timeout Ns' preceded by space inside double-quoted string" {
  _run_lint "fp-echo-dq-timeout" '#!/usr/bin/env bash
set -euo pipefail
echo "retry after timeout 30s exceeded"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"fp-echo-dq-timeout"* ]]
}

@test "39F passes: printf '%s\\n' with double-quoted arg containing '(timeout Ns)'" {
  # The format string is single-quoted; the message arg is double-quoted.
  # Both string types must be stripped before the command-position check.
  _run_lint "fp-printf-sq-fmt-dq-msg" '#!/usr/bin/env bash
set -euo pipefail
printf '"'"'%s\n'"'"' "Could not acquire lock (timeout 30s)" >&2'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"fp-printf-sq-fmt-dq-msg"* ]]
}

@test "39F passes: live-failure shape — drift-log.sh:293 pre-reword lock-failure printf (#1504)" {
  # Reproduces the pre-reword form of lib/utils/drift-log.sh:293 that caused a
  # false positive during the 2026-10-26 doc-sync batch run (#1504).  The fix
  # at the time was to reword the message; this test ensures no future message
  # string triggers the rule again.
  _run_lint "fp-drift-log-293-preword" '#!/usr/bin/env bash
set -euo pipefail
drift_log_union_merge() {
  local _dlm_path="${1:-}"
  [ -n "$_dlm_path" ] || return 1
  [ -f "$_dlm_path" ] || return 1
  printf "failed to acquire exclusive lock (timeout 30s)\n" >&2
  return 1
}'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"fp-drift-log-293-preword"* ]]
}

@test "39F passes: comment line containing 'timeout Ns' does not fire" {
  _run_lint "fp-comment-timeout" '#!/usr/bin/env bash
set -euo pipefail
# retry with timeout 30s if the first attempt fails
echo "done"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"fp-comment-timeout"* ]]
}

# ===========================================================================
# 39F — genuine violations: bare timeout in command position MUST fire
# ===========================================================================

@test "39F fires: genuine bare 'timeout 30 cmd' in command position" {
  _run_lint "tp-bare-timeout-cmd" '#!/usr/bin/env bash
set -euo pipefail
timeout 30 some_command >/dev/null 2>&1'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" == *"tp-bare-timeout-cmd"* ]]
}

@test "39F fires: bare timeout inside if-condition is still detected" {
  _run_lint "tp-bare-timeout-if" '#!/usr/bin/env bash
set -euo pipefail
if timeout 10 git fetch --prune origin >/dev/null 2>&1; then
  echo "fetched"
fi'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" == *"tp-bare-timeout-if"* ]]
}

@test "39F fires: timeout inside double-quoted command substitution VAR=\"\$(timeout N cmd)\" detected" {
  # Regression for the canonical capture idiom VAR="$(timeout 30 cmd)".
  # Before the "$(...)" unwrap step, the double-quote stripper erased the entire
  # "$(timeout 30 some_command)" block, producing a false negative (#1504).
  _run_lint "tp-dq-cmdsub-timeout" '#!/usr/bin/env bash
set -euo pipefail
RESULT="$(timeout 30 some_command)"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" == *"tp-dq-cmdsub-timeout"* ]]
}

# ===========================================================================
# 39F — existing guards still pass (regression protection)
# ===========================================================================

@test "39F passes: run_with_timeout portable wrapper is not flagged" {
  _run_lint "guard-run-with-timeout" '#!/usr/bin/env bash
set -euo pipefail
run_with_timeout 30 some_command >/dev/null 2>&1'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"guard-run-with-timeout"* ]]
}

@test "39F passes: timeout guarded by command -v timeout on preceding line" {
  _run_lint "guard-command-v-timeout" '#!/usr/bin/env bash
set -euo pipefail
if command -v timeout >/dev/null 2>&1; then
  timeout 30 long_cmd
fi'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"guard-command-v-timeout"* ]]
}

# ===========================================================================
# 39B — false-positive case: 'sed \u' in a message string must NOT fire
# ===========================================================================

@test "39B passes: message string containing 'sed \\u' does not fire" {
  # Before the _r39_strip_quoted guard was applied to 39B, a double-quoted
  # message string containing 'sed \u' (e.g. a help text or error message)
  # would produce an unfixable false positive — the same #1504 failure mode
  # fixed for 39A and 39F (#1504).
  _run_lint "fp-39b-sed-u-string" '#!/usr/bin/env bash
set -euo pipefail
echo "use sed \u for uppercase conversion (GNU only, not portable)"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"fp-39b-sed-u-string"* ]]
}
