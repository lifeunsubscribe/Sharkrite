#!/usr/bin/env bash
# Shared stub writer for promote-branch.sh unit tests.
#
# Sourced by tests that source the real promote-branch.sh in a subprocess runner
# so they can avoid network/filesystem side-effects without maintaining duplicate
# stub code in each bats file.
#
# Usage (in a bats file):
#   load '../helpers/promote-stubs'
#   ...
#   _write_promote_stubs_base "$_lib"

# ---------------------------------------------------------------------------
# Write minimal lib stubs into a fake RITE_LIB_DIR so a subprocess runner can
# source the real promote-branch.sh without network or filesystem side-effects.
#
# Arguments:
#   $1  path to the fake lib directory (created if absent)
#
# Each stub uses a function-sentinel guard so sourcing it twice is safe.
# local-review.sh logs to ${_PROMOTE_CALLLOG:-/dev/null} — set _PROMOTE_CALLLOG
# before running the runner if you need to assert it was called.
# ---------------------------------------------------------------------------
_write_promote_stubs_base() {
  local _lib="$1"
  mkdir -p "$_lib/utils" "$_lib/core" "$_lib/providers"

  cat > "$_lib/utils/config.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f _pb_config_stub >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
_pb_config_stub() { true; }
RITE_DATA_DIR="${RITE_DATA_DIR:-.rite}"
RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT:-$(pwd)}"
RITE_LIB_DIR="${RITE_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/.."}"
RITE_PROJECT_NAME="${RITE_PROJECT_NAME:-fake-project}"
RITE_INSTALL_DIR="${RITE_INSTALL_DIR:-$(dirname "${BASH_SOURCE[0]}")/../..}"
RITE_STATE_DIR="${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}"
RITE_WORKTREE_DIR="${RITE_WORKTREE_DIR:-/tmp/test-worktrees}"
export RITE_DATA_DIR RITE_PROJECT_ROOT RITE_LIB_DIR RITE_PROJECT_NAME
export RITE_INSTALL_DIR RITE_STATE_DIR RITE_WORKTREE_DIR
STUB

  cat > "$_lib/utils/colors.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f print_info >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
print_header()  { echo "=== $* ==="; }
print_info()    { echo "[INFO] $*"; }
print_step()    { echo "[STEP] $*"; }
print_success() { echo "[OK] $*"; }
print_warning() { echo "[WARN] $*" >&2; }
print_error()   { echo "[ERROR] $*" >&2; }
STUB

  cat > "$_lib/utils/logging.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f _diag >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
_diag() { true; }
verbose_header()  { true; }
verbose_info()    { true; }
verbose_step()    { true; }
verbose_success() { true; }
verbose_warning() { true; }
STUB

  cat > "$_lib/utils/gh-retry.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f gh_safe >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
gh_safe() { true; }
STUB

  cat > "$_lib/utils/git-helpers.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f git_fetch_safe >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
git_fetch_safe() { return 0; }
rmdir_empty_worktree_container() { return 0; }
STUB

  cat > "$_lib/utils/blocker-rules.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f detect_critical_issues >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
detect_critical_issues() { return 0; }
STUB

  cat > "$_lib/utils/integration-ledger.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f integration_ledger_append >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
integration_ledger_append()        { return 0; }
integration_ledger_entries()       { return 0; }
integration_ledger_mark_promoted() { return 0; }
STUB

  cat > "$_lib/providers/provider-interface.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f provider_resolve_model >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
provider_resolve_model()           { echo "claude-sonnet-4-6"; }
provider_run_prompt_with_timeout() { echo "stub narrative"; return 0; }
STUB

  cat > "$_lib/utils/promotion-composer.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f compose_promotion_pr_body >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
gather_promotion_context()    { return 0; }
compose_promotion_pr_body()   { echo "stub promotion body"; return 0; }
STUB

  cat > "$_lib/core/local-review.sh" << 'STUB'
#!/bin/bash
echo "local-review-called pr=$1" >> "${_PROMOTE_CALLLOG:-/dev/null}"
exit 0
STUB
  chmod +x "$_lib/core/local-review.sh"

  cat > "$_lib/utils/markers.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f rite_markers_loaded >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
rite_markers_loaded() { return 0; }
RITE_MARKER_REVIEW="sharkrite-local-review"
RITE_MARKER_ASSESSMENT="sharkrite-assessment"
RITE_MARKER_FOLLOWUP="sharkrite-followup-issue"
export RITE_MARKER_REVIEW RITE_MARKER_ASSESSMENT RITE_MARKER_FOLLOWUP
STUB

  # Recording merge-pr.sh stub: if this file is ever sourced, it sets a flag.
  cat > "$_lib/core/merge-pr.sh" << 'STUB'
#!/bin/bash
_MERGE_PR_SH_SOURCED_IN_TEST=true
STUB
}
