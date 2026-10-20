#!/bin/bash
# lib/utils/sanitize-output.sh
# Strip operator-local rtk wrapper commands from LLM-generated GitHub artifacts.
#
# Root cause: claude --print loads the operator's user-global ~/.claude/CLAUDE.md
# (which carries RTK hook instructions), so the model authors rtk-wrapped commands
# into generated issue bodies and PR comments. Those commands are unrunnable for
# any human or CI system without the operator's personal rtk hook installed.
#
# Sanitization is output-side (not input-side) — suppressing user-global CLAUDE.md
# loading at the provider call level would lose auth/config context. Output sanitization
# is the correct seam.
#
# Public API:
#   sanitize_generated_commands <body> [project_root]
#     Strips "rtk proxy <cmd>" → "<cmd>" and "rtk <cmd>" → "<cmd>" at
#     command positions (line-start, after backtick / $( / "| " / "&& ").
#     Prose mentions of "rtk" not at a command position are left untouched.
#     Prints the sanitized body on stdout; one print_info line to stderr when
#     anything is rewritten.
#
#     Grounded exception: when project_root's tracked files reference rtk
#     (git grep -qlw rtk), sanitization is skipped — the target repo genuinely
#     uses rtk and its commands must be preserved.
#
# Extension point: this is intentionally rtk-specific (rtk is the live failure —
# a generic "unknown tool" detector is unbounded). Add parallel checks here if
# another operator-local tool causes the same class of leak.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f sanitize_generated_commands >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Load print_info if not already available (tests may source this file directly)
if ! declare -f print_info >/dev/null 2>&1; then
  if [ -n "${RITE_LIB_DIR:-}" ]; then
    # shellcheck source=/dev/null
    source "$RITE_LIB_DIR/utils/colors.sh"
  fi
  # Fallback: guard against the RITE_LIB_DIR-unset case where colors.sh was
  # unavailable. Without this, a call to sanitize_generated_commands that
  # rewrites anything would exit 127 inside a $() substitution — the silent-death
  # pattern documented in CLAUDE.md "Silent death: pipelines inside $()".
  if ! declare -f print_info >/dev/null 2>&1; then
    print_info() { printf '[INFO] %s\n' "$*" >&2; }
  fi
fi

# sanitize_generated_commands <body> [project_root]
#
# Strips rtk wrapper prefixes at command positions:
#   "rtk proxy <cmd>" → "<cmd>"  (proxy subcommand stripped too)
#   "rtk <cmd>"       → "<cmd>"
#
# Command positions checked: line-start, after backtick, $(, "| ", "&& ".
# Order: proxy rules run before bare-rtk rules to avoid a double-strip.
#
# Grounded exception: when git grep finds "rtk" as a whole word in the project
# root's tracked files, that repo genuinely ships rtk commands — skip sanitization.
sanitize_generated_commands() {
  local _sgc_body="${1:-}"
  local _sgc_root="${2:-${RITE_PROJECT_ROOT:-}}"

  # Grounded exception: repos that use rtk keep their commands intact.
  # Extension point: add parallel checks here for other operator-local tools.
  if [ -n "${_sgc_root:-}" ] && git -C "$_sgc_root" grep -qlw rtk 2>/dev/null; then
    printf '%s' "$_sgc_body"
    return 0
  fi

  # Strip rtk wrappers at command positions.
  # Each sed call handles one position type; processing line-start before mid-line
  # prevents a double-strip on lines that start with an rtk call.
  # -E for ERE throughout; each substitution is a simple literal-string replacement.
  local _sgc_sanitized
  _sgc_sanitized=$(printf '%s' "$_sgc_body" | \
    sed -E 's/^rtk proxy //' | \
    sed -E 's/^rtk //' | \
    sed -E 's/`rtk proxy /`/g' | \
    sed -E 's/`rtk /`/g' | \
    sed -E 's/\$\(rtk proxy /\$(/g' | \
    sed -E 's/\$\(rtk /\$(/g' | \
    sed -E 's/([|] )rtk proxy /\1/g' | \
    sed -E 's/([|] )rtk /\1/g' | \
    sed -E 's/(&& )rtk proxy /\1/g' | \
    sed -E 's/(&& )rtk /\1/g' || true)

  if [ "${_sgc_sanitized}" = "${_sgc_body}" ]; then
    printf '%s' "$_sgc_body"
    return 0
  fi

  # Count changed lines as a proxy for "number of rtk wrappers stripped".
  local _sgc_count=0
  _sgc_count=$(diff \
    <(printf '%s\n' "$_sgc_body") \
    <(printf '%s\n' "$_sgc_sanitized") \
    | grep -c '^<' || true)
  print_info "Sanitized ${_sgc_count} rtk wrapper command(s) from generated body" >&2

  printf '%s' "$_sgc_sanitized"
}
