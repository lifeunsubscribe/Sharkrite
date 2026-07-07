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
# return 1 (no output) when the command is allowed. Two anchor conventions:
# word anchors ((^|[^[:alnum:]_]) ... ([[:space:]]|$)) for tokens forbidden
# anywhere in the string (git/gh/rm/network — "makefile"/"cmake" still don't
# match "make"-style rules), and the command-POSITION anchor $_cmd_pos for
# tokens forbidden only as the executed command (runners, env dumps), so path
# arguments naming them don't trip the rule (issue #994).
_rite_hook_denial_reason() {
  _cmd="$1"
  # Command-position anchor (issue #994): start of the string or of a segment
  # after ; & | ( $( `, optionally behind wrapper words (env/command/npx/
  # nohup/time/xargs/sudo), a `[g]timeout [flags] DURATION` prefix, or VAR=val
  # assignments. grep is line-based, so newline-separated commands anchor via
  # ^ per line. A path ARGUMENT (cp tests/foo.bats /tmp) never sits at command
  # position. The regex is quote-blind — two accepted residuals: a separator
  # inside quotes ("echo 'a; bats b'") still denies (fails closed), and a
  # runner quoted into a nested shell ("bash -c 'bats t/'") is allowed (fails
  # open; the nested shell's own tool calls are still hook-gated).
  _cmd_pos='(^|[;&|(]|[$][(]|`)[[:space:]]*((env|command|npx|nohup|time|xargs|sudo)[[:space:]]+|g?timeout[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[0-9]+[smhd]?[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
  # git commit / git push (read-only git is allowed: status, diff, log, add, ...)
  if printf '%s' "$_cmd" | grep -qE '(^|[^[:alnum:]_])git[[:space:]]+(commit|push)([^[:alnum:]_]|$)'; then
    echo "git commit/push is handled by the rite workflow after this session"; return 0
  fi
  # gh — the workflow owns all GitHub interaction
  if printf '%s' "$_cmd" | grep -qE '(^|[^[:alnum:]_])gh([[:space:]]|$)'; then
    echo "gh commands are handled by the rite workflow, not the session"; return 0
  fi
  # test/lint runners — these run in the post-commit gate, not in-session.
  # Command-position anchored (issue #994): a .bats/make/pytest path argument
  # (cp/ls/bash -n/git add on a test file) must not deny. ([^[:space:];&|]*/)?
  # keeps path-INVOKED runners denied (/usr/local/bin/bats, node_modules/.bin/
  # bats); direct-exec of a test file (./tests/foo.bats) is deliberately
  # allowed — the rule targets the runner, not test files named like it.
  if printf '%s' "$_cmd" | grep -qE "${_cmd_pos}([^[:space:];&|]*/)?(make|bats|pytest|python[0-9.]*[[:space:]]+-m[[:space:]]+pytest)([[:space:]]|$)"; then
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
  # environment / credential dumps (env / printenv as a command). Shares the
  # command-position anchor — strict superset of the old bespoke (^|[;&|]…)
  # anchor (additionally denies "FOO=1 env"; allows nothing new).
  if printf '%s' "$_cmd" | grep -qE "${_cmd_pos}(env|printenv)([[:space:]]|$)"; then
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
