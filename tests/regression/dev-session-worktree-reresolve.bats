#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh
# tests/regression/dev-session-worktree-reresolve.bats
#
# Regression tests for #1688: re-resolve worktree by branch after EMPTY_INIT
# auto-recovery creates a new worktree with a different batch suffix.
#
# When the dev session's branch-health preflight detects an empty branch
# (EMPTY_INIT), it exec-restarts claude-workflow.sh, which creates a new
# worktree with the CURRENT batch suffix (different from the stale one the
# orchestrator found).  The orchestrator's cached WORKTREE_PATH becomes stale.
# _assert_worktree_alignment now resolves by branch before hard-failing.
#
# Live failure (2026-11-08): issue #1518 in batch rite-1542-…-20261108-161916 —
# old worktree …_b1492-1464-1527 (PR #1580, init only), new worktree
# …_b1542-1531-1518 with 2 commits; orchestrator PHASE_FAILED one second after
# SESSION exit=0; the stranded commits had to be pushed by hand.
#
# See: docs/architecture/behavioral-design.md — Orchestrator/Dev-Session Worktree Alignment

load '../helpers/setup'

# ============================================================================
# File-scope constants (all use BATS_TEST_FILENAME to stay portable)
# ============================================================================

# sharkrite-lint disable BATS_FILE_SCOPE_ENV_READ - Reason: BATS_TEST_FILENAME is
# set by bats before file parsing and is always available at file scope.
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WORKFLOW_RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

# ============================================================================
# Setup / teardown
# ============================================================================

setup() {
  setup_test_tmpdir
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/state"
  mkdir -p "$RITE_STATE_DIR"

  # Capture real git before PATH is modified so the stub can delegate to it.
  export REAL_GIT_PATH
  REAL_GIT_PATH="$(command -v git)"

  # Build a stub git that serves GIT_PORCELAIN_STUB for `git worktree list --porcelain`
  # and delegates everything else to the real binary.
  export STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/git" << 'GITSTUB'
#!/bin/bash
if [ "${1:-}" = "worktree" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "--porcelain" ]; then
  printf '%s' "${GIT_PORCELAIN_STUB:-}"
else
  exec "${REAL_GIT_PATH}" "$@"
fi
GITSTUB
  chmod +x "$STUB_DIR/git"

  # Prepend stub dir so the helper scripts see the stub git first.
  export PATH="$STUB_DIR:$PATH"

  # Default to empty porcelain output (no matches → hard error).
  export GIT_PORCELAIN_STUB=""
}

teardown() {
  teardown_test_tmpdir
}

# ============================================================================
# Helper: run the _assert_worktree_alignment logic in an isolated subshell.
#
# Writes the full logic (including the new branch re-resolution path) to a
# temp script and executes it.  Uses GIT_PORCELAIN_STUB (exported by each test)
# to control git worktree list --porcelain output.
#
# Outputs markers to stdout so callers can assert behaviour:
#   FINAL_PATH=<path>              — final WORKTREE_PATH value on success
#   WORKTREE_RERESOLVED from=<old> to=<new>  — re-resolution diag (via _diag stub)
#   MISMATCH                       — hard-error path taken (exit 1)
#   DEV_SESSION_USED=<path>        — dev session path printed on hard error
#   ORCHESTRATOR_FOUND=<path>      — orchestrator path printed on hard error
#   NO_HANDOFF_WARNING             — missing handoff on clean exit (exit 0)
#   HANDOFF_DIR_MISSING            — handoff path does not exist (exit 0)
# ============================================================================

_run_reresolve_check() {
  local state_dir="$1"
  local issue_number="$2"
  local old_wt="$3"
  local new_wt="$4"
  local wf_exit="${5:-0}"

  local _script="$BATS_TEST_TMPDIR/reresolve-check-${issue_number}.sh"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: state_dir, issue_number,
  # old_wt, and new_wt must expand; inner script variables are protected with \$.
  cat > "$_script" <<SCRIPT_EOF
#!/bin/bash
set -euo pipefail

RITE_STATE_DIR='${state_dir}'
WORKTREE_PATH='${old_wt}'
_issue_num='${issue_number}'
_wf_exit='${wf_exit}'

print_info()    { echo "[INFO] \$*"; }
print_error()   { echo "[ERROR] \$*"; }
print_warning() { echo "[WARN] \$*"; }
_diag()         { echo "[DIAG] \$*"; }

_dev_session_wt=''
_handoff_file="\${RITE_STATE_DIR}/worktree-handoff-\${_issue_num}.txt"
if [ -f "\$_handoff_file" ]; then
  _dev_session_wt=\$(cat "\$_handoff_file" 2>/dev/null || true)
  rm -f "\$_handoff_file"
fi

if [ -z "\${_dev_session_wt:-}" ] && [ "\${_wf_exit:-0}" -eq 0 ] && [ -n "\${RITE_STATE_DIR:-}" ]; then
  echo 'NO_HANDOFF_WARNING'
fi

if [ -n "\${_dev_session_wt:-}" ] && [ ! -d "\$_dev_session_wt" ]; then
  echo 'HANDOFF_DIR_MISSING'
  _dev_session_wt=''
fi

if [ -n "\${_dev_session_wt:-}" ] && [ -n "\${WORKTREE_PATH:-}" ]; then
  _canonical_handoff=\$(cd "\$_dev_session_wt" 2>/dev/null && pwd -P 2>/dev/null || echo "\$_dev_session_wt")
  _canonical_discovered=\$(cd "\$WORKTREE_PATH" 2>/dev/null && pwd -P 2>/dev/null || echo "\$WORKTREE_PATH")
  if [ "\$_canonical_handoff" != "\$_canonical_discovered" ]; then
    _rr_branch=\$(git worktree list --porcelain 2>/dev/null | awk \
      -v wt="\$_canonical_handoff" '
      /^worktree / { cur = \$2 }
      /^branch /   { if (cur == wt) { print \$2; exit } }
    ' || true)
    if [ -n "\${_rr_branch:-}" ]; then
      _rr_wt=\$(git worktree list --porcelain 2>/dev/null | awk \
        -v br="\$_rr_branch" '
        /^worktree / { cur = \$2 }
        /^branch /   { if (\$2 == br) print cur }
      ' || true)
      _rr_count=\$(printf '%s\n' "\$_rr_wt" | grep -c '[^[:space:]]' || true)
      if [ "\${_rr_count:-0}" -eq 1 ]; then
        _rr_canonical=\$(cd "\$_rr_wt" 2>/dev/null && pwd -P 2>/dev/null || echo "\$_rr_wt")
        if [ "\$_rr_canonical" = "\$_canonical_handoff" ]; then
          print_info "Worktree re-resolved by branch after auto-recovery: \$_dev_session_wt (was: \$WORKTREE_PATH)"
          _diag "WORKTREE_RERESOLVED issue=\${_issue_num} from=\$WORKTREE_PATH to=\$_dev_session_wt"
          WORKTREE_PATH="\$_dev_session_wt"
          echo "FINAL_PATH=\$WORKTREE_PATH"
          exit 0
        fi
      fi
    fi
    print_error 'Worktree path mismatch: dev session and orchestrator found different worktrees'
    echo "DEV_SESSION_USED=\$_dev_session_wt"
    echo "ORCHESTRATOR_FOUND=\$WORKTREE_PATH"
    echo 'MISMATCH'
    exit 1
  fi
fi

if [ -n "\${_dev_session_wt:-}" ]; then
  WORKTREE_PATH="\$_dev_session_wt"
fi

echo "FINAL_PATH=\$WORKTREE_PATH"
exit 0
SCRIPT_EOF

  bash "$_script"
}

# ============================================================================
# 1. Re-resolution succeeds: single match on branch == dev session's path
#    → returns 0, adopts new path, emits WORKTREE_RERESOLVED
#    (models the #1518 shape: old worktree deleted, new one created)
# ============================================================================

@test "reresolve: exactly one branch match equal to dev session path → adopts, returns 0" {
  local issue_number="1518"
  local old_wt="$RITE_TEST_TMPDIR/wt/ft-issue-1518_b1492-1464-1527"
  local new_wt="$RITE_TEST_TMPDIR/wt/ft-issue-1518_b1542-1531-1518"
  mkdir -p "$old_wt" "$new_wt"

  echo "$new_wt" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  export GIT_PORCELAIN_STUB
  GIT_PORCELAIN_STUB="$(printf 'worktree %s\nHEAD abc123\nbranch refs/heads/ft-issue-1518_b1542-1531-1518\n\n' "$new_wt")"

  run _run_reresolve_check "$RITE_STATE_DIR" "$issue_number" "$old_wt" "$new_wt"

  [ "$status" -eq 0 ]
  [[ "$output" == *"WORKTREE_RERESOLVED"* ]]
  [[ "$output" == *"FINAL_PATH=$new_wt"* ]]
  [[ "$output" != *"MISMATCH"* ]]
}

@test "reresolve: adopted path is exactly the dev session's handoff path" {
  local issue_number="1518"
  local old_wt="$RITE_TEST_TMPDIR/wt/ft-old_b1492"
  local new_wt="$RITE_TEST_TMPDIR/wt/ft-new_b1542"
  mkdir -p "$old_wt" "$new_wt"

  echo "$new_wt" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  export GIT_PORCELAIN_STUB
  GIT_PORCELAIN_STUB="$(printf 'worktree %s\nHEAD def456\nbranch refs/heads/ft-new_b1542\n\n' "$new_wt")"

  run _run_reresolve_check "$RITE_STATE_DIR" "$issue_number" "$old_wt" "$new_wt"

  [ "$status" -eq 0 ]
  [[ "$output" == *"FINAL_PATH=$new_wt"* ]]
}

@test "reresolve: WORKTREE_RERESOLVED diag carries from= and to= fields" {
  local issue_number="42"
  local old_wt="$RITE_TEST_TMPDIR/wt/ft-old_b99"
  local new_wt="$RITE_TEST_TMPDIR/wt/ft-new_b100"
  mkdir -p "$old_wt" "$new_wt"

  echo "$new_wt" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  export GIT_PORCELAIN_STUB
  GIT_PORCELAIN_STUB="$(printf 'worktree %s\nHEAD abc\nbranch refs/heads/ft-new_b100\n\n' "$new_wt")"

  run _run_reresolve_check "$RITE_STATE_DIR" "$issue_number" "$old_wt" "$new_wt"

  [ "$status" -eq 0 ]
  [[ "$output" == *"from=$old_wt"* ]]
  [[ "$output" == *"to=$new_wt"* ]]
}

# ============================================================================
# 2. Hard error: branch checked out at a different (third) path
#    → guard fires, returns 1 with existing "Worktree path mismatch" text
# ============================================================================

@test "reresolve: branch at a third path (multiple matches) → hard error, returns 1" {
  local issue_number="77"
  local old_wt="$RITE_TEST_TMPDIR/wt/ft-old_b77"
  local new_wt="$RITE_TEST_TMPDIR/wt/ft-new_b77"
  local third_wt="$RITE_TEST_TMPDIR/wt/ft-third_b77"
  mkdir -p "$old_wt" "$new_wt" "$third_wt"

  echo "$new_wt" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  # Both new_wt and third_wt share the same branch → count = 2 → hard error
  export GIT_PORCELAIN_STUB
  GIT_PORCELAIN_STUB="$(printf \
    'worktree %s\nHEAD abc\nbranch refs/heads/ft-shared_b77\n\nworktree %s\nHEAD def\nbranch refs/heads/ft-shared_b77\n\n' \
    "$new_wt" "$third_wt")"

  run _run_reresolve_check "$RITE_STATE_DIR" "$issue_number" "$old_wt" "$new_wt"

  [ "$status" -eq 1 ]
  [[ "$output" == *"MISMATCH"* ]]
}

@test "reresolve: branch at multiple paths keeps existing mismatch error text" {
  local issue_number="88"
  local old_wt="$RITE_TEST_TMPDIR/wt/ft-old_b88"
  local new_wt="$RITE_TEST_TMPDIR/wt/ft-new_b88"
  local third_wt="$RITE_TEST_TMPDIR/wt/ft-extra_b88"
  mkdir -p "$old_wt" "$new_wt" "$third_wt"

  echo "$new_wt" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  export GIT_PORCELAIN_STUB
  GIT_PORCELAIN_STUB="$(printf \
    'worktree %s\nHEAD a\nbranch refs/heads/ft-shared\n\nworktree %s\nHEAD b\nbranch refs/heads/ft-shared\n\n' \
    "$new_wt" "$third_wt")"

  run _run_reresolve_check "$RITE_STATE_DIR" "$issue_number" "$old_wt" "$new_wt"

  [ "$status" -eq 1 ]
  [[ "$output" == *"DEV_SESSION_USED=$new_wt"* ]]
  [[ "$output" == *"ORCHESTRATOR_FOUND=$old_wt"* ]]
}

# ============================================================================
# 3. Hard error: porcelain shows no branch for the dev session's worktree
#    (detached HEAD or worktree not in porcelain) → hard error, returns 1
# ============================================================================

@test "reresolve: no branch entry for dev session worktree (detached HEAD) → hard error" {
  local issue_number="55"
  local old_wt="$RITE_TEST_TMPDIR/wt/ft-old_b55"
  local new_wt="$RITE_TEST_TMPDIR/wt/ft-new_b55"
  mkdir -p "$old_wt" "$new_wt"

  echo "$new_wt" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  # Porcelain shows new_wt in detached state — no branch line
  export GIT_PORCELAIN_STUB
  GIT_PORCELAIN_STUB="$(printf 'worktree %s\nHEAD abc123\ndetached\n\n' "$new_wt")"

  run _run_reresolve_check "$RITE_STATE_DIR" "$issue_number" "$old_wt" "$new_wt"

  [ "$status" -eq 1 ]
  [[ "$output" == *"MISMATCH"* ]]
}

@test "reresolve: porcelain empty (no worktrees listed) → hard error, returns 1" {
  local issue_number="66"
  local old_wt="$RITE_TEST_TMPDIR/wt/ft-old_b66"
  local new_wt="$RITE_TEST_TMPDIR/wt/ft-new_b66"
  mkdir -p "$old_wt" "$new_wt"

  echo "$new_wt" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  export GIT_PORCELAIN_STUB=""

  run _run_reresolve_check "$RITE_STATE_DIR" "$issue_number" "$old_wt" "$new_wt"

  [ "$status" -eq 1 ]
  [[ "$output" == *"MISMATCH"* ]]
}

# ============================================================================
# 4. Zero behavior change on the common path: paths equal → no diag, no message
# ============================================================================

@test "reresolve: paths agree → no WORKTREE_RERESOLVED, no MISMATCH, returns 0" {
  local issue_number="99"
  local wt="$RITE_TEST_TMPDIR/wt/ft-agreed_b99"
  mkdir -p "$wt"

  echo "$wt" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  # GIT_PORCELAIN_STUB is irrelevant (re-resolution path not reached)
  export GIT_PORCELAIN_STUB=""

  run _run_reresolve_check "$RITE_STATE_DIR" "$issue_number" "$wt" "$wt"

  [ "$status" -eq 0 ]
  [[ "$output" != *"WORKTREE_RERESOLVED"* ]]
  [[ "$output" != *"MISMATCH"* ]]
  [[ "$output" == *"FINAL_PATH=$wt"* ]]
}

# ============================================================================
# 5. Structural: re-resolution code exists in workflow-runner.sh
# ============================================================================

@test "structural: git worktree list --porcelain appears in _assert_worktree_alignment" {
  [ -f "$WORKFLOW_RUNNER" ] || {
    echo "FATAL: $WORKFLOW_RUNNER not found" >&2
    return 1
  }
  # Extract the function body and verify the porcelain call is present.
  _func_body=$(awk '
    /^_assert_worktree_alignment[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: could not extract _assert_worktree_alignment from $WORKFLOW_RUNNER" >&2
    return 1
  }

  echo "$_func_body" | grep -qF 'worktree list --porcelain' || {
    echo "FAIL: 'git worktree list --porcelain' not found in _assert_worktree_alignment" >&2
    echo "      Branch re-resolution requires porcelain worktree enumeration (#1688)" >&2
    return 1
  }
}

@test "structural: WORKTREE_RERESOLVED diag string in _assert_worktree_alignment" {
  [ -f "$WORKFLOW_RUNNER" ] || {
    echo "FATAL: $WORKFLOW_RUNNER not found" >&2
    return 1
  }
  grep -q 'WORKTREE_RERESOLVED' "$WORKFLOW_RUNNER" || {
    echo "FAIL: 'WORKTREE_RERESOLVED' not found in $WORKFLOW_RUNNER" >&2
    echo "      _assert_worktree_alignment must emit this diag on successful re-resolution" >&2
    return 1
  }
}

@test "structural: WORKTREE_RERESOLVED documented in CLAUDE.md diagnostic section" {
  [ -f "$CLAUDE_MD" ] || {
    echo "FATAL: $CLAUDE_MD not found" >&2
    return 1
  }
  grep -q 'WORKTREE_RERESOLVED' "$CLAUDE_MD" || {
    echo "FAIL: 'WORKTREE_RERESOLVED' not found in CLAUDE.md" >&2
    echo "      Diagnostic logging section must document this diag (#1688)" >&2
    return 1
  }
}

@test "structural: hard error message still present (guard not weakened)" {
  [ -f "$WORKFLOW_RUNNER" ] || {
    echo "FATAL: $WORKFLOW_RUNNER not found" >&2
    return 1
  }
  grep -q 'Worktree path mismatch' "$WORKFLOW_RUNNER" || {
    echo "FAIL: 'Worktree path mismatch' not found in $WORKFLOW_RUNNER" >&2
    echo "      The hard-error path from #1630 must be preserved" >&2
    return 1
  }
}
