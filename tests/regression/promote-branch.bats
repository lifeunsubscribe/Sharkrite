#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/promote-branch.sh, bin/rite
# tests/regression/promote-branch.bats
#
# Regression tests for rite --promote <branch> (#1022).
#
# Tests verify:
#   1. bin/rite dispatch: --promote parses, rejects bad values, --dry-run plans.
#   2. Preflight: absent/empty ledger and zero unpromoted entries abort with
#      "nothing to promote" before any gh mutation.
#   3. Preflight: behind-main abort message contains the literal corrected command.
#   4. Re-run reuses an existing open promotion PR (gh pr edit, not pr create).
#   5. Full-suite failure (stub exits 1) aborts before the merge API call.
#   6. CRITICAL findings abort before the merge API call.
#   7. Full-branch promote never invokes merge-pr.sh (own-merge-path pin).
#   8. Post-merge: ledger entries flip to promoted=true, branch deleted,
#      per-issue comments attempted.

load '../helpers/setup'

# ---------------------------------------------------------------------------
# Shared minimal lib stubs written into a fake RITE_LIB_DIR so unit tests can
# source the real promote-branch.sh without network or filesystem side-effects.
# ---------------------------------------------------------------------------
_write_promote_stubs() {
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

# ---------------------------------------------------------------------------
# Helper: write a small runner script, chmod it, and echo its path.
# The caller provides the body (a heredoc expansion); this helper just
# handles the temp-file lifecycle so tests stay concise.
# ---------------------------------------------------------------------------
_write_runner() {
  local _path="$RITE_TEST_TMPDIR/runner_$$.sh"
  cat > "$_path"
  chmod +x "$_path"
  echo "$_path"
}

setup() {
  setup_test_tmpdir
}

teardown() {
  teardown_test_tmpdir
}

# ===========================================================================
# Group 1: bin/rite --promote dispatch
# ===========================================================================

# bin/rite checks for a git repository BEFORE it parses args, and
# setup_test_tmpdir cd's into a bare temp dir. Without an init the run dies on
# "Not inside a git repository" and never reaches --promote validation at all:
# `$status -ne 0` then passes for the wrong reason while the message assertion
# fails. That is exactly how both tests read on main. The repo is initialized
# per-test (hermetic — never the real checkout, which a real --promote could
# touch), and each test now also pins WHY it failed so the precondition can
# never masquerade as arg validation again.
_init_bare_repo_for_arg_test() {
  git init -q . >/dev/null 2>&1
  git config user.email t@t
  git config user.name t
}

@test "bin/rite --promote rejects missing value" {
  _init_bare_repo_for_arg_test
  run bash "$RITE_REPO_ROOT/bin/rite" --promote < /dev/null 2>&1 || true
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "\-\-promote"
  # It must be the arg-validation error, not a precondition bail.
  ! echo "$output" | grep -qi "not inside a git repository"
}

@test "bin/rite --promote rejects flag-shaped value" {
  _init_bare_repo_for_arg_test
  run bash "$RITE_REPO_ROOT/bin/rite" --promote --supervised < /dev/null 2>&1 || true
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "\-\-promote"
  ! echo "$output" | grep -qi "not inside a git repository"
}

@test "bin/rite --dry-run --promote <branch> prints plan and exits 0" {
  # RITE_DRY_RUN exits before sourcing promote-branch.sh, so no fake lib needed
  run env \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR" \
    RITE_DRY_RUN=true \
    bash "$RITE_REPO_ROOT/bin/rite" --promote "release-1.2" < /dev/null 2>&1

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "promote-branch.sh"
  echo "$output" | grep -q "release-1.2"
}

# ===========================================================================
# Group 2: Preflight — abort before any gh mutation
# ===========================================================================

@test "preflight: absent ledger aborts with 'nothing to promote'" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs "$_lib"

  local _runner
  _runner=$(_write_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { return 0; }
run_promote "no-ledger-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "nothing to promote"
}

@test "preflight: zero unpromoted entries aborts with 'nothing to promote'" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs "$_lib"

  # A ledger entry that is already promoted=true
  local _already
  _already="issue=10	pr=20	sha=aaa000	merged_at=2026-01-01T00:00:00Z	promoted=true"

  local _runner
  _runner=$(_write_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { printf '%s\n' "$_already"; }
run_promote "all-promoted-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "nothing to promote"
}

@test "preflight: behind-main abort message contains 'rite --sync <branch>'" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs "$_lib"

  local _entry="issue=42	pr=97	sha=abc1234500000000000000000000000000000000	merged_at=2026-01-01T00:00:00Z	promoted=false"

  # Fake git: rev-list returns "5" (branch is behind main)
  local _fake_bin="$RITE_TEST_TMPDIR/bin"
  mkdir -p "$_fake_bin"
  cat > "$_fake_bin/git" << 'GITEOF'
#!/bin/bash
for _arg in "$@"; do
  [ "$_arg" = "rev-list" ] && { echo "5"; exit 0; }
done
# Pass other git commands through or stub them
case "${1:-}" in
  ls-remote) echo "abc refs/heads/behind-branch"; exit 0 ;;
  worktree)  [ "${2:-}" = "add" ] && mkdir -p "${3:-}"; exit 0 ;;
  push|branch) exit 0 ;;
esac
exit 0
GITEOF
  chmod +x "$_fake_bin/git"

  local _runner
  _runner=$(_write_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { printf '%s\n' "$_entry"; }
run_promote "behind-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 1 ]
  # Abort message MUST contain the exact corrected command
  echo "$output" | grep -q "rite --sync behind-branch"
}

# ===========================================================================
# Group 3: Re-run reuses existing open promotion PR
# ===========================================================================

@test "re-run reuses an existing open promotion PR (gh pr edit, not create)" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs "$_lib"

  local _entry="issue=42	pr=97	sha=abc1234500000000000000000000000000000000	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _call_log="$RITE_TEST_TMPDIR/calls.log"

  local _full_suite="$RITE_TEST_TMPDIR/bin/rite-full-suite"
  mkdir -p "$(dirname "$_full_suite")"
  printf '#!/bin/bash\nexit 0\n' > "$_full_suite"
  chmod +x "$_full_suite"

  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-bin"
  mkdir -p "$_fake_bin"
  cat > "$_fake_bin/git" << 'GITEOF'
#!/bin/bash
for _arg in "$@"; do [ "$_arg" = "rev-list" ] && { echo "0"; exit 0; }; done
case "${1:-}" in
  ls-remote) echo "abc refs/heads/reuse-branch"; exit 0 ;;
  worktree)  [ "${2:-}" = "add" ] && mkdir -p "${3:-}"; exit 0 ;;
  push|branch) exit 0 ;;
esac
exit 0
GITEOF
  chmod +x "$_fake_bin/git"

  local _runner
  _runner=$(_write_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt-$$"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { printf '%s\n' "$_entry"; }
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context() { printf '' > "\${2:-/dev/null}"; return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues() { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)   echo "55"; return 0 ;;    # existing PR #55
        edit)   echo "PR_EDIT pr=\${3:-}" >> "$_call_log"; return 0 ;;
        create) echo "PR_CREATE" >> "$_call_log"; echo "99"; return 0 ;;
        view)
          printf '%s\n' "\$@" | grep -q "headRefOid" && echo "abc123" || true
          return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)  echo '{"merged":true}'; return 0 ;;
    issue) return 0 ;;
  esac
  return 0
}
run_promote "reuse-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1 || true

  # Must have edited the existing PR (not created a new one)
  grep -q "PR_EDIT pr=55" "$_call_log"
  ! grep -q "PR_CREATE" "$_call_log"
}

# ===========================================================================
# Group 3b: PR-creation argument shape — no --json flag; URL parsing
# ===========================================================================

@test "first-time promotion: gh pr create called without --json, PR number parsed from URL" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs "$_lib"

  local _entry="issue=42	pr=97	sha=abc1234500000000000000000000000000000000	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _call_log="$RITE_TEST_TMPDIR/pr_shape.log"

  mkdir -p "$RITE_TEST_TMPDIR/bin"
  printf '#!/bin/bash\nexit 0\n' > "$RITE_TEST_TMPDIR/bin/rite-full-suite"
  chmod +x "$RITE_TEST_TMPDIR/bin/rite-full-suite"

  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-bin-shape"
  mkdir -p "$_fake_bin"
  cat > "$_fake_bin/git" << 'GITEOF'
#!/bin/bash
for _a in "$@"; do [ "$_a" = "rev-list" ] && { echo "0"; exit 0; }; done
case "${1:-}" in
  rev-parse) echo "abc1234567890123456789012345678901234abcd"; exit 0 ;;
  ls-remote) echo "abc refs/heads/shape-branch"; exit 0 ;;
  worktree)  [ "${2:-}" = "add" ] && mkdir -p "${3:-}"; exit 0 ;;
  push|branch) exit 0 ;;
esac
exit 0
GITEOF
  chmod +x "$_fake_bin/git"

  local _runner
  _runner=$(_write_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt-$$"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { printf '%s\n' "$_entry"; }
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context() { printf '' > "\${2:-/dev/null}"; return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues() { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)   echo ""; return 0 ;;
        create)
          echo "GH_PR_CREATE_ARGS: \$*" >> "$_call_log"
          echo "https://github.com/owner/repo/pull/88"
          return 0 ;;
        edit)   return 0 ;;
        view)   return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)  echo '{"merged":true}'; return 0 ;;
    issue) return 0 ;;
  esac
  return 0
}
run_test_gate() { return 0; }
run_promote "shape-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 0 ]

  # gh pr create must NOT use --json flag
  ! grep -q "\-\-json" "$_call_log"

  # PR number must be correctly extracted from the URL output
  echo "$output" | grep -q "PR #88"
}

# ===========================================================================
# Group 4: Full-suite failure aborts before merge API call
# ===========================================================================

@test "full-suite failure aborts before merge API call" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs "$_lib"

  local _entry="issue=42	pr=97	sha=abc1234500000000000000000000000000000000	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _call_log="$RITE_TEST_TMPDIR/merge_calls.log"

  # Full-suite stub that exits 1
  mkdir -p "$RITE_TEST_TMPDIR/bin"
  printf '#!/bin/bash\necho "1 test failed"\nexit 1\n' > "$RITE_TEST_TMPDIR/bin/rite-full-suite"
  chmod +x "$RITE_TEST_TMPDIR/bin/rite-full-suite"

  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-bin2"
  mkdir -p "$_fake_bin"
  cat > "$_fake_bin/git" << 'GITEOF'
#!/bin/bash
for _a in "$@"; do [ "$_a" = "rev-list" ] && { echo "0"; exit 0; }; done
case "${1:-}" in
  ls-remote) echo "abc refs/heads/suite-branch"; exit 0 ;;
  worktree)  [ "${2:-}" = "add" ] && mkdir -p "${3:-}"; exit 0 ;;
  push|branch) exit 0 ;;
esac
exit 0
GITEOF
  chmod +x "$_fake_bin/git"

  local _runner
  _runner=$(_write_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt-$$"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { printf '%s\n' "$_entry"; }
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context() { printf '' > "\${2:-/dev/null}"; return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues() { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)  echo ""; return 0 ;;
        create) echo "88"; return 0 ;;
        view)
          printf '%s\n' "\$@" | grep -q "headRefOid" && echo "abc123" || true
          return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)  echo "MERGE_CALLED" >> "$_call_log"; echo '{"merged":true}'; return 0 ;;
    issue) return 0 ;;
  esac
  return 0
}
run_promote "suite-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 1 ]
  # Merge API must NOT have been called
  [ ! -f "$_call_log" ] || ! grep -q "MERGE_CALLED" "$_call_log"
}

# ===========================================================================
# Group 5: CRITICAL findings abort before merge API call
# ===========================================================================

@test "CRITICAL findings abort before merge API call" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs "$_lib"

  local _entry="issue=42	pr=97	sha=abc1234500000000000000000000000000000000	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _call_log="$RITE_TEST_TMPDIR/critical_merge.log"

  mkdir -p "$RITE_TEST_TMPDIR/bin"
  printf '#!/bin/bash\nexit 0\n' > "$RITE_TEST_TMPDIR/bin/rite-full-suite"
  chmod +x "$RITE_TEST_TMPDIR/bin/rite-full-suite"

  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-bin3"
  mkdir -p "$_fake_bin"
  cat > "$_fake_bin/git" << 'GITEOF'
#!/bin/bash
for _a in "$@"; do [ "$_a" = "rev-list" ] && { echo "0"; exit 0; }; done
case "${1:-}" in
  ls-remote) echo "abc refs/heads/crit-branch"; exit 0 ;;
  worktree)  [ "${2:-}" = "add" ] && mkdir -p "${3:-}"; exit 0 ;;
  push|branch) exit 0 ;;
esac
exit 0
GITEOF
  chmod +x "$_fake_bin/git"

  local _runner
  _runner=$(_write_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt-$$"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { printf '%s\n' "$_entry"; }
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context() { printf '' > "\${2:-/dev/null}"; return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
# detect_critical_issues returns 1 = CRITICAL found
detect_critical_issues() { echo "BLOCKER: CRITICAL issues found (1)" >&2; return 1; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)  echo ""; return 0 ;;
        create) echo "88"; return 0 ;;
        view)
          printf '%s\n' "\$@" | grep -q "headRefOid" && echo "abc123" || true
          return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)  echo "MERGE_CALLED" >> "$_call_log"; echo '{"merged":true}'; return 0 ;;
    issue) return 0 ;;
  esac
  return 0
}
run_promote "crit-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 1 ]
  [ ! -f "$_call_log" ] || ! grep -q "MERGE_CALLED" "$_call_log"
}

# ===========================================================================
# Group 6: Own-merge-path — merge-pr.sh is never sourced
# ===========================================================================

@test "full-branch promote never invokes merge-pr.sh" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs "$_lib"

  local _entry="issue=42	pr=97	sha=abc1234500000000000000000000000000000000	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _call_log="$RITE_TEST_TMPDIR/own_path.log"

  mkdir -p "$RITE_TEST_TMPDIR/bin"
  printf '#!/bin/bash\nexit 0\n' > "$RITE_TEST_TMPDIR/bin/rite-full-suite"
  chmod +x "$RITE_TEST_TMPDIR/bin/rite-full-suite"

  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-bin4"
  mkdir -p "$_fake_bin"
  cat > "$_fake_bin/git" << 'GITEOF'
#!/bin/bash
for _a in "$@"; do [ "$_a" = "rev-list" ] && { echo "0"; exit 0; }; done
case "${1:-}" in
  rev-parse) echo "deadbeef123456789012345678901234deadbeef"; exit 0 ;;
  ls-remote) echo "abc refs/heads/own-branch"; exit 0 ;;
  worktree)  [ "${2:-}" = "add" ] && mkdir -p "${3:-}"; exit 0 ;;
  push)  echo "GIT_PUSH $*" >> "${_PROMOTE_CALLLOG:-/dev/null}"; exit 0 ;;
  branch) exit 0 ;;
esac
exit 0
GITEOF
  chmod +x "$_fake_bin/git"

  local _runner
  _runner=$(_write_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt-$$"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { printf '%s\n' "$_entry"; }
integration_ledger_mark_promoted() {
  echo "LEDGER_MARKED branch=\$1 issue=\$2" >> "$_call_log"
}
gather_promotion_context() { printf '' > "\${2:-/dev/null}"; return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues() { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)  echo ""; return 0 ;;
        create) echo "77"; return 0 ;;
        view)
          printf '%s\n' "\$@" | grep -q "headRefOid" && echo "deadbeef" || true
          return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)
      echo "DIRECT_API_MERGE \$*" >> "$_call_log"
      echo '{"merged":true}'
      return 0 ;;
    issue)
      echo "ISSUE_COMMENT \$*" >> "$_call_log"
      return 0 ;;
  esac
  return 0
}
run_test_gate() { return 0; }
run_promote "own-branch" 2>&1
# Report whether merge-pr.sh was sourced
echo "MERGE_PR_SOURCED_FLAG=${_MERGE_PR_SH_SOURCED_IN_TEST:-false}"
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 0 ]

  # Direct REST merge API must have been called (own merge path)
  grep -q "DIRECT_API_MERGE" "$_call_log"

  # merge-pr.sh stub recording flag must NOT be set — it was never sourced
  ! echo "$output" | grep -q "MERGE_PR_SOURCED_FLAG=true"
}

# ===========================================================================
# Group 7: Post-merge state
# ===========================================================================

@test "post-merge: ledger marked, branch deleted, issue comments posted" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs "$_lib"

  # Two unpromoted entries
  local _e1="issue=42	pr=97	sha=abc1234500000000000000000000000000000000	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _e2="issue=55	pr=110	sha=def1234500000000000000000000000000000000	merged_at=2026-01-02T00:00:00Z	promoted=false"
  local _call_log="$RITE_TEST_TMPDIR/post_merge.log"

  mkdir -p "$RITE_TEST_TMPDIR/bin"
  printf '#!/bin/bash\nexit 0\n' > "$RITE_TEST_TMPDIR/bin/rite-full-suite"
  chmod +x "$RITE_TEST_TMPDIR/bin/rite-full-suite"

  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-bin5"
  mkdir -p "$_fake_bin"
  cat > "$_fake_bin/git" << 'GITEOF'
#!/bin/bash
for _a in "$@"; do [ "$_a" = "rev-list" ] && { echo "0"; exit 0; }; done
case "${1:-}" in
  rev-parse) echo "deadbeef123456789012345678901234deadbeef"; exit 0 ;;
  ls-remote) echo "abc refs/heads/pm-branch"; exit 0 ;;
  worktree)  [ "${2:-}" = "add" ] && mkdir -p "${3:-}"; exit 0 ;;
  push)
    printf 'GIT_PUSH %s\n' "$*" >> "${_PROMOTE_CALLLOG:-/dev/null}"
    exit 0 ;;
  branch)
    printf 'GIT_BRANCH %s\n' "$*" >> "${_PROMOTE_CALLLOG:-/dev/null}"
    exit 0 ;;
esac
exit 0
GITEOF
  chmod +x "$_fake_bin/git"

  local _runner
  _runner=$(_write_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt-$$"
export PATH="$_fake_bin:\$PATH"
export _PROMOTE_CALLLOG="$_call_log"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() {
  printf '%s\n' "$_e1"
  printf '%s\n' "$_e2"
}
integration_ledger_mark_promoted() {
  echo "LEDGER_MARKED branch=\$1 issue=\$2" >> "$_call_log"
}
gather_promotion_context() { printf '' > "\${2:-/dev/null}"; return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues() { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)  echo ""; return 0 ;;
        create) echo "200"; return 0 ;;
        view)
          printf '%s\n' "\$@" | grep -q "headRefOid" && echo "deadbeef" || true
          return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)
      echo "MERGE_CALLED" >> "$_call_log"
      echo '{"merged":true}'
      return 0 ;;
    issue)
      echo "ISSUE_COMMENT issue=\${3:-?}" >> "$_call_log"
      return 0 ;;
  esac
  return 0
}
run_test_gate() { return 0; }
run_promote "pm-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 0 ]

  # Both ledger entries must be marked promoted
  grep -q "LEDGER_MARKED branch=pm-branch issue=42" "$_call_log"
  grep -q "LEDGER_MARKED branch=pm-branch issue=55" "$_call_log"

  # Integration branch must be deleted (remote: git push --delete; local: git branch -D)
  grep -qiE "GIT_PUSH.*--delete.*pm-branch" "$_call_log"
  grep -qiE "GIT_BRANCH.*-D.*pm-branch" "$_call_log"

  # Per-issue "Promoted to main" comments must be attempted for both issues
  grep -q "ISSUE_COMMENT issue=42" "$_call_log"
  grep -q "ISSUE_COMMENT issue=55" "$_call_log"
}

# ===========================================================================
# Group 8: Placement pin — git worktree prune is unconditional
# ===========================================================================

@test "git worktree prune is called regardless of whether a stale worktree existed" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs "$_lib"

  local _entry="issue=42	pr=97	sha=abc1234500000000000000000000000000000000	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _call_log="$RITE_TEST_TMPDIR/prune_pin.log"

  mkdir -p "$RITE_TEST_TMPDIR/bin"
  printf '#!/bin/bash\nexit 0\n' > "$RITE_TEST_TMPDIR/bin/rite-full-suite"
  chmod +x "$RITE_TEST_TMPDIR/bin/rite-full-suite"

  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-prune"
  mkdir -p "$_fake_bin"
  # Records every `git worktree *` call to the call log so we can assert prune ran
  cat > "$_fake_bin/git" << 'GITEOF'
#!/bin/bash
for _a in "$@"; do [ "$_a" = "rev-list" ] && { echo "0"; exit 0; }; done
case "${1:-}" in
  rev-parse) echo "abc1234567890123456789012345678901234abcd"; exit 0 ;;
  ls-remote) echo "abc refs/heads/prune-branch"; exit 0 ;;
  worktree)
    printf 'GIT_WORKTREE %s\n' "$*" >> "${_PROMOTE_CALLLOG:-/dev/null}"
    [ "${2:-}" = "add" ] && mkdir -p "${3:-}"
    exit 0 ;;
  push|branch) exit 0 ;;
esac
exit 0
GITEOF
  chmod +x "$_fake_bin/git"

  local _runner
  _runner=$(_write_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt"
export PATH="$_fake_bin:\$PATH"
export _PROMOTE_CALLLOG="$_call_log"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { printf '%s\n' "$_entry"; }
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context() { printf '' > "\${2:-/dev/null}"; return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues() { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)   echo ""; return 0 ;;
        create) echo "55"; return 0 ;;
        view)   return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)  echo '{"merged":true}'; return 0 ;;
    issue) return 0 ;;
  esac
  return 0
}
run_test_gate() { return 0; }
run_promote "prune-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 0 ]

  # git worktree prune must have been called even though no stale worktree existed
  grep -qE "GIT_WORKTREE.*prune" "$_call_log"
}

# ===========================================================================
# Group 9: SHA re-capture after supervised sync
# ===========================================================================

@test "supervised sync re-captures _branch_sha before passing to merge API" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs "$_lib"

  # integration-sync.sh stub needed for the supervised sync code path
  cat > "$_lib/utils/integration-sync.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f sync_integration_branch >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
sync_integration_branch() { return 0; }
STUB

  local _entry="issue=42	pr=97	sha=abc1234500000000000000000000000000000000	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _call_log="$RITE_TEST_TMPDIR/sha_recp.log"
  # State file: tracks how many rev-list calls have fired; used by rev-parse too
  local _git_state="$RITE_TEST_TMPDIR/git_revlist_state.txt"
  printf '0\n' > "$_git_state"

  mkdir -p "$RITE_TEST_TMPDIR/bin"
  printf '#!/bin/bash\nexit 0\n' > "$RITE_TEST_TMPDIR/bin/rite-full-suite"
  chmod +x "$RITE_TEST_TMPDIR/bin/rite-full-suite"

  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-sha-recp"
  mkdir -p "$_fake_bin"
  # Stateful stub: first rev-list returns 1 (behind main); after state flips, returns 0.
  # rev-parse returns sha-pre-sync before state flips, sha-post-sync after.
  cat > "$_fake_bin/git" << 'GITEOF'
#!/bin/bash
_state="${_GIT_STATE_FILE:-/dev/null}"
_n=0
[ -f "$_state" ] && _n=$(cat "$_state" 2>/dev/null || echo 0)
for _a in "$@"; do
  [ "$_a" = "rev-list" ] && {
    if [ "$_n" -eq 0 ]; then
      printf '1\n'
      printf '1\n' > "$_state"
    else
      printf '0\n'
    fi
    exit 0
  }
done
case "${1:-}" in
  rev-parse)
    _nc=0; [ -f "$_state" ] && _nc=$(cat "$_state" 2>/dev/null || echo 0)
    [ "$_nc" -gt 0 ] && printf 'sha-post-sync\n' || printf 'sha-pre-sync\n'
    exit 0 ;;
  ls-remote) echo "abc refs/heads/sha-recp-branch"; exit 0 ;;
  worktree)  [ "${2:-}" = "add" ] && mkdir -p "${3:-}"; exit 0 ;;
  push|branch) exit 0 ;;
esac
exit 0
GITEOF
  chmod +x "$_fake_bin/git"

  local _runner
  _runner=$(_write_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt"
export RITE_SUPERVISED=true
export PATH="$_fake_bin:\$PATH"
export _GIT_STATE_FILE="$_git_state"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe() { return 0; }
integration_ledger_entries() { printf '%s\n' "$_entry"; }
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context() { printf '' > "\${2:-/dev/null}"; return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues() { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)   echo ""; return 0 ;;
        create) echo "55"; return 0 ;;
        view)   return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)  printf 'MERGE_API: %s\n' "\$*" >> "$_call_log"; echo '{"merged":true}'; return 0 ;;
    issue) return 0 ;;
  esac
  return 0
}
run_test_gate() { return 0; }
run_promote "sha-recp-branch" 2>&1
RUNEOF
)

  # Pipe 'y' to answer the supervised sync prompt
  run bash "$_runner" <<< "y" 2>&1
  [ "$status" -eq 0 ]

  # The merge API must have been called with the post-sync SHA, not the pre-sync SHA
  grep -q "sha=sha-post-sync" "$_call_log"
  ! grep -q "sha=sha-pre-sync" "$_call_log"
}

# ===========================================================================
# Structural: coverage header must be present and accurate
# ===========================================================================

@test "promote-branch.bats has correct sharkrite-test-covers header" {
  head -2 "$RITE_REPO_ROOT/tests/regression/promote-branch.bats" \
    | grep -q "sharkrite-test-covers: lib/core/promote-branch.sh, bin/rite"
}
