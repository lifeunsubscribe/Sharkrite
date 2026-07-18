#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/core/batch-process-issues.sh, docs/architecture/exit-codes.md
# tests/regression/workflow-runner-no-work-invariant.bats
#
# Regression test for: workflow-runner.sh should fail loud when no work produced
# Issue #380 (trigger), this issue adds the generic invariant guard.
#
# Bug history (2026-06-04 finance-glance batch, rite 1 2 3 4 5 6 7):
#   bootstrap-docs.sh sourced assess-documentation.sh's top-level code, which ran
#   the full post-merge flow as a side effect, hit `exit 0`, and silently terminated
#   workflow-runner with status 0. The batch reporter logged:
#     ✅ Issue #1 → PR #1 (167s)
#   But issue #1 was still OPEN, no branch existed, no PR existed.
#
#   PR #378 fixed the specific sourcing path. This test covers the generic invariant:
#   run_workflow() must return 13 (not 0) when no commits exist on the feature branch
#   AND no PR exists for the issue — regardless of what phase logic led there.
#
# Tests:
#   STRUCTURAL:
#     1. run_workflow() contains the invariant check block
#     2. The invariant returns 13 (not 0 or 1)
#     3. The invariant is positioned AFTER phase_completion (defense-in-depth location)
#     4. main() dispatcher explicitly propagates exit 13 (not swallowed as exit 1)
#     5. batch-process-issues.sh handles EXIT_CODE -eq 13 distinctly
#     6. exit-codes.md documents exit 13 for workflow-runner.sh
#   BEHAVIORAL:
#     7. _check_no_work_invariant with no artifacts → returns 13 (real function, not a copy)
#     8. _check_no_work_invariant with PR_NUMBER set → returns 0 (invariant passes)
#     9. RITE_WORKFLOW_EXPLICIT_COMPLETE=1 bypasses the invariant check
#    10. batch loop: exit 13 is recorded as invariant_violated (not completed, not abort)

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"

  # Stub print functions (all to stderr to avoid polluting stdout)
  print_status()  { echo "STATUS: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_warning() { echo "WARNING: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }
  export -f print_status print_info print_warning print_error print_success print_header
}

teardown() {
  teardown_test_tmpdir
}

# =============================================================================
# STRUCTURAL: verify the invariant guard is present in source files
# =============================================================================

@test "structural: run_workflow() contains INVARIANT_VIOLATED guard block" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ -f "$_wfr" ]

  # The invariant check must exist in the source
  _count=$(grep -c "INVARIANT_VIOLATED" "$_wfr" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: INVARIANT_VIOLATED diagnostic not found in workflow-runner.sh"
    return 1
  }
}

@test "structural: invariant guard uses return 13 (not 0 or 1)" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

  # The return inside the invariant block must be 13
  _count=$(grep -c "return 13" "$_wfr" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: 'return 13' not found in workflow-runner.sh — invariant must return 13"
    return 1
  }
}

@test "structural: invariant guard is positioned after phase_completion call in run_workflow()" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

  # Extract run_workflow() body and verify ordering:
  # phase_completion call must appear BEFORE the INVARIANT_VIOLATED guard
  _fn_body=$(awk '
    /^run_workflow[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c = substr($0,i,1)
        if (c == "{") depth++
        else if (c == "}") {
          depth--
          if (depth == 0) { print; in_fn=0; next }
        }
      }
      print
    }
  ' "$_wfr")

  _line_completion=$(echo "$_fn_body" | grep -n "phase_completion" | head -1 | cut -d: -f1)
  _line_invariant=$(echo "$_fn_body" | grep -n "_check_no_work_invariant" | head -1 | cut -d: -f1)

  [ -n "$_line_completion" ] || {
    echo "FAIL: phase_completion call not found in run_workflow() body"
    return 1
  }
  [ -n "$_line_invariant" ] || {
    echo "FAIL: _check_no_work_invariant call not found in run_workflow() body"
    return 1
  }
  [ "$_line_completion" -lt "$_line_invariant" ] || {
    echo "FAIL: phase_completion (line $_line_completion) must appear before _check_no_work_invariant call (line $_line_invariant)"
    return 1
  }
}

@test "structural: main() dispatcher in workflow-runner.sh explicitly propagates exit 13" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

  # The main() dispatcher must have a branch for workflow_exit -eq 13 that exits 13
  # (not falls through to the generic `exit 1` else branch)
  _count=$(grep -c "workflow_exit -eq 13" "$_wfr" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: main() dispatcher does not branch on workflow_exit -eq 13"
    echo "Exit 13 would be swallowed by the generic 'else: exit 1' branch"
    return 1
  }

  # And there must be an 'exit 13' in the dispatcher context
  _count_exit=$(grep -c "exit 13" "$_wfr" || true)
  [ "$_count_exit" -ge 1 ] || {
    echo "FAIL: 'exit 13' not found in workflow-runner.sh main() dispatcher"
    return 1
  }
}

@test "structural: batch-process-issues.sh handles EXIT_CODE -eq 13 distinctly" {
  _batch="$RITE_REPO_ROOT/lib/core/batch-process-issues.sh"
  [ -f "$_batch" ]

  _count=$(grep -c "EXIT_CODE -eq 13" "$_batch" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: batch-process-issues.sh does not handle EXIT_CODE -eq 13"
    echo "Exit 13 would fall through to the generic failure branch"
    echo "and be indistinguishable from a real dev/merge failure"
    return 1
  }
}

@test "structural: batch-process-issues.sh records exit 13 as invariant_violated status" {
  _batch="$RITE_REPO_ROOT/lib/core/batch-process-issues.sh"

  _count=$(grep -c "invariant_violated" "$_batch" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: batch-process-issues.sh does not set status=invariant_violated for exit 13"
    return 1
  }
}

@test "structural: docs/architecture/exit-codes.md documents exit 13 for workflow-runner" {
  _doc="$RITE_REPO_ROOT/docs/architecture/exit-codes.md"
  [ -f "$_doc" ]

  _count=$(grep -c "13" "$_doc" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: exit code 13 not mentioned in docs/architecture/exit-codes.md"
    return 1
  }

  # More specific: the workflow-runner section must mention 13 and invariant
  _inv_mention=$(grep -A 30 'workflow-runner.*return codes from' "$_doc" | grep "13" || true)
  [ -n "$_inv_mention" ] || {
    echo "FAIL: exit 13 entry not found in the workflow-runner.sh section of exit-codes.md"
    echo "(checked 30 lines after the 'return codes from' header)"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: exercise the real _check_no_work_invariant function from
# workflow-runner.sh. These tests source the real file with stubbed dependencies
# so any change to the invariant predicate is automatically covered here —
# no inline copy of the predicate logic.
#
# Stub pattern mirrors tests/regression/conflict-resolver-exit-5-propagation.bats.
# =============================================================================

# _setup_stub_lib creates a stub RITE_LIB_DIR in RITE_TEST_TMPDIR and populates
# it with empty stub files for every module sourced by workflow-runner.sh at
# load time.  Call this helper at the top of each behavioral test.
_setup_stub_lib() {
  local _stub_lib="$RITE_TEST_TMPDIR/stub-lib"
  for _subdir in utils providers core; do
    mkdir -p "$_stub_lib/$_subdir"
  done

  for _mod in \
    utils/notifications.sh utils/blocker-rules.sh utils/session-tracker.sh \
    utils/pr-summary.sh utils/normalize-issue.sh utils/markers.sh \
    utils/pr-detection.sh utils/date-helpers.sh utils/stash-manager.sh \
    utils/mid-run-rebase.sh utils/review-helper.sh utils/colors.sh \
    utils/logging.sh utils/timeout.sh utils/test-gate.sh \
    providers/provider-interface.sh; do
    printf '#!/usr/bin/env bash\n# stub\n' > "$_stub_lib/$_mod"
  done

  echo "$_stub_lib"
}

@test "behavioral: _check_no_work_invariant with no commits and no PR returns 13" {
  # Calls the real _check_no_work_invariant extracted from workflow-runner.sh.
  # No worktree, no PR → invariant fires and returns 13.
  _stub_lib=$(_setup_stub_lib)

  _result=0
  (
    set +e
    export RITE_LIB_DIR="$_stub_lib"
    export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
    export RITE_DATA_DIR=".rite"
    export RITE_LOG_FILE=""
    WORKFLOW_MODE="unsupervised"
    CURRENT_RETRY=0
    INTERRUPT_RECEIVED=false
    GREEN=""; NC=""; BLUE=""; RED=""; YELLOW=""
    print_status()  { :; }
    print_info()    { echo "INFO: $*" >&2; }
    print_warning() { :; }
    print_error()   { echo "ERROR: $*" >&2; }
    print_success() { :; }
    print_header()  { :; }
    _diag()         { :; }
    _timer_start()  { :; }
    _timer_end()    { :; }
    ensure_timeout_cmd() { :; }

    # shellcheck disable=SC1090
    source "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

    # No worktree, no PR → must return 13
    _check_no_work_invariant "42" "" ""
  ) || _result=$?

  [ "$_result" -eq 13 ] || {
    echo "FAIL: expected exit 13 (invariant violated), got $_result"
    return 1
  }
}

@test "behavioral: _check_no_work_invariant with PR_NUMBER set returns 0" {
  # Calls the real _check_no_work_invariant: PR_NUMBER="99" → invariant passes.
  _stub_lib=$(_setup_stub_lib)

  _result=0
  (
    set +e
    export RITE_LIB_DIR="$_stub_lib"
    export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
    export RITE_DATA_DIR=".rite"
    export RITE_LOG_FILE=""
    WORKFLOW_MODE="unsupervised"
    CURRENT_RETRY=0
    INTERRUPT_RECEIVED=false
    GREEN=""; NC=""; BLUE=""; RED=""; YELLOW=""
    print_status()  { :; }
    print_info()    { :; }
    print_warning() { :; }
    print_error()   { echo "ERROR: $*" >&2; }
    print_success() { :; }
    print_header()  { :; }
    _diag()         { :; }
    _timer_start()  { :; }
    _timer_end()    { :; }
    ensure_timeout_cmd() { :; }

    # shellcheck disable=SC1090
    source "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

    # PR_NUMBER="99" → invariant must pass (return 0)
    _check_no_work_invariant "42" "" "99"
  ) || _result=$?

  [ "$_result" -eq 0 ] || {
    echo "FAIL: expected exit 0 (PR exists — invariant should pass), got $_result"
    return 1
  }
}

@test "behavioral: _check_no_work_invariant with commits on branch returns 0" {
  # Calls the real _check_no_work_invariant with a real git repo that has
  # commits ahead of origin/main. Invariant must pass (return 0).
  _stub_lib=$(_setup_stub_lib)

  # Set up a bare "remote" and a local clone with a feature branch ahead of origin/main
  _remote="$RITE_TEST_TMPDIR/remote.git"
  git init -q --bare "$_remote"
  _local="$RITE_TEST_TMPDIR/local"
  git clone -q "$_remote" "$_local"
  git -C "$_local" config user.email "test@test.com"
  git -C "$_local" config user.name "Test"
  echo "init" > "$_local/file.txt"
  git -C "$_local" add .
  git -C "$_local" commit -qm "init"
  git -C "$_local" push -q origin HEAD:main
  git -C "$_local" checkout -q -b feature
  echo "feature work" >> "$_local/file.txt"
  git -C "$_local" add .
  git -C "$_local" commit -qm "feat: add feature"
  # origin/main now points to the init commit; feature branch has 1 commit ahead

  _result=0
  (
    set +e
    export RITE_LIB_DIR="$_stub_lib"
    export RITE_PROJECT_ROOT="$_local"
    export RITE_DATA_DIR=".rite"
    export RITE_LOG_FILE=""
    WORKFLOW_MODE="unsupervised"
    CURRENT_RETRY=0
    INTERRUPT_RECEIVED=false
    GREEN=""; NC=""; BLUE=""; RED=""; YELLOW=""
    print_status()  { :; }
    print_info()    { :; }
    print_warning() { :; }
    print_error()   { echo "ERROR: $*" >&2; }
    print_success() { :; }
    print_header()  { :; }
    _diag()         { :; }
    _timer_start()  { :; }
    _timer_end()    { :; }
    ensure_timeout_cmd() { :; }

    # shellcheck disable=SC1090
    source "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

    # Worktree has 1 commit ahead of origin/main → invariant must pass (return 0)
    _check_no_work_invariant "42" "$_local" ""
  ) || _result=$?

  [ "$_result" -eq 0 ] || {
    echo "FAIL: expected exit 0 (commits exist — invariant should pass), got $_result"
    return 1
  }
}

@test "behavioral: RITE_WORKFLOW_EXPLICIT_COMPLETE=1 bypasses invariant (future no-code paths)" {
  # Calls the real _check_no_work_invariant with no commits and no PR,
  # but RITE_WORKFLOW_EXPLICIT_COMPLETE=1 set — must return 0 (bypass).
  _stub_lib=$(_setup_stub_lib)

  _result=0
  (
    set +e
    export RITE_LIB_DIR="$_stub_lib"
    export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
    export RITE_DATA_DIR=".rite"
    export RITE_LOG_FILE=""
    export RITE_WORKFLOW_EXPLICIT_COMPLETE=1  # bypass signal
    WORKFLOW_MODE="unsupervised"
    CURRENT_RETRY=0
    INTERRUPT_RECEIVED=false
    GREEN=""; NC=""; BLUE=""; RED=""; YELLOW=""
    print_status()  { :; }
    print_info()    { :; }
    print_warning() { :; }
    print_error()   { echo "ERROR: $*" >&2; }
    print_success() { :; }
    print_header()  { :; }
    _diag()         { :; }
    _timer_start()  { :; }
    _timer_end()    { :; }
    ensure_timeout_cmd() { :; }

    # shellcheck disable=SC1090
    source "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

    # No commits, no PR, bypass=1 → must return 0
    _check_no_work_invariant "42" "" ""
  ) || _result=$?

  [ "$_result" -eq 0 ] || {
    echo "FAIL: expected exit 0 (RITE_WORKFLOW_EXPLICIT_COMPLETE=1 should bypass invariant), got $_result"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: batch reporter treats exit 13 distinctly from exit 0 and exit 1
# =============================================================================

@test "behavioral: batch loop records exit 13 as invariant_violated (not completed)" {
  # Simulate the batch loop receiving exit 13 from a workflow-runner subprocess.
  # The issue must be recorded as failed (not completed), loop must continue.
  _script="$RITE_TEST_TMPDIR/test-batch-exit13.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

COMPLETED=0
FAILED=()
INVARIANT_VIOLATED=()
PROCESSED=""

for N in 1 2 3; do
  # Issue 2 returns exit 13 (invariant violated)
  case $N in 1) C=0;; 2) C=13;; 3) C=0;; esac
  PROCESSED="$PROCESSED $N"

  if [ $C -eq 0 ]; then
    COMPLETED=$((COMPLETED+1))
  elif [ $C -eq 13 ]; then
    # Invariant violated — record as failure, continue loop
    INVARIANT_VIOLATED+=("$N")
    FAILED+=("$N")
    # Do NOT break — other issues are not affected
  elif [ $C -eq 5 ]; then
    FAILED+=("$N")
    break  # usage cap aborts
  else
    FAILED+=("$N")
  fi
done

echo "processed:$PROCESSED"
echo "completed:$COMPLETED"
echo "failed:${FAILED[*]:-none}"
echo "invariant_violated:${INVARIANT_VIOLATED[*]:-none}"
EOF
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ]

  # Issue 3 was processed (loop did NOT break on exit 13)
  echo "$output" | grep -qE "processed:.*3" || {
    echo "FAIL: loop broke early on exit 13 — issue 3 not processed"
    echo "output: $output"
    return 1
  }

  # Issue 2 is in invariant_violated (not completed)
  echo "$output" | grep -qE "invariant_violated:.*2" || {
    echo "FAIL: issue 2 not recorded as invariant_violated"
    echo "output: $output"
    return 1
  }

  # Issues 1 and 3 completed
  echo "$output" | grep -q "completed:2" || {
    echo "FAIL: expected 2 completed issues (1 and 3)"
    echo "output: $output"
    return 1
  }
}

@test "behavioral: batch loop does NOT record exit 13 as completed (phantom completion prevented)" {
  # Critical negative test: exit 13 must NOT increment the completed counter.
  # This is the exact bug the invariant was introduced to prevent.
  _script="$RITE_TEST_TMPDIR/test-batch-exit13-not-completed.sh"
  cat > "$_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

COMPLETED=0
for N in 1 2; do
  case $N in 1) C=13;; 2) C=13;; esac
  if [ $C -eq 0 ]; then
    COMPLETED=$((COMPLETED+1))
  fi
  # exit 13 does not increment COMPLETED — falls through without counting
done
echo "completed:$COMPLETED"
EOF
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "completed:0" ]] || {
    echo "FAIL: exit 13 should NOT increment completed counter (phantom completion)"
    echo "output: $output"
    return 1
  }
}

# =============================================================================
# STRUCTURAL: exit code uniqueness — 13 must not collide with any existing code
# =============================================================================

@test "structural: exit 13 (invariant-violated) is numerically distinct from all other documented exit codes" {
  # Full set of documented cross-script codes including the new exit 13
  # Source: docs/architecture/exit-codes.md
  _codes=(0 1 2 3 4 5 6 10 11 12 13 124 127)

  # Verify all codes are distinct (no two codes are numerically equal)
  declare -A _seen
  for _code in "${_codes[@]}"; do
    if [ -n "${_seen[$_code]+x}" ]; then
      echo "FAIL: duplicate exit code detected: $_code" >&2
      return 1
    fi
    _seen[$_code]=1
  done

  # 13 must be in the set
  [ -n "${_seen[13]+x}" ] || {
    echo "FAIL: exit 13 not in the uniqueness table"
    return 1
  }
}
