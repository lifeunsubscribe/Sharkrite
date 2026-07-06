#!/bin/bash
# lib/providers/provider-interface.sh — Provider abstraction dispatcher
#
# Loads a named provider (claude is the only shipped provider) and aliases its
# functions to a generic provider_* namespace so callers don't need to know which
# provider is active. The abstraction is kept so the codebase stays provider-
# neutral (enforced by the provider-agnosticism lint + tests/provider-swap, which
# swap in a mock provider).
#
# Usage:
#   source "$RITE_LIB_DIR/providers/provider-interface.sh"
#   load_provider "claude"          # or "${RITE_DEV_PROVIDER:-claude}"
#   provider_detect_cli || exit 1
#   provider_run_prompt "$prompt" "$model" "$auto_mode"
#
# IMPORTANT: Call load_provider() at script top level, NOT inside $() subshells.
# The function sets globals (PROVIDER_CMD) that would be lost in a subshell.
# Calling provider_run_prompt etc. inside $() is fine (they only produce stdout).

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f load_provider >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# =============================================================================
# Provider Interface Contract
# =============================================================================
#
# Every provider file (lib/providers/<name>.sh) MUST implement these functions,
# prefixed with <name>_provider_. For example, claude.sh implements
# claude_provider_detect_cli, claude_provider_run_prompt, etc.
#
# --- CLI Detection & Validation ---
#
# provider_detect_cli()
#   Set PROVIDER_CMD to the CLI command path. Return 0 if found, 1 if not.
#   Print install instructions to stderr on failure.
#
# provider_validate_cli()
#   Verify the CLI is authenticated and functional. Return 0/1.
#
# --- Invocation ---
#
# provider_run_agentic_session(prompt, timeout, auto_mode, stderr_file)
#   Run an agentic dev/fix session with streaming output and tool restrictions.
#   Handles its own streaming format internally (jq for Claude, TBD for others).
#   Returns: exit code (124=timeout, 127=not found). Stdout streams to terminal.
#
# provider_run_prompt(prompt, model, auto_mode)
#   Text-in/text-out. Returns exit code; stdout = LLM response text.
#   model="" means use the provider's default for the current role.
#   auto_mode="true" enables permission bypass (e.g., --dangerously-skip-permissions).
#
# provider_run_prompt_with_timeout(prompt, model, auto_mode, timeout_seconds)
#   Same as run_prompt but with a timeout wrapper. Exit 124 on timeout.
#
# provider_run_streaming_prompt(prompt, model)
#   Streaming text output (no tool restrictions). Used by plan-issues.
#   Returns exit code; stdout streams text in real-time.
#
# provider_run_classify(prompt)
#   Minimal invocation for one-word classification (RELEVANT/UNRELATED/TRIVIAL).
#   Returns exit code; stdout = raw LLM response.
#
# provider_run_uncached(prompt, stderr_file)
#   Legacy pattern: no caching, no --print. Used by merge-pr.sh.
#   Returns exit code; stdout = LLM response.
#
# --- Error Handling ---
#
# provider_detect_error(error_output, exit_code)
#   Classify provider-specific stderr into error types.
#   Stdout: RATE_LIMITED | AUTH_EXPIRED | NETWORK_ERROR | PROVIDER_BUG | UNKNOWN
#   Returns 0 if classified to a known type, 1 for UNKNOWN.
#
# --- Safety ---
#
# provider_supports_tool_restrictions()
#   Return 0 if this provider can enforce tool restrictions (e.g., --disallowedTools).
#   Return 1 if not. Providers returning 1 are blocked from unsupervised agentic sessions.
#
# provider_build_tool_restrictions()
#   Return the provider-specific restriction spec string on stdout.
#   Only called if provider_supports_tool_restrictions returns 0.
#
# --- Prompt Adaptation ---
#
# provider_dev_session_preamble(auto_mode, task_description)
#   Return provider-specific prompt preamble for dev sessions on stdout.
#   Includes identity statement, tool references, git/gh prohibition.
#
# provider_exit_instructions(auto_mode)
#   Return provider-specific session exit instructions on stdout.
#
# --- Model Resolution ---
#
# provider_resolve_model(role)
#   Map a role ("dev" or "review") to the provider-specific model name.
#   Returns the model name on stdout.
#
# provider_name()
#   Return the provider display name on stdout (e.g., "claude").

# =============================================================================
# Dispatcher
# =============================================================================

# Track the currently loaded provider to avoid redundant reloads
_LOADED_PROVIDER=""

load_provider() {
  local provider_name="$1"
  local provider_file="${RITE_LIB_DIR}/providers/${provider_name}.sh"

  # Skip reload if already loaded
  if [ "$_LOADED_PROVIDER" = "$provider_name" ]; then
    return 0
  fi

  if [ ! -f "$provider_file" ]; then
    echo "Unknown provider: $provider_name" >&2
    echo "Available providers: claude" >&2
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$provider_file"

  # Alias <name>_provider_* -> provider_*
  local fn
  for fn in \
    detect_cli validate_cli \
    run_agentic_session run_prompt run_prompt_with_timeout \
    run_streaming_prompt run_classify run_uncached \
    detect_error \
    supports_tool_restrictions build_tool_restrictions \
    dev_session_preamble exit_instructions \
    load_test_authoring_runbook \
    resolve_model name; do
    eval "provider_${fn}() { ${provider_name}_provider_${fn} \"\$@\"; }"
  done

  _LOADED_PROVIDER="$provider_name"
}
