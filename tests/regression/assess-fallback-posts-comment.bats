#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh
# Regression test for issue #821 (also LeadFlow #435/#431, same night):
# assessment-failure fallback must post the assessment PR comment.
#
# Background:
#   When the LLM assessment call fails (e.g. transient 529 overloaded) but the
#   post-commit gate has blocking findings (GATE_NOW_COUNT > 0),
#   assess-and-resolve.sh's fallback branch exits 2 to force the fix loop.
#   Before the fix, it echoed the [GATE] items only to fd 3 (stdout) and posted
#   NO <!-- sharkrite-assessment --> PR comment — but claude-workflow.sh
#   FIX_REVIEW_MODE reads the assessment EXCLUSIVELY from that PR comment when
#   a PR number is passed. Fix mode died with "No assessment found" → exit 1 →
#   PHASE_FAILED, despite exit 2 correctly requesting the fix loop.
#
#   Fix: _post_gate_fallback_assessment_comment() posts a minimal assessment
#   comment (marker + Summary + `---` + [GATE] ACTIONABLE_NOW items) before
#   the fallback branch exits 2. A failed comment post prints a loud warning
#   and still exits 2.
#
# Tests in this file:
#   1. LLM failure + gate findings → exit 2 AND assessment comment posted
#      containing the marker and the [GATE] item
#   2. Posted comment body survives fix mode's extraction pipeline
#      (`---` strip + ACTIONABLE_NOW awk from claude-workflow.sh)
#   3. gh comment post failure → loud warning, still exit 2
#   4. No gate findings (GATE_NOW_COUNT=0): fallback path unchanged —
#      exit 0, no assessment comment posted
#
# Harness: mirrors tests/integration/assess-and-resolve-dedup.bats — runs
# assess-and-resolve.sh as a subprocess against the stateful gh mock, with a
# mock lib tree whose assess-review-issues.sh stub FAILS (simulated 529).
#
# Verification command:
#   bats tests/regression/assess-fallback-posts-comment.bats

load '../helpers/setup'
load '../helpers/gh-mock'
load '../helpers/gh-mock-state'

# Review with findings so the zero-findings early-exit path is not taken and
# the assessment step actually runs (and fails).
_REVIEW_WITH_FINDINGS='<!-- sharkrite-local-review model:claude-opus-4-8 timestamp:2026-06-01T12:00:00Z -->
## Code Review

Findings: CRITICAL: 0 | HIGH: 1 | MEDIUM: 1 | LOW: 0

### Issue: Input not validated
**Severity:** HIGH
**Location:** lib/core/foo.sh:42

### Issue: Missing docs
**Severity:** MEDIUM
**Location:** docs/README.md:1
'

setup() {
  setup_test_tmpdir

  if ! command -v jq &>/dev/null; then
    skip "jq not available — required for these tests"
  fi

  # --- Stateful gh mock state dir ---
  export GH_MOCK_STATE_DIR="$RITE_TEST_TMPDIR/gh-mock-state"
  setup_gh_mock_state

  # --- Project dirs required by config.sh ---
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/project"
  export RITE_DATA_DIR=".rite"
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/project/.rite/locks"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/project/.rite/state"
  export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/project/.rite/worktrees"
  export RITE_LOG_FILE="$RITE_TEST_TMPDIR/diag.log"
  touch "$RITE_LOG_FILE"

  mkdir -p "$RITE_PROJECT_ROOT/$RITE_DATA_DIR"
  mkdir -p "$RITE_LOCK_DIR"
  mkdir -p "$RITE_STATE_DIR"
  mkdir -p "$RITE_WORKTREE_DIR"

  # --- Mock lib tree with a FAILING assessment stub ---
  export MOCK_LIB_DIR="$RITE_TEST_TMPDIR/mock-lib"
  _setup_mock_lib_tree_failing_assessment

  # --- Mock gh binary ---
  export MOCK_BIN_DIR="$RITE_TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_BIN_DIR"
  cp "$RITE_REPO_ROOT/tests/helpers/gh-mock-binary.sh" "$MOCK_BIN_DIR/gh"
  cp "$RITE_REPO_ROOT/tests/helpers/gh-mock-state.bash" "$MOCK_BIN_DIR/gh-mock-state.bash"
  chmod +x "$MOCK_BIN_DIR/gh"
  export PATH="$MOCK_BIN_DIR:$PATH"

  # --- PR view response (review present, with findings) ---
  export GH_MOCK_PR_VIEW_FILE="$RITE_TEST_TMPDIR/mock-pr-view.json"
  jq -n \
    --arg body "$_REVIEW_WITH_FINDINGS" \
    '{
       "comments": [
         {
           "body": $body,
           "createdAt": "2026-06-01T12:00:00Z",
           "author": {"login": "rite-bot"}
         }
       ],
       "headRefName": "test/feature-branch",
       "title": "Test PR",
       "files": [{"path":"lib/core/foo.sh"},{"path":"docs/README.md"}]
     }' \
  > "$GH_MOCK_PR_VIEW_FILE"

  # Misc config expected by config.sh / assess-and-resolve.sh
  export RITE_LIB_DIR="$MOCK_LIB_DIR"
  export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR/install"
  export RITE_REVIEW_MODEL="claude-opus-4-8"
  export RITE_MAX_RETRIES=3
  export RITE_DEDUP_BACKOFF=0
  export RITE_GH_MAX_RETRIES=1
  export RITE_DRY_RUN=false
  export RITE_VERBOSE=false
  export RITE_GH_RETRY_MAX_SLEEP=0

  _diag() { :; }
  export -f _diag 2>/dev/null || true
  is_verbose() { false; }
  export -f is_verbose 2>/dev/null || true
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Mock lib tree where assess-review-issues.sh FAILS — simulating the live #821
# failure (Anthropic 529 overloaded → assessment exit 1, no output).
_setup_mock_lib_tree_failing_assessment() {
  mkdir -p "$MOCK_LIB_DIR/core"
  mkdir -p "$MOCK_LIB_DIR/utils"

  for _f in "$RITE_REPO_ROOT/lib/utils/"*.sh; do
    ln -sf "$_f" "$MOCK_LIB_DIR/utils/$(basename "$_f")"
  done
  for _f in "$RITE_REPO_ROOT/lib/core/"*.sh; do
    ln -sf "$_f" "$MOCK_LIB_DIR/core/$(basename "$_f")"
  done

  # Override: assess-review-issues.sh — FAILS with a 529-style error.
  # CRITICAL: rm -f first to break the symlink from the loop above; writing
  # through the symlink would overwrite the real production file (the exact
  # accident documented in assess-and-resolve-dedup.bats / PR #260).
  rm -f "$MOCK_LIB_DIR/core/assess-review-issues.sh"
  cat > "$MOCK_LIB_DIR/core/assess-review-issues.sh" << 'ASSESS_STUB_EOF'
#!/usr/bin/env bash
# Stub assess-review-issues.sh: simulates a transient LLM failure (529).
set -euo pipefail
echo 'API Error: 529 {"type":"error","error":{"type":"overloaded_error"}}' >&2
exit 1
ASSESS_STUB_EOF
  chmod +x "$MOCK_LIB_DIR/core/assess-review-issues.sh"

  # Override: format-review.sh — no-op display stub.
  rm -f "$MOCK_LIB_DIR/utils/format-review.sh"
  cat > "$MOCK_LIB_DIR/utils/format-review.sh" << 'FORMAT_STUB_EOF'
#!/usr/bin/env bash
# Stub format-review.sh: no-op.
exit 0
FORMAT_STUB_EOF
  chmod +x "$MOCK_LIB_DIR/utils/format-review.sh"
}

# Writes a gate findings JSON with one blocking bats failure and points
# RITE_GATE_FINDINGS at it (the same channel the live #821 run used).
# assess-and-resolve.sh deletes the file after consumption, so each test
# writes its own copy.
_write_gate_findings_with_failure() {
  export RITE_GATE_FINDINGS="$RITE_TEST_TMPDIR/gate-findings.json"
  printf '%s\n' \
    '{"lint":[],"tests":[{"file":"tests/regression/example.bats","test_name":"add_approved_blocker concurrency timeout","reason":"assertion failed"}],"exit_code":1}' \
    > "$RITE_GATE_FINDINGS"
}

# run_assess_and_resolve PR_NUMBER ISSUE_NUMBER [RETRY_COUNT]
run_assess_and_resolve() {
  local _pr="${1:-42}"
  local _issue="${2:-10}"
  local _retry="${3:-0}"
  run bash "$RITE_REPO_ROOT/lib/core/assess-and-resolve.sh" \
    "$_pr" "$_issue" "$_retry" --auto
}

# Returns the recorded comment bodies for a PR (newline-joined) from the
# stateful mock, or empty when none were posted.
_recorded_comments_for_pr() {
  local _pr="$1"
  jq -r --arg pr "$_pr" \
    'if has($pr) then [.[$pr][].body] | join("\n=====\n") else "" end' \
    "$GH_MOCK_STATE_DIR/pr-comments.json"
}

# ---------------------------------------------------------------------------
# 1. LLM failure + gate findings: assessment comment posted, exit 2
# ---------------------------------------------------------------------------

@test "assessment failure + gate findings: posts assessment comment with marker and [GATE] items, exits 2" {
  _write_gate_findings_with_failure

  run_assess_and_resolve 70 35

  [ "$status" -eq 2 ] || {
    echo "FAIL: expected exit 2 (gate-forced fix loop), got $status"
    echo "Output: ${output:0:1500}"
    false
  }

  # The fd-3 stdout contract must still hold (workflow-runner pipes this).
  echo "$output" | grep -q "^### \[GATE\] bats failure: tests/regression/example.bats - ACTIONABLE_NOW$" || {
    echo "FAIL: exit-2 stdout missing the [GATE] ACTIONABLE_NOW item"
    echo "Output: ${output:0:1500}"
    false
  }

  # An assessment comment must have been posted to the PR (the #821 contract).
  local _bodies
  _bodies=$(_recorded_comments_for_pr 70)
  [ -n "$_bodies" ] || {
    echo "FAIL: no PR comment was posted — fix mode will die with 'No assessment found'"
    cat "$GH_MOCK_STATE_DIR/pr-comments.json"
    false
  }

  echo "$_bodies" | grep -q "<!-- sharkrite-assessment" || {
    echo "FAIL: posted comment missing the sharkrite-assessment marker"
    echo "Comment: ${_bodies:0:800}"
    false
  }

  # Comment must carry the [GATE] item in the structured format fix mode parses.
  echo "$_bodies" | grep -q "^### \[GATE\] bats failure: tests/regression/example.bats - ACTIONABLE_NOW$" || {
    echo "FAIL: posted comment missing the structured [GATE] ACTIONABLE_NOW item"
    echo "Comment: ${_bodies:0:800}"
    false
  }
  echo "$_bodies" | grep -q "add_approved_blocker concurrency timeout" || {
    echo "FAIL: posted comment missing the failing test name"
    echo "Comment: ${_bodies:0:800}"
    false
  }
}

# ---------------------------------------------------------------------------
# 2. Posted comment survives fix mode's extraction pipeline
# ---------------------------------------------------------------------------

@test "posted fallback comment is parseable by claude-workflow.sh fix-mode extraction" {
  _write_gate_findings_with_failure

  run_assess_and_resolve 71 36
  [ "$status" -eq 2 ]

  local _body
  _body=$(jq -r --arg pr "71" \
    'if has($pr) then .[$pr][0].body else "" end' \
    "$GH_MOCK_STATE_DIR/pr-comments.json")
  [ -n "$_body" ] || {
    echo "FAIL: no comment recorded for PR #71"
    false
  }

  # Replicate claude-workflow.sh FIX_REVIEW_MODE processing exactly:
  # (a) strip everything before the first `---` separator line
  local _content="$_body"
  if echo "$_content" | grep -q "^---$"; then
    _content=$(echo "$_content" | sed -n '/^---$/,$p' | tail -n +2 || true)
  else
    echo "FAIL: comment body has no ^---$ separator — fix mode's header strip contract broken"
    echo "Comment: ${_body:0:800}"
    false
  fi

  # (b) the ACTIONABLE_NOW awk from claude-workflow.sh (verbatim)
  local _now_items
  _now_items=$(echo "$_content" | awk '/^### .* - ACTIONABLE_NOW$/ { printing=1 } /^### .* - (ACTIONABLE_LATER|DISMISSED)$/ { printing=0 } /^(✅|───|━━)/ { printing=0 } printing { print }' || true)

  [ -n "$_now_items" ] || {
    echo "FAIL: fix-mode awk extracted zero ACTIONABLE_NOW items from the comment"
    echo "Stripped content: ${_content:0:800}"
    false
  }

  local _count
  _count=$(echo "$_now_items" | grep -c "^### .* - ACTIONABLE_NOW" || true)
  [ "$_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 ACTIONABLE_NOW item after extraction, got $_count"
    echo "Extracted: ${_now_items:0:800}"
    false
  }
  echo "$_now_items" | grep -q "add_approved_blocker concurrency timeout" || {
    echo "FAIL: extracted item lost the failing test name"
    echo "Extracted: ${_now_items:0:800}"
    false
  }
}

# ---------------------------------------------------------------------------
# 3. gh comment post failure: loud warning, still exit 2
# ---------------------------------------------------------------------------

@test "comment post failure: prints loud warning naming the failed post, still exits 2" {
  _write_gate_findings_with_failure

  # Prepend a gh wrapper that fails ONLY `gh pr comment` and delegates
  # everything else to the stateful mock binary.
  local _fail_bin_dir="$RITE_TEST_TMPDIR/fail-bin"
  mkdir -p "$_fail_bin_dir"
  cat > "$_fail_bin_dir/gh" << WRAPPER_EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "comment" ]; then
  echo "gh: simulated comment outage" >&2
  exit 1
fi
exec "$MOCK_BIN_DIR/gh" "\$@"
WRAPPER_EOF
  chmod +x "$_fail_bin_dir/gh"
  export PATH="$_fail_bin_dir:$PATH"

  run_assess_and_resolve 72 37

  # Exit code contract: still 2 — the fix loop is forced by objective gate
  # failures whether or not the comment landed.
  [ "$status" -eq 2 ] || {
    echo "FAIL: expected exit 2 even when the comment post fails, got $status"
    echo "Output: ${output:0:1500}"
    false
  }

  # The warning must say the comment post itself failed (not a generic error).
  echo "$output" | grep -qi "FAILED to post gate-findings assessment comment" || {
    echo "FAIL: output does not contain the loud comment-post-failure warning"
    echo "Output: ${output:0:1500}"
    false
  }

  # No comment recorded in the mock (the wrapper blocked it).
  local _bodies
  _bodies=$(_recorded_comments_for_pr 72)
  [ -z "$_bodies" ] || {
    echo "FAIL: expected no recorded comment when gh pr comment fails"
    false
  }
}

# ---------------------------------------------------------------------------
# 4. No gate findings: fallback path unchanged (exit 0, no comment)
# ---------------------------------------------------------------------------

@test "assessment failure with NO gate findings: fallback unchanged — exit 0, no assessment comment" {
  # No RITE_GATE_FINDINGS file → GATE_NOW_COUNT=0. The fallback parses raw
  # review counts (0 for this fixture's format), reaches the follow-up gate
  # with nothing to create, and exits 0 exactly as before the #821 fix.
  unset RITE_GATE_FINDINGS 2>/dev/null || true

  run_assess_and_resolve 73 38

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (no-gate fallback path unchanged), got $status"
    echo "Output: ${output:0:1500}"
    false
  }

  echo "$output" | grep -qi "Falling back to raw review count" || {
    echo "FAIL: output missing the assessment-failure fallback message"
    echo "Output: ${output:0:1500}"
    false
  }

  # No assessment comment must be posted on this path.
  local _bodies
  _bodies=$(_recorded_comments_for_pr 73)
  echo "$_bodies" | grep -q "<!-- sharkrite-assessment" && {
    echo "FAIL: no-gate fallback path posted an assessment comment (behavior change)"
    echo "Comment: ${_bodies:0:800}"
    false
  }
  true
}
