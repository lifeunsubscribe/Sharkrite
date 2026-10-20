#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Regression (#1128): supervised dev-flow commit/push prompts consolidated into
# one — "Commit and push N file(s)? [y/n/e]".  The five old micro-prompts
# ("Run tests before committing?", "Create commit?", "Accept this message?",
# "Push to remote?", plus the salvage pair) are gone.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  WF="${RITE_LIB_DIR}/core/claude-workflow.sh"
  set +u; set +o pipefail
}

# ---------------------------------------------------------------------------
# Structural: old prompts are absent
# ---------------------------------------------------------------------------

@test "structural: 'Run tests before committing?' prompt is gone" {
  count=$(grep -c 'Run tests before committing' "$WF" || true)
  [ "$count" -eq 0 ]
}

@test "structural: 'Create commit?' prompt is gone" {
  count=$(grep -c 'Create commit?' "$WF" || true)
  [ "$count" -eq 0 ]
}

@test "structural: 'Accept this message?' prompt is gone" {
  count=$(grep -c 'Accept this message?' "$WF" || true)
  [ "$count" -eq 0 ]
}

@test "structural: standalone 'Push to remote?' prompt is gone" {
  # The old 'Push to remote?' read -p prompts are deleted; any remaining match
  # must not be a read -p line (comments or output lines are fine).
  count=$(grep -c 'read -p.*Push to remote' "$WF" || true)
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Structural: new consolidated prompt exists in both paths
# ---------------------------------------------------------------------------

@test "structural: main flow has single 'Commit and push N file(s)?' prompt" {
  count=$(grep -c 'Commit and push.*file(s).*\[y/n/e\]' "$WF" || true)
  [ "$count" -ge 1 ]
}

@test "structural: salvage path has 'Commit and push N change(s) before exiting?' prompt" {
  count=$(grep -c 'Commit and push.*change(s) before exiting' "$WF" || true)
  [ "$count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Structural: read -p commit prompt count is exactly 3
# (2 consolidated + 1 "Continue with commit anyway?" failure-override in auto mode)
# ---------------------------------------------------------------------------

@test "structural: exactly 3 'read -p.*[Cc]ommit' lines in total" {
  count=$(grep -c 'read -p.*[Cc]ommit' "$WF" || true)
  [ "$count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# Structural: e-path loop and case handling present in main flow
# ---------------------------------------------------------------------------

@test "structural: main flow has y/n/e case statement" {
  fn_body=$(sed -n '/Commit and push.*file(s).*\[y\/n\/e\]/,/done$/p' "$WF" | head -40)
  echo "$fn_body" | grep -q 'e|E'
  echo "$fn_body" | grep -q 'n|N'
}

# ---------------------------------------------------------------------------
# Structural: y/n/e behavioral contracts — verified via code inspection
# (Main-flow commit+push body is inline, not a callable function; structural
# verification is the feasible coverage until it is extracted — deferred to #1169)
# ---------------------------------------------------------------------------

@test "structural: n path calls 'exit 0' (aborts without committing)" {
  # The n|N branch must call exit 0 so a declined commit is a clean exit,
  # not a failure — matching the old "Create commit? → n" behaviour.
  fn_body=$(sed -n '/Commit and push.*file(s).*\[y\/n\/e\]/,/done$/p' "$WF" | head -30)
  echo "$fn_body" | grep -A3 'n|N)' | grep -q 'exit 0'
}

@test "structural: e path uses read -re (backslash-safe message editing)" {
  # read -e alone eats backslashes in input; -r is required for correct passthrough.
  fn_body=$(sed -n '/Commit and push.*file(s).*\[y\/n\/e\]/,/done$/p' "$WF" | head -50)
  echo "$fn_body" | grep -q 'read -re'
}

@test "structural: consolidated read prompts default to n on EOF (EOF-safe)" {
  # Under set -e, an EOF on read -p returns 1; guarding with 'if ! read' and
  # defaulting to 'n' ensures the loop exits cleanly instead of busy-looping
  # or aborting the handler before lock release. Both consolidated prompts
  # must use the if-not-read pattern.
  count=$(grep -c 'if ! read -p.*\[y/n/e\]' "$WF" || true)
  [ "$count" -ge 2 ]
}

@test "structural: auto mode bypasses the supervised commit prompt" {
  # The 'Commit and push ... file(s)? [y/n/e]' prompt must be inside
  # 'if [ "$AUTO_MODE" = false ]' — auto runs are unaffected by this issue.
  prompt_line=$(grep -n 'Commit and push.*file(s).*\[y\/n\/e\]' "$WF" | head -1 | cut -d: -f1)
  [ -n "$prompt_line" ]
  # Find the nearest preceding guard line — it must test AUTO_MODE = false, not
  # just reference AUTO_MODE (which would be vacuous since any earlier reference
  # to AUTO_MODE passes the grep even without the = false guard).
  context=$(sed -n "1,${prompt_line}p" "$WF" | grep 'AUTO_MODE' | tail -1)
  echo "$context" | grep -q 'AUTO_MODE.*=.*false\|=.*false.*AUTO_MODE'
}
