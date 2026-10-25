#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh::batch_suffix_matches_issue, lib/core/workflow-runner.sh
# Regression test: batch-suffix self-skip in overlap guard (#1460)
#
# Bug: The cross-batch overlap guard's self-skip pattern (*[-_]N[-_]*|*[-_]N)
# failed to match a worktree whose batch suffix carries the _b<N> form.
# An issue detected its own worktree as a conflicting peer and deferred itself.
# Only the first issue in a _b<N>-<N>-<N> suffix was affected because later
# numbers are flanked by plain hyphens.
#
# Fix: batch_suffix_matches_issue() helper added to batch-process-issues.sh
# covers both the _b<N>[-_] batch-suffix form and the plain [-_]<N>[-_] form.
# Three grep-E sites in batch-process-issues.sh and workflow-runner.sh extended
# to add _b${N}[-_]|_b${N}$ to their patterns.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
WORKFLOW_RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"

setup() {
  [ -f "$BATCH_PROCESSOR" ] || {
    echo "FATAL: $BATCH_PROCESSOR not found" >&2
    return 1
  }
  [ -f "$WORKFLOW_RUNNER" ] || {
    echo "FATAL: $WORKFLOW_RUNNER not found" >&2
    return 1
  }
}

# Extract batch_suffix_matches_issue from the source file and invoke it in a
# subshell so the test drives the actual implementation, not a copy.
# Args: <path> <issue_num>
# Returns the exit code of the function (0=matched, 1=no match).
_bsm() {
  local _path="$1" _n="$2"
  local _src
  _src=$(awk '
    /^batch_suffix_matches_issue\(\)/ { in_func=1 }
    in_func { print }
    in_func && /^\}$/ { exit }
  ' "$BATCH_PROCESSOR")
  bash -c "
    set -euo pipefail
    ${_src}
    batch_suffix_matches_issue $(printf '%q' "$_path") $(printf '%q' "$_n")
  "
}

# =============================================================================
# STRUCTURAL: verify all four sites use the shared matcher
# =============================================================================

@test "structural: batch_suffix_matches_issue() function exists in batch-process-issues.sh" {
  grep -q 'batch_suffix_matches_issue()' "$BATCH_PROCESSOR"
}

@test "structural: batch-process-issues.sh has batch_suffix_matches_issue or _b\${" {
  local _count
  _count=$(grep -c 'batch_suffix_matches_issue\|_b\${' "$BATCH_PROCESSOR" || true)
  [ "$_count" -ge 2 ]
}

@test "structural: workflow-runner.sh has _b\${issue_number} at both worktree-discover sites" {
  local _count
  _count=$(grep -c '_b\${issue_number}' "$WORKFLOW_RUNNER" || true)
  [ "$_count" -ge 2 ]
}

@test "structural: batch-process-issues.sh active-wt detect includes _b\${ISSUE_NUM}" {
  grep -q '_b\${ISSUE_NUM}' "$BATCH_PROCESSOR"
}

# =============================================================================
# BEHAVIORAL: batch_suffix_matches_issue function correctness
# =============================================================================

@test "behavioral: _b<N> matches at FIRST position in batch suffix (live failure shape)" {
  # Exact live failure from #1460: issue 1419 saw its own worktree
  # dc-phase-1-commit-docs-map-with_b1419-1420-1421 as a conflicting peer.
  run _bsm "dc-phase-1-commit-docs-map-with_b1419-1420-1421" "1419"
  [ "$status" -eq 0 ]
}

@test "behavioral: _b<N> matches at SECOND position in batch suffix" {
  run _bsm "slug_b1419-1420-1421" "1420"
  [ "$status" -eq 0 ]
}

@test "behavioral: _b<N> matches at THIRD position in batch suffix" {
  run _bsm "slug_b1419-1420-1421" "1421"
  [ "$status" -eq 0 ]
}

@test "behavioral: _b<N> matches when N is the only entry in suffix" {
  run _bsm "fix-foo_b1419" "1419"
  [ "$status" -eq 0 ]
}

@test "behavioral: plain [-_]<N>[-_] separator form still matches" {
  run _bsm "issue-1419-fix-foo" "1419"
  [ "$status" -eq 0 ]
}

@test "behavioral: plain [-_]<N> at end-of-string still matches" {
  run _bsm "fix-foo-1419" "1419"
  [ "$status" -eq 0 ]
}

@test "behavioral: substring collision - issue 9 must NOT match _b99-100" {
  # _b99-100: char after _b9 is '9', not a separator — must NOT match issue 9.
  run _bsm "_b99-100" "9"
  [ "$status" -ne 0 ]
}

@test "behavioral: substring collision - issue 9 must NOT match slug-99-bar" {
  run _bsm "slug-99-bar" "9"
  [ "$status" -ne 0 ]
}

@test "behavioral: unrelated worktree does NOT match" {
  run _bsm "fix-unrelated-feature-1234" "1419"
  [ "$status" -ne 0 ]
}
