#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/docs-map.sh, lib/core/docs-command.sh
# Regression tests for the committed docs-map path, type/rubric columns,
# legacy migration, and the rebuild hook in _docs_apply_approved.

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT

  FIXTURE_DIR="$(mktemp -d)"
  export FIXTURE_DIR

  git -C "$FIXTURE_DIR" init -q
  git -C "$FIXTURE_DIR" config user.email "test@example.com"
  git -C "$FIXTURE_DIR" config user.name "Test"

  mkdir -p "$FIXTURE_DIR/docs/architecture"
  mkdir -p "$FIXTURE_DIR/.rite/state"

  printf '# ADR 001\n## Context\n## Decision\n' \
    > "$FIXTURE_DIR/docs/adr-001-example.md"
  printf '# Feature Doc\n## Overview\n' \
    > "$FIXTURE_DIR/docs/architecture/feature-doc.md"
  printf '# README\n## Install\n' > "$FIXTURE_DIR/README.md"
  printf '# CLAUDE\n## Identity\n' > "$FIXTURE_DIR/CLAUDE.md"

  git -C "$FIXTURE_DIR" add -A
  git -C "$FIXTURE_DIR" commit -q -m "fixture"

  export RITE_PROJECT_ROOT="$FIXTURE_DIR"
  export RITE_STATE_DIR="$FIXTURE_DIR/.rite/state"
  export RITE_DOCS_MAP_AUTO="true"
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
# 1. docs_map_build writes to the committed path, not the legacy state path
# ---------------------------------------------------------------------------
@test "docs-map: build writes to docs/docs-map.tsv (committed path)" {
  _source_docs_map
  docs_map_build
  [ -f "$FIXTURE_DIR/docs/docs-map.tsv" ]
  [ ! -f "$FIXTURE_DIR/.rite/state/docs-map.tsv" ]
}

# ---------------------------------------------------------------------------
# 2. docs_map_path returns the committed path
# ---------------------------------------------------------------------------
@test "docs-map: docs_map_path returns docs/docs-map.tsv" {
  _source_docs_map
  local path
  path="$(docs_map_path)"
  [ "$path" = "$FIXTURE_DIR/docs/docs-map.tsv" ]
}

# ---------------------------------------------------------------------------
# 3. Legacy migration: .rite/state/docs-map.tsv is removed after rebuild
# ---------------------------------------------------------------------------
@test "docs-map: legacy state-dir map is removed after rebuild" {
  _source_docs_map
  # Simulate pre-existing legacy file
  printf '# docs-map v2 sha=abc built=2026-01-01\n' \
    > "$FIXTURE_DIR/.rite/state/docs-map.tsv"
  [ -f "$FIXTURE_DIR/.rite/state/docs-map.tsv" ]

  docs_map_build

  # New path created, legacy path removed
  [ -f "$FIXTURE_DIR/docs/docs-map.tsv" ]
  [ ! -f "$FIXTURE_DIR/.rite/state/docs-map.tsv" ]
}

# ---------------------------------------------------------------------------
# 4. type column: adr for ADR files, feature for docs/, other for README/CLAUDE
# ---------------------------------------------------------------------------
@test "docs-map: type column carries adr|feature|other per file" {
  _source_docs_map
  docs_map_build
  local map="$FIXTURE_DIR/docs/docs-map.tsv"

  # ADR file → type=adr (column 7)
  local adr_type
  adr_type="$(grep -F "docs/adr-001-example.md" "$map" | cut -f7 | sort -u || true)"
  [ "$adr_type" = "adr" ]

  # Feature doc under docs/ → type=feature
  local feat_type
  feat_type="$(grep -F "docs/architecture/feature-doc.md" "$map" | cut -f7 | sort -u || true)"
  [ "$feat_type" = "feature" ]

  # README.md → type=other
  local readme_type
  readme_type="$(grep -F "README.md" "$map" | cut -f7 | sort -u || true)"
  [ "$readme_type" = "other" ]

  # CLAUDE.md → type=other
  local claude_type
  claude_type="$(grep -F "CLAUDE.md" "$map" | cut -f7 | sort -u || true)"
  [ "$claude_type" = "other" ]
}

# ---------------------------------------------------------------------------
# 5. rubric column: defaults to "-" for all rows (column 8, last column)
# ---------------------------------------------------------------------------
@test "docs-map: rubric column (last field) defaults to - for all rows" {
  _source_docs_map
  docs_map_build
  local bad_rubric
  bad_rubric="$(grep -v '^#' "$FIXTURE_DIR/docs/docs-map.tsv" | \
    awk -F'\t' '$NF != "-"' || true)"
  [ -z "$bad_rubric" ]
}

# ---------------------------------------------------------------------------
# 6. Rebuild path: no provider_run_prompt calls in docs_map_build
# ---------------------------------------------------------------------------
@test "docs-map: rebuild is deterministic — zero provider calls in docs-map.sh" {
  local count
  count="$(grep -c "provider_run_prompt" "$RITE_REPO_ROOT/lib/utils/docs-map.sh" || true)"
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 7. docs-command.sh: _docs_apply_approved calls docs_map_build before git add,
#    gated on _aa_applied counter (so all-skipped paths don't trigger a spurious
#    commit+push of just the map rebuild)
# ---------------------------------------------------------------------------
@test "docs-apply: _docs_apply_approved rebuilds docs-map only when proposals were applied" {
  # Extract the _docs_apply_approved function body and verify:
  #   (a) docs_map_build is called inside the function (hook exists)
  #   (b) the call is gated on _aa_applied (all-skipped guard exists)
  # An awk extraction is used so matches outside the function body cannot satisfy (a).
  local fn_body
  fn_body="$(awk '/^_docs_apply_approved\(\)/{found=1} found{print} found && /^\}$/{exit}' \
    "$RITE_REPO_ROOT/lib/core/docs-command.sh" || true)"

  # (a) docs_map_build must appear inside _docs_apply_approved
  printf '%s\n' "$fn_body" | grep -q "docs_map_build"

  # (b) _aa_applied counter must gate the rebuild call
  printf '%s\n' "$fn_body" | grep -q "_aa_applied"
}

# ---------------------------------------------------------------------------
# 8. docs_map_ensure upgrades a v2 map to v3 (new format)
# ---------------------------------------------------------------------------
@test "docs-map ensure: v2 map at committed path triggers rebuild to v3" {
  _source_docs_map
  # Plant a v2 map at the committed path
  printf '# docs-map v2 sha=abc built=2026-01-01\n' \
    > "$FIXTURE_DIR/docs/docs-map.tsv"
  printf 'docs/adr-001-example.md\tabc\tadr\t\t\tdeadbeef\n' \
    >> "$FIXTURE_DIR/docs/docs-map.tsv"

  docs_map_ensure

  local header
  header="$(head -1 "$FIXTURE_DIR/docs/docs-map.tsv")"
  [[ "$header" == "# docs-map v3"* ]]
}
