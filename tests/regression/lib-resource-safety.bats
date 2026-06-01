#!/usr/bin/env bats
# Regression test for #61/#62/#90/#91/#156/#157: Re-source safety for all lib files
#
# Bug history:
# - #61/#62: readonly SHARKRITE_STASH_MARKER crashed on double-source (stash-manager.sh)
# - #90/#91: BASH_SOURCE-relative dep loading broke in fresh subprocesses (claude.sh, timeout.sh)
# - #156/#157: Sweep — add re-source guards to ALL remaining lib/**/*.sh files
#
# This test ensures:
# 1. Every lib/**/*.sh can be sourced twice under set -euo pipefail without error
# 2. The UNGUARDED_READONLY lint rule is active in tools/sharkrite-lint.sh
# 3. The codebase has zero bare (unguarded) readonly declarations

PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

setup() {
  export RITE_TEST_TMPDIR="${BATS_TEST_TMPDIR}/rite-resrc-$$"
  mkdir -p "$RITE_TEST_TMPDIR"
  git init --quiet "$RITE_TEST_TMPDIR/fake-repo" 2>/dev/null || true
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/fake-repo"
  export RITE_INSTALL_DIR="$PROJECT_ROOT"
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  export RITE_DATA_DIR=".rite"
  export SCRATCHPAD_FILE="$RITE_TEST_TMPDIR/scratch.md"
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/locks"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/state"
  export WORKFLOW_MODE="unsupervised"
  mkdir -p "$RITE_TEST_TMPDIR/locks" "$RITE_TEST_TMPDIR/state"
}

teardown() {
  rm -rf "$RITE_TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Helper A: Direct double-source (for pure function libraries).
# Both source calls must succeed and "double-source-ok" must be printed.
# ---------------------------------------------------------------------------
_assert_double_source_safe() {
  local rel_path="$1"
  local lib_file="$PROJECT_ROOT/lib/$rel_path"

  run bash -c "
set -euo pipefail
export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
export RITE_INSTALL_DIR='$PROJECT_ROOT'
export RITE_LIB_DIR='$PROJECT_ROOT/lib'
export RITE_DATA_DIR='.rite'
export SCRATCHPAD_FILE='$RITE_TEST_TMPDIR/scratch.md'
export RITE_LOCK_DIR='$RITE_TEST_TMPDIR/locks'
export RITE_STATE_DIR='$RITE_TEST_TMPDIR/state'
export WORKFLOW_MODE='unsupervised'
mkdir -p '$RITE_TEST_TMPDIR/locks' '$RITE_TEST_TMPDIR/state'
source '$lib_file'
source '$lib_file'
echo 'double-source-ok'
"
  if [ "$status" -ne 0 ]; then
    echo "FAILED double-source for lib/$rel_path (exit $status)"
    echo "$output" | tail -5
    return 1
  fi
  [[ "$output" =~ "double-source-ok" ]]
}

# ---------------------------------------------------------------------------
# Helper B: Sentinel guard test (for main-body CLI scripts that call exit).
# Pre-set the sentinel variable (simulating a prior successful source), then
# source the file — the guard must fire immediately and not execute the body.
# ---------------------------------------------------------------------------
_assert_sentinel_guard_fires() {
  local rel_path="$1"
  local sentinel_var="$2"
  local lib_file="$PROJECT_ROOT/lib/$rel_path"

  run bash -c "
set -euo pipefail
export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
export RITE_INSTALL_DIR='$PROJECT_ROOT'
export RITE_LIB_DIR='$PROJECT_ROOT/lib'
export RITE_DATA_DIR='.rite'
export SCRATCHPAD_FILE='$RITE_TEST_TMPDIR/scratch.md'
export RITE_LOCK_DIR='$RITE_TEST_TMPDIR/locks'
export RITE_STATE_DIR='$RITE_TEST_TMPDIR/state'
export WORKFLOW_MODE='unsupervised'
mkdir -p '$RITE_TEST_TMPDIR/locks' '$RITE_TEST_TMPDIR/state'
export ${sentinel_var}=1
source '$lib_file'
echo 'sentinel-guard-ok'
"
  if [ "$status" -ne 0 ]; then
    echo "FAILED sentinel guard for lib/$rel_path (exit $status, sentinel=$sentinel_var)"
    echo "$output" | tail -5
    return 1
  fi
  [[ "$output" =~ "sentinel-guard-ok" ]]
}

# ---------------------------------------------------------------------------
# lib/utils — pure function libraries (direct double-source)
# ---------------------------------------------------------------------------

@test "lib/utils/colors.sh double-source safe" {
  _assert_double_source_safe "utils/colors.sh"
}

@test "lib/utils/logging.sh double-source safe" {
  _assert_double_source_safe "utils/logging.sh"
}

@test "lib/utils/date-helpers.sh double-source safe" {
  _assert_double_source_safe "utils/date-helpers.sh"
}

@test "lib/utils/labels.sh double-source safe" {
  _assert_double_source_safe "utils/labels.sh"
}

@test "lib/utils/notifications.sh double-source safe" {
  _assert_double_source_safe "utils/notifications.sh"
}

@test "lib/utils/portable-cmds.sh double-source safe" {
  _assert_double_source_safe "utils/portable-cmds.sh"
}

@test "lib/utils/scope-checker.sh double-source safe" {
  _assert_double_source_safe "utils/scope-checker.sh"
}

@test "lib/utils/scratchpad-lock.sh double-source safe" {
  _assert_double_source_safe "utils/scratchpad-lock.sh"
}

@test "lib/utils/session-tracker.sh double-source safe" {
  _assert_double_source_safe "utils/session-tracker.sh"
}

@test "lib/utils/branch-preflight.sh double-source safe" {
  _assert_double_source_safe "utils/branch-preflight.sh"
}

@test "lib/utils/create-followup-issues.sh double-source safe" {
  _assert_double_source_safe "utils/create-followup-issues.sh"
}

@test "lib/utils/divergence-handler.sh double-source safe" {
  _assert_double_source_safe "utils/divergence-handler.sh"
}

@test "lib/utils/git-helpers.sh double-source safe" {
  _assert_double_source_safe "utils/git-helpers.sh"
}

@test "lib/utils/issue-lock.sh double-source safe" {
  _assert_double_source_safe "utils/issue-lock.sh"
}

@test "lib/utils/normalize-issue.sh double-source safe" {
  _assert_double_source_safe "utils/normalize-issue.sh"
}

@test "lib/utils/post-merge-verify.sh double-source safe" {
  _assert_double_source_safe "utils/post-merge-verify.sh"
}

@test "lib/utils/pr-detection.sh double-source safe" {
  _assert_double_source_safe "utils/pr-detection.sh"
}

@test "lib/utils/pr-summary.sh double-source safe" {
  _assert_double_source_safe "utils/pr-summary.sh"
}

@test "lib/utils/repo-status.sh double-source safe" {
  _assert_double_source_safe "utils/repo-status.sh"
}

@test "lib/utils/review-assessment.sh double-source safe" {
  _assert_double_source_safe "utils/review-assessment.sh"
}

@test "lib/utils/review-helper.sh double-source safe" {
  _assert_double_source_safe "utils/review-helper.sh"
}

@test "lib/utils/scratchpad-manager.sh double-source safe" {
  _assert_double_source_safe "utils/scratchpad-manager.sh"
}

@test "lib/utils/stale-branch.sh double-source safe" {
  _assert_double_source_safe "utils/stale-branch.sh"
}

@test "lib/utils/stash-manager.sh double-source safe" {
  _assert_double_source_safe "utils/stash-manager.sh"
}

@test "lib/utils/blocker-rules.sh double-source safe" {
  _assert_double_source_safe "utils/blocker-rules.sh"
}

@test "lib/utils/timeout.sh double-source safe" {
  _assert_double_source_safe "utils/timeout.sh"
}

@test "lib/utils/config.sh double-source safe" {
  _assert_double_source_safe "utils/config.sh"
}

# ---------------------------------------------------------------------------
# lib/utils — standalone CLI scripts (sentinel guard test)
# These scripts call `exit` from main body, which propagates through `source`.
# The sentinel guard is set before any exit-prone code runs, so a second
# source (with sentinel pre-set) returns immediately without side effects.
# ---------------------------------------------------------------------------

@test "lib/utils/cleanup-worktrees.sh sentinel guard fires" {
  _assert_sentinel_guard_fires "utils/cleanup-worktrees.sh" "_RITE_CLEANUP_WORKTREES_LOADED"
}

@test "lib/utils/validate-setup.sh sentinel guard fires" {
  _assert_sentinel_guard_fires "utils/validate-setup.sh" "_RITE_VALIDATE_SETUP_LOADED"
}

# ---------------------------------------------------------------------------
# lib/providers — function libraries (direct double-source)
# ---------------------------------------------------------------------------

@test "lib/providers/provider-interface.sh double-source safe" {
  _assert_double_source_safe "providers/provider-interface.sh"
}

@test "lib/providers/claude.sh double-source safe" {
  _assert_double_source_safe "providers/claude.sh"
}

@test "lib/providers/gemini.sh double-source safe" {
  _assert_double_source_safe "providers/gemini.sh"
}

# ---------------------------------------------------------------------------
# lib/core — function libraries (direct double-source)
# ---------------------------------------------------------------------------

@test "lib/core/batch-reporter.sh double-source safe" {
  _assert_double_source_safe "core/batch-reporter.sh"
}

@test "lib/core/plan-issues.sh double-source safe" {
  _assert_double_source_safe "core/plan-issues.sh"
}

# ---------------------------------------------------------------------------
# lib/core — main-body CLI scripts (sentinel guard test)
# ---------------------------------------------------------------------------

@test "lib/core/assess-documentation.sh sentinel guard fires" {
  _assert_sentinel_guard_fires "core/assess-documentation.sh" "_RITE_ASSESS_DOCUMENTATION_LOADED"
}

@test "lib/core/assess-review-issues.sh sentinel guard fires" {
  _assert_sentinel_guard_fires "core/assess-review-issues.sh" "_RITE_ASSESS_REVIEW_LOADED"
}

@test "lib/core/batch-process-issues.sh sentinel guard fires" {
  _assert_sentinel_guard_fires "core/batch-process-issues.sh" "_RITE_BATCH_PROCESS_LOADED"
}

@test "lib/core/bootstrap-docs.sh sentinel guard fires" {
  _assert_sentinel_guard_fires "core/bootstrap-docs.sh" "_RITE_BOOTSTRAP_DOCS_LOADED"
}

@test "lib/core/create-pr.sh sentinel guard fires" {
  _assert_sentinel_guard_fires "core/create-pr.sh" "_RITE_CREATE_PR_LOADED"
}

@test "lib/core/local-review.sh sentinel guard fires" {
  _assert_sentinel_guard_fires "core/local-review.sh" "_RITE_LOCAL_REVIEW_LOADED"
}

@test "lib/core/merge-pr.sh sentinel guard fires" {
  _assert_sentinel_guard_fires "core/merge-pr.sh" "_RITE_MERGE_PR_LOADED"
}

@test "lib/core/undo-workflow.sh sentinel guard fires" {
  _assert_sentinel_guard_fires "core/undo-workflow.sh" "_RITE_UNDO_WORKFLOW_LOADED"
}

@test "lib/core/assess-and-resolve.sh sentinel guard fires" {
  _assert_sentinel_guard_fires "core/assess-and-resolve.sh" "_RITE_ASSESS_RESOLVE_LOADED"
}

@test "lib/core/workflow-runner.sh sentinel guard fires" {
  _assert_sentinel_guard_fires "core/workflow-runner.sh" "_RITE_WORKFLOW_RUNNER_LOADED"
}

@test "lib/core/claude-workflow.sh sentinel guard fires" {
  _assert_sentinel_guard_fires "core/claude-workflow.sh" "_RITE_CLAUDE_WORKFLOW_LOADED"
}

# ---------------------------------------------------------------------------
# format-review.sh — standalone script with function guard
# ---------------------------------------------------------------------------

@test "lib/utils/format-review.sh function guard fires on second source" {
  run bash -c "
set -euo pipefail
export RITE_LIB_DIR='$PROJECT_ROOT/lib'
extract_key_phrase() { echo stub; }
source '$PROJECT_ROOT/lib/utils/format-review.sh'
echo 'function-guard-ok'
"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "function-guard-ok" ]]
}

# ---------------------------------------------------------------------------
# Lint rule verification
# ---------------------------------------------------------------------------

@test "UNGUARDED_READONLY lint rule is active in sharkrite-lint.sh" {
  run grep -q "UNGUARDED_READONLY" "$PROJECT_ROOT/tools/sharkrite-lint.sh"
  [ "$status" -eq 0 ]
}

@test "codebase has zero unguarded readonly declarations in lib/" {
  run bash -c '
violations=0
while IFS=: read -r file lineno content; do
  if echo "$content" | grep -qE '"'"'^\s*#'"'"'; then continue; fi
  if echo "$content" | grep -qE '"'"'(if\s*\[|\[\s*-[znZ]|\[\s*"\$\{).*readonly|readonly.*\|\|'"'"'; then continue; fi
  prev=$((lineno - 1))
  prev_line=$(sed -n "${prev}p" "$file" 2>/dev/null || echo "")
  if echo "$prev_line" | grep -qE '"'"'(if\s*\[|\[\s*-[znZ]|\[\s*"\$\{|declare -f|_LOADED)'"'"'; then continue; fi
  echo "VIOLATION: $file:$lineno: $content"
  violations=$((violations + 1))
done < <(grep -rn "^\s*readonly\s" "'"$PROJECT_ROOT"'/lib" 2>/dev/null || true)
exit $violations
'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Verify that sentinel-based scripts define their sentinel variable
# ---------------------------------------------------------------------------

@test "all sentinel-based scripts define their sentinel variable" {
  local failed=0
  local checks=(
    "lib/core/assess-documentation.sh:_RITE_ASSESS_DOCUMENTATION_LOADED"
    "lib/core/assess-review-issues.sh:_RITE_ASSESS_REVIEW_LOADED"
    "lib/core/batch-process-issues.sh:_RITE_BATCH_PROCESS_LOADED"
    "lib/core/bootstrap-docs.sh:_RITE_BOOTSTRAP_DOCS_LOADED"
    "lib/core/create-pr.sh:_RITE_CREATE_PR_LOADED"
    "lib/core/local-review.sh:_RITE_LOCAL_REVIEW_LOADED"
    "lib/core/merge-pr.sh:_RITE_MERGE_PR_LOADED"
    "lib/core/undo-workflow.sh:_RITE_UNDO_WORKFLOW_LOADED"
    "lib/core/assess-and-resolve.sh:_RITE_ASSESS_RESOLVE_LOADED"
    "lib/core/workflow-runner.sh:_RITE_WORKFLOW_RUNNER_LOADED"
    "lib/core/claude-workflow.sh:_RITE_CLAUDE_WORKFLOW_LOADED"
    "lib/utils/cleanup-worktrees.sh:_RITE_CLEANUP_WORKTREES_LOADED"
    "lib/utils/validate-setup.sh:_RITE_VALIDATE_SETUP_LOADED"
  )
  for check in "${checks[@]}"; do
    rel_path="${check%%:*}"
    sentinel="${check##*:}"
    if ! grep -q "$sentinel" "$PROJECT_ROOT/$rel_path"; then
      echo "MISSING sentinel $sentinel in $rel_path"
      failed=$((failed + 1))
    fi
  done
  [ "$failed" -eq 0 ]
}
