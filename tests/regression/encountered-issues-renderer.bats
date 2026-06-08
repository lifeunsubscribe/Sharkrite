#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/encountered-issues-renderer.sh
# Regression test for: encountered-issues-renderer.sh
#
# Tests that the renderer:
#   1. Fetches closed issues with `recurring-pattern` label via gh
#   2. Produces correctly structured markdown (header, TOC, entries)
#   3. Sorts entries by issue number ascending (stable output)
#   4. Is idempotent: running twice produces byte-identical output
#   5. Handles the empty-issues case (no labeled issues) gracefully
#   6. Extracts **Description**: text from the standard Sharkrite issue template
#   7. bin/rite --refresh-encountered-issues flag dispatches to the renderer

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_INSTALL_DIR="$RITE_REPO_ROOT"
  mkdir -p "$RITE_TEST_TMPDIR/.rite"
  mkdir -p "$RITE_TEST_TMPDIR/docs/architecture"

  # Mock gh: write a stub that echoes preset JSON based on arguments.
  # Placed in a temp bin dir that is prepended to PATH.
  MOCK_BIN="$RITE_TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_BIN"

  # The stub returns 3 issues when called with the recurring-pattern label query.
  # Issues are returned out of order to verify sort-by-number behaviour.
  cat > "$MOCK_BIN/gh" <<'MOCK_EOF'
#!/bin/bash
# Mock gh: returns preset JSON for the issue list query; no-ops for anything else.

# Detect the issue list query by looking for --label in the args
_args="$*"
if echo "$_args" | grep -q "issue list" && echo "$_args" | grep -q "recurring-pattern"; then
  cat <<'JSON'
[
  {
    "number": 42,
    "title": "Batch reporter ignores deferred issues",
    "body": "## Bug confirmation (run FIRST, do not skip)\n\nSome confirmation steps.\n\n---\n\n**Time**: 30min\n\n**Description**:\nBatch reporter under-counts skipped issues when the skip reason is `waiting_for_parent`. Users see Skipped: 0 but an issue was silently deferred.\n\n**Acceptance Criteria**:\n- [ ] Fix the counter\n",
    "closedAt": "2026-05-15T10:00:00Z",
    "closedByPullRequestsReferences": [
      {"number": 88, "url": "https://github.com/example/repo/pull/88", "repository": {"owner": {"login": "example"}, "name": "repo"}}
    ]
  },
  {
    "number": 7,
    "title": "local outside function crashes worktree creation",
    "body": "## Bug confirmation (run FIRST, do not skip)\n\nConfirmation steps here.\n\n---\n\n**Time**: 45min\n\n**Description**:\n`local base_ref` placed outside a function body. Under `set -euo pipefail`, `local` outside a function crashes with \"local: can only be used in a function\".\n\n**Acceptance Criteria**:\n- [ ] Lint rule added\n",
    "closedAt": "2026-05-10T08:00:00Z",
    "closedByPullRequestsReferences": [
      {"number": 9, "url": "https://github.com/example/repo/pull/9", "repository": {"owner": {"login": "example"}, "name": "repo"}}
    ]
  },
  {
    "number": 23,
    "title": "Silent death: grep no-match in subshell kills script",
    "body": "## Bug confirmation (run FIRST, do not skip)\n\nConfirmation here.\n\n---\n\n**Time**: 2hr\n\n**Description**:\nPipeline inside `$()` that ends in `grep` silently kills the script when grep finds no match under `set -euo pipefail`.\n\n**Acceptance Criteria**:\n- [ ] Add || true everywhere\n",
    "closedAt": "2026-05-12T14:30:00Z",
    "closedByPullRequestsReferences": [
      {"number": 31, "url": "https://github.com/example/repo/pull/31", "repository": {"owner": {"login": "example"}, "name": "repo"}},
      {"number": 35, "url": "https://github.com/example/repo/pull/35", "repository": {"owner": {"login": "example"}, "name": "repo"}}
    ]
  }
]
JSON
  exit 0
fi

# No-op for any other gh invocation
exit 0
MOCK_EOF
  chmod +x "$MOCK_BIN/gh"

  # Prepend mock-bin to PATH so the renderer uses our stub gh
  export PATH="$MOCK_BIN:$PATH"

  export OUTPUT_FILE="$RITE_TEST_TMPDIR/docs/architecture/encountered-issues.md"

  RENDERER="$RITE_REPO_ROOT/lib/utils/encountered-issues-renderer.sh"
  [ -f "$RENDERER" ] || {
    echo "setup: renderer not found at $RENDERER (RITE_REPO_ROOT=$RITE_REPO_ROOT)" >&2
    false
  }
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: run the renderer in a subprocess (avoids polluting test env)
# ---------------------------------------------------------------------------
_run_renderer() {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export OUTPUT_FILE='$OUTPUT_FILE'
    export PATH='$MOCK_BIN:$PATH'
    RITE_SOURCE_FUNCTIONS_ONLY=0 source '$RITE_REPO_ROOT/lib/utils/encountered-issues-renderer.sh'
  "
}

# ---------------------------------------------------------------------------
# Test 1: renderer exits 0 and produces the output file
# ---------------------------------------------------------------------------

@test "renderer exits 0 and creates the output file" {
  _run_renderer

  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_FILE" ]
}

# ---------------------------------------------------------------------------
# Test 2: output file contains the auto-generated header comment
# ---------------------------------------------------------------------------

@test "output file contains auto-generated header comment" {
  _run_renderer

  [ -f "$OUTPUT_FILE" ]
  run grep -c "Auto-generated" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 3: output file contains "Do not hand-edit" in the header
# ---------------------------------------------------------------------------

@test "output file includes 'Do not hand-edit' warning" {
  _run_renderer

  [ -f "$OUTPUT_FILE" ]
  run grep -q "Do not hand-edit" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 4: output file contains 'rite --refresh-encountered-issues' instruction
# ---------------------------------------------------------------------------

@test "output file includes refresh command instruction" {
  _run_renderer

  [ -f "$OUTPUT_FILE" ]
  run grep -q "refresh-encountered-issues" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 5: entries are sorted by issue number ascending (7, 23, 42)
# ---------------------------------------------------------------------------

@test "entries are sorted by issue number ascending" {
  _run_renderer

  [ -f "$OUTPUT_FILE" ]

  # Extract issue numbers from TOC lines (format: "- [#N: ...](...)")
  # TOC lines start with "- [#" and contain the issue number before the colon
  run bash -c "grep -oE '^- \[#[0-9]+:' '$OUTPUT_FILE' | grep -oE '[0-9]+' | head -3 | tr '\n' ',' || true"
  [ "$status" -eq 0 ]

  # TOC entries should appear in ascending order: 7, 23, 42
  [[ "$output" == "7,23,42," ]]
}

# ---------------------------------------------------------------------------
# Test 6: all three issue titles appear in the output
# ---------------------------------------------------------------------------

@test "output includes all three issue titles" {
  _run_renderer

  [ -f "$OUTPUT_FILE" ]

  run grep -c "Batch reporter ignores deferred issues" "$OUTPUT_FILE"
  [ "$output" -ge 1 ]

  run grep -c "local outside function" "$OUTPUT_FILE"
  [ "$output" -ge 1 ]

  run grep -c "Silent death" "$OUTPUT_FILE"
  [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 7: PR references appear in the output
# ---------------------------------------------------------------------------

@test "output includes PR references" {
  _run_renderer

  [ -f "$OUTPUT_FILE" ]
  run grep -q "PR \[#9\]" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]

  run grep -q "PR \[#31\]" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]

  run grep -q "PR \[#88\]" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 8: Description text is extracted from the standard Sharkrite template
# ---------------------------------------------------------------------------

@test "Description field is extracted from standard issue template format" {
  _run_renderer

  [ -f "$OUTPUT_FILE" ]

  # Issue #7's Description should be present (not the bug confirmation text)
  run grep -q "local: can only be used in a function" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]

  # The Bug Confirmation boilerplate should NOT appear
  run grep -c "Bug confirmation" "$OUTPUT_FILE"
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 9: Idempotency — running twice produces byte-identical output
# (minus the Last refreshed date comment, which changes daily)
# ---------------------------------------------------------------------------

@test "renderer is idempotent: second run produces identical content" {
  _run_renderer
  local first_run
  first_run=$(grep -v "Last refreshed:" "$OUTPUT_FILE" || true)

  _run_renderer
  local second_run
  second_run=$(grep -v "Last refreshed:" "$OUTPUT_FILE" || true)

  [ "$first_run" = "$second_run" ]
}

# ---------------------------------------------------------------------------
# Test 10: Empty case — no labeled issues → placeholder message
# ---------------------------------------------------------------------------

@test "empty issue list produces placeholder message" {
  # Override mock gh to return empty array for this test
  cat > "$MOCK_BIN/gh" <<'EMPTY_MOCK'
#!/bin/bash
echo "[]"
exit 0
EMPTY_MOCK
  chmod +x "$MOCK_BIN/gh"

  _run_renderer

  [ -f "$OUTPUT_FILE" ]
  run grep -q "No recurring patterns recorded" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 11: Table of Contents section is present
# ---------------------------------------------------------------------------

@test "output includes Table of Contents section" {
  _run_renderer

  [ -f "$OUTPUT_FILE" ]
  run grep -q "## Table of Contents" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 12: Multiple PRs for a single issue are all listed
# ---------------------------------------------------------------------------

@test "multiple closing PRs for one issue are all listed" {
  _run_renderer

  [ -f "$OUTPUT_FILE" ]
  # Issue #23 has PRs #31 and #35
  run grep -q "PR \[#31\]" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
  run grep -q "PR \[#35\]" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 13: bin/rite --refresh-encountered-issues dispatches to renderer
# (static code check — no network calls)
# ---------------------------------------------------------------------------

@test "bin/rite contains --refresh-encountered-issues case" {
  run grep -q "refresh-encountered-issues" "$RITE_REPO_ROOT/bin/rite"
  [ "$status" -eq 0 ]
}

@test "bin/rite dispatches --refresh-encountered-issues to renderer" {
  # Verify the dispatch block sources the renderer and calls render_encountered_issues
  run grep -A3 "MODE.*=.*refresh-encountered-issues" "$RITE_REPO_ROOT/bin/rite"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "encountered-issues-renderer" ]]
}

# ---------------------------------------------------------------------------
# Test 14: renderer is safe to source multiple times (re-source guard)
# ---------------------------------------------------------------------------

@test "renderer is safe to source twice (re-source guard)" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export OUTPUT_FILE='$OUTPUT_FILE'
    export PATH='$MOCK_BIN:$PATH'
    export RITE_SOURCE_FUNCTIONS_ONLY=1
    source '$RITE_REPO_ROOT/lib/utils/encountered-issues-renderer.sh'
    source '$RITE_REPO_ROOT/lib/utils/encountered-issues-renderer.sh'
    echo 'double-source-ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"double-source-ok"* ]]
}
