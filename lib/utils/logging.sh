#!/bin/bash
# lib/utils/logging.sh - Verbose-aware output functions
#
# Wraps the print_* functions from colors.sh with verbose gating.
# Output only appears when RITE_VERBOSE=true (set explicitly via --verbose
# or implicitly via --supervised).
#
# Usage:
#   source "$RITE_LIB_DIR/utils/logging.sh"
#   verbose_header "Section Title"
#   verbose_echo "detail line"
#   if is_verbose; then
#     echo "multi-line block"
#   fi

# Ensure colors.sh is loaded (idempotent — already sourced by most callers)
if ! declare -f print_header &>/dev/null; then
  source "${RITE_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}/utils/colors.sh"
fi

# Check if verbose output is enabled
is_verbose() {
  [ "${RITE_VERBOSE:-false}" = "true" ]
}

# Verbose-only output functions (no-op when not verbose)
verbose_header()  { is_verbose && print_header "$1"  || true; }
verbose_echo()    { is_verbose && echo "$@"           || true; }
verbose_info()    { is_verbose && print_info "$1"     || true; }
verbose_status()  { is_verbose && print_status "$1"   || true; }
verbose_success() { is_verbose && print_success "$1"  || true; }
verbose_warning() { is_verbose && print_warning "$1"  || true; }
verbose_step()    { is_verbose && print_step "$1"     || true; }

# Export for use in subshells
export RITE_VERBOSE
export -f is_verbose verbose_header verbose_echo verbose_info verbose_status verbose_success verbose_warning verbose_step 2>/dev/null || true
