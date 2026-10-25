#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/docs-map.sh::docs_map_adr_links
#
# Regression tests for docs_map_adr_links().
# Covers: in-map link emission, external URL exclusion, code-file exclusion,
# zero-link ADR, fragment stripping, relative path resolution, deduplication.

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT

  FIXTURE_DIR="$(mktemp -d)"
  export FIXTURE_DIR

  git -C "$FIXTURE_DIR" init -q
  git -C "$FIXTURE_DIR" config user.email "test@example.com"
  git -C "$FIXTURE_DIR" config user.name "Test"

  mkdir -p "$FIXTURE_DIR/docs/architecture"
  mkdir -p "$FIXTURE_DIR/docs/features"
  mkdir -p "$FIXTURE_DIR/.rite/state"

  # Feature docs that will appear in the map
  printf '# Feature A\n\nContent for feature A.\n' \
    > "$FIXTURE_DIR/docs/features/feature-a.md"
  printf '# Feature B\n\nContent for feature B.\n' \
    > "$FIXTURE_DIR/docs/features/feature-b.md"

  printf '# README\n' > "$FIXTURE_DIR/README.md"

  # Initial commit so HEAD is valid
  git -C "$FIXTURE_DIR" add -A
  git -C "$FIXTURE_DIR" commit -q -m "fixture"

  export RITE_PROJECT_ROOT="$FIXTURE_DIR"
  export RITE_STATE_DIR="$FIXTURE_DIR/.rite/state"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DOCS_MAP_AUTO="false"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

_source_docs_map() {
  RITE_SOURCE_FUNCTIONS_ONLY=0 source "$RITE_REPO_ROOT/lib/utils/docs-map.sh"
  set +u
  set +o pipefail
}

# Build the docs map from the fixture files (without the ADR, so ADR links
# back to itself are not in-map by default).
_build_map() {
  docs_map_build
}

# ---------------------------------------------------------------------------
# Basic: ADR links to in-map feature docs
# ---------------------------------------------------------------------------

@test "docs_map_adr_links: emits in-map feature docs linked from ADR" {
  printf '# ADR 001\n\n## Decision\n\nSee [Feature A](../features/feature-a.md) and [Feature B](../features/feature-b.md).\n' \
    > "$FIXTURE_DIR/docs/architecture/adr-001.md"

  _source_docs_map
  _build_map

  run docs_map_adr_links "docs/architecture/adr-001.md"
  [ "$status" -eq 0 ]
  # Both feature docs should be present (order matches link order in ADR)
  local found_a=0 found_b=0
  local line
  for line in "${lines[@]}"; do
    [ "$line" = "docs/features/feature-a.md" ] && found_a=1
    [ "$line" = "docs/features/feature-b.md" ] && found_b=1
  done
  [ "$found_a" -eq 1 ]
  [ "$found_b" -eq 1 ]
  [ "${#lines[@]}" -eq 2 ]
}

# ---------------------------------------------------------------------------
# External URLs are excluded
# ---------------------------------------------------------------------------

@test "docs_map_adr_links: excludes external http/https links" {
  printf '# ADR 001\n\nSee [External](https://example.com/docs) and [Also](http://foo.org).\n' \
    > "$FIXTURE_DIR/docs/architecture/adr-001.md"

  _source_docs_map
  _build_map

  run docs_map_adr_links "docs/architecture/adr-001.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Code files (not in docs map) are excluded
# ---------------------------------------------------------------------------

@test "docs_map_adr_links: excludes links to code files not in map" {
  # lib/utils/config.sh is real in the sharkrite repo but is NOT a .md file
  # and will not appear in the fixture docs map
  printf '# ADR 001\n\nImplemented in [config.sh](../../lib/utils/config.sh).\n' \
    > "$FIXTURE_DIR/docs/architecture/adr-001.md"

  _source_docs_map
  _build_map

  run docs_map_adr_links "docs/architecture/adr-001.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Zero links → empty output, exits 0
# ---------------------------------------------------------------------------

@test "docs_map_adr_links: ADR with zero links emits nothing and exits 0" {
  printf '# ADR 001\n\nThis ADR has no markdown links at all.\n' \
    > "$FIXTURE_DIR/docs/architecture/adr-001.md"

  _source_docs_map
  _build_map

  run docs_map_adr_links "docs/architecture/adr-001.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Fragment stripping: link to doc#section resolves to doc
# ---------------------------------------------------------------------------

@test "docs_map_adr_links: strips URL fragment before in-map lookup" {
  printf '# ADR 001\n\nSee [Feature A section](../features/feature-a.md#overview).\n' \
    > "$FIXTURE_DIR/docs/architecture/adr-001.md"

  _source_docs_map
  _build_map

  run docs_map_adr_links "docs/architecture/adr-001.md"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "docs/features/feature-a.md" ]
  [ "${#lines[@]}" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Deduplication: same doc linked multiple times → emitted once
# ---------------------------------------------------------------------------

@test "docs_map_adr_links: deduplicates repeated links to the same doc" {
  printf '# ADR 001\n\nSee [Feature A](../features/feature-a.md). Also [Feature A again](../features/feature-a.md#section).\n' \
    > "$FIXTURE_DIR/docs/architecture/adr-001.md"

  _source_docs_map
  _build_map

  run docs_map_adr_links "docs/architecture/adr-001.md"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "docs/features/feature-a.md" ]
  [ "${#lines[@]}" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Non-existent ADR → empty output, exits 0
# ---------------------------------------------------------------------------

@test "docs_map_adr_links: non-existent ADR produces empty output" {
  _source_docs_map
  _build_map

  run docs_map_adr_links "docs/architecture/does-not-exist.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Anchor-only links (#section) are excluded
# ---------------------------------------------------------------------------

@test "docs_map_adr_links: excludes anchor-only links" {
  printf '# ADR 001\n\nGo to [section](#decision).\n' \
    > "$FIXTURE_DIR/docs/architecture/adr-001.md"

  _source_docs_map
  _build_map

  run docs_map_adr_links "docs/architecture/adr-001.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Mixed: in-map + external + code file in one ADR
# ---------------------------------------------------------------------------

@test "docs_map_adr_links: mixed links emits only the in-map subset" {
  printf '# ADR 001\n\nSee [Feature A](../features/feature-a.md), [External](https://example.com), [Code](../../lib/utils/config.sh), [Section](#ctx).\n' \
    > "$FIXTURE_DIR/docs/architecture/adr-001.md"

  _source_docs_map
  _build_map

  run docs_map_adr_links "docs/architecture/adr-001.md"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "docs/features/feature-a.md" ]
  [ "${#lines[@]}" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Absolute path argument is accepted
# ---------------------------------------------------------------------------

@test "docs_map_adr_links: accepts absolute path argument" {
  printf '# ADR 001\n\nSee [Feature B](../features/feature-b.md).\n' \
    > "$FIXTURE_DIR/docs/architecture/adr-001.md"

  _source_docs_map
  _build_map

  run docs_map_adr_links "${FIXTURE_DIR}/docs/architecture/adr-001.md"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "docs/features/feature-b.md" ]
  [ "${#lines[@]}" -eq 1 ]
}

# ---------------------------------------------------------------------------
# No docs map → empty output, exits 0 (no crash)
# ---------------------------------------------------------------------------

@test "docs_map_adr_links: absent docs map produces empty output" {
  printf '# ADR 001\n\nSee [Feature A](../features/feature-a.md).\n' \
    > "$FIXTURE_DIR/docs/architecture/adr-001.md"

  _source_docs_map
  # Do NOT call _build_map — map file should be absent

  run docs_map_adr_links "docs/architecture/adr-001.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
