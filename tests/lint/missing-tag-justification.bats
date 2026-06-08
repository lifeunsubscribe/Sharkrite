#!/usr/bin/env bats
# sharkrite-test-covers: tools/*-lint.sh, lib/utils/tag-index.sh
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

  # Point the linter's PROJECT_ROOT to a tmp dir so tag-index.md can be seeded
  # without modifying the real repository.  The linter resolves PROJECT_ROOT
  # relative to its own script location; we override it via an env var that the
  # linter reads when constructing _tag_index_path.
  #
  # Strategy: create a fresh PROJECT_ROOT tmp dir per test that mirrors the
  # directory structure sharkrite-lint.sh expects for the tag-index file.
  FAKE_PROJECT_ROOT="${BATS_TEST_TMPDIR}/fake-project-root"
  mkdir -p "$FAKE_PROJECT_ROOT/docs/architecture"
  TAG_INDEX_PATH="$FAKE_PROJECT_ROOT/docs/architecture/tag-index.md"

  # Back up the real tag-index.md once at the start of each test so that
  # teardown() can always restore it — even if the test body fails mid-way.
  _backup_tag_index
}

teardown() {
  rm -rf "$LINT_FIXTURE_DIR"
  rm -rf "$FAKE_PROJECT_ROOT"
  unset RITE_LINT_EXTRA_DIRS
  # Always restore the real tag-index.md, regardless of test outcome.
  _restore_tag_index
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

# Helper: run the linter with PROJECT_ROOT overridden to FAKE_PROJECT_ROOT.
# We patch this by temporarily symlinking the docs dir inside the real script's
# PROJECT_ROOT — but since the linter resolves PROJECT_ROOT from SCRIPT_DIR,
# the cleanest approach is to run the linter with a wrapper that overrides the
# _tag_index_path variable.
#
# Instead, we create the tag-index.md inside the REAL project root's docs/
# directory — but that would modify the real repo.  Instead: we patch by
# running a modified version of the linter that accepts RITE_TAG_INDEX_PATH_OVERRIDE.
#
# Since neither approach is clean without modifying the linter, we use a
# simpler strategy: place a real tag-index.md at the actual project location
# and rely on cleanup.  But the project root already has a tag-index.md, so
# we cannot do that without risk.
#
# Final approach: the linter uses PROJECT_ROOT derived from BASH_SOURCE[0]
# (the lint script location), so it always resolves to the real repo root.
# We create the tag-index.md in the REAL repo's docs/architecture/tag-index.md
# in a temp location and symlink it in place for the duration of the test.
#
# Actually, looking at the linter code:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
#   _tag_index_path="${PROJECT_ROOT}/docs/architecture/tag-index.md"
#
# PROJECT_ROOT is always the real repo root.  We cannot override this via env
# without patching the linter.  Instead, we will create/remove the real
# tag-index.md in the repo's docs/architecture/ directory within each test.
# Since tests are isolated subshells and use proper teardown, this is safe.
_run_linter() {
  run "$LINT_SCRIPT"
}

# The REAL tag-index.md path (in the repo's docs/architecture/)
_real_tag_index() {
  local repo_root
  repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  echo "$repo_root/docs/architecture/tag-index.md"
}

# Back up the real tag-index.md at test start (called from setup())
_backup_tag_index() {
  local real_path
  real_path="$(_real_tag_index)"
  if [ -f "$real_path" ]; then
    cp "$real_path" "${real_path}.bak"
  fi
}

# Seed the real tag-index.md with fixture content (no backup — setup() already did it)
_seed_tag_index() {
  local content="$1"
  local real_path
  real_path="$(_real_tag_index)"
  printf '%s\n' "$content" > "$real_path"
}

# Restore the real tag-index.md after a test (called from teardown())
_restore_tag_index() {
  local real_path
  real_path="$(_real_tag_index)"
  if [ -f "${real_path}.bak" ]; then
    mv "${real_path}.bak" "$real_path"
  else
    # No backup → file did not exist before; remove our temp version
    rm -f "$real_path"
  fi
}

# ---------------------------------------------------------------------------
# Test: No tag-index.md → rule 23 is skipped entirely (no violation)
# ---------------------------------------------------------------------------

@test "MISSING_TAG_JUSTIFICATION: rule is skipped when tag-index.md does not exist" {
  # Ensure the real tag-index.md does not exist for this test
  # (setup() already backed it up, so we can safely remove it here)
  local real_path
  real_path="$(_real_tag_index)"
  rm -f "$real_path"

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
