#!/usr/bin/env bats
# Regression test for: Track follow-up creation failures in assessment
# Issue #156 / #157
#
# Bug: assess-and-resolve.sh printed "All issues resolved or tracked - ready to
# proceed" even when `gh issue create` failed with non-zero.  The ACTIONABLE_LATER
# items were silently dropped — no GitHub issue, no scratchpad entry.
#
# Fix:
#   1. On gh issue create failure, set _followup_creation_failed=true and write
#      orphaned items to .rite/orphaned-followup-items.md.
#   2. Final summary checks _followup_creation_failed before printing the "ready
#      to proceed" success message — exits 1 with actionable remediation instead.
#
# This test verifies:
#   1. When follow-up creation fails, the script exits non-zero (exit 1)
#   2. .rite/orphaned-followup-items.md is written and contains the item content
#   3. "All issues resolved or tracked" is NOT printed on failure
#   4. An actionable recovery message IS printed on failure
#   5. Structural: _followup_creation_failed guards the success exit path in source
#   6. Structural: orphaned-followup-items.md path is computed in the failure branch

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"

  mkdir -p "$RITE_TEST_TMPDIR/.rite"

  # Stub print functions (output to stderr; bats captures stderr via 2>&1 redirect)
  print_status()   { echo "STATUS: $*"  >&2; }
  print_info()     { echo "INFO: $*"    >&2; }
  print_warning()  { echo "WARNING: $*" >&2; }
  print_error()    { echo "ERROR: $*"   >&2; }
  print_success()  { echo "SUCCESS: $*" >&2; }
  print_header()   { echo "HEADER: $*"  >&2; }
  print_critical() { echo "CRITICAL: $*" >&2; }
  export -f print_status print_info print_warning print_error print_success print_header print_critical
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helpers — inline the failure path and final-summary logic from
# assess-and-resolve.sh so we can exercise it without sourcing the full
# script (which needs a live GH environment and many sourced utilities).
#
# If this block diverges from the source, Test 5 and 6 (static checks)
# will catch the mismatch.
# ---------------------------------------------------------------------------

# The failure branch (inside the `else` of `if FOLLOWUP_ISSUE=$(gh issue create ...)`)
_followup_failure_block='
  _followup_creation_failed=true
  _orphaned_file="${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}/orphaned-followup-items.md"
  mkdir -p "$(dirname "$_orphaned_file")" 2>/dev/null || true
  {
    printf "# Orphaned Follow-up Items\n\n"
    printf "<!-- Written by assess-and-resolve.sh on follow-up creation failure -->\n"
    printf "<!-- Re-run: rite %s --assess-and-fix   (after resolving the gh API issue) -->\n\n" "${ISSUE_NUMBER:-$PR_NUMBER}"
    printf "**PR:** #%s\n" "$PR_NUMBER"
    [ -n "${ISSUE_NUMBER:-}" ] && printf "**Source Issue:** #%s\n" "$ISSUE_NUMBER"
    printf "**Date:** %s\n\n" "$(date -u '\''+%Y-%m-%dT%H:%M:%SZ'\'' 2>/dev/null || date '\''+%Y-%m-%dT%H:%M:%SZ'\'')"
    printf "## Items Not Tracked\n\n"
    printf "%s\n" "${FILTERED_CONTENT:-${FOLLOWUP_BODY:-*(assessment content unavailable)*}}"
  } > "$_orphaned_file" 2>/dev/null || true
'

# The final-summary block — the guard that was missing before the fix
_final_summary_block='
  if [ "${_followup_creation_failed:-false}" = "true" ]; then
    _orphaned_file="${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}/orphaned-followup-items.md"
    print_error "Follow-up creation failed. Items NOT tracked."
    echo ""
    echo "  The deferred ACTIONABLE_LATER item(s) were not filed as a GitHub issue."
    echo "  They have been saved to: ${_orphaned_file}"
    echo ""
    echo "  To recover:"
    echo "    1. Check the orphaned items file — confirm what was not tracked"
    echo "    2. Resolve the underlying gh API issue (auth, rate limit, network)"
    echo "    3. Re-run: rite ${ISSUE_NUMBER:-$PR_NUMBER} --assess-and-fix"
    exit 1
  fi
  if [ "$MERGE_EXIT_CODE" -eq 0 ]; then
    print_success "All issues resolved or tracked - ready to proceed"
    exit 0
  else
    print_error "CRITICAL issues remain — manual intervention required"
    exit 1
  fi
'

# ---------------------------------------------------------------------------
# Test 1: failure branch exits non-zero
# ---------------------------------------------------------------------------

@test "assess-and-resolve: follow-up creation failure causes non-zero exit" {
  run bash -c "
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_DATA_DIR='.rite'
    mkdir -p '$RITE_TEST_TMPDIR/.rite'

    print_error()   { echo \"ERROR: \$*\" >&2; }
    print_success() { echo \"SUCCESS: \$*\" >&2; }
    export -f print_error print_success

    PR_NUMBER=99
    ISSUE_NUMBER=49
    MERGE_EXIT_CODE=0
    FILTERED_CONTENT='### Missing input validation - ACTIONABLE_LATER
Severity: MEDIUM
Defer Reason: Out of scope for current PR'

    # Simulate failure branch: set the flag and write orphaned file
    $_followup_failure_block

    # Simulate final summary: should exit 1 because flag is set
    $_final_summary_block
  " 2>&1

  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 2: orphaned-followup-items.md is written with item content
# ---------------------------------------------------------------------------

@test "assess-and-resolve: orphaned-followup-items.md written on creation failure" {
  _orphaned_file="$RITE_TEST_TMPDIR/.rite/orphaned-followup-items.md"

  bash -c "
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_DATA_DIR='.rite'
    mkdir -p '$RITE_TEST_TMPDIR/.rite'

    PR_NUMBER=99
    ISSUE_NUMBER=49
    FILTERED_CONTENT='### Missing input validation - ACTIONABLE_LATER
Severity: MEDIUM
Defer Reason: Out of scope for current PR'

    $_followup_failure_block
  " 2>/dev/null || true

  # File must exist
  [ -f "$_orphaned_file" ]

  # File must contain the ACTIONABLE_LATER item
  grep -q "Missing input validation" "$_orphaned_file"
}

# ---------------------------------------------------------------------------
# Test 3: "All issues resolved or tracked" is NOT printed on failure
# ---------------------------------------------------------------------------

@test "assess-and-resolve: 'All issues resolved or tracked' NOT printed when creation fails" {
  run bash -c "
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_DATA_DIR='.rite'
    mkdir -p '$RITE_TEST_TMPDIR/.rite'

    print_error()   { echo \"ERROR: \$*\" >&2; }
    print_success() { echo \"SUCCESS: \$*\" >&2; }
    export -f print_error print_success

    PR_NUMBER=99
    ISSUE_NUMBER=49
    MERGE_EXIT_CODE=0
    FILTERED_CONTENT='### Validate inputs - ACTIONABLE_LATER
Severity: MEDIUM'

    $_followup_failure_block
    $_final_summary_block
  " 2>&1

  [ "$status" -eq 1 ]
  [[ "$output" != *"All issues resolved or tracked"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: actionable recovery message IS printed on failure
# ---------------------------------------------------------------------------

@test "assess-and-resolve: actionable recovery message printed on creation failure" {
  run bash -c "
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_DATA_DIR='.rite'
    mkdir -p '$RITE_TEST_TMPDIR/.rite'

    print_error()   { echo \"ERROR: \$*\" >&2; }
    print_success() { echo \"SUCCESS: \$*\" >&2; }
    export -f print_error print_success

    PR_NUMBER=99
    ISSUE_NUMBER=49
    MERGE_EXIT_CODE=0
    FILTERED_CONTENT='### Validate inputs - ACTIONABLE_LATER
Severity: MEDIUM'

    $_followup_failure_block
    $_final_summary_block
  " 2>&1

  [ "$status" -eq 1 ]
  # Must mention the orphaned file path
  [[ "$output" == *"orphaned-followup-items.md"* ]]
  # Must mention re-run instructions
  [[ "$output" == *"--assess-and-fix"* ]]
}

# ---------------------------------------------------------------------------
# Test 5 (structural): source code guards "ready to proceed" with
# _followup_creation_failed check
# ---------------------------------------------------------------------------

@test "structural: assess-and-resolve.sh checks _followup_creation_failed before success exit" {
  _src="${RITE_LIB_DIR}/core/assess-and-resolve.sh"

  # The guard must appear before the "All issues resolved" line
  _guard_line=$(grep -n '_followup_creation_failed.*true' "$_src" | tail -1 | cut -d: -f1)
  _success_line=$(grep -n 'All issues resolved or tracked' "$_src" | tail -1 | cut -d: -f1)

  [ -n "$_guard_line" ]
  [ -n "$_success_line" ]
  # Guard must come before the success message line
  [ "$_guard_line" -lt "$_success_line" ]
}

# ---------------------------------------------------------------------------
# Test 6 (structural): source code writes orphaned-followup-items.md on failure
# ---------------------------------------------------------------------------

@test "structural: assess-and-resolve.sh writes orphaned-followup-items.md on gh failure" {
  _src="${RITE_LIB_DIR}/core/assess-and-resolve.sh"

  # Must reference the orphaned file path
  grep -q 'orphaned-followup-items.md' "$_src"

  # Must set the failed flag in the else branch of gh issue create
  grep -q '_followup_creation_failed=true' "$_src"
}
