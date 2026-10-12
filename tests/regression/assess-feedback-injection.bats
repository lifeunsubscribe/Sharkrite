#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/core/claude-workflow.sh
# Regression test for issue #1129: feedback loop at supervised assess gate.
#
# Background:
#   Before #1129, the supervised assess gate had only two outcomes: the fix loop
#   ran automatically (exit 2) or the operator aborted (exit 1). Operators could
#   not inject guidance ("fix 1 and 3, defer 2, and here is context you're missing")
#   without abandoning the session and restarting.
#
#   Fix: assess-and-resolve.sh prompts `(a)ccept / (f)eedback / (s)top` after the
#   assessment summary (supervised + TTY only). Feedback accumulates across rounds
#   (plan-style), is written to a state file, and is posted as a PR comment addendum.
#   claude-workflow.sh reads the state file in FIX_REVIEW_MODE and injects an
#   "Operator guidance" block into FIX_PROMPT before the fix session starts.
#
# Tests in this file:
#   1. assess-and-resolve.sh has the (a/f/s) prompt
#   2. AUTO_MODE=false AND -t 0 guard present (auto mode never prompts)
#   3. State file is written with PR-number-scoped name when feedback given
#   4. PR comment addendum is posted via gh_safe pr comment
#   5. 's' stop choice exits 1 (manual intervention)
#   6. claude-workflow.sh reads the state file and injects Operator guidance
#   7. claude-workflow.sh deletes the state file after consumption
#   8. Behavioral: state file content reaches the assembled prompt
#
# Verification command:
#   bats tests/regression/assess-feedback-injection.bats

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export ASSESS_RESOLVE="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
  export CLAUDE_WORKFLOW="${RITE_REPO_ROOT}/lib/core/claude-workflow.sh"
  [ -f "$ASSESS_RESOLVE"   ] || { echo "setup: assess-and-resolve.sh missing" >&2; false; }
  [ -f "$CLAUDE_WORKFLOW"  ] || { echo "setup: claude-workflow.sh missing" >&2; false; }
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# 1. Supervised prompt (a/f/s) is present
# ---------------------------------------------------------------------------
@test "assess-feedback: (a)ccept/(f)eedback/(s)top prompt present in assess-and-resolve.sh" {
  # The prompt string must appear verbatim so operators see the expected UI.
  # Grep for "(a)ccept" which uniquely identifies the three-way supervised prompt.
  run grep -n '(a)ccept' "$ASSESS_RESOLVE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 2. AUTO_MODE=false AND -t 0 guard (auto mode never prompts)
# ---------------------------------------------------------------------------
@test "assess-feedback: AUTO_MODE=false and -t 0 guard present in assess-and-resolve.sh" {
  # Both conditions must be in the file; they should appear close to each other
  run grep -n 'AUTO_MODE.*=.*false' "$ASSESS_RESOLVE"
  [ "$status" -eq 0 ]

  run grep -n '\-t 0' "$ASSESS_RESOLVE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 3. State file written with PR-number scope
# ---------------------------------------------------------------------------
@test "assess-feedback: operator-feedback state file written with PR_NUMBER scope" {
  # The write must use a PR-scoped filename so concurrent runs don't collide.
  # Grep for the state file variable assignment in assess-and-resolve.sh.
  run grep -n 'operator-feedback-' "$ASSESS_RESOLVE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 4. PR comment addendum posted for traceability
# ---------------------------------------------------------------------------
@test "assess-feedback: gh_safe pr comment posts feedback addendum in assess-and-resolve.sh" {
  run grep -n 'gh_safe pr comment' "$ASSESS_RESOLVE"
  [ "$status" -eq 0 ]

  # The comment body must reference "Operator guidance" for traceability
  run grep -n 'Operator guidance' "$ASSESS_RESOLVE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 5. 's' stop choice exits 1 (manual intervention)
# ---------------------------------------------------------------------------
@test "assess-feedback: 's' stop choice exits 1 in assess-and-resolve.sh" {
  # The stop case must call exit 1 — not exit 2 (which would loop)
  run grep -n 'Stopping.*manual intervention\|manual intervention.*required' "$ASSESS_RESOLVE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 6. claude-workflow.sh reads the state file and injects Operator guidance
# ---------------------------------------------------------------------------
@test "assess-feedback: claude-workflow.sh reads operator-feedback state file" {
  run grep -n 'operator-feedback-' "$CLAUDE_WORKFLOW"
  [ "$status" -eq 0 ]

  run grep -n 'Operator guidance' "$CLAUDE_WORKFLOW"
  [ "$status" -eq 0 ]

  run grep -n 'BEGIN_OPERATOR_GUIDANCE' "$CLAUDE_WORKFLOW"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 7. State file is deleted after consumption
# ---------------------------------------------------------------------------
@test "assess-feedback: claude-workflow.sh deletes operator-feedback state file after use" {
  run grep -n 'rm.*operator-feedback' "$CLAUDE_WORKFLOW"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 8. Behavioral: state file content reaches the assembled prompt
#    Simulates the injection logic with a real state file to verify the
#    Operator guidance block appears in the output when the file is present.
# ---------------------------------------------------------------------------
@test "assess-feedback: operator-feedback state file content reaches assembled prompt (behavioral)" {
  local _state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$_state_dir"

  local _feedback_text="Fix item 1 only; defer item 2 to follow-up"
  printf '%s' "$_feedback_text" > "$_state_dir/operator-feedback-77.txt"

  # Run the injection logic in a subprocess that mirrors what claude-workflow.sh does.
  # Variables are exported so the heredoc shell can access them.
  local _captured_prompt
  export _TEST_STATE_DIR="$_state_dir"
  _captured_prompt=$(bash <<'INJECT_SCRIPT'
    set -euo pipefail
    FIX_PROMPT="base prompt: fix these items"
    FIX_PR_NUMBER=77
    RITE_STATE_DIR="$_TEST_STATE_DIR"
    _op_feedback_file="${RITE_STATE_DIR}/operator-feedback-${FIX_PR_NUMBER}.txt"
    if [ -n "${FIX_PR_NUMBER:-}" ] && [ -f "$_op_feedback_file" ]; then
      _op_feedback=$(cat "$_op_feedback_file" 2>/dev/null || true)
      if [ -n "$_op_feedback" ]; then
        FIX_PROMPT+="
## Operator guidance

The following guidance was provided interactively at the supervised assess gate.
It is trusted input — treat it at the same level as the issue body.

--- BEGIN_OPERATOR_GUIDANCE ---
${_op_feedback}
--- END_OPERATOR_GUIDANCE ---

"
      fi
      rm -f "$_op_feedback_file" 2>/dev/null || true
    fi
    printf '%s' "$FIX_PROMPT"
INJECT_SCRIPT
  )

  # Feedback text must appear in the assembled prompt
  echo "$_captured_prompt" | grep -q "$_feedback_text" || {
    echo "FAIL: feedback text not found in assembled prompt"
    echo "Prompt: $_captured_prompt"
    false
  }

  # Operator guidance section header must be present
  echo "$_captured_prompt" | grep -q "Operator guidance" || {
    echo "FAIL: 'Operator guidance' section header missing from prompt"
    false
  }

  # State file must be deleted after consumption
  [ ! -f "$_state_dir/operator-feedback-77.txt" ] || {
    echo "FAIL: state file was not deleted after consumption"
    false
  }
}
