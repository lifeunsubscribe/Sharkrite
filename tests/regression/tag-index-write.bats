#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/tag-index.sh
# Regression test: tag-index write helpers (Stage 2)
#
# Tests that:
#   1. tag_index_ensure_file() creates tag-index.md with bootstrap scaffold
#   2. tag_index_ensure_file() is a no-op when the file already exists
#   3. tag_index_ensure_heading() creates a new ## heading when missing
#   4. tag_index_ensure_heading() is a no-op when the heading already exists
#   5. tag_index_add_pointer() adds a pointer line under the correct heading
#   6. tag_index_add_pointer() is idempotent (re-running does not duplicate)
#   7. tag_index_add_pointer() adds pointer only under the target heading
#   8. update_tag_index_from_block() tags: field updates tag-index.md
#   9. update_tag_index_from_block() new-tags: field creates new headings
#  10. update_tag_index_from_block() with no tags is a no-op
#  11. update_tag_index_from_block() bootstraps tag-index.md if missing
#  12. tag_index_add_pointer() returns 1 when heading is absent (not silent no-op)
#  13. tag_index_add_pointer() prints error to stderr when heading is absent
#  14. tag_index_add_pointer() does not modify the file when heading is absent

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_INSTALL_DIR="$RITE_REPO_ROOT"

  mkdir -p "$RITE_TEST_TMPDIR/docs/architecture"

  TAG_INDEX_PATH="$RITE_TEST_TMPDIR/docs/architecture/tag-index.md"

  # Source logging stubs (verbose_info is called by update_tag_index_from_block)
  verbose_info() { :; }
  export -f verbose_info

  # Source tag-index.sh to load write helpers
  source "$RITE_LIB_DIR/utils/tag-index.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# tag_index_ensure_file()
# ---------------------------------------------------------------------------

@test "tag_index_ensure_file: creates tag-index.md when missing" {
  [ ! -f "$TAG_INDEX_PATH" ]
  tag_index_ensure_file
  [ -f "$TAG_INDEX_PATH" ]
}

@test "tag_index_ensure_file: bootstrap contains expected header" {
  tag_index_ensure_file
  grep -q "^# Tag Index$" "$TAG_INDEX_PATH"
  grep -q "Auto-maintained" "$TAG_INDEX_PATH"
}

@test "tag_index_ensure_file: no-op when file already exists" {
  echo "existing content" > "$TAG_INDEX_PATH"
  local before
  before=$(cat "$TAG_INDEX_PATH")
  tag_index_ensure_file
  local after
  after=$(cat "$TAG_INDEX_PATH")
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# tag_index_ensure_heading()
# ---------------------------------------------------------------------------

@test "tag_index_ensure_heading: creates a new heading when missing" {
  tag_index_ensure_file
  tag_index_ensure_heading "set-e"
  grep -qxF "## set-e" "$TAG_INDEX_PATH"
}

@test "tag_index_ensure_heading: idempotent — no duplicate when heading exists" {
  tag_index_ensure_file
  tag_index_ensure_heading "set-e"
  tag_index_ensure_heading "set-e"
  local count
  count=$(grep -c "^## set-e$" "$TAG_INDEX_PATH" || true)
  [ "$count" -eq 1 ]
}

@test "tag_index_ensure_heading: creates multiple independent headings" {
  tag_index_ensure_file
  tag_index_ensure_heading "foo"
  tag_index_ensure_heading "bar"
  grep -qxF "## foo" "$TAG_INDEX_PATH"
  grep -qxF "## bar" "$TAG_INDEX_PATH"
}

# ---------------------------------------------------------------------------
# tag_index_add_pointer()
# ---------------------------------------------------------------------------

@test "tag_index_add_pointer: adds pointer under the correct heading" {
  cat > "$TAG_INDEX_PATH" <<'EOF'
# Tag Index

**Auto-maintained.**

---

## grep-c

EOF
  tag_index_add_pointer "grep-c" "conventions.md" "grep -c pattern"
  # Pointer must be present in the file (use -F without -x: BSD grep on macOS
  # chokes on -xF with multi-byte UTF-8 characters like → in the pattern)
  grep -qF "conventions.md → grep -c pattern" "$TAG_INDEX_PATH"
}

@test "tag_index_add_pointer: idempotent — second call does not duplicate pointer" {
  cat > "$TAG_INDEX_PATH" <<'EOF'
# Tag Index

**Auto-maintained.**

---

## grep-c

EOF
  tag_index_add_pointer "grep-c" "conventions.md" "grep -c pattern"
  tag_index_add_pointer "grep-c" "conventions.md" "grep -c pattern"
  local count
  count=$(grep -c "conventions.md → grep -c pattern" "$TAG_INDEX_PATH" || true)
  [ "$count" -eq 1 ]
}

@test "tag_index_add_pointer: does not add pointer to wrong heading section" {
  cat > "$TAG_INDEX_PATH" <<'EOF'
# Tag Index

**Auto-maintained.**

---

## section-a

## section-b

EOF
  tag_index_add_pointer "section-a" "conventions.md" "My Convention"

  # Pointer must appear under section-a
  awk '/^## section-a$/{found=1} found && /conventions.md.*My Convention/{exit 0} found && /^## section-b$/{exit 1}' \
    "$TAG_INDEX_PATH"

  # Pointer must NOT appear under section-b
  local in_b=0
  local found_ptr=0
  while IFS= read -r _line; do
    [ "$_line" = "## section-b" ] && in_b=1
    if [ "$in_b" -eq 1 ] && echo "$_line" | grep -q "conventions.md"; then
      found_ptr=1
    fi
  done < "$TAG_INDEX_PATH"
  [ "$found_ptr" -eq 0 ]
}

@test "tag_index_add_pointer: same convention title can appear under two different tags" {
  cat > "$TAG_INDEX_PATH" <<'EOF'
# Tag Index

**Auto-maintained.**

---

## set-e

## subshell

EOF
  tag_index_add_pointer "set-e"    "conventions.md" "Shared Convention"
  tag_index_add_pointer "subshell" "conventions.md" "Shared Convention"

  # Count total pointer lines — must be exactly 2 (one per tag section)
  local count
  count=$(grep -c "conventions.md → Shared Convention" "$TAG_INDEX_PATH" || true)
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# update_tag_index_from_block()
# ---------------------------------------------------------------------------

@test "update_tag_index_from_block: tags: field adds pointers to existing headings" {
  cat > "$TAG_INDEX_PATH" <<'EOF'
# Tag Index

**Auto-maintained.**

---

## foo

## bar

EOF
  update_tag_index_from_block "foo, bar" "" "conventions.md" "My Convention" "42"
  # BSD grep on macOS chokes on -xF with multi-byte UTF-8 chars (→) in the pattern
  grep -qF "conventions.md → My Convention" "$TAG_INDEX_PATH"
  # Verify pointer appears twice (once under ## foo, once under ## bar)
  local count
  count=$(grep -c "conventions.md → My Convention" "$TAG_INDEX_PATH" || true)
  [ "$count" -eq 2 ]
}

@test "update_tag_index_from_block: new-tags: field creates new heading and pointer" {
  tag_index_ensure_file
  # No headings yet
  update_tag_index_from_block "" "  - brand-new: First use of this tag" "conventions.md" "New Convention" "77"
  grep -qxF "## brand-new" "$TAG_INDEX_PATH"
  grep -qF "conventions.md → New Convention" "$TAG_INDEX_PATH"
}

@test "update_tag_index_from_block: empty tags and new-tags is a complete no-op" {
  cat > "$TAG_INDEX_PATH" <<'EOF'
# Tag Index

**Auto-maintained.**

---

EOF
  local before
  before=$(cat "$TAG_INDEX_PATH")
  update_tag_index_from_block "" "" "conventions.md" "No-tag Convention" "88"
  local after
  after=$(cat "$TAG_INDEX_PATH")
  [ "$before" = "$after" ]
}

@test "update_tag_index_from_block: bootstraps tag-index.md when missing" {
  rm -f "$TAG_INDEX_PATH"
  [ ! -f "$TAG_INDEX_PATH" ]
  update_tag_index_from_block "mytag" "" "conventions.md" "Bootstrap Test" "99"
  [ -f "$TAG_INDEX_PATH" ]
  grep -q "^# Tag Index$" "$TAG_INDEX_PATH"
  grep -qxF "## mytag" "$TAG_INDEX_PATH"
  grep -qF "conventions.md → Bootstrap Test" "$TAG_INDEX_PATH"
}

@test "update_tag_index_from_block: tags: field is idempotent across two calls" {
  cat > "$TAG_INDEX_PATH" <<'EOF'
# Tag Index

**Auto-maintained.**

---

## idempotent-tag

EOF
  update_tag_index_from_block "idempotent-tag" "" "conventions.md" "Some Convention" "101"
  update_tag_index_from_block "idempotent-tag" "" "conventions.md" "Some Convention" "101"
  local count
  count=$(grep -c "conventions.md → Some Convention" "$TAG_INDEX_PATH" || true)
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# tag_index_add_pointer() — missing heading detection
# ---------------------------------------------------------------------------

@test "tag_index_add_pointer: returns 1 when heading is absent" {
  cat > "$TAG_INDEX_PATH" <<'EOF'
# Tag Index

**Auto-maintained.**

---

## some-other-tag

EOF
  run tag_index_add_pointer "nonexistent-tag" "conventions.md" "My Heading"
  [ "$status" -eq 1 ]
}

@test "tag_index_add_pointer: prints error to stderr when heading is absent" {
  cat > "$TAG_INDEX_PATH" <<'EOF'
# Tag Index

**Auto-maintained.**

---

## some-other-tag

EOF
  run --separate-stderr tag_index_add_pointer "nonexistent-tag" "conventions.md" "My Heading"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"heading '## nonexistent-tag' not found"* ]]
}

@test "tag_index_add_pointer: does not modify file when heading is absent" {
  cat > "$TAG_INDEX_PATH" <<'EOF'
# Tag Index

**Auto-maintained.**

---

## some-other-tag

EOF
  local before
  before=$(cat "$TAG_INDEX_PATH")
  # run captures exit code without crashing the test on non-zero
  run tag_index_add_pointer "nonexistent-tag" "conventions.md" "My Heading"
  local after
  after=$(cat "$TAG_INDEX_PATH")
  [ "$before" = "$after" ]
}

@test "update_tag_index_from_block: tags: and new-tags: combined works correctly" {
  cat > "$TAG_INDEX_PATH" <<'EOF'
# Tag Index

**Auto-maintained.**

---

## existing-tag

EOF
  update_tag_index_from_block "existing-tag" "  - fresh-tag: A new tag for this domain" \
    "conventions.md" "Combined Convention" "202"

  # existing-tag heading must have the pointer (use -F not -xF: BSD grep chokes on -xF with → in pattern)
  grep -qF "conventions.md → Combined Convention" "$TAG_INDEX_PATH"
  # fresh-tag heading must have been created
  grep -qxF "## fresh-tag" "$TAG_INDEX_PATH"
  # Both sections must have the pointer
  local count
  count=$(grep -c "conventions.md → Combined Convention" "$TAG_INDEX_PATH" || true)
  [ "$count" -eq 2 ]
}
