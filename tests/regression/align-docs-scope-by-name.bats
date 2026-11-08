#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh::docs_resolve_doc_scope
# tests/regression/align-docs-scope-by-name.bats
#
# Regression tests for #1437: rite align-docs [doc ...] scoping.
#
# Covers:
#   - With-extension and without-extension forms resolve to the same map entry.
#   - Unknown name exits 1 and lists candidates.
#   - No args returns every doc in the map.
#   - Multiple names are accepted and deduped.

load '../helpers/setup'

# ---------------------------------------------------------------------------
# Shared fixture: write a minimal docs-map.tsv to the fake project.
# Columns: file_path<TAB>sha<TAB>adr_flag<TAB>heading_level<TAB>heading_text<TAB>fp<TAB>type<TAB>rubric<TAB>tags<TAB>note
# ---------------------------------------------------------------------------
_write_fake_map() {
  local map_dir="$1"
  mkdir -p "${map_dir}/docs"
  cat > "${map_dir}/docs/docs-map.tsv" <<'MAP_EOF'
# docs-map v4 sha=abc123 built=2026-01-01T00:00:00Z
docs/architecture/behavioral-design.md	abc123	-	1	Behavioral Design	fp	feature	-	-	-
docs/architecture/conventions.md	abc123	-	1	Conventions	fp	feature	-	-	-
docs/other/conventions.md	abc123	-	1	Conventions Alt	fp	feature	-	-	-
README.md	abc123	-		README	fp	other	-	-	-
MAP_EOF
}

# ---------------------------------------------------------------------------
# Helper: one-shot subshell that sources docs-command.sh with overrides, then
# calls docs_resolve_doc_scope with the arguments passed to this function.
# Writes a helper script once per test into BATS_TEST_TMPDIR.
# ---------------------------------------------------------------------------
_scope_helper() {
  local helper="${BATS_TEST_TMPDIR}/scope_helper.sh"
  cat > "$helper" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="${RITE_LIB_DIR}"
export RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT}"
source "${RITE_LIB_DIR}/core/docs-command.sh"
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs function-sentinel guard; post-source stubs preserved
load_provider() { return 0; }
provider_run_prompt_with_timeout() { echo "NO_PROPOSALS_NEEDED"; }
provider_resolve_model() { echo "claude-sonnet-4-6"; }
docs_map_path() { echo "${RITE_PROJECT_ROOT}/docs/docs-map.tsv"; }
docs_map_build() { return 0; }
docs_map_ensure() { return 0; }
docs_resolve_doc_scope "$@"
HELPER_EOF
  chmod +x "$helper"
  echo "$helper"
}

setup() {
  setup_test_tmpdir
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/project"
  export RITE_INSTALL_DIR="$RITE_REPO_ROOT"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_STATE_DIR="$RITE_PROJECT_ROOT/.rite/state"
  mkdir -p "$RITE_PROJECT_ROOT/.rite/state"
  _write_fake_map "$RITE_PROJECT_ROOT"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# AC1: with-extension and without-extension forms resolve to the same path.
# ---------------------------------------------------------------------------

@test "behavioral-design (no ext) resolves to docs/architecture/behavioral-design.md" {
  local helper
  helper="$(_scope_helper)"
  run bash "$helper" behavioral-design < /dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs/architecture/behavioral-design.md"* ]]
}

@test "behavioral-design.md (with ext) resolves to the same path" {
  local helper
  helper="$(_scope_helper)"
  run bash "$helper" behavioral-design.md < /dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs/architecture/behavioral-design.md"* ]]
}

@test "with-ext and without-ext produce identical output" {
  local helper
  helper="$(_scope_helper)"
  run bash "$helper" behavioral-design < /dev/null 2>&1
  local out_no_ext="$output"
  run bash "$helper" behavioral-design.md < /dev/null 2>&1
  [ "$out_no_ext" = "$output" ]
}

# ---------------------------------------------------------------------------
# AC2: unknown name exits 1 and lists candidates.
# ---------------------------------------------------------------------------

@test "unknown doc name exits 1" {
  local helper
  helper="$(_scope_helper)"
  run bash "$helper" nonexistent-totally-unknown-doc < /dev/null 2>&1
  [ "$status" -eq 1 ]
}

@test "unknown doc name prints error to output" {
  local helper
  helper="$(_scope_helper)"
  run bash "$helper" nonexistent-totally-unknown-doc < /dev/null 2>&1
  [[ "$output" == *"error: unknown doc"* ]]
}

@test "unknown doc with substring match lists the candidate" {
  local helper
  helper="$(_scope_helper)"
  # 'behav' is a prefix of 'behavioral-design' basename
  run bash "$helper" behav < /dev/null 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"behavioral-design"* ]]
}

# ---------------------------------------------------------------------------
# AC3: no args → scope is every doc in the map.
# ---------------------------------------------------------------------------

@test "no args echoes all docs from the map" {
  local helper
  helper="$(_scope_helper)"
  run bash "$helper" < /dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs/architecture/behavioral-design.md"* ]]
  [[ "$output" == *"docs/architecture/conventions.md"* ]]
  [[ "$output" == *"docs/other/conventions.md"* ]]
  [[ "$output" == *"README.md"* ]]
}

@test "no args output contains exactly the expected doc count" {
  local helper
  helper="$(_scope_helper)"
  run bash "$helper" < /dev/null 2>&1
  [ "$status" -eq 0 ]
  local count
  count="$(printf '%s\n' "$output" | grep -c '.md' || true)"
  [ "$count" -eq 4 ]
}

# ---------------------------------------------------------------------------
# AC4: multiple names accepted and deduped.
# ---------------------------------------------------------------------------

@test "multiple names returns all resolved paths" {
  local helper
  helper="$(_scope_helper)"
  run bash "$helper" behavioral-design README < /dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs/architecture/behavioral-design.md"* ]]
  [[ "$output" == *"README.md"* ]]
}

@test "duplicate names are deduped in output" {
  local helper
  helper="$(_scope_helper)"
  run bash "$helper" behavioral-design behavioral-design.md behavioral-design < /dev/null 2>&1
  [ "$status" -eq 0 ]
  local count
  count="$(printf '%s\n' "$output" | grep -c 'behavioral-design.md' || true)"
  [ "$count" -eq 1 ]
}

@test "mixed with-ext and without-ext deduped to one entry" {
  local helper
  helper="$(_scope_helper)"
  # behavioral-design has a unique basename; conventions is ambiguous (two paths)
  run bash "$helper" behavioral-design behavioral-design.md < /dev/null 2>&1
  [ "$status" -eq 0 ]
  local count
  count="$(printf '%s\n' "$output" | grep -c 'behavioral-design.md' || true)"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC5: ambiguous basename exits 1 and lists all matching paths.
# ---------------------------------------------------------------------------

@test "ambiguous basename exits 1" {
  local helper
  helper="$(_scope_helper)"
  # 'conventions' matches both docs/architecture/conventions.md and docs/other/conventions.md
  run bash "$helper" conventions < /dev/null 2>&1
  [ "$status" -eq 1 ]
}

@test "ambiguous basename error message names the doc and lists candidates" {
  local helper
  helper="$(_scope_helper)"
  run bash "$helper" conventions < /dev/null 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"ambiguous"* ]]
  [[ "$output" == *"docs/architecture/conventions.md"* ]]
  [[ "$output" == *"docs/other/conventions.md"* ]]
}

# ---------------------------------------------------------------------------
# AC6: whitespace-containing arg exits 1 with a helpful message.
# ---------------------------------------------------------------------------

@test "arg containing a space exits 1" {
  local helper
  helper="$(_scope_helper)"
  run bash "$helper" "behavioral design" < /dev/null 2>&1
  [ "$status" -eq 1 ]
}

@test "arg containing a space prints whitespace error message" {
  local helper
  helper="$(_scope_helper)"
  run bash "$helper" "behavioral design" < /dev/null 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"whitespace"* ]]
}
