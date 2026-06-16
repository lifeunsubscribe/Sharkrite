#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh
# Regression test for: No fallback when per-item summary comment fails
# Issue #552 (from PR #546 assessment)
#
# Bug: When SKIP_ROLLUP_DUE_TO_PER_ITEM=true and gh fails to post the
# per-item summary comment, the only feedback was a terse warning:
#   "Could not post summary comment (per-item issues are still filed)"
#
# The PR was left with no machine-readable marker linking to the filed issues,
# and no recovery artifact — a traceability gap with no path to manual recovery.
#
# Fix:
#   1. Capture gh stderr so the actual error is visible in logs
#   2. On failure, save the comment body (including machine-readable markers) to
#      .rite/orphaned-summary-comment-<PR>.md with re-post instructions
#   3. Emit a [diag] line for health-report aggregation
#
# Tests in this file:
#   1. Inline unit: failure path writes orphaned-summary-comment-<PR>.md
#   2. Inline unit: orphaned file contains the machine-readable markers
#   3. Inline unit: orphaned file contains re-post instructions
#   4. Inline unit: warning message includes PR number on failure
#   5. Static: gh_safe call no longer silences stderr with 2>/dev/null
#   6. Static: orphaned-summary-comment file write is present in source
#   7. Static: _diag line emitted on failure
#   8. Static: orphaned-summary path has intentional non-PID-scoped comment (#345 deviation)

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  mkdir -p "$RITE_TEST_TMPDIR/.rite"

  export ASSESS_RESOLVE_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
  [ -f "$ASSESS_RESOLVE_SCRIPT" ] || {
    echo "setup: ASSESS_RESOLVE_SCRIPT not found at $ASSESS_RESOLVE_SCRIPT" >&2
    false
  }
}

teardown() {
  teardown_test_tmpdir
}

# ─── Inline reproduction of the failure branch ────────────────────────────────
#
# We inline the critical section to avoid pulling in the full dependency graph.
# Static checks (Tests 5-7) catch any drift between the inlined block and source.

_per_item_comment_failure_inline='
  PR_NUMBER=99
  ISSUE_NUMBER=42
  RITE_MARKER_FOLLOWUP="sharkrite-followup-issue"
  PER_ITEM_ISSUES="201
202"

  _per_item_refs=""
  while IFS= read -r _num; do
    [ -z "$_num" ] && continue
    _per_item_refs="${_per_item_refs}#${_num} "
  done <<< "$PER_ITEM_ISSUES"
  _per_item_refs=$(echo "$_per_item_refs" | sed "s/[[:space:]]*$//" || true)

  _per_item_markers=""
  while IFS= read -r _mnum; do
    [ -z "$_mnum" ] && continue
    _per_item_markers="${_per_item_markers}<!-- ${RITE_MARKER_FOLLOWUP}:${_mnum} -->
"
  done <<< "$PER_ITEM_ISSUES"
  _summary_comment="${_per_item_markers}📋 **Follow-up issues filed (per-item):** ${_per_item_refs}

Each deferred finding has its own prioritized issue — no consolidated rollup needed."
  _summary_file=$(mktemp)
  printf "%s" "$_summary_comment" > "$_summary_file"
  _summary_stderr_file=$(mktemp)

  # Simulate gh_safe failure
  gh_safe() { echo "simulated network error" >&2; return 1; }

  if gh_safe pr comment "$PR_NUMBER" --body-file "$_summary_file" 2>"$_summary_stderr_file"; then
    print_success "Posted per-item follow-up summary to PR #$PR_NUMBER"
  else
    _summary_stderr=$(cat "$_summary_stderr_file" 2>/dev/null || true)
    print_warning "Could not post per-item summary comment to PR #$PR_NUMBER (per-item issues are still filed)"
    [ -n "$_summary_stderr" ] && print_warning "gh error: $_summary_stderr"
    # Intentionally NOT PID-scoped (deviation from #345 convention).
    # This is a persistent recovery artifact in .rite/, not a /tmp/ temp file.
    # Per-PR naming (no $$) is correct: content is idempotent per PR (safe to
    # overwrite), and a single well-known path makes manual recovery straightforward
    # — multiple PID-suffixed files would make the recovery file hard to discover.
    _orphaned_summary="${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}/orphaned-summary-comment-${PR_NUMBER}.md"
    mkdir -p "${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}" 2>/dev/null || true
    {
      echo "# Orphaned Per-Item Summary Comment"
      echo "# Generated: $(date '"'"'+%Y-%m-%d %H:%M:%S'"'"')"
      echo "# PR: #${PR_NUMBER}"
      echo "# Source issue: #${ISSUE_NUMBER:-unknown}"
      echo "# Re-post: gh pr comment ${PR_NUMBER} --body-file <this-file>"
      echo "# (Re-run '"'"'rite ${ISSUE_NUMBER:-N} --assess-and-fix'"'"' to regenerate automatically)"
      echo ""
      cat "$_summary_file" 2>/dev/null || echo "(comment body unavailable)"
    } > "$_orphaned_summary" || true
    print_warning "Comment body saved to: $_orphaned_summary"
    _diag "PER_ITEM_SUMMARY_COMMENT_FAILED pr=${PR_NUMBER} issue=${ISSUE_NUMBER:-} orphaned=${_orphaned_summary}"
  fi
  rm -f "$_summary_file" "$_summary_stderr_file"
  unset _per_item_refs _per_item_markers _summary_comment _summary_file _num _mnum \
        _summary_stderr_file _summary_stderr _orphaned_summary
'

# ─── Test 1: failure path writes orphaned-summary-comment-<PR>.md ─────────────

@test "per-item summary comment: failure path writes orphaned-summary-comment file" {
  bash -c "
    set -uo pipefail
    GREEN=''; RED=''; YELLOW=''; NC=''; BOLD=''
    print_warning() { echo \"WARNING: \$*\" >&2; }
    print_error()   { echo \"ERROR: \$*\" >&2; }
    print_success() { echo \"SUCCESS: \$*\"; }
    _diag() { true; }
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_DATA_DIR='.rite'

    $_per_item_comment_failure_inline
  " 2>/dev/null

  _orphaned="$RITE_TEST_TMPDIR/.rite/orphaned-summary-comment-99.md"
  [ -f "$_orphaned" ] || {
    echo "FAIL: orphaned-summary-comment-99.md not created at $_orphaned"
    false
  }
}

# ─── Test 2: orphaned file contains machine-readable markers ──────────────────

@test "per-item summary comment: orphaned file contains sharkrite-followup-issue markers" {
  bash -c "
    set -uo pipefail
    GREEN=''; RED=''; YELLOW=''; NC=''; BOLD=''
    print_warning() { echo \"WARNING: \$*\" >&2; }
    print_error()   { echo \"ERROR: \$*\" >&2; }
    print_success() { echo \"SUCCESS: \$*\"; }
    _diag() { true; }
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_DATA_DIR='.rite'

    $_per_item_comment_failure_inline
  " 2>/dev/null

  _orphaned="$RITE_TEST_TMPDIR/.rite/orphaned-summary-comment-99.md"
  _contents=$(cat "$_orphaned")

  # Must contain the machine-readable marker for issue 201
  [[ "$_contents" == *"sharkrite-followup-issue:201"* ]] || {
    echo "FAIL: orphaned file missing marker for issue 201"
    echo "Contents: $_contents"
    false
  }

  # Must contain the machine-readable marker for issue 202
  [[ "$_contents" == *"sharkrite-followup-issue:202"* ]] || {
    echo "FAIL: orphaned file missing marker for issue 202"
    echo "Contents: $_contents"
    false
  }
}

# ─── Test 3: orphaned file contains re-post instructions ──────────────────────

@test "per-item summary comment: orphaned file contains gh re-post command" {
  bash -c "
    set -uo pipefail
    GREEN=''; RED=''; YELLOW=''; NC=''; BOLD=''
    print_warning() { echo \"WARNING: \$*\" >&2; }
    print_error()   { echo \"ERROR: \$*\" >&2; }
    print_success() { echo \"SUCCESS: \$*\"; }
    _diag() { true; }
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_DATA_DIR='.rite'

    $_per_item_comment_failure_inline
  " 2>/dev/null

  _orphaned="$RITE_TEST_TMPDIR/.rite/orphaned-summary-comment-99.md"
  _contents=$(cat "$_orphaned")

  # Must contain a re-post command referencing the PR number
  [[ "$_contents" == *"gh pr comment 99"* ]] || {
    echo "FAIL: orphaned file missing re-post command with PR number"
    echo "Contents: $_contents"
    false
  }
}

# ─── Test 4: warning message includes PR number on failure ────────────────────

@test "per-item summary comment: warning message includes PR number" {
  run bash -c "
    set -uo pipefail
    GREEN=''; RED=''; YELLOW=''; NC=''; BOLD=''
    print_warning() { echo \"WARNING: \$*\" >&2; }
    print_error()   { echo \"ERROR: \$*\" >&2; }
    print_success() { echo \"SUCCESS: \$*\"; }
    _diag() { true; }
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_DATA_DIR='.rite'

    $_per_item_comment_failure_inline
  " 2>&1

  [[ "$output" == *"PR #99"* ]] || {
    echo "FAIL: warning did not mention PR #99"
    echo "Output: $output"
    false
  }
}

# ─── Test 5: static check — gh_safe call no longer silences stderr ────────────

@test "assess-and-resolve.sh: per-item summary gh_safe call does not use 2>/dev/null" {
  # The original bug hid error detail by suppressing stderr.
  # After the fix, stderr must be captured to a temp file (not /dev/null).
  #
  # Check: the gh_safe pr comment call for the per-item summary path must NOT
  # be immediately followed by 2>/dev/null on the same line.
  _bad_pattern=$(grep -n 'gh_safe pr comment.*--body-file.*_summary_file.*2>/dev/null' \
    "$ASSESS_RESOLVE_SCRIPT" || true)

  [ -z "$_bad_pattern" ] || {
    echo "FAIL: per-item summary gh_safe call still uses 2>/dev/null:"
    echo "$_bad_pattern"
    false
  }
}

# ─── Test 6: static check — orphaned-summary-comment write present in source ──

@test "assess-and-resolve.sh: orphaned-summary-comment write is present in source" {
  _write=$(grep -n 'orphaned-summary-comment' "$ASSESS_RESOLVE_SCRIPT" || true)

  [ -n "$_write" ] || {
    echo "FAIL: orphaned-summary-comment write not found in $ASSESS_RESOLVE_SCRIPT"
    false
  }

  # Must reference the PR number variable for a unique filename per PR
  [[ "$_write" == *'PR_NUMBER'* ]] || {
    echo "FAIL: orphaned-summary-comment filename does not include PR_NUMBER"
    echo "Found: $_write"
    false
  }
}

# ─── Test 7: static check — _diag line emitted on failure ────────────────────

@test "assess-and-resolve.sh: _diag emitted on per-item summary comment failure" {
  _diag_line=$(grep -n 'PER_ITEM_SUMMARY_COMMENT_FAILED' "$ASSESS_RESOLVE_SCRIPT" || true)

  [ -n "$_diag_line" ] || {
    echo "FAIL: PER_ITEM_SUMMARY_COMMENT_FAILED diag line not found in $ASSESS_RESOLVE_SCRIPT"
    false
  }
}

# ─── Test 8: static check — non-PID-scoped deviation comment present ─────────

@test "assess-and-resolve.sh: orphaned-summary path has intentional non-PID-scoped comment" {
  # The #345 convention requires PID-suffixed temp files to prevent concurrent-run
  # clobbering.  The orphaned-summary-comment file deliberately deviates: it is a
  # persistent recovery artifact (in .rite/, not /tmp/) and per-PR naming is
  # intentional (idempotent content; single well-known path aids manual recovery).
  # This test asserts the deviation is documented with an inline comment so future
  # readers (and reviewers) understand the intentional choice.
  _comment=$(grep -n 'NOT PID-scoped' "$ASSESS_RESOLVE_SCRIPT" || true)

  [ -n "$_comment" ] || {
    echo "FAIL: intentional non-PID-scoped deviation comment not found near _orphaned_summary in $ASSESS_RESOLVE_SCRIPT"
    echo "Expected a comment explaining why orphaned-summary-comment-\${PR_NUMBER}.md is not PID-scoped"
    false
  }
}
