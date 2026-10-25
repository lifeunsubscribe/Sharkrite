#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/docs-map.sh, lib/utils/markers.sh
#
# Regression tests for docs_map_enforcing_tests() and the RITE_MARKER_ENFORCED_BY
# constant. Covers: single marker, no marker, placeholder rejection (#90 class),
# multiple comma-separated paths, and multiple markers in one doc.

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT

  FIXTURE_DIR="$(mktemp -d)"
  export FIXTURE_DIR

  git -C "$FIXTURE_DIR" init -q
  git -C "$FIXTURE_DIR" config user.email "test@example.com"
  git -C "$FIXTURE_DIR" config user.name "Test"

  mkdir -p "$FIXTURE_DIR/docs"
  mkdir -p "$FIXTURE_DIR/.rite/state"

  # Initial commit so HEAD is valid
  printf '# README\n' > "$FIXTURE_DIR/README.md"
  git -C "$FIXTURE_DIR" add -A
  git -C "$FIXTURE_DIR" commit -q -m "fixture"

  export RITE_PROJECT_ROOT="$FIXTURE_DIR"
  export RITE_STATE_DIR="$FIXTURE_DIR/.rite/state"
  export RITE_DOCS_MAP_AUTO="false"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
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
# Marker constant
# ---------------------------------------------------------------------------

@test "RITE_MARKER_ENFORCED_BY is defined with value sharkrite-enforced-by" {
  run bash -c "
    set -euo pipefail
    source '${RITE_REPO_ROOT}/lib/utils/markers.sh'
    printf '%s' \"\$RITE_MARKER_ENFORCED_BY\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "sharkrite-enforced-by" ]
}

# ---------------------------------------------------------------------------
# docs_map_enforcing_tests: basic single marker
# ---------------------------------------------------------------------------

@test "docs_map_enforcing_tests: returns declared test paths one per line" {
  printf '# Feature\n\nSome text.\n\n<!-- sharkrite-enforced-by: tests/regression/foo.bats, tests/regression/bar.bats -->\n' \
    > "$FIXTURE_DIR/docs/feature.md"

  _source_docs_map

  run docs_map_enforcing_tests "docs/feature.md"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "tests/regression/foo.bats" ]
  [ "${lines[1]}" = "tests/regression/bar.bats" ]
  [ "${#lines[@]}" -eq 2 ]
}

# ---------------------------------------------------------------------------
# docs_map_enforcing_tests: no marker → empty output
# ---------------------------------------------------------------------------

@test "docs_map_enforcing_tests: empty output for doc without marker" {
  printf '# Feature\n\nNo enforcing-test declaration here.\n' \
    > "$FIXTURE_DIR/docs/no-marker.md"

  _source_docs_map

  run docs_map_enforcing_tests "docs/no-marker.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# docs_map_enforcing_tests: placeholder rejection (#90 bare-prefix class)
#
# A doc that *documents* the marker format but has no real .bats path must
# produce empty output. The format anchor [^[:space:]]+\.bats is the guard.
# ---------------------------------------------------------------------------

@test "docs_map_enforcing_tests: rejects documentation placeholder without .bats token" {
  # Marker text referencing the format but no path-shaped .bats token
  printf '# Docs\n\nSee format: <!-- sharkrite-enforced-by: N/A -->\n' \
    > "$FIXTURE_DIR/docs/placeholder.md"

  _source_docs_map

  run docs_map_enforcing_tests "docs/placeholder.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "docs_map_enforcing_tests: rejects empty marker value" {
  printf '# Docs\n\n<!-- sharkrite-enforced-by: -->\n' \
    > "$FIXTURE_DIR/docs/empty-marker.md"

  _source_docs_map

  run docs_map_enforcing_tests "docs/empty-marker.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# docs_map_enforcing_tests: multiple markers accumulate
# ---------------------------------------------------------------------------

@test "docs_map_enforcing_tests: multiple markers in one doc accumulate" {
  printf '# Feature\n\n<!-- sharkrite-enforced-by: tests/regression/alpha.bats -->\n\nSome text.\n\n<!-- sharkrite-enforced-by: tests/regression/beta.bats, tests/regression/gamma.bats -->\n' \
    > "$FIXTURE_DIR/docs/multi-marker.md"

  _source_docs_map

  run docs_map_enforcing_tests "docs/multi-marker.md"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "tests/regression/alpha.bats" ]
  [ "${lines[1]}" = "tests/regression/beta.bats" ]
  [ "${lines[2]}" = "tests/regression/gamma.bats" ]
  [ "${#lines[@]}" -eq 3 ]
}

# ---------------------------------------------------------------------------
# docs_map_enforcing_tests: absolute path resolution
# ---------------------------------------------------------------------------

@test "docs_map_enforcing_tests: accepts absolute path" {
  printf '# Feature\n\n<!-- sharkrite-enforced-by: tests/regression/abs.bats -->\n' \
    > "$FIXTURE_DIR/docs/abs.md"

  _source_docs_map

  run docs_map_enforcing_tests "${FIXTURE_DIR}/docs/abs.md"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "tests/regression/abs.bats" ]
}

# ---------------------------------------------------------------------------
# docs_map_enforcing_tests: non-existent doc → empty output (no crash)
# ---------------------------------------------------------------------------

@test "docs_map_enforcing_tests: non-existent doc produces empty output" {
  _source_docs_map

  run docs_map_enforcing_tests "docs/does-not-exist.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
