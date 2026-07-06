#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/encountered-issues-renderer.sh, lib/utils/markers.sh
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
#   8. Harvests patterns from <!-- sharkrite-recurring-pattern --> body marker blocks
#   9. Format-anchor guard: a body that only documents the marker string does NOT match
#  10. Transition: marker and legacy label results are unioned and deduplicated
#  11. PR bodies with the marker block are ingested as entries
#  12. All gh fetches use --limit 1000 (durability: aged issues not dropped from catalog)

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

  # The stub handles three query types:
  #   1. issue list --label recurring-pattern  → 3 legacy-labeled issues (no body marker)
  #   2. issue list --search "sharkrite-recurring-pattern in:body" → empty (default setup)
  #   3. pr list   --search "sharkrite-recurring-pattern in:body" → empty (default setup)
  # Issues are returned out of order to verify sort-by-number behaviour.
  cat > "$MOCK_BIN/gh" <<'MOCK_EOF'
#!/bin/bash
# Mock gh: returns preset JSON for the issue list query; no-ops for anything else.

_args="$*"

# Legacy label query: issue list --label recurring-pattern
if echo "$_args" | grep -q "issue list" && echo "$_args" | grep -q -- "--label"; then
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

# Marker-search queries (issue list --search / pr list --search): return empty by default.
# Individual tests override this mock to return marker-carrying bodies.
if echo "$_args" | grep -q "issue list" && echo "$_args" | grep -q -- "--search"; then
  echo "[]"
  exit 0
fi
if echo "$_args" | grep -q "pr list" && echo "$_args" | grep -q -- "--search"; then
  echo "[]"
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

# ---------------------------------------------------------------------------
# Test 15: _extract_marker_block extracts content from a well-formed body
# (unit test for the format-anchored block extractor)
# ---------------------------------------------------------------------------

@test "_extract_marker_block returns block content from a body with the marker" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export PATH='$MOCK_BIN:$PATH'
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_REPO_ROOT/lib/utils/markers.sh'
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_REPO_ROOT/lib/utils/encountered-issues-renderer.sh'
    set +u; set +o pipefail
    BODY=\$(printf '%s\n' \
      'Some prose before.' \
      '<!-- sharkrite-recurring-pattern -->' \
      '**Pattern:** Unanchored grep' \
      '**Root Cause:** grep -q without format anchor matches documentation examples' \
      '**Mitigation:** Use grep -qE with digit anchor ([0-9]+)' \
      '<!-- /sharkrite-recurring-pattern -->' \
      'Some prose after.')
    _extract_marker_block \"\$BODY\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Pattern:** Unanchored grep"* ]]
  [[ "$output" == *"**Root Cause:**"* ]]
  [[ "$output" == *"**Mitigation:**"* ]]
  # Prose outside the block must not appear
  [[ "$output" != *"Some prose before"* ]]
  [[ "$output" != *"Some prose after"* ]]
}

# ---------------------------------------------------------------------------
# Test 16: _extract_marker_block returns empty for a body with bare marker text
# (format-anchor guard — bare-prefix-guard rule)
# ---------------------------------------------------------------------------

@test "_extract_marker_block returns empty for body that only documents the marker string" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export PATH='$MOCK_BIN:$PATH'
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_REPO_ROOT/lib/utils/markers.sh'
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_REPO_ROOT/lib/utils/encountered-issues-renderer.sh'
    set +u; set +o pipefail
    # Body documents the marker in a code span — not a real HTML comment block
    BODY='To add a pattern use sharkrite-recurring-pattern in your issue body.'
    result=\$(_extract_marker_block \"\$BODY\")
    if [ -n \"\$result\" ]; then
      echo \"FAIL: extracted non-empty block from documentation-only body: \$result\"
      exit 1
    fi
    echo 'empty-ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty-ok"* ]]
}

# ---------------------------------------------------------------------------
# Test 17: _extract_marker_block rejects marker inside a fenced code block
# (fence guard — prevents code examples from being ingested as real entries)
# ---------------------------------------------------------------------------

@test "_extract_marker_block rejects marker inside fenced code block" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export PATH='$MOCK_BIN:$PATH'
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_REPO_ROOT/lib/utils/markers.sh'
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_REPO_ROOT/lib/utils/encountered-issues-renderer.sh'
    set +u; set +o pipefail
    # Marker inside a fenced code block — must not be extracted.
    # Build with printf so bats preprocessor does not rewrite @test-like lines.
    # FENCE var holds the triple-backtick string to avoid literal backtick issues.
    FENCE='```'
    BODY=\$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
      'Example format:' \
      "\$FENCE" \
      '<!-- sharkrite-recurring-pattern -->' \
      '**Pattern:** Example only' \
      '<!-- /sharkrite-recurring-pattern -->' \
      "\$FENCE")
    result=\$(_extract_marker_block \"\$BODY\")
    if [ -n \"\$result\" ]; then
      echo \"FAIL: extracted block from inside fenced code: \$result\"
      exit 1
    fi
    echo 'fence-guard-ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"fence-guard-ok"* ]]
}

# ---------------------------------------------------------------------------
# Test 18: renderer ingests an issue whose body carries the marker block
# (primary harvest path — marker takes priority over legacy label)
# ---------------------------------------------------------------------------

@test "renderer ingests issue with body marker block and renders its content" {
  # Override mock gh to return one issue with a real marker block in its body
  # for the --search query path; nothing for the legacy --label path.
  # Body uses JSON \n escapes so jq -r produces real newlines on extraction.
  cat > "$MOCK_BIN/gh" <<'MARKER_MOCK'
#!/bin/bash
_args="$*"
# Marker-search query: return one issue with a real recurring-pattern block
if echo "$_args" | grep -q "issue list" && echo "$_args" | grep -q -- "--search"; then
  cat <<'JSON'
[{"number":55,"title":"BSD date -d crashes on macOS","body":"Some prose.\n<!-- sharkrite-recurring-pattern -->\n**Pattern:** BSD date -d not portable\n**Root Cause:** GNU date -d parses date strings; BSD date -d does not exist\n**Mitigation:** Use date -jf on macOS with detection guard\n<!-- /sharkrite-recurring-pattern -->\nMore prose.","closedAt":"2026-07-01T12:00:00Z","closedByPullRequestsReferences":[{"number":99}]}]
JSON
  exit 0
fi
# Legacy label query and pr list: return empty for this test
echo "[]"
exit 0
MARKER_MOCK
  chmod +x "$MOCK_BIN/gh"

  _run_renderer

  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_FILE" ]

  # The marker block content must appear in the output
  run grep -q "BSD date -d not portable" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]

  run grep -q "GNU date -d parses" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]

  # The issue title must appear
  run grep -q "BSD date -d crashes on macOS" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 19: transition — marker-path and legacy-label-path results are unioned
# and deduplicated (same issue number appears in both sources → one entry)
# ---------------------------------------------------------------------------

@test "transition: marker-path and legacy-label-path results deduplicate by number" {
  # Override mock: marker search returns issue #7 with a body marker;
  # legacy label query returns issues #7 and #42 (without a body marker).
  # After dedup, #7 appears once (from marker path, higher priority).
  cat > "$MOCK_BIN/gh" <<'DEDUP_MOCK'
#!/bin/bash
_args="$*"
# Marker-search issues: issue #7 WITH body marker
if echo "$_args" | grep -q "issue list" && echo "$_args" | grep -q -- "--search"; then
  cat <<'JSON'
[{"number":7,"title":"local outside function","body":"<!-- sharkrite-recurring-pattern -->\n**Pattern:** local outside function\n**Mitigation:** LOCAL_OUTSIDE_FUNCTION lint rule\n<!-- /sharkrite-recurring-pattern -->","closedAt":"2026-05-10T08:00:00Z","closedByPullRequestsReferences":[{"number":9}]}]
JSON
  exit 0
fi
# Legacy label: issues #7 and #42 (without body marker)
if echo "$_args" | grep -q "issue list" && echo "$_args" | grep -q -- "--label"; then
  cat <<'JSON'
[{"number":7,"title":"local outside function","body":"No marker here.","closedAt":"2026-05-10T08:00:00Z","closedByPullRequestsReferences":[{"number":9}]},{"number":42,"title":"Batch reporter","body":"No marker.","closedAt":"2026-05-15T10:00:00Z","closedByPullRequestsReferences":[{"number":88}]}]
JSON
  exit 0
fi
# PR search: empty
echo "[]"
exit 0
DEDUP_MOCK
  chmod +x "$MOCK_BIN/gh"

  _run_renderer

  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_FILE" ]

  # Both issues must appear (union)
  run grep -q "local outside function" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
  run grep -q "Batch reporter" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]

  # Issue #7 must appear exactly once (dedup)
  run bash -c "grep -c '^\*\*Issue:\*\* \[#7\]' '$OUTPUT_FILE' || true"
  [ "$output" -eq 1 ]

  # The marker block content (from the primary path) must be rendered for #7
  run grep -q "LOCAL_OUTSIDE_FUNCTION lint rule" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 20: markers.sh exports RITE_MARKER_RECURRING_PATTERN
# ---------------------------------------------------------------------------

@test "markers.sh defines RITE_MARKER_RECURRING_PATTERN constant" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export PATH='$MOCK_BIN:$PATH'
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_REPO_ROOT/lib/utils/markers.sh'
    echo \"\$RITE_MARKER_RECURRING_PATTERN\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "sharkrite-recurring-pattern" ]
}

# ---------------------------------------------------------------------------
# Test 21: all gh fetches in render_encountered_issues use --limit 1000
# (durability: aged marker-carrying issues are not silently dropped from the
# catalog as the repo grows past the old 200/300-result window — issue #923)
# ---------------------------------------------------------------------------

@test "all gh fetches in render_encountered_issues use --limit 1000 (not 200 or 300)" {
  local renderer="$RITE_REPO_ROOT/lib/utils/encountered-issues-renderer.sh"

  # Verify --limit 1000 appears on exactly five gh_safe argument lines (server
  # issues, backstop issues, server PRs, backstop PRs, legacy label).
  # Match the continuation-line pattern "    --limit 1000 2>/dev/null" which
  # appears only on real call sites, not in comments (comments end at EOL, not
  # with a redirection suffix).  gh_safe and --limit are on separate continuation
  # lines so the old "grep gh_safe | grep --limit" pipeline always matched 0.
  run bash -c "grep -c -- '--limit 1000 2>/dev/null' '$renderer' || true"
  [ "$status" -eq 0 ]
  # Must be exactly 5 — one per gh_safe call site; any fewer means a call site
  # was silently dropped and the durability guarantee is broken.
  [ "$output" -eq 5 ]

  # No surviving --limit 200 or --limit 300 on call-site lines (the 2>/dev/null
  # suffix distinguishes call lines from comment lines that may mention old caps).
  run bash -c "grep -c -- '--limit 200 2>/dev/null' '$renderer' || true"
  [ "$output" -eq 0 ]

  run bash -c "grep -c -- '--limit 300 2>/dev/null' '$renderer' || true"
  [ "$output" -eq 0 ]
}
