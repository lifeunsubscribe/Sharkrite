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

# ---------------------------------------------------------------------------
# Helpers for success-path tests (issues #849)
# ---------------------------------------------------------------------------

# Installs a SUCCEEDING assess-review-issues.sh stub that outputs assessment
# items in the structured format used by assess-and-resolve.sh and exits 0.
# The stub's output controls which decision branch assess-and-resolve.sh takes:
#   - all-dismissed:  ASSESSMENT_TYPE=dismissed → all items DISMISSED
#   - later-only:     ASSESSMENT_TYPE=later     → all items ACTIONABLE_LATER
#
# The stub also simulates the assess-review-issues.sh PR comment post so the
# stateful mock records an initial comment (without gate items) — allowing the
# test to verify that _post_gate_fallback_assessment_comment posts a SECOND
# comment that carries the gate items.
#
# Caller must set ASSESSMENT_TYPE before invoking run_assess_and_resolve.
_setup_mock_lib_tree_succeeding_assessment() {
  mkdir -p "$MOCK_LIB_DIR/core"
  mkdir -p "$MOCK_LIB_DIR/utils"

  for _f in "$RITE_REPO_ROOT/lib/utils/"*.sh; do
    ln -sf "$_f" "$MOCK_LIB_DIR/utils/$(basename "$_f")"
  done
  for _f in "$RITE_REPO_ROOT/lib/core/"*.sh; do
    ln -sf "$_f" "$MOCK_LIB_DIR/core/$(basename "$_f")"
  done

  # Override: assess-review-issues.sh — outputs well-formed assessment and exits 0.
  # CRITICAL: rm -f first to break the symlink from the loop above.
  rm -f "$MOCK_LIB_DIR/core/assess-review-issues.sh"
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must be expanded
  cat > "$MOCK_LIB_DIR/core/assess-review-issues.sh" << ASSESS_SUCCESS_STUB_EOF
#!/usr/bin/env bash
# Stub assess-review-issues.sh: succeeds with a structured assessment.
# ASSESSMENT_TYPE controls the output:
#   dismissed  → one DISMISSED item
#   later      → one ACTIONABLE_LATER item
set -euo pipefail

_type="\${ASSESSMENT_TYPE:-dismissed}"

# Emit a minimal but well-formed assessment comment to the PR (simulating the
# real assess-review-issues.sh behaviour at line ~822) so tests can verify
# that the gate-fallback comment is posted AS A SECOND comment afterward.
_ts=\$(date -u +"%Y-%m-%dT%H:%M:%SZ")
_pr="\${1:-0}"
_body_file=\$(mktemp)
if [ "\$_type" = "later" ]; then
  printf '%s' "<!-- sharkrite-assessment pr:\${_pr} iteration:1 timestamp:\${_ts} -->

## Sharkrite Assessment
### Summary
- **ACTIONABLE_NOW:** 0 items
- **ACTIONABLE_LATER:** 1 items

---

### Missing docs - ACTIONABLE_LATER
**Severity:** LOW
**Location:** docs/README.md:1
" > "\$_body_file"
else
  printf '%s' "<!-- sharkrite-assessment pr:\${_pr} iteration:1 timestamp:\${_ts} -->

## Sharkrite Assessment
### Summary
- **ACTIONABLE_NOW:** 0 items
- **ACTIONABLE_LATER:** 0 items

---

### Missing docs - DISMISSED
**Severity:** LOW
**Location:** docs/README.md:1
" > "\$_body_file"
fi
# Post the comment via gh (captured by the stateful mock).
gh pr comment "\$_pr" --body-file "\$_body_file" >/dev/null 2>&1 || true
rm -f "\$_body_file"

# Output the assessment result to stdout (what assess-and-resolve.sh captures).
if [ "\$_type" = "later" ]; then
  printf '%s\n' \
    "### Missing docs - ACTIONABLE_LATER" \
    "**Severity:** LOW" \
    "**Location:** docs/README.md:1"
else
  printf '%s\n' \
    "### Missing docs - DISMISSED" \
    "**Severity:** LOW" \
    "**Location:** docs/README.md:1"
fi
exit 0
ASSESS_SUCCESS_STUB_EOF
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

# ---------------------------------------------------------------------------
# 5. Success path: all-dismissed + gate findings → posts gate comment, exits 2
# ---------------------------------------------------------------------------

@test "success-path all-dismissed + gate findings: posts gate assessment comment and exits 2" {
  # Replace the failing-assessment mock lib with the succeeding one.
  rm -rf "$MOCK_LIB_DIR"
  export ASSESSMENT_TYPE=dismissed
  _setup_mock_lib_tree_succeeding_assessment

  _write_gate_findings_with_failure

  run_assess_and_resolve 80 45

  [ "$status" -eq 2 ] || {
    echo "FAIL: expected exit 2 (gate-forced fix loop), got $status"
    echo "Output: ${output:0:1500}"
    false
  }

  # Gate comment must have been posted (the #849 contract).
  local _bodies
  _bodies=$(_recorded_comments_for_pr 80)
  [ -n "$_bodies" ] || {
    echo "FAIL: no PR comment was posted — fix mode will die with 'No assessment found'"
    cat "$GH_MOCK_STATE_DIR/pr-comments.json"
    false
  }

  # The LAST comment must carry the gate items (posted by _post_gate_fallback_assessment_comment).
  local _last_comment
  _last_comment=$(jq -r --arg pr "80" \
    'if has($pr) then .[$pr][-1].body else "" end' \
    "$GH_MOCK_STATE_DIR/pr-comments.json")

  echo "$_last_comment" | grep -q "<!-- sharkrite-assessment" || {
    echo "FAIL: last comment missing the sharkrite-assessment marker"
    echo "Comment: ${_last_comment:0:800}"
    false
  }
  echo "$_last_comment" | grep -q "^### \[GATE\] bats failure: tests/regression/example.bats - ACTIONABLE_NOW$" || {
    echo "FAIL: last comment missing the structured [GATE] ACTIONABLE_NOW item"
    echo "Comment: ${_last_comment:0:800}"
    false
  }
  echo "$_last_comment" | grep -q "add_approved_blocker concurrency timeout" || {
    echo "FAIL: last comment missing the failing test name"
    echo "Comment: ${_last_comment:0:800}"
    false
  }
}

# ---------------------------------------------------------------------------
# 6. Success path: LATER-only + gate findings → posts gate comment, exits 2
# ---------------------------------------------------------------------------

@test "success-path LATER-only + gate findings: posts gate assessment comment and exits 2" {
  # Replace the failing-assessment mock lib with the succeeding one.
  rm -rf "$MOCK_LIB_DIR"
  export ASSESSMENT_TYPE=later
  _setup_mock_lib_tree_succeeding_assessment

  _write_gate_findings_with_failure

  run_assess_and_resolve 81 46

  [ "$status" -eq 2 ] || {
    echo "FAIL: expected exit 2 (gate-forced fix loop), got $status"
    echo "Output: ${output:0:1500}"
    false
  }

  # Gate comment must have been posted.
  local _bodies
  _bodies=$(_recorded_comments_for_pr 81)
  [ -n "$_bodies" ] || {
    echo "FAIL: no PR comment was posted — fix mode will die with 'No assessment found'"
    cat "$GH_MOCK_STATE_DIR/pr-comments.json"
    false
  }

  # The LAST comment must carry the gate items.
  local _last_comment
  _last_comment=$(jq -r --arg pr "81" \
    'if has($pr) then .[$pr][-1].body else "" end' \
    "$GH_MOCK_STATE_DIR/pr-comments.json")

  echo "$_last_comment" | grep -q "<!-- sharkrite-assessment" || {
    echo "FAIL: last comment missing the sharkrite-assessment marker"
    echo "Comment: ${_last_comment:0:800}"
    false
  }
  echo "$_last_comment" | grep -q "^### \[GATE\] bats failure: tests/regression/example.bats - ACTIONABLE_NOW$" || {
    echo "FAIL: last comment missing the structured [GATE] ACTIONABLE_NOW item"
    echo "Comment: ${_last_comment:0:800}"
    false
  }
  echo "$_last_comment" | grep -q "add_approved_blocker concurrency timeout" || {
    echo "FAIL: last comment missing the failing test name"
    echo "Comment: ${_last_comment:0:800}"
    false
  }
}

# ---------------------------------------------------------------------------
# 7. Pure-review: success + no gate findings → behavior unchanged (no extra comment)
# ---------------------------------------------------------------------------

@test "success-path pure-review no gate findings: all-dismissed exits 0, no extra gate comment" {
  # Replace the failing-assessment mock lib with the succeeding all-dismissed one.
  rm -rf "$MOCK_LIB_DIR"
  export ASSESSMENT_TYPE=dismissed
  _setup_mock_lib_tree_succeeding_assessment

  # No gate findings.
  unset RITE_GATE_FINDINGS 2>/dev/null || true

  run_assess_and_resolve 82 47

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (all-dismissed, no gate), got $status"
    echo "Output: ${output:0:1500}"
    false
  }

  # assess-review-issues.sh stub posts one comment; no gate-fallback comment.
  local _comment_count
  _comment_count=$(jq -r --arg pr "82" \
    'if has($pr) then (.[$pr] | length) else 0 end' \
    "$GH_MOCK_STATE_DIR/pr-comments.json" 2>/dev/null || echo "0")

  # Exactly one comment (from the stub's simulate-real-behavior post); zero or
  # one is acceptable — what must NOT happen is a second gate-fallback comment.
  local _bodies
  _bodies=$(_recorded_comments_for_pr 82)
  local _gate_comment_count
  _gate_comment_count=$(printf '%s\n' "$_bodies" | grep -c "LLM assessment failed" || true)
  [ "$_gate_comment_count" -eq 0 ] || {
    echo "FAIL: a gate-fallback comment was posted on the no-gate pure-review path (behavior change)"
    echo "Comment: ${_bodies:0:800}"
    false
  }
}

# ---------------------------------------------------------------------------
# #949: gate items must reach the POSTED assessment on the LLM-SUCCESS path.
# The normal comment (assess-review-issues) posts BEFORE the [GATE] merge, so
# fix mode — which reads the LATEST posted assessment — saw no NOW items when
# gate findings were the only ones: empty ~90s fix cycles to exhaustion
# (LeadFlow #401/#491, sharkrite #910). The fix posts a superseding MERGED
# comment at the merge point; these pins prove the posted shape parses through
# fix mode's real extraction pipeline.
# ---------------------------------------------------------------------------

@test "#949: merged comment parses through fix-mode extraction (gate-only NOW)" {
  # Body in _post_gate_fallback_assessment_comment's exact shape, param2 = the
  # MERGED assessment (gate items + LLM text with its own sections).
  merged_comment='<!-- sharkrite-assessment pr:99 iteration:1 timestamp:T -->

## 🔍 Sharkrite Assessment

**Model:** merged — LLM assessment + 1 gate finding(s) (#949)

### Summary
- **ACTIONABLE_NOW:** 1 items (fix in this PR)

---

### [GATE] bats failure: tests/regression/foo.bats - ACTIONABLE_NOW
**Severity:** HIGH
Objective gate failure.

### Cosmetic nit in logging - DISMISSED
**Reasoning:** not actionable.'

  # Fix mode pipeline: strip to first ---, then extract NOW blocks (verbatim awk).
  content=$(echo "$merged_comment" | sed -n '/^---$/,$p' | tail -n +2)
  now_items=$(echo "$content" | awk '/^### .* - ACTIONABLE_NOW$/ { printing=1 } /^### .* - (ACTIONABLE_LATER|DISMISSED)$/ { printing=0 } /^(✅|───|━━)/ { printing=0 } printing { print }')
  [[ "$now_items" == *"[GATE] bats failure: tests/regression/foo.bats"* ]]
  [[ "$now_items" != *"Cosmetic nit"* ]]
  [ -n "$now_items" ]
}

@test "#949 source: LLM-success path posts the merged assessment after the counts" {
  run grep -n "Posted merged assessment (LLM + \[GATE\] items)" "${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"
  [ "$status" -eq 0 ]
  # The superseding post passes the MERGED NOW count, not the gate-only count.
  run grep -A1 '_post_gate_fallback_assessment_comment "\$PR_NUMBER" "\$ASSESSMENT_RESULT" "\$ACTIONABLE_NOW_COUNT"' "${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# #985: Grouped comment + split counts when both origins present
# ---------------------------------------------------------------------------
#
# These tests cover the "both gate and review ACTIONABLE_NOW items" path:
#   - _post_gate_fallback_assessment_comment with _now_review_count > 0 must
#     group items under #### Failed tests (gate) and #### Review findings
#   - The Summary ACTIONABLE_NOW line must carry the split annotation
#   - The ASSESSMENT diag line must include now_gate= and now_review= fields
#   - Fix-mode extraction must still capture ALL ACTIONABLE_NOW blocks
#     from the grouped comment (both gate and review groups)
#
# Harness: uses a new succeeding stub that outputs ACTIONABLE_NOW review items
# alongside the gate findings, triggering the merged (#949) + grouped (#985) path.

# Installs a succeeding assess-review-issues.sh stub that outputs one
# ACTIONABLE_NOW review item — triggering the merged #949 + grouped #985 path.
_setup_mock_lib_tree_now_review_item() {
  mkdir -p "$MOCK_LIB_DIR/core"
  mkdir -p "$MOCK_LIB_DIR/utils"

  for _f in "$RITE_REPO_ROOT/lib/utils/"*.sh; do
    ln -sf "$_f" "$MOCK_LIB_DIR/utils/$(basename "$_f")"
  done
  for _f in "$RITE_REPO_ROOT/lib/core/"*.sh; do
    ln -sf "$_f" "$MOCK_LIB_DIR/core/$(basename "$_f")"
  done

  # Override: assess-review-issues.sh — outputs ONE ACTIONABLE_NOW review item.
  rm -f "$MOCK_LIB_DIR/core/assess-review-issues.sh"
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must be expanded
  cat > "$MOCK_LIB_DIR/core/assess-review-issues.sh" << ASSESS_NOW_STUB_EOF
#!/usr/bin/env bash
# Stub: outputs one ACTIONABLE_NOW review item (triggers #949 merged path).
set -euo pipefail
_ts=\$(date -u +"%Y-%m-%dT%H:%M:%SZ")
_pr="\${1:-0}"
_body_file=\$(mktemp)
printf '%s' "<!-- sharkrite-assessment pr:\${_pr} iteration:1 timestamp:\${_ts} -->

## Sharkrite Assessment
### Summary
- **ACTIONABLE_NOW:** 1 items

---

### Input validation missing - ACTIONABLE_NOW
**Severity:** HIGH
**Location:** lib/core/config.sh:10
" > "\$_body_file"
gh pr comment "\$_pr" --body-file "\$_body_file" >/dev/null 2>&1 || true
rm -f "\$_body_file"

printf '%s\n' \
  "### Input validation missing - ACTIONABLE_NOW" \
  "**Severity:** HIGH" \
  "**Location:** lib/core/config.sh:10"
exit 0
ASSESS_NOW_STUB_EOF
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

@test "#985: merged comment (gate + review) groups items under sub-headings in posted comment" {
  rm -rf "$MOCK_LIB_DIR"
  _setup_mock_lib_tree_now_review_item

  _write_gate_findings_with_failure

  run_assess_and_resolve 90 55

  [ "$status" -eq 2 ] || {
    echo "FAIL: expected exit 2 (gate-forced fix loop), got $status"
    echo "Output: ${output:0:1500}"
    false
  }

  # The LAST comment is the merged #949 superseding comment.
  local _last_comment
  _last_comment=$(jq -r --arg pr "90" \
    'if has($pr) then .[$pr][-1].body else "" end' \
    "$GH_MOCK_STATE_DIR/pr-comments.json")

  [ -n "$_last_comment" ] || {
    echo "FAIL: no PR comment recorded for PR #90"
    cat "$GH_MOCK_STATE_DIR/pr-comments.json"
    false
  }

  # Must have the #### Failed tests (gate) sub-heading.
  echo "$_last_comment" | grep -q "#### Failed tests (gate)" || {
    echo "FAIL: merged comment missing '#### Failed tests (gate)' sub-heading"
    echo "Comment: ${_last_comment:0:1200}"
    false
  }

  # Must have the #### Review findings sub-heading.
  echo "$_last_comment" | grep -q "#### Review findings" || {
    echo "FAIL: merged comment missing '#### Review findings' sub-heading"
    echo "Comment: ${_last_comment:0:1200}"
    false
  }

  # Both item types must be present.
  echo "$_last_comment" | grep -q "^### \[GATE\] bats failure" || {
    echo "FAIL: merged comment missing the gate item"
    echo "Comment: ${_last_comment:0:1200}"
    false
  }
  echo "$_last_comment" | grep -q "^### Input validation missing - ACTIONABLE_NOW" || {
    echo "FAIL: merged comment missing the review item"
    echo "Comment: ${_last_comment:0:1200}"
    false
  }
}

@test "#985: Summary ACTIONABLE_NOW line shows split annotation (gate=N, review=N)" {
  rm -rf "$MOCK_LIB_DIR"
  _setup_mock_lib_tree_now_review_item

  _write_gate_findings_with_failure

  run_assess_and_resolve 91 56

  [ "$status" -eq 2 ] || {
    echo "FAIL: expected exit 2, got $status"
    echo "Output: ${output:0:1500}"
    false
  }

  local _last_comment
  _last_comment=$(jq -r --arg pr "91" \
    'if has($pr) then .[$pr][-1].body else "" end' \
    "$GH_MOCK_STATE_DIR/pr-comments.json")

  # The Summary ACTIONABLE_NOW line must carry the split annotation.
  # Format: ACTIONABLE_NOW: 2 items (1 failed tests, 1 review) (fix in this PR)
  echo "$_last_comment" | grep -qE "\*\*ACTIONABLE_NOW:\*\* [0-9]+ items \([0-9]+ failed tests, [0-9]+ review\)" || {
    echo "FAIL: Summary ACTIONABLE_NOW line missing split annotation '(N failed tests, N review)'"
    echo "Comment summary section:"
    echo "$_last_comment" | grep -A4 "### Summary" || true
    false
  }
}

@test "#985 source: ASSESSMENT diag line carries now_gate= and now_review= fields" {
  # Structural pin: _diag is a no-op in the subprocess harness, so we verify
  # the _diag call site in source rather than running a subprocess.
  # This is a legitimate structural check: the format of the diag emission line
  # is a wiring invariant (health-report parsers key on these field names) that
  # cannot be expressed by a behavioral test without removing the _diag no-op.
  local _assess_file="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"
  run grep -n 'now_gate=' "$_assess_file"
  [ "$status" -eq 0 ] || {
    echo "FAIL: now_gate= field not found in _diag call in assess-and-resolve.sh"
    false
  }
  run grep -n 'now_review=' "$_assess_file"
  [ "$status" -eq 0 ] || {
    echo "FAIL: now_review= field not found in _diag call in assess-and-resolve.sh"
    false
  }
  # Verify both fields appear on the same _diag "ASSESSMENT" line.
  run grep -E '_diag.*ASSESSMENT.*now_gate=.*now_review=' "$_assess_file"
  [ "$status" -eq 0 ] || {
    echo "FAIL: _diag ASSESSMENT line does not carry both now_gate= and now_review= fields on the same line"
    grep '_diag.*ASSESSMENT' "$_assess_file" || true
    false
  }
}

@test "#985: fix-mode extraction captures ALL ACTIONABLE_NOW blocks from grouped comment (gate + review)" {
  # This extends the #949 parse-through test to verify both groups survive extraction.
  # The grouped comment has sub-headings between item blocks; the awk extractor
  # must be unaffected (it triggers on ^### not ^####).
  merged_grouped_comment='<!-- sharkrite-assessment pr:99 iteration:1 timestamp:T -->

## 🔍 Sharkrite Assessment

**Model:** merged — LLM assessment + 1 gate finding(s) (#949)

### Summary
- **ACTIONABLE_NOW:** 2 items (1 failed tests, 1 review) (fix in this PR)

---

#### Failed tests (gate)

### [GATE] bats failure: tests/regression/foo.bats - ACTIONABLE_NOW
**Severity:** HIGH
Objective gate failure.

#### Review findings

### Input not sanitized - ACTIONABLE_NOW
**Severity:** HIGH
**Location:** lib/core/config.sh:10
Subjective review finding.'

  # Fix mode pipeline: strip to first ---, then extract NOW blocks (verbatim awk).
  content=$(echo "$merged_grouped_comment" | sed -n '/^---$/,$p' | tail -n +2)
  now_items=$(echo "$content" | awk '/^### .* - ACTIONABLE_NOW$/ { printing=1 } /^### .* - (ACTIONABLE_LATER|DISMISSED)$/ { printing=0 } /^(✅|───|━━)/ { printing=0 } printing { print }')

  # Both groups must be captured.
  [[ "$now_items" == *"[GATE] bats failure: tests/regression/foo.bats"* ]] || {
    echo "FAIL: gate item not captured by fix-mode awk from grouped comment"
    echo "Extracted: ${now_items:0:600}"
    false
  }
  [[ "$now_items" == *"Input not sanitized"* ]] || {
    echo "FAIL: review item not captured by fix-mode awk from grouped comment"
    echo "Extracted: ${now_items:0:600}"
    false
  }

  # Sub-headings must NOT become separate extracted items (#### level, not ###).
  local _count
  _count=$(echo "$now_items" | grep -c "^### .* - ACTIONABLE_NOW" || true)
  [ "$_count" -eq 2 ] || {
    echo "FAIL: expected exactly 2 ACTIONABLE_NOW blocks extracted, got $_count"
    echo "Extracted: ${now_items:0:600}"
    false
  }

  # DISMISSED/LATER items and sub-headings must not leak into the extracted output
  [[ "$now_items" != *"DISMISSED"* ]] || {
    echo "FAIL: DISMISSED item leaked into ACTIONABLE_NOW extraction"
    false
  }
  [ -n "$now_items" ]
}

@test "#985 invariant: assess-and-resolve.sh introduces no new ### - STATE header grammar" {
  # Three-state machine invariant: origin grouping is via #### sub-headings (H4),
  # never new H3 (###) state tokens. This pin asserts that no line in
  # assess-and-resolve.sh echoes or prints a new `### ... - <STATE>` pattern
  # beyond the three canonical states.
  # (make check catches this too via the grammar; this bats pin is the runtime guard.)
  local _assess_file="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"
  local _bad_states
  _bad_states=$(grep -oE '"### .* - [A-Z_]+"' "$_assess_file" | \
    grep -vE '"### .*- (ACTIONABLE_NOW|ACTIONABLE_LATER|DISMISSED)"' | \
    grep -vE '^\s*#' || true)
  if [ -n "$_bad_states" ]; then
    echo "FAIL: new ### - STATE header string introduced in assess-and-resolve.sh"
    echo "Found: $_bad_states"
    return 1
  fi
  true
}
