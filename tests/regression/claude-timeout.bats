#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh, lib/utils/timeout.sh
# Regression test for: Add timeout to all Claude provider prompt calls
#
# Verifies that run_prompt, run_classify, run_streaming_prompt, and run_uncached
# all respect their configured timeouts and exit with code 124 when exceeded.
#
# Strategy: replace the `claude` CLI with a `sleep 99999` shim. Set the timeout
# env vars to a very short value (3s). Assert each call exits within ~15s.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"

  # Create a shim directory with a fake 'claude' that sleeps forever
  export SHIM_DIR
  SHIM_DIR=$(mktemp -d)
  cat > "${SHIM_DIR}/claude" <<'SHIM'
#!/bin/bash
# Shim: simulates a hung Claude CLI
sleep 99999
SHIM
  chmod +x "${SHIM_DIR}/claude"

  # Prepend shim dir so provider picks up our fake claude
  export PATH="${SHIM_DIR}:${PATH}"

  # Use a short timeout so tests finish fast (3 seconds)
  export RITE_CLAUDE_TIMEOUT_PROMPT=3
  export RITE_CLAUDE_TIMEOUT_AGENTIC=3

  # Source the timeout utility and ensure gtimeout/timeout is detected
  source "${RITE_LIB_DIR}/utils/timeout.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
  ensure_timeout_cmd

  # Skip entire suite if no timeout command is available (CI without coreutils)
  if [ -z "${RITE_TIMEOUT_CMD:-}" ]; then
    skip "No timeout command available (install coreutils)"
  fi

  # Source the provider (timeout.sh already sourced, so run_with_timeout is defined)
  # Unset _RITE_TIMEOUT_CHECKED guard so re-sourcing claude.sh can call ensure_timeout_cmd
  CLAUDE_PROVIDER_CMD="${SHIM_DIR}/claude"
  export CLAUDE_PROVIDER_CMD

  # Source claude.sh after setting up the shim; it will find run_with_timeout already defined
  source "${RITE_LIB_DIR}/providers/claude.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  rm -rf "${SHIM_DIR:-}"
}

# ---------------------------------------------------------------------------
# run_prompt — text-in/text-out
# ---------------------------------------------------------------------------

@test "run_prompt: exits 124 on timeout (sleep-shim claude)" {
  run claude_provider_run_prompt "hello world"

  [ "$status" -eq 124 ]
}

@test "run_prompt: logs timeout message to stderr" {
  # bats `run` captures both stdout and stderr in $output
  run claude_provider_run_prompt "hello world"

  [ "$status" -eq 124 ]
  [[ "$output" =~ "timed out after" ]]
}

@test "run_prompt: respects RITE_CLAUDE_TIMEOUT_PROMPT override" {
  # Set a 2s timeout and verify it fires (stays under 15s total)
  export RITE_CLAUDE_TIMEOUT_PROMPT=2
  run claude_provider_run_prompt "hello world"

  [ "$status" -eq 124 ]
}

# ---------------------------------------------------------------------------
# run_classify — one-word classification
# ---------------------------------------------------------------------------

@test "run_classify: exits 124 on timeout (sleep-shim claude)" {
  run claude_provider_run_classify "RELEVANT or UNRELATED?"

  [ "$status" -eq 124 ]
}

@test "run_classify: logs timeout message to stderr" {
  run claude_provider_run_classify "RELEVANT or UNRELATED?"

  [ "$status" -eq 124 ]
  [[ "$output" =~ "timed out after" ]]
}

# ---------------------------------------------------------------------------
# run_streaming_prompt — plan-issues pattern
# ---------------------------------------------------------------------------

@test "run_streaming_prompt: exits 124 on timeout (sleep-shim claude)" {
  run claude_provider_run_streaming_prompt "generate some issues"

  [ "$status" -eq 124 ]
}

@test "run_streaming_prompt: logs timeout message to stderr" {
  run claude_provider_run_streaming_prompt "generate some issues"

  [ "$status" -eq 124 ]
  [[ "$output" =~ "timed out after" ]]
}

# ---------------------------------------------------------------------------
# run_uncached — legacy merge-pr.sh pattern
# ---------------------------------------------------------------------------

@test "run_uncached: exits 124 on timeout (sleep-shim claude)" {
  run claude_provider_run_uncached "analyze this code"

  [ "$status" -eq 124 ]
}

@test "run_uncached: logs timeout message to stderr" {
  run claude_provider_run_uncached "analyze this code"

  [ "$status" -eq 124 ]
  [[ "$output" =~ "timed out after" ]]
}

# ---------------------------------------------------------------------------
# Env var configuration
# ---------------------------------------------------------------------------

@test "RITE_CLAUDE_TIMEOUT_PROMPT default is 600" {
  # Source a fresh shell without env overrides to check the default
  run bash -c "
    unset RITE_CLAUDE_TIMEOUT_PROMPT RITE_CLAUDE_TIMEOUT_AGENTIC
    export RITE_PROJECT_ROOT=\"\$(mktemp -d)\"
    export RITE_GLOBAL_CONFIG=/dev/null
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    echo \"\${RITE_CLAUDE_TIMEOUT_PROMPT:-unset}\"
  "
  [[ "$output" =~ "600" ]]
}

@test "RITE_CLAUDE_TIMEOUT_AGENTIC default is 1800" {
  run bash -c "
    unset RITE_CLAUDE_TIMEOUT_PROMPT RITE_CLAUDE_TIMEOUT_AGENTIC
    export RITE_PROJECT_ROOT=\"\$(mktemp -d)\"
    export RITE_GLOBAL_CONFIG=/dev/null
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    echo \"\${RITE_CLAUDE_TIMEOUT_AGENTIC:-unset}\"
  "
  [[ "$output" =~ "1800" ]]
}

# ===========================================================================
# run_with_timeout SIGKILL escalation (#1299)
#
# `timeout N cmd` sends SIGTERM at the deadline then WAITS for cmd to exit. A
# process that ignores SIGTERM never exits and timeout waits with it forever,
# so the deadline silently becomes advisory.
#
# Live (batch 20261014-184054): every LLM session is wrapped by this helper and
# every one blew past its deadline — claude_fix_session 2h39m against 1800s,
# review_generation 4h25m against 600s, claude_dev_session 10h58m. Issues #1231
# and #1262 ran 7h38m and 11h08m. Phase-boundary caps never fired because a
# single unbounded call never reaches a boundary.
# ===========================================================================

_timeout_sut() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$RITE_REPO_ROOT/lib/utils/timeout.sh"
  ensure_timeout_cmd >/dev/null 2>&1 || true
}

# A process that ignores SIGTERM — exactly what outlives a bare `timeout N`.
_write_term_ignoring_cmd() {
  cat > "$1" <<'STUBEOF'
#!/bin/bash
trap '' TERM
sleep 60
STUBEOF
  chmod +x "$1"
}

@test "run_with_timeout: passes -k so a TERM-ignoring process is still killed" {
  _timeout_sut
  [ -n "${RITE_TIMEOUT_CMD:-}" ] || skip "no timeout command on this host"

  local _stub="$BATS_TEST_TMPDIR/stubborn.sh"
  _write_term_ignoring_cmd "$_stub"

  local _t0 _elapsed _exit=0
  _t0=$(date +%s)
  RITE_TIMEOUT_KILL_AFTER=2 run_with_timeout 2 "$_stub" 2>/dev/null || _exit=$?
  _elapsed=$(( $(date +%s) - _t0 ))

  # Must die, not hang: deadline 2s + kill-after 2s, with slack for load.
  [ "$_elapsed" -lt 20 ] || {
    echo "FAIL: ran ${_elapsed}s against a 2s deadline — -k is not being passed"
    false
  }
  # 137 = 128 + SIGKILL(9). A bare TERM would never have landed.
  [ "$_exit" -eq 137 ] || [ "$_exit" -eq 124 ]
}

@test "run_with_timeout: a normal fast command is unaffected" {
  _timeout_sut
  local _out
  _out=$(run_with_timeout 10 /bin/echo "hello" 2>/dev/null)
  [ "$_out" = "hello" ]
}

@test "run_with_timeout: non-zero exit from the command is propagated verbatim" {
  _timeout_sut
  local _exit=0
  run_with_timeout 10 /bin/sh -c 'exit 42' 2>/dev/null || _exit=$?
  [ "$_exit" -eq 42 ]
}

@test "run_with_timeout: warns once when no timeout command is available" {
  _timeout_sut
  # Simulate a host without timeout/gtimeout. Unbounded is survivable; silent
  # unbounded is not — an 11-hour run must not look like a slow call.
  local _err
  _err=$(RITE_TIMEOUT_CMD="" _RITE_TIMEOUT_UNBOUNDED_WARNED="" \
    run_with_timeout 5 /bin/echo hi 2>&1 >/dev/null)
  echo "$_err" | grep -qi "unbounded"
}

@test "run_with_timeout: the unbounded warning is not repeated" {
  _timeout_sut
  local _err
  _err=$(
    export RITE_TIMEOUT_CMD="" _RITE_TIMEOUT_UNBOUNDED_WARNED=""
    run_with_timeout 5 /bin/echo a 2>&1 >/dev/null
    run_with_timeout 5 /bin/echo b 2>&1 >/dev/null
  )
  [ "$(echo "$_err" | grep -ci unbounded || true)" -eq 1 ]
}

@test "structural: every run_with_timeout call site routes through the shared helper" {
  # The gate already used -k directly and was the only bounded path. Any NEW
  # bare "$RITE_TIMEOUT_CMD" <secs> invocation outside timeout.sh/test-gate.sh
  # would reintroduce an unbounded deadline.
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  local _bare
  _bare=$(grep -rn '"\$RITE_TIMEOUT_CMD" "\$' "$RITE_REPO_ROOT/lib" 2>/dev/null \
    | grep -v 'utils/timeout.sh' || true)
  [ -z "$_bare" ] || {
    echo "Bare RITE_TIMEOUT_CMD invocation without -k:"
    echo "$_bare"
    false
  }
}
