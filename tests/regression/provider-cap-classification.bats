#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh::_claude_classify_exit, lib/core/local-review.sh

# Regression test for: Detect usage caps on all provider call paths (#1613)
#
# Verifies that:
#  1. _claude_classify_exit() is the shared helper (phrase list in one place,
#     "out of usage credits" among them).
#  2. All five non-agentic runners produce exit 5 on a cap phrase and exit 18
#     on an auth phrase, scanning both stdout and stderr.
#  3. False-abort guard: a successful call (exit 0) that quotes a cap phrase in
#     its output is never misclassified — the caller gets 0.
#  4. The agentic runner still classifies cap/auth correctly for the phrases it
#     already matched before this change (regression guard).
#
# Strategy: replace the claude CLI with tiny fixture scripts that emit a known
# phrase on stdout or stderr and exit with a controlled code.

RITE_LIB="${BATS_TEST_DIRNAME}/../../lib"

# ---------------------------------------------------------------------------
# Helpers shared across tests
# ---------------------------------------------------------------------------

_make_shim_dir() {
  SHIM_DIR=$(mktemp -d)
  export SHIM_DIR
}

_write_shim() {
  local phrase="$1"
  local channel="${2:-stdout}"   # stdout | stderr
  local exit_code="${3:-1}"
  local shim="${SHIM_DIR}/claude"
  if [ "$channel" = "stderr" ]; then
    cat > "$shim" <<SHIM
#!/bin/bash
echo "$phrase" >&2
exit $exit_code
SHIM
  else
    cat > "$shim" <<SHIM
#!/bin/bash
echo "$phrase"
exit $exit_code
SHIM
  fi
  chmod +x "$shim"
}

setup() {
  export RITE_LIB_DIR="$RITE_LIB"
  _make_shim_dir
  export PATH="${SHIM_DIR}:${PATH}"
  export RITE_CLAUDE_TIMEOUT_PROMPT=30
  export RITE_CLAUDE_TIMEOUT_AGENTIC=30

  source "${RITE_LIB}/utils/timeout.sh"
  ensure_timeout_cmd

  CLAUDE_PROVIDER_CMD="${SHIM_DIR}/claude"
  export CLAUDE_PROVIDER_CMD

  source "${RITE_LIB}/providers/claude.sh"
  set +u; set +o pipefail
}

teardown() {
  rm -rf "${SHIM_DIR:-}"
}

# ---------------------------------------------------------------------------
# 1. Shared helper: phrase list includes "out of usage credits"
# ---------------------------------------------------------------------------

@test "_claude_classify_exit: shared helper exists as a function" {
  declare -f _claude_classify_exit >/dev/null 2>&1
}

@test "_claude_classify_exit: 'out of usage credits' on stdout returns 5" {
  local _out _err
  _out=$(mktemp); _err=$(mktemp)
  printf 'out of usage credits\n' > "$_out"
  : > "$_err"
  result=$(_claude_classify_exit "$_out" "$_err" 1)
  rm -f "$_out" "$_err"
  [ "$result" -eq 5 ]
}

@test "_claude_classify_exit: 'out of usage credits' on stderr returns 5" {
  local _out _err
  _out=$(mktemp); _err=$(mktemp)
  : > "$_out"
  printf 'out of usage credits\n' > "$_err"
  result=$(_claude_classify_exit "$_out" "$_err" 1)
  rm -f "$_out" "$_err"
  [ "$result" -eq 5 ]
}

@test "_claude_classify_exit: 'Spending cap reached' on stdout returns 5" {
  local _out _err
  _out=$(mktemp); _err=$(mktemp)
  printf 'Spending cap reached resets 11:20pm\n' > "$_out"
  : > "$_err"
  result=$(_claude_classify_exit "$_out" "$_err" 1)
  rm -f "$_out" "$_err"
  [ "$result" -eq 5 ]
}

@test "_claude_classify_exit: auth phrase on stdout returns 18" {
  local _out _err
  _out=$(mktemp); _err=$(mktemp)
  printf 'Invalid API key · Please run /login\n' > "$_out"
  : > "$_err"
  result=$(_claude_classify_exit "$_out" "$_err" 1)
  rm -f "$_out" "$_err"
  [ "$result" -eq 18 ]
}

@test "_claude_classify_exit: auth phrase on stderr returns 18" {
  local _out _err
  _out=$(mktemp); _err=$(mktemp)
  : > "$_out"
  printf 'Invalid API key · Please run /login\n' > "$_err"
  result=$(_claude_classify_exit "$_out" "$_err" 1)
  rm -f "$_out" "$_err"
  [ "$result" -eq 18 ]
}

@test "_claude_classify_exit: unknown phrase returns original exit code" {
  local _out _err
  _out=$(mktemp); _err=$(mktemp)
  printf 'some other error message\n' > "$_out"
  : > "$_err"
  result=$(_claude_classify_exit "$_out" "$_err" 2)
  rm -f "$_out" "$_err"
  [ "$result" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 2. False-abort guard: exit-0 success with quoted cap phrase → still 0
# ---------------------------------------------------------------------------

@test "_claude_classify_exit: exit 0 with cap phrase in body is NOT reclassified" {
  local _out _err
  _out=$(mktemp); _err=$(mktemp)
  # Simulate a successful review that documents the phrase mid-line
  printf 'This code checks for "Spending cap reached" messages correctly.\n' > "$_out"
  : > "$_err"
  result=$(_claude_classify_exit "$_out" "$_err" 0)
  rm -f "$_out" "$_err"
  [ "$result" -eq 0 ]
}

@test "_claude_classify_exit: exit 0 with cap phrase at line-start is NOT reclassified (non-agentic guard)" {
  # Non-agentic runners call _claude_classify_exit only when exit != 0.
  # Directly calling with exit 0 must return 0 regardless of content.
  local _out _err
  _out=$(mktemp); _err=$(mktemp)
  printf 'Spending cap reached resets 1:00am\n' > "$_out"
  : > "$_err"
  result=$(_claude_classify_exit "$_out" "$_err" 0)
  rm -f "$_out" "$_err"
  [ "$result" -eq 0 ]
}

@test "run_prompt: exit 0 quoting a cap phrase is not misclassified (false-abort guard)" {
  _write_shim "Review note: 'Spending cap reached' detection looks correct." stdout 0
  run claude_provider_run_prompt "review this"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 3. run_prompt: cap and auth on both channels
# ---------------------------------------------------------------------------

@test "run_prompt: cap phrase on stdout → exit 5" {
  _write_shim "Spending cap reached resets 11:20pm" stdout 1
  run claude_provider_run_prompt "summarize this"
  [ "$status" -eq 5 ]
}

@test "run_prompt: cap phrase on stderr → exit 5" {
  _write_shim "Claude usage limit reached" stderr 1
  run claude_provider_run_prompt "summarize this"
  [ "$status" -eq 5 ]
}

@test "run_prompt: 'out of usage credits' on stdout → exit 5" {
  _write_shim "out of usage credits" stdout 1
  run claude_provider_run_prompt "summarize this"
  [ "$status" -eq 5 ]
}

@test "run_prompt: auth phrase on stdout → exit 18" {
  _write_shim "Invalid API key · Please run /login" stdout 1
  run claude_provider_run_prompt "summarize this"
  [ "$status" -eq 18 ]
}

@test "run_prompt: auth phrase on stderr → exit 18" {
  _write_shim "not logged in" stderr 1
  run claude_provider_run_prompt "summarize this"
  [ "$status" -eq 18 ]
}

# ---------------------------------------------------------------------------
# 4. run_prompt_with_timeout: cap and auth
# ---------------------------------------------------------------------------

@test "run_prompt_with_timeout: cap phrase on stdout → exit 5" {
  _write_shim "5-hour limit reached" stdout 1
  run claude_provider_run_prompt_with_timeout "summarize" "" true 30
  [ "$status" -eq 5 ]
}

@test "run_prompt_with_timeout: cap phrase on stderr → exit 5" {
  _write_shim "spending cap reached" stderr 1
  run claude_provider_run_prompt_with_timeout "summarize" "" true 30
  [ "$status" -eq 5 ]
}

@test "run_prompt_with_timeout: auth phrase on stderr → exit 18" {
  _write_shim "authentication_error" stderr 1
  run claude_provider_run_prompt_with_timeout "summarize" "" true 30
  [ "$status" -eq 18 ]
}

# ---------------------------------------------------------------------------
# 5. run_streaming_prompt: cap and auth
# ---------------------------------------------------------------------------

@test "run_streaming_prompt: cap phrase on stdout → exit 5" {
  _write_shim "you've hit your session limit" stdout 1
  run claude_provider_run_streaming_prompt "plan these issues"
  [ "$status" -eq 5 ]
}

@test "run_streaming_prompt: cap phrase on stderr → exit 5" {
  _write_shim "out of usage credits" stderr 1
  run claude_provider_run_streaming_prompt "plan these issues"
  [ "$status" -eq 5 ]
}

@test "run_streaming_prompt: auth phrase on stderr → exit 18" {
  _write_shim "please run /login" stderr 1
  run claude_provider_run_streaming_prompt "plan these issues"
  [ "$status" -eq 18 ]
}

# ---------------------------------------------------------------------------
# 6. run_classify: cap and auth (also verifies stderr is no longer discarded)
# ---------------------------------------------------------------------------

@test "run_classify: cap phrase on stdout → exit 5" {
  _write_shim "Claude usage limit reached" stdout 1
  run claude_provider_run_classify "RELEVANT or UNRELATED?"
  [ "$status" -eq 5 ]
}

@test "run_classify: cap phrase on stderr → exit 5 (stderr no longer discarded)" {
  _write_shim "out of usage credits" stderr 1
  run claude_provider_run_classify "RELEVANT or UNRELATED?"
  [ "$status" -eq 5 ]
}

@test "run_classify: auth phrase on stderr → exit 18 (stderr no longer discarded)" {
  _write_shim "not logged in" stderr 1
  run claude_provider_run_classify "RELEVANT or UNRELATED?"
  [ "$status" -eq 18 ]
}

@test "run_classify: classification word still reaches stdout on success" {
  _write_shim "trivial" stdout 0
  run claude_provider_run_classify "is this trivial or complex?"
  [ "$status" -eq 0 ]
  [[ "$output" == *"trivial"* ]]
}

# ---------------------------------------------------------------------------
# 7. run_uncached: cap and auth
# ---------------------------------------------------------------------------

@test "run_uncached: cap phrase on stdout → exit 5" {
  _write_shim "Spending cap reached resets 2:00am" stdout 1
  run claude_provider_run_uncached "prompt text"
  [ "$status" -eq 5 ]
}

@test "run_uncached: cap phrase on stderr → exit 5" {
  _write_shim "you've hit your usage limit" stderr 1
  local _stderr_tmp
  _stderr_tmp=$(mktemp)
  run claude_provider_run_uncached "prompt text" "$_stderr_tmp"
  rm -f "$_stderr_tmp"
  [ "$status" -eq 5 ]
}

@test "run_uncached: auth phrase on stderr → exit 18" {
  _write_shim "Invalid API key" stderr 1
  local _stderr_tmp
  _stderr_tmp=$(mktemp)
  run claude_provider_run_uncached "prompt text" "$_stderr_tmp"
  rm -f "$_stderr_tmp"
  [ "$status" -eq 18 ]
}

# ---------------------------------------------------------------------------
# 8. Agentic runner regression (structural): non-zero path uses shared helper
# ---------------------------------------------------------------------------
# The agentic pipeline runs jq (stream filter) which would reject the non-JSON
# cap phrase and exit non-zero before we can capture PIPESTATUS.  Structural
# grep tests are the correct tool here: they verify the invariant ("non-zero
# path delegates to _claude_classify_exit") without the jq pipeline complexity.
# See test-authoring-runbook.md § "Structural vs behavioral pins".

@test "agentic session non-zero path delegates to shared _claude_classify_exit" {
  grep -qF '_claude_classify_exit "$_stdout_capture" "$stderr_file" "$_exit_code"' \
    "${RITE_LIB}/providers/claude.sh"
}

@test "agentic session exit-0 phrase list includes 'out of usage credits'" {
  grep -qF 'out of usage credits' \
    "${RITE_LIB}/providers/claude.sh"
}

@test "agentic session exit-0 path still exists as a separate elif branch" {
  # The exit-0 cap path (issue #1121) is a separate elif — confirm it exists.
  grep -qE 'elif.*_exit_code.*-eq.*0.*&&' \
    "${RITE_LIB}/providers/claude.sh"
}

# ---------------------------------------------------------------------------
# 9. local-review.sh retry loop: exit 5/18 short-circuit guards exist
#    (structural; issue #1623 — detection without propagation makes the
#     feature inert on the review path)
# ---------------------------------------------------------------------------

@test "local-review.sh retry loop has an exit-5 short-circuit guard" {
  grep -qE 'REVIEW_EXIT.*-eq.*5' \
    "${RITE_LIB}/core/local-review.sh"
}

@test "local-review.sh retry loop has an exit-18 short-circuit guard" {
  grep -qE 'REVIEW_EXIT.*-eq.*18' \
    "${RITE_LIB}/core/local-review.sh"
}
