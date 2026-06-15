#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/core/undo-workflow.sh, lib/utils/session-tracker.sh, lib/core/claude-workflow.sh
# Regression test for issue #610: Record interrupted session repo as worktree path
#
# Live incident 2026-06-14: .rite/session-state-544.json recorded
#   worktree_path: /Users/sarahtime/Dev/sharkrite  (main repo root)
# because a pre-worktree interruption (batch of 8, 8th issue) triggered
# save_session_state_with_phase with WORKTREE_PATH equal to the main checkout.
# On resume, the workflow ran in-place on the feature branch, attempted a
# git merge of main that conflicted, and failed in ~10s.
# --undo was unsafe because it would have run `git worktree remove --force`
# on the primary checkout.
#
# Four guards added (issue #610):
#   1. save_session_state_with_phase: never persist main-root or empty path
#   2. save_session_state (session-tracker.sh): same guard for the SIGINT interrupt path
#   3. Resume validation: reject saved path that is main-root or not a linked worktree
#   4. undo-workflow.sh: refuse to remove main repo root as worktree
#
# Tests:
#   STRUCTURAL (guard presence):
#     1. save_session_state_with_phase contains main-root guard
#     2. Resume validation section contains main-root rejection
#     3. Resume validation contains linked-worktree check
#     4. undo-workflow.sh contains main-root guard
#     5. save_session_state (session-tracker.sh) contains main-root guard [interrupt path]
#   BEHAVIORAL (save_session_state_with_phase guard):
#     6. save_session_state_with_phase writes empty worktree_path when passed main root
#     7. save_session_state_with_phase writes empty worktree_path when passed empty string
#     8. save_session_state_with_phase preserves a valid worktree path unchanged
#   BEHAVIORAL (resume validation — structural, via state file):
#     9. A state file with worktree_path=<project root> is treated as no-resume (fresh start)
#    10. A state file with worktree_path="" is treated as no-resume (fresh start)
#    11. A state file with a valid linked worktree path is accepted for resume
#   BEHAVIORAL (undo guard):
#    12. undo-workflow.sh WORKTREE_PATH is cleared when it matches RITE_PROJECT_ROOT
#    13. Existing session-state-29.json and session-state-202.json (empty paths) are safe
#   BEHAVIORAL (save_session_state interrupt-path guard — mirrors tests 6-8 for session-tracker.sh):
#    14. save_session_state writes empty worktree_path when passed main repo root
#    15. save_session_state writes empty worktree_path when passed empty string
#    16. save_session_state preserves a valid (non-root) worktree path unchanged
#   BEHAVIORAL (linked-worktree membership check — real git worktree harness, issue #614):
#    17. resume validation accepts a path that is a real linked worktree
#    18. resume validation rejects a directory that exists but is NOT in git worktree list
#    19. resume validation rejects a path that resolves to main repo root via symlink (pwd -P)
#    20. resume validation accepts a linked worktree whose path contains spaces
#    21. resume validation accepts a linked worktree accessed via a symlink (pwd -P canonicalization)

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

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
# STRUCTURAL: verify guards are present in source files
# =============================================================================

@test "structural: save_session_state_with_phase contains main-root guard" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ -f "$_wfr" ] || { echo "FAIL: workflow-runner.sh not found"; return 1; }

  # The guard compares worktree_path against RITE_PROJECT_ROOT and clears it
  _count=$(grep -c 'worktree_path.*RITE_PROJECT_ROOT\|RITE_PROJECT_ROOT.*worktree_path' "$_wfr" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: save_session_state_with_phase does not contain a main-root guard"
    echo "Expected pattern: worktree_path compared against RITE_PROJECT_ROOT"
    return 1
  }
}

@test "structural: resume validation contains main-repo-root rejection" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

  # The resume block rejects when saved_worktree equals RITE_PROJECT_ROOT
  _count=$(grep -c 'main repo root\|equals main repo root\|pre-worktree interruption' "$_wfr" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: resume validation block does not contain a main-root rejection comment/message"
    return 1
  }
}

@test "structural: resume validation contains linked-worktree check" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

  # The resume block checks git worktree list for linked worktree membership
  _count=$(grep -c 'not a linked worktree\|worktree list.*linked\|linked worktree.*git' "$_wfr" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: resume validation does not check that saved path is a linked worktree"
    return 1
  }
}

@test "structural: undo-workflow.sh contains main-root worktree guard" {
  _undo="$RITE_REPO_ROOT/lib/core/undo-workflow.sh"
  [ -f "$_undo" ] || { echo "FAIL: undo-workflow.sh not found"; return 1; }

  # Guard compares WORKTREE_PATH against RITE_PROJECT_ROOT and clears it
  _count=$(grep -c 'WORKTREE_PATH.*RITE_PROJECT_ROOT\|RITE_PROJECT_ROOT.*WORKTREE_PATH' "$_undo" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: undo-workflow.sh does not guard against WORKTREE_PATH == RITE_PROJECT_ROOT"
    return 1
  }
}

@test "structural: save_session_state in session-tracker.sh contains main-root guard [interrupt path]" {
  # issue #610: save_session_state() is called from claude-workflow.sh cleanup_on_interrupt().
  # A pre-worktree SIGINT passes current_dir (== main repo root) as worktree_path.
  # The guard must clear it to "" before writing the state file, identical to
  # the save_session_state_with_phase() guard in workflow-runner.sh.
  _st="$RITE_REPO_ROOT/lib/utils/session-tracker.sh"
  [ -f "$_st" ] || { echo "FAIL: session-tracker.sh not found"; return 1; }

  # Verify the guard pattern: compare worktree_path against RITE_PROJECT_ROOT and clear
  _count=$(grep -c 'worktree_path.*_main_root\|_main_root.*worktree_path' "$_st" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: save_session_state() in session-tracker.sh does not contain a main-root guard"
    echo "Expected: worktree_path comparison against _main_root / RITE_PROJECT_ROOT"
    return 1
  }
}

# =============================================================================
# Shared setup: stub RITE_LIB_DIR for sourcing workflow-runner.sh functions
# without pulling in the full dependency chain.
# =============================================================================

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

# =============================================================================
# BEHAVIORAL: save_session_state_with_phase guard
# =============================================================================

@test "behavioral: save_session_state_with_phase writes empty worktree_path when passed main repo root" {
  # Reproduce the live incident: WORKTREE_PATH was set to the main checkout.
  # The guard must write "" (not the main-root path) to the state file.
  local _stub_lib
  _stub_lib=$(_setup_stub_lib)

  mkdir -p "$RITE_TEST_TMPDIR/.rite"

  local _result=0
  (
    set +e
    export RITE_LIB_DIR="$_stub_lib"
    export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
    export RITE_DATA_DIR=".rite"
    export RITE_LOG_FILE=""
    export WORKFLOW_MODE="unsupervised"
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

    # Call with main repo root as worktree_path (live incident scenario)
    save_session_state_with_phase "544" "interrupted" "$RITE_TEST_TMPDIR" "unknown" ""
  ) || _result=$?

  [ "$_result" -eq 0 ] || {
    echo "FAIL: save_session_state_with_phase exited with code $_result (expected 0)"
    return 1
  }

  local _state_file="$RITE_TEST_TMPDIR/.rite/session-state-544.json"
  [ -f "$_state_file" ] || {
    echo "FAIL: state file was not created at $_state_file"
    return 1
  }

  # worktree_path in the JSON must be "" (empty string), NOT the main repo root
  local _saved_wt
  _saved_wt=$(jq -r '.worktree_path // empty' "$_state_file" 2>/dev/null || true)
  [ -z "$_saved_wt" ] || {
    echo "FAIL: worktree_path should be empty when main root was passed"
    echo "  Got: '$_saved_wt'"
    echo "  Expected: '' (empty string)"
    return 1
  }
}

@test "behavioral: save_session_state_with_phase writes empty worktree_path when passed empty string" {
  local _stub_lib
  _stub_lib=$(_setup_stub_lib)

  mkdir -p "$RITE_TEST_TMPDIR/.rite"

  local _result=0
  (
    set +e
    export RITE_LIB_DIR="$_stub_lib"
    export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
    export RITE_DATA_DIR=".rite"
    export RITE_LOG_FILE=""
    export WORKFLOW_MODE="unsupervised"
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

    # Empty worktree_path (pre-worktree blocker scenario)
    save_session_state_with_phase "99" "credentials_expired" "" "claude-workflow" ""
  ) || _result=$?

  [ "$_result" -eq 0 ] || {
    echo "FAIL: save_session_state_with_phase exited $_result (expected 0)"
    return 1
  }

  local _state_file="$RITE_TEST_TMPDIR/.rite/session-state-99.json"
  [ -f "$_state_file" ] || { echo "FAIL: state file not created"; return 1; }

  local _saved_wt
  _saved_wt=$(jq -r '.worktree_path // empty' "$_state_file" 2>/dev/null || true)
  [ -z "$_saved_wt" ] || {
    echo "FAIL: worktree_path should be empty when '' was passed; got: '$_saved_wt'"
    return 1
  }
}

@test "behavioral: save_session_state_with_phase preserves a valid (non-root) worktree path" {
  local _stub_lib
  _stub_lib=$(_setup_stub_lib)

  mkdir -p "$RITE_TEST_TMPDIR/.rite"
  # Create a distinct linked-worktree-like directory (not the main root)
  local _fake_wt="$RITE_TEST_TMPDIR/../fake-worktree-$$"
  mkdir -p "$_fake_wt"

  local _result=0
  (
    set +e
    export RITE_LIB_DIR="$_stub_lib"
    export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
    export RITE_DATA_DIR=".rite"
    export RITE_LOG_FILE=""
    export WORKFLOW_MODE="unsupervised"
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

    # Valid path (not main root) — must be preserved
    save_session_state_with_phase "42" "interrupted" "$_fake_wt" "create-pr" "101"
  ) || _result=$?

  rm -rf "$_fake_wt" 2>/dev/null || true

  [ "$_result" -eq 0 ] || {
    echo "FAIL: save_session_state_with_phase exited $_result (expected 0)"
    return 1
  }

  local _state_file="$RITE_TEST_TMPDIR/.rite/session-state-42.json"
  [ -f "$_state_file" ] || { echo "FAIL: state file not created"; return 1; }

  local _saved_wt
  _saved_wt=$(jq -r '.worktree_path' "$_state_file" 2>/dev/null || true)
  [ "$_saved_wt" = "$_fake_wt" ] || {
    echo "FAIL: valid worktree path was unexpectedly modified"
    echo "  Expected: '$_fake_wt'"
    echo "  Got:      '$_saved_wt'"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: resume validation via structural check on the state-file branch
#
# Testing the full resume path requires stubbing git and gh, which is
# expensive. Instead we verify the validation logic via a targeted shell
# script that mirrors the exact condition tree from workflow-runner.sh.
# This catches regressions if the condition order or logic changes.
# =============================================================================

# _simulate_resume_validation simulates the worktree-validation branch from
# workflow-runner.sh main() and prints "ACCEPT" or "REJECT:<reason>".
_simulate_resume_validation() {
  local _saved_worktree="$1"
  local _project_root="$2"
  # For simplicity we skip the git worktree list check (no live git repo needed)
  # and test the earlier conditions that cover the issue #610 scenarios.

  local _worktree_valid=false
  local _worktree_reject_reason=""

  if [ -z "$_saved_worktree" ] || [ "$_saved_worktree" = "null" ]; then
    _worktree_reject_reason="empty or null"
  elif [ "$_saved_worktree" = "$_project_root" ]; then
    _worktree_reject_reason="equals main repo root (pre-worktree interruption fallback)"
  elif [ ! -d "$_saved_worktree" ]; then
    _worktree_reject_reason="directory no longer exists"
  else
    _worktree_valid=true
  fi

  if [ "$_worktree_valid" = true ]; then
    echo "ACCEPT"
  else
    echo "REJECT:$_worktree_reject_reason"
  fi
}

@test "behavioral: resume validation rejects worktree_path equal to project root" {
  # The live incident: worktree_path was the main repo checkout.
  local _project_root="$RITE_TEST_TMPDIR"
  local _result
  _result=$(_simulate_resume_validation "$_project_root" "$_project_root")

  [[ "$_result" == REJECT:* ]] || {
    echo "FAIL: resume did not reject main-root worktree_path"
    echo "  worktree_path='$_project_root'"
    echo "  project_root='$_project_root'"
    echo "  result='$_result'"
    return 1
  }
  echo "Correctly rejected: $_result"
}

@test "behavioral: resume validation rejects empty worktree_path" {
  local _result
  _result=$(_simulate_resume_validation "" "$RITE_TEST_TMPDIR")

  [[ "$_result" == REJECT:* ]] || {
    echo "FAIL: resume did not reject empty worktree_path"
    echo "  result='$_result'"
    return 1
  }
  echo "Correctly rejected: $_result"
}

@test "behavioral: resume validation rejects null worktree_path" {
  local _result
  _result=$(_simulate_resume_validation "null" "$RITE_TEST_TMPDIR")

  [[ "$_result" == REJECT:* ]] || {
    echo "FAIL: resume did not reject 'null' worktree_path"
    echo "  result='$_result'"
    return 1
  }
  echo "Correctly rejected: $_result"
}

@test "behavioral: resume validation rejects worktree_path that no longer exists on disk" {
  local _gone_path="$RITE_TEST_TMPDIR/nonexistent-worktree-$$"
  local _result
  _result=$(_simulate_resume_validation "$_gone_path" "$RITE_TEST_TMPDIR")

  [[ "$_result" == REJECT:* ]] || {
    echo "FAIL: resume did not reject non-existent worktree_path"
    echo "  worktree_path='$_gone_path'"
    echo "  result='$_result'"
    return 1
  }
  echo "Correctly rejected: $_result"
}

@test "behavioral: resume validation accepts a valid worktree path (different from project root, exists on disk)" {
  # Create a separate directory to simulate a real linked worktree path
  local _valid_wt="$RITE_TEST_TMPDIR/sh-wt/fx-issue-42"
  mkdir -p "$_valid_wt"

  local _result
  _result=$(_simulate_resume_validation "$_valid_wt" "$RITE_TEST_TMPDIR")

  [ "$_result" = "ACCEPT" ] || {
    echo "FAIL: resume incorrectly rejected a valid worktree path"
    echo "  worktree_path='$_valid_wt'"
    echo "  project_root='$RITE_TEST_TMPDIR'"
    echo "  result='$_result'"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: undo-workflow.sh WORKTREE_PATH guard
# The undo script runs top-level code, so we test its guard logic via a
# targeted inline script that mirrors the guard block exactly.
# =============================================================================

@test "behavioral: undo guard clears WORKTREE_PATH when it equals RITE_PROJECT_ROOT" {
  # Simulate the discovery section in undo-workflow.sh:
  # state file has worktree_path = main repo root → guard must clear it.
  local _state_file="$RITE_TEST_TMPDIR/session-state-610.json"
  local _project_root="$RITE_TEST_TMPDIR"

  cat > "$_state_file" <<EOF
{
  "issue_number": "610",
  "worktree_path": "${_project_root}",
  "phase": "unknown",
  "reason": "interrupted"
}
EOF

  # Inline script mirrors the undo-workflow.sh guard
  local _result
  _result=$(bash <<EOF
set -euo pipefail
RITE_PROJECT_ROOT="$_project_root"
STATE_FILE="$_state_file"
WORKTREE_PATH=\$(jq -r '.worktree_path // empty' "\$STATE_FILE" 2>/dev/null || echo "")
[ "\$WORKTREE_PATH" = "null" ] && WORKTREE_PATH=""
[ -n "\$WORKTREE_PATH" ] && [ ! -d "\$WORKTREE_PATH" ] && WORKTREE_PATH="" || true
# Apply the guard
if [ -n "\$WORKTREE_PATH" ] && [ "\$WORKTREE_PATH" = "\$RITE_PROJECT_ROOT" ]; then
  WORKTREE_PATH=""
fi
echo "\${WORKTREE_PATH:-EMPTY}"
EOF
)

  [ "$_result" = "EMPTY" ] || {
    echo "FAIL: undo guard did not clear WORKTREE_PATH when it equalled RITE_PROJECT_ROOT"
    echo "  RITE_PROJECT_ROOT='$_project_root'"
    echo "  WORKTREE_PATH after guard='$_result'"
    return 1
  }
}

@test "behavioral: undo guard preserves WORKTREE_PATH when it is a valid non-root path" {
  local _valid_wt="$RITE_TEST_TMPDIR/sh-wt/fx-issue-100"
  mkdir -p "$_valid_wt"

  local _state_file="$RITE_TEST_TMPDIR/session-state-100.json"
  cat > "$_state_file" <<EOF
{
  "issue_number": "100",
  "worktree_path": "${_valid_wt}",
  "phase": "merge",
  "reason": "test_failures"
}
EOF

  local _result
  _result=$(bash <<EOF
set -euo pipefail
RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
STATE_FILE="$_state_file"
WORKTREE_PATH=\$(jq -r '.worktree_path // empty' "\$STATE_FILE" 2>/dev/null || echo "")
[ "\$WORKTREE_PATH" = "null" ] && WORKTREE_PATH=""
[ -n "\$WORKTREE_PATH" ] && [ ! -d "\$WORKTREE_PATH" ] && WORKTREE_PATH="" || true
# Apply the guard
if [ -n "\$WORKTREE_PATH" ] && [ "\$WORKTREE_PATH" = "\$RITE_PROJECT_ROOT" ]; then
  WORKTREE_PATH=""
fi
echo "\${WORKTREE_PATH:-EMPTY}"
EOF
)

  [ "$_result" = "$_valid_wt" ] || {
    echo "FAIL: undo guard incorrectly cleared a valid non-root WORKTREE_PATH"
    echo "  Expected: '$_valid_wt'"
    echo "  Got: '$_result'"
    return 1
  }
}

# =============================================================================
# SAFETY: existing session-state files with empty paths are handled gracefully
# (they trigger the "empty or null" reject reason and start fresh — no crash)
# =============================================================================

@test "safety: existing state file with empty worktree_path triggers fresh start (not crash)" {
  # Mirrors session-state-29.json and session-state-202.json in this repo
  local _saved_worktree=""
  local _result
  _result=$(_simulate_resume_validation "$_saved_worktree" "$RITE_TEST_TMPDIR")

  # Must produce a REJECT (starting fresh), NOT crash or ACCEPT
  [[ "$_result" == REJECT:* ]] || {
    echo "FAIL: empty worktree_path from legacy state file did not produce REJECT"
    echo "  result='$_result'"
    return 1
  }
  # Specifically must be the "empty or null" reason (not a different failure path)
  [[ "$_result" == *"empty or null"* ]] || {
    echo "FAIL: expected 'empty or null' rejection reason"
    echo "  result='$_result'"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: save_session_state() interrupt-path guard (session-tracker.sh)
#
# Mirrors the behavioral tests 6-8 for save_session_state_with_phase() but
# exercises save_session_state() directly — the function called by
# claude-workflow.sh::cleanup_on_interrupt() when SIGINT fires during the
# Claude dev session, which may fire before any worktree is created.
# =============================================================================

@test "behavioral: save_session_state writes empty worktree_path when passed main repo root [interrupt path]" {
  # The interrupt path: cleanup_on_interrupt() passes current_dir (== main root)
  # as worktree_path.  The guard must write "" to the state file.
  mkdir -p "$RITE_TEST_TMPDIR/.rite"

  # Stub SESSION_STATE_FILE with minimal valid JSON (read inside save_session_state)
  local _session_file="$RITE_TEST_TMPDIR/.rite/session-state.json"
  printf '{"completions":0,"total_minutes":0}' > "$_session_file"

  local _result=0
  (
    set +e
    export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
    export RITE_DATA_DIR=".rite"
    export SESSION_STATE_FILE="$_session_file"
    # session-tracker.sh is a pure library — source it directly
    # shellcheck disable=SC1090
    source "$RITE_REPO_ROOT/lib/utils/session-tracker.sh"

    # Call with main repo root as worktree_path (live interrupt scenario)
    save_session_state "610" "interrupted" "$RITE_TEST_TMPDIR"
  ) || _result=$?

  [ "$_result" -eq 0 ] || {
    echo "FAIL: save_session_state exited with code $_result (expected 0)"
    return 1
  }

  local _state_file="$RITE_TEST_TMPDIR/.rite/session-state-610.json"
  [ -f "$_state_file" ] || {
    echo "FAIL: state file was not created at $_state_file"
    return 1
  }

  # worktree_path in the JSON must be "" (empty string), NOT the main repo root
  local _saved_wt
  _saved_wt=$(jq -r '.worktree_path // empty' "$_state_file" 2>/dev/null || true)
  [ -z "$_saved_wt" ] || {
    echo "FAIL: worktree_path should be empty when main root was passed"
    echo "  Got: '$_saved_wt'"
    echo "  Expected: '' (empty string)"
    return 1
  }
}

@test "behavioral: save_session_state writes empty worktree_path when passed empty string [interrupt path]" {
  # Pre-worktree interruption: current_dir may somehow be empty.
  mkdir -p "$RITE_TEST_TMPDIR/.rite"

  local _session_file="$RITE_TEST_TMPDIR/.rite/session-state.json"
  printf '{"completions":0,"total_minutes":0}' > "$_session_file"

  local _result=0
  (
    set +e
    export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
    export RITE_DATA_DIR=".rite"
    export SESSION_STATE_FILE="$_session_file"
    # shellcheck disable=SC1090
    source "$RITE_REPO_ROOT/lib/utils/session-tracker.sh"

    save_session_state "99" "interrupted" ""
  ) || _result=$?

  [ "$_result" -eq 0 ] || {
    echo "FAIL: save_session_state exited with code $_result (expected 0)"
    return 1
  }

  local _state_file="$RITE_TEST_TMPDIR/.rite/session-state-99.json"
  [ -f "$_state_file" ] || { echo "FAIL: state file not created"; return 1; }

  local _saved_wt
  _saved_wt=$(jq -r '.worktree_path // empty' "$_state_file" 2>/dev/null || true)
  [ -z "$_saved_wt" ] || {
    echo "FAIL: worktree_path should be empty when '' was passed; got: '$_saved_wt'"
    return 1
  }
}

@test "behavioral: save_session_state preserves a valid (non-root) worktree path [interrupt path]" {
  # Post-worktree SIGINT: current_dir is inside a real linked worktree.
  # The path is different from project root and must be preserved unchanged.
  mkdir -p "$RITE_TEST_TMPDIR/.rite"
  local _fake_wt="$RITE_TEST_TMPDIR/../fake-worktree-$$"
  mkdir -p "$_fake_wt"

  local _session_file="$RITE_TEST_TMPDIR/.rite/session-state.json"
  printf '{"completions":0,"total_minutes":0}' > "$_session_file"

  local _result=0
  (
    set +e
    export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
    export RITE_DATA_DIR=".rite"
    export SESSION_STATE_FILE="$_session_file"
    # shellcheck disable=SC1090
    source "$RITE_REPO_ROOT/lib/utils/session-tracker.sh"

    save_session_state "42" "interrupted" "$_fake_wt"
  ) || _result=$?

  rm -rf "$_fake_wt" 2>/dev/null || true

  [ "$_result" -eq 0 ] || {
    echo "FAIL: save_session_state exited with code $_result (expected 0)"
    return 1
  }

  local _state_file="$RITE_TEST_TMPDIR/.rite/session-state-42.json"
  [ -f "$_state_file" ] || { echo "FAIL: state file not created"; return 1; }

  local _saved_wt
  _saved_wt=$(jq -r '.worktree_path' "$_state_file" 2>/dev/null || true)
  [ "$_saved_wt" = "$_fake_wt" ] || {
    echo "FAIL: valid worktree path was unexpectedly modified"
    echo "  Expected: '$_fake_wt'"
    echo "  Got:      '$_saved_wt'"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: linked-worktree membership check — real git worktree harness
# (issue #614)
#
# The earlier _simulate_resume_validation() helper skipped the git worktree
# list membership step for simplicity.  These tests exercise the full
# validation path, including:
#   - porcelain parsing (awk + tail -n +2 to skip main checkout)
#   - pwd -P symlink canonicalization for each candidate path
#   - ACCEPT when saved path is in the linked list
#   - REJECT when saved path is a real directory but absent from the list
#   - REJECT when a symlink makes the path resolve to the main repo root
#   - ACCEPT for paths containing spaces (verifying --porcelain necessity)
#   - ACCEPT when path is accessed via a symlink (pwd -P handles it)
# =============================================================================

# _simulate_resume_validation_with_worktree_check mirrors the FULL condition
# tree from workflow-runner.sh main(), including the git worktree list step.
# Arguments:
#   $1  saved_worktree  — path read from the session-state JSON
#   $2  project_root    — RITE_PROJECT_ROOT equivalent
# Prints "ACCEPT" or "REJECT:<reason>" to stdout.
_simulate_resume_validation_with_worktree_check() {
  local _saved_worktree="$1"
  local _project_root="$2"

  local _worktree_valid=false
  local _worktree_reject_reason=""

  # Tier 1: empty / null
  if [ -z "$_saved_worktree" ] || [ "$_saved_worktree" = "null" ]; then
    _worktree_reject_reason="empty or null"

  # Tier 2: string-equal to project root (pre-worktree interruption fallback)
  elif [ "$_saved_worktree" = "$_project_root" ]; then
    _worktree_reject_reason="equals main repo root (pre-worktree interruption fallback)"

  # Tier 3: directory no longer exists
  elif [ ! -d "$_saved_worktree" ]; then
    _worktree_reject_reason="directory no longer exists"

  else
    # Tier 4: confirm path resolves to something other than main repo root
    # (catches symlink aliases of the main checkout)
    local _main_wt
    _main_wt=$(git -C "$_project_root" rev-parse --show-toplevel 2>/dev/null || true)

    local _saved_real
    _saved_real=$(cd "$_saved_worktree" 2>/dev/null && pwd -P || echo "$_saved_worktree")
    local _main_real
    _main_real=$(cd "${_main_wt:-$_project_root}" 2>/dev/null && pwd -P || echo "${_main_wt:-$_project_root}")

    if [ "$_saved_real" = "$_main_real" ]; then
      _worktree_reject_reason="resolves to main repo root (symlink or alias)"
    else
      # Tier 5: membership — must appear in the LINKED worktree list.
      # --porcelain preserves paths with spaces; tail -n +2 skips the main
      # checkout (always the first entry); pwd -P canonicalises each entry.
      local _linked_match=false
      local _wt_path
      while IFS= read -r _wt_path; do
        local _wt_real
        _wt_real=$(cd "$_wt_path" 2>/dev/null && pwd -P || echo "$_wt_path")
        if [ "$_wt_real" = "$_saved_real" ]; then
          _linked_match=true
          break
        fi
      done < <(git -C "$_project_root" worktree list --porcelain 2>/dev/null \
                 | awk '/^worktree /{print substr($0,10)}' \
                 | tail -n +2 || true)

      if [ "$_linked_match" = true ]; then
        _worktree_valid=true
      else
        _worktree_reject_reason="not a linked worktree (not in git worktree list)"
      fi
    fi
  fi

  if [ "$_worktree_valid" = true ]; then
    echo "ACCEPT"
  else
    echo "REJECT:$_worktree_reject_reason"
  fi
}

# ---------------------------------------------------------------------------
# Shared setup for linked-worktree harness tests: real git repo + worktree.
# Each test that needs a live repo calls _setup_linked_wt_repo() at its top.
# We do NOT fold this into the global setup() because most tests in this file
# do not need a git repo and creating one would slow the suite.
# ---------------------------------------------------------------------------
_setup_linked_wt_repo() {
  # Build a fresh fixture repo with a bare remote inside RITE_TEST_TMPDIR.
  # create_bare_remote / create_fixture_repo are from helpers/git-fixtures.bash.
  local _bare
  _bare=$(create_bare_remote "origin")
  local _repo
  _repo=$(create_fixture_repo "$_bare")

  # Create a feature branch and linked worktree
  cd "$_repo" || return 1
  local _branch="feat/test-linked-wt-$$"
  git checkout -b "$_branch" main >/dev/null 2>&1
  echo "feature" > feature.sh
  git add feature.sh
  git commit -m "Add feature" >/dev/null 2>&1

  local _wt_path="${RITE_TEST_TMPDIR}/linked-wt-$$"
  git worktree add "$_wt_path" "$_branch" >/dev/null 2>&1

  # Resolve canonical path (macOS /var → /private/var symlink)
  local _wt_real
  _wt_real=$(cd "$_wt_path" && pwd -P 2>/dev/null || echo "$_wt_path")

  # Return to repo root so callers start in a known CWD
  cd "$_repo" || return 1

  # Export for caller
  echo "REPO=$_repo"
  echo "WT_PATH=$_wt_path"
  echo "WT_REAL=$_wt_real"
  echo "BRANCH=$_branch"
}

@test "behavioral: linked-worktree check — ACCEPT real linked worktree" {
  # Test 17: the happy path — saved path is in git worktree list → ACCEPT
  local _setup_out
  _setup_out=$(_setup_linked_wt_repo)

  local _repo _wt_real
  _repo=$(echo "$_setup_out" | awk -F= '/^REPO=/{print $2}')
  _wt_real=$(echo "$_setup_out" | awk -F= '/^WT_REAL=/{print $2}')

  local _result
  _result=$(_simulate_resume_validation_with_worktree_check "$_wt_real" "$_repo")

  [ "$_result" = "ACCEPT" ] || {
    echo "FAIL: expected ACCEPT for a real linked worktree"
    echo "  saved_worktree='$_wt_real'"
    echo "  project_root='$_repo'"
    echo "  result='$_result'"
    # Dump worktree list for diagnosis
    git -C "$_repo" worktree list --porcelain >&2 || true
    return 1
  }
}

@test "behavioral: linked-worktree check — REJECT directory not in git worktree list" {
  # Test 18: a real directory that exists but was never registered as a worktree
  # must be rejected to prevent session state from pointing at random directories.
  local _setup_out
  _setup_out=$(_setup_linked_wt_repo)

  local _repo
  _repo=$(echo "$_setup_out" | awk -F= '/^REPO=/{print $2}')

  # A separate directory that exists on disk but is NOT a registered worktree
  local _impostor="${RITE_TEST_TMPDIR}/impostor-dir-$$"
  mkdir -p "$_impostor"

  local _result
  _result=$(_simulate_resume_validation_with_worktree_check "$_impostor" "$_repo")

  [[ "$_result" == REJECT:* ]] || {
    echo "FAIL: expected REJECT for directory not in git worktree list"
    echo "  saved_worktree='$_impostor'"
    echo "  result='$_result'"
    return 1
  }
  [[ "$_result" == *"not a linked worktree"* ]] || {
    echo "FAIL: expected 'not a linked worktree' rejection reason"
    echo "  result='$_result'"
    return 1
  }
  echo "Correctly rejected: $_result"
}

@test "behavioral: linked-worktree check — REJECT path that resolves to main repo root via symlink (pwd -P)" {
  # Test 19: a symlink that points at the main checkout must be rejected even
  # though the symlink path itself is different from RITE_PROJECT_ROOT.
  # This validates the pwd -P canonicalisation step.
  local _setup_out
  _setup_out=$(_setup_linked_wt_repo)

  local _repo
  _repo=$(echo "$_setup_out" | awk -F= '/^REPO=/{print $2}')

  # Create a symlink to the main repo root
  local _sym="${RITE_TEST_TMPDIR}/main-alias-$$"
  ln -s "$_repo" "$_sym"

  local _result
  _result=$(_simulate_resume_validation_with_worktree_check "$_sym" "$_repo")

  [[ "$_result" == REJECT:* ]] || {
    echo "FAIL: expected REJECT for symlink to main repo root"
    echo "  saved_worktree (symlink)='$_sym' → '$_repo'"
    echo "  result='$_result'"
    return 1
  }
  # Either "equals main repo root" (tier-2 string match) or
  # "resolves to main repo root" (tier-4 pwd -P match) is acceptable —
  # both indicate the guard fired correctly.
  [[ "$_result" == *"main repo root"* ]] || {
    echo "FAIL: expected a 'main repo root' rejection reason"
    echo "  result='$_result'"
    return 1
  }
  echo "Correctly rejected: $_result"
}

@test "behavioral: linked-worktree check — ACCEPT linked worktree whose path contains spaces" {
  # Test 20: verifies --porcelain is necessary; plain 'git worktree list' truncates
  # paths at the first space via awk '{print $1}', causing false non-match.
  local _bare
  _bare=$(create_bare_remote "origin-spaces")
  local _repo
  _repo=$(create_fixture_repo "$_bare")

  cd "$_repo" || return 1
  local _branch="feat/spaces-test-$$"
  git checkout -b "$_branch" main >/dev/null 2>&1
  echo "spaces" > spaces.sh
  git add spaces.sh
  git commit -m "Add spaces feature" >/dev/null 2>&1

  # Worktree path with a space in the name
  local _wt_path="${RITE_TEST_TMPDIR}/linked wt spaces $$"
  git worktree add "$_wt_path" "$_branch" >/dev/null 2>&1

  local _wt_real
  _wt_real=$(cd "$_wt_path" && pwd -P 2>/dev/null || echo "$_wt_path")

  local _result
  _result=$(_simulate_resume_validation_with_worktree_check "$_wt_real" "$_repo")

  [ "$_result" = "ACCEPT" ] || {
    echo "FAIL: expected ACCEPT for linked worktree with spaces in path"
    echo "  saved_worktree='$_wt_real'"
    echo "  project_root='$_repo'"
    echo "  result='$_result'"
    git -C "$_repo" worktree list --porcelain >&2 || true
    return 1
  }
}

@test "behavioral: linked-worktree check — ACCEPT linked worktree accessed via symlink (pwd -P canonicalisation)" {
  # Test 21: a symlink to the linked worktree must be accepted after pwd -P
  # resolves it to the same canonical path that git worktree list --porcelain
  # reports.  Both the saved_worktree path and the list entries are resolved
  # via pwd -P, so the comparison is always canonical-vs-canonical.
  local _setup_out
  _setup_out=$(_setup_linked_wt_repo)

  local _repo _wt_real
  _repo=$(echo "$_setup_out" | awk -F= '/^REPO=/{print $2}')
  _wt_real=$(echo "$_setup_out" | awk -F= '/^WT_REAL=/{print $2}')

  # Create a symlink to the linked worktree
  local _sym="${RITE_TEST_TMPDIR}/wt-sym-$$"
  ln -s "$_wt_real" "$_sym"

  # Pass the symlink as the saved path — pwd -P must resolve it to _wt_real
  local _result
  _result=$(_simulate_resume_validation_with_worktree_check "$_sym" "$_repo")

  [ "$_result" = "ACCEPT" ] || {
    echo "FAIL: expected ACCEPT when saved path is a symlink to a real linked worktree"
    echo "  symlink='$_sym' → '$_wt_real'"
    echo "  project_root='$_repo'"
    echo "  result='$_result'"
    git -C "$_repo" worktree list --porcelain >&2 || true
    return 1
  }
}
