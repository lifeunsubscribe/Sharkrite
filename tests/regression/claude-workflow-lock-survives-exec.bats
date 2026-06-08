#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh, lib/utils/issue-lock.sh
# tests/regression/claude-workflow-lock-survives-exec.bats
#
# Regression test for: claude-workflow.sh leaks issue lock across exec (issue #421)
#
# Root cause: claude-workflow.sh execs itself to restart after stale-branch and
# empty-branch auto-recovery. `exec` replaces the process image WITHOUT firing
# EXIT traps, so the `trap "release_issue_lock ..." EXIT` registered after lock
# acquisition never fires. The re-exec'd process (same PID, $$) then attempts
# acquire_issue_lock, finds its own live lock, and fails with:
#   ❌ Issue #N is already being processed by PID X
#   ❌ Lock timeout after 30 seconds
#
# Live failure: issue #343, batch run rite-338-340-343-345-20260606-092031.log:1012
#
# Fix:
#   Option A: Explicit release_issue_lock "$ISSUE_NUMBER" before each exec call.
#   Option B: Defense-in-depth — acquire_issue_lock reclaims self-held locks
#             (lock_pid == $$) with a warning instead of timing out.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/$RITE_DATA_DIR/locks"

  mkdir -p "$RITE_LOCK_DIR"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Static checks: verify release_issue_lock immediately precedes each exec site
# that passes $ISSUE_NUMBER. The approach: for each exec line number, assert
# that release_issue_lock appears within the 5 lines before it (not just
# anywhere in the file — must be the immediately adjacent call).
# ---------------------------------------------------------------------------

# Helper: returns line numbers for a pattern in claude-workflow.sh
_exec_site_has_release_before() {
  local exec_pattern="$1"
  local workflow_file="${RITE_REPO_ROOT}/lib/core/claude-workflow.sh"

  # Find all exec lines matching the pattern
  local exec_lines
  exec_lines=$(grep -n "$exec_pattern" "$workflow_file" | grep -v '^[[:space:]]*#' | awk -F: '{print $1}')

  if [ -z "$exec_lines" ]; then
    echo "FAIL: no exec lines found matching: $exec_pattern" >&2
    return 1
  fi

  local all_ok=true
  local exec_line
  for exec_line in $exec_lines; do
    # Look in the 8 lines immediately before this exec for release_issue_lock
    local start_line=$(( exec_line - 8 ))
    [ $start_line -lt 1 ] && start_line=1
    local window
    window=$(sed -n "${start_line},${exec_line}p" "$workflow_file")
    if echo "$window" | grep -q 'release_issue_lock'; then
      echo "OK: exec at line $exec_line has release_issue_lock in preceding lines" >&2
    else
      echo "FAIL: exec at line $exec_line does NOT have release_issue_lock in preceding 8 lines" >&2
      all_ok=false
    fi
  done

  [ "$all_ok" = "true" ]
}

@test "static: all exec SCRIPT_PATH ISSUE_NUMBER --auto sites preceded by release_issue_lock" {
  # Covers: stale-branch auto restart (line ~1340) and empty-branch auto restart (line ~1369)
  run bash -c "
    $(declare -f _exec_site_has_release_before)
    _exec_site_has_release_before 'exec \"\\\$SCRIPT_PATH\" \"\\\$ISSUE_NUMBER\" --auto'
    echo 'PASS'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "static: exec SCRIPT_PATH ISSUE_NUMBER (no --auto) site preceded by release_issue_lock" {
  # Covers: stale-branch supervised restart (line ~1342) and supervised cleanup (line ~1401)
  # Note: line ~1342 is in the else branch after the auto release, so the same release call
  # at ~1338 precedes both. Line ~1401 has its own release at ~1400.
  run bash -c "
    $(declare -f _exec_site_has_release_before)
    _exec_site_has_release_before 'exec \"\\\$SCRIPT_PATH\" \"\\\$ISSUE_NUMBER\"[^[:space:]]'
    echo 'PASS'
  " 2>&1
  # This pattern is tricky — let's use a simpler approach
  local workflow_file="${RITE_REPO_ROOT}/lib/core/claude-workflow.sh"

  # Find lines with exec "$SCRIPT_PATH" "$ISSUE_NUMBER" but NOT --auto
  run bash -c "
    _workflow='${RITE_REPO_ROOT}/lib/core/claude-workflow.sh'
    _all_ok=true

    while IFS= read -r _entry; do
      _exec_line=\$(echo \"\$_entry\" | cut -d: -f1)
      # Skip if --auto is on the same line
      _exec_content=\$(echo \"\$_entry\" | cut -d: -f2-)
      echo \"\$_exec_content\" | grep -q -- '--auto' && continue

      # Check preceding 8 lines for release_issue_lock
      _start=\$(( _exec_line - 8 ))
      [ \$_start -lt 1 ] && _start=1
      _window=\$(sed -n \"\${_start},\${_exec_line}p\" \"\$_workflow\")
      if echo \"\$_window\" | grep -q 'release_issue_lock'; then
        echo \"OK: exec at line \$_exec_line has release_issue_lock nearby\" >&2
      else
        echo \"FAIL: exec at line \$_exec_line missing release_issue_lock\" >&2
        _all_ok=false
      fi
    done < <(grep -n 'exec \"\\\$SCRIPT_PATH\" \"\\\$ISSUE_NUMBER\"' \"\$_workflow\" | grep -v '^[[:space:]]*#')

    if [ \"\$_all_ok\" = true ]; then
      echo 'PASS: all exec ISSUE_NUMBER sites have release_issue_lock'
    else
      echo 'FAIL: some exec sites missing release_issue_lock'
      exit 1
    fi
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "static: no exec SCRIPT_PATH ISSUE_NUMBER site is missing release_issue_lock (combined)" {
  # Single comprehensive check: every exec "$SCRIPT_PATH" "$ISSUE_NUMBER" line (with or
  # without --auto) must have release_issue_lock in the 8 lines before it.
  run bash -c "
    _workflow='${RITE_REPO_ROOT}/lib/core/claude-workflow.sh'
    _all_ok=true
    _checked=0

    while IFS= read -r _entry; do
      _exec_line=\$(echo \"\$_entry\" | awk -F: '{print \$1}')
      _start=\$(( _exec_line - 8 ))
      [ \$_start -lt 1 ] && _start=1
      _window=\$(sed -n \"\${_start},\${_exec_line}p\" \"\$_workflow\")
      if echo \"\$_window\" | grep -q 'release_issue_lock'; then
        _checked=\$(( _checked + 1 ))
      else
        echo \"FAIL: exec at line \$_exec_line missing release_issue_lock in preceding 8 lines\" >&2
        _all_ok=false
      fi
    done < <(grep -n 'exec \"\\\$SCRIPT_PATH\" \"\\\$ISSUE_NUMBER\"' \"\$_workflow\" | grep -v '^[[:space:]]*#')

    if [ \"\$_all_ok\" = true ] && [ \$_checked -gt 0 ]; then
      echo \"PASS: all \$_checked exec sites have release_issue_lock\"
    elif [ \$_checked -eq 0 ]; then
      echo 'FAIL: no exec \$SCRIPT_PATH \$ISSUE_NUMBER sites found — pattern may have changed'
      exit 1
    else
      exit 1
    fi
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  # Should have found at least 3 exec sites (stale auto, empty auto, supervised cleanup)
  # The stale supervised is in else after the same release so also counted
  local count
  count=$(echo "$output" | grep -oE '[0-9]+ exec sites' | grep -oE '^[0-9]+')
  [ "${count:-0}" -ge 3 ]
}

# ---------------------------------------------------------------------------
# Functional: Option B — self-reclaim in acquire_issue_lock (defense-in-depth)
#
# Simulates the exec semantics: lock acquired → EXIT trap cleared (as exec does)
# → same process attempts re-acquire. Without Option B, this would block for
# 30 seconds and time out. With Option B, it reclaims immediately.
# ---------------------------------------------------------------------------

@test "acquire_issue_lock reclaims self-held lock (post-exec restart simulation)" {
  # Simulate exec semantics:
  # 1. Process acquires lock (PID = $$ written to pid file)
  # 2. Process execs itself — EXIT trap is cleared but PID is same
  # 3. Re-exec'd process tries to acquire the same lock
  # Expected: Option B reclaims the self-held lock with a warning, not a 30s timeout
  run bash -c "
    export RITE_PROJECT_ROOT='${RITE_TEST_TMPDIR}'
    export RITE_DATA_DIR='.rite'
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    # Skip grace period sleep for tests
    export _RITE_LOCK_GRACE_PERIOD_S=0

    source '${RITE_LIB_DIR}/utils/issue-lock.sh'

    # Step 1: Acquire lock (simulates first process incarnation)
    acquire_issue_lock 343 || { echo 'FAIL: first acquire failed'; exit 1; }

    # Verify lock is ours
    _lock_dir=\"\${RITE_LOCK_DIR}/issue-343.lock\"
    [ -f \"\$_lock_dir/pid\" ] || { echo 'FAIL: pid file missing after first acquire'; exit 1; }
    _pid=\$(cat \"\$_lock_dir/pid\")
    [ \"\$_pid\" = \"\$\$\" ] || { echo \"FAIL: pid mismatch: expected \$\$ got \$_pid\"; exit 1; }

    # Step 2: Simulate exec — do NOT release the lock (EXIT trap cleared by exec).
    # The lock dir stays with our PID written to it.
    # (No release_issue_lock call here — this is the broken pre-fix behavior)

    # Step 3: Re-acquire (as if we are the re-exec'd incarnation of the same process)
    # With Option B, this should reclaim our own lock and succeed.
    acquire_issue_lock 343 2>&1 || { echo 'FAIL: re-acquire after exec simulation failed (Option B not working)'; exit 1; }

    # Verify lock is ours again
    [ -f \"\$_lock_dir/pid\" ] || { echo 'FAIL: pid file missing after re-acquire'; exit 1; }
    _pid2=\$(cat \"\$_lock_dir/pid\")
    [ \"\$_pid2\" = \"\$\$\" ] || { echo \"FAIL: re-acquire pid mismatch: expected \$\$ got \$_pid2\"; exit 1; }

    release_issue_lock 343

    echo 'PASS: self-held lock reclaimed without 30s timeout'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: self-held lock reclaimed without 30s timeout"* ]]
  # Should have emitted the reclaim warning
  [[ "$output" == *"Reclaiming self-held lock"* ]]
}

@test "acquire_issue_lock self-reclaim emits warning (not silent)" {
  # Verify that the self-reclaim warning is printed to stderr so future debugging is easier.
  run bash -c "
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    export _RITE_LOCK_GRACE_PERIOD_S=0
    source '${RITE_LIB_DIR}/utils/issue-lock.sh'

    # Acquire and leave lock without releasing (simulate exec)
    acquire_issue_lock 344

    # Re-acquire — must emit self-reclaim warning (to stderr, captured via 2>&1)
    acquire_issue_lock 344 2>&1
    release_issue_lock 344
    echo 'done'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reclaiming self-held lock"* ]]
}

# ---------------------------------------------------------------------------
# Functional: Option A — explicit release before exec prevents self-lock collision
#
# Tests that the combination of release + re-acquire works cleanly without
# triggering any self-reclaim warning (the proper path).
# ---------------------------------------------------------------------------

@test "explicit release before exec allows clean re-acquire (Option A verification)" {
  # Simulates the corrected exec pattern:
  # 1. Acquire lock
  # 2. release_issue_lock explicitly (as added in the fix)
  # 3. Re-acquire succeeds cleanly (no self-reclaim warning, no timeout)
  run bash -c "
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    export _RITE_LOCK_GRACE_PERIOD_S=0
    source '${RITE_LIB_DIR}/utils/issue-lock.sh'

    # Step 1: Acquire lock (first incarnation)
    acquire_issue_lock 345 || { echo 'FAIL: first acquire failed'; exit 1; }

    # Step 2: Explicit release before exec (the Option A fix)
    release_issue_lock 345

    # Lock must be gone
    _lock_dir=\"\${RITE_LOCK_DIR}/issue-345.lock\"
    [ ! -d \"\$_lock_dir\" ] || { echo 'FAIL: lock dir still exists after explicit release'; exit 1; }

    # Step 3: Re-acquire (as if re-exec'd)
    acquire_issue_lock 345 2>&1 || { echo 'FAIL: re-acquire after explicit release failed'; exit 1; }

    # Lock must be held by us
    [ -f \"\$_lock_dir/pid\" ] || { echo 'FAIL: pid file missing after re-acquire'; exit 1; }
    _pid=\$(cat \"\$_lock_dir/pid\")
    [ \"\$_pid\" = \"\$\$\" ] || { echo \"FAIL: pid mismatch after re-acquire: expected \$\$ got \$_pid\"; exit 1; }

    release_issue_lock 345
    echo 'PASS: clean re-acquire after explicit release (no self-reclaim needed)'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: clean re-acquire after explicit release"* ]]
  # No self-reclaim warning should be emitted when Option A is followed
  ! [[ "$output" == *"Reclaiming self-held lock"* ]]
}

# ---------------------------------------------------------------------------
# Negative case: without Option B, self-lock collision causes the error
# (validates that the test correctly detects the bug)
# ---------------------------------------------------------------------------

@test "negative: without self-reclaim, same-PID re-acquire produces already-being-processed error" {
  # Manually simulate the pre-fix acquire behavior to verify the negative case.
  # We create a lock with our own PID and then call a modified acquire that does NOT
  # have Option B — it must hit the "already being processed" message.
  run bash -c "
    export RITE_LOCK_DIR='${RITE_LOCK_DIR}'
    export _RITE_LOCK_GRACE_PERIOD_S=0
    source '${RITE_LIB_DIR}/utils/issue-lock.sh'

    # Manually plant a lock with our own PID (simulates leaked exec lock)
    _lock_dir=\"\${RITE_LOCK_DIR}/issue-346.lock\"
    mkdir \"\$_lock_dir\"
    echo \$\$ > \"\$_lock_dir/pid\"

    # Now simulate pre-fix logic: a simple acquire loop that does NOT have the
    # self-reclaim branch. Use max_attempts=1 to fail fast rather than wait 30 seconds.
    _max=1
    _attempts=0
    _got_error=false
    while ! mkdir \"\$_lock_dir\" 2>/dev/null; do
      if [ -f \"\$_lock_dir/pid\" ]; then
        _pid=\$(cat \"\$_lock_dir/pid\" 2>/dev/null || echo '')
        # Without Option B: treat any live PID (including own) as blocking
        if [ -n \"\$_pid\" ] && kill -0 \"\$_pid\" 2>/dev/null; then
          if [ \$_attempts -eq 0 ]; then
            echo \"❌ Issue #346 is already being processed by PID \$_pid\"
            _got_error=true
          fi
        fi
      fi
      _attempts=\$(( _attempts + 1 ))
      [ \$_attempts -ge \$_max ] && break
    done

    # Clean up the planted lock
    rm -rf \"\$_lock_dir\"

    if [ \"\$_got_error\" = true ]; then
      echo 'CONFIRMED: without self-reclaim, same-PID lock collision produces blocking error'
    else
      echo 'UNEXPECTED: no error produced — test is invalid'
      exit 1
    fi
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"already being processed"* ]]
  [[ "$output" == *"CONFIRMED"* ]]
}
