#!/bin/bash
# claude-pretooluse-deny.sh — PreToolUse hook enforcing sharkrite's in-session
# command denylist.
#
# WHY THIS EXISTS: the Claude CLI silently ignores --disallowedTools when
# --output-format stream-json is set (CLI 2.0.24), which every sharkrite dev/fix
# session uses. PreToolUse hooks ARE enforced under stream-json, so this hook is
# the real deterministic backstop. It mirrors the intent of
# claude_provider_build_tool_restrictions (lib/providers/claude.sh).
# See: docs/architecture/behavioral-design.md → "Deterministic backstop is broken".
#
# Contract: reads the PreToolUse event JSON on stdin. For Bash tool calls whose
# command matches a forbidden pattern, emits a deny decision (exit 0 + JSON on
# stdout). All other calls are allowed (exit 0, no output). It never blocks
# bash -n, file reads, grep, or read-only git (status/diff/log/add) — only the
# specific forbidden operations below.
set -euo pipefail

# Re-source guard. This file is an executable hook (never sourced in production),
# but lib/ lint Rule 16 requires a guard; it is harmless here.
if declare -f _rite_hook_denial_reason >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Echo a human-readable reason and return 0 when $1 is a forbidden command;
# return 1 (no output) when the command is allowed. Patterns use word anchors
# ((^|[^[:alnum:]_]) ... ([[:space:]]|$)) so "makefile"/"cmake" don't match "make".
_rite_hook_denial_reason() {
  _cmd="$1"
  # git commit / git push (read-only git is allowed: status, diff, log, add, ...)
  if printf '%s' "$_cmd" | grep -qE '(^|[^[:alnum:]_])git[[:space:]]+(commit|push)([^[:alnum:]_]|$)'; then
    echo "git commit/push is handled by the rite workflow after this session"; return 0
  fi
  # gh — the workflow owns all GitHub interaction
  if printf '%s' "$_cmd" | grep -qE '(^|[^[:alnum:]_])gh([[:space:]]|$)'; then
    echo "gh commands are handled by the rite workflow, not the session"; return 0
  fi
  # test/lint runners — these run in the post-commit gate, not in-session
  if printf '%s' "$_cmd" | grep -qE '(^|[^[:alnum:]_])(make|bats|pytest)([[:space:]]|$)'; then
    echo "test/lint runners run in the post-commit gate; do not run them in-session"; return 0
  fi
  # rm -rf / rm -fr (any flag bundle containing both r and f)
  if printf '%s' "$_cmd" | grep -qE '(^|[^[:alnum:]_])rm[[:space:]]+(-[[:alnum:]]*r[[:alnum:]]*f|-[[:alnum:]]*f[[:alnum:]]*r)'; then
    echo "rm -rf is blocked in-session"; return 0
  fi
  # remote access / network
  if printf '%s' "$_cmd" | grep -qE '(^|[^[:alnum:]_])(ssh|scp|curl|wget)([[:space:]]|$)'; then
    echo "remote/network access is blocked in-session"; return 0
  fi
  # environment / credential dumps (env / printenv as a command, not env-prefix vars)
  if printf '%s' "$_cmd" | grep -qE '(^|[;&|][[:space:]]*)(env|printenv)([[:space:]]|$)'; then
    echo "environment dumps are blocked in-session"; return 0
  fi
  # sensitive paths (shells rc, ssh keys, system config)
  if printf '%s' "$_cmd" | grep -qE '(/etc/|/var/|~/\.ssh|~/\.zsh|~/\.bash|~/\.[[:alnum:]]*rc)'; then
    echo "access to sensitive paths (/etc, /var, ~/.ssh, shell rc) is blocked in-session"; return 0
  fi
  return 1
}

# ---- executable body --------------------------------------------------------
_rite_hook_input=$(cat)

# Extract tool name + command. jq is a hard dependency (install.sh), but fall
# back to sed so a missing jq fails open (allow) rather than crashing the session.
if command -v jq >/dev/null 2>&1; then
  _rite_hook_tool=$(printf '%s' "$_rite_hook_input" | jq -r '.tool_name // empty' 2>/dev/null || true)
  _rite_hook_cmd=$(printf '%s' "$_rite_hook_input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
else
  _rite_hook_tool=$(printf '%s' "$_rite_hook_input" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)
  _rite_hook_cmd=$(printf '%s' "$_rite_hook_input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)
fi

# Only Bash tool calls are gated.
[ "${_rite_hook_tool:-}" = "Bash" ] || exit 0

_rite_hook_reason=$(_rite_hook_denial_reason "${_rite_hook_cmd:-}" || true)
if [ -n "$_rite_hook_reason" ]; then
  # JSON-escape the reason via jq; fall back to a plain quoted string.
  if command -v jq >/dev/null 2>&1; then
    _rite_hook_reason_json=$(printf '%s' "$_rite_hook_reason" | jq -R . 2>/dev/null || printf '"%s"' "$_rite_hook_reason")
  else
    _rite_hook_reason_json="\"$_rite_hook_reason\""
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$_rite_hook_reason_json"
  exit 0
fi
exit 0
