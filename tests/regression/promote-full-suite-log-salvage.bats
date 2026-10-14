#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/promote-branch.sh
# tests/regression/promote-full-suite-log-salvage.bats
#
# Regression tests for full-suite log and flag salvage before promote worktree
# removal (#1210). The gate subshell runs with RITE_PROJECT_ROOT set to the
# temp worktree, so any rite-full-suite log lands inside the worktree and dies
# with it unless promote-branch.sh copies it before git worktree remove.
#
# Tests verify:
#   1. Failing gate: full-suite log is copied to project .rite/logs/
#   2. Failing gate: failure message prints the log path
#   3. Failing gate: failure flag is copied to project .rite/state/
#   4. Passing gate: no stray flag copied to project .rite/state/
#   5. Worktree is removed in both failure and success outcomes

load '../helpers/setup'

# ---------------------------------------------------------------------------
# Shared fake lib stubs (minimal — only deps promote-branch.sh sources)
# ---------------------------------------------------------------------------
_write_salvage_stubs() {
  local _lib="$1"
  mkdir -p "$_lib/utils" "$_lib/core" "$_lib/providers"

  cat > "$_lib/utils/config.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f _pb_salvage_cfg >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
_pb_salvage_cfg() { true; }
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
exit 0
STUB
  chmod +x "$_lib/core/local-review.sh"

  cat > "$_lib/core/merge-pr.sh" << 'STUB'
#!/bin/bash
_MERGE_PR_SH_SOURCED_IN_TEST=true
STUB
}

# ---------------------------------------------------------------------------
# Helper: write a runner script, chmod it, return its path.
# ---------------------------------------------------------------------------
_write_salvage_runner() {
  local _path="$RITE_TEST_TMPDIR/runner_salvage_$$.sh"
  cat > "$_path"
  chmod +x "$_path"
  echo "$_path"
}

# ---------------------------------------------------------------------------
# Helper: build the fake git binary that handles worktree add/remove.
# Creates the worktree dir on "add" and deletes it on "remove" so the
# worktree-removed assertions work without a real git repo.
# ---------------------------------------------------------------------------
_write_fake_git() {
  local _fake_bin="$1"
  mkdir -p "$_fake_bin"
  cat > "$_fake_bin/git" << 'GITEOF'
#!/bin/bash
for _a in "$@"; do [ "$_a" = "rev-list" ] && { echo "0"; exit 0; }; done
case "${1:-}" in
  rev-parse)  echo "deadbeefdeadbeef1234567890123456deadbeef"; exit 0 ;;
  ls-remote)  echo "abc refs/heads/feature-x"; exit 0 ;;
  worktree)
    case "${2:-}" in
      add)    mkdir -p "${3:-}"; exit 0 ;;
      remove) rm -rf "${3:-}"; exit 0 ;;
    esac
    exit 0 ;;
  push|branch|prune) exit 0 ;;
esac
exit 0
GITEOF
  chmod +x "$_fake_bin/git"
}

setup() {
  setup_test_tmpdir
}

teardown() {
  teardown_test_tmpdir
}

# ===========================================================================
# Failure path: gate writes log + flag to worktree .rite/, then exits 1
# ===========================================================================

@test "failing gate: full-suite log is salvaged to project .rite/logs/" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_salvage_stubs "$_lib"
  local _entry="issue=42	pr=97	sha=abc123	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _wt_base="$RITE_TEST_TMPDIR/worktrees"
  local _fake_bin="$RITE_TEST_TMPDIR/fakebin-fail"
  _write_fake_git "$_fake_bin"

  local _runner
  _runner=$(_write_salvage_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_base"
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
        create) echo "https://github.com/owner/repo/pull/88"; return 0 ;;
        view)   return 0 ;;
      esac ;;
    repo)  echo 'owner/repo'; return 0 ;;
    api)   echo '{"merged":true}'; return 0 ;;
    issue) return 0 ;;
  esac
  return 0
}
run_test_gate() {
  local _wt_root="\${2:-\$(pwd)}"
  mkdir -p "\$_wt_root/.rite/logs" "\$_wt_root/.rite/state"
  echo "# promote gate failure transcript for feature-x" > "\$_wt_root/.rite/logs/full-suite-20261012.log"
  printf 'outcome=failed\ntest_count=3\n' > "\$_wt_root/.rite/state/full-suite-failure.flag"
  return 1
}
run_promote "feature-x" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 1 ]

  # Salvaged log must exist under the project's .rite/logs/ with a branch-scoped name
  local _saved_log=""
  _saved_log=$(ls "$RITE_TEST_TMPDIR/.rite/logs/full-suite-promote-feature-x-"*.log 2>/dev/null \
    | head -1 || true)
  [ -n "$_saved_log" ]
  grep -q "promote gate failure transcript for feature-x" "$_saved_log"
}

@test "failing gate: failure message prints the log path" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_salvage_stubs "$_lib"
  local _entry="issue=42	pr=97	sha=abc123	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _wt_base="$RITE_TEST_TMPDIR/worktrees"
  local _fake_bin="$RITE_TEST_TMPDIR/fakebin-msg"
  _write_fake_git "$_fake_bin"

  local _runner
  _runner=$(_write_salvage_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_base"
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
        create) echo "https://github.com/owner/repo/pull/88"; return 0 ;;
        view)   return 0 ;;
      esac ;;
    repo)  echo 'owner/repo'; return 0 ;;
    api)   echo '{"merged":true}'; return 0 ;;
    issue) return 0 ;;
  esac
  return 0
}
run_test_gate() {
  local _wt_root="\${2:-\$(pwd)}"
  mkdir -p "\$_wt_root/.rite/logs" "\$_wt_root/.rite/state"
  echo "# gate transcript" > "\$_wt_root/.rite/logs/full-suite-20261013.log"
  return 1
}
run_promote "feature-x" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 1 ]

  # Failure output must mention "Failure log:" and a path that contains the branch name
  echo "$output" | grep -q "Failure log:"
  echo "$output" | grep -q "full-suite-promote-feature-x"
}

@test "failing gate: full-suite failure flag is salvaged to project .rite/state/" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_salvage_stubs "$_lib"
  local _entry="issue=42	pr=97	sha=abc123	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _wt_base="$RITE_TEST_TMPDIR/worktrees"
  local _fake_bin="$RITE_TEST_TMPDIR/fakebin-flag"
  _write_fake_git "$_fake_bin"

  local _runner
  _runner=$(_write_salvage_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_base"
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
        create) echo "https://github.com/owner/repo/pull/88"; return 0 ;;
        view)   return 0 ;;
      esac ;;
    repo)  echo 'owner/repo'; return 0 ;;
    api)   echo '{"merged":true}'; return 0 ;;
    issue) return 0 ;;
  esac
  return 0
}
run_test_gate() {
  local _wt_root="\${2:-\$(pwd)}"
  mkdir -p "\$_wt_root/.rite/logs" "\$_wt_root/.rite/state"
  echo "# transcript" > "\$_wt_root/.rite/logs/full-suite-20261013.log"
  printf 'outcome=failed\ntest_count=5\n' > "\$_wt_root/.rite/state/full-suite-failure.flag"
  return 1
}
run_promote "feature-x" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 1 ]

  # Failure flag must be in the project's .rite/state/
  local _saved_flag="$RITE_TEST_TMPDIR/.rite/state/full-suite-promote-feature-x.flag"
  [ -f "$_saved_flag" ]
  grep -q "test_count=5" "$_saved_flag"
}

@test "passing gate: no stray flag copied to project .rite/state/" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_salvage_stubs "$_lib"
  local _entry="issue=42	pr=97	sha=abc123	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _wt_base="$RITE_TEST_TMPDIR/worktrees"
  local _fake_bin="$RITE_TEST_TMPDIR/fakebin-pass"
  _write_fake_git "$_fake_bin"

  local _runner
  _runner=$(_write_salvage_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_base"
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
        create) echo "https://github.com/owner/repo/pull/88"; return 0 ;;
        view)
          printf '%s\n' "\$@" | grep -q "headRefOid" && echo "deadbeef" || true
          return 0 ;;
      esac ;;
    repo)  echo 'owner/repo'; return 0 ;;
    api)   echo '{"merged":true}'; return 0 ;;
    issue) return 0 ;;
  esac
  return 0
}
# Passing gate: exits 0, writes no failure flag
run_test_gate() {
  return 0
}
run_promote "feature-x" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1

  # A stray flag must NOT be present after a passing promote
  local _stray_flag="$RITE_TEST_TMPDIR/.rite/state/full-suite-promote-feature-x.flag"
  [ ! -f "$_stray_flag" ]
}

@test "worktree is removed after gate failure" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_salvage_stubs "$_lib"
  local _entry="issue=42	pr=97	sha=abc123	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _wt_base="$RITE_TEST_TMPDIR/worktrees"
  local _fake_bin="$RITE_TEST_TMPDIR/fakebin-wt-fail"
  _write_fake_git "$_fake_bin"

  local _runner
  _runner=$(_write_salvage_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_base"
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
        create) echo "https://github.com/owner/repo/pull/88"; return 0 ;;
        view)   return 0 ;;
      esac ;;
    repo)  echo 'owner/repo'; return 0 ;;
    api)   echo '{"merged":true}'; return 0 ;;
    issue) return 0 ;;
  esac
  return 0
}
run_test_gate() {
  local _wt_root="\${2:-\$(pwd)}"
  mkdir -p "\$_wt_root/.rite/logs"
  echo "# transcript" > "\$_wt_root/.rite/logs/full-suite-20261013.log"
  return 1
}
run_promote "feature-x" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 1 ]

  # Temp worktree must be gone — the fake git's 'worktree remove' deletes the dir
  [ ! -d "$_wt_base/promote-feature-x" ]
}

@test "worktree is removed after gate success" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_salvage_stubs "$_lib"
  local _entry="issue=42	pr=97	sha=abc123	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _wt_base="$RITE_TEST_TMPDIR/worktrees"
  local _fake_bin="$RITE_TEST_TMPDIR/fakebin-wt-pass"
  _write_fake_git "$_fake_bin"

  local _runner
  _runner=$(_write_salvage_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_base"
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
        create) echo "https://github.com/owner/repo/pull/88"; return 0 ;;
        view)
          printf '%s\n' "\$@" | grep -q "headRefOid" && echo "deadbeef" || true
          return 0 ;;
      esac ;;
    repo)  echo 'owner/repo'; return 0 ;;
    api)   echo '{"merged":true}'; return 0 ;;
    issue) return 0 ;;
  esac
  return 0
}
run_test_gate() { return 0; }
run_promote "feature-x" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1

  # Temp worktree must be gone regardless of outcome
  [ ! -d "$_wt_base/promote-feature-x" ]
}
