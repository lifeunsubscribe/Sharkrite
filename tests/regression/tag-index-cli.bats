#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/tag-index.sh, bin/rite
# Regression test: tag-index CLI behavior (rite --tags)
#
# Tests that:
#   1. Missing tag-index.md prints stub message and exits 0
#   2. rite --tags prints the full index from a seeded file
#   3. rite --tags <tag> prints pointers for a specific tag
#   4. rite --tags <nonexistent> prints "no such tag" message
#   5. rite --tags --orphans lists untagged catalog headings
#   6. rite --tags --history returns the stub message
#   7. lib/utils/tag-index.sh is safe to source twice (re-source guard)
#   8. bin/rite contains the --tags dispatch

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_INSTALL_DIR="$RITE_REPO_ROOT"

  mkdir -p "$RITE_TEST_TMPDIR/.rite"
  mkdir -p "$RITE_TEST_TMPDIR/docs/architecture"

  TAG_INDEX_PATH="$RITE_TEST_TMPDIR/docs/architecture/tag-index.md"
  CONVENTIONS_PATH="$RITE_TEST_TMPDIR/docs/architecture/conventions.md"
  ENCOUNTERED_PATH="$RITE_TEST_TMPDIR/docs/architecture/encountered-issues.md"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: run show_tag_index directly (avoids full bin/rite setup)
# ---------------------------------------------------------------------------
_run_tag_index() {
  local subarg="${1:-}"
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    show_tag_index '$subarg'
  "
}

# ---------------------------------------------------------------------------
# Seed a hand-crafted tag-index.md for tests that need real data
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
- encountered-issues.md → Bare-prefix marker grep

## gh-cli

- conventions.md → CWD after worktree removal
EOTAG
}

# ---------------------------------------------------------------------------
# Seed a minimal conventions.md with some headings
# ---------------------------------------------------------------------------
_seed_conventions() {
  cat > "$CONVENTIONS_PATH" <<'EOCONV'
# Conventions

## CWD after worktree removal

Content here.

## grep -c pattern

Content here.

## Silent death: pipelines inside $()

Content here.

## Subshell variable loss

Content here.

## Some untagged convention

Content that has no tag pointing at it.
EOCONV
}

# ---------------------------------------------------------------------------
# Seed a minimal encountered-issues.md with some headings
# ---------------------------------------------------------------------------
_seed_encountered() {
  cat > "$ENCOUNTERED_PATH" <<'EOENC'
# Encountered Issues

## Subshell pipefail propagation

Entry here.

## Bare-prefix marker grep

Entry here.

## Untagged encountered issue

Entry with no tag pointer.
EOENC
}

# ===========================================================================
# Test 1: Missing tag-index.md → stub message, exit 0
# ===========================================================================

@test "missing tag-index.md prints stub message and exits 0" {
  # Ensure no tag-index.md exists
  rm -f "$TAG_INDEX_PATH"

  _run_tag_index ""

  [ "$status" -eq 0 ]
  [[ "$output" == *"No tag-index yet"* ]]
}

@test "missing tag-index.md stub message includes 'tags:' block hint" {
  rm -f "$TAG_INDEX_PATH"

  _run_tag_index ""

  [ "$status" -eq 0 ]
  [[ "$output" == *"tags:"* ]]
}

# ===========================================================================
# Test 2: rite --tags (full index)
# ===========================================================================

@test "full index shows tag count and pointer count in header" {
  _seed_tag_index

  _run_tag_index ""

  [ "$status" -eq 0 ]
  # Header: "Tag Index (3 tags, 6 pointers)"
  [[ "$output" == *"Tag Index"* ]]
  [[ "$output" == *"3 tags"* ]]
  [[ "$output" == *"6 pointers"* ]]
}

@test "full index lists all tag names" {
  _seed_tag_index

  _run_tag_index ""

  [ "$status" -eq 0 ]
  [[ "$output" == *"subshell"* ]]
  [[ "$output" == *"set-e"* ]]
  [[ "$output" == *"gh-cli"* ]]
}

@test "full index shows entry counts per tag" {
  _seed_tag_index

  _run_tag_index ""

  [ "$status" -eq 0 ]
  # subshell has 2 entries, set-e has 3, gh-cli has 1
  [[ "$output" == *"2 entries"* ]]
  [[ "$output" == *"3 entries"* ]]
  [[ "$output" == *"1 entry"* ]]
}

@test "full index shows pointer arrows for each tag" {
  _seed_tag_index

  _run_tag_index ""

  [ "$status" -eq 0 ]
  [[ "$output" == *"→ conventions.md → Subshell variable loss"* ]]
  [[ "$output" == *"→ conventions.md → grep -c pattern"* ]]
  [[ "$output" == *"→ conventions.md → CWD after worktree removal"* ]]
}

@test "full index shows untagged entry count at bottom" {
  _seed_tag_index

  _run_tag_index ""

  [ "$status" -eq 0 ]
  [[ "$output" == *"Untagged catalog entries:"* ]]
}

@test "full index suggests --orphans for untagged entries" {
  _seed_tag_index

  _run_tag_index ""

  [ "$status" -eq 0 ]
  [[ "$output" == *"--tags --orphans"* ]]
}

# ===========================================================================
# Test 3: rite --tags <tag> (single tag lookup)
# ===========================================================================

@test "single tag lookup returns pointers for known tag" {
  _seed_tag_index

  _run_tag_index "subshell"

  [ "$status" -eq 0 ]
  [[ "$output" == *"subshell"* ]]
  [[ "$output" == *"→ conventions.md → Subshell variable loss"* ]]
  [[ "$output" == *"→ encountered-issues.md → Subshell pipefail propagation"* ]]
}

@test "single tag lookup is case-insensitive" {
  _seed_tag_index

  _run_tag_index "SUBSHELL"

  [ "$status" -eq 0 ]
  [[ "$output" == *"subshell"* ]]
  [[ "$output" == *"→ conventions.md → Subshell variable loss"* ]]
}

@test "single tag lookup for set-e shows all three pointers" {
  _seed_tag_index

  _run_tag_index "set-e"

  [ "$status" -eq 0 ]
  [[ "$output" == *"→ conventions.md → grep -c pattern"* ]]
  [[ "$output" == *"→ conventions.md → Silent death: pipelines inside"* ]]
  [[ "$output" == *"→ encountered-issues.md → Bare-prefix marker grep"* ]]
}

# ===========================================================================
# Test 4: rite --tags <nonexistent> → "no such tag"
# ===========================================================================

@test "unknown tag prints 'No such tag' and exits 0" {
  _seed_tag_index

  _run_tag_index "nonexistent-tag"

  [ "$status" -eq 0 ]
  [[ "$output" == *"No such tag"* ]]
  [[ "$output" == *"nonexistent-tag"* ]]
}

@test "missing tag-index with single tag lookup prints stub message" {
  rm -f "$TAG_INDEX_PATH"

  _run_tag_index "subshell"

  [ "$status" -eq 0 ]
  [[ "$output" == *"No tag-index yet"* ]]
}

# ===========================================================================
# Test 5: rite --tags --orphans
# ===========================================================================

@test "--orphans lists untagged headings from conventions.md" {
  _seed_tag_index
  _seed_conventions

  _run_tag_index "--orphans"

  [ "$status" -eq 0 ]
  # "Some untagged convention" is not pointed at by any tag
  [[ "$output" == *"Some untagged convention"* ]]
}

@test "--orphans lists untagged headings from encountered-issues.md" {
  _seed_tag_index
  _seed_encountered

  _run_tag_index "--orphans"

  [ "$status" -eq 0 ]
  # "Untagged encountered issue" is not pointed at by any tag
  [[ "$output" == *"Untagged encountered issue"* ]]
}

@test "--orphans does NOT list headings that are already tagged" {
  _seed_tag_index
  _seed_conventions

  _run_tag_index "--orphans"

  [ "$status" -eq 0 ]
  # "CWD after worktree removal" IS pointed at by gh-cli tag — should not appear as orphan
  [[ "$output" != *"CWD after worktree removal"* ]]
}

@test "--orphans shows 'none' message when all entries are tagged" {
  _seed_tag_index
  # Create conventions.md with only entries that are pointed at
  cat > "$CONVENTIONS_PATH" <<'EOCONV'
# Conventions

## CWD after worktree removal

Content.
EOCONV

  _run_tag_index "--orphans"

  [ "$status" -eq 0 ]
  [[ "$output" == *"none"* ]] || [[ "$output" == *"all catalog headings are tagged"* ]]
}

@test "--orphans works gracefully when catalog files are missing" {
  _seed_tag_index
  # No conventions.md or encountered-issues.md

  _run_tag_index "--orphans"

  [ "$status" -eq 0 ]
}

@test "--orphans on missing tag-index prints stub message" {
  rm -f "$TAG_INDEX_PATH"
  _seed_conventions

  # When tag-index.md is missing, parse_tag_index fails → all headings are orphans
  _run_tag_index "--orphans"

  [ "$status" -eq 0 ]
  # All headings should show as orphans since there's no index
  [[ "$output" == *"Some untagged convention"* ]]
}

# ===========================================================================
# Test 6: rite --tags --history → stub message
# ===========================================================================

@test "--history returns stub message and exits 0" {
  _run_tag_index "--history"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no history yet"* ]]
}

@test "--history stub message mentions Stage 3" {
  _run_tag_index "--history"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Stage 3"* ]]
}

# ===========================================================================
# Test 7: Re-source guard
# ===========================================================================

@test "tag-index.sh is safe to source twice (re-source guard)" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    echo 'double-source-ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"double-source-ok"* ]]
}

# ===========================================================================
# Test 8: bin/rite dispatch (static code checks)
# ===========================================================================

@test "bin/rite contains --tags case in arg parsing" {
  run grep -q "\-\-tags)" "$RITE_REPO_ROOT/bin/rite"
  [ "$status" -eq 0 ]
}

@test "bin/rite dispatches --tags mode to tag-index.sh" {
  run grep -A3 "MODE.*=.*tags" "$RITE_REPO_ROOT/bin/rite"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tag-index"* ]]
}

@test "bin/rite --tags mode is in read-only skip-logging list" {
  # The logging-skip condition must include MODE="tags"
  run grep -q '"tags"' "$RITE_REPO_ROOT/bin/rite"
  [ "$status" -eq 0 ]
}
