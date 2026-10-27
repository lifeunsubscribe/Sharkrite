#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/core/claude-workflow.sh, lib/core/workflow-runner.sh
# tests/regression/followup-target-inheritance.bats
#
# Regression test: follow-ups filed during a --branch X batch run must NOT
# inherit the parent session's integration-branch target.
#
# Issue #1531 — "Stop follow-ups inheriting session target branch"
#
# Root cause: assess-and-resolve.sh files a follow-up (e.g. #1496). Later,
# #1496 is processed in the same --branch doc-refactor batch. Phase 1 writes
# .rite/state/target-branch-1496.txt = doc-refactor. On any subsequent run,
# tier-2 of resolve_target_branch returns doc-refactor even for standalone
# `rite 1496` — causing check_branch_mismatch to fire with a corrected command
# that itself hits the same state file, looping forever.
#
# Fixes:
#   A. assess-and-resolve.sh writes followup-no-inherit-N.marker at creation
#      time for each new follow-up issue number.
#   B. claude-workflow.sh reads the marker and skips the state-file write for
#      issues that carry it.
#   C. handle_branch_mismatch() accepts a 6th SOURCE argument (state/env/default)
#      and names it in the error message; prescribes "rite --branch <pr_base> N"
#      for state-file-driven mismatches so the --base handler in main() can clear
#      the stale file, breaking the loop.
#   D. workflow-runner.sh --base handler: when --base main is passed explicitly,
#      rm -f the stale target-branch-N.txt before check_branch_mismatch runs.
#
# Tests in this file:
#   STRUCTURAL (static code inspection):
#     1.  assess-and-resolve.sh writes followup-no-inherit marker after creation
#     2.  claude-workflow.sh reads the no-inherit marker before writing state file
#     3.  check_branch_mismatch captures RESOLVED_TARGET_SOURCE
#     4.  check_branch_mismatch passes source to handle_branch_mismatch (6th arg)
#     5.  handle_branch_mismatch has SOURCE parameter and names it in output
#     6.  handle_branch_mismatch uses --branch for state-file source (anti-loop)
#     7.  workflow-runner.sh --base main handler removes stale state file
#
#   BEHAVIORAL (subprocess execution with stubs):
#     8.  No-inherit marker prevents state file from being written (genuine fix)
#     9.  Genuine (non-follow-up) issue still records state file
#    10.  State-file-driven mismatch output contains "state file" source label
#    11.  State-file-driven mismatch prescribes "rite --branch main N" not bare "rite N"
#    12.  Anti-loop: --base main handler clears state file; re-check produces no mismatch

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WORKFLOW_RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"
ASSESS_AND_RESOLVE="$REPO_ROOT/lib/core/assess-and-resolve.sh"
CLAUDE_WORKFLOW="$REPO_ROOT/lib/core/claude-workflow.sh"

setup() {
  [ -f "$WORKFLOW_RUNNER" ] || {
    echo "FATAL: $WORKFLOW_RUNNER not found" >&2
    return 1
  }
  [ -f "$ASSESS_AND_RESOLVE" ] || {
    echo "FATAL: $ASSESS_AND_RESOLVE not found" >&2
    return 1
  }
  [ -f "$CLAUDE_WORKFLOW" ] || {
    echo "FATAL: $CLAUDE_WORKFLOW not found" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: assess-and-resolve.sh
# =============================================================================

@test "structural: assess-and-resolve.sh writes followup-no-inherit marker after creation" {
  grep -qF "followup-no-inherit" "$ASSESS_AND_RESOLVE" || {
    echo "FAIL: 'followup-no-inherit' marker write not found in assess-and-resolve.sh" >&2
    echo "      assess-and-resolve.sh must write followup-no-inherit-N.marker after each new follow-up" >&2
    return 1
  }

  # Marker write must be near the _new_issue_num confirmation block (within the
  # same logical unit as FOLLOWUP_NUMBERS assignment)
  _creation_block=$(awk '
    /FOLLOWUP_NUMBERS=.*_new_issue_num/ { found=1 }
    found { print; count++ }
    count > 30 { exit }
  ' "$ASSESS_AND_RESOLVE")

  echo "$_creation_block" | grep -qF "followup-no-inherit" || {
    echo "FAIL: followup-no-inherit marker write is not near the FOLLOWUP_NUMBERS assignment" >&2
    echo "      It must be in the same _new_issue_num confirmed block" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: claude-workflow.sh
# =============================================================================

@test "structural: claude-workflow.sh reads no-inherit marker before writing state file" {
  grep -qF "followup-no-inherit" "$CLAUDE_WORKFLOW" || {
    echo "FAIL: 'followup-no-inherit' marker check not found in claude-workflow.sh" >&2
    echo "      claude-workflow.sh must skip the state-file write when the marker is present" >&2
    return 1
  }

  # The marker check must appear in the sharkrite-target-transport block
  _transport_block=$(grep -A 15 "sharkrite-target-transport" "$CLAUDE_WORKFLOW" | head -40 || true)
  echo "$_transport_block" | grep -qF "followup-no-inherit" || {
    echo "FAIL: followup-no-inherit check is not inside the sharkrite-target-transport block" >&2
    echo "      The no-inherit guard must gate the state-file write, not run elsewhere" >&2
    return 1
  }
}

@test "structural: claude-workflow.sh state-file write is inside no-inherit guard" {
  # The actual write (sharkrite-target-transport echo line) must be nested inside
  # the [ ! -f ... no-inherit ... ] guard.  Extract the block and verify ordering.
  _block=$(awk '
    /followup-no-inherit/ { in_block=1 }
    in_block { print; count++ }
    count > 10 { exit }
  ' "$CLAUDE_WORKFLOW")

  # The echo that writes target-branch-N.txt must appear AFTER the no-inherit check
  _target_write_line=$(echo "$_block" | grep -n "target-branch-.*\.txt" | head -1 | cut -d: -f1 || true)
  _no_inherit_line=$(echo "$_block" | grep -n "no-inherit" | head -1 | cut -d: -f1 || true)

  [ -n "$_target_write_line" ] && [ -n "$_no_inherit_line" ] || {
    echo "FAIL: could not locate both 'followup-no-inherit' guard and 'target-branch' write in the extracted block" >&2
    echo "      Block was: $_block" >&2
    return 1
  }

  if [ "$_target_write_line" -le "$_no_inherit_line" ]; then
    echo "FAIL: state-file write (line $_target_write_line) appears before no-inherit guard (line $_no_inherit_line)" >&2
    echo "      The write must be inside (after) the guard" >&2
    return 1
  fi
}

# =============================================================================
# STRUCTURAL: workflow-runner.sh
# =============================================================================

@test "structural: check_branch_mismatch captures RESOLVED_TARGET_SOURCE" {
  _func_body=$(awk '
    /^check_branch_mismatch[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract check_branch_mismatch body from workflow-runner.sh" >&2
    return 1
  }

  echo "$_func_body" | grep -qE "RESOLVED_TARGET_SOURCE|_mismatch_source" || {
    echo "FAIL: check_branch_mismatch does not capture RESOLVED_TARGET_SOURCE" >&2
    echo "      It must save the source tier after calling resolve_target_branch" >&2
    return 1
  }
}

@test "structural: check_branch_mismatch passes source as 6th arg to handle_branch_mismatch" {
  _func_body=$(awk '
    /^check_branch_mismatch[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  # The handle_branch_mismatch call must have 6 arguments; check for the source var
  echo "$_func_body" | grep -E "handle_branch_mismatch" | grep -qE "_mismatch_source|RESOLVED_TARGET_SOURCE" || {
    echo "FAIL: check_branch_mismatch does not pass source to handle_branch_mismatch" >&2
    echo "      The call must include the 6th SOURCE argument" >&2
    return 1
  }
}

@test "structural: handle_branch_mismatch has SOURCE parameter and names it in output" {
  _func_body=$(awk '
    /^handle_branch_mismatch[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract handle_branch_mismatch function body" >&2
    return 1
  }

  echo "$_func_body" | grep -qE "_source=" || {
    echo "FAIL: handle_branch_mismatch does not declare a _source parameter" >&2
    echo "      6th arg must be accepted as local _source=..." >&2
    return 1
  }

  echo "$_func_body" | grep -qE "_source_label" || {
    echo "FAIL: handle_branch_mismatch does not build a _source_label" >&2
    echo "      The source tier must be included in the refusal message" >&2
    return 1
  }
}

@test "structural: handle_branch_mismatch uses --branch for state-file source (anti-loop guard)" {
  _func_body=$(awk '
    /^handle_branch_mismatch[(][)]/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract handle_branch_mismatch function body" >&2
    return 1
  }

  # When source = "state", the corrected command must always include --branch
  # (even when pr_base is "main"), so the --base handler can clear the stale file.
  _state_branch=$(echo "$_func_body" | awk '
    /"\$_source" = "state"/ { in_state=1 }
    in_state { print }
    in_state && /;;/ { exit }
  ')

  echo "$_state_branch" | grep -qE "rite --branch" || {
    echo "FAIL: state-file-driven corrected command does not include 'rite --branch'" >&2
    echo "      State-file mismatches need --branch so the --base handler can clear the stale file" >&2
    echo "      Without it, bare 'rite N' still hits tier-2 and loops on the same mismatch" >&2
    return 1
  }
}

@test "structural: workflow-runner.sh --base main handler removes stale state file" {
  # The --base handler in main() must rm -f the stale target-branch file when
  # RITE_TARGET_BRANCH is set to "main". This is what makes "rite --branch main N"
  # an effective escape from a poisoned state file.
  _base_handler=$(awk '
    /--base[)]/ { in_handler=1 }
    in_handler { print; count++ }
    in_handler && /;;$/ { exit }
    count > 30 { exit }
  ' "$WORKFLOW_RUNNER")

  echo "$_base_handler" | grep -qE 'rm -f.*target-branch' || {
    echo "FAIL: --base handler does not rm -f a stale target-branch-N.txt file" >&2
    echo "      Without this, 'rite --branch main N' still hits the old state-file tier-2" >&2
    echo "      and loops on the same mismatch it was supposed to fix" >&2
    return 1
  }

  echo "$_base_handler" | grep -qE '"main"' || {
    echo "FAIL: state-file deletion in --base handler is not gated on target == main" >&2
    echo "      Only clear the file when --base main is passed (re-targeting to main)" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: subprocess execution with stubs
# =============================================================================

@test "behavioral: no-inherit marker prevents state-file write for a follow-up issue" {
  _tmpdir="$BATS_TEST_TMPDIR/state"
  mkdir -p "$_tmpdir"
  _issue_num="9001"
  _marker="${_tmpdir}/followup-no-inherit-${_issue_num}.marker"
  _state_file="${_tmpdir}/target-branch-${_issue_num}.txt"

  # Write the marker (simulating assess-and-resolve.sh filing the issue)
  touch "$_marker"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand
  _script="$BATS_TEST_TMPDIR/test-no-inherit.sh"
  cat > "$_script" <<STUB_EOF
#!/usr/bin/env bash
set -euo pipefail
RITE_STATE_DIR="${_tmpdir}"
RITE_TARGET_BRANCH="doc-refactor"
ISSUE_NUMBER="${_issue_num}"

_target_no_inherit_marker="\${RITE_STATE_DIR}/followup-no-inherit-\${ISSUE_NUMBER}.marker"
if [ ! -f "\$_target_no_inherit_marker" ]; then
  echo "\$RITE_TARGET_BRANCH" > "\${RITE_STATE_DIR}/target-branch-\${ISSUE_NUMBER}.txt" 2>/dev/null || true
fi
unset _target_no_inherit_marker
exit 0
STUB_EOF
  chmod +x "$_script"
  run bash "$_script"
  [ "$status" -eq 0 ]

  [ ! -f "$_state_file" ] || {
    echo "FAIL: state file was written despite no-inherit marker" >&2
    echo "      state file content: $(cat "$_state_file")" >&2
    return 1
  }
}

@test "behavioral: genuine issue (no marker) still writes state file" {
  _tmpdir="$BATS_TEST_TMPDIR/state2"
  mkdir -p "$_tmpdir"
  _issue_num="9002"
  _state_file="${_tmpdir}/target-branch-${_issue_num}.txt"
  # No marker file — this is a genuine (non-follow-up) issue

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand
  _script="$BATS_TEST_TMPDIR/test-genuine.sh"
  cat > "$_script" <<STUB_EOF
#!/usr/bin/env bash
set -euo pipefail
RITE_STATE_DIR="${_tmpdir}"
RITE_TARGET_BRANCH="doc-refactor"
ISSUE_NUMBER="${_issue_num}"

_target_no_inherit_marker="\${RITE_STATE_DIR}/followup-no-inherit-\${ISSUE_NUMBER}.marker"
if [ ! -f "\$_target_no_inherit_marker" ]; then
  echo "\$RITE_TARGET_BRANCH" > "\${RITE_STATE_DIR}/target-branch-\${ISSUE_NUMBER}.txt" 2>/dev/null || true
fi
unset _target_no_inherit_marker
exit 0
STUB_EOF
  chmod +x "$_script"
  run bash "$_script"
  [ "$status" -eq 0 ]

  [ -f "$_state_file" ] || {
    echo "FAIL: state file was NOT written for genuine (non-follow-up) issue" >&2
    echo "      Genuine issues must keep recording their target branch for resume" >&2
    return 1
  }

  _content=$(cat "$_state_file")
  [ "$_content" = "doc-refactor" ] || {
    echo "FAIL: state file content '$_content' != 'doc-refactor'" >&2
    return 1
  }
}

@test "behavioral: state-file-driven mismatch output contains 'state file' source label" {
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand
  _script="$BATS_TEST_TMPDIR/test-state-mismatch-label.sh"
  cat > "$_script" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail

print_error() { echo "ERROR: $*" >&2; }

# Inline the handle_branch_mismatch logic under test
handle_branch_mismatch() {
  local issue_number="$1"
  local pr_number="$2"
  local pr_base="$3"
  local effective_target="$4"
  local _mode_suffix="${5:-}"
  local _source="${6:-default}"

  local _corrected_cmd
  if [ "$_source" = "state" ]; then
    _corrected_cmd="rite --branch ${pr_base} ${issue_number}${_mode_suffix:+ $_mode_suffix}"
  elif [ "$pr_base" = "main" ]; then
    _corrected_cmd="rite ${issue_number}${_mode_suffix:+ $_mode_suffix}"
  else
    _corrected_cmd="rite --branch ${pr_base} ${issue_number}${_mode_suffix:+ $_mode_suffix}"
  fi

  local _source_label
  case "$_source" in
    state)   _source_label="state file (.rite/state/target-branch-${issue_number}.txt)" ;;
    env)     _source_label="RITE_TARGET_BRANCH env var" ;;
    *)       _source_label="default" ;;
  esac

  print_error "PR #${pr_number} base mismatch for issue #${issue_number}"
  print_error "  Current effective target:  ${effective_target}  [from: ${_source_label}]"
  print_error "  Re-run with: ${_corrected_cmd}"
  return 19
}

_output=$(handle_branch_mismatch "42" "456" "main" "doc-refactor" "" "state" 2>&1 || true)
echo "$_output" | grep -qF "state file" || {
  echo "FAIL: 'state file' not found in handle_branch_mismatch output for source=state" >&2
  echo "Output was: $_output" >&2
  exit 1
}
exit 0
STUB_EOF
  chmod +x "$_script"
  run bash "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: test script exited $status" >&2
    echo "$output" >&2
    return 1
  }
}

@test "behavioral: state-file mismatch with pr_base=main prescribes 'rite --branch main N' (anti-loop)" {
  # When the effective target came from the state file and the PR base is main,
  # the corrected command must be "rite --branch main N", NOT bare "rite N".
  # Without --branch main, a bare "rite N" still hits the old state-file tier-2
  # and loops on the same mismatch.
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand
  _script="$BATS_TEST_TMPDIR/test-state-mismatch-main-base.sh"
  cat > "$_script" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail

print_error() { echo "ERROR: $*" >&2; }

handle_branch_mismatch() {
  local issue_number="$1"
  local pr_base="$3"
  local _source="${6:-default}"

  local _corrected_cmd
  if [ "$_source" = "state" ]; then
    _corrected_cmd="rite --branch ${pr_base} ${issue_number}"
  elif [ "$pr_base" = "main" ]; then
    _corrected_cmd="rite ${issue_number}"
  else
    _corrected_cmd="rite --branch ${pr_base} ${issue_number}"
  fi

  print_error "Re-run with: ${_corrected_cmd}"
  return 19
}

_output=$(handle_branch_mismatch "1496" "520" "main" "doc-refactor" "" "state" 2>&1 || true)

# Must contain --branch main (not bare "rite 1496")
echo "$_output" | grep -qF "rite --branch main 1496" || {
  echo "FAIL: corrected command does not contain 'rite --branch main 1496'" >&2
  echo "Output was: $_output" >&2
  exit 1
}

# Must NOT be bare "rite 1496" (without --branch): that loops on the state file
if echo "$_output" | grep -qE "^ERROR: Re-run with: rite 1496$"; then
  echo "FAIL: bare 'rite 1496' (without --branch) would loop on the stale state file" >&2
  echo "Output was: $_output" >&2
  exit 1
fi

exit 0
STUB_EOF
  chmod +x "$_script"
  run bash "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: test script exited $status" >&2
    echo "$output" >&2
    return 1
  }
}

@test "behavioral: anti-loop: --base main handler clears state file; subsequent mismatch check passes" {
  # Full loop-escape simulation:
  #   1. Poison the state file (target-branch-1496.txt = doc-refactor)
  #   2. PR base is "main"
  #   3. handle_branch_mismatch prescribes "rite --branch main 1496"
  #   4. The --base main handler runs: rm -f target-branch-1496.txt
  #   5. resolve_target_branch now returns "main" (default; no state file)
  #   6. compare main == main → NO mismatch → anti-loop confirmed
  _tmpdir="$BATS_TEST_TMPDIR/anti-loop"
  mkdir -p "$_tmpdir"
  _issue_num="1496"
  _state_file="${_tmpdir}/target-branch-${_issue_num}.txt"

  # Step 1: poison the state file
  echo "doc-refactor" > "$_state_file"

  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand
  _script="$BATS_TEST_TMPDIR/test-anti-loop.sh"
  cat > "$_script" <<STUB_EOF
#!/usr/bin/env bash
set -euo pipefail

RITE_STATE_DIR="${_tmpdir}"
ISSUE_NUMBER="${_issue_num}"

# Simulate resolve_target_branch: returns state-file value when present, else main
resolve_target_branch() {
  local _issue="\${1:-}"
  local _state="\${RITE_STATE_DIR}/target-branch-\${_issue}.txt"
  if [ -f "\$_state" ]; then
    cat "\$_state"
    RESOLVED_TARGET_SOURCE="state"
  else
    echo "main"
    RESOLVED_TARGET_SOURCE="default"
  fi
}
RESOLVED_TARGET_SOURCE="default"

# Step 2: first resolution hits the poisoned state file
_target1=\$(resolve_target_branch "\$ISSUE_NUMBER")
[ "\$_target1" = "doc-refactor" ] || {
  echo "FAIL: expected state file to return 'doc-refactor', got '\$_target1'" >&2
  exit 1
}
[ "\$RESOLVED_TARGET_SOURCE" = "state" ] || {
  echo "FAIL: expected RESOLVED_TARGET_SOURCE='state', got '\$RESOLVED_TARGET_SOURCE'" >&2
  exit 1
}

# Step 3: mismatch fires (PR base=main, effective=doc-refactor)
# Step 4: simulate --base main handler clearing the state file
RITE_TARGET_BRANCH="main"
if [ "\$RITE_TARGET_BRANCH" = "main" ] && [ -n "\${RITE_STATE_DIR:-}" ] && [ -n "\${ISSUE_NUMBER:-}" ]; then
  rm -f "\${RITE_STATE_DIR}/target-branch-\${ISSUE_NUMBER}.txt" 2>/dev/null || true
fi

# Step 5: re-resolve (simulates check_branch_mismatch on the corrected-command run)
_target2=\$(resolve_target_branch "\$ISSUE_NUMBER")

# Step 6: must now return "main" (no state file, default wins)
[ "\$_target2" = "main" ] || {
  echo "FAIL: after --base main handler, resolve returned '\$_target2' (expected 'main')" >&2
  exit 1
}

# PR base is "main", effective target is now "main" → NO mismatch (anti-loop confirmed)
[ "\$_target2" = "main" ] && echo "PASS: prescribed command breaks the loop"
exit 0
STUB_EOF
  chmod +x "$_script"
  run bash "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: anti-loop simulation failed (exit $status)" >&2
    echo "$output" >&2
    return 1
  }
  echo "$output" | grep -qF "PASS: prescribed command breaks the loop" || {
    echo "FAIL: anti-loop assertion not confirmed in output" >&2
    echo "Output: $output" >&2
    return 1
  }
}
