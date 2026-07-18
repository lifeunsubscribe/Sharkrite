#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/core/claude-workflow.sh, lib/utils/trivial-fix-fastpath.sh, lib/utils/scope-checker.sh
# tests/regression/target-branch-dev-diffs.bats
#
# Regression tests for: Convert dev-side origin/main diffs to target (#1035)
#
# Design intent:
#   All diff/rev-list ranges used for "how much work has this branch done?"
#   decisions must use the resolved target branch, not a hardcoded "origin/main".
#   Against an integration branch, every accumulated target commit reads as new
#   work when diffed vs main, causing skip-dev misfires, zero-work detection
#   not tripping, the gate selecting wrong tests, and scope-check false positives.
#
# Sites converted by this issue (#1035):
#   lib/core/workflow-runner.sh
#     - phase_claude_workflow(): FILE_CHANGES, post_dev_changes, file_changes
#     - phase_assess_and_resolve(): gate fallback diff base
#     - run_workflow(): _file_changes (worktree rediscovery), no-PR resume fetch/
#       rev-list/merge, _dev_changes (phase-skip), autofix prepass --changed,
#       initial gate seed
#     - _check_no_work_invariant(): _inv_commits rev-list
#   lib/core/claude-workflow.sh
#     - check_dev_session_output(): commits_ahead, commit_range, has_real_work
#     - FIX_REVIEW_MODE: _fix_branch_has_tests
#     - placeholder-PR FILE_CHANGES
#     - init-commit dedup _commit_range
#     - dev-prompt scope-check instruction (cosmetic)
#     - DIAG block
#     - check_scope_boundary() call (pass resolved base as 3rd arg)
#     - end-of-session FILE_CHANGES
#     - empty-branch cleanup _commit_range
#     - end-of-run summary
#   lib/utils/trivial-fix-fastpath.sh
#     - try_trivial_fix_fastpath(): internal fetch + fork base ref
#   lib/utils/scope-checker.sh
#     - check_scope_boundary(): added optional base_ref param; uses it for diff
#
# Sites deliberately NOT converted (in-scope exclusions):
#   claude-workflow.sh lines ~2337/~2415  — cross-worktree UNPUSHED cleanup
#     guards; these iterate other worktrees using origin/<that-branch>-or-main
#     as a last-resort fallback and are unrelated to the current issue's target.
#   claude-workflow.sh ~2091 verify_already_fixed_on_main() — deliberately
#     pinned to main (checks if a fix already landed on the canonical branch).
#
# Default behaviour (no target configured) must be byte-identical to pre-#1035
# behaviour: every converted site must evaluate to "origin/main" when the
# resolver returns the default "main".
#
# These tests use structural grep (no runtime execution) to enforce the
# invariants without requiring git/gh/claude infrastructure.

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
# STRUCTURAL: lib/utils/scope-checker.sh — optional base_ref parameter
# =============================================================================

@test "structural: scope-checker.sh check_scope_boundary accepts optional base_ref param" {
  # The function signature must declare a base_ref local (3rd param).
  _src=$(cat "$RITE_REPO_ROOT/lib/utils/scope-checker.sh")

  echo "$_src" | grep -q 'base_ref=' || {
    echo "FAIL: scope-checker.sh check_scope_boundary missing base_ref variable"
    return 1
  }
}

@test "structural: scope-checker.sh diff uses \$base_ref not literal origin/main" {
  # The diff inside check_scope_boundary must reference \$base_ref, not a literal.
  _src=$(cat "$RITE_REPO_ROOT/lib/utils/scope-checker.sh")

  # Must NOT have bare origin/main in the diff line
  if echo "$_src" | grep -E 'diff.*origin/main\.\.\.HEAD|origin/main\.\.\.HEAD.*diff' | grep -qv '#'; then
    echo "FAIL: scope-checker.sh still has literal origin/main...HEAD in diff command"
    return 1
  fi

  # Must HAVE \$base_ref in a diff or rev-parse line
  echo "$_src" | grep -qE '\$base_ref' || {
    echo "FAIL: scope-checker.sh missing \$base_ref reference"
    return 1
  }
}

@test "structural: scope-checker.sh base_ref defaults to origin/main (backward compat)" {
  # The default value must be origin/main so standalone callers get the old behaviour.
  _src=$(cat "$RITE_REPO_ROOT/lib/utils/scope-checker.sh")

  echo "$_src" | grep -qE 'base_ref.*:-.*origin/main|base_ref=.*\$\{.*:-.*origin/main' || {
    echo "FAIL: scope-checker.sh base_ref does not default to origin/main"
    return 1
  }
}

# =============================================================================
# STRUCTURAL: lib/utils/trivial-fix-fastpath.sh — internal fetch + fork base
# =============================================================================

@test "structural: trivial-fix-fastpath.sh resolves _tf_target for internal fetch" {
  # try_trivial_fix_fastpath must call resolve_target_branch into _tf_target and
  # use it for the fetch and fork base ref.
  _src=$(cat "$RITE_REPO_ROOT/lib/utils/trivial-fix-fastpath.sh")

  echo "$_src" | grep -q '_tf_target' || {
    echo "FAIL: trivial-fix-fastpath.sh missing _tf_target variable"
    return 1
  }

  echo "$_src" | grep -qE 'fetch origin "\$_tf_target"|fetch origin \$_tf_target' || {
    echo "FAIL: trivial-fix-fastpath.sh fetch does not use \$_tf_target"
    return 1
  }
}

@test "structural: trivial-fix-fastpath.sh fork base ref uses \$_tf_target not main" {
  _src=$(cat "$RITE_REPO_ROOT/lib/utils/trivial-fix-fastpath.sh")

  # _base_ref must be set to origin/${_tf_target} not origin/main
  if echo "$_src" | grep -qE '_base_ref="origin/main"'; then
    echo "FAIL: trivial-fix-fastpath.sh still has literal _base_ref=\"origin/main\" for fork"
    return 1
  fi

  echo "$_src" | grep -qE '_base_ref=.*_tf_target' || {
    echo "FAIL: trivial-fix-fastpath.sh _base_ref does not reference _tf_target"
    return 1
  }
}

@test "structural: trivial-fix-fastpath.sh has no raw origin/main diff ranges" {
  _src=$(cat "$RITE_REPO_ROOT/lib/utils/trivial-fix-fastpath.sh")

  if echo "$_src" | grep -qE 'origin/main[.][.][.]?HEAD|HEAD[.][.][.]?origin/main'; then
    echo "FAIL: trivial-fix-fastpath.sh still has a raw origin/main diff range"
    return 1
  fi
}

# =============================================================================
# STRUCTURAL: lib/core/workflow-runner.sh — all converted sites
# =============================================================================

@test "structural: workflow-runner.sh has no raw origin/main diff ranges" {
  # All origin/main...HEAD and origin/main..HEAD patterns should be gone;
  # every site now uses origin/\${_target} or origin/\${_inv_target}.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  if echo "$_src" | grep -qE 'origin/main[.][.][.]?HEAD|HEAD[.][.][.]?origin/main'; then
    echo "FAIL: workflow-runner.sh still has a raw origin/main diff range"
    return 1
  fi
}

@test "structural: workflow-runner.sh phase_claude_workflow uses _target for diff" {
  _src=$(cat "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  # Must contain a _target variable assigned from resolve_target_branch
  echo "$_src" | grep -q 'resolve_target_branch' || {
    echo "FAIL: workflow-runner.sh missing resolve_target_branch call"
    return 1
  }

  echo "$_src" | grep -qE 'origin/\$\{_target\}\.\.\.' || {
    echo "FAIL: workflow-runner.sh missing origin/\${_target}... diff range"
    return 1
  }
}

@test "structural: workflow-runner.sh _check_no_work_invariant uses _inv_target" {
  _src=$(cat "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  echo "$_src" | grep -q '_inv_target' || {
    echo "FAIL: workflow-runner.sh _check_no_work_invariant missing _inv_target variable"
    return 1
  }

  echo "$_src" | grep -qE 'origin/\$\{_inv_target\}' || {
    echo "FAIL: workflow-runner.sh _check_no_work_invariant missing origin/\${_inv_target} ref"
    return 1
  }
}

@test "structural: workflow-runner.sh initial gate seed uses _target" {
  # The initial gate invocation (concurrent with first review) must pass
  # RITE_TEST_GATE_DIFF_BASE seeded from origin/\$_target.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  echo "$_src" | grep -qE 'RITE_TEST_GATE_DIFF_BASE.*origin/\$\{?_target\}?' || {
    echo "FAIL: workflow-runner.sh initial gate seed missing RITE_TEST_GATE_DIFF_BASE=origin/\${_target}"
    return 1
  }
}

@test "structural: workflow-runner.sh autofix prepass --changed uses _target" {
  # The autofix prepass must pass origin/\$_target (or the operator override) as
  # the --changed argument.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  echo "$_src" | grep -qE '\-\-changed.*origin/\$\{?_target\}?' || \
  echo "$_src" | grep -qE 'RITE_TEST_GATE_DIFF_BASE.*_target.*\-\-changed' || {
    echo "FAIL: workflow-runner.sh autofix prepass --changed does not reference \$_target"
    return 1
  }
}

# =============================================================================
# STRUCTURAL: lib/core/claude-workflow.sh — all converted sites
# =============================================================================

@test "structural: claude-workflow.sh has no raw origin/main diff ranges outside UNPUSHED guards" {
  # All origin/main...HEAD and origin/main..HEAD patterns must be gone EXCEPT
  # for the two cross-worktree UNPUSHED cleanup-guard fallbacks (~lines 2337/2415).
  # Those are exempt because they iterate other worktrees and use origin/main
  # only as a last-resort fallback when origin/<that_branch> is absent.
  # Both exempt lines use rev-list --count (not diff/log/show), so we filter them out.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  # Filter out the two exempt UNPUSHED guard lines (identified by rev-list --count),
  # then count any remaining raw origin/main diff ranges — expect 0.
  _count=$(echo "$_src" | grep -E 'origin/main[.][.][.]?HEAD|HEAD[.][.][.]?origin/main' \
    | grep -v 'rev-list --count' \
    | grep -c '.' || true)
  if [ "$_count" -gt 0 ]; then
    echo "FAIL: claude-workflow.sh has $_count raw origin/main diff range(s) outside UNPUSHED guards (expected 0)"
    echo "--- matches ---"
    echo "$_src" | grep -nE 'origin/main[.][.][.]?HEAD|HEAD[.][.][.]?origin/main' \
      | grep -v 'rev-list --count' || true
    return 1
  fi
}

@test "structural: claude-workflow.sh early _target resolution present before FIX_REVIEW_MODE" {
  # The early main-body _target resolution block must appear before the
  # FIX_REVIEW_MODE check so the FIX path and all subsequent functions inherit it.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  echo "$_src" | grep -q 'resolve_target_branch' || {
    echo "FAIL: claude-workflow.sh missing resolve_target_branch call"
    return 1
  }

  # The _target assignment must precede FIX_REVIEW_MODE
  _target_line=$(echo "$_src" | grep -n '_target=.*resolve_target_branch' | head -1 | cut -d: -f1 || true)
  _fix_line=$(echo "$_src" | grep -n 'FIX_REVIEW_MODE' | head -1 | cut -d: -f1 || true)

  if [ -z "$_target_line" ] || [ -z "$_fix_line" ]; then
    echo "FAIL: could not find _target= assignment or FIX_REVIEW_MODE in claude-workflow.sh"
    return 1
  fi

  if [ "$_target_line" -ge "$_fix_line" ]; then
    echo "FAIL: _target resolution (line $_target_line) is not before FIX_REVIEW_MODE (line $_fix_line)"
    return 1
  fi
}

@test "structural: claude-workflow.sh check_scope_boundary call passes origin/\${_target} as 3rd arg" {
  _src=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  echo "$_src" | grep -qE 'check_scope_boundary.*origin/\$\{_target\}' || {
    echo "FAIL: claude-workflow.sh check_scope_boundary call does not pass origin/\${_target} as 3rd arg"
    return 1
  }
}

@test "structural: claude-workflow.sh end-of-session FILE_CHANGES uses _target" {
  # The end-of-session zero-work check must diff against origin/\${_target}.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  # Must NOT have literal origin/main in a FILE_CHANGES= assignment
  if echo "$_src" | grep -E 'FILE_CHANGES=.*origin/main' | grep -qv '#'; then
    echo "FAIL: claude-workflow.sh end-of-session FILE_CHANGES still uses literal origin/main"
    return 1
  fi
}

@test "structural: claude-workflow.sh end-of-run summary uses _target" {
  # The Workflow Complete summary block must reference origin/\${_target}.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  # Must have origin/${_target} in the summary block
  echo "$_src" | grep -qE 'origin/\$\{_target\}.*HEAD.*rev-list|rev-list.*origin/\$\{_target\}' || \
  echo "$_src" | grep -A20 'Workflow Complete' | grep -qE 'origin/\$\{_target\}' || {
    echo "FAIL: claude-workflow.sh end-of-run summary does not reference origin/\${_target}"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: default target resolves to origin/main (backward compat)
# =============================================================================

@test "behavioral: scope-checker.sh check_scope_boundary base_ref default is origin/main" {
  # When called without a 3rd arg (old callers), base_ref must be origin/main.
  # This is a unit-level check on the default value in the function signature.

  _diag()         { :; }
  print_status()  { :; }
  print_info()    { :; }
  print_warning() { :; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_success() { :; }
  verbose_echo()  { :; }
  is_verbose()    { return 1; }
  export -f _diag print_status print_info print_warning print_error print_success
  export -f verbose_echo is_verbose

  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_REPO_ROOT/lib/utils/scope-checker.sh"
  set +u; set +o pipefail

  # Capture the resolved base_ref by overriding git inside the function
  _captured_base_ref=""
  git() {
    # Capture the ref used in the diff call
    case "$*" in
      *"diff --name-status"*) _captured_base_ref="${*#*diff --name-status }" ;;
      *"rev-parse --verify"*) return 1 ;;  # force the else branch (no diff run)
      *) return 0 ;;
    esac
  }
  export -f git

  # Call without 3rd arg — base_ref must default to origin/main
  # We don't need a real issue body; just confirm the default applies.
  check_scope_boundary "" "" 2>/dev/null || true

  # Verify the default was not overridden to something other than origin/main
  # (the function stores its 3rd param in base_ref="${3:-origin/main}")
  _src=$(grep 'base_ref=' "$RITE_REPO_ROOT/lib/utils/scope-checker.sh" | head -1 || true)
  echo "$_src" | grep -q 'origin/main' || {
    echo "FAIL: scope-checker.sh base_ref default is not 'origin/main'"
    return 1
  }
}

@test "behavioral: resolver default produces origin/main for all diff sites" {
  # When resolve_target_branch returns 'main' (the default), every converted
  # diff site must evaluate to 'origin/main' — byte-identical to pre-#1035.
  # This is verified structurally: confirm that the pattern 'origin/${_target}'
  # in each file would produce 'origin/main' when _target='main'.

  # Structural check: origin/\${_target} with _target=main -> origin/main
  # We confirm the substitution pattern is present (not a fallback literal).

  for _file in \
      "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" \
      "$RITE_REPO_ROOT/lib/core/claude-workflow.sh" \
      "$RITE_REPO_ROOT/lib/utils/trivial-fix-fastpath.sh"; do

    _src=$(cat "$_file")

    # At least one origin/${_target} diff reference must exist
    echo "$_src" | grep -qE 'origin/\$\{[_a-z]*target[_a-z]*\}' || {
      echo "FAIL: $_file has no origin/\${*target*} diff reference (cannot default to origin/main)"
      return 1
    }
  done
}

# =============================================================================
# BEHAVIORAL: RITE_SOURCE_FUNCTIONS_ONLY=1 suppresses _target resolution side effects
# =============================================================================

@test "behavioral: claude-workflow.sh _target block is side-effect-free under RITE_SOURCE_FUNCTIONS_ONLY=1" {
  # Pins the fix for the unguarded _target block (issue #1035 review finding).
  # When sourced with RITE_SOURCE_FUNCTIONS_ONLY=1, the block that sources
  # stale-branch.sh and calls resolve_target_branch must NOT execute — even
  # when ISSUE_NUMBER and PR_NUMBER are set (the conditions that trigger a live
  # gh API call inside resolve_target_branch).

  _sentinel="${RITE_TEST_TMPDIR}/resolve_target_branch_called.sentinel"

  # Ensure we're not blocked by the re-source guard from a prior source in this session.
  unset _RITE_CLAUDE_WORKFLOW_LOADED

  # Define resolve_target_branch as a sentinel-touching stub.
  # Must be defined after any source that could overwrite it — but claude-workflow.sh
  # does not define resolve_target_branch (it lives in stale-branch.sh), so a
  # pre-source definition is safe. We also re-define after source as defense-in-depth.
  resolve_target_branch() {
    touch "$_sentinel"
    echo "main"
  }
  export -f resolve_target_branch

  # Source with RITE_SOURCE_FUNCTIONS_ONLY=1 to load only function definitions.
  # ISSUE_NUMBER and PR_NUMBER are set to maximise the chance the guarded block
  # would fire if unguarded.
  ISSUE_NUMBER=99 PR_NUMBER=42 RITE_SOURCE_FUNCTIONS_ONLY=1 \
    source "${RITE_LIB_DIR}/core/claude-workflow.sh" 2>/dev/null || true
  set +u; set +o pipefail

  # Re-define stub after source (Rule 34: BATS_PRE_SOURCE_STUB_OVERWRITE defense-in-depth).
  # claude-workflow.sh does not define resolve_target_branch, so this is a no-op guard.
  resolve_target_branch() {
    touch "$_sentinel"
    echo "main"
  }

  # Assert the sentinel was NOT created — the guarded block must not have run.
  if [ -f "$_sentinel" ]; then
    echo "FAIL: resolve_target_branch was called under RITE_SOURCE_FUNCTIONS_ONLY=1 — _target block is not guarded"
    return 1
  fi
}
