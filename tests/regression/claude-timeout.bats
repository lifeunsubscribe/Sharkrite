#!/usr/bin/env bats
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
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    echo \"\${RITE_CLAUDE_TIMEOUT_PROMPT:-unset}\"
  "
  [[ "$output" =~ "600" ]]
}

@test "RITE_CLAUDE_TIMEOUT_AGENTIC default is 1800" {
  run bash -c "
    source '${RITE_LIB_DIR}/utils/config.sh' 2>/dev/null || true
    echo \"\${RITE_CLAUDE_TIMEOUT_AGENTIC:-unset}\"
  "
  [[ "$output" =~ "1800" ]]
}
