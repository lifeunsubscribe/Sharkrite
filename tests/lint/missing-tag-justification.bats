#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/23-missing-tag-justification-tag-in-convention.sh, tools/sharkrite-lint.sh, lib/utils/tag-index.sh
# Tests for Rule 23: MISSING_TAG_JUSTIFICATION
#
# A convention block with tags: foo declares a tag.  Every declared tag must:
#   (a) already have a ## foo heading in docs/architecture/tag-index.md, OR
#   (b) appear in the same block's new-tags: field with a justification line.
#
# When neither condition holds the lint rule must report MISSING_TAG_JUSTIFICATION.

setup() {
  LINT_SCRIPT="$BATS_TEST_DIRNAME/../../tools/sharkrite-lint.sh"

  # Each test gets its own isolated fixture directory injected via RITE_LINT_EXTRA_DIRS.
  # Using BATS_TEST_TMPDIR keeps fixtures outside the project tree so they don't
  # accidentally trigger other lint rules that scan lib/, bin/, tools/.
  LINT_FIXTURE_DIR="${BATS_TEST_TMPDIR}/r23-fixtures"
  mkdir -p "$LINT_FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$LINT_FIXTURE_DIR"

  # True test isolation for tag-index.md via RITE_TAG_INDEX_PATH_OVERRIDE.
  #
  # The linter derives PROJECT_ROOT from its own BASH_SOURCE[0] location, so it
  # always resolves to the real repo root — there is no way to redirect it via
  # a fake project root without patching the linter.  Instead, we added
  # RITE_TAG_INDEX_PATH_OVERRIDE to sharkrite-lint.sh so each test can supply a
  # fresh temp file as the tag-index without touching docs/architecture/tag-index.md.
  #
  # This eliminates the old backup/restore hazard: if a test crashed between
  # backup and restore, the real file was left in fixture state.  Parallel runs
  # also clobbered each other's backup files.  The override approach gives each
  # bats worker its own path in BATS_TEST_TMPDIR (per-test tmp), so there is no
  # shared mutable state at all.
  TAG_INDEX_PATH="${BATS_TEST_TMPDIR}/tag-index.md"
  export RITE_TAG_INDEX_PATH_OVERRIDE="$TAG_INDEX_PATH"
}

teardown() {
  rm -rf "$LINT_FIXTURE_DIR"
  unset RITE_LINT_EXTRA_DIRS
  unset RITE_TAG_INDEX_PATH_OVERRIDE
  # TAG_INDEX_PATH lives inside BATS_TEST_TMPDIR which bats cleans up automatically.
}

# Helper: create a fixture shell file in LINT_FIXTURE_DIR
create_fixture() {
  local filename="$1"
  local content="$2"
  cat > "$LINT_FIXTURE_DIR/$filename" <<FIXTURE_EOF
#!/bin/bash
$content
FIXTURE_EOF
}

# Helper: run the linter (RITE_TAG_INDEX_PATH_OVERRIDE is already exported by setup())
_run_linter() {
  run "$LINT_SCRIPT"
}

# Helper: seed the per-test tag-index temp file with fixture content
_seed_tag_index() {
  local content="$1"
  printf '%s\n' "$content" > "$TAG_INDEX_PATH"
}

# ---------------------------------------------------------------------------
# Test: No tag-index.md → rule 23 is skipped entirely (no violation)
# ---------------------------------------------------------------------------

@test "MISSING_TAG_JUSTIFICATION: rule is skipped when tag-index.md does not exist" {
  # RITE_TAG_INDEX_PATH_OVERRIDE points to a non-existent temp file (not seeded).
  # The linter must detect the absence and skip rule 23 entirely.
  # No need to remove the real tag-index.md — this test never touches it.

  # Convention block with an unknown tag — but since index is absent, no violation
  create_fixture "convention-no-index.sh" \
'<!-- sharkrite-convention -->
title: my-convention
rule: Do something
why: Because
tags: unknown-tag-xyz
<!-- /sharkrite-convention -->'

  _run_linter
  # Must NOT fire MISSING_TAG_JUSTIFICATION
  echo "$output" | grep -qvF "MISSING_TAG_JUSTIFICATION" || true
  [[ "$output" != *"MISSING_TAG_JUSTIFICATION"* ]]
}

# ---------------------------------------------------------------------------
# Test: Tag exists in tag-index.md → no violation
# ---------------------------------------------------------------------------

@test "MISSING_TAG_JUSTIFICATION: no violation when tag exists in tag-index.md" {
  _seed_tag_index "# Tag Index

**Auto-maintained.**

---

## set-e

## subshell
"

  create_fixture "convention-known-tags.sh" \
'<!-- sharkrite-convention -->
title: valid-convention
rule: Do something
why: Because
tags: set-e, subshell
<!-- /sharkrite-convention -->'

  _run_linter
  [[ "$output" != *"MISSING_TAG_JUSTIFICATION"* ]]
}

# ---------------------------------------------------------------------------
# Test: Tag NOT in index but in new-tags: → no violation
# ---------------------------------------------------------------------------

@test "MISSING_TAG_JUSTIFICATION: no violation when unknown tag is justified in new-tags:" {
  _seed_tag_index "# Tag Index

**Auto-maintained.**

---

## set-e
"

  create_fixture "convention-new-tag-justified.sh" \
'<!-- sharkrite-convention -->
title: justified-convention
rule: Do something new
why: Because
tags: brand-new-xyz
new-tags:
  - brand-new-xyz: Covers the new domain of XYZ patterns
<!-- /sharkrite-convention -->'

  _run_linter
  [[ "$output" != *"MISSING_TAG_JUSTIFICATION"* ]]
}

# ---------------------------------------------------------------------------
# Test: Tag NOT in index and NOT in new-tags: → violation
# ---------------------------------------------------------------------------

@test "MISSING_TAG_JUSTIFICATION: violation when tag not in index and not in new-tags:" {
  _seed_tag_index "# Tag Index

**Auto-maintained.**

---

## set-e
"

  create_fixture "convention-missing-justification.sh" \
'<!-- sharkrite-convention -->
title: unjustified-convention
rule: Do something
why: Because
tags: totally-unknown-zzz
<!-- /sharkrite-convention -->'

  _run_linter
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING_TAG_JUSTIFICATION"* ]]
  [[ "$output" == *"totally-unknown-zzz"* ]]
}

# ---------------------------------------------------------------------------
# Test: One tag known, one unknown and unjustified → violation for unknown only
# ---------------------------------------------------------------------------

@test "MISSING_TAG_JUSTIFICATION: reports only the unknown unjustified tag when mixed" {
  _seed_tag_index "# Tag Index

**Auto-maintained.**

---

## set-e
"

  create_fixture "convention-partial-tags.sh" \
'<!-- sharkrite-convention -->
title: partial-convention
rule: Do something
why: Because
tags: set-e, unknown-partial-tag
<!-- /sharkrite-convention -->'

  _run_linter
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING_TAG_JUSTIFICATION"* ]]
  # Known tag must NOT be reported
  [[ "$output" != *"'set-e'"* ]]
  # Unknown tag must be reported
  [[ "$output" == *"unknown-partial-tag"* ]]
}

# ---------------------------------------------------------------------------
# Test: Convention block without tags: field → no violation
# ---------------------------------------------------------------------------

@test "MISSING_TAG_JUSTIFICATION: no violation when convention block has no tags: field" {
  _seed_tag_index "# Tag Index

**Auto-maintained.**

---
"

  create_fixture "convention-no-tags-field.sh" \
'<!-- sharkrite-convention -->
title: untagged-convention
rule: Do something
why: Because
<!-- /sharkrite-convention -->'

  _run_linter
  [[ "$output" != *"MISSING_TAG_JUSTIFICATION"* ]]
}

# ---------------------------------------------------------------------------
# Test: Tags: field with whitespace around tag names is handled correctly
# ---------------------------------------------------------------------------

@test "MISSING_TAG_JUSTIFICATION: whitespace around tag names is trimmed correctly" {
  _seed_tag_index "# Tag Index

**Auto-maintained.**

---

## trimmed-tag
"

  create_fixture "convention-whitespace-tags.sh" \
'<!-- sharkrite-convention -->
title: whitespace-convention
rule: Do something
why: Because
tags:  trimmed-tag , other-unknown-tag
new-tags:
  - other-unknown-tag: Justified here
<!-- /sharkrite-convention -->'

  _run_linter
  # Both tags are justified (one in index, one in new-tags:) → no violation
  [[ "$output" != *"MISSING_TAG_JUSTIFICATION"* ]]
}
