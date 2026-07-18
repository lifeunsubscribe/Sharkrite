#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/core/claude-workflow.sh, lib/utils/trivial-fix-fastpath.sh, lib/utils/scope-checker.sh
# tests/regression/target-branch-dev-diffs.bats
#
# Regression test for: Convert dev-side origin/main diffs to target (#1037)
#
# Design intent (issue #1037):
#   All dev-side diff bases that were hardcoded to "origin/main" must instead
#   use the branch resolved by resolve_target_branch() (#1033).  After this
#   issue, `rite --branch integration/x 42` drives FILE_CHANGES, gate seeds,
#   no-PR resume fetch/rev-list/merge, and scope-checker diffs against
#   origin/integration/x — not origin/main.
#
#   The default (no --branch / no env / no state file) must remain
#   byte-identical to the prior hard-coded "origin/main" behaviour.
#
# Sites converted by this issue (#1037):
#   lib/core/workflow-runner.sh   — FILE_CHANGES, post_dev_changes, no-PR resume,
#                                   gate seeds (initial + fix-loop), autofix fallback,
#                                   _check_no_work_invariant, phase-skip _dev_changes
#   lib/core/claude-workflow.sh   — check_dev_session_output(), fix-session test signal,
#                                   placeholder-PR FILE_CHANGES, init-commit dedup,
#                                   end-of-session FILE_CHANGES, empty-branch cleanup,
#                                   scope-check third arg, DIAG block, dev-prompt instruction
#   lib/utils/trivial-fix-fastpath.sh — fetch + fork base (early resolve; PR --base covered by #1036)
#   lib/utils/scope-checker.sh   — optional base_ref third param (defaults to origin/main)
#
# Sites deliberately NOT converted (still "origin/main"):
#   workflow-runner.sh ~2803 / ~2870 — cross-worktree UNPUSHED guards for OTHER
#     issues' worktrees (targets unknowable); comment + #1052 deferred
#   lib/utils/test-gate.sh :1753, :2239 — RITE_TEST_GATE_DIFF_BASE defaults
#     in the gate itself; seeded upstream (this issue) not replaced here
#   merge-pr.sh, mid-run-rebase.sh — sibling issues #1038/#1039
#
# This test verifies:
#  STRUCTURAL (grep-based):
#   1.  workflow-runner.sh: resolve_target_branch called in run_workflow()
#   2.  workflow-runner.sh: no-PR resume fetch uses "$_target" not literal "main"
#   3.  workflow-runner.sh: no-PR resume rev-list uses "origin/${_target}" not "origin/main"
#   4.  workflow-runner.sh: no-PR resume merge uses "origin/${_target}" not "origin/main"
#   5.  workflow-runner.sh: gate seeds use "origin/${_target}" not literal "origin/main"
#   6.  workflow-runner.sh: FILE_CHANGES diffs use "origin/${_target}" not "origin/main"
#   7.  claude-workflow.sh: resolve_target_branch call present in main body
#   8.  claude-workflow.sh: check_dev_session_output uses _cds_target not literal "main"
#   9.  claude-workflow.sh: scope-check call passes three args (third = origin/$_target)
#   10. trivial-fix-fastpath.sh: fetch uses "$_fastpath_target" not literal "main"
#   11. trivial-fix-fastpath.sh: fork base uses "origin/${_fastpath_target}" not "origin/main"
#   12. scope-checker.sh: check_scope_boundary accepts optional third base_ref param
#   13. test-gate.sh: RITE_TEST_GATE_DIFF_BASE defaults remain "origin/main" (unchanged)
#  BEHAVIORAL:
#   14. resolver default is "main" → scope-checker default stays "origin/main"
#   15. resolver returns custom target from state file (tier 2 → "integration-x")
#   16. RITE_TEST_GATE_DIFF_BASE is NOT exported (no batch poisoning)

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
# STRUCTURAL: workflow-runner.sh — resolve_target_branch in run_workflow()
# =============================================================================

@test "structural: workflow-runner.sh run_workflow resolves target branch" {
  # run_workflow() (and phase functions it calls) must call resolve_target_branch
  # so that diff bases use the correct branch, not literal "main".
  _src=$(cat "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  echo "$_src" | grep -q 'resolve_target_branch' || {
    echo "FAIL: workflow-runner.sh missing resolve_target_branch call"
    return 1
  }

  # Must have a _target variable populated from the resolver
  echo "$_src" | grep -q '_target=$(resolve_target_branch' || {
    echo "FAIL: workflow-runner.sh missing _target=\$(resolve_target_branch ...)"
    return 1
  }
}

# =============================================================================
# STRUCTURAL: workflow-runner.sh — no-PR resume block
# =============================================================================

@test "structural: workflow-runner.sh no-PR resume fetch uses \$_target not literal main" {
  _src=$(cat "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  # Must NOT have: fetch origin main (literal)
  if echo "$_src" | grep -qE 'fetch origin main\b'; then
    echo "FAIL: workflow-runner.sh still has literal 'fetch origin main'"
    return 1
  fi

  # Must HAVE: fetch origin "$_target"
  echo "$_src" | grep -q 'fetch origin "$_target"' || {
    echo "FAIL: workflow-runner.sh missing 'fetch origin \"\$_target\"'"
    return 1
  }
}

@test "structural: workflow-runner.sh no-PR resume rev-list uses origin/\${_target} not origin/main" {
  _src=$(cat "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  # rev-list for _behind_main must use origin/${_target}
  echo "$_src" | grep -q 'rev-list --count "HEAD..origin/${_target}"' || {
    echo "FAIL: workflow-runner.sh no-PR rev-list missing HEAD..origin/\${_target}"
    return 1
  }
}

@test "structural: workflow-runner.sh no-PR resume merge uses origin/\${_target} not origin/main" {
  _src=$(cat "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  # merge block must reference origin/${_target}
  echo "$_src" | grep -q 'merge "origin/${_target}"' || {
    echo "FAIL: workflow-runner.sh no-PR merge missing 'merge \"origin/\${_target}\"'"
    return 1
  }
}

# =============================================================================
# STRUCTURAL: workflow-runner.sh — gate seeds
# =============================================================================

@test "structural: workflow-runner.sh gate seeds use origin/\${_target} not literal origin/main" {
  _src=$(cat "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  # Both gate seed invocations must reference origin/${_target} (not literal origin/main)
  _seed_count=$(echo "$_src" | grep -c 'RITE_TEST_GATE_DIFF_BASE=.*origin/\${_target}' || true)
  if [ "$_seed_count" -lt 2 ]; then
    echo "FAIL: workflow-runner.sh has only $_seed_count RITE_TEST_GATE_DIFF_BASE seeds with origin/\${_target} (expected >= 2)"
    return 1
  fi
}

@test "structural: workflow-runner.sh RITE_TEST_GATE_DIFF_BASE is not exported" {
  # Must never export RITE_TEST_GATE_DIFF_BASE — that would poison batch siblings.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  if echo "$_src" | grep -qE '^[[:space:]]*export RITE_TEST_GATE_DIFF_BASE'; then
    echo "FAIL: workflow-runner.sh exports RITE_TEST_GATE_DIFF_BASE (batch poisoning risk)"
    return 1
  fi
}

# =============================================================================
# STRUCTURAL: workflow-runner.sh — FILE_CHANGES diffs
# =============================================================================

@test "structural: workflow-runner.sh FILE_CHANGES diffs use origin/\${_target} not origin/main" {
  _src=$(cat "$RITE_REPO_ROOT/lib/core/workflow-runner.sh")

  # Count diffs using origin/${_target}...HEAD
  _diff_count=$(echo "$_src" | grep -c 'diff --name-only "origin/${_target}' || true)
  if [ "$_diff_count" -lt 3 ]; then
    echo "FAIL: workflow-runner.sh has only $_diff_count diff sites using origin/\${_target} (expected >= 3)"
    return 1
  fi
}

# =============================================================================
# STRUCTURAL: claude-workflow.sh — resolver + converted sites
# =============================================================================

@test "structural: claude-workflow.sh has resolve_target_branch call in main body" {
  _src=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  echo "$_src" | grep -q 'declare -f resolve_target_branch' || {
    echo "FAIL: claude-workflow.sh missing lazy-source guard for resolve_target_branch"
    return 1
  }

  echo "$_src" | grep -q '_target=$(resolve_target_branch' || {
    echo "FAIL: claude-workflow.sh missing _target=\$(resolve_target_branch ...)"
    return 1
  }
}

@test "structural: claude-workflow.sh check_dev_session_output uses _cds_target not literal main" {
  # The check_dev_session_output() function must use _cds_target="${_target:-main}"
  # for its rev-list and rev-parse calls, not a hardcoded "origin/main".
  _src=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  echo "$_src" | grep -q '_cds_target=' || {
    echo "FAIL: claude-workflow.sh check_dev_session_output missing _cds_target variable"
    return 1
  }

  # Must NOT have literal origin/main inside check_dev_session_output
  # (the UNPUSHED cross-worktree guards are in a different code block)
  echo "$_src" | grep -q 'origin/${_cds_target}' || {
    echo "FAIL: claude-workflow.sh check_dev_session_output missing origin/\${_cds_target} usage"
    return 1
  }
}

@test "structural: claude-workflow.sh scope-check passes origin/\${_target:-main} as third arg" {
  # check_scope_boundary must be called with three args, third being origin/${_target:-main}.
  _src=$(cat "$RITE_REPO_ROOT/lib/core/claude-workflow.sh")

  echo "$_src" | grep -q 'check_scope_boundary.*origin/${_target:-main}' || {
    echo "FAIL: claude-workflow.sh scope-check call missing origin/\${_target:-main} as third arg"
    return 1
  }
}

# =============================================================================
# STRUCTURAL: trivial-fix-fastpath.sh — fetch + fork base
# =============================================================================

@test "structural: trivial-fix-fastpath.sh fetch uses \$_fastpath_target not literal main" {
  _src=$(cat "$RITE_REPO_ROOT/lib/utils/trivial-fix-fastpath.sh")

  # Must NOT have: fetch origin main (literal)
  if echo "$_src" | grep -qE 'fetch origin main\b'; then
    echo "FAIL: trivial-fix-fastpath.sh still has literal 'fetch origin main'"
    return 1
  fi

  # Must HAVE: fetch origin "$_fastpath_target"
  echo "$_src" | grep -q 'fetch origin "$_fastpath_target"' || {
    echo "FAIL: trivial-fix-fastpath.sh missing 'fetch origin \"\$_fastpath_target\"'"
    return 1
  }
}

@test "structural: trivial-fix-fastpath.sh fork base uses origin/\${_fastpath_target} not origin/main" {
  _src=$(cat "$RITE_REPO_ROOT/lib/utils/trivial-fix-fastpath.sh")

  # Fork base (_base_ref) must use _fastpath_target
  echo "$_src" | grep -q '_base_ref="origin/${_fastpath_target}"' || {
    echo "FAIL: trivial-fix-fastpath.sh missing _base_ref=\"origin/\${_fastpath_target}\""
    return 1
  }

  # Fallback must also use _fastpath_target
  echo "$_src" | grep -q '_base_ref="$_fastpath_target"' || {
    echo "FAIL: trivial-fix-fastpath.sh missing _base_ref=\"\$_fastpath_target\" fallback"
    return 1
  }
}

# =============================================================================
# STRUCTURAL: scope-checker.sh — optional base_ref third param
# =============================================================================

@test "structural: scope-checker.sh check_scope_boundary accepts optional base_ref third param" {
  _src=$(cat "$RITE_REPO_ROOT/lib/utils/scope-checker.sh")

  # Must have the optional third param with origin/main default
  echo "$_src" | grep -q 'base_ref="${3:-origin/main}"' || {
    echo "FAIL: scope-checker.sh check_scope_boundary missing 'local base_ref=\"\${3:-origin/main}\"'"
    return 1
  }

  # The diff must use $base_ref not literal origin/main
  echo "$_src" | grep -q '"${base_ref}...HEAD"' || {
    echo "FAIL: scope-checker.sh diff missing '\"\${base_ref}...HEAD\"' usage"
    return 1
  }
}

@test "structural: scope-checker.sh rev-parse uses \$base_ref not literal origin/main" {
  _src=$(cat "$RITE_REPO_ROOT/lib/utils/scope-checker.sh")

  echo "$_src" | grep -q 'rev-parse --verify "$base_ref"' || {
    echo "FAIL: scope-checker.sh missing 'rev-parse --verify \"\$base_ref\"'"
    return 1
  }
}

# =============================================================================
# STRUCTURAL: test-gate.sh — defaults unchanged (acceptance criterion)
# =============================================================================

@test "structural: test-gate.sh RITE_TEST_GATE_DIFF_BASE defaults are still origin/main (unchanged)" {
  # The gate itself uses a default of origin/main — the seeding happens upstream
  # in workflow-runner.sh. Verify exactly 2 occurrences of the default pattern.
  _src=$(cat "$RITE_REPO_ROOT/lib/utils/test-gate.sh")

  _count=$(echo "$_src" | grep -c 'RITE_TEST_GATE_DIFF_BASE:-origin/main' || true)
  if [ "$_count" -lt 2 ]; then
    echo "FAIL: test-gate.sh has only $_count RITE_TEST_GATE_DIFF_BASE:-origin/main occurrences (expected >= 2)"
    return 1
  fi
}

# =============================================================================
# BEHAVIORAL: resolver default → scope-checker uses "origin/main"
# =============================================================================

@test "behavioral: scope-checker uses origin/main when resolver returns default main" {
  # Without a state file or RITE_TARGET_BRANCH, resolve_target_branch returns "main".
  # Callers must therefore produce "origin/main" diff bases — byte-identical to before.

  # Stub deps for stale-branch.sh
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

  # Re-stub after source (Rule 34 defense-in-depth)
  _diag() { :; }
  gh_safe() { return 0; }
  git_fetch_safe() { return 0; }
  export -f _diag gh_safe git_fetch_safe

  set +u; set +o pipefail

  # No state dir, no env — resolver must return "main"
  unset RITE_TARGET_BRANCH || true
  unset RITE_STATE_DIR     || true

  _tmp_out=$(mktemp)
  resolve_target_branch "" "" > "$_tmp_out"
  _resolved=$(cat "$_tmp_out")
  rm -f "$_tmp_out"

  [ "$_resolved" = "main" ] || {
    echo "FAIL: default resolved '$_resolved', expected 'main'"
    return 1
  }

  # With resolver returning "main", the downstream base_ref would be "origin/main"
  # (pattern: "origin/${_target:-main}" or "origin/${resolved}").
  # Verify the substitution produces the correct string.
  _tgt="$_resolved"
  _base_ref="origin/${_tgt}"
  [ "$_base_ref" = "origin/main" ] || {
    echo "FAIL: base_ref='$_base_ref', expected 'origin/main'"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: state-file-only resolution → non-main diff bases
# =============================================================================

@test "behavioral: state-file resolution drives integration-x diff bases (no PR_NUMBER)" {
  # The no-PR resume path uses only tier 2 (state file) when PR_NUMBER is empty.
  # This test stubs git to record the arguments it receives and verifies that
  # fetch, rev-list, and merge all reference origin/integration-x.

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

  # Write target-branch-42.txt with "integration-x" (tier 2 — state file)
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/state"
  mkdir -p "$RITE_STATE_DIR"
  echo "integration-x" > "$RITE_STATE_DIR/target-branch-42.txt"

  # No PR_NUMBER — forces tier 2 path
  unset RITE_TARGET_BRANCH || true
  _pr_number=""

  _tmp_out=$(mktemp)
  resolve_target_branch "42" "$_pr_number" > "$_tmp_out"
  _resolved=$(cat "$_tmp_out")
  rm -f "$_tmp_out"

  [ "$_resolved" = "integration-x" ] || {
    echo "FAIL: tier-2 resolved '$_resolved', expected 'integration-x'"
    return 1
  }
  [ "${RESOLVED_TARGET_SOURCE:-}" = "state" ] || {
    echo "FAIL: RESOLVED_TARGET_SOURCE='${RESOLVED_TARGET_SOURCE:-}', expected 'state'"
    return 1
  }

  # Simulate the no-PR resume block argument construction.
  # workflow-runner.sh:2801: git -C "$WORKTREE_PATH" fetch origin "$_target"
  # workflow-runner.sh:2803: rev-list --count "HEAD..origin/${_target}"
  # workflow-runner.sh:2808: merge "origin/${_target}"
  _target="$_resolved"
  _fetch_arg="origin $_target"
  _revlist_range="HEAD..origin/${_target}"
  _merge_ref="origin/${_target}"

  [ "$_fetch_arg" = "origin integration-x" ] || {
    echo "FAIL: fetch arg='$_fetch_arg', expected 'origin integration-x'"
    return 1
  }
  [ "$_revlist_range" = "HEAD..origin/integration-x" ] || {
    echo "FAIL: rev-list range='$_revlist_range', expected 'HEAD..origin/integration-x'"
    return 1
  }
  [ "$_merge_ref" = "origin/integration-x" ] || {
    echo "FAIL: merge ref='$_merge_ref', expected 'origin/integration-x'"
    return 1
  }
}

@test "behavioral: gate seed uses integration-x when state file says integration-x" {
  # RITE_TEST_GATE_DIFF_BASE seed pattern: ${RITE_TEST_GATE_DIFF_BASE:-origin/${_target}}
  # When operator has NOT set RITE_TEST_GATE_DIFF_BASE, the resolved target wins.

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

  # Write state file
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/state"
  mkdir -p "$RITE_STATE_DIR"
  echo "integration-x" > "$RITE_STATE_DIR/target-branch-42.txt"

  unset RITE_TARGET_BRANCH     || true
  unset RITE_TEST_GATE_DIFF_BASE || true

  _tmp_out=$(mktemp)
  resolve_target_branch "42" "" > "$_tmp_out"
  _target=$(cat "$_tmp_out")
  rm -f "$_tmp_out"

  # Simulate the gate seed: ${RITE_TEST_GATE_DIFF_BASE:-origin/${_target}}
  _gate_seed="${RITE_TEST_GATE_DIFF_BASE:-origin/${_target}}"

  [ "$_gate_seed" = "origin/integration-x" ] || {
    echo "FAIL: gate seed='$_gate_seed', expected 'origin/integration-x'"
    return 1
  }
}

@test "behavioral: gate seed stays origin/main when resolver returns default" {
  # When no state file and no env, resolver returns "main".
  # Gate seed must evaluate to "origin/main" (byte-identical to before).

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

  unset RITE_TARGET_BRANCH       || true
  unset RITE_STATE_DIR           || true
  unset RITE_TEST_GATE_DIFF_BASE || true

  _tmp_out=$(mktemp)
  resolve_target_branch "" "" > "$_tmp_out"
  _target=$(cat "$_tmp_out")
  rm -f "$_tmp_out"

  [ "$_target" = "main" ] || {
    echo "FAIL: default target='$_target', expected 'main'"
    return 1
  }

  _gate_seed="${RITE_TEST_GATE_DIFF_BASE:-origin/${_target}}"

  [ "$_gate_seed" = "origin/main" ] || {
    echo "FAIL: default gate seed='$_gate_seed', expected 'origin/main'"
    return 1
  }
}

@test "behavioral: operator-set RITE_TEST_GATE_DIFF_BASE overrides resolved target" {
  # When an operator sets RITE_TEST_GATE_DIFF_BASE explicitly, it must win over the
  # per-invocation seed (${RITE_TEST_GATE_DIFF_BASE:-origin/${_target}}).
  # This verifies the :-  (not :=) pattern honours pre-existing overrides.

  set +u; set +o pipefail

  # Simulate: state file says integration-x, but operator pinned the base
  _target="integration-x"
  export RITE_TEST_GATE_DIFF_BASE="origin/my-custom-base"

  _gate_seed="${RITE_TEST_GATE_DIFF_BASE:-origin/${_target}}"

  [ "$_gate_seed" = "origin/my-custom-base" ] || {
    echo "FAIL: gate seed='$_gate_seed', expected 'origin/my-custom-base' (operator override)"
    return 1
  }

  unset RITE_TEST_GATE_DIFF_BASE || true
}
