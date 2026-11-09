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
  # and GIT_SYMBOLIC_REF_STUB for `git -C <dir> symbolic-ref -q HEAD`.
  # Strips -C <dir> prefix so the stub also intercepts the production form
  # `git -C <dir> worktree list --porcelain` (added in #1688 to handle
  # cwd-after-worktree-removal) and `git -C <dir> symbolic-ref -q HEAD` (added
  # for branch re-resolution — dir names != branch names in production).
  export STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/git" << 'GITSTUB'
#!/bin/bash
# Strip -C <dir> argument if present before dispatch.
if [ "${1:-}" = "-C" ]; then
  shift 2
fi
if [ "${1:-}" = "worktree" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "--porcelain" ]; then
  printf '%s' "${GIT_PORCELAIN_STUB:-}"
elif [ "${1:-}" = "symbolic-ref" ] && [ "${2:-}" = "-q" ] && [ "${3:-}" = "HEAD" ]; then
  printf '%s\n' "${GIT_SYMBOLIC_REF_STUB:-}"
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
# Helper: run the real _assert_worktree_alignment in an isolated subshell.
#
# Extracts the function definition from workflow-runner.sh at runtime so that
# tests exercise the shipped code rather than a re-implementation that can drift.
# Uses GIT_PORCELAIN_STUB (exported by each test) to control git output.
#
# Outputs markers to stdout so callers can assert behaviour:
#   FINAL_PATH=<path>                — final WORKTREE_PATH on return
#   WORKTREE_RERESOLVED ...          — re-resolution diag (via _diag stub)
#   MISMATCH                         — hard-error path taken (exit 1)
#   [INFO] / [ERROR] / [WARN]        — print_* stub output
# ============================================================================

_run_reresolve_check() {
  local state_dir="$1"
  local issue_number="$2"
  local old_wt="$3"
  # $4 is new_wt — provided via handoff file by the caller, not injected here
  local wf_exit="${5:-0}"

  local _script="$BATS_TEST_TMPDIR/reresolve-check-${issue_number}.sh"
  local _func_def
  _func_def=$(awk '
    /^_assert_worktree_alignment[(][)]/ { in_func=1 }
    in_func { print }
    in_func && /^\}$/ { exit }
  ' "$WORKFLOW_RUNNER")

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: state_dir, issue_number,
  # old_wt, and wf_exit must expand; inner script variables are protected with \$.
  cat > "$_script" <<SCRIPT_EOF
#!/bin/bash
set -euo pipefail

RITE_STATE_DIR='${state_dir}'
WORKTREE_PATH='${old_wt}'
RITE_PROJECT_ROOT='${state_dir}'

print_info()    { echo "[INFO] \$*"; }
print_error()   { echo "[ERROR] \$*"; }
print_warning() { echo "[WARN] \$*"; }
_diag()         { echo "[DIAG] \$*"; }
SCRIPT_EOF

  printf '%s\n' "$_func_def" >> "$_script"

  cat >> "$_script" <<CALL_EOF

_exit_code=0
_assert_worktree_alignment '${issue_number}' '${wf_exit}' || _exit_code=\$?
[ "\$_exit_code" -eq 0 ] || echo 'MISMATCH'
echo "FINAL_PATH=\$WORKTREE_PATH"
exit \$_exit_code
CALL_EOF

  bash "$_script"
}

# ============================================================================
# 1. Re-resolution succeeds: single match on branch == dev session's path
#    → returns 0, adopts new path, emits WORKTREE_RERESOLVED
#    (models the #1518 shape: old worktree deleted, new one created)
# ============================================================================

@test "reresolve: exactly one branch match equal to dev session path → adopts, returns 0" {
  local issue_number="1518"
  # Production-shaped names: dir is truncated/prefixed/batch-suffixed; branch is the real ref.
  local old_wt="$RITE_TEST_TMPDIR/wt/ft-resolve-wt-by-branch_b1492-1464-1527"
  local new_wt="$RITE_TEST_TMPDIR/wt/ft-resolve-wt-by-branch_b1542-1531-1518"
  # Only new_wt exists — old_wt was deleted by EMPTY_INIT recovery (the [ ! -d ] guard).
  mkdir -p "$new_wt"

  echo "$new_wt" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  # symbolic-ref returns the full branch ref (not the dir basename).
  export GIT_SYMBOLIC_REF_STUB="refs/heads/feat/resolve-worktree-by-branch-after-dev-auto-recovery"
  export GIT_PORCELAIN_STUB
  GIT_PORCELAIN_STUB="$(printf 'worktree %s\nHEAD abc123\nbranch refs/heads/feat/resolve-worktree-by-branch-after-dev-auto-recovery\n\n' "$new_wt")"

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
  # old_wt deleted by EMPTY_INIT; only new_wt exists.
  mkdir -p "$new_wt"

  echo "$new_wt" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  export GIT_SYMBOLIC_REF_STUB="refs/heads/feat/some-feature-branch"
  export GIT_PORCELAIN_STUB
  GIT_PORCELAIN_STUB="$(printf 'worktree %s\nHEAD def456\nbranch refs/heads/feat/some-feature-branch\n\n' "$new_wt")"

  run _run_reresolve_check "$RITE_STATE_DIR" "$issue_number" "$old_wt" "$new_wt"

  [ "$status" -eq 0 ]
  [[ "$output" == *"FINAL_PATH=$new_wt"* ]]
}

@test "reresolve: WORKTREE_RERESOLVED diag carries from= and to= fields" {
  local issue_number="42"
  local old_wt="$RITE_TEST_TMPDIR/wt/ft-old_b99"
  local new_wt="$RITE_TEST_TMPDIR/wt/ft-new_b100"
  # old_wt deleted by EMPTY_INIT; only new_wt exists.
  mkdir -p "$new_wt"

  echo "$new_wt" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  export GIT_SYMBOLIC_REF_STUB="refs/heads/feat/diag-test-branch"
  export GIT_PORCELAIN_STUB
  GIT_PORCELAIN_STUB="$(printf 'worktree %s\nHEAD abc\nbranch refs/heads/feat/diag-test-branch\n\n' "$new_wt")"

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

  # symbolic-ref returns the branch; both new_wt and third_wt register it → count = 2 → hard error.
  export GIT_SYMBOLIC_REF_STUB="refs/heads/feat/shared-branch"
  export GIT_PORCELAIN_STUB
  GIT_PORCELAIN_STUB="$(printf \
    'worktree %s\nHEAD abc\nbranch refs/heads/feat/shared-branch\n\nworktree %s\nHEAD def\nbranch refs/heads/feat/shared-branch\n\n' \
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

  export GIT_SYMBOLIC_REF_STUB="refs/heads/feat/another-shared"
  export GIT_PORCELAIN_STUB
  GIT_PORCELAIN_STUB="$(printf \
    'worktree %s\nHEAD a\nbranch refs/heads/feat/another-shared\n\nworktree %s\nHEAD b\nbranch refs/heads/feat/another-shared\n\n' \
    "$new_wt" "$third_wt")"

  run _run_reresolve_check "$RITE_STATE_DIR" "$issue_number" "$old_wt" "$new_wt"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Dev session used:   $new_wt"* ]]
  [[ "$output" == *"Orchestrator found: $old_wt"* ]]
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

  # symbolic-ref returns empty (detached HEAD exits non-zero; stub returns "").
  export GIT_SYMBOLIC_REF_STUB=""
  # Porcelain shows new_wt in detached state — no branch line.
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

  export GIT_SYMBOLIC_REF_STUB="refs/heads/feat/no-match-branch"
  export GIT_PORCELAIN_STUB=""

  run _run_reresolve_check "$RITE_STATE_DIR" "$issue_number" "$old_wt" "$new_wt"

  [ "$status" -eq 1 ]
  [[ "$output" == *"MISMATCH"* ]]
}

# ============================================================================
# 2b. Hard error: stale path still exists as a directory (genuine mismatch —
#     NOT an EMPTY_INIT recovery) → [ ! -d "$WORKTREE_PATH" ] guard fires.
#
# The dir-existence guard protects against path-canonicalization skew in
# _rr_stale_present: if the stale path exists under a different spelling,
# _rr_stale_present could return 0 (false negative), allowing adoption of a
# genuine crossed-state-files mismatch. [ ! -d "$WORKTREE_PATH" ] is
# canonicalization-proof and blocks this.
# ============================================================================

@test "reresolve: stale path still exists as directory → hard error even with one branch match" {
  local issue_number="44"
  local old_wt="$RITE_TEST_TMPDIR/wt/ft-old_b44"
  local new_wt="$RITE_TEST_TMPDIR/wt/ft-new_b44"
  # Both directories exist — this is NOT an EMPTY_INIT recovery.
  mkdir -p "$old_wt" "$new_wt"

  echo "$new_wt" > "${RITE_STATE_DIR}/worktree-handoff-${issue_number}.txt"

  # One branch match (count=1) and stale path absent from porcelain (_rr_stale_present=0)
  # would satisfy the old condition — but old_wt still exists on disk, so the
  # [ ! -d "$WORKTREE_PATH" ] guard blocks adoption and hard-fails.
  export GIT_SYMBOLIC_REF_STUB="refs/heads/feat/genuine-mismatch"
  export GIT_PORCELAIN_STUB
  GIT_PORCELAIN_STUB="$(printf 'worktree %s\nHEAD abc\nbranch refs/heads/feat/genuine-mismatch\n\n' "$new_wt")"

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

@test "structural: symbolic-ref used for branch lookup (not basename)" {
  [ -f "$WORKFLOW_RUNNER" ] || {
    echo "FATAL: $WORKFLOW_RUNNER not found" >&2
    return 1
  }
  _func_body=$(awk '
    /^_assert_worktree_alignment[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print }
  ' "$WORKFLOW_RUNNER")

  echo "$_func_body" | grep -qF 'symbolic-ref' || {
    echo "FAIL: 'symbolic-ref' not found in _assert_worktree_alignment" >&2
    echo "      Branch must be read from worktree HEAD, not from dir basename (#1688)" >&2
    return 1
  }
  # Confirm basename is not used (the false convention that produced zero matches).
  echo "$_func_body" | grep -v '^[[:space:]]*#' | grep -qF '$(basename' && {
    echo "FAIL: '\$(basename' still used in _assert_worktree_alignment branch lookup" >&2
    echo "      Dir names are transformations of branches; basename always mismatches" >&2
    return 1
  } || true
}
