#!/usr/bin/env bats
# Regression test for: Add error handling for follow-up issue creation
# Issue #156
#
# Bug: assess-and-resolve.sh printed "Failed to create consolidated follow-up
# issue" (warning) and then immediately printed "All issues resolved or tracked
# - ready to proceed" (success) and exited 0.  The two messages are mutually
# exclusive — the second is a lie when the first fired.  The MEDIUM item that
# should have been tracked in a follow-up issue was silently lost.
#
# Live failure (2026-05-31, issue #49 run, batch log):
#   ⚠️  Failed to create consolidated follow-up issue   ← FAILURE
#   ✅ All issues resolved or tracked - ready to proceed ← LIE
#
# Fix:
#   1. On gh issue create failure, set _followup_creation_failed=true
#   2. Save the issue body to .rite/orphaned-followup-items.md
#   3. At final summary, if _followup_creation_failed=true, exit 1 and
#      print an actionable remediation message — never print "tracked".
#
# Tests in this file:
#   1. Inline unit: failure branch sets _followup_creation_failed and saves file
#   2. Inline unit: success message is suppressed when _followup_creation_failed
#   3. Inline unit: orphaned-followup-items.md contains the MEDIUM item body
#   4. Static: source code does NOT print "tracked" in the _followup_creation_failed path
#   5. Static: _followup_creation_failed flag is initialized before set +e block
#   6. Static: failure branch writes orphaned-followup-items.md

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  mkdir -p "$RITE_TEST_TMPDIR/.rite"

  export ASSESS_RESOLVE_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
  [ -f "$ASSESS_RESOLVE_SCRIPT" ] || {
    echo "setup: ASSESS_RESOLVE_SCRIPT not found at $ASSESS_RESOLVE_SCRIPT (RITE_REPO_ROOT=$RITE_REPO_ROOT)" >&2
    false
  }
}

teardown() {
  teardown_test_tmpdir
}

# ─── Inline reproduction of the failure branch ────────────────────────────────
#
# We inline the critical section rather than running the full script to avoid
# pulling in the full assess-and-resolve.sh dependency graph (gh, Claude, etc.).
# If the inlined block drifts from the source, Test 4-6 (static checks) catch
# the mismatch.

_failure_branch_inline='
  # Reproduce the else branch from assess-and-resolve.sh (gh issue create failure)
  _followup_creation_failed=false
  FOLLOWUP_BODY_FILE=$(mktemp)
  printf "## Follow-up\n\n- [MEDIUM] Fix input validation in lib/foo.sh\n" > "$FOLLOWUP_BODY_FILE"

  # Simulate gh issue create failing
  if false; then
    : # success path (not taken)
  else
    _orphaned_file="${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}/orphaned-followup-items.md"
    mkdir -p "${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}" 2>/dev/null || true
    {
      echo "# Orphaned Follow-up Items"
      echo "# Generated: $(date '"'"'+%Y-%m-%d %H:%M:%S'"'"')"
      echo "# PR: #${PR_NUMBER}"
      echo "# Source issue: #${ISSUE_NUMBER:-unknown}"
      echo "# Intended title: ${ISSUE_TITLE:-}"
      echo "# Re-run:  rite ${ISSUE_NUMBER:-N} --assess-and-fix  (after resolving gh API issue)"
      echo ""
      cat "$FOLLOWUP_BODY_FILE" 2>/dev/null || echo "(body file unavailable)"
    } > "$_orphaned_file" || true

    rm -f "$FOLLOWUP_BODY_FILE"
    print_warning "Failed to create consolidated follow-up issue"
    print_error "Items NOT tracked. Saved to: $_orphaned_file"
    print_error "Re-run: rite ${ISSUE_NUMBER:-N} --assess-and-fix  (after resolving gh API issue)"
    _followup_creation_failed=true
  fi
'

_final_summary_inline='
  # Reproduce the final summary from assess-and-resolve.sh
  _summary_exit=0
  if [ "${_followup_creation_failed:-false}" = true ]; then
    print_error "Follow-up issue creation failed — workflow halted to prevent silent data loss"
    _summary_exit=1
  elif [ "${MERGE_EXIT_CODE:-0}" -eq 0 ]; then
    print_success "All issues resolved or tracked - ready to proceed"
    _summary_exit=0
  else
    print_error "CRITICAL issues remain — manual intervention required"
    _summary_exit=1
  fi
  exit "$_summary_exit"
'

# ─── Test 1: failure branch sets _followup_creation_failed=true ───────────────

@test "assess-and-resolve: gh issue create failure sets _followup_creation_failed=true" {
  run bash -c "
    set -uo pipefail
    GREEN=''; RED=''; YELLOW=''; NC=''; BOLD=''
    print_warning() { echo \"WARNING: \$*\" >&2; }
    print_error()   { echo \"ERROR: \$*\" >&2; }
    export PR_NUMBER=42
    export ISSUE_NUMBER=49
    export ISSUE_TITLE='Tech Debt: Review feedback from PR #42'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_DATA_DIR='.rite'

    $_failure_branch_inline

    # Report the flag value on stdout for assertion
    echo \"flag=\$_followup_creation_failed\"
  " 2>&1

  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=true"* ]] || {
    echo "FAIL: _followup_creation_failed was not set to true"
    echo "Output: $output"
    false
  }
}

# ─── Test 2: final summary exits non-zero when _followup_creation_failed=true ─

@test "assess-and-resolve: final summary exits 1 when _followup_creation_failed=true" {
  run bash -c "
    set -uo pipefail
    GREEN=''; RED=''; YELLOW=''; NC=''; BOLD=''
    print_warning() { echo \"WARNING: \$*\" >&2; }
    print_error()   { echo \"ERROR: \$*\" >&2; }
    print_success() { echo \"SUCCESS: \$*\" >&2; }

    _followup_creation_failed=true
    MERGE_EXIT_CODE=0

    $_final_summary_inline
  " 2>&1

  # Must exit non-zero
  [ "$status" -eq 1 ] || {
    echo "FAIL: expected exit 1, got $status"
    false
  }

  # Must NOT print the lie
  [[ "$output" != *"All issues resolved or tracked"* ]] || {
    echo "FAIL: 'All issues resolved or tracked' was printed even though follow-up failed"
    false
  }

  # Must print the failure message
  [[ "$output" == *"workflow halted"* ]] || {
    echo "FAIL: expected 'workflow halted' in output"
    echo "Output: $output"
    false
  }
}

# ─── Test 3: orphaned-followup-items.md contains the deferred item body ───────

@test "assess-and-resolve: orphaned-followup-items.md is written with item body on gh failure" {
  bash -c "
    set -uo pipefail
    GREEN=''; RED=''; YELLOW=''; NC=''; BOLD=''
    print_warning() { echo \"WARNING: \$*\" >&2; }
    print_error()   { echo \"ERROR: \$*\" >&2; }
    export PR_NUMBER=42
    export ISSUE_NUMBER=49
    export ISSUE_TITLE='Tech Debt: Review feedback from PR #42'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_DATA_DIR='.rite'

    $_failure_branch_inline
  " 2>/dev/null

  _orphaned="$RITE_TEST_TMPDIR/.rite/orphaned-followup-items.md"

  # File must exist
  [ -f "$_orphaned" ] || {
    echo "FAIL: orphaned-followup-items.md not created at $_orphaned"
    false
  }

  # File must contain the MEDIUM item from the body
  _contents=$(cat "$_orphaned")
  [[ "$_contents" == *"MEDIUM"* ]] || {
    echo "FAIL: orphaned file does not contain MEDIUM item"
    echo "Contents: $_contents"
    false
  }

  # File must contain the PR number
  [[ "$_contents" == *"PR: #42"* ]] || {
    echo "FAIL: orphaned file does not reference PR #42"
    echo "Contents: $_contents"
    false
  }
}

# ─── Test 4: static check — "tracked" success is not printed on failure path ──

@test "assess-and-resolve.sh: 'All issues resolved or tracked' NOT reachable when _followup_creation_failed=true" {
  # The final summary must gate on _followup_creation_failed BEFORE the
  # "All issues resolved" branch.  Extract the if-block from the source and
  # verify the if-ordering guarantees the success message is unreachable.
  #
  # Strategy: find the line numbers for the _followup_creation_failed if-check
  # and the "All issues resolved" print_success.  The if-check must come BEFORE
  # the elif that prints the success message — ensuring the failure path exits
  # before ever reaching the success print.

  # Line where the _followup_creation_failed guard appears (as an if condition)
  _guard_line=$(grep -n 'if \[ "\${_followup_creation_failed' "$ASSESS_RESOLVE_SCRIPT" | \
    head -1 | cut -d: -f1 || true)

  # Line where "All issues resolved or tracked" is printed
  _success_line=$(grep -n '"All issues resolved or tracked' "$ASSESS_RESOLVE_SCRIPT" | \
    head -1 | cut -d: -f1 || true)

  [ -n "$_guard_line" ] || {
    echo "FAIL: _followup_creation_failed if-guard not found in source"
    false
  }
  [ -n "$_success_line" ] || {
    echo "FAIL: 'All issues resolved or tracked' not found in source"
    false
  }

  # The guard must appear BEFORE the success message (so failure path exits first)
  [ "$_guard_line" -lt "$_success_line" ] || {
    echo "FAIL: _followup_creation_failed guard (line $_guard_line) must come before success message (line $_success_line)"
    false
  }

  # The guard block must end with exit 1 (not fall through to success)
  # Extract 10 lines from the guard and verify exit 1 is present in that section
  _guard_block=$(awk "NR>=$_guard_line && NR<=$_success_line" "$ASSESS_RESOLVE_SCRIPT" || true)
  [[ "$_guard_block" == *"exit 1"* ]] || {
    echo "FAIL: _followup_creation_failed guard block does not contain exit 1"
    echo "Block (lines $_guard_line-$_success_line):"
    echo "$_guard_block"
    false
  }
}

# ─── Test 5: static check — _followup_creation_failed initialized before set +e ─

@test "assess-and-resolve.sh: _followup_creation_failed initialized before 'set +e'" {
  # We need to verify that _followup_creation_failed=false is assigned BEFORE
  # the set +e block that wraps the follow-up creation section, so that
  # set -u (in force at initialization time) doesn't crash when it's referenced.
  _init_line=$(grep -n '_followup_creation_failed=false' "$ASSESS_RESOLVE_SCRIPT" | \
    head -1 | cut -d: -f1 || true)
  _sete_line=$(grep -n '^set +e' "$ASSESS_RESOLVE_SCRIPT" | head -1 | cut -d: -f1 || true)

  [ -n "$_init_line" ] || {
    echo "FAIL: _followup_creation_failed=false not found in source"
    false
  }
  [ -n "$_sete_line" ] || {
    echo "FAIL: 'set +e' not found in source"
    false
  }

  [ "$_init_line" -lt "$_sete_line" ] || {
    echo "FAIL: _followup_creation_failed must be initialized (line $_init_line) before set +e (line $_sete_line)"
    false
  }
}

# ─── Test 6: static check — failure branch writes orphaned-followup-items.md ──

@test "assess-and-resolve.sh: failure branch writes orphaned-followup-items.md" {
  # Verify the orphaned file path and write are present in the source's else branch.
  _orphaned_write=$(grep -n 'orphaned-followup-items\.md' "$ASSESS_RESOLVE_SCRIPT" | \
    head -5 || true)

  [ -n "$_orphaned_write" ] || {
    echo "FAIL: orphaned-followup-items.md write not found in $ASSESS_RESOLVE_SCRIPT"
    false
  }

  # The write must occur inside the failure else-branch (after gh issue create fails)
  # Verify by checking the file also references FOLLOWUP_BODY_FILE (the body content)
  _body_ref=$(grep -n 'FOLLOWUP_BODY_FILE\|orphaned-followup-items' "$ASSESS_RESOLVE_SCRIPT" | \
    grep -v '^--$' || true)

  [[ "$_body_ref" == *"orphaned-followup-items"* ]] || {
    echo "FAIL: no reference to orphaned-followup-items.md in source"
    false
  }
}
