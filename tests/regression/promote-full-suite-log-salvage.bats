#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/promote-branch.sh
# tests/regression/promote-full-suite-log-salvage.bats
#
# Regression tests for gate verdict salvage before promote worktree removal
# (#1210). run_test_gate writes its verdict JSON to its first arg ($1); if the
# gate fails and that file is non-empty, promote-branch.sh copies it to the
# project's .rite/state/ before removing the worktree.
#
# Tests verify:
#   1. Failing gate: verdict JSON is copied to project .rite/state/
#   2. Failing gate: failure message names the verdict save path
#   3. Failing gate: no JSON salvaged when gate exits without writing verdict
#   4. Passing gate: no stray verdict JSON copied to project .rite/state/
#   5. Worktree is removed in both failure and success outcomes

load '../helpers/setup'
load '../helpers/promote-stubs'

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

@test "failing gate: gate JSON verdict is salvaged to project .rite/state/" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  local _entry="issue=42	pr=97	sha=abc123	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _wt_base="$RITE_TEST_TMPDIR/worktrees"
  local _fake_bin="$RITE_TEST_TMPDIR/fakebin-fail"
  _write_fake_git "$_fake_bin"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_base"
export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
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
  echo '{"tests":[{"test_name":"fake-failing-test"}]}' > "\${1:-/dev/null}"
  return 1
}
run_promote "feature-x" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 1 ]

  # Verdict JSON must be salvaged to .rite/state/ with a branch-scoped name
  local _saved_json="$RITE_TEST_TMPDIR/.rite/state/promote-gate-feature-x.json"
  [ -f "$_saved_json" ]
  grep -q "fake-failing-test" "$_saved_json"
}

@test "failing gate: failure message names the verdict save path" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  local _entry="issue=42	pr=97	sha=abc123	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _wt_base="$RITE_TEST_TMPDIR/worktrees"
  local _fake_bin="$RITE_TEST_TMPDIR/fakebin-msg"
  _write_fake_git "$_fake_bin"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_base"
export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
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
  echo '{"tests":[]}' > "\${1:-/dev/null}"
  return 1
}
run_promote "feature-x" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 1 ]

  # Failure output must mention "verdict saved to" and the branch-scoped save path
  echo "$output" | grep -q "verdict saved to .rite/state/promote-gate-feature-x.json"
}

@test "failing gate: no JSON salvaged when gate exits without writing verdict" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  local _entry="issue=42	pr=97	sha=abc123	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _wt_base="$RITE_TEST_TMPDIR/worktrees"
  local _fake_bin="$RITE_TEST_TMPDIR/fakebin-flag"
  _write_fake_git "$_fake_bin"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_base"
export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
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
# Gate fails without writing the verdict JSON — the [ -s ] guard must suppress the copy
run_test_gate() {
  return 1
}
run_promote "feature-x" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 1 ]

  # No copy should exist in .rite/state/ when the gate wrote no verdict JSON
  local _saved_json="$RITE_TEST_TMPDIR/.rite/state/promote-gate-feature-x.json"
  [ ! -f "$_saved_json" ]
}

@test "passing gate: no stray verdict JSON copied to project .rite/state/" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  local _entry="issue=42	pr=97	sha=abc123	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _wt_base="$RITE_TEST_TMPDIR/worktrees"
  local _fake_bin="$RITE_TEST_TMPDIR/fakebin-pass"
  _write_fake_git "$_fake_bin"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_base"
export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
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
  [ "$status" -eq 0 ]

  # A stray verdict JSON must NOT be present after a passing promote
  local _stray_json="$RITE_TEST_TMPDIR/.rite/state/promote-gate-feature-x.json"
  [ ! -f "$_stray_json" ]
}

@test "worktree is removed after gate failure" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  local _entry="issue=42	pr=97	sha=abc123	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _wt_base="$RITE_TEST_TMPDIR/worktrees"
  local _fake_bin="$RITE_TEST_TMPDIR/fakebin-wt-fail"
  _write_fake_git "$_fake_bin"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_base"
export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
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
  _write_promote_stubs_base "$_lib"
  local _entry="issue=42	pr=97	sha=abc123	merged_at=2026-01-01T00:00:00Z	promoted=false"
  local _wt_base="$RITE_TEST_TMPDIR/worktrees"
  local _fake_bin="$RITE_TEST_TMPDIR/fakebin-wt-pass"
  _write_fake_git "$_fake_bin"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$_wt_base"
export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
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
  [ "$status" -eq 0 ]

  # Temp worktree must be gone regardless of outcome
  [ ! -d "$_wt_base/promote-feature-x" ]
}
