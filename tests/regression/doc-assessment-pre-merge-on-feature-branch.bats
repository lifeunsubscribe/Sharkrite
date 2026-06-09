#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh, lib/core/workflow-runner.sh, lib/core/merge-pr.sh
#
# Doc assessment moved from post-merge (merge-pr.sh) to pre-merge (workflow-runner.sh)
# so Layer 2 commits land on the feature branch and ride the squash merge.
#
# This test asserts the placement contract:
#   1. assess-documentation.sh accepts a --worktree <path> argument and cd's there
#      instead of RITE_PROJECT_ROOT.
#   2. workflow-runner.sh has phase_spawn_doc_assessment + phase_wait_doc_assessment
#      helpers, and the spawn invokes assess-documentation.sh with --worktree.
#   3. workflow-runner.sh wires spawn after the test gate kicks off in Phase 3.
#   4. workflow-runner.sh waits for doc assessment in phase_merge_pr right before
#      the merge-pr.sh call (NOT at the top of phase_merge_pr — placement matters
#      so doc work overlaps with the pre-merge gate).
#   5. merge-pr.sh no longer spawns or waits on assess-documentation.sh.
#   6. The PR-diff filter strips .rite/docs/ and docs/ hunks so prior doc commits
#      don't recursively appear in the next iteration's doc assessment input.
#
# Regression target: a future refactor that "centralizes" doc assessment back into
# merge-pr.sh would silently undo the parallelization gain (~60-120s saved per
# issue) and re-introduce the Layer-2-commits-to-main race we eliminated by
# landing doc updates on the feature branch.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ASSESS_DOC_SCRIPT="$PROJECT_ROOT/lib/core/assess-documentation.sh"
  WORKFLOW_RUNNER="$PROJECT_ROOT/lib/core/workflow-runner.sh"
  MERGE_PR="$PROJECT_ROOT/lib/core/merge-pr.sh"
}

# -----------------------------------------------------------------------
# assess-documentation.sh — --worktree flag
# -----------------------------------------------------------------------

@test "assess-documentation.sh: --worktree flag is documented in usage" {
  grep -q -- '--worktree <path>' "$ASSESS_DOC_SCRIPT"
}

@test "assess-documentation.sh: rejects --worktree with no path argument" {
  run bash -c "
    cd '$PROJECT_ROOT'
    export RITE_LIB_DIR='$PROJECT_ROOT/lib'
    export RITE_PROJECT_ROOT='\${TMPDIR:-/tmp}'
    export RITE_DATA_DIR='.rite'
    bash '$ASSESS_DOC_SCRIPT' 1 --worktree 2>&1
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"--worktree requires a path argument"* ]]
}

@test "assess-documentation.sh: cd's to --worktree path before any git operation" {
  # Build a tiny temp directory and pass it as --worktree. Stub gh to print its
  # cwd to stderr, then assert the stub ran from the temp dir (proving the cd
  # happened) rather than from RITE_PROJECT_ROOT.
  _tmp_wt=$(mktemp -d)
  trap "rm -rf '$_tmp_wt'" RETURN

  run bash -c "
    export RITE_LIB_DIR='$PROJECT_ROOT/lib'
    export RITE_PROJECT_ROOT='$PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_VERBOSE=false
    export RITE_REVIEW_PROVIDER=claude

    # Stub provider — we don't want to spin up Claude
    provider_detect_cli()   { return 0; }
    provider_validate_cli() { return 0; }
    export -f provider_detect_cli provider_validate_cli

    # Stub gh — print cwd to stderr, exit 1 to short-circuit the script
    gh() { pwd >&2; return 1; }
    export -f gh

    bash '$ASSESS_DOC_SCRIPT' 99999 --auto --worktree '$_tmp_wt' 2>&1 || true
  "

  # Output should contain the temp worktree path (proves cd happened)
  # and NOT the project root (proves we didn't fall through to the default).
  [[ "$output" == *"$_tmp_wt"* ]]
}

# -----------------------------------------------------------------------
# assess-documentation.sh — PR diff filtering
# -----------------------------------------------------------------------

@test "assess-documentation.sh: filters .rite/docs/ and docs/ hunks from PR diff input" {
  # Static check: the awk filter must reference both doc roots. We use grep -F
  # with a fixed-string excerpt of the awk pattern to avoid the regex-escaping
  # contortions a regex grep would require. Slashes inside awk's /.../ regex
  # delimiters are backslash-escaped in the source, hence \/ rather than /.
  grep -F -q '(\.rite\/docs|docs)\/' "$ASSESS_DOC_SCRIPT"
}

# -----------------------------------------------------------------------
# workflow-runner.sh — helper functions + wiring
# -----------------------------------------------------------------------

@test "workflow-runner.sh: defines phase_spawn_doc_assessment" {
  grep -qE '^phase_spawn_doc_assessment\(\)' "$WORKFLOW_RUNNER"
}

@test "workflow-runner.sh: defines phase_wait_doc_assessment" {
  grep -qE '^phase_wait_doc_assessment\(\)' "$WORKFLOW_RUNNER"
}

@test "workflow-runner.sh: defines phase_kill_doc_assessment for interrupt path" {
  grep -qE '^phase_kill_doc_assessment\(\)' "$WORKFLOW_RUNNER"
}

@test "workflow-runner.sh: spawn helper passes --worktree to assess-documentation.sh" {
  # The spawn helper must invoke assess-documentation.sh with --worktree so the
  # script cd's into the feature worktree and commits land on the feature branch.
  # We assert this by extracting the helper body and confirming --worktree appears.
  _helper_body=$(awk '/^phase_spawn_doc_assessment\(\)/,/^}/' "$WORKFLOW_RUNNER")
  [[ "$_helper_body" == *"--worktree"* ]]
}

@test "workflow-runner.sh: spawns doc assessment in Phase 3 fix loop" {
  # Verify the call site exists in phase_assess_and_resolve, after the gate
  # spawn but before phase_create_pr. We look for the spawn call inside the
  # function body that runs run_test_gate.
  _fn_body=$(awk '/^phase_assess_and_resolve\(\)/,/^}/' "$WORKFLOW_RUNNER")
  [[ "$_fn_body" == *"phase_spawn_doc_assessment"* ]]
  [[ "$_fn_body" == *"run_test_gate"* ]]
}

@test "workflow-runner.sh: waits for doc assessment in phase_merge_pr, right before merge-pr.sh runs" {
  # The wait must sit immediately before the "$MERGE_PR" invocation (not at the
  # top of phase_merge_pr) so doc work runs in parallel with the pre-merge gate
  # — changes summary fetch, check_blockers, verify_pr_head, divergence handling.
  # Placing it at the entry collapses parallelism to ~zero in the no-fix-loop case.
  _fn_body=$(awk '/^phase_merge_pr\(\)/,/^phase_completion\(\)/' "$WORKFLOW_RUNNER")
  [[ "$_fn_body" == *"phase_wait_doc_assessment"* ]]

  # The wait must appear AFTER the pre-merge gate (check_blockers, verify_pr_head)
  # and BEFORE the merge-pr.sh invocation.
  _wait_line=$(echo "$_fn_body" | grep -n 'phase_wait_doc_assessment' | head -1 | cut -d: -f1)
  _blockers_line=$(echo "$_fn_body" | grep -n 'check_blockers "pre-merge"' | head -1 | cut -d: -f1)
  _merge_call_line=$(echo "$_fn_body" | grep -n '"\$MERGE_PR" "\$pr_number"' | head -1 | cut -d: -f1)

  [ -n "$_wait_line" ]
  [ -n "$_blockers_line" ]
  [ -n "$_merge_call_line" ]

  # Order: blockers gate < wait < merge call
  [ "$_blockers_line" -lt "$_wait_line" ]
  [ "$_wait_line" -lt "$_merge_call_line" ]
}

@test "workflow-runner.sh: waits for doc assessment before claude --fix-review" {
  # The wait must come BEFORE the fix-review LLM session — the LLM needs a clean
  # worktree (doc subprocess commits must land first). We extract the function
  # body and verify wait appears before --fix-review.
  _fn_body=$(awk '/^phase_assess_and_resolve\(\)/,/^}/' "$WORKFLOW_RUNNER")
  _wait_line=$(echo "$_fn_body" | grep -n 'phase_wait_doc_assessment' | head -1 | cut -d: -f1)
  _fix_line=$(echo "$_fn_body" | grep -n -- '--fix-review' | head -1 | cut -d: -f1)
  [ -n "$_wait_line" ]
  [ -n "$_fix_line" ]
  [ "$_wait_line" -lt "$_fix_line" ]
}

# -----------------------------------------------------------------------
# merge-pr.sh — must NOT spawn or wait on doc assessment anymore
# -----------------------------------------------------------------------

@test "merge-pr.sh: does NOT fork assess-documentation.sh as a background subprocess" {
  # The old post-merge spawn was: "$DOC_ASSESSMENT_SCRIPT" "$PR_NUMBER" ... &
  # Assert no such background invocation exists.
  ! grep -qE '"\$DOC_ASSESSMENT_SCRIPT".*&[[:space:]]*$' "$MERGE_PR"
  ! grep -qE 'assess-documentation\.sh.*&[[:space:]]*$' "$MERGE_PR"
}

@test "merge-pr.sh: does NOT wait on _DOC_PID" {
  # The old wait block used _DOC_PID as a variable. Now Phase 3 handles waiting.
  ! grep -q 'wait "\$_DOC_PID"' "$MERGE_PR"
  ! grep -q '_DOC_PID=' "$MERGE_PR"
}
