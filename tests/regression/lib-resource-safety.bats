#!/usr/bin/env bats
# Regression test: lib file re-source safety
#
# Every file in lib/ must be safe to source multiple times under
# set -euo pipefail. This prevents "readonly re-assignment crashes" and
# "program logic re-runs on double-source" bugs documented in:
#   - #61: assess-documentation.sh — verbose_info undefined
#   - #69: issue-lock.sh — guard checked wrong variable (RITE_LIB_DIR vs RITE_LOCK_DIR)
#   - commit 2267841: stash-manager.sh — readonly crash on re-source
#   - commit 93c7ddd: claude.sh — source-path construction bug
#
# Test strategy:
#
# Two categories of lib files:
#
# 1. Pure library files (only define functions, no top-level program logic):
#    Source twice unconditionally. Both sources must exit 0.
#
# 2. Executable-with-functions files (have top-level program logic after
#    function defs — require a tty, git context, etc.):
#    Source twice with RITE_SOURCE_FUNCTIONS_ONLY=1. Both sources must exit 0.
#    These files implement the local-review.sh pattern: function defs first,
#    then a guard that stops before the executable body when in function-only mode.
#
# Files that need RITE_SOURCE_FUNCTIONS_ONLY=1 are those known to run top-level
# interactive or network-dependent code (cleanup-worktrees.sh). Other executables
# (validate-setup.sh, format-review.sh) have their own variable-based guards that
# make second-source exit 0 without needing the env var.

setup() {
  # RITE_REPO_ROOT is the sharkrite source root
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT
}

# ---------------------------------------------------------------------------
# Helper: double-source a single file and assert both sources exit 0
#
# Usage: _assert_double_source <lib_file> [source_only_mode]
#   lib_file        — path relative to RITE_REPO_ROOT
#   source_only_mode — if "1", export RITE_SOURCE_FUNCTIONS_ONLY=1 before sourcing
# ---------------------------------------------------------------------------
_assert_double_source() {
  local lib_file="$1"
  local source_only="${2:-0}"

  local env_prefix=""
  if [ "$source_only" = "1" ]; then
    env_prefix="export RITE_SOURCE_FUNCTIONS_ONLY=1; "
  fi

  # Run in a fresh subshell with set -euo pipefail.
  # Both sources must succeed (exit 0). If either fails, the subshell exits
  # non-zero and 'run' captures that in $status.
  run bash -c "
    ${env_prefix}set -euo pipefail
    source '${RITE_REPO_ROOT}/${lib_file}' 2>/dev/null
    source '${RITE_REPO_ROOT}/${lib_file}' 2>/dev/null
    echo OK
  "

  # Status 0 means both sources exited 0
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# lib/utils — pure function libraries
# ---------------------------------------------------------------------------

@test "lib/utils/blocker-rules.sh sources twice without error" {
  _assert_double_source "lib/utils/blocker-rules.sh"
}

@test "lib/utils/branch-preflight.sh sources twice without error" {
  _assert_double_source "lib/utils/branch-preflight.sh"
}

@test "lib/utils/colors.sh sources twice without error" {
  _assert_double_source "lib/utils/colors.sh"
}

@test "lib/utils/config.sh sources twice without error" {
  _assert_double_source "lib/utils/config.sh"
}

@test "lib/utils/create-followup-issues.sh sources twice without error" {
  _assert_double_source "lib/utils/create-followup-issues.sh"
}

@test "lib/utils/date-helpers.sh sources twice without error" {
  _assert_double_source "lib/utils/date-helpers.sh"
}

@test "lib/utils/divergence-handler.sh sources twice without error" {
  _assert_double_source "lib/utils/divergence-handler.sh"
}

@test "lib/utils/format-review.sh sources twice without error" {
  _assert_double_source "lib/utils/format-review.sh"
}

@test "lib/utils/gh-retry.sh sources twice without error" {
  _assert_double_source "lib/utils/gh-retry.sh"
}

@test "lib/utils/git-helpers.sh sources twice without error" {
  _assert_double_source "lib/utils/git-helpers.sh"
}

@test "lib/utils/issue-lock.sh sources twice without error" {
  # Regression: #69 — guard checked wrong variable (RITE_LIB_DIR vs RITE_LOCK_DIR)
  # This test confirms the guard uses RITE_LOCK_DIR, not RITE_LIB_DIR.
  _assert_double_source "lib/utils/issue-lock.sh"
}

@test "lib/utils/labels.sh sources twice without error" {
  _assert_double_source "lib/utils/labels.sh"
}

@test "lib/utils/markers.sh sources twice without error" {
  _assert_double_source "lib/utils/markers.sh"
}

@test "lib/utils/logging.sh sources twice without error" {
  _assert_double_source "lib/utils/logging.sh"
}

@test "lib/utils/normalize-issue.sh sources twice without error" {
  _assert_double_source "lib/utils/normalize-issue.sh"
}

@test "lib/utils/notifications.sh sources twice without error" {
  _assert_double_source "lib/utils/notifications.sh"
}

@test "lib/utils/portable-cmds.sh sources twice without error" {
  _assert_double_source "lib/utils/portable-cmds.sh"
}

@test "lib/utils/post-merge-verify.sh sources twice without error" {
  _assert_double_source "lib/utils/post-merge-verify.sh"
}

@test "lib/utils/pr-detection.sh sources twice without error" {
  _assert_double_source "lib/utils/pr-detection.sh"
}

@test "lib/utils/pr-summary.sh sources twice without error" {
  _assert_double_source "lib/utils/pr-summary.sh"
}

@test "lib/utils/repo-status.sh sources twice without error" {
  _assert_double_source "lib/utils/repo-status.sh"
}

@test "lib/utils/review-assessment.sh sources twice without error" {
  _assert_double_source "lib/utils/review-assessment.sh"
}

@test "lib/utils/review-helper.sh sources twice without error" {
  _assert_double_source "lib/utils/review-helper.sh"
}

@test "lib/utils/scope-checker.sh sources twice without error" {
  _assert_double_source "lib/utils/scope-checker.sh"
}

@test "lib/utils/scratchpad-lock.sh sources twice without error" {
  _assert_double_source "lib/utils/scratchpad-lock.sh"
}

@test "lib/utils/scratchpad-manager.sh sources twice without error" {
  _assert_double_source "lib/utils/scratchpad-manager.sh"
}

@test "lib/utils/session-tracker.sh sources twice without error" {
  _assert_double_source "lib/utils/session-tracker.sh"
}

@test "lib/utils/stale-branch.sh sources twice without error" {
  _assert_double_source "lib/utils/stale-branch.sh"
}

@test "lib/utils/stash-manager.sh sources twice without error" {
  # Regression: commit 2267841 — readonly crash on re-source
  _assert_double_source "lib/utils/stash-manager.sh"
}

@test "lib/utils/timeout.sh sources twice without error" {
  # Reference implementation of the canonical guard pattern
  _assert_double_source "lib/utils/timeout.sh"
}

@test "lib/utils/validate-setup.sh sources twice without error" {
  _assert_double_source "lib/utils/validate-setup.sh"
}

# ---------------------------------------------------------------------------
# lib/utils — executables that need RITE_SOURCE_FUNCTIONS_ONLY=1
# ---------------------------------------------------------------------------

@test "lib/utils/cleanup-worktrees.sh sources twice with RITE_SOURCE_FUNCTIONS_ONLY=1" {
  # cleanup-worktrees.sh runs an interactive tty program; RITE_SOURCE_FUNCTIONS_ONLY=1
  # stops it before the interactive body so tests can load it safely.
  _assert_double_source "lib/utils/cleanup-worktrees.sh" "1"
}

# ---------------------------------------------------------------------------
# lib/providers
# ---------------------------------------------------------------------------

@test "lib/providers/claude.sh sources twice without error" {
  # Regression: commit 93c7ddd — source-path construction bug (/utils misplaced)
  _assert_double_source "lib/providers/claude.sh"
}

@test "lib/providers/gemini.sh sources twice without error" {
  _assert_double_source "lib/providers/gemini.sh"
}

@test "lib/providers/provider-interface.sh sources twice without error" {
  _assert_double_source "lib/providers/provider-interface.sh"
}

# ---------------------------------------------------------------------------
# lib/core — pure function libraries (sourceable)
# ---------------------------------------------------------------------------

@test "lib/core/batch-reporter.sh sources twice without error" {
  _assert_double_source "lib/core/batch-reporter.sh"
}

# ---------------------------------------------------------------------------
# lib/core — orchestrators with env-var guards
#
# These files source config.sh and other deps on first load, so they cannot
# be sourced cold in a test environment. We verify the guard itself works by
# pre-setting the loaded variable, then sourcing twice. Both sources hit the
# guard and return 0 immediately — confirming the guard machinery is correct.
# ---------------------------------------------------------------------------

@test "lib/core/assess-and-resolve.sh guard exits 0 on re-source" {
  run bash -c "
    set -euo pipefail
    export _RITE_ASSESS_AND_RESOLVE_LOADED=true
    source '${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh' 2>/dev/null
    source '${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh' 2>/dev/null
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "lib/core/batch-process-issues.sh guard exits 0 on re-source" {
  run bash -c "
    set -euo pipefail
    export _RITE_BATCH_PROCESS_LOADED=true
    source '${RITE_REPO_ROOT}/lib/core/batch-process-issues.sh' 2>/dev/null
    source '${RITE_REPO_ROOT}/lib/core/batch-process-issues.sh' 2>/dev/null
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "lib/core/claude-workflow.sh guard exits 0 on re-source" {
  run bash -c "
    set -euo pipefail
    export _RITE_CLAUDE_WORKFLOW_LOADED=true
    source '${RITE_REPO_ROOT}/lib/core/claude-workflow.sh' 2>/dev/null
    source '${RITE_REPO_ROOT}/lib/core/claude-workflow.sh' 2>/dev/null
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "lib/core/create-pr.sh guard exits 0 on re-source" {
  run bash -c "
    set -euo pipefail
    export _RITE_CREATE_PR_LOADED=true
    source '${RITE_REPO_ROOT}/lib/core/create-pr.sh' 2>/dev/null
    source '${RITE_REPO_ROOT}/lib/core/create-pr.sh' 2>/dev/null
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "lib/core/merge-pr.sh guard exits 0 on re-source" {
  run bash -c "
    set -euo pipefail
    export _RITE_MERGE_PR_LOADED=true
    source '${RITE_REPO_ROOT}/lib/core/merge-pr.sh' 2>/dev/null
    source '${RITE_REPO_ROOT}/lib/core/merge-pr.sh' 2>/dev/null
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "lib/core/undo-workflow.sh guard exits 0 on re-source" {
  run bash -c "
    set -euo pipefail
    export _RITE_UNDO_WORKFLOW_LOADED=true
    source '${RITE_REPO_ROOT}/lib/core/undo-workflow.sh' 2>/dev/null
    source '${RITE_REPO_ROOT}/lib/core/undo-workflow.sh' 2>/dev/null
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "lib/core/workflow-runner.sh guard exits 0 on re-source" {
  run bash -c "
    set -euo pipefail
    export _RITE_WORKFLOW_RUNNER_LOADED=true
    source '${RITE_REPO_ROOT}/lib/core/workflow-runner.sh' 2>/dev/null
    source '${RITE_REPO_ROOT}/lib/core/workflow-runner.sh' 2>/dev/null
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

# ---------------------------------------------------------------------------
# Lint rule verification: MISSING_RESOURCE_GUARD catches unguarded files
# ---------------------------------------------------------------------------

@test "lint rule MISSING_RESOURCE_GUARD detects file without re-source guard" {
  local fixture_dir="${RITE_REPO_ROOT}/lib/test-fixtures-temp"
  mkdir -p "$fixture_dir"

  # Create a lib file WITHOUT a re-source guard
  cat > "$fixture_dir/unguarded.sh" << 'EOF'
#!/bin/bash
# lib/test-fixtures-temp/unguarded.sh - no re-source guard (fixture for lint test)
set -euo pipefail

some_function() {
  echo "hello"
}
EOF

  # Lint should flag our fixture with MISSING_RESOURCE_GUARD.
  # We check for the rule name in output, not overall exit status — other pre-existing
  # lint rules (UNSAFE_PIPE_IN_CMDSUB, etc.) may also fire and that's expected.
  run bash "${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"

  rm -f "$fixture_dir/unguarded.sh"
  rmdir "$fixture_dir" 2>/dev/null || true

  [[ "$output" =~ "MISSING_RESOURCE_GUARD" ]]
  [[ "$output" =~ "unguarded.sh" ]]
}

@test "lint rule MISSING_RESOURCE_GUARD passes file with declare -f guard" {
  local fixture_dir="${RITE_REPO_ROOT}/lib/test-fixtures-temp"
  mkdir -p "$fixture_dir"

  # Create a lib file WITH the canonical declare -f guard
  cat > "$fixture_dir/guarded.sh" << 'EOF'
#!/bin/bash
# lib/test-fixtures-temp/guarded.sh - has canonical re-source guard
set -euo pipefail

if declare -f guarded_function >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

guarded_function() {
  echo "hello"
}
EOF

  # Lint should NOT flag our guarded fixture with MISSING_RESOURCE_GUARD.
  # (Other pre-existing lint rules may still fire — that's expected and unrelated.)
  run bash "${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"
  local lint_output="$output"

  rm -f "$fixture_dir/guarded.sh"
  rmdir "$fixture_dir" 2>/dev/null || true

  # guarded.sh must NOT appear paired with MISSING_RESOURCE_GUARD in the output.
  # Filter only the MISSING_RESOURCE_GUARD lines and check guarded.sh is absent.
  local guard_violations
  guard_violations=$(echo "$lint_output" | grep "MISSING_RESOURCE_GUARD" || true)
  ! echo "$guard_violations" | grep -q "guarded.sh"
}

@test "codebase: no lib files have MISSING_RESOURCE_GUARD violations" {
  # Run the lint tool and extract only MISSING_RESOURCE_GUARD lines.
  # This test fails if any lib file is added without a guard.
  # Other pre-existing lint violations (UNSAFE_PIPE_IN_CMDSUB, etc.) are
  # ignored here — they are tracked by their own regression tests.
  run bash -c "
    bash '${RITE_REPO_ROOT}/tools/sharkrite-lint.sh' 2>/dev/null \
      | grep 'MISSING_RESOURCE_GUARD' || true
  "

  # If any MISSING_RESOURCE_GUARD violations were found, output will be non-empty
  if [ -n "$output" ]; then
    echo "MISSING_RESOURCE_GUARD violations found:" >&3
    echo "$output" >&3
    false
  fi
}
