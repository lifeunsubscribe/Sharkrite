#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh
# tests/regression/no-change-already-fixed-close.bats
#
# Regression test for: close already-fixed issues on no-change sessions
#
# Bug history (2026-07-01, LeadFlow #348):
#   After PR #407 merged the demanded `...commonLambdaEnv` at 15:37Z, the
#   15:54 batch run made no changes (correct) but marked issue #348 as
#   "failed (exit code: 1)". The workflow had no way to distinguish
#   "already satisfied" from "crashed / not actionable".
#
# Fix (this PR):
#   verify_already_satisfied() is called at BOTH retry-fail paths inside
#   phase_claude_workflow(). It extracts the Verification Commands block
#   from the issue body and runs each one against origin/main. If all exit 0
#   the issue is closed with evidence. If any fail the old loud-fail path
#   runs unchanged.
#
# This test suite verifies:
#   1. verify_already_satisfied() is defined in workflow-runner.sh (structural)
#   2. BOTH no-change exit paths call verify_already_satisfied (structural)
#   3. run_workflow handles exit 15 (structural)
#   4. Verification commands are extracted from the issue body correctly (unit)
#   5. When all commands pass → returns 0 (behavioral / subprocess)
#   6. When any command fails → returns 1 (behavioral / subprocess)
#   7. When no commands found → returns 1 (behavioral / subprocess)
#   8. Close comment includes command + output evidence (behavioral / subprocess)
#   9. Close comment includes machine-readable marker (behavioral / subprocess)
#  10. No-change sessions without evidence still fail loud — return 1 preserved (structural)

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: build a self-contained subprocess script that stubs all deps and
# runs verify_already_satisfied. The awk extraction of the function from
# workflow-runner.sh is used so the test always exercises the REAL function,
# not a copy. The caller writes the issue body and any extra stubs into the
# script before the function source, then calls verify_already_satisfied.
# ---------------------------------------------------------------------------

_write_driver() {
  # _write_driver SCRIPT_PATH ISSUE_BODY
  # Writes a runnable bash script that:
  #   - defines minimal stubs (print_*, _diag, git)
  #   - stubs gh_safe with configurable issue-view output
  #   - extracts and sources verify_already_satisfied from the real source
  #   - runs: verify_already_satisfied "99" && echo "EXIT:0" || echo "EXIT:$?"
  local _path="$1"
  local _body="$2"

  # Write the issue body to a sidecar file so the driver can cat it without
  # heredoc/variable-expansion quoting hazards (multi-line bodies with backticks
  # and special chars are safe in a file reference).
  local _body_file="${RITE_TEST_TMPDIR}/issue_body_$(basename "$_path").txt"
  printf '%s' "$_body" > "$_body_file"

  # The heredoc delimiter is unquoted so we can expand $RITE_TEST_TMPDIR and
  # $RITE_REPO_ROOT at write time. Dollar signs that must appear in the driver
  # script are escaped as \$.
  cat > "$_path" <<SCRIPT
#!/bin/bash
set -euo pipefail
RITE_PROJECT_ROOT="${RITE_TEST_TMPDIR}"
print_success() { echo "SUCCESS: \$*" >&2; }
print_info()    { echo "INFO: \$*" >&2; }
print_warning() { echo "WARNING: \$*" >&2; }
print_error()   { echo "ERROR: \$*" >&2; }
_diag()         { :; }
git()           { return 0; }

_BODY_FILE="${_body_file}"
_COMMENT_FILE="${RITE_TEST_TMPDIR}/captured_comment.txt"
_CLOSED_FILE="${RITE_TEST_TMPDIR}/issue_closed.txt"

gh_safe() {
  local _sub="\$1"; shift
  case "\$_sub" in
    issue)
      local _cmd="\$1"; shift
      case "\$_cmd" in
        view)   cat "\$_BODY_FILE" ;;
        comment)
          while [ \$# -gt 0 ]; do
            if [ "\$1" = "--body" ]; then printf '%s' "\$2" > "\$_COMMENT_FILE"; fi
            shift
          done ;;
        close)  echo "closed" > "\$_CLOSED_FILE" ;;
        *)      : ;;
      esac ;;
    pr)
      # absorb pr view --json additions calls (return 0 additions)
      echo "0" ;;
    *) : ;;
  esac
}

# Extract verify_already_satisfied from the real source file.
_fn_file="${RITE_TEST_TMPDIR}/verify_fn_\$\$.sh"
awk '
  /^verify_already_satisfied\(\)/ { printing=1 }
  printing { print }
  printing && /^\}$/ { exit }
' "${RITE_REPO_ROOT}/lib/core/workflow-runner.sh" > "\$_fn_file"

# shellcheck disable=SC1090
source "\$_fn_file"

verify_already_satisfied "99" && echo "EXIT:0" || echo "EXIT:\$?"
SCRIPT
  chmod +x "$_path"
}

# =============================================================================
# STRUCTURAL: verify the fix is in place
# =============================================================================

@test "structural: verify_already_satisfied() is defined in workflow-runner.sh" {
  _count=$(grep -c "^verify_already_satisfied()" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" || true)
  [ "$_count" -ge 1 ]
}

@test "structural: verify_already_satisfied() is defined BEFORE phase_claude_workflow()" {
  _line_verify=$(grep -n "^verify_already_satisfied()" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" | head -1 | cut -d: -f1)
  _line_phase=$(grep -n "^phase_claude_workflow()" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" | head -1 | cut -d: -f1)
  [ -n "$_line_verify" ] && [ -n "$_line_phase" ]
  [ "$_line_verify" -lt "$_line_phase" ]
}

@test "structural: at least 3 occurrences of verify_already_satisfied (def + 2 call sites)" {
  _count=$(grep -c "verify_already_satisfied" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" || true)
  [ "$_count" -ge 3 ] || {
    echo "FAIL: expected >=3 occurrences (1 def + 2 call sites), found $_count"
    return 1
  }
}

@test "structural: WORKFLOW_EXIT -eq 4 path (PR-exists branch) calls verify_already_satisfied" {
  _file="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  # Extract lines from the WORKFLOW_EXIT -eq 4 block (ends at first return 1)
  _block=$(awk '
    /if \[ \$WORKFLOW_EXIT -eq 4 \]/ { in_block=1 }
    in_block { print; if (/return 1/) { exit } }
  ' "$_file" || true)
  echo "$_block" | grep -q "verify_already_satisfied" || {
    echo "FAIL: verify_already_satisfied not called in WORKFLOW_EXIT -eq 4 block"
    return 1
  }
}

@test "structural: workflow_exit -eq 4 path (fresh-start branch) calls verify_already_satisfied" {
  _file="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  _block=$(awk '
    /if \[ \$workflow_exit -eq 4 \]/ { in_block=1 }
    in_block { print; if (/return 1/) { exit } }
  ' "$_file" || true)
  echo "$_block" | grep -q "verify_already_satisfied" || {
    echo "FAIL: verify_already_satisfied not called in workflow_exit -eq 4 block"
    return 1
  }
}

@test "structural: run_workflow handles _phase1_exit -eq 15 (already-satisfied sentinel)" {
  _count=$(grep -c "_phase1_exit -eq 15" "$RITE_REPO_ROOT/lib/core/workflow-runner.sh" || true)
  [ "$_count" -ge 1 ] || {
    echo "FAIL: _phase1_exit -eq 15 handler not found in run_workflow"
    return 1
  }
}

@test "structural: exit-15 handler sets RITE_WORKFLOW_EXPLICIT_COMPLETE=1 (bypasses invariant)" {
  _file="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  _block=$(awk '
    /_phase1_exit -eq 15/ { in_block=1 }
    in_block { print; if (/return 0/) { exit } }
  ' "$_file" || true)
  echo "$_block" | grep -q "RITE_WORKFLOW_EXPLICIT_COMPLETE=1" || {
    echo "FAIL: RITE_WORKFLOW_EXPLICIT_COMPLETE=1 not set in exit-15 block"
    return 1
  }
}

# =============================================================================
# UNIT: awk extraction of Verification Commands
# (These tests replicate the exact awk used in verify_already_satisfied to
# confirm the extraction logic is correct — they do not need to source the
# function.)
# =============================================================================

@test "unit: extracts commands from Verification Commands block" {
  _body='## Verification Commands

```bash
echo hello
grep foo /dev/null
```
'
  _cmds=$(printf '%s\n' "$_body" | awk '
    /^#+[[:space:]]+(Verification Commands?)[[:space:]]*$/ { in_section=1; next }
    in_section && /^```/ {
      if (!in_fence) { in_fence=1; next }
      else { exit }
    }
    in_section && in_fence { print }
  ' || true)
  _real=$(printf '%s\n' "$_cmds" | grep -vE '^\s*(#|$)' || true)

  echo "$_real" | grep -q "echo hello"
  echo "$_real" | grep -q "grep foo /dev/null"
}

@test "unit: skips comment lines in Verification Commands block" {
  _body='## Verification Commands

```bash
# This is a comment
echo hello
```
'
  _cmds=$(printf '%s\n' "$_body" | awk '
    /^#+[[:space:]]+(Verification Commands?)[[:space:]]*$/ { in_section=1; next }
    in_section && /^```/ {
      if (!in_fence) { in_fence=1; next }
      else { exit }
    }
    in_section && in_fence { print }
  ' || true)
  _real=$(printf '%s\n' "$_cmds" | grep -vE '^\s*(#|$)' || true)

  ! echo "$_real" | grep -q "^# This is"
  echo "$_real" | grep -q "echo hello"
}

@test "unit: returns empty when no Verification Commands heading present" {
  _body='## Acceptance Criteria

- [ ] foo passes

## Done Definition

Done when fixed.
'
  _cmds=$(printf '%s\n' "$_body" | awk '
    /^#+[[:space:]]+(Verification Commands?)[[:space:]]*$/ { in_section=1; next }
    in_section && /^```/ {
      if (!in_fence) { in_fence=1; next }
      else { exit }
    }
    in_section && in_fence { print }
  ' || true)
  _real=$(printf '%s\n' "$_cmds" | grep -vE '^\s*(#|$)' || true)
  [ -z "${_real:-}" ]
}

@test "unit: only captures first fenced block after heading (stops at closing fence)" {
  _body='## Verification Commands

```bash
echo first
```

```bash
echo second
```
'
  _cmds=$(printf '%s\n' "$_body" | awk '
    /^#+[[:space:]]+(Verification Commands?)[[:space:]]*$/ { in_section=1; next }
    in_section && /^```/ {
      if (!in_fence) { in_fence=1; next }
      else { exit }
    }
    in_section && in_fence { print }
  ' || true)
  _real=$(printf '%s\n' "$_cmds" | grep -vE '^\s*(#|$)' || true)

  echo "$_real" | grep -q "echo first"
  ! echo "$_real" | grep -q "echo second"
}

# =============================================================================
# BEHAVIORAL: verify_already_satisfied() — subprocess tests
# Each test runs the real function in a self-contained subprocess with stubs.
# =============================================================================

@test "behavioral: all commands pass → function returns 0 (already satisfied)" {
  _body='## Verification Commands

```bash
true
echo "check passed"
```
'
  _script="$RITE_TEST_TMPDIR/test-satisfied.sh"
  _write_driver "$_script" "$_body"

  run bash "$_script"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "EXIT:0" ]]
}

@test "behavioral: one command fails → function returns 1 (not already satisfied)" {
  _body='## Verification Commands

```bash
true
false
```
'
  _script="$RITE_TEST_TMPDIR/test-fail.sh"
  _write_driver "$_script" "$_body"

  run bash "$_script"
  [ "$status" -eq 0 ]   # the driver itself exits 0; EXIT: line reports fn result
  [[ "$output" =~ "EXIT:1" ]]
}

@test "behavioral: no Verification Commands block → function returns 1" {
  _body='## Description

Fix the thing.

## Done Definition

Done when fixed.
'
  _script="$RITE_TEST_TMPDIR/test-no-cmds.sh"
  _write_driver "$_script" "$_body"

  run bash "$_script"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "EXIT:1" ]]
}

@test "behavioral: empty issue body → function returns 1 without closing" {
  _script="$RITE_TEST_TMPDIR/test-empty-body.sh"
  # Empty body — gh_safe issue view returns blank
  _write_driver "$_script" ""

  run bash "$_script"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "EXIT:1" ]]
  # Issue must NOT have been closed
  [ ! -f "$RITE_TEST_TMPDIR/issue_closed.txt" ]
}

@test "behavioral: close comment includes the command and its output as evidence" {
  _body='## Verification Commands

```bash
echo "evidence_marker_xyz"
```
'
  _script="$RITE_TEST_TMPDIR/test-evidence.sh"
  _write_driver "$_script" "$_body"

  run bash "$_script"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "EXIT:0" ]]

  # Evidence comment must have been written
  [ -f "$RITE_TEST_TMPDIR/captured_comment.txt" ]
  grep -q "echo.*evidence_marker_xyz" "$RITE_TEST_TMPDIR/captured_comment.txt"
  grep -q "evidence_marker_xyz" "$RITE_TEST_TMPDIR/captured_comment.txt"
}

@test "behavioral: close comment includes machine-readable sharkrite marker" {
  _body='## Verification Commands

```bash
true
```
'
  _script="$RITE_TEST_TMPDIR/test-marker.sh"
  _write_driver "$_script" "$_body"

  run bash "$_script"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "EXIT:0" ]]

  [ -f "$RITE_TEST_TMPDIR/captured_comment.txt" ]
  grep -q "sharkrite-auto-closed-already-satisfied" "$RITE_TEST_TMPDIR/captured_comment.txt"
}

@test "behavioral: issue is closed via gh_safe issue close when satisfied" {
  _body='## Verification Commands

```bash
true
```
'
  _script="$RITE_TEST_TMPDIR/test-closed.sh"
  _write_driver "$_script" "$_body"

  run bash "$_script"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "EXIT:0" ]]
  # The gh_safe issue close call must have fired
  [ -f "$RITE_TEST_TMPDIR/issue_closed.txt" ]
}

# =============================================================================
# BEHAVIORAL: loud-fail path preserved (regression guard)
# Confirm that returning 1 after verify_already_satisfied returns 1 is still
# structurally present — the loud-fail path must not have been removed.
# =============================================================================

@test "regression: WORKFLOW_EXIT -eq 4 block still returns 1 after verify check" {
  _file="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  _block=$(awk '
    /if \[ \$WORKFLOW_EXIT -eq 4 \]/ { in_block=1 }
    in_block { print; if (/return 1/) { exit } }
  ' "$_file" || true)
  echo "$_block" | grep -q "return 1" || {
    echo "FAIL: return 1 removed from WORKFLOW_EXIT -eq 4 block — loud-fail path was deleted"
    return 1
  }
}

@test "regression: workflow_exit -eq 4 block still returns 1 after verify check" {
  _file="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  _block=$(awk '
    /if \[ \$workflow_exit -eq 4 \]/ { in_block=1 }
    in_block { print; if (/return 1/) { exit } }
  ' "$_file" || true)
  echo "$_block" | grep -q "return 1" || {
    echo "FAIL: return 1 removed from workflow_exit -eq 4 block — loud-fail path was deleted"
    return 1
  }
}
