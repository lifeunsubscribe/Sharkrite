#!/usr/bin/env bats
# tests/integration/assess-and-resolve-dedup.bats
#
# Integration tests that drive assess-and-resolve.sh's dedup block against the
# stateful gh mock from tests/helpers/gh-mock.bash.
#
# Background:
#   All prior tests for the dedup logic (tests/regression/gh-mock-dedup.bats,
#   tests/concurrency/followup-issue-dedup.bats) exercise either the mock
#   contract in isolation or the locking primitives directly.  None of them
#   run assess-and-resolve.sh end-to-end with the stateful mock, so a change
#   to the search/view call pattern inside the script could pass mock-only
#   tests while silently breaking the real flow.
#
# Strategy:
#   Each test spawns assess-and-resolve.sh as a subprocess with:
#     - RITE_LIB_DIR pointing to a temp mock-lib tree that contains:
#         core/assess-review-issues.sh  — stub returning a fixed assessment
#         utils/format-review.sh        — stub (no-op display)
#     - PATH overridden so 'gh' resolves to tests/helpers/gh-mock-binary.sh
#       (a standalone script that reads/writes stateful dedup state files).
#     - A pre-written review file injected into the mock gh pr view response.
#     - GH_MOCK_STATE_DIR initialised with setup_gh_mock_state so the dedup
#       search/create/comment calls use live state.
#
# What is tested (coverage gap closed):
#   1. ACTIONABLE_LATER path: assess-and-resolve.sh creates a follow-up issue
#      via gh issue create; stateful mock records it.
#   2. Dedup on second run: body-marker search (Source 2) finds the existing
#      issue and skips creation.
#   3. Title-search fallback (Source 3): body search returns empty, title
#      search finds the previously-created issue.
#   4. Local evidence (Source 1): write_followup_evidence written by first run
#      is read back by second run to skip creation.
#   5. ACTIONABLE_NOW path: exit 2 with assessment piped to stdout.
#   6. Zero-findings early exit: skips assessment and returns exit 0 without
#      creating any issue.
#   7. Index lag with local evidence: second run relies on Source 1 when
#      searches return empty due to simulated index lag.
#   8. Dedup retry loop uses PR comment guard (Source 4) then finds issue.
#   9. All-DISMISSED assessment: exit 0, no follow-up issue.
#  10. Follow-up issue body contains sharkrite-parent-pr marker.
#  11. CLOSED-state evidence clearing: evidence pointing to CLOSED issue is
#      removed and a new follow-up is created (covers assess-and-resolve.sh
#      CLOSED branch at lines 1180-1183).
#  12. CLOSED-evidence log message: script emits informational message when
#      clearing stale evidence for a CLOSED issue.
#
# Verification command:
#   bats tests/integration/assess-and-resolve-dedup.bats

load '../helpers/setup'
load '../helpers/gh-mock'
load '../helpers/gh-mock-state'

# ---------------------------------------------------------------------------
# Pre-canned review and assessment content
# ---------------------------------------------------------------------------

# Minimal review with findings so assess-and-resolve.sh does not take the
# zero-findings early-exit path (which skips assessment and follow-up creation).
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

# Assessment with ACTIONABLE_LATER items only — triggers follow-up creation, exit 0.
_ASSESSMENT_LATER_ONLY='### Input Not Validated - ACTIONABLE_LATER

**Severity:** HIGH
**Category:** Security
**Reasoning:** Valid improvement but out of scope for this PR.
**Defer Reason:** Too broad for this PR; defer to tech-debt.
**Fix Effort:** <1hr

### Missing Docs - ACTIONABLE_LATER

**Severity:** MEDIUM
**Category:** Documentation
**Reasoning:** Docs are absent but non-blocking.
**Defer Reason:** Separate docs PR.
**Fix Effort:** <10min
'

# Assessment with ACTIONABLE_NOW items — triggers exit 2 (fix loop).
_ASSESSMENT_NOW_ITEMS='### Input Not Validated - ACTIONABLE_NOW

**Severity:** HIGH
**Category:** Security
**Reasoning:** User input reaches sensitive path without validation.
**Context:** Within scope of this PR.
**Location:** lib/core/foo.sh:42
**Fix Effort:** <10min
'

# Assessment with only DISMISSED items — exit 0, no follow-up.
_ASSESSMENT_ALL_DISMISSED='### Some Style Issue - DISMISSED

**Severity:** LOW
**Category:** Style
**Reasoning:** Personal preference, not worth tracking.
'

# Zero-findings review — triggers early exit 0 without creating issues.
_REVIEW_ZERO_FINDINGS='<!-- sharkrite-local-review model:claude-opus-4-8 timestamp:2026-06-01T12:00:00Z -->
## Code Review

Findings: CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 0

Looks great — no issues found.
'

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  # Verify required tools are available
  if ! command -v jq &>/dev/null; then
    skip "jq not available — required for integration tests"
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

  # --- Mock lib tree ---
  # assess-and-resolve.sh sources several scripts from RITE_LIB_DIR.
  # We create stubs for scripts that would invoke Claude or make network calls,
  # and symlink everything else to the real library.
  export MOCK_LIB_DIR="$RITE_TEST_TMPDIR/mock-lib"
  _setup_mock_lib_tree

  # --- Mock gh binary ---
  # Copy tests/helpers/gh-mock-binary.sh into a temp bin dir.
  # The binary reads GH_MOCK_STATE_DIR and GH_MOCK_PR_VIEW_FILE from the env.
  # gh-mock-state.bash (the shared library) must be copied alongside the binary
  # because gh-mock-binary.sh sources it via a relative path from BASH_SOURCE[0].
  export MOCK_BIN_DIR="$RITE_TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_BIN_DIR"
  cp "$RITE_REPO_ROOT/tests/helpers/gh-mock-binary.sh" "$MOCK_BIN_DIR/gh"
  cp "$RITE_REPO_ROOT/tests/helpers/gh-mock-state.bash" "$MOCK_BIN_DIR/gh-mock-state.bash"
  chmod +x "$MOCK_BIN_DIR/gh"
  export PATH="$MOCK_BIN_DIR:$PATH"

  # --- Default assessment stub (ACTIONABLE_LATER, triggers follow-up) ---
  # Can be overridden per-test by writing different content to MOCK_ASSESSMENT_FILE.
  export MOCK_ASSESSMENT_FILE="$RITE_TEST_TMPDIR/mock-assessment.txt"
  printf '%s' "$_ASSESSMENT_LATER_ONLY" > "$MOCK_ASSESSMENT_FILE"

  # --- Default PR view response (review present, with findings) ---
  export GH_MOCK_PR_VIEW_FILE="$RITE_TEST_TMPDIR/mock-pr-view.json"
  _write_pr_view_json "$_REVIEW_WITH_FINDINGS"

  # Misc config expected by config.sh / assess-and-resolve.sh
  export RITE_LIB_DIR="$MOCK_LIB_DIR"
  export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR/install"
  export RITE_REVIEW_MODEL="claude-opus-4-8"
  export RITE_MAX_RETRIES=3
  export RITE_DEDUP_BACKOFF=0       # No sleep delays in tests
  export RITE_GH_MAX_RETRIES=1      # Single attempt; suppress retry loops
  export RITE_DRY_RUN=false
  export RITE_VERBOSE=false
  export RITE_GH_RETRY_MAX_SLEEP=0

  # Export _diag as a no-op so assess-and-resolve.sh's ERR trap and diagnostic
  # calls work correctly when invoked directly (not via workflow-runner.sh which
  # normally sources logging.sh and exports _diag into subprocesses).
  _diag() { :; }
  export -f _diag 2>/dev/null || true

  # Export is_verbose required by logging.sh functions that _diag may chain through
  is_verbose() { false; }
  export -f is_verbose 2>/dev/null || true
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _setup_mock_lib_tree
# Creates MOCK_LIB_DIR with stubs for scripts that invoke Claude or generate
# reviews, and symlinks for all other lib scripts.
_setup_mock_lib_tree() {
  mkdir -p "$MOCK_LIB_DIR/core"
  mkdir -p "$MOCK_LIB_DIR/utils"

  # Symlink ALL of lib/utils — all pure bash, no network calls.
  # Intentionally broad: assess-and-resolve.sh sources several utils directly
  # (blocker-rules.sh, scratchpad-manager.sh, divergence-handler.sh, etc.) and
  # future sourcing dependencies could be added without notice.  Narrowing to a
  # known subset would break non-obvious transitive sources silently.
  for _f in "$RITE_REPO_ROOT/lib/utils/"*.sh; do
    ln -sf "$_f" "$MOCK_LIB_DIR/utils/$(basename "$_f")"
  done

  # Symlink ALL of lib/core — intentionally broad for the same reason: the set
  # of files sourced by assess-and-resolve.sh (or its transitive dependencies)
  # can grow without this test needing to be updated.  Individual scripts that
  # must NOT run (assess-review-issues.sh, format-review.sh) are overridden
  # with stubs immediately below.
  for _f in "$RITE_REPO_ROOT/lib/core/"*.sh; do
    ln -sf "$_f" "$MOCK_LIB_DIR/core/$(basename "$_f")"
  done

  # Override: assess-review-issues.sh — outputs MOCK_ASSESSMENT_FILE to stdout.
  # This isolates assess-and-resolve.sh from needing a live Claude CLI.
  cat > "$MOCK_LIB_DIR/core/assess-review-issues.sh" << 'ASSESS_STUB_EOF'
#!/usr/bin/env bash
# Stub assess-review-issues.sh: outputs MOCK_ASSESSMENT_FILE content to stdout.
set -euo pipefail
if [ -z "${MOCK_ASSESSMENT_FILE:-}" ] || [ ! -f "$MOCK_ASSESSMENT_FILE" ]; then
  echo "STUB ERROR: MOCK_ASSESSMENT_FILE not set or missing" >&2
  exit 1
fi
cat "$MOCK_ASSESSMENT_FILE"
exit 0
ASSESS_STUB_EOF
  chmod +x "$MOCK_LIB_DIR/core/assess-review-issues.sh"

  # Override: format-review.sh — no-op (avoids display logic in tests).
  cat > "$MOCK_LIB_DIR/utils/format-review.sh" << 'FORMAT_STUB_EOF'
#!/usr/bin/env bash
# Stub format-review.sh: no-op.
exit 0
FORMAT_STUB_EOF
  chmod +x "$MOCK_LIB_DIR/utils/format-review.sh"
}

# _write_pr_view_json REVIEW_BODY
# Writes a JSON fixture to GH_MOCK_PR_VIEW_FILE that models what
# `gh pr view PR --json comments` returns when a sharkrite-local-review
# comment is present with no commits after it (review is current).
# Used by: setup() default fixture, test 6 (zero-findings override),
# and tests 11-12 (CLOSED-evidence tests that refresh the fixture explicitly).
_write_pr_view_json() {
  local _review_body="$1"
  jq -n \
    --arg body "$_review_body" \
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
}

# run_assess_and_resolve PR_NUMBER ISSUE_NUMBER [RETRY_COUNT]
# Runs assess-and-resolve.sh as a subprocess under bats `run` with all mock
# infrastructure active.  Populates $status and $output.
run_assess_and_resolve() {
  local _pr="${1:-42}"
  local _issue="${2:-10}"
  local _retry="${3:-0}"

  # Run with --auto so the script does not prompt for interactive input.
  run bash "$RITE_REPO_ROOT/lib/core/assess-and-resolve.sh" \
    "$_pr" "$_issue" "$_retry" --auto
}

# ---------------------------------------------------------------------------
# 1. ACTIONABLE_LATER path: first run creates a follow-up issue (exit 0)
# ---------------------------------------------------------------------------

@test "integration: ACTIONABLE_LATER assessment creates follow-up issue and exits 0" {
  # Assessment stub returns ACTIONABLE_LATER items → CREATE_SECURITY_DEBT path.
  # assess-and-resolve.sh should call gh issue create, write evidence, exit 0.

  run_assess_and_resolve 42 10

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (ACTIONABLE_LATER path), got $status"
    echo "--- output ---"
    echo "$output"
    false
  }

  # Stateful mock must have recorded exactly one new issue
  local _count
  _count=$(jq 'length' "$GH_MOCK_STATE_DIR/issues.json")
  [ "$_count" -eq 1 ] || {
    echo "FAIL: expected 1 created issue, got $_count"
    jq '.' "$GH_MOCK_STATE_DIR/issues.json"
    false
  }

  # Created issue body must contain the sharkrite-source-issue marker
  local _body
  _body=$(jq -r '.[0].body' "$GH_MOCK_STATE_DIR/issues.json")
  echo "$_body" | grep -q "sharkrite-source-issue:10" || {
    echo "FAIL: issue body missing sharkrite-source-issue:10 marker"
    echo "Body: ${_body:0:300}"
    false
  }
}

@test "integration: follow-up issue title includes PR number" {
  run_assess_and_resolve 43 11

  [ "$status" -eq 0 ]

  local _title
  _title=$(jq -r '.[0].title' "$GH_MOCK_STATE_DIR/issues.json")
  echo "$_title" | grep -q "PR #43" || {
    echo "FAIL: issue title '$_title' does not contain 'PR #43'"
    false
  }
}

@test "integration: follow-up PR comment contains sharkrite-followup-issue marker" {
  run_assess_and_resolve 44 12

  [ "$status" -eq 0 ]

  # The mock should have received a pr comment call
  local _count
  _count=$(jq --arg pr "44" \
    'if has($pr) then .[$pr] | length else 0 end' \
    "$GH_MOCK_STATE_DIR/pr-comments.json")
  [ "$_count" -ge 1 ] || {
    echo "FAIL: no PR comment posted to PR #44"
    false
  }

  # Comment body must contain the marker
  local _body
  _body=$(jq -r --arg pr "44" \
    'if has($pr) then .[$pr][0].body else "" end' \
    "$GH_MOCK_STATE_DIR/pr-comments.json")
  echo "$_body" | grep -q "sharkrite-followup-issue:" || {
    echo "FAIL: PR comment missing sharkrite-followup-issue marker"
    echo "Comment: ${_body:0:200}"
    false
  }
}

# ---------------------------------------------------------------------------
# 2. Dedup on second run: body-marker search (Source 2) skips re-creation
# ---------------------------------------------------------------------------

@test "integration: second run with same PR+issue skips follow-up creation via body-marker search" {
  # First run: creates issue
  run_assess_and_resolve 45 13
  [ "$status" -eq 0 ]

  local _count_first
  _count_first=$(jq 'length' "$GH_MOCK_STATE_DIR/issues.json")
  [ "$_count_first" -eq 1 ] || {
    echo "FAIL: expected 1 issue after first run, got $_count_first"
    false
  }

  # Second run: body-marker search (Source 2) should find the existing issue
  run_assess_and_resolve 45 13
  [ "$status" -eq 0 ] || {
    echo "FAIL: second run exited $status (expected 0)"
    echo "$output"
    false
  }

  # Issue count must NOT increase — dedup worked
  local _count_second
  _count_second=$(jq 'length' "$GH_MOCK_STATE_DIR/issues.json")
  [ "$_count_second" -eq 1 ] || {
    echo "FAIL: second run created a duplicate (count=$_count_second, expected 1)"
    jq '.' "$GH_MOCK_STATE_DIR/issues.json"
    false
  }

  # Output must mention skipping the duplicate (match specific phrases emitted by
  # the dedup path, not the bare token 'skip' which could match unrelated output)
  echo "$output" | grep -qi "already exists\|skipping assessment\|skipping follow-up\|follow-up already" || {
    echo "FAIL: second run output does not mention skipping duplicate"
    echo "Output snippet: ${output:0:500}"
    false
  }
}

@test "integration: different source issues on same PR each get their own follow-up" {
  # PR #46 has source issues #14 and #15; each must create a distinct follow-up.

  run_assess_and_resolve 46 14
  [ "$status" -eq 0 ]

  run_assess_and_resolve 46 15
  [ "$status" -eq 0 ]

  local _count
  _count=$(jq 'length' "$GH_MOCK_STATE_DIR/issues.json")
  [ "$_count" -eq 2 ] || {
    echo "FAIL: expected 2 follow-up issues (one per source issue), got $_count"
    jq '.' "$GH_MOCK_STATE_DIR/issues.json"
    false
  }

  # Each issue body must contain the correct source marker
  local _body14 _body15
  _body14=$(jq -r '[.[] | .body] | map(select(contains("sharkrite-source-issue:14"))) | .[0] // ""' \
    "$GH_MOCK_STATE_DIR/issues.json")
  _body15=$(jq -r '[.[] | .body] | map(select(contains("sharkrite-source-issue:15"))) | .[0] // ""' \
    "$GH_MOCK_STATE_DIR/issues.json")

  [ -n "$_body14" ] || { echo "FAIL: no issue with sharkrite-source-issue:14"; false; }
  [ -n "$_body15" ] || { echo "FAIL: no issue with sharkrite-source-issue:15"; false; }
}

@test "integration: re-running for same source issue does not create a second follow-up" {
  # Three runs on the same (PR, source issue) — only the first creates an issue.
  run_assess_and_resolve 55 23
  [ "$status" -eq 0 ]
  run_assess_and_resolve 55 23
  [ "$status" -eq 0 ]
  run_assess_and_resolve 55 23
  [ "$status" -eq 0 ]

  local _count
  _count=$(jq 'length' "$GH_MOCK_STATE_DIR/issues.json")
  [ "$_count" -eq 1 ] || {
    echo "FAIL: expected 1 issue after 3 runs (dedup), got $_count"
    false
  }
}

# ---------------------------------------------------------------------------
# 3. Title-search fallback dedup (Source 3)
# ---------------------------------------------------------------------------

@test "integration: title-search fallback prevents duplicate when body search misses" {
  # Pre-seed state with an issue that has the right title but NO body marker
  # (simulating an older follow-up created before body-marker embedding).
  # Source 3 (title search) should find it and prevent re-creation.
  local _pr=47
  local _issue=16
  local _title="[tech-debt] Test PR: review feedback from PR #${_pr} for issue #${_issue}"
  local _body_file="$RITE_TEST_TMPDIR/title-only-body.md"
  printf 'Review feedback without body marker.' > "$_body_file"

  # Issue number 9999 is intentionally out-of-band with respect to the mock gh
  # issue-create generator, which assigns numbers as (_seq + 1000) starting at
  # 1000. A typical test run creates at most a handful of issues, so the
  # generator stays in the low-1000s range — 9999 cannot collide with any
  # generated number unless the test suite creates ~9000 issues.  If the
  # generator base ever changes (see _gh_mock_state_issue_create in gh-mock-state.bash), this seed
  # must be updated to remain safely above it.
  local _seed_num=9999
  jq --argjson num "$_seed_num" \
     --arg title "$_title" \
     --rawfile body "$_body_file" \
     --arg label "tech-debt" \
     --arg state "OPEN" \
     ". += [{\"number\": \$num, \"title\": \$title, \"body\": \$body, \"label\": \$label, \"state\": \$state, \"url\": \"https://github.com/mock/repo/issues/${_seed_num}\"}]" \
     "$GH_MOCK_STATE_DIR/issues.json" > "$GH_MOCK_STATE_DIR/issues.json.tmp" \
  && mv "$GH_MOCK_STATE_DIR/issues.json.tmp" "$GH_MOCK_STATE_DIR/issues.json"

  # Run: Source 2 (body search) misses (no marker), Source 3 (title search) finds $_seed_num
  run_assess_and_resolve "$_pr" "$_issue"

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $status"
    echo "$output"
    false
  }

  # Total must still be 1 — no new issue created
  local _total
  _total=$(jq 'length' "$GH_MOCK_STATE_DIR/issues.json")
  [ "$_total" -eq 1 ] || {
    echo "FAIL: expected 1 issue (title-search dedup), got $_total"
    jq '.[].title' "$GH_MOCK_STATE_DIR/issues.json"
    false
  }

  # Identity assertion: the surviving issue must be the seeded one (number and
  # title), not a newly-created duplicate that pushed total back to 1 via
  # collision or replacement.  A count-only assertion cannot catch a false pass
  # where the seeded issue was missed and a new issue with the same count was
  # created instead.
  local _surviving_num _surviving_title
  _surviving_num=$(jq '.[0].number' "$GH_MOCK_STATE_DIR/issues.json")
  _surviving_title=$(jq -r '.[0].title' "$GH_MOCK_STATE_DIR/issues.json")
  [ "$_surviving_num" -eq "$_seed_num" ] || {
    echo "FAIL: surviving issue number is $_surviving_num, expected $_seed_num (seeded issue)"
    false
  }
  [ "$_surviving_title" = "$_title" ] || {
    echo "FAIL: surviving issue title does not match seeded title"
    echo "  expected: $_title"
    echo "  got:      $_surviving_title"
    false
  }
}

# ---------------------------------------------------------------------------
# 4. Local evidence (Source 1) prevents re-creation under search-index lag
# ---------------------------------------------------------------------------

@test "integration: local evidence file is written after first run" {
  run_assess_and_resolve 48 17

  [ "$status" -eq 0 ]

  # Evidence file must exist in RITE_LOCK_DIR
  local _evidence_file="$RITE_LOCK_DIR/pr-48-src-17-followup-created.txt"
  [ -f "$_evidence_file" ] || {
    echo "FAIL: local evidence file not found at $_evidence_file"
    ls "$RITE_LOCK_DIR/" || true
    false
  }

  # Evidence must contain a valid issue number
  local _content
  _content=$(cat "$_evidence_file")
  [[ "$_content" =~ ^[0-9]+$ ]] || {
    echo "FAIL: evidence content '$_content' is not a number"
    false
  }
}

@test "integration: local evidence prevents re-creation when search index has lag" {
  # First run creates issue and writes local evidence.
  run_assess_and_resolve 49 18
  [ "$status" -eq 0 ]

  local _evidence_file="$RITE_LOCK_DIR/pr-49-src-18-followup-created.txt"
  [ -f "$_evidence_file" ] || {
    echo "FAIL: local evidence not written by first run"
    false
  }

  # Simulate search-index lag so Sources 2 & 3 return empty on second run.
  echo "2" > "$GH_MOCK_STATE_DIR/search-lag.txt"

  # Second run: Sources 2/3 miss (lag), Source 1 (local evidence) should detect
  # the existing issue and skip creation.
  run_assess_and_resolve 49 18
  [ "$status" -eq 0 ]

  # Issue count must still be 1
  local _total
  _total=$(jq 'length' "$GH_MOCK_STATE_DIR/issues.json")
  [ "$_total" -eq 1 ] || {
    echo "FAIL: expected 1 issue (local evidence dedup under index lag), got $_total"
    false
  }
}

# ---------------------------------------------------------------------------
# 5. ACTIONABLE_NOW path: exit 2 with assessment piped to stdout
# ---------------------------------------------------------------------------

@test "integration: ACTIONABLE_NOW assessment exits 2 with content on stdout" {
  # How assess-and-resolve.sh pipes assessment to fix-mode Claude (and to bats):
  #   Line ~32: exec 3>&1   — save original stdout as fd 3 (bats captures fd 1 → $output)
  #   Line ~33: exec 1>&2   — redirect display output to stderr (not captured by bats)
  #   ACTIONABLE_NOW path:  echo "$ASSESSMENT_RESULT" >&3 — writes to saved fd 3
  # Because fd 3 IS the subprocess's original stdout, bats $output receives it.
  printf '%s' "$_ASSESSMENT_NOW_ITEMS" > "$MOCK_ASSESSMENT_FILE"

  run_assess_and_resolve 50 19

  # Exit 2: fix loop required
  [ "$status" -eq 2 ] || {
    echo "FAIL: expected exit 2 (ACTIONABLE_NOW), got $status"
    echo "Output: ${output:0:500}"
    false
  }

  # Stdout must contain ACTIONABLE_NOW (piped to fix-mode Claude)
  echo "$output" | grep -q "ACTIONABLE_NOW" || {
    echo "FAIL: exit 2 output missing ACTIONABLE_NOW"
    echo "Output: ${output:0:500}"
    false
  }

  # No follow-up issue should be created (ACTIONABLE_NOW → fix first, then re-assess)
  local _count
  _count=$(jq 'length' "$GH_MOCK_STATE_DIR/issues.json")
  [ "$_count" -eq 0 ] || {
    echo "FAIL: no follow-up issue expected on exit 2, got $_count"
    false
  }
}

# ---------------------------------------------------------------------------
# 6. Zero-findings early exit: skip assessment, exit 0, no issues created
# ---------------------------------------------------------------------------

@test "integration: zero-findings review exits 0 without creating any follow-up issue" {
  _write_pr_view_json "$_REVIEW_ZERO_FINDINGS"

  run_assess_and_resolve 51 20

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (zero findings), got $status"
    echo "Output: ${output:0:500}"
    false
  }

  # No issue created
  local _count
  _count=$(jq 'length' "$GH_MOCK_STATE_DIR/issues.json")
  [ "$_count" -eq 0 ] || {
    echo "FAIL: expected 0 issues for zero-findings review, got $_count"
    false
  }

  # Output must mention zero findings or skipping assessment (match specific
  # phrases emitted by the early-exit path, not the bare token 'skip' which
  # could match unrelated output — script emits "skipping assessment" or
  # "zero findings")
  echo "$output" | grep -qi "zero findings\|skipping assessment" || {
    echo "FAIL: output doesn't mention skipping due to zero findings"
    echo "Output: ${output:0:500}"
    false
  }
}

# ---------------------------------------------------------------------------
# 7. Dedup retry loop: PR comment guard (Source 4) prevents duplicate
#    when index has lag and local evidence has been removed
# ---------------------------------------------------------------------------

@test "integration: dedup retry loop uses PR comment marker to prevent duplicate under index lag" {
  # Sequence:
  #   First run: creates issue + posts PR comment marker + writes local evidence.
  #   Then: remove local evidence, set search-index lag=1, run again.
  #   Second run: Sources 2+3 miss on first pass (lag); Source 4 detects the
  #   PR comment marker, triggers a retry; lag=0 on retry so Sources 2/3 find it.
  #   No duplicate should be created.

  run_assess_and_resolve 52 21
  [ "$status" -eq 0 ]

  # Verify PR comment was posted
  local _comment_count
  _comment_count=$(jq --arg pr "52" \
    'if has($pr) then .[$pr] | length else 0 end' \
    "$GH_MOCK_STATE_DIR/pr-comments.json")
  [ "$_comment_count" -ge 1 ] || {
    echo "FAIL: expected PR comment to be posted on first run"
    false
  }

  # Remove local evidence to force Source 4 path on second run
  rm -f "$RITE_LOCK_DIR/pr-52-src-21-followup-created.txt"

  # Set search-index lag = 1 (first body/title search returns empty)
  echo "1" > "$GH_MOCK_STATE_DIR/search-lag.txt"

  # RITE_DEDUP_BACKOFF=0 already set in setup — no sleep in retry
  run_assess_and_resolve 52 21
  [ "$status" -eq 0 ]

  # No duplicate
  local _total
  _total=$(jq 'length' "$GH_MOCK_STATE_DIR/issues.json")
  [ "$_total" -eq 1 ] || {
    echo "FAIL: expected 1 issue (PR comment guard dedup under lag), got $_total"
    false
  }
}

# ---------------------------------------------------------------------------
# 8. All-DISMISSED assessment: exit 0, no follow-up issue created
# ---------------------------------------------------------------------------

@test "integration: all-dismissed assessment exits 0 without creating a follow-up issue" {
  printf '%s' "$_ASSESSMENT_ALL_DISMISSED" > "$MOCK_ASSESSMENT_FILE"

  run_assess_and_resolve 53 22

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0 (all dismissed), got $status"
    echo "Output: ${output:0:500}"
    false
  }

  local _count
  _count=$(jq 'length' "$GH_MOCK_STATE_DIR/issues.json")
  [ "$_count" -eq 0 ] || {
    echo "FAIL: expected no issue for all-dismissed assessment, got $_count"
    false
  }
}

# ---------------------------------------------------------------------------
# 9. Follow-up issue body contains parent PR and source-issue markers
# ---------------------------------------------------------------------------

@test "integration: follow-up issue body contains sharkrite-parent-pr marker" {
  run_assess_and_resolve 54 24

  [ "$status" -eq 0 ]

  local _body
  _body=$(jq -r '.[0].body' "$GH_MOCK_STATE_DIR/issues.json")
  echo "$_body" | grep -q "sharkrite-parent-pr:54" || {
    echo "FAIL: issue body missing sharkrite-parent-pr:54 marker"
    echo "Body: ${_body:0:300}"
    false
  }
}

# ---------------------------------------------------------------------------
# 10. CLOSED-state evidence clearing: stale evidence pointing to a CLOSED
#     issue is removed and a new follow-up is created
# ---------------------------------------------------------------------------

@test "integration: CLOSED evidenced issue clears stale evidence and creates new follow-up" {
  # Sequence:
  #   First run: creates follow-up issue #1000 and writes local evidence.
  #   Then: close the evidenced issue (flip state to CLOSED in mock state).
  #   Second run: Source 1 reads evidence → gh issue view returns CLOSED
  #     → script clears stale evidence → dedup check creates a new follow-up.
  #
  # This exercises the branch in assess-and-resolve.sh:1180-1183:
  #   elif [ -n "$_evidence_issue_state" ]; then
  #     # Confirmed non-OPEN (e.g. CLOSED) — stale evidence, safe to clear
  #     clear_followup_evidence "$PR_NUMBER" "${ISSUE_NUMBER:-}"

  # Explicit cleanup at test start: clear any residual state from a prior
  # partial failure.  setup() creates fresh directories under a unique
  # RITE_TEST_TMPDIR, so cross-test leakage cannot happen in normal runs;
  # this guard covers partial-failure scenarios where teardown was skipped.
  rm -f "$RITE_LOCK_DIR"/* 2>/dev/null || true
  setup_gh_mock_state

  local _pr=60
  local _issue=30

  # Capture baseline issue count before this test creates anything.
  # Asserting baseline+2 (not a fixed 2) guards against non-clean mock state
  # from earlier tests leaking issues into this test's state dir.
  local _baseline_count
  _baseline_count=$(jq 'length' "$GH_MOCK_STATE_DIR/issues.json")

  # First run: creates a follow-up issue (number 1000) and writes evidence.
  run_assess_and_resolve "$_pr" "$_issue"
  [ "$status" -eq 0 ] || {
    echo "FAIL: first run exited $status (expected 0)"
    echo "$output"
    false
  }

  # Evidence file must exist after the first run.
  local _evidence_file="$RITE_LOCK_DIR/pr-${_pr}-src-${_issue}-followup-created.txt"
  [ -f "$_evidence_file" ] || {
    echo "FAIL: local evidence file not found at $_evidence_file after first run"
    ls "$RITE_LOCK_DIR/" || true
    false
  }

  # Retrieve the evidenced issue number.
  local _evidenced_issue_num
  _evidenced_issue_num=$(cat "$_evidence_file")
  [[ "$_evidenced_issue_num" =~ ^[0-9]+$ ]] || {
    echo "FAIL: evidence content '$_evidenced_issue_num' is not a number"
    false
  }

  # Close the evidenced issue in the mock state.
  # This simulates the follow-up being closed/resolved independently before
  # the next assess-and-resolve run (e.g. someone fixed and closed it manually).
  _gh_mock_state_issue_set_state "$_evidenced_issue_num" "CLOSED"

  # Verify the state flip took effect before the second run.
  local _state_after_close
  _state_after_close=$(jq --argjson num "$_evidenced_issue_num" \
    '.[] | select(.number == $num) | .state' \
    "$GH_MOCK_STATE_DIR/issues.json" 2>/dev/null | tr -d '"' || true)
  [ "$_state_after_close" = "CLOSED" ] || {
    echo "FAIL: expected state CLOSED after _gh_mock_state_issue_set_state, got '$_state_after_close'"
    false
  }

  # Second run: Source 1 sees evidence → gh issue view returns CLOSED
  # → clears stale evidence → continues to Sources 2/3 → creates new follow-up.
  run_assess_and_resolve "$_pr" "$_issue"
  [ "$status" -eq 0 ] || {
    echo "FAIL: second run exited $status (expected 0)"
    echo "$output"
    false
  }

  # A new follow-up must have been created — total issues in state is now
  # baseline+2: the original CLOSED follow-up plus the newly created one.
  local _total _expected_total
  _total=$(jq 'length' "$GH_MOCK_STATE_DIR/issues.json")
  _expected_total=$(( _baseline_count + 2 ))
  [ "$_total" -eq "$_expected_total" ] || {
    echo "FAIL: expected $_expected_total issues (baseline $_baseline_count + original CLOSED + new follow-up), got $_total"
    jq '[.[] | {number, state, title}]' "$GH_MOCK_STATE_DIR/issues.json"
    false
  }

  # Evidence must now point to the new OPEN issue, NOT the old CLOSED one.
  # The CLOSED branch clears the old evidence; the creation path then writes
  # fresh evidence for the new issue.
  local _new_evidence_num
  _new_evidence_num=$(cat "$_evidence_file" 2>/dev/null || echo "")
  [ "$_new_evidence_num" != "$_evidenced_issue_num" ] || {
    echo "FAIL: evidence still points to original CLOSED issue #$_evidenced_issue_num"
    echo "Expected: a different (new) issue number"
    false
  }
  [[ "$_new_evidence_num" =~ ^[0-9]+$ ]] || {
    echo "FAIL: new evidence content '$_new_evidence_num' is not a valid issue number"
    false
  }

  # The new follow-up must be OPEN.
  # Use _new_evidence_num (from the evidence file) to look up the specific newly
  # created issue — .[0] would pick an arbitrary pre-existing issue when
  # baseline > 0, causing a vacuous pass even if no new issue was created.
  local _new_issue_state
  _new_issue_state=$(jq -r \
    --argjson num "$_new_evidence_num" \
    '.[] | select(.number == $num) | .state' \
    "$GH_MOCK_STATE_DIR/issues.json" 2>/dev/null || true)
  [ "$_new_issue_state" = "OPEN" ] || {
    echo "FAIL: new follow-up issue #$_new_evidence_num state is '$_new_issue_state' (expected OPEN)"
    false
  }
}

# ---------------------------------------------------------------------------
# 11. CLOSED-evidence output: script logs the stale-evidence message
# ---------------------------------------------------------------------------

@test "integration: CLOSED evidenced issue produces stale-evidence log message" {
  # Verify the informational message emitted by the CLOSED-evidence branch.
  # assess-and-resolve.sh:1182 outputs to stderr:
  #   "Local evidence points to issue #N (state: CLOSED) — removing stale evidence file..."
  # bats $output captures both stdout and stderr (via combined redirection in `run`).

  # Explicit cleanup at test start: same guard as test 10 — covers partial-failure
  # scenarios where a prior run did not complete teardown.
  rm -f "$RITE_LOCK_DIR"/* 2>/dev/null || true
  setup_gh_mock_state

  local _pr=61
  local _issue=31

  # Explicit mock data setup for PR 61 / issue 31.
  # gh-mock-binary.sh serves GH_MOCK_PR_VIEW_FILE for any pr view call — the mock
  # is PR-number-agnostic, so writing a fresh fixture here (rather than relying on
  # the setup() default) confirms the review data is present and valid for this test.
  _write_pr_view_json "$_REVIEW_WITH_FINDINGS"

  # First run: creates a follow-up and writes evidence.
  run_assess_and_resolve "$_pr" "$_issue"
  [ "$status" -eq 0 ]

  local _evidence_file="$RITE_LOCK_DIR/pr-${_pr}-src-${_issue}-followup-created.txt"
  local _evidenced_num
  _evidenced_num=$(cat "$_evidence_file" 2>/dev/null || echo "")
  [[ "$_evidenced_num" =~ ^[0-9]+$ ]] || {
    echo "FAIL: could not read evidenced issue number from $_evidence_file"
    false
  }

  # Close the evidenced issue.
  _gh_mock_state_issue_set_state "$_evidenced_num" "CLOSED"

  # Second run: should emit the stale-evidence message.
  run_assess_and_resolve "$_pr" "$_issue"
  [ "$status" -eq 0 ] || {
    echo "FAIL: second run exited $status (expected 0)"
    echo "$output"
    false
  }

  # Output must mention stale evidence removal.
  echo "$output" | grep -qi "stale evidence\|removing stale\|stale evidence file" || {
    echo "FAIL: output does not mention stale evidence clearing"
    echo "Output: ${output:0:800}"
    false
  }
}
