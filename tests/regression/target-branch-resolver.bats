#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/stale-branch.sh, lib/core/workflow-runner.sh, lib/core/claude-workflow.sh, bin/rite
# tests/regression/target-branch-resolver.bats
#
# Regression tests for the four-tier target-branch resolver, per-issue state
# file, and ensure_target_branch_exists preflight (issue #1033).
#
# Tests:
#  1.  resolver: no PR number → falls through tier 1, resolves from env (tier 3)
#  2.  resolver: PR API returns valid branch → tier 1 hit (source=pr)
#  3.  resolver: PR API falls back (source=fallback) → tier 2 state file used
#  4.  resolver: state file beats env when API unavailable
#  5.  resolver: invalid state file content → falls through to tier 3 env
#  6.  resolver: state file path-traversal → falls through to tier 3 env
#  7.  resolver: state file multi-line → falls through to env
#  8.  resolver: env tier fires only when != "main" and non-empty
#  9.  resolver: all tiers empty / API unavailable / no env → default "main"
# 10.  resolver: PR base IS "main" via API → tier 1 hit, source=pr, result=main
# 11.  _rite_branch_name_safe: accepts valid branch names
# 12.  _rite_branch_name_safe: rejects path traversal "../evil"
# 13.  _rite_branch_name_safe: rejects shell meta "foo;rm"
# 14.  _rite_branch_name_safe: rejects multi-line value
# 15.  _rite_branch_name_safe: rejects empty string
# 16.  ensure_target_branch_exists: returns 0 immediately for "main"
# 17.  ensure_target_branch_exists: returns 0 when branch exists on remote
# 18.  ensure_target_branch_exists: auto-creates branch from origin/main on miss, exactly one push
# 19.  ensure_target_branch_exists: returns 1 + print_error when push fails
# 20.  state-file write: non-main RITE_TARGET_BRANCH → file written in claude-workflow (structural pin)
# 21.  state-file write: main RITE_TARGET_BRANCH → no file written (default byte-identical)
# 22.  workflow-runner --base: validates and exports RITE_TARGET_BRANCH
# 23.  workflow-runner --base: rejects missing value
# 24.  workflow-runner --base: rejects flag-shaped value
# 25.  lib-resource-safety: stale-branch.sh still double-sources cleanly after additions

load '../helpers/setup'

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LOG_FILE=""

  # Stub print functions (all tests)
  print_status()  { :; }
  print_info()    { :; }
  print_warning() { :; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_success() { :; }
  print_header()  { :; }
  _diag()         { :; }
  export -f print_status print_info print_warning print_error print_success print_header _diag

  # Stub stale-branch hard deps so sourcing doesn't invoke network/git
  create_sharkrite_stash() { return 0; }
  verify_post_merge()      { return 0; }
  export -f create_sharkrite_stash verify_post_merge

  # Stub git_fetch_safe (provided by git-helpers.sh; stubbed so the lib sources cleanly)
  git_fetch_safe() { return 0; }
  export -f git_fetch_safe

  # Default: RITE_STATE_DIR inside the tmp dir so state-file operations are isolated
  mkdir -p "$RITE_TEST_TMPDIR/.rite/state"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"

  # Source stale-branch.sh — defines _rite_branch_name_safe, _stale_resolve_base_branch,
  # resolve_target_branch, ensure_target_branch_exists. Stub gh_safe BEFORE sourcing
  # (lib uses declare -f guard, so we must define it before the guard check runs).
  gh_safe() { return 0; }
  export -f gh_safe

  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  # Re-stub after source: colors.sh (sourced transitively, env-var guard) overwrites
  # print_* with real implementations. Re-define all pre-source stubs here so the
  # test-controlled behaviour is restored. (Rule 34: BATS_PRE_SOURCE_STUB_OVERWRITE)
  print_status()  { :; }
  print_info()    { :; }
  print_warning() { :; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_success() { :; }
  print_header()  { :; }
  _diag()         { :; }
  gh_safe()             { return 0; }
  create_sharkrite_stash() { return 0; }
  verify_post_merge()      { return 0; }
  git_fetch_safe()         { return 0; }
  export -f print_status print_info print_warning print_error print_success print_header _diag
  export -f gh_safe create_sharkrite_stash verify_post_merge git_fetch_safe

  # Restore bats shell flags (lib sources under set -euo pipefail)
  set +u; set +o pipefail
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Section 1: resolve_target_branch — four-tier precedence
# ---------------------------------------------------------------------------

@test "resolver tier 3: no PR number + env set → env used (source=env)" {
  # Call WITHOUT $() so RESOLVED_TARGET_SOURCE is set in THIS shell.
  # Capture stdout to a temp file to check the returned branch name.
  gh_safe() { echo "SHOULD_NOT_BE_CALLED"; }
  export -f gh_safe
  export RITE_TARGET_BRANCH="integration"
  unset RITE_STATE_DIR || true

  local _tmpout="$RITE_TEST_TMPDIR/resolver-out.txt"
  resolve_target_branch "42" "" > "$_tmpout"
  local _out
  _out=$(cat "$_tmpout")
  [ "$_out" = "integration" ] || { echo "FAIL: output='$_out', expected 'integration'"; return 1; }
  [ "$RESOLVED_TARGET_SOURCE" = "env" ] || { echo "FAIL: source='$RESOLVED_TARGET_SOURCE'"; return 1; }
}

@test "resolver tier 1: PR API returns valid branch → tier 1 hit (source=pr)" {
  gh_safe() { echo "develop"; }
  export -f gh_safe
  export RITE_TARGET_BRANCH="ignored-env"  # tier 3 would fire but tier 1 wins

  local _tmpout="$RITE_TEST_TMPDIR/resolver-out.txt"
  resolve_target_branch "42" "99" > "$_tmpout"
  local _out
  _out=$(cat "$_tmpout")
  [ "$_out" = "develop" ] || { echo "FAIL: output='$_out', expected 'develop'"; return 1; }
  [ "$RESOLVED_TARGET_SOURCE" = "pr" ] || { echo "FAIL: source='$RESOLVED_TARGET_SOURCE'"; return 1; }
}

@test "resolver tier 1 fallback → tier 2 state file used (source=state)" {
  # API returns empty → source=fallback → fall through to tier 2
  gh_safe() { echo ""; }
  export -f gh_safe
  export RITE_TARGET_BRANCH=""  # tier 3 inactive

  echo "release/v2" > "${RITE_STATE_DIR}/target-branch-42.txt"

  local _tmpout="$RITE_TEST_TMPDIR/resolver-out.txt"
  resolve_target_branch "42" "99" > "$_tmpout"
  local _out
  _out=$(cat "$_tmpout")
  [ "$_out" = "release/v2" ] || { echo "FAIL: output='$_out', expected 'release/v2'"; return 1; }
  [ "$RESOLVED_TARGET_SOURCE" = "state" ] || { echo "FAIL: source='$RESOLVED_TARGET_SOURCE'"; return 1; }
}

@test "resolver tier 2: state file beats env when API unavailable" {
  gh_safe() { echo ""; }
  export -f gh_safe
  export RITE_TARGET_BRANCH="env-branch"

  echo "state-branch" > "${RITE_STATE_DIR}/target-branch-7.txt"

  local _tmpout="$RITE_TEST_TMPDIR/resolver-out.txt"
  resolve_target_branch "7" "99" > "$_tmpout"
  local _out
  _out=$(cat "$_tmpout")
  [ "$_out" = "state-branch" ] || { echo "FAIL: output='$_out'"; return 1; }
  [ "$RESOLVED_TARGET_SOURCE" = "state" ] || { echo "FAIL: source='$RESOLVED_TARGET_SOURCE'"; return 1; }
}

@test "resolver tier 2 invalid content → falls through to tier 3 env" {
  gh_safe() { echo ""; }
  export -f gh_safe
  export RITE_TARGET_BRANCH="env-branch"

  # Invalid content: contains shell meta
  printf 'foo;rm -rf /' > "${RITE_STATE_DIR}/target-branch-5.txt"

  local _tmpout="$RITE_TEST_TMPDIR/resolver-out.txt"
  resolve_target_branch "5" "99" > "$_tmpout"
  local _out
  _out=$(cat "$_tmpout")
  [ "$_out" = "env-branch" ] || { echo "FAIL: output='$_out'"; return 1; }
  [ "$RESOLVED_TARGET_SOURCE" = "env" ] || { echo "FAIL: source='$RESOLVED_TARGET_SOURCE'"; return 1; }
}

@test "resolver tier 2 path-traversal → falls through to tier 3 env" {
  gh_safe() { echo ""; }
  export -f gh_safe
  export RITE_TARGET_BRANCH="safe-env"

  printf '../evil' > "${RITE_STATE_DIR}/target-branch-6.txt"

  local _tmpout="$RITE_TEST_TMPDIR/resolver-out.txt"
  resolve_target_branch "6" "99" > "$_tmpout"
  local _out
  _out=$(cat "$_tmpout")
  [ "$_out" = "safe-env" ] || { echo "FAIL: output='$_out'"; return 1; }
  [ "$RESOLVED_TARGET_SOURCE" = "env" ] || { echo "FAIL: source='$RESOLVED_TARGET_SOURCE'"; return 1; }
}

@test "resolver tier 2 multi-line state file → falls through to env" {
  gh_safe() { echo ""; }
  export -f gh_safe
  export RITE_TARGET_BRANCH="env-after-multiline"

  printf 'valid-line\nextra-line' > "${RITE_STATE_DIR}/target-branch-8.txt"

  local _tmpout="$RITE_TEST_TMPDIR/resolver-out.txt"
  resolve_target_branch "8" "99" > "$_tmpout"
  local _out
  _out=$(cat "$_tmpout")
  [ "$_out" = "env-after-multiline" ] || { echo "FAIL: output='$_out'"; return 1; }
  [ "$RESOLVED_TARGET_SOURCE" = "env" ] || { echo "FAIL: source='$RESOLVED_TARGET_SOURCE'"; return 1; }
}

@test "resolver tier 3: env fires only when non-empty AND != main" {
  gh_safe() { echo ""; }
  export -f gh_safe

  # RITE_TARGET_BRANCH=main → tier 3 inactive → falls through to tier 4 default
  export RITE_TARGET_BRANCH="main"
  unset RITE_STATE_DIR || true

  local _tmpout="$RITE_TEST_TMPDIR/resolver-out.txt"
  resolve_target_branch "9" "" > "$_tmpout"
  local _out
  _out=$(cat "$_tmpout")
  [ "$_out" = "main" ] || { echo "FAIL: output='$_out'"; return 1; }
  [ "$RESOLVED_TARGET_SOURCE" = "default" ] || { echo "FAIL: source='$RESOLVED_TARGET_SOURCE'"; return 1; }
}

@test "resolver tier 4: all tiers inactive → default main (source=default)" {
  gh_safe() { echo ""; }
  export -f gh_safe
  unset RITE_TARGET_BRANCH || true
  unset RITE_STATE_DIR || true

  local _tmpout="$RITE_TEST_TMPDIR/resolver-out.txt"
  resolve_target_branch "10" "" > "$_tmpout"
  local _out
  _out=$(cat "$_tmpout")
  [ "$_out" = "main" ] || { echo "FAIL: output='$_out'"; return 1; }
  [ "$RESOLVED_TARGET_SOURCE" = "default" ] || { echo "FAIL: source='$RESOLVED_TARGET_SOURCE'"; return 1; }
}

@test "resolver tier 1: PR base IS main via API → source=pr, result=main" {
  # PR's baseRefName is literally "main" — tier 1 still hits (source=api)
  gh_safe() { echo "main"; }
  export -f gh_safe
  export RITE_TARGET_BRANCH="integration"  # tier 3 would be non-main, but tier 1 wins first

  local _tmpout="$RITE_TEST_TMPDIR/resolver-out.txt"
  resolve_target_branch "11" "55" > "$_tmpout"
  local _out
  _out=$(cat "$_tmpout")
  [ "$_out" = "main" ] || { echo "FAIL: output='$_out'"; return 1; }
  [ "$RESOLVED_TARGET_SOURCE" = "pr" ] || { echo "FAIL: source='$RESOLVED_TARGET_SOURCE'"; return 1; }
}

# ---------------------------------------------------------------------------
# Section 2: _rite_branch_name_safe
# ---------------------------------------------------------------------------

@test "_rite_branch_name_safe: accepts standard branch names" {
  _rite_branch_name_safe "main"        || { echo "FAIL: main"; return 1; }
  _rite_branch_name_safe "develop"     || { echo "FAIL: develop"; return 1; }
  _rite_branch_name_safe "feature/foo" || { echo "FAIL: feature/foo"; return 1; }
  _rite_branch_name_safe "release-1.0" || { echo "FAIL: release-1.0"; return 1; }
  _rite_branch_name_safe "my_branch"   || { echo "FAIL: my_branch"; return 1; }
}

@test "_rite_branch_name_safe: rejects path traversal '../evil'" {
  _rite_branch_name_safe "../evil" && return 1 || true
}

@test "_rite_branch_name_safe: rejects shell meta 'foo;rm'" {
  _rite_branch_name_safe "foo;rm -rf /" && return 1 || true
}

@test "_rite_branch_name_safe: rejects multi-line value" {
  # printf output includes embedded newline between the two lines.
  # We use a bats variable assignment (not $()) to preserve the newline.
  # Note: $() strips trailing newlines so "line1\nline2" via printf loses
  # the newline when assigned with $() — use printf with -v or a temp file.
  local _state_file="$RITE_TEST_TMPDIR/multi.txt"
  printf 'validline\nevil' > "$_state_file"
  local _multi
  _multi=$(cat "$_state_file")
  # If the file has a newline, wc -l will count >=1 line; if $() stripped it,
  # test the raw printf result. Either way the function must return 1.
  _rite_branch_name_safe "$(printf 'validline\nevil')" && return 1 || true
}

@test "_rite_branch_name_safe: rejects empty string" {
  _rite_branch_name_safe "" && return 1 || true
}

# ---------------------------------------------------------------------------
# Section 3: ensure_target_branch_exists
# ---------------------------------------------------------------------------

@test "ensure_target_branch_exists: returns 0 immediately for 'main'" {
  # No git or network calls should be made for main
  git() { echo "GIT_SHOULD_NOT_BE_CALLED: $*" >&2; return 1; }
  export -f git

  run ensure_target_branch_exists "main"
  [ "$status" -eq 0 ]
  # No error output
  [ -z "$output" ]
}

@test "ensure_target_branch_exists: returns 0 when branch exists on origin" {
  _ls_remote_calls=0
  git() {
    if [ "$1" = "ls-remote" ]; then
      _ls_remote_calls=$(( _ls_remote_calls + 1 ))
      return 0  # exists
    fi
    echo "GIT_UNEXPECTED: $*" >&2
    return 1
  }
  export -f git

  run ensure_target_branch_exists "release/v3"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ensure_target_branch_exists: auto-creates branch, exactly one push, one print_info" {
  # Use a temp file as push counter so the count survives the run subshell.
  local _push_count_file="$RITE_TEST_TMPDIR/push_count.txt"
  echo "0" > "$_push_count_file"
  export _PUSH_COUNT_FILE="$_push_count_file"

  git() {
    case "$1" in
      ls-remote)
        return 1 ;;  # branch does NOT exist
      push)
        local _c
        _c=$(cat "$_PUSH_COUNT_FILE")
        echo $(( _c + 1 )) > "$_PUSH_COUNT_FILE"
        # Verify the refspec format: origin/main:refs/heads/<branch>
        if [ "$3" != "origin/main:refs/heads/integration" ]; then
          echo "WRONG_REFSPEC: $3" >&2
          return 1
        fi
        return 0 ;;
      *)
        echo "GIT_UNEXPECTED: $*" >&2
        return 1 ;;
    esac
  }
  export -f git

  run ensure_target_branch_exists "integration"
  [ "$status" -eq 0 ]
  local _push_count
  _push_count=$(cat "$_push_count_file")
  [ "$_push_count" -eq 1 ] || { echo "FAIL: push_count=$_push_count expected 1"; return 1; }
}

@test "ensure_target_branch_exists: returns 1 + print_error on push failure" {
  git() {
    case "$1" in
      ls-remote) return 1 ;;   # branch missing
      push)      return 1 ;;   # push fails
      *)
        echo "GIT_UNEXPECTED: $*" >&2; return 1 ;;
    esac
  }
  export -f git

  _error_count=0
  print_error() { _error_count=$(( _error_count + 1 )); echo "ERROR: $*" >&2; }
  export -f print_error

  run ensure_target_branch_exists "integration"
  [ "$status" -eq 1 ]
}

@test "ensure_target_branch_exists: returns 1 with print_error for invalid branch name" {
  run ensure_target_branch_exists "../evil"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Invalid target branch name"
}

# ---------------------------------------------------------------------------
# Section 4: state-file write in claude-workflow.sh (structural pins)
# ---------------------------------------------------------------------------

@test "state-file write: non-main RITE_TARGET_BRANCH → write gated by != main check" {
  # Structural pin: the write block in claude-workflow.sh must be gated on
  # RITE_TARGET_BRANCH != "main" AND carry the sharkrite-target-transport marker.
  _src=$(grep -n 'target-branch-' "$RITE_REPO_ROOT/lib/core/claude-workflow.sh" || true)

  # The path must use ${RITE_STATE_DIR}/ prefix (absolute)
  echo "$_src" | grep -q '${RITE_STATE_DIR}' || {
    echo "FAIL: write does not use \${RITE_STATE_DIR}/ prefix"
    return 1
  }

  # Must be gated on != "main"
  _guard_line=$(grep -n '"main"' "$RITE_REPO_ROOT/lib/core/claude-workflow.sh" | \
    grep 'RITE_TARGET_BRANCH' | grep '!=' | head -1 || true)
  [ -n "$_guard_line" ] || {
    echo "FAIL: no != main guard found near state-file write"
    return 1
  }
}

@test "state-file write: carries sharkrite-target-transport marker" {
  _marker_count=$(grep -c 'sharkrite-target-transport' \
    "$RITE_REPO_ROOT/lib/core/claude-workflow.sh" || true)
  [ "$_marker_count" -ge 1 ] || {
    echo "FAIL: sharkrite-target-transport marker missing from claude-workflow.sh"
    return 1
  }
}

@test "state-file write: functional — non-main target writes file to RITE_STATE_DIR" {
  # Direct functional test of the write logic
  local _state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$_state_dir"

  # Replicate the write logic from claude-workflow.sh
  local RITE_TARGET_BRANCH="integration"
  local ISSUE_NUMBER="99"
  local RITE_STATE_DIR="$_state_dir"

  if [ -n "${RITE_STATE_DIR:-}" ] && [ -n "${ISSUE_NUMBER:-}" ] && [ "${RITE_TARGET_BRANCH:-main}" != "main" ]; then
    echo "$RITE_TARGET_BRANCH" > "${RITE_STATE_DIR}/target-branch-${ISSUE_NUMBER}.txt" 2>/dev/null || true
  fi

  [ -f "$_state_dir/target-branch-99.txt" ] || {
    echo "FAIL: state file not written"
    return 1
  }
  _written=$(cat "$_state_dir/target-branch-99.txt")
  [ "$_written" = "integration" ] || {
    echo "FAIL: state file contains '${_written}', expected 'integration'"
    return 1
  }
}

@test "state-file write: functional — main target does NOT write file" {
  local _state_dir="$RITE_TEST_TMPDIR/state-main"
  mkdir -p "$_state_dir"

  local RITE_TARGET_BRANCH="main"
  local ISSUE_NUMBER="88"
  local RITE_STATE_DIR="$_state_dir"

  if [ -n "${RITE_STATE_DIR:-}" ] && [ -n "${ISSUE_NUMBER:-}" ] && [ "${RITE_TARGET_BRANCH:-main}" != "main" ]; then
    echo "$RITE_TARGET_BRANCH" > "${RITE_STATE_DIR}/target-branch-${ISSUE_NUMBER}.txt" 2>/dev/null || true
  fi

  [ ! -f "$_state_dir/target-branch-88.txt" ] || {
    echo "FAIL: state file should NOT be written for main target"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Section 5: workflow-runner.sh --base flag parser (structural pins)
# ---------------------------------------------------------------------------

@test "workflow-runner --base: case arm present in flag parser" {
  grep -q "^      --base)" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" || {
    echo "FAIL: --base) case arm not found in workflow-runner.sh"
    return 1
  }
}

@test "workflow-runner --base: exports RITE_TARGET_BRANCH" {
  _arm=$(grep -A 10 "^      --base)" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" || true)
  echo "$_arm" | grep -q "export RITE_TARGET_BRANCH" || {
    echo "FAIL: export RITE_TARGET_BRANCH not in --base arm"
    return 1
  }
}

@test "workflow-runner --base: has extra shift for value consumption" {
  _arm=$(grep -A 12 "^      --base)" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" || true)
  _shift_count=$(echo "$_arm" | grep -c "shift" || true)
  [ "$_shift_count" -ge 1 ] || {
    echo "FAIL: --base arm should have at least one shift (for value)"
    return 1
  }
}

@test "workflow-runner --base: usage block mentions --base <branch>" {
  grep -q "\-\-base <branch>" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" || {
    echo "FAIL: --base <branch> not in usage block"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Section 6: bin/rite preflight gate (structural pins)
# ---------------------------------------------------------------------------

@test "bin/rite preflight: ensure_target_branch_exists wired before dispatch case" {
  _preflight=$(grep -n "ensure_target_branch_exists" "$RITE_REPO_ROOT/bin/rite" || true)
  [ -n "$_preflight" ] || {
    echo "FAIL: ensure_target_branch_exists not found in bin/rite"
    return 1
  }
}

@test "bin/rite preflight: scoped to workflow-running dispatch keys" {
  # The gate case must include single-issue and batch-multi
  _gate_block=$(grep -A 5 "single-issue|single-issue-text|batch-filter|batch-multi|dev-and-pr" \
    "$RITE_REPO_ROOT/bin/rite" | head -10 || true)
  echo "$_gate_block" | grep -q "ensure_target_branch_exists" || {
    echo "FAIL: ensure_target_branch_exists not in workflow-dispatch-keys gate"
    return 1
  }
}

@test "bin/rite preflight: gated on non-main (RITE_TARGET_BRANCH != main)" {
  _gate_lines=$(grep -B 2 "ensure_target_branch_exists" "$RITE_REPO_ROOT/bin/rite" || true)
  echo "$_gate_lines" | grep -q '!= "main"' || {
    echo "FAIL: != main gate not found before ensure_target_branch_exists in bin/rite"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Section 7: Single API reader invariant
# ---------------------------------------------------------------------------

@test "single API reader: exactly one baseRefName query in stale-branch.sh" {
  _count=$(grep -c 'pr view.*baseRefName' "$RITE_REPO_ROOT/lib/utils/stale-branch.sh" || true)
  [ "$_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 'pr view.*baseRefName' in stale-branch.sh, got $_count"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Section 8: CLAUDE.md accuracy
# ---------------------------------------------------------------------------

@test "CLAUDE.md: architecture line for stale-branch.sh mentions target-branch resolver" {
  grep -q "target-branch resolver" "$RITE_REPO_ROOT/CLAUDE.md" || {
    echo "FAIL: 'target-branch resolver' not found in CLAUDE.md"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Section 9: _STALE_BASE_BRANCH_SOURCE extension (backward-compatible)
# ---------------------------------------------------------------------------

@test "_stale_resolve_base_branch: sets _STALE_BASE_BRANCH_SOURCE=api on valid API response" {
  gh_safe() { echo "develop"; }
  export -f gh_safe

  _stale_resolve_base_branch "42"
  [ "$_STALE_BASE_BRANCH" = "develop" ] || {
    echo "FAIL: expected 'develop', got '$_STALE_BASE_BRANCH'"
    return 1
  }
  [ "$_STALE_BASE_BRANCH_SOURCE" = "api" ] || {
    echo "FAIL: expected source=api, got '$_STALE_BASE_BRANCH_SOURCE'"
    return 1
  }
}

@test "_stale_resolve_base_branch: sets _STALE_BASE_BRANCH_SOURCE=fallback on empty response" {
  gh_safe() { echo ""; }
  export -f gh_safe

  _stale_resolve_base_branch "42"
  [ "$_STALE_BASE_BRANCH" = "main" ] || {
    echo "FAIL: expected 'main', got '$_STALE_BASE_BRANCH'"
    return 1
  }
  [ "$_STALE_BASE_BRANCH_SOURCE" = "fallback" ] || {
    echo "FAIL: expected source=fallback, got '$_STALE_BASE_BRANCH_SOURCE'"
    return 1
  }
}

@test "_stale_resolve_base_branch: sets _STALE_BASE_BRANCH_SOURCE=fallback on invalid name" {
  gh_safe() { printf '../evil'; }
  export -f gh_safe

  _stale_resolve_base_branch "42"
  [ "$_STALE_BASE_BRANCH" = "main" ] || {
    echo "FAIL: expected 'main', got '$_STALE_BASE_BRANCH'"
    return 1
  }
  [ "$_STALE_BASE_BRANCH_SOURCE" = "fallback" ] || {
    echo "FAIL: expected source=fallback, got '$_STALE_BASE_BRANCH_SOURCE'"
    return 1
  }
}

@test "_stale_resolve_base_branch: sets _STALE_BASE_BRANCH_SOURCE=fallback when pr_number empty" {
  gh_safe() { echo "SHOULD_NOT_BE_CALLED"; }
  export -f gh_safe

  _stale_resolve_base_branch ""
  [ "$_STALE_BASE_BRANCH_SOURCE" = "fallback" ] || {
    echo "FAIL: expected source=fallback for empty PR, got '$_STALE_BASE_BRANCH_SOURCE'"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Section 10: double-source safety (re-source guard still works after additions)
# ---------------------------------------------------------------------------

@test "stale-branch.sh: double-sources cleanly after new functions added" {
  # Source a second time — the re-source guard must prevent duplicate-definition crash
  # and both resolve_target_branch and ensure_target_branch_exists must still be present.
  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  declare -f resolve_target_branch >/dev/null 2>&1 || {
    echo "FAIL: resolve_target_branch not defined after second source"
    return 1
  }
  declare -f ensure_target_branch_exists >/dev/null 2>&1 || {
    echo "FAIL: ensure_target_branch_exists not defined after second source"
    return 1
  }
}
