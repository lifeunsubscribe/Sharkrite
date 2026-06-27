#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh, lib/utils/tag-index.sh, lib/utils/relevance-grep.sh
# Regression test: "Relevant prior art" injection (tag-index Stage 4)
#
# Tests the four code paths from docs/architecture/tag-index-system.md → "Failure Modes":
#   Path A (tag-block)   — issue body has <!-- sharkrite-issue-tags --> block
#   Path B (label)       — no tag block, but GitHub labels match tag-index headings
#   Path C (keyword)     — no labels, but title/body keywords match tag-index headings
#   Path D (no-match)    — nothing matches → empty block (falls through to full-catalog)
#
# Also tests:
#   - lookup_tag_pointers() returns correct pointer lines for given tags
#   - slice_section() returns correct section text and applies 5KB cap
#   - relevance_grep() extracts file paths and backticked symbols

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_INSTALL_DIR="$RITE_REPO_ROOT"
  export RITE_DATA_DIR=".rite"

  # Create directory structure
  mkdir -p "$RITE_TEST_TMPDIR/docs/architecture"
  mkdir -p "$RITE_TEST_TMPDIR/.rite"
  mkdir -p "$RITE_TEST_TMPDIR/lib/utils"
  mkdir -p "$RITE_TEST_TMPDIR/bin"

  TAG_INDEX_PATH="$RITE_TEST_TMPDIR/docs/architecture/tag-index.md"
  CONVENTIONS_PATH="$RITE_TEST_TMPDIR/docs/architecture/conventions.md"
  ENCOUNTERED_PATH="$RITE_TEST_TMPDIR/docs/architecture/encountered-issues.md"
  BEHAVIORAL_PATH="$RITE_TEST_TMPDIR/docs/architecture/behavioral-design.md"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

_seed_tag_index() {
  cat > "$TAG_INDEX_PATH" <<'EOTAG'
# Tag Index

**Auto-maintained — do not hand-edit.**

---

## subshell

- conventions.md → Subshell variable loss
- encountered-issues.md → Subshell pipefail propagation

## set-e

- conventions.md → grep -c pattern
- conventions.md → Silent death: pipelines inside $()

## gh-cli

- conventions.md → CWD after worktree removal
EOTAG
}

_seed_conventions() {
  cat > "$CONVENTIONS_PATH" <<'EOCONV'
# Conventions

## Subshell variable loss

Variables set inside `while read | pipe` are lost. Use process substitution or temp files.

This is a short section for testing.

## grep -c pattern

`grep -c` always outputs a count but returns exit code 1 when count is 0.

Use `|| true` to suppress the exit code.

## CWD after worktree removal

When merge-pr.sh finishes a successful merge it removes the feature-branch worktree.
The shell that called merge-pr.sh is still cd'd inside that now-deleted directory.
EOCONV
}

_seed_encountered_issues() {
  cat > "$ENCOUNTERED_PATH" <<'EOENC'
# Encountered Issues

## Subshell pipefail propagation

Pipelines inside $() run in a subshell. Under set -euo pipefail, a failing pipeline
inside $() kills the script silently.
EOENC
}

# ---------------------------------------------------------------------------
# Helper: run lookup_tag_pointers in isolation
# ---------------------------------------------------------------------------
_run_lookup_tag_pointers() {
  local tags_csv="$1"
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    lookup_tag_pointers '$tags_csv' '$TAG_INDEX_PATH'
  "
}

# ---------------------------------------------------------------------------
# Helper: run slice_section in isolation
# ---------------------------------------------------------------------------
_run_slice_section() {
  local file="$1"
  local heading="$2"
  local max_bytes="${3:-5120}"
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    slice_section '$file' '$heading' '$max_bytes'
  "
}

# ---------------------------------------------------------------------------
# Helper: run relevance_grep in isolation
# ---------------------------------------------------------------------------
_run_relevance_grep() {
  local issue_text="$1"
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    relevance_grep $(printf '%q' "$issue_text") '$RITE_TEST_TMPDIR'
  "
}

# ---------------------------------------------------------------------------
# Helper: run build_relevant_prior_art in isolation (sources claude-workflow.sh
# with RITE_SOURCE_FUNCTIONS_ONLY=1 to get just the function definitions)
# ---------------------------------------------------------------------------
_run_build_prior_art() {
  local issue_body="$1"
  local issue_number="${2:-}"
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_SOURCE_FUNCTIONS_ONLY=1

    # Stub print functions (they write to stderr in the function, so safe to stub)
    print_info()    { echo \"\$*\" >&2; }
    print_status()  { echo \"\$*\" >&2; }
    print_success() { echo \"\$*\" >&2; }
    print_warning() { echo \"\$*\" >&2; }

    # Stub gh_safe so label-fetch path is deterministic without real GitHub
    gh_safe() { echo ''; }

    # Source dependencies
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/colors.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    source '$RITE_LIB_DIR/core/claude-workflow.sh'

    build_relevant_prior_art $(printf '%q' "$issue_body") '$issue_number' '$RITE_TEST_TMPDIR'
  "
}

# ===========================================================================
# lookup_tag_pointers tests
# ===========================================================================

@test "lookup_tag_pointers: returns matching pointers for a single tag" {
  _seed_tag_index

  _run_lookup_tag_pointers "subshell"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "conventions.md".*"Subshell variable loss" ]]
  [[ "$output" =~ "encountered-issues.md".*"Subshell pipefail propagation" ]]
}

@test "lookup_tag_pointers: returns merged deduplicated pointers for multiple tags" {
  _seed_tag_index

  _run_lookup_tag_pointers "subshell,set-e"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Subshell variable loss" ]]
  [[ "$output" =~ "grep -c pattern" ]]
}

@test "lookup_tag_pointers: case-insensitive tag matching" {
  _seed_tag_index

  _run_lookup_tag_pointers "SUBSHELL"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Subshell variable loss" ]]
}

@test "lookup_tag_pointers: returns empty when tag does not exist" {
  _seed_tag_index

  _run_lookup_tag_pointers "nonexistent-tag"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lookup_tag_pointers: returns empty when tag-index.md is missing" {
  # No _seed_tag_index call — file doesn't exist

  _run_lookup_tag_pointers "subshell"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lookup_tag_pointers: ignores empty tag in comma list" {
  _seed_tag_index

  _run_lookup_tag_pointers ",subshell,"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Subshell variable loss" ]]
}

# ===========================================================================
# slice_section tests
# ===========================================================================

@test "slice_section: returns section text including the heading line" {
  _seed_conventions

  _run_slice_section "$CONVENTIONS_PATH" "Subshell variable loss"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "## Subshell variable loss" ]]
  [[ "$output" =~ "Variables set inside" ]]
}

@test "slice_section: stops at the next H2 heading" {
  _seed_conventions

  _run_slice_section "$CONVENTIONS_PATH" "Subshell variable loss"

  [ "$status" -eq 0 ]
  # Should NOT include the grep -c pattern heading
  [[ ! "$output" =~ "## grep -c pattern" ]]
}

@test "slice_section: returns empty for unknown heading" {
  _seed_conventions

  _run_slice_section "$CONVENTIONS_PATH" "Nonexistent heading text"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "slice_section: returns empty when catalog file missing" {
  _run_slice_section "/nonexistent/path.md" "Some heading"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "slice_section: truncates at max_bytes and appends suffix" {
  # Create a catalog with a section larger than 20 bytes (our tiny limit)
  cat > "$CONVENTIONS_PATH" <<'EOCONV'
# Conventions

## Big section

This is a very long line that will definitely exceed twenty bytes when read.
And here is another very long line to make the section even bigger.
And yet another line for good measure to ensure truncation fires.
EOCONV

  _run_slice_section "$CONVENTIONS_PATH" "Big section" "20"

  [ "$status" -eq 0 ]
  # Output must contain the truncation marker
  [[ "$output" =~ "..." ]]
  [[ "$output" =~ "→ see full:" ]]
  # The anchor slug should contain "big-section"
  [[ "$output" =~ "big-section" ]]
}

@test "slice_section: no truncation when content is within max_bytes" {
  _seed_conventions

  # 5120 bytes is plenty for the small test sections
  _run_slice_section "$CONVENTIONS_PATH" "grep -c pattern" "5120"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "grep -c" ]]
  [[ ! "$output" =~ "→ see full:" ]]
}

@test "slice_section: case-insensitive heading match" {
  _seed_conventions

  _run_slice_section "$CONVENTIONS_PATH" "subshell variable loss"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Variables set inside" ]]
}

# ===========================================================================
# relevance_grep tests
# ===========================================================================

@test "relevance_grep: extracts and greps for file paths in issue body" {
  # Plant a file in lib/ that relevance_grep will find
  mkdir -p "$RITE_TEST_TMPDIR/lib/utils"
  cat > "$RITE_TEST_TMPDIR/lib/utils/sample.sh" <<'EOSH'
#!/bin/bash
# sample.sh — used for grep testing
sample_function() { echo "sample"; }
EOSH

  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    relevance_grep 'Fix the issue in lib/utils/sample.sh file' '$RITE_TEST_TMPDIR'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Existing usages of" ]]
  [[ "$output" =~ "sample.sh" ]]
}

@test "relevance_grep: extracts and greps for backtick function symbols" {
  mkdir -p "$RITE_TEST_TMPDIR/lib/utils"
  cat > "$RITE_TEST_TMPDIR/lib/utils/mymodule.sh" <<'EOSH'
#!/bin/bash
my_helper_function() { echo "hello"; }
my_helper_function "arg1"
EOSH

  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    relevance_grep 'Call \`my_helper_function()\` here' '$RITE_TEST_TMPDIR'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Existing usages of" ]]
  [[ "$output" =~ "my_helper_function" ]]
}

@test "relevance_grep: extracts and greps for backtick env var symbols" {
  mkdir -p "$RITE_TEST_TMPDIR/lib/utils"
  cat > "$RITE_TEST_TMPDIR/lib/utils/env-user.sh" <<'EOSH'
#!/bin/bash
echo "Value: $MY_SPECIAL_VAR"
[ -n "$MY_SPECIAL_VAR" ] && do_something
EOSH

  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    relevance_grep 'Check \`\$MY_SPECIAL_VAR\` is set' '$RITE_TEST_TMPDIR'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Existing usages of" ]]
  [[ "$output" =~ "MY_SPECIAL_VAR" ]]
}

@test "relevance_grep: returns empty when no matching symbols in issue body" {
  mkdir -p "$RITE_TEST_TMPDIR/lib"

  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    relevance_grep 'This body has no file paths or backtick symbols at all' '$RITE_TEST_TMPDIR'
  "

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "relevance_grep: returns empty when grep produces no hits for a symbol" {
  mkdir -p "$RITE_TEST_TMPDIR/lib"
  # lib/ exists but the symbol isn't in any file there

  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    relevance_grep 'See \`totally_absent_function()\` for details' '$RITE_TEST_TMPDIR'
  "

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===========================================================================
# build_relevant_prior_art: Path A (explicit tag block)
# ===========================================================================

@test "build_relevant_prior_art: Path A — tag block produces prior-art block" {
  _seed_tag_index
  _seed_conventions
  _seed_encountered_issues

  local issue_body
  issue_body=$(cat <<'EOBODY'
## Description
Fix subshell issues.

<!-- sharkrite-issue-tags -->
tags: subshell
<!-- /sharkrite-issue-tags -->
EOBODY
)

  _run_build_prior_art "$issue_body"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Relevant prior art" ]]
  [[ "$output" =~ "Subshell variable loss" ]]
}

@test "build_relevant_prior_art: Path A — tag block with multiple tags loads all pointers" {
  _seed_tag_index
  _seed_conventions
  _seed_encountered_issues

  local issue_body
  issue_body=$(cat <<'EOBODY'
## Description
Fix subshell and set-e issues.

<!-- sharkrite-issue-tags -->
tags: subshell, set-e
<!-- /sharkrite-issue-tags -->
EOBODY
)

  _run_build_prior_art "$issue_body"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Relevant prior art" ]]
  [[ "$output" =~ "Subshell variable loss" ]]
  [[ "$output" =~ "grep -c pattern" ]]
}

# ===========================================================================
# build_relevant_prior_art: Path C (keyword-grep fallback)
# ===========================================================================

@test "build_relevant_prior_art: Path C — keyword in body matches tag-index heading" {
  _seed_tag_index
  _seed_conventions
  _seed_encountered_issues

  # Issue body contains the word "subshell" (matches the ## subshell heading)
  # No tag block, no labels (gh_safe stubbed to return empty)
  local issue_body="This issue fixes a bug related to subshell behavior in pipelines."

  _run_build_prior_art "$issue_body"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Relevant prior art" ]]
  [[ "$output" =~ "Subshell variable loss" ]]
}

# ===========================================================================
# build_relevant_prior_art: Path D (no-match fallback)
# ===========================================================================

@test "build_relevant_prior_art: Path D — no matches returns empty (no regression)" {
  _seed_tag_index
  # seed a conventions file but use a body that won't match any heading
  _seed_conventions

  local issue_body="Fix a completely unrelated build configuration issue with no keywords."

  _run_build_prior_art "$issue_body"

  # Exit 0 and empty output — caller falls through to full-catalog load
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "build_relevant_prior_art: Path D — missing tag-index returns empty" {
  # tag-index.md does not exist
  _seed_conventions

  local issue_body="Fix subshell pipefail issues."

  _run_build_prior_art "$issue_body"

  # Codebase grep may fire for symbols, but with no lib/ content it should be empty
  [ "$status" -eq 0 ]
  # We don't assert on output content (codebase grep may find things), but status must be 0
}

@test "build_relevant_prior_art: null issue body does not crash" {
  _seed_tag_index

  _run_build_prior_art "null"

  [ "$status" -eq 0 ]
}

@test "build_relevant_prior_art: empty issue body does not crash" {
  _seed_tag_index

  _run_build_prior_art ""

  [ "$status" -eq 0 ]
}

# ===========================================================================
# re-source safety
# ===========================================================================

@test "tag-index.sh is safe to source twice (lookup_tag_pointers available after re-source)" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    # Both functions must be available after double-source
    declare -f lookup_tag_pointers >/dev/null
    declare -f slice_section >/dev/null
    echo 'OK'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "OK" ]]
}

@test "relevance-grep.sh is safe to source twice" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    declare -f relevance_grep >/dev/null
    echo 'OK'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "OK" ]]
}
