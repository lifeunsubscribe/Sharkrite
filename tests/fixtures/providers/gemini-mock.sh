#!/bin/bash
# tests/fixtures/providers/gemini-mock.sh — Mock Gemini provider for testing
#
# This mock implementation records every prompt it receives to detect
# provider-specific token leaks (Claude CLI flags, /exit commands, etc.)
#
# Usage in tests:
#   export RITE_DEV_PROVIDER=gemini-mock
#   export RITE_REVIEW_PROVIDER=gemini-mock
#   export RITE_UTILITY_PROVIDER=gemini-mock
#   # Run workflow - all prompts will be logged to $GEMINI_MOCK_LOG_FILE

set -euo pipefail

# Log file for recording prompts (must be set by test harness)
GEMINI_MOCK_LOG_FILE="${GEMINI_MOCK_LOG_FILE:-${RITE_TEST_TMPDIR:-/tmp}/gemini-mock-prompts.log}"

# Helper to log prompts with context
_log_prompt() {
  local context="$1"
  local prompt="$2"

  cat >> "$GEMINI_MOCK_LOG_FILE" <<EOF
=== ${context} ===
${prompt}
=== END ${context} ===

EOF
}

# =============================================================================
# CLI Detection
# =============================================================================

GEMINI_MOCK_PROVIDER_CMD="gemini-mock"

gemini_mock_provider_detect_cli() {
  # Mock always reports CLI as available
  PROVIDER_CMD="$GEMINI_MOCK_PROVIDER_CMD"
  return 0
}

gemini_mock_provider_validate_cli() {
  # Mock always validates successfully
  return 0
}

# =============================================================================
# Invocation Functions
# =============================================================================

gemini_mock_provider_run_agentic_session() {
  local prompt="$1"
  local timeout="${2:-0}"
  local auto_mode="${3:-false}"
  local stderr_file="${4:-/dev/null}"

  _log_prompt "AGENTIC_SESSION" "$prompt"

  # Return minimal success output
  echo "Mock agentic session completed successfully."
  return 0
}

gemini_mock_provider_run_prompt() {
  local prompt="$1"
  local model="${2:-}"
  local auto_mode="${3:-false}"

  _log_prompt "RUN_PROMPT (model: ${model:-default})" "$prompt"

  # Return minimal text response
  echo "Mock response"
  return 0
}

gemini_mock_provider_run_prompt_with_timeout() {
  local prompt="$1"
  local model="${2:-}"
  local auto_mode="${3:-false}"
  local timeout_seconds="${4:-120}"

  _log_prompt "RUN_PROMPT_WITH_TIMEOUT (timeout: ${timeout_seconds}s)" "$prompt"

  echo "Mock response with timeout"
  return 0
}

gemini_mock_provider_run_streaming_prompt() {
  local prompt="$1"
  local model="${2:-}"

  _log_prompt "STREAMING_PROMPT" "$prompt"

  # Simulate streaming output
  echo "Mock streaming response line 1"
  echo "Mock streaming response line 2"
  return 0
}

gemini_mock_provider_run_classify() {
  local prompt="$1"

  _log_prompt "CLASSIFY" "$prompt"

  # Always return RELEVANT for classification
  echo "RELEVANT"
  return 0
}

gemini_mock_provider_run_uncached() {
  local prompt="$1"
  local stderr_file="${2:-/dev/null}"

  _log_prompt "UNCACHED" "$prompt"

  echo "Mock uncached response"
  return 0
}

# =============================================================================
# Error Detection
# =============================================================================

gemini_mock_provider_detect_error() {
  local error_output="$1"
  local exit_code="$2"

  # Mock never detects errors (always returns UNKNOWN)
  echo "UNKNOWN"
  return 1
}

# =============================================================================
# Safety
# =============================================================================

gemini_mock_provider_supports_tool_restrictions() {
  # Mock doesn't support tool restrictions (like real Gemini)
  return 1
}

gemini_mock_provider_build_tool_restrictions() {
  # No tool restrictions available
  echo ""
}

# =============================================================================
# Prompt Adaptation
# =============================================================================

gemini_mock_provider_dev_session_preamble() {
  local auto_mode="$1"
  local task_description="$2"

  # Return provider-agnostic preamble (same as gemini.sh)
  cat <<EOF
You are running inside a **Sharkrite** (CLI: \`rite\`) automated workflow session.
The workflow tool is called **rite** — not any other name.
When this session ends, the rite workflow automatically handles commit, push, and PR creation.
Do NOT run git commit, git push, gh pr create, or any git/gh commands yourself.

Task: ${task_description}

Before starting, plan your work with these phases:
1. Phase 0: Requirements Clarification - Ask questions if task is ambiguous
2. Phase 1: Analysis - Understanding the codebase and requirements
3. Phase 2: Planning - Designing the implementation approach
4. Phase 3: Implementation - Writing the code
5. Phase 4: Testing & Validation - Running tests and verifying correctness
6. Phase 5: Code Comments - Adding inline comments for complex logic
EOF
}

gemini_mock_provider_exit_instructions() {
  local auto_mode="$1"

  if [ "$auto_mode" = true ]; then
    cat <<'EOF'
**Auto Mode**: Complete all phases automatically. After Phase 5:
1. Provide a brief summary of what you implemented
2. Exit immediately — the rite workflow will automatically handle commit, push, and PR creation
EOF
  else
    cat <<'EOF'
**When all phases are complete**: Provide a brief summary of what you implemented, then exit the session. The rite workflow will automatically handle commit, push, and PR creation — do NOT commit, push, or create PRs yourself.
EOF
  fi
}

# =============================================================================
# Model Resolution
# =============================================================================

gemini_mock_provider_resolve_model() {
  local role="$1"
  echo "gemini-mock-model"
}

# =============================================================================
# Display Name
# =============================================================================

gemini_mock_provider_name() {
  echo "gemini-mock"
}
