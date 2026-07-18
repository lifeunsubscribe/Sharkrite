#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh, lib/core/create-pr.sh, lib/core/workflow-runner.sh, lib/utils/trivial-fix-fastpath.sh, bin/rite
# tests/regression/target-branch-propagation.bats
#
# Regression test for: Propagate resolved target to worktree and PR base (#1035/1036/1037)
#
# Design intent (issue #1036):
#   All hardcoded "main" references for worktree fork refs and PR --base arguments
#   must go through resolve_target_branch() instead.  The resolver is a four-tier
#   lookup (PR baseRefName → state file → RITE_TARGET_BRANCH env → "main") added by
#   #1033.  After this issue, `rite --branch integration/foo 42` produces:
#     - a worktree forked from origin/integration/foo
#     - a PR with --base integration/foo
#   with the default (no --branch / no env / no state file) remaining byte-identical
#   to the prior hard-coded "main" behaviour.
#
# Sites converted by this issue:
#   lib/core/claude-workflow.sh  — new-worktree fetch, fork ref, defensive merge, draft-PR base
#   lib/core/create-pr.sh        — BASE_BRANCH default → resolver (sentinel "" pattern)
#   lib/core/workflow-runner.sh  — phase_create_pr() --base arg to both $CREATE_PR calls
#   lib/utils/trivial-fix-fastpath.sh — fastpath PR --base arg
#   bin/rite                     — --branch arm → WORKFLOW_FLAGS+=("--base" "$2")
#
# Sites NOT converted (owned by sibling #1037 or deliberately excluded):
#   claude-workflow.sh dev-side diff base    — sibling scope
#   trivial-fix-fastpath.sh internal fetch (line ~127) and fork ref (line ~133) — sibling scope
#
# This test verifies:
#   1. claude-workflow.sh: resolve_target_branch called before fetch + fork
#   2. claude-workflow.sh: defensive merge block uses $_target not literal "main"
#   3. claude-workflow.sh: draft-PR --base uses $_target not literal --base main
#   4. create-pr.sh: BASE_BRANCH initialises to "" (sentinel) not "main"
#   5. create-pr.sh: resolver block present after arg loop
#   6. workflow-runner.sh: phase_create_pr passes --base "$_wf_target" to both $CREATE_PR calls
#   7. trivial-fix-fastpath.sh: resolver called; --base "$_fastpath_target" present
#   8. bin/rite: --branch arm populates WORKFLOW_FLAGS with --base
#   9. behavioral: resolver returns "main" by default (no env / no state file)
#  10. behavioral: resolver returns custom target from state file (tier 2)
#  11. behavioral: resolver returns custom target from env (tier 3)

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
}

teardown() {
  teardown_test_tmpdir
}

# =============================================================================
# STRUCTURAL: claude-workflow.sh — resolver + fetch/fork converted
# =============================================================================

@test "structural: claude-workflow.sh calls resolve_target_branch before new-worktree fetch" {
  # resolve_target_branch must be called (lazy-sourced) before git_fetch_safe origin \$_target
  # in the new-worktree branch.  We verify both the lazy-source guard and the call exist.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  echo "$_src" | grep -q 'declare -f resolve_target_branch' || {
    echo "FAIL: claude-workflow.sh missing lazy-source guard for resolve_target_branch"
    return 1
  }

  echo "$_src" | grep -q '_target=.*resolve_target_branch' || {
    echo "FAIL: claude-workflow.sh does not call resolve_target_branch into _target"
    return 1
  }
}

@test "structural: claude-workflow.sh fetch uses \$_target not literal main" {
  # git_fetch_safe must use \$_target so a non-main integration branch is fetched.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  # Must NOT have: git_fetch_safe origin main (literal)
  if echo "$_src" | grep -q 'git_fetch_safe origin main'; then
    echo "FAIL: claude-workflow.sh still contains literal 'git_fetch_safe origin main'"
    return 1
  fi

  # Must HAVE: git_fetch_safe origin "\$_target"
  echo "$_src" | grep -q 'git_fetch_safe origin "\$_target"' || \
  echo "$_src" | grep -q "git_fetch_safe origin \"\$_target\"" || \
  echo "$_src" | grep -qE 'git_fetch_safe origin "?\$_target"?' || {
    echo "FAIL: claude-workflow.sh missing git_fetch_safe origin \$_target"
    return 1
  }
}

@test "structural: claude-workflow.sh fork ref uses \$_target not literal origin/main" {
  # The _base_ref and _retry_base_ref must reference origin/\${_target}, not origin/main.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  # Must NOT have: _base_ref="origin/main" or _retry_base_ref="origin/main"
  if echo "$_src" | grep -qE '_base_ref="origin/main"'; then
    echo "FAIL: claude-workflow.sh still has literal _base_ref=\"origin/main\""
    return 1
  fi

  # Must HAVE the \${_target} form
  echo "$_src" | grep -qE '_base_ref="origin/\$\{_target\}"' || \
  echo "$_src" | grep -qE "_base_ref=\"origin/\\\$\\{_target\\}\"" || {
    echo "FAIL: claude-workflow.sh missing _base_ref=\"origin/\${_target}\""
    return 1
  }
}

@test "structural: claude-workflow.sh defensive merge uses \$_target not literal main" {
  # The defensive pre-dev merge block must reference \$_target, not hardcoded "main".
  _src=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  # Must NOT have: git merge "origin/main" or git_fetch_safe origin main
  # (Allow one literal "main" only in the skip-guard comparison which is legitimate)
  _merge_main_count=$(echo "$_src" | grep -c '"origin/main"' || true)
  if [ "$_merge_main_count" -gt 0 ]; then
    echo "FAIL: claude-workflow.sh still has $(_merge_main_count) literal \"origin/main\" strings (expected 0)"
    return 1
  fi
}

@test "structural: claude-workflow.sh draft-PR --base uses \$_target not literal main" {
  # gh pr create must pass --base "\$_target", not --base main.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  if echo "$_src" | grep -qE '\-\-base main\b'; then
    echo "FAIL: claude-workflow.sh still has literal --base main"
    return 1
  fi

  echo "$_src" | grep -q -- '--base "$_target"' || {
    echo "FAIL: claude-workflow.sh missing --base \"\$_target\" in draft-PR creation"
    return 1
  }
}

# =============================================================================
# STRUCTURAL: create-pr.sh — sentinel + resolver
# =============================================================================

@test "structural: create-pr.sh initialises BASE_BRANCH to empty sentinel not main" {
  # BASE_BRANCH="" is the sentinel that triggers the resolver.
  # BASE_BRANCH="main" (old hardcode) would bypass the resolver.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/create-pr.sh")

  if echo "$_src" | grep -qE '^BASE_BRANCH="main"'; then
    echo "FAIL: create-pr.sh still initialises BASE_BRANCH=\"main\" (should be empty sentinel)"
    return 1
  fi

  echo "$_src" | grep -qE '^BASE_BRANCH=""' || {
    echo "FAIL: create-pr.sh does not initialise BASE_BRANCH to empty sentinel"
    return 1
  }
}

@test "structural: create-pr.sh has resolver block for empty BASE_BRANCH" {
  # When --base is not passed, create-pr.sh must call resolve_target_branch.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/create-pr.sh")

  echo "$_src" | grep -q 'resolve_target_branch' || {
    echo "FAIL: create-pr.sh missing resolve_target_branch call"
    return 1
  }

  # The resolver must be inside a guard that checks BASE_BRANCH is still empty.
  echo "$_src" | grep -q 'BASE_BRANCH:-' || {
    echo "FAIL: create-pr.sh resolver not guarded by \${BASE_BRANCH:-} check"
    return 1
  }
}

# =============================================================================
# STRUCTURAL: workflow-runner.sh — phase_create_pr --base threading
# =============================================================================

@test "structural: workflow-runner.sh phase_create_pr resolves target and passes --base" {
  # phase_create_pr() must call resolve_target_branch and pass --base "\$_wf_target"
  # to both \$CREATE_PR invocations.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  echo "$_src" | grep -q 'resolve_target_branch' || {
    echo "FAIL: workflow-runner.sh missing resolve_target_branch call"
    return 1
  }

  echo "$_src" | grep -q '_wf_target' || {
    echo "FAIL: workflow-runner.sh missing _wf_target variable"
    return 1
  }

  # Both \$CREATE_PR calls must include --base "\$_wf_target"
  _base_count=$(echo "$_src" | grep -c '"--base" "\$_wf_target"\|--base "\$_wf_target"' || true)
  # Expect at least 2 (one supervised, one auto)
  if [ "$_base_count" -lt 2 ]; then
    echo "FAIL: workflow-runner.sh has only $_base_count --base \"\$_wf_target\" occurrences (expected >= 2)"
    return 1
  fi
}

# =============================================================================
# STRUCTURAL: trivial-fix-fastpath.sh — resolver + --base threading
# =============================================================================

@test "structural: trivial-fix-fastpath.sh resolves target and passes --base \$_fastpath_target" {
  # The fastpath PR creation must call resolve_target_branch into _fastpath_target
  # and pass --base "\$_fastpath_target" to gh pr create.
  _src=$(cat "$RITE_REPO_ROOT/lib/utils/trivial-fix-fastpath.sh")

  echo "$_src" | grep -q '_fastpath_target' || {
    echo "FAIL: trivial-fix-fastpath.sh missing _fastpath_target variable"
    return 1
  }

  echo "$_src" | grep -q 'resolve_target_branch' || {
    echo "FAIL: trivial-fix-fastpath.sh missing resolve_target_branch call"
    return 1
  }

  echo "$_src" | grep -q -- '--base "\$_fastpath_target"' || {
    echo "FAIL: trivial-fix-fastpath.sh missing --base \"\$_fastpath_target\" in gh pr create"
    return 1
  }

  # Must NOT have literal --base main
  if echo "$_src" | grep -qE '\-\-base main\b'; then
    echo "FAIL: trivial-fix-fastpath.sh still has literal --base main"
    return 1
  fi
}

# =============================================================================
# STRUCTURAL: bin/rite — --branch arm → WORKFLOW_FLAGS --base
# =============================================================================

@test "structural: bin/rite --branch arm threads target via WORKFLOW_FLAGS --base" {
  # bin/rite's --branch) case must add --base to WORKFLOW_FLAGS so the single-issue
  # exec to workflow-runner.sh carries the target explicitly (not env-only).
  _src=$(cat "$RITE_REPO_ROOT/bin/rite")

  echo "$_src" | grep -q 'WORKFLOW_FLAGS+=.*"--base"' || {
    echo "FAIL: bin/rite --branch) arm does not add --base to WORKFLOW_FLAGS"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: resolver default is "main" (byte-identical to pre-#1036)
# =============================================================================

@test "behavioral: resolver returns main by default (no env, no state file, no PR)" {
  # When nothing is configured, resolve_target_branch must return "main".
  # This verifies the default is byte-identical to the pre-#1036 hardcoded value.

  # Stub deps that stale-branch.sh sources transitively
  _diag() { :; }
  print_status()  { :; }
  print_info()    { :; }
  print_warning() { :; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_success() { :; }
  gh_safe() { return 0; }
  git_fetch_safe() { return 0; }
  export -f _diag print_status print_info print_warning print_error print_success
  export -f gh_safe git_fetch_safe

  # shellcheck disable=SC1090
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  # Re-stub after source (Rule 34: stale-branch.sh uses function-sentinel guard;
  # re-stub as defense-in-depth for transitively sourced env-guard libs)
  _diag() { :; }
  gh_safe() { return 0; }
  git_fetch_safe() { return 0; }
  export -f _diag gh_safe git_fetch_safe

  set +u; set +o pipefail

  # No env, no state dir, no PR
  unset RITE_TARGET_BRANCH || true
  unset RITE_STATE_DIR     || true

  _result=$(resolve_target_branch "" "")

  [ "$_result" = "main" ] || {
    echo "FAIL: default resolved '$_result', expected 'main'"
    return 1
  }
  [ "$RESOLVED_TARGET_SOURCE" = "default" ] || {
    echo "FAIL: RESOLVED_TARGET_SOURCE is '$RESOLVED_TARGET_SOURCE', expected 'default'"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: resolver reads non-main target from state file (tier 2)
# =============================================================================

@test "behavioral: resolver returns custom target from state file (tier 2)" {
  # When a target-branch-<N>.txt state file is present, the resolver must return
  # its value (tier 2), not "main".  This simulates a resumed single-issue run
  # where the branch was written by bin/rite's --branch arm.

  # Stub deps
  _diag() { :; }
  print_status()  { :; }
  print_info()    { :; }
  print_warning() { :; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_success() { :; }
  gh_safe() { return 0; }
  git_fetch_safe() { return 0; }
  export -f _diag print_status print_info print_warning print_error print_success
  export -f gh_safe git_fetch_safe

  # shellcheck disable=SC1090
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  # Re-stub after source
  _diag() { :; }
  gh_safe() { return 0; }
  git_fetch_safe() { return 0; }
  export -f _diag gh_safe git_fetch_safe

  set +u; set +o pipefail

  # Write a state file for issue 99
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/state"
  mkdir -p "$RITE_STATE_DIR"
  echo "release/v2" > "$RITE_STATE_DIR/target-branch-99.txt"

  unset RITE_TARGET_BRANCH || true

  _result=$(resolve_target_branch "99" "")

  [ "$_result" = "release/v2" ] || {
    echo "FAIL: tier-2 resolved '$_result', expected 'release/v2'"
    return 1
  }
  [ "$RESOLVED_TARGET_SOURCE" = "state" ] || {
    echo "FAIL: RESOLVED_TARGET_SOURCE is '$RESOLVED_TARGET_SOURCE', expected 'state'"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: resolver reads non-main target from env (tier 3)
# =============================================================================

@test "behavioral: resolver returns custom target from RITE_TARGET_BRANCH env (tier 3)" {
  # When RITE_TARGET_BRANCH is set to a non-main value and no state file exists,
  # the resolver must return RITE_TARGET_BRANCH (tier 3).

  # Stub deps
  _diag() { :; }
  print_status()  { :; }
  print_info()    { :; }
  print_warning() { :; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_success() { :; }
  gh_safe() { return 0; }
  git_fetch_safe() { return 0; }
  export -f _diag print_status print_info print_warning print_error print_success
  export -f gh_safe git_fetch_safe

  # shellcheck disable=SC1090
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  # Re-stub after source
  _diag() { :; }
  gh_safe() { return 0; }
  git_fetch_safe() { return 0; }
  export -f _diag gh_safe git_fetch_safe

  set +u; set +o pipefail

  # No state dir — force tier 3
  unset RITE_STATE_DIR || true
  export RITE_TARGET_BRANCH="integration/canary"

  _result=$(resolve_target_branch "55" "")

  [ "$_result" = "integration/canary" ] || {
    echo "FAIL: tier-3 resolved '$_result', expected 'integration/canary'"
    return 1
  }
  [ "$RESOLVED_TARGET_SOURCE" = "env" ] || {
    echo "FAIL: RESOLVED_TARGET_SOURCE is '$RESOLVED_TARGET_SOURCE', expected 'env'"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: env tier 3 skips literal "main" (transport-only sentinel)
# =============================================================================

@test "behavioral: RITE_TARGET_BRANCH=main is skipped by tier 3 (falls through to default)" {
  # config.sh defaults RITE_TARGET_BRANCH to "main".  A bare "main" value is
  # indistinguishable from unset — tier 3 must NOT fire for it; the resolver falls
  # through to tier 4 ("main" default).  This verifies byte-identical default behaviour
  # even when RITE_TARGET_BRANCH is exported to the env.

  # Stub deps
  _diag() { :; }
  print_status()  { :; }
  print_info()    { :; }
  print_warning() { :; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_success() { :; }
  gh_safe() { return 0; }
  git_fetch_safe() { return 0; }
  export -f _diag print_status print_info print_warning print_error print_success
  export -f gh_safe git_fetch_safe

  # shellcheck disable=SC1090
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_REPO_ROOT/lib/utils/stale-branch.sh"

  # Re-stub after source
  _diag() { :; }
  gh_safe() { return 0; }
  git_fetch_safe() { return 0; }
  export -f _diag gh_safe git_fetch_safe

  set +u; set +o pipefail

  unset RITE_STATE_DIR || true
  export RITE_TARGET_BRANCH="main"  # transport default — must not fire tier 3

  _result=$(resolve_target_branch "77" "")

  [ "$_result" = "main" ] || {
    echo "FAIL: resolved '$_result', expected 'main' (tier 3 must skip literal main)"
    return 1
  }
  [ "$RESOLVED_TARGET_SOURCE" = "default" ] || {
    echo "FAIL: RESOLVED_TARGET_SOURCE is '$RESOLVED_TARGET_SOURCE', expected 'default' (not 'env')"
    return 1
  }
}
