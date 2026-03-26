#!/bin/bash
# lib/providers/claude.sh — Claude Code CLI provider for Sharkrite
#
# Implements the provider interface defined in provider-interface.sh.
# All functions are prefixed with claude_provider_ and aliased to provider_*
# by the load_provider() dispatcher.

# =============================================================================
# CLI Detection
# =============================================================================

# The resolved CLI command (set by detect_cli)
CLAUDE_PROVIDER_CMD=""

claude_provider_detect_cli() {
  if command -v claude &>/dev/null; then
    CLAUDE_PROVIDER_CMD="claude"
  elif command -v claude-code &>/dev/null; then
    CLAUDE_PROVIDER_CMD="claude-code"
  elif [ -f "$HOME/.claude/claude" ]; then
    CLAUDE_PROVIDER_CMD="$HOME/.claude/claude"
  else
    echo "Claude CLI not found" >&2
    echo "Install: npm install -g @anthropic-ai/claude-code" >&2
    return 1
  fi
  # Export for child processes that may need it
  PROVIDER_CMD="$CLAUDE_PROVIDER_CMD"
  return 0
}

claude_provider_validate_cli() {
  # Quick health check: can the CLI process a trivial prompt?
  local _cmd="${CLAUDE_PROVIDER_CMD:-claude}"
  if ! echo "test" | "$_cmd" --print --dangerously-skip-permissions &>/dev/null; then
    echo "Claude CLI not authenticated or not working" >&2
    echo "Run: claude login" >&2
    return 1
  fi
  return 0
}

# =============================================================================
# Streaming Filters (internal helpers)
# =============================================================================

# Colored stream filter for dev/fix sessions — shows text + tool-use indicators
# with ANSI color codes for terminal readability.
_claude_stream_filter_colored() {
  jq --unbuffered -rj '
    if .type == "assistant" then
      (.message.content[]? |
        if .type == "text" then "\u001b[38;5;216m" + .text + "\u001b[0m"
        elif .type == "tool_use" then "\n\u001b[0;33m⚡ " + .name + "\u001b[0m\n"
        else empty end)
    else empty end
  ' 2>/dev/null
}

# Plain stream filter for plan-issues and other non-interactive streaming.
# Extracts text content and result fields, no colors or tool indicators.
_claude_stream_filter_plain() {
  jq --unbuffered -rj '
    if .type == "assistant" then
      (.message.content[]? |
        if .type == "text" then .text
        else empty end)
    elif .type == "result" then .result // empty
    else empty end
  ' 2>/dev/null
}

# =============================================================================
# Agentic Session
# =============================================================================

claude_provider_run_agentic_session() {
  local prompt="$1"
  local timeout="$2"
  local auto_mode="$3"
  local stderr_file="${4:-/dev/null}"

  local _cmd="${CLAUDE_PROVIDER_CMD:-claude}"
  local _model
  _model=$(claude_provider_resolve_model "dev")
  local _restrictions
  _restrictions=$(claude_provider_build_tool_restrictions)

  local _exit_code=0

  if [ "$auto_mode" = true ]; then
    # Auto mode: prompt as positional arg, permissions bypassed.
    # --disallowedTools is variadic but positional arg works when it's last.
    run_with_timeout "$timeout" "$_cmd" --model "$_model" \
      --print --verbose --dangerously-skip-permissions \
      --disallowedTools "$_restrictions" --output-format stream-json \
      "$prompt" 2>"$stderr_file" | \
      _claude_stream_filter_colored || true
    _exit_code=${PIPESTATUS[0]}
  else
    # Supervised mode: prompt via stdin because --disallowedTools is variadic
    # and eats positional args after it.
    local _prompt_file
    _prompt_file=$(mktemp)
    printf '%s' "$prompt" > "$_prompt_file"
    run_with_timeout "$timeout" "$_cmd" --model "$_model" \
      --print --verbose --dangerously-skip-permissions \
      --disallowedTools "$_restrictions" --output-format stream-json \
      < "$_prompt_file" 2>"$stderr_file" | \
      _claude_stream_filter_colored || true
    _exit_code=${PIPESTATUS[0]}
    rm -f "$_prompt_file"
  fi

  return "$_exit_code"
}

# =============================================================================
# Text-in/Text-out Prompt
# =============================================================================

claude_provider_run_prompt() {
  local prompt="$1"
  local model="${2:-}"
  local auto_mode="${3:-true}"

  local _cmd="${CLAUDE_PROVIDER_CMD:-claude}"
  local _args="--print"

  # Resolve model if not explicitly provided
  if [ -z "$model" ]; then
    model=$(claude_provider_resolve_model "review")
  fi
  if [ -n "$model" ]; then
    _args="$_args --model $model"
  fi

  if [ "$auto_mode" = true ]; then
    _args="$_args --dangerously-skip-permissions"
  fi

  # shellcheck disable=SC2086
  echo "$prompt" | $_cmd $_args
}

# =============================================================================
# Prompt with Timeout
# =============================================================================

claude_provider_run_prompt_with_timeout() {
  local prompt="$1"
  local model="${2:-}"
  local auto_mode="${3:-true}"
  local timeout="${4:-120}"

  local _cmd="${CLAUDE_PROVIDER_CMD:-claude}"
  local _args="--print"

  if [ -z "$model" ]; then
    model=$(claude_provider_resolve_model "review")
  fi
  if [ -n "$model" ]; then
    _args="$_args --model $model"
  fi

  if [ "$auto_mode" = true ]; then
    _args="$_args --dangerously-skip-permissions"
  fi

  # Use timeout command if available
  if [ -n "${RITE_TIMEOUT_CMD:-}" ]; then
    # shellcheck disable=SC2086
    echo "$prompt" | $RITE_TIMEOUT_CMD "$timeout" $_cmd $_args
  elif command -v timeout &>/dev/null; then
    # shellcheck disable=SC2086
    echo "$prompt" | timeout "$timeout" $_cmd $_args
  else
    # No timeout available — run without
    # shellcheck disable=SC2086
    echo "$prompt" | $_cmd $_args
  fi
}

# =============================================================================
# Streaming Prompt (plan-issues pattern)
# =============================================================================

claude_provider_run_streaming_prompt() {
  local prompt="$1"
  local model="${2:-}"

  local _cmd="${CLAUDE_PROVIDER_CMD:-claude}"

  if [ -z "$model" ]; then
    model=$(claude_provider_resolve_model "review")
  fi

  echo "$prompt" | "$_cmd" --print --verbose --dangerously-skip-permissions \
    --model "$model" --output-format stream-json | \
    _claude_stream_filter_plain
}

# =============================================================================
# Classification (minimal, one-word response)
# =============================================================================

claude_provider_run_classify() {
  local prompt="$1"
  local _cmd="${CLAUDE_PROVIDER_CMD:-claude}"

  echo "$prompt" | "$_cmd" --print 2>/dev/null
}

# =============================================================================
# Uncached Prompt (legacy merge-pr.sh pattern)
# =============================================================================

claude_provider_run_uncached() {
  local prompt="$1"
  local stderr_file="${2:-/dev/null}"
  local _cmd="${CLAUDE_PROVIDER_CMD:-claude}"

  echo "$prompt" | "$_cmd" --no-cache 2>"$stderr_file"
}

# =============================================================================
# Error Detection
# =============================================================================
# Moved from assess-review-issues.sh:360-391.
# Classifies Claude CLI stderr output into known error types.

claude_provider_detect_error() {
  local error_output="$1"
  local exit_code="$2"

  # AJV/OAuth bug — GitHub MCP server schema validation failure
  if echo "$error_output" | grep -qiE "ajv|schema.*validation|oauth.*fail|token.*invalid|mcp.*error"; then
    echo "PROVIDER_BUG"
    return 0
  fi

  # Rate limiting
  if echo "$error_output" | grep -qiE "rate.?limit|too many requests|429"; then
    echo "RATE_LIMITED"
    return 0
  fi

  # Authentication expired
  if echo "$error_output" | grep -qiE "unauthorized|401|auth.*expired|login required"; then
    echo "AUTH_EXPIRED"
    return 0
  fi

  # Network/connection issues
  if echo "$error_output" | grep -qiE "connection.*refused|network.*error|timeout|ECONNREFUSED"; then
    echo "NETWORK_ERROR"
    return 0
  fi

  # Unknown error
  echo "UNKNOWN"
  return 1
}

# =============================================================================
# Safety
# =============================================================================

claude_provider_supports_tool_restrictions() {
  # Claude CLI supports --disallowedTools, enforced by the CLI even with
  # --dangerously-skip-permissions. This is the primary safety mechanism
  # preventing Claude from running git commit/push/gh during dev sessions.
  return 0
}

claude_provider_build_tool_restrictions() {
  # Block git commit/push (post-workflow handles them), gh, and network commands.
  # Bash(pattern) syntax is Claude CLI specific.
  echo 'Bash(git commit*),Bash(git push*),Bash(*git commit*),Bash(*git push*),Bash(gh *),Bash(gh),Bash(*gh pr*),Bash(*gh issue*),Bash(*gh api*),Bash(curl *),Bash(wget *)'
}

# =============================================================================
# Prompt Adaptation
# =============================================================================

claude_provider_dev_session_preamble() {
  local auto_mode="$1"
  local task_description="$2"

  cat <<EOF
You are running inside a **Sharkrite** (CLI: \`rite\`) automated workflow session.
The workflow tool is called **rite** — not "forge" or any other name.
When this session ends, the rite workflow automatically handles commit, push, and PR creation.
Do NOT run git commit, git push, gh pr create, or any git/gh commands yourself.

Task: ${task_description}

**IMPORTANT: Use the TodoWrite tool to track progress throughout this workflow.**

Before starting, create a todo list with these items:
1. Phase 0: Requirements Clarification - Ask questions if task is ambiguous
2. Phase 1: Analysis - Understanding the codebase and requirements
3. Phase 2: Planning - Designing the implementation approach
4. Phase 3: Implementation - Writing the code
5. Phase 4: Testing & Validation - Running tests and verifying correctness
6. Phase 5: Code Comments - Adding inline comments for complex logic

Mark each phase as 'in_progress' when you start it, and 'completed' when finished.
For complex phases, break them into sub-tasks.
EOF
}

claude_provider_exit_instructions() {
  local auto_mode="$1"

  if [ "$auto_mode" = true ]; then
    cat <<'EOF'
**Auto Mode**: Complete all phases automatically. After Phase 5:
1. Provide a brief summary of what you implemented
2. Exit immediately — the rite workflow will automatically handle commit, push, and PR creation
EOF
  else
    cat <<'EOF'
**When all phases are complete**: Provide a brief summary of what you implemented, then immediately exit the session with `/exit`. The rite workflow will automatically handle commit, push, and PR creation — do NOT commit, push, or create PRs yourself.
EOF
  fi
}

# =============================================================================
# Model Resolution
# =============================================================================

claude_provider_resolve_model() {
  local role="$1"
  case "$role" in
    dev)    echo "${RITE_CLAUDE_MODEL:-claude-sonnet-4-5}" ;;
    review) echo "${RITE_REVIEW_MODEL:-claude-opus-4-5}" ;;
    *)      echo "${RITE_CLAUDE_MODEL:-claude-sonnet-4-5}" ;;
  esac
}

# =============================================================================
# Display Name
# =============================================================================

claude_provider_name() {
  echo "claude"
}
