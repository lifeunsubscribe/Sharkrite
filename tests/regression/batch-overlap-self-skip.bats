#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh, lib/core/workflow-runner.sh
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

@test "behavioral: slug containing 'issue' with colliding number does NOT match (no false positive)" {
  # fix-issue-queue-99 must NOT match issue 9 — the word "issue" followed by a
  # digit containing 9 was matched by the now-removed *"issue"?*N* alternate.
  run _bsm "fix-issue-queue-99" "9"
  [ "$status" -ne 0 ]
}

@test "behavioral: batch slug with colliding number in later position does NOT match (no false positive)" {
  # fix-issue-runbook_b1470-1471 must NOT match issue 147 — _b1470 contains the
  # digits 1,4,7 but is not the whole-token _b147 suffix.
  run _bsm "fix-issue-runbook_b1470-1471" "147"
  [ "$status" -ne 0 ]
}

# =============================================================================
# STRUCTURAL: verify grep-E sites carry ([^0-9]|$) trailing anchor on issue.?N and #N
# =============================================================================

@test "structural: workflow-runner.sh all three worktree-discover sites have anchored issue[^0-9]?N pattern" {
  # Three sites: PR-exists-but-no-worktree recovery (line ~964), initial fresh
  # discover (~1011), and retry re-discover (~1053); all must carry [^0-9]? and
  # the trailing ([^0-9]|$) anchor to prevent substring collisions.
  local _count
  _count=$(grep -cF 'issue[^0-9]?${issue_number}([^0-9]|$)' "$WORKFLOW_RUNNER" || true)
  [ "$_count" -ge 3 ]
}

@test "structural: workflow-runner.sh has no unanchored issue/# worktree-discover grep (old form absent)" {
  # The old unanchored form '(issue.?${issue_number}|#${issue_number})' must be
  # gone; any match here means a site was not updated.
  local _count
  _count=$(grep -cF 'issue.?${issue_number}|#${issue_number})' "$WORKFLOW_RUNNER" || true)
  [ "$_count" -eq 0 ]
}

@test "structural: batch-process-issues.sh active-wt detect has trailing non-digit anchor on issue[^0-9]?N" {
  grep -qF 'issue[^0-9]?${ISSUE_NUM}([^0-9]|$)' "$BATCH_PROCESSOR"
}

# =============================================================================
# BEHAVIORAL: grep-E pattern substring-collision prevention (issue.?N and #N)
# =============================================================================

# Helper: run the same grep-E used at the three worktree-discover sites.
# Args: <path> <issue_num>
# Returns 0 if the path matches, 1 if not.
_wt_grep() {
  local _path="$1" _n="$2"
  printf '%s\n' "$_path" | \
    grep -qE "(issue[^0-9]?${_n}([^0-9]|\$)|#${_n}([^0-9]|\$)|[-_]${_n}[-_]|[-_]${_n}\$|_b${_n}[-_]|_b${_n}\$)"
}

@test "grep-E behavioral: issue-141 matches issue 141" {
  run _wt_grep "fix-issue-141" "141"
  [ "$status" -eq 0 ]
}

@test "grep-E behavioral: issue-1419 must NOT match issue 141 (substring collision)" {
  run _wt_grep "fix-issue-1419" "141"
  [ "$status" -ne 0 ]
}

@test "grep-E behavioral: #141 matches issue 141" {
  run _wt_grep "branch#141" "141"
  [ "$status" -eq 0 ]
}

@test "grep-E behavioral: #1419 must NOT match issue 141 (substring collision on # prefix)" {
  run _wt_grep "branch#1419" "141"
  [ "$status" -ne 0 ]
}

@test "grep-E behavioral: issue2141 must NOT match issue 141 (leading-digit-swallow via .?)" {
  # .? matches any character including a digit, so issue2141 could match
  # issue + (any char) + 141. [^0-9]? prevents this.
  run _wt_grep "fix-issue2141" "141"
  [ "$status" -ne 0 ]
}
