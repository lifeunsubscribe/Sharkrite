#!/bin/bash
# lib/providers/gemini.sh — Gemini CLI provider skeleton for Sharkrite
#
# STATUS: Skeleton — all functions stubbed. Requires Gemini CLI research
# to implement. See docs/architecture/behavioral-design.md for context.
#
# To implement this provider:
# 1. Research Gemini CLI flags for non-interactive mode, streaming, auth
# 2. Determine if Gemini CLI supports tool restrictions (--disallowedTools equiv)
# 3. Map Gemini's streaming event format for jq parsing
# 4. Test text-in/text-out prompts first (simplest to verify)

# =============================================================================
# CLI Detection
# =============================================================================

GEMINI_PROVIDER_CMD=""

gemini_provider_detect_cli() {
  if command -v gemini &>/dev/null; then
    GEMINI_PROVIDER_CMD="gemini"
    PROVIDER_CMD="$GEMINI_PROVIDER_CMD"
    return 0
  fi
  echo "Gemini CLI not found" >&2
  echo "Install: pip install google-genai" >&2
  return 1
}

gemini_provider_validate_cli() {
  local _cmd="${GEMINI_PROVIDER_CMD:-gemini}"
  # TODO: Implement Gemini CLI health check once CLI interface is known
  echo "Gemini provider: validate_cli not yet implemented" >&2
  return 1
}

# =============================================================================
# Invocation (all stubbed)
# =============================================================================

gemini_provider_run_agentic_session() {
  echo "Gemini provider: agentic sessions not yet implemented" >&2
  echo "Requires: Gemini CLI with tool-use, streaming events, and tool restrictions" >&2
  return 1
}

gemini_provider_run_prompt() {
  # This is the simplest function to implement — text-in/text-out.
  # Once the Gemini CLI's equivalent of `claude --print` is known,
  # this becomes: echo "$prompt" | gemini <flags> --model "$model"
  echo "Gemini provider: run_prompt not yet implemented" >&2
  return 1
}

gemini_provider_run_prompt_with_timeout() {
  echo "Gemini provider: run_prompt_with_timeout not yet implemented" >&2
  return 1
}

gemini_provider_run_streaming_prompt() {
  echo "Gemini provider: streaming prompts not yet implemented" >&2
  return 1
}

gemini_provider_run_classify() {
  # Classification is a minimal text-in/text-out call.
  # Once run_prompt works, this can delegate to it.
  echo "Gemini provider: run_classify not yet implemented" >&2
  return 1
}

gemini_provider_run_uncached() {
  echo "Gemini provider: run_uncached not yet implemented" >&2
  return 1
}

# =============================================================================
# Error Detection
# =============================================================================

gemini_provider_detect_error() {
  local error_output="$1"
  local exit_code="$2"

  # TODO: Map Gemini-specific error patterns when CLI is researched
  # Expected patterns: quota exceeded, auth errors, network issues

  # Usage cap / quota exhaustion (distinct from transient rate limiting)
  if echo "$error_output" | grep -qiE "usage.?cap|over.?capacity|plan.?limit|quota.*exceeded|resource.?exhausted"; then
    echo "USAGE_CAP"
    return 0
  fi

  # Rate limiting (transient — retryable)
  if echo "$error_output" | grep -qiE "rate.?limit|429|too many requests"; then
    echo "RATE_LIMITED"
    return 0
  fi

  # Authentication
  if echo "$error_output" | grep -qiE "unauthorized|403|auth.*fail|invalid.*credentials|api.?key"; then
    echo "AUTH_EXPIRED"
    return 0
  fi

  # Network
  if echo "$error_output" | grep -qiE "connection.*refused|network.*error|timeout|ECONNREFUSED"; then
    echo "NETWORK_ERROR"
    return 0
  fi

  echo "UNKNOWN"
  return 1
}

# =============================================================================
# Safety
# =============================================================================

gemini_provider_supports_tool_restrictions() {
  # Gemini CLI does not (currently) support --disallowedTools or equivalent.
  # Until this is implemented, agentic sessions MUST run supervised only.
  # The safety gate in claude-workflow.sh will block unsupervised mode.
  return 1
}

gemini_provider_build_tool_restrictions() {
  # No tool restrictions available — return empty
  echo ""
}

# =============================================================================
# Prompt Adaptation
# =============================================================================

gemini_provider_dev_session_preamble() {
  local auto_mode="$1"
  local task_description="$2"

  # Gemini-specific preamble: no TodoWrite reference (Gemini may not have it),
  # but keep the sharkrite identity and git/gh prohibition.
  cat <<EOF
You are **Thresher**, running inside a **Sharkrite** (CLI: \`rite\`) automated workflow session.
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

gemini_provider_exit_instructions() {
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

gemini_provider_resolve_model() {
  local role="$1"
  case "$role" in
    dev)    echo "${RITE_GEMINI_DEV_MODEL:-gemini-2.5-pro}" ;;
    review) echo "${RITE_GEMINI_REVIEW_MODEL:-gemini-2.5-pro}" ;;
    *)      echo "${RITE_GEMINI_DEV_MODEL:-gemini-2.5-pro}" ;;
  esac
}

# =============================================================================
# Display Name
# =============================================================================

gemini_provider_name() {
  echo "gemini"
}
