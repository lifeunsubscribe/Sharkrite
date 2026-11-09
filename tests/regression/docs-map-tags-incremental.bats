#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/docs-map.sh, lib/core/assess-documentation.sh
# Regression tests for fingerprint-gated tag carry-forward (issue #1423).
#
# Verified:
#   1. Unchanged section fingerprint → tags/note carried forward from prior map
#   2. Changed section fingerprint → tags reset to "-" (triggers re-enrichment)
#   3. docs_map_tag_section_by_pointer adds tag to matching row (idempotent)
#   4. docs_map_render_tag_index calls tag_index_ensure_heading + tag_index_add_pointer

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

  # Two-section doc: deterministic heading text for lookup assertions
  printf '# Section Alpha\nContent alpha.\n\n# Section Beta\nContent beta.\n' \
    > "$FIXTURE_DIR/docs/test-doc.md"

  git -C "$FIXTURE_DIR" add -A
  git -C "$FIXTURE_DIR" commit -q -m "fixture"

  FIXTURE_HEAD="$(git -C "$FIXTURE_DIR" rev-parse HEAD)"
  export FIXTURE_HEAD

  export RITE_PROJECT_ROOT="$FIXTURE_DIR"
  export RITE_STATE_DIR="$FIXTURE_DIR/.rite/state"
  MAP_FILE="$FIXTURE_DIR/docs/docs-map.tsv"
  export MAP_FILE
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

# Inject pre-tagged rows into an existing map (simulates a prior enrichment pass).
# Usage: _inject_tags HEADING TAG NOTE
_inject_tags() {
  local heading="$1" tag="$2" note="$3"
  local tmp
  tmp="$(mktemp "${FIXTURE_DIR}/docs/docs-map.tsv.XXXXXX")"
  head -1 "$MAP_FILE" > "$tmp"
  awk -F'\t' -v OFS='\t' -v ht="$heading" -v tg="$tag" -v nt="$note" \
    'NR>1{ if ($5==ht) { $9=tg; $10=nt } print }' "$MAP_FILE" >> "$tmp"
  mv "$tmp" "$MAP_FILE"
}

# ---------------------------------------------------------------------------
# 1. Unchanged fingerprint carries forward tags — no provider call needed
# ---------------------------------------------------------------------------
@test "docs-map tags: unchanged fingerprint carries forward tags/note" {
  _source_docs_map

  # Initial build — all tags "-"
  docs_map_build

  # Simulate prior enrichment: set tags on "Section Alpha"
  _inject_tags "Section Alpha" "set-e, subshell" "Alpha section note"

  # Rebuild with identical doc content — fingerprint unchanged
  docs_map_build

  # Tags/note must be carried forward for "Section Alpha"
  local tags note
  tags="$(awk -F'\t' '$5=="Section Alpha"{print $9}' "$MAP_FILE")"
  note="$(awk -F'\t' '$5=="Section Alpha"{print $10}' "$MAP_FILE")"

  [ "$tags" = "set-e, subshell" ]
  [ "$note" = "Alpha section note" ]
}

# ---------------------------------------------------------------------------
# 2. Changed fingerprint resets tags to "-"
# ---------------------------------------------------------------------------
@test "docs-map tags: changed fingerprint resets tags to dash" {
  _source_docs_map

  # Initial build
  docs_map_build

  # Simulate prior enrichment for "Section Beta"
  _inject_tags "Section Beta" "async" "Beta section note"

  # Modify the doc — changes "Section Beta"'s content, breaking its fingerprint
  printf '# Section Alpha\nContent alpha.\n\n# Section Beta\nContent beta CHANGED.\n' \
    > "$FIXTURE_DIR/docs/test-doc.md"

  # Rebuild — Section Beta's fingerprint no longer matches the cache
  docs_map_build

  local tags
  tags="$(awk -F'\t' '$5=="Section Beta"{print $9}' "$MAP_FILE")"

  [ "$tags" = "-" ]
}

# ---------------------------------------------------------------------------
# 3. Unchanged section is NOT reset — only the changed section resets
# ---------------------------------------------------------------------------
@test "docs-map tags: unchanged sibling section keeps its tags after partial change" {
  _source_docs_map

  docs_map_build
  _inject_tags "Section Alpha" "stable-tag" "Stable note"
  _inject_tags "Section Beta" "other-tag" "Other note"

  # Change only Section Beta
  printf '# Section Alpha\nContent alpha.\n\n# Section Beta\nNow different.\n' \
    > "$FIXTURE_DIR/docs/test-doc.md"

  docs_map_build

  local alpha_tags beta_tags
  alpha_tags="$(awk -F'\t' '$5=="Section Alpha"{print $9}' "$MAP_FILE")"
  beta_tags="$(awk -F'\t' '$5=="Section Beta"{print $9}' "$MAP_FILE")"

  [ "$alpha_tags" = "stable-tag" ]
  [ "$beta_tags" = "-" ]
}

# ---------------------------------------------------------------------------
# 4. docs_map_tag_section_by_pointer adds tag to matching row
# ---------------------------------------------------------------------------
@test "docs-map tags: tag_section_by_pointer adds tag to matching row" {
  _source_docs_map

  docs_map_build

  # Add a tag to the "Section Alpha" row in test-doc.md
  docs_map_tag_section_by_pointer "test-doc.md#Section Alpha" "routing-tag"

  local tags
  tags="$(awk -F'\t' '$5=="Section Alpha"{print $9}' "$MAP_FILE")"
  [ "$tags" = "routing-tag" ]
}

# ---------------------------------------------------------------------------
# 5. docs_map_tag_section_by_pointer is idempotent — no duplicate tags
# ---------------------------------------------------------------------------
@test "docs-map tags: tag_section_by_pointer is idempotent" {
  _source_docs_map

  docs_map_build
  docs_map_tag_section_by_pointer "test-doc.md#Section Alpha" "dedup-tag"
  docs_map_tag_section_by_pointer "test-doc.md#Section Alpha" "dedup-tag"

  local tags
  tags="$(awk -F'\t' '$5=="Section Alpha"{print $9}' "$MAP_FILE")"
  # Must be exactly "dedup-tag", not "dedup-tag, dedup-tag"
  [ "$tags" = "dedup-tag" ]
}

# ---------------------------------------------------------------------------
# 6. docs_map_render_tag_index calls tag_index_ensure_heading + tag_index_add_pointer
# ---------------------------------------------------------------------------
@test "docs-map tags: render_tag_index calls ensure_heading and add_pointer for each tag" {
  _source_docs_map

  docs_map_build
  # Add a tag to a row so render has something to emit
  docs_map_tag_section_by_pointer "test-doc.md#Section Alpha" "render-tag"

  # Stub log file
  local log_file="${FIXTURE_DIR}/render-calls.log"

  # Stub write helpers — must be defined before calling render_tag_index
  tag_index_ensure_file() { :; }
  tag_index_ensure_heading() { printf 'ensure_heading:%s\n' "$1" >> "$log_file"; }
  tag_index_add_pointer() { printf 'add_pointer:%s:%s:%s\n' "$1" "$2" "$3" >> "$log_file"; }

  docs_map_render_tag_index

  # Verify stubs were invoked with expected args
  grep -qF 'ensure_heading:render-tag' "$log_file"
  grep -qF 'add_pointer:render-tag:test-doc.md:Section Alpha' "$log_file"
}

# ---------------------------------------------------------------------------
# 7. docs_map_render_tag_index degrades gracefully when helpers not loaded
# ---------------------------------------------------------------------------
@test "docs-map tags: render_tag_index returns 0 when write helpers absent" {
  _source_docs_map

  docs_map_build

  # Unset write helpers to simulate tag-index.sh not being loaded
  unset -f tag_index_ensure_heading 2>/dev/null || true
  unset -f tag_index_add_pointer 2>/dev/null || true

  # Must return 0 without crashing
  docs_map_render_tag_index
}
