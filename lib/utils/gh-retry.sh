#!/bin/bash
# lib/utils/gh-retry.sh — Robust gh invocations with retry + error distinction.
#
# Why this exists: `gh ... 2>/dev/null || echo "{}"` swallows transient
# failures (secondary rate limit, network blips, 5xx) and routes them through
# the same code path as legitimate 404s. On 2026-05-26 this produced false
# success — a batch finished its busy run on issue #4, hit a rate-limit on
# the next gh issue view, and silently marked issue #7 as "already done"
# because the empty response landed in the "issue not OPEN" branch.
#
# gh_safe — invoke gh with up-to-3 attempts and exponential backoff.
#
# Usage:
#   if out=$(gh_safe "fetch issue $N" issue view "$N" --json title,state); then
#     handle "$out"
#   else
#     case $? in
#       4) handle_not_found ;;   # genuine HTTP 404
#       *) handle_failure ;;     # persistent / unknown failure
#     esac
#   fi
#
# Contract:
#   - Returns 0 on success. Writes captured stdout to stdout. Stdout is
#     guaranteed non-empty (empty-stdout-with-exit-0 is treated as failure).
#   - Returns 4 on HTTP 404 / "Could not resolve to" — caller may interpret
#     as "issue/PR does not exist." No retry attempted.
#   - Returns 1 on persistent failure (3 attempts exhausted, non-404 error).
#     Diagnostic (command, exit code, captured stderr) is printed to stderr
#     so the failure is never silent.
#
# Caller rules:
#   - DO NOT wrap with `2>/dev/null` — that defeats the diagnostic.
#   - DO NOT chain with `|| echo "{}"` — that re-introduces the silent-failure
#     bug this helper exists to prevent.
#   - DO check the exit code. Treat empty result as a hard error (never
#     "fall through to issue-closed path").

gh_safe() {
  local _label="$1"
  shift

  local _max=3
  local _delays=(2 8)
  local _attempt _stdout _stderr _exit _delay

  for _attempt in $(seq 1 "$_max"); do
    _stderr=$(mktemp)
    _stdout=$(gh "$@" 2>"$_stderr")
    _exit=$?

    # Success requires both exit 0 AND non-empty stdout. A gh call that
    # returns exit 0 with empty stdout is the exact failure mode that
    # caused the workflow-runner.sh:1455 false-success bug.
    if [ "$_exit" -eq 0 ] && [ -n "$_stdout" ]; then
      rm -f "$_stderr"
      printf '%s' "$_stdout"
      return 0
    fi

    # 404 / not-found — never retry, return distinct exit code.
    if [ -s "$_stderr" ] && grep -qiE 'HTTP 404|Could not resolve to|GraphQL.*Could not resolve' "$_stderr"; then
      rm -f "$_stderr"
      return 4
    fi

    if [ "$_attempt" -eq "$_max" ]; then
      {
        echo ""
        echo "❌ gh call failed after $_max attempts: $_label"
        echo "   Command: gh $*"
        echo "   Exit code: $_exit"
        if [ -s "$_stderr" ]; then
          echo "   stderr:"
          sed 's/^/     /' "$_stderr"
        else
          echo "   stderr: (empty)"
        fi
        [ -z "$_stdout" ] && [ "$_exit" -eq 0 ] && \
          echo "   note: exit 0 with empty stdout — treating as failure"
      } >&2
      rm -f "$_stderr"
      return 1
    fi

    _delay=${_delays[$((_attempt - 1))]}
    {
      echo "⚠️  gh call '$_label' failed (attempt $_attempt/$_max, exit $_exit) — retrying in ${_delay}s"
      [ -s "$_stderr" ] && head -3 "$_stderr" | sed 's/^/    /'
    } >&2
    rm -f "$_stderr"
    sleep "$_delay"
  done

  return 1
}

export -f gh_safe 2>/dev/null || true
