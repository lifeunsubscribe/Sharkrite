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
#
# Write guard: for Edit/Write/MultiEdit/NotebookEdit calls, a target file inside
# the PRIMARY checkout is denied when the session runs in a linked worktree —
# the edit would never reach the PR and would dirty the operator's checkout
# (freshup #597, 2026-11-15). The denial names the same file inside the worktree.
set -euo pipefail

# Bash 4+ re-exec guard (issue #1361 fallout — see #1374).
#
# lib/utils/gate-runners.sh nests `case` statements inside process
# substitutions, which bash 3.2 cannot parse, so it refuses to load under 3.2.
# On macOS /bin/bash IS 3.2, so any #!/bin/bash file that reaches it — directly
# or through test-gate.sh / gate-verdict.sh — dies before doing any work.
#
# #1374 guarded the five entry points known at the time and missed the rest:
# create-pr.sh then died the same way one phase later. Rather than chase them
# one at a time, every executable #!/bin/bash file in lib/ now carries this.
# It is inert when the file is sourced (the BASH_SOURCE test is false), so it
# costs nothing for the ones that are only ever libraries.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  for _newer_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$_newer_bash" ] && [ "$_newer_bash" != "${BASH:-}" ]; then
      exec "$_newer_bash" "$0" "$@"
    fi
  done
  echo "Error: requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi

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
  # tools/sharkrite-lint.sh is permitted in-session: it matches none of the
  # deny patterns below (make|bats|pytest) so it falls through to return 1.
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

# True when path $1 is $2 itself or sits beneath it.
_rite_hook_path_under() {
  case "$1" in
    "$2"|"$2"/*) return 0 ;;
  esac
  return 1
}

# Echo a reason and return 0 when the file a write tool targets ($1) sits in the
# primary checkout while the session ($2 = its launch directory) runs in a
# linked worktree of that checkout; return 1 (no output) otherwise.
#
# Allowed by construction: a session launched in the primary checkout itself
# (interactive use, repos without worktrees), any path under the session's own
# worktree — tested on the path as written, so the worktree's .rite and .venv
# symlinks into the primary checkout stay writable — the shared
# <primary>/.rite/ state dir, and every path outside the repository. Anything
# that cannot be resolved (not a git repo, relative path, bare repo) is allowed:
# the hook fails open.
_rite_hook_write_denial_reason() {
  _wpath="$1"
  _wsession="$2"
  [ -n "$_wpath" ] && [ -n "$_wsession" ] || return 1
  case "$_wpath" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -d "$_wsession" ] || return 1

  _wtop=$(git -C "$_wsession" rev-parse --show-toplevel 2>/dev/null || true)
  _wcommon=$(cd "$_wsession" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P || true)
  [ -n "$_wtop" ] && [ -n "$_wcommon" ] || return 1
  # A normal clone's common dir is <primary>/.git; anything else (bare repo,
  # GIT_DIR tricks) has no primary checkout to protect.
  [ "${_wcommon##*/}" = ".git" ] || return 1
  _wprimary="${_wcommon%/.git}"
  _wtop_phys=$(cd "$_wtop" 2>/dev/null && pwd -P || true)
  [ -n "$_wtop_phys" ] || return 1
  # The session is in the primary checkout itself: nothing to redirect.
  [ "$_wtop_phys" != "$_wprimary" ] || return 1

  # Under this session's worktree, as written (logical or physical spelling).
  if _rite_hook_path_under "$_wpath" "$_wtop" || _rite_hook_path_under "$_wpath" "$_wtop_phys" \
     || _rite_hook_path_under "$_wpath" "${_wsession%/}"; then
    return 1
  fi

  # Resolve the deepest existing ancestor so /tmp vs /private/tmp spellings of
  # the primary checkout compare equal (the target file may not exist yet).
  _wdir="${_wpath%/*}"
  _wrest="/${_wpath##*/}"
  while [ -n "$_wdir" ] && [ ! -d "$_wdir" ]; do
    _wrest="/${_wdir##*/}${_wrest}"
    _wdir="${_wdir%/*}"
  done
  _wphys="$_wpath"
  if [ -n "$_wdir" ]; then
    _wdir_phys=$(cd "$_wdir" 2>/dev/null && pwd -P || true)
    if [ -n "$_wdir_phys" ]; then
      _wphys="${_wdir_phys}${_wrest}"
    fi
  fi

  # A symlink inside the worktree may have resolved back under the worktree.
  if _rite_hook_path_under "$_wphys" "$_wtop_phys"; then
    return 1
  fi
  _rite_hook_path_under "$_wphys" "$_wprimary" || return 1
  # Shared sharkrite state (scratchpad, logs) lives in the primary checkout.
  if _rite_hook_path_under "$_wphys" "$_wprimary/.rite"; then
    return 1
  fi

  echo "this session works in the worktree ${_wtop}; ${_wpath} is in the primary checkout and would never reach the PR. Edit ${_wtop}${_wphys#"$_wprimary"} instead"
  return 0
}

# Print the deny decision for reason $1 and exit 0.
_rite_hook_emit_deny() {
  # JSON-escape the reason via jq; fall back to a plain quoted string.
  if command -v jq >/dev/null 2>&1; then
    _rite_hook_reason_json=$(printf '%s' "$1" | jq -R . 2>/dev/null || printf '"%s"' "$1")
  else
    _rite_hook_reason_json="\"$1\""
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$_rite_hook_reason_json"
  exit 0
}

# ---- executable body --------------------------------------------------------
_rite_hook_input=$(cat)

# Extract tool name + command. jq is a hard dependency (install.sh), but fall
# back to sed so a missing jq fails open (allow) rather than crashing the session.
_rite_hook_path=""
_rite_hook_cwd=""
if command -v jq >/dev/null 2>&1; then
  _rite_hook_tool=$(printf '%s' "$_rite_hook_input" | jq -r '.tool_name // empty' 2>/dev/null || true)
  _rite_hook_cmd=$(printf '%s' "$_rite_hook_input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
  _rite_hook_path=$(printf '%s' "$_rite_hook_input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)
  _rite_hook_cwd=$(printf '%s' "$_rite_hook_input" | jq -r '.cwd // empty' 2>/dev/null || true)
else
  _rite_hook_tool=$(printf '%s' "$_rite_hook_input" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)
  _rite_hook_cmd=$(printf '%s' "$_rite_hook_input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)
fi

case "${_rite_hook_tool:-}" in
  Bash)
    _rite_hook_reason=$(_rite_hook_denial_reason "${_rite_hook_cmd:-}" || true)
    ;;
  Edit|Write|MultiEdit|NotebookEdit)
    # The provider pins the directory the session was launched in; the event's
    # own cwd follows the model's `cd` and is only the fallback.
    _rite_hook_reason=$(_rite_hook_write_denial_reason "${_rite_hook_path:-}" \
      "${_RITE_HOOK_SESSION_DIR:-${_rite_hook_cwd:-$PWD}}" 2>/dev/null || true)
    ;;
  *)
    # Every other tool is ungated.
    exit 0
    ;;
esac

if [ -n "${_rite_hook_reason:-}" ]; then
  _rite_hook_emit_deny "$_rite_hook_reason"
fi
exit 0
