#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/docs-map.sh, lib/core/docs-command.sh
# Regression tests for:
#   1. docs-map committed path (docs/docs-map.tsv, not .rite/state/)
#   2. type and rubric columns in the v3 format
#   3. legacy .rite/state/docs-map.tsv migration on first build
#   4. _docs_apply_approved rebuild hook: map rebuilt before git add

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT

  FIXTURE_DIR="$(mktemp -d)"
  export FIXTURE_DIR

  git -C "$FIXTURE_DIR" init -q
  git -C "$FIXTURE_DIR" config user.email "test@example.com"
  git -C "$FIXTURE_DIR" config user.name "Test"

  # Minimal docs structure
  mkdir -p "$FIXTURE_DIR/docs/architecture"
  mkdir -p "$FIXTURE_DIR/.rite/state"

  printf '# ADR 001\n## Context\n## Decision\n' \
    > "$FIXTURE_DIR/docs/architecture/adr-001-example.md"
  printf '# Feature Guide\n## Overview\n' \
    > "$FIXTURE_DIR/docs/feature-guide.md"
  printf '# README\n## Section A\n' > "$FIXTURE_DIR/README.md"
  printf '# CLAUDE\n## Identity\n' > "$FIXTURE_DIR/CLAUDE.md"

  git -C "$FIXTURE_DIR" add -A
  git -C "$FIXTURE_DIR" commit -q -m "fixture"

  FIXTURE_HEAD="$(git -C "$FIXTURE_DIR" rev-parse HEAD)"
  export FIXTURE_HEAD

  export RITE_PROJECT_ROOT="$FIXTURE_DIR"
  export RITE_STATE_DIR="$FIXTURE_DIR/.rite/state"
  export RITE_DOCS_MAP_AUTO="true"

  # Canonical new path
  MAP_FILE="$FIXTURE_DIR/docs/docs-map.tsv"
  export MAP_FILE
  # Legacy path (gitignored .rite/state/)
  LEGACY_MAP="$FIXTURE_DIR/.rite/state/docs-map.tsv"
  export LEGACY_MAP
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

_source_docs_map() {
  RITE_SOURCE_FUNCTIONS_ONLY=0 source "$RITE_REPO_ROOT/lib/utils/docs-map.sh"
  set +u
  set +o pipefail
}

# ---------------------------------------------------------------------------
# 1. docs_map_path returns the committed path (docs/docs-map.tsv)
# ---------------------------------------------------------------------------
@test "docs-map path: docs_map_path returns docs/docs-map.tsv under project root" {
  _source_docs_map
  local path
  path="$(docs_map_path)"
  [ "$path" = "$FIXTURE_DIR/docs/docs-map.tsv" ]
}

# ---------------------------------------------------------------------------
# 2. docs_map_build writes to the committed path, not .rite/state/
# ---------------------------------------------------------------------------
@test "docs-map path: build writes to docs/docs-map.tsv, not .rite/state/" {
  _source_docs_map
  docs_map_build
  # Committed path must exist
  [ -f "$MAP_FILE" ]
  # Legacy path must NOT be created
  [ ! -f "$LEGACY_MAP" ]
}

# ---------------------------------------------------------------------------
# 3. Map header is v4 format
# ---------------------------------------------------------------------------
@test "docs-map path: built map has v4 header" {
  _source_docs_map
  docs_map_build
  local header
  header="$(head -1 "$MAP_FILE")"
  [[ "$header" == "# docs-map v4 sha="* ]]
}

# ---------------------------------------------------------------------------
# 4. type column: ADR file gets type=adr
# ---------------------------------------------------------------------------
@test "docs-map type: ADR-pattern file gets type=adr in column 7" {
  _source_docs_map
  docs_map_build
  local adr_types
  adr_types="$(grep -F "docs/architecture/adr-001-example.md" "$MAP_FILE" | \
    cut -f7 | sort -u || true)"
  [ "$adr_types" = "adr" ]
}

# ---------------------------------------------------------------------------
# 5. type column: non-ADR docs/ file gets type=feature
# ---------------------------------------------------------------------------
@test "docs-map type: non-ADR docs/ file gets type=feature in column 7" {
  _source_docs_map
  docs_map_build
  local feat_types
  feat_types="$(grep -F "docs/feature-guide.md" "$MAP_FILE" | \
    cut -f7 | sort -u || true)"
  [ "$feat_types" = "feature" ]
}

# ---------------------------------------------------------------------------
# 6. type column: README.md and CLAUDE.md get type=other
# ---------------------------------------------------------------------------
@test "docs-map type: README.md and CLAUDE.md get type=other in column 7" {
  _source_docs_map
  docs_map_build
  local readme_type
  readme_type="$(grep -F "README.md" "$MAP_FILE" | cut -f7 | sort -u || true)"
  [ "$readme_type" = "other" ]

  local claude_type
  claude_type="$(grep -F "CLAUDE.md" "$MAP_FILE" | cut -f7 | sort -u || true)"
  [ "$claude_type" = "other" ]
}

# ---------------------------------------------------------------------------
# 7. rubric column: all rows default to "-" in column 8 (last field)
# ---------------------------------------------------------------------------
@test "docs-map rubric: all rows default rubric to - in column 8" {
  _source_docs_map
  docs_map_build
  # $NF (last field) is rubric; every data row must be "-"
  local non_default
  non_default="$(grep -v '^#' "$MAP_FILE" | \
    awk -F'\t' '$NF != "-" {print}' || true)"
  [ -z "$non_default" ]
}

# ---------------------------------------------------------------------------
# 8. Migration: legacy .rite/state/docs-map.tsv is removed after first build
# ---------------------------------------------------------------------------
@test "docs-map migration: legacy .rite/state/docs-map.tsv removed after build" {
  _source_docs_map
  # Simulate a legacy file at the old path
  printf '# docs-map v2 sha=old\n' > "$LEGACY_MAP"
  [ -f "$LEGACY_MAP" ]

  # Build should write to the new path and remove the legacy file
  docs_map_build

  [ -f "$MAP_FILE" ]
  [ ! -f "$LEGACY_MAP" ]
}

# ---------------------------------------------------------------------------
# 9. Migration bats case: docs_map_ensure with legacy-only state triggers
#    a rebuild at the new path and removes the legacy file
# ---------------------------------------------------------------------------
@test "docs-map migration: docs_map_ensure migrates legacy-only state" {
  _source_docs_map
  # Simulate: new path absent, legacy path present
  rm -f "$MAP_FILE"
  printf '# docs-map v2 sha=old\n' > "$LEGACY_MAP"

  docs_map_ensure

  # New path must now exist
  [ -f "$MAP_FILE" ]
  # Legacy must be gone
  [ ! -f "$LEGACY_MAP" ]
  # New map must be v4
  local header
  header="$(head -1 "$MAP_FILE")"
  [[ "$header" == "# docs-map v4"* ]]
}

# ---------------------------------------------------------------------------
# 10. Rebuild is deterministic — zero provider calls on the rebuild path
#     (structural grep: no provider_run_prompt in docs_map_build call chain)
# ---------------------------------------------------------------------------
@test "docs-map rebuild: docs_map_build contains no provider_run_prompt call" {
  # Structural grep: the rebuild path must not invoke provider_run_prompt.
  # Scope to docs_map_build function body (stops before docs_map_ensure).
  # docs_map_populate_tags (a separate LLM-enrichment function) does call
  # provider_run_prompt_with_timeout, so we must not grep the whole file.
  local hits
  hits="$(awk '/^docs_map_build\(\)/{f=1} /^docs_map_ensure\(\)/{f=0} f{print}' \
    "$RITE_REPO_ROOT/lib/utils/docs-map.sh" | grep -c 'provider_run_prompt' || true)"
  [ "$hits" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 11. _docs_apply_approved rebuild hook: map is updated before git add
#     Test approach: call docs_map_build inside a subshell with a modified
#     PROJECT_ROOT and verify the map at the new path reflects the change.
#     (The full _docs_apply_approved path requires network/git infrastructure;
#     this test verifies the rebuild mechanism docs_map_build uses.)
# ---------------------------------------------------------------------------
@test "docs-map rebuild hook: docs_map_build reflects doc changes in worktree root" {
  _source_docs_map

  # Initial build
  docs_map_build
  local initial_count
  initial_count="$(grep -c "feature-guide.md" "$MAP_FILE" || true)"
  [ "$initial_count" -ge 1 ]

  # Simulate a doc change (new file added)
  printf '# New Feature\n## Details\n' > "$FIXTURE_DIR/docs/new-feature.md"

  # Rebuild (as _docs_apply_approved does: override PROJECT_ROOT in subshell)
  ( export RITE_PROJECT_ROOT="$FIXTURE_DIR"; unset RITE_STATE_DIR 2>/dev/null || true
    docs_map_build )

  # New doc must appear in the rebuilt map
  local new_count
  new_count="$(grep -c "new-feature.md" "$MAP_FILE" || true)"
  [ "$new_count" -ge 1 ]

  # new-feature.md is in docs/ but not ADR → type must be feature
  local new_type
  new_type="$(grep -F "docs/new-feature.md" "$MAP_FILE" | cut -f7 | sort -u || true)"
  [ "$new_type" = "feature" ]
}
