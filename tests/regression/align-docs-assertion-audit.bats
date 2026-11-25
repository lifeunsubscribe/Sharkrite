#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh::docs_run_assertion_audit
# tests/regression/align-docs-assertion-audit.bats
#
# Regression tests for #1439: chunked assertion audit.
#
# Covers:
#   - Pre-run confirmation gate: declining exits 0, no LLM calls made.
#   - Each LLM call is bounded to one map-anchored section + code context,
#     never a whole document (stub-asserted via call recorder).
#   - Rubric selection follows the map's type column; rubric-override pointer
#     in the map wins over shipped defaults.
#   - ADR role check calls docs_map_adr_links for ADR-type sections.
#   - Nondeterministic findings auto-record as kind=refinement drift entries.

load '../helpers/setup'

# ---------------------------------------------------------------------------
# Build a minimal docs-map.tsv with one or more sections.
#
# Columns (v4): file_path, last_verified_sha, adr_flag, heading_level,
#               heading_text, fingerprint, type, rubric, tags, note
# ---------------------------------------------------------------------------
_write_map() {
  local map_file="$1"
  shift
  # Write v4 header
  printf '# docs-map v4 sha=abc123 built=2026-10-26T00:00:00Z\n' > "$map_file"
  # Remaining args: "doc_path|hl|ht|type|rubric" per section row
  local entry
  for entry in "$@"; do
    local _p _hl _ht _dt _rb
    _p="$(printf '%s' "$entry" | cut -d'|' -f1)"
    _hl="$(printf '%s' "$entry" | cut -d'|' -f2)"
    _ht="$(printf '%s' "$entry" | cut -d'|' -f3)"
    _dt="$(printf '%s' "$entry" | cut -d'|' -f4)"
    _rb="$(printf '%s' "$entry" | cut -d'|' -f5)"
    printf '%s\tabc123\t-\t%s\t%s\tfingerprint000\t%s\t%s\t-\t-\n' \
      "$_p" "$_hl" "$_ht" "$_dt" "$_rb" >> "$map_file"
  done
}

# ---------------------------------------------------------------------------
# Build a helper script that sources docs-command.sh with stubs and calls
# docs_run_assertion_audit.
#
# Arguments:
#   $1 — provider output (what provider_run_prompt_with_timeout echoes)
#   $2 — stdin to feed (y/N for confirmation, then y/n per finding)
#   $3 — path to write provider call log (records each prompt's first line)
#   $4 — optional: path to write docs_map_adr_links call log
#   $5 — optional: what docs_map_adr_links should return (default empty)
#   $6 — optional: what drift_log_append should write to (call log path)
# ---------------------------------------------------------------------------
_audit_helper() {
  local provider_output="$1"
  local stdin_input="${2:-y}"
  local call_log="${3:-}"
  local adr_log="${4:-}"
  local adr_return="${5:-}"
  local drift_log="${6:-}"
  local info_log="${7:-}"

  local helper="${BATS_TEST_TMPDIR}/audit_helper.sh"
  cat > "$helper" << HELPER_EOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="${RITE_LIB_DIR}"
export RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT}"
export RITE_STATE_DIR="${RITE_STATE_DIR}"
export RITE_TARGET_BRANCH="main"
export _RITE_FORCE_TTY=1
source "\${RITE_LIB_DIR}/core/docs-command.sh"
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs function-sentinel guard; post-source stubs are preserved
provider_run_prompt_with_timeout() {
  local _prompt="\$1"
  if [ -n "${call_log}" ]; then
    printf '%s\n' "\$_prompt" >> "${call_log}"
    printf -- '---CALL-BOUNDARY---\n' >> "${call_log}"
  fi
  printf '%s\n' "${provider_output}"
}
provider_resolve_model() { echo "claude-sonnet-4-6"; }
docs_map_path() { echo "\${RITE_PROJECT_ROOT}/docs/docs-map.tsv"; }
docs_map_build() { return 0; }
docs_map_ensure() { return 0; }
docs_resolve_doc_scope() {
  awk -F'\t' '/^#/{next} NF>=1{print \$1}' "\${RITE_PROJECT_ROOT}/docs/docs-map.tsv" 2>/dev/null | sort -u || true
}
docs_map_adr_links() {
  if [ -n "${adr_log}" ]; then
    printf '%s\n' "\$1" >> "${adr_log}"
  fi
  printf '%s\n' "${adr_return}"
}
drift_log_append() {
  if [ -n "${drift_log}" ]; then
    printf '%s\n' "\$@" >> "${drift_log}"
  fi
  return 0
}
lock_acquire() { return 0; }
lock_release() { return 0; }
print_info() {
  if [ -n "${info_log}" ]; then
    printf '%s\n' "\$@" >> "${info_log}"
  fi
}
print_warning() { true; }
print_success() { true; }
git() {
  case "\${1:-}" in
    -C) shift; shift ;;
  esac
  case "\${1:-}" in
    rev-parse) echo "main" ;;
    *) true ;;
  esac
}
docs_run_assertion_audit "\${@}"
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
  mkdir -p "$RITE_PROJECT_ROOT/docs/architecture"
  mkdir -p "$RITE_STATE_DIR"

  # Write a feature doc with one heading section
  printf '# Feature A\n\nThis section describes feature A.\n' \
    > "$RITE_PROJECT_ROOT/docs/feature-a.md"
  # Write a simple ADR
  printf '# ADR-001 Architecture\n\nDecision: use feature-a.\n' \
    > "$RITE_PROJECT_ROOT/docs/architecture/adr-001-arch.md"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Test 1: Pre-run confirmation gate — declining exits 0 with no LLM calls.
# ---------------------------------------------------------------------------
@test "confirmation gate: declining exits 0 and makes no provider calls" {
  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/feature-a.md|1|Feature A|feature|-"

  local call_log="${BATS_TEST_TMPDIR}/calls.log"
  local helper
  helper="$(_audit_helper "NOTHING_FOUND" "n" "$call_log")"

  # Feed "n" to decline the confirmation prompt
  run bash "$helper" <<< $'n\n'
  [ "$status" -eq 0 ]
  # No LLM calls should have been made
  [ ! -f "$call_log" ] || [ ! -s "$call_log" ]
}

# ---------------------------------------------------------------------------
# Test 2: Each call is bounded to one section + code, never the whole doc.
# The call log records the first 5 lines of each prompt; we assert each
# recorded call references a section anchor (§) and the total call count
# matches the number of map sections (not the number of docs).
# ---------------------------------------------------------------------------
@test "per-section chunking: one call per map section, each prompt contains section anchor" {
  # Two sections in the same doc → expect two calls
  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/feature-a.md|1|Feature A|feature|-" \
    "docs/feature-a.md|2|Sub-section B|feature|-"

  # Append second heading to the doc so _docs_extract_section finds it
  printf '## Sub-section B\n\nContent for sub-section B.\n' \
    >> "$RITE_PROJECT_ROOT/docs/feature-a.md"

  local call_log="${BATS_TEST_TMPDIR}/calls.log"
  local helper
  helper="$(_audit_helper "NOTHING_FOUND" "y" "$call_log")"

  run bash "$helper" <<< $'y\n'
  [ "$status" -eq 0 ]

  # Exactly two call boundaries recorded
  local call_count
  call_count="$(grep -c '^---CALL-BOUNDARY---$' "$call_log" || true)"
  [ "$call_count" -eq 2 ]

  # Each call's prompt must contain a section anchor (§) — never the whole doc
  local anchor_count
  anchor_count="$(grep -c '§' "$call_log" || true)"
  [ "$anchor_count" -ge 2 ]
}

# ---------------------------------------------------------------------------
# Test 3: Rubric selection — feature type uses feature rubric; ADR type uses
# ADR rubric; map's rubric-override file wins over shipped defaults.
# ---------------------------------------------------------------------------
@test "rubric selection: feature doc section receives feature rubric" {
  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/feature-a.md|1|Feature A|feature|-"

  local call_log="${BATS_TEST_TMPDIR}/calls.log"
  local helper
  helper="$(_audit_helper "NOTHING_FOUND" "y" "$call_log")"

  run bash "$helper" <<< $'y\n'
  [ "$status" -eq 0 ]

  # The feature rubric keyword must appear in the logged prompt
  grep -q "feature boundary\|sibling feature" "$call_log"
}

@test "rubric selection: ADR doc section receives ADR rubric" {
  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/architecture/adr-001-arch.md|1|ADR-001 Architecture|adr|-"

  local call_log="${BATS_TEST_TMPDIR}/calls.log"
  local helper
  helper="$(_audit_helper "NOTHING_FOUND" "y" "$call_log")"

  run bash "$helper" <<< $'y\n'
  [ "$status" -eq 0 ]

  # The ADR rubric keyword must appear in the logged prompt
  grep -q "ADR role check\|feature doc\|architectural decision\|link every feature" "$call_log"
}

@test "rubric selection: map rubric-override file wins over shipped defaults" {
  # Write a custom rubric file
  local rubric_file="${RITE_PROJECT_ROOT}/docs/custom-rubric.txt"
  printf 'CUSTOM_RUBRIC_SENTINEL_XYZ: only check for capitalization errors.\n' > "$rubric_file"

  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/feature-a.md|1|Feature A|feature|docs/custom-rubric.txt"

  local call_log="${BATS_TEST_TMPDIR}/calls.log"
  local helper
  helper="$(_audit_helper "NOTHING_FOUND" "y" "$call_log")"

  run bash "$helper" <<< $'y\n'
  [ "$status" -eq 0 ]

  # The custom rubric content must appear in the prompt (override wins)
  grep -q "CUSTOM_RUBRIC_SENTINEL_XYZ" "$call_log"
  # The shipped feature rubric must NOT appear (it was overridden)
  ! grep -q "feature boundary\|sibling feature" "$call_log"
}

# ---------------------------------------------------------------------------
# Test 4: ADR role check calls docs_map_adr_links for ADR-type sections.
# Zero-coverage and missing-link findings surface as audit findings, not edits.
# ---------------------------------------------------------------------------
@test "ADR role check: docs_map_adr_links is called for ADR sections" {
  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/architecture/adr-001-arch.md|1|ADR-001 Architecture|adr|-"

  local adr_log="${BATS_TEST_TMPDIR}/adr_calls.log"
  local call_log="${BATS_TEST_TMPDIR}/calls.log"
  local helper
  helper="$(_audit_helper "NOTHING_FOUND" "y" "$call_log" "$adr_log" "")"

  run bash "$helper" <<< $'y\n'
  [ "$status" -eq 0 ]

  # docs_map_adr_links must have been invoked for the ADR doc
  grep -qF "docs/architecture/adr-001-arch.md" "$adr_log"
}

@test "ADR role check: missing feature-doc links surface as cross-doc context in prompt" {
  # Map has one feature doc and one ADR section; ADR does NOT link the feature doc
  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/architecture/adr-001-arch.md|1|ADR-001 Architecture|adr|-" \
    "docs/feature-a.md|1|Feature A|feature|-"

  local call_log="${BATS_TEST_TMPDIR}/calls.log"
  local adr_log="${BATS_TEST_TMPDIR}/adr_calls.log"
  # docs_map_adr_links returns empty → feature-a.md is NOT linked → missing
  local helper
  helper="$(_audit_helper "NOTHING_FOUND" "y" "$call_log" "$adr_log" "")"

  run bash "$helper" <<< $'y\n'
  [ "$status" -eq 0 ]

  # Cross-doc context must appear in the ADR section's prompt
  grep -q "docs/feature-a.md\|NOT linked\|cross-doc" "$call_log"
}

# ---------------------------------------------------------------------------
# Test 5: Nondeterministic findings auto-record as kind=refinement drift entries.
# ---------------------------------------------------------------------------
@test "nondeterministic finding auto-records as refinement drift entry without prompt" {
  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/feature-a.md|1|Feature A|feature|-"

  local drift_calls="${BATS_TEST_TMPDIR}/drift_calls.log"
  local provider_out="FINDING: nondeterministic|The assertion 'always succeeds' cannot be verified statically"
  # stdin only has the confirmation "y" — no per-finding prompts (auto-routed)
  local helper
  helper="$(_audit_helper "$provider_out" "y" "" "" "" "$drift_calls")"

  run bash "$helper" <<< $'y\n'
  [ "$status" -eq 0 ]

  # drift_log_append must have been called
  [ -f "$drift_calls" ] && [ -s "$drift_calls" ]

  # The kind argument must be "refinement"
  grep -qF "refinement" "$drift_calls"
}

@test "accuracy finding prompts the user and records kind=contradiction on accept" {
  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/feature-a.md|1|Feature A|feature|-"

  local drift_calls="${BATS_TEST_TMPDIR}/drift_calls.log"
  local provider_out="FINDING: accuracy|Function foo() is described as returning 0 on success but actually returns 1"
  # stdin: "y" for confirmation, then "y" to accept the finding
  local helper
  helper="$(_audit_helper "$provider_out" "y" "" "" "" "$drift_calls")"

  run bash "$helper" <<< $'y\ny\n'
  [ "$status" -eq 0 ]

  [ -f "$drift_calls" ] && [ -s "$drift_calls" ]
  grep -qF "contradiction" "$drift_calls"
}

@test "accuracy finding skipped when user declines" {
  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/feature-a.md|1|Feature A|feature|-"

  local drift_calls="${BATS_TEST_TMPDIR}/drift_calls.log"
  local provider_out="FINDING: accuracy|Function foo() is described as returning 0 on success but actually returns 1"
  # stdin: "y" for confirmation, then "n" to skip the finding
  local helper
  helper="$(_audit_helper "$provider_out" "y" "" "" "" "$drift_calls")"

  run bash "$helper" <<< $'y\nn\n'
  [ "$status" -eq 0 ]

  # drift_log_append must NOT have been called (no finding accepted)
  [ ! -f "$drift_calls" ] || [ ! -s "$drift_calls" ]
}

# ---------------------------------------------------------------------------
# Tests for deterministic enforcing-test marker check (#1836-1838).
# Covers: rubric removal, missing/existing path recording, no-marker count,
#         and check runs even when all sections are already done.
# ---------------------------------------------------------------------------
@test "feature rubric has no marker item" {
  # The shipped default feature rubric must not ask the model about enforcing tests.
  local rubric_line
  rubric_line="$(grep -m1 '_DOCS_AUDIT_RUBRIC_FEATURE.*:-' \
    "$RITE_LIB_DIR/core/docs-command.sh" || true)"
  [ -n "$rubric_line" ]
  ! grep -qE "enforcing test|sharkrite-enforced-by|path[.]bats" <<< "$rubric_line"
}

@test "missing enforcing test is recorded as reference-missing drift entry" {
  # Feature doc declares a test file that does not exist.
  printf '# Feature A\n\n<!-- sharkrite-enforced-by: tests/regression/nonexistent-et-1836.bats -->\n\nContent.\n' \
    > "$RITE_PROJECT_ROOT/docs/feature-a.md"

  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/feature-a.md|1|Feature A|feature|-"

  local drift_calls="${BATS_TEST_TMPDIR}/drift_calls.log"
  local helper
  helper="$(_audit_helper "NOTHING_FOUND" "y" "" "" "" "$drift_calls")"

  run bash "$helper" <<< $'y\n'
  [ "$status" -eq 0 ]

  # drift_log_append must have been called with reference-missing for the path
  [ -f "$drift_calls" ] && [ -s "$drift_calls" ]
  grep -qF "reference-missing" "$drift_calls"
  grep -qF "tests/regression/nonexistent-et-1836.bats" "$drift_calls"
}

@test "existing enforcing test records nothing" {
  # Feature doc declares a test file that DOES exist — no drift entry.
  mkdir -p "$RITE_PROJECT_ROOT/tests/regression"
  touch "$RITE_PROJECT_ROOT/tests/regression/existing-et-1836.bats"
  printf '# Feature A\n\n<!-- sharkrite-enforced-by: tests/regression/existing-et-1836.bats -->\n\nContent.\n' \
    > "$RITE_PROJECT_ROOT/docs/feature-a.md"

  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/feature-a.md|1|Feature A|feature|-"

  local drift_calls="${BATS_TEST_TMPDIR}/drift_calls.log"
  local helper
  helper="$(_audit_helper "NOTHING_FOUND" "y" "" "" "" "$drift_calls")"

  run bash "$helper" <<< $'y\n'
  [ "$status" -eq 0 ]

  # No reference-missing entry for the existing path
  [ ! -f "$drift_calls" ] || ! grep -qF "existing-et-1836.bats" "$drift_calls"
}

@test "docs without enforcing tests are counted, no drift entry recorded" {
  # Feature doc has no enforced-by marker: counted in info summary, no drift entry.
  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/feature-a.md|1|Feature A|feature|-"

  local drift_calls="${BATS_TEST_TMPDIR}/drift_calls.log"
  local info_log="${BATS_TEST_TMPDIR}/info.log"
  local helper
  helper="$(_audit_helper "NOTHING_FOUND" "y" "" "" "" "$drift_calls" "$info_log")"

  run bash "$helper" <<< $'y\n'
  [ "$status" -eq 0 ]

  # No drift entry recorded for a doc with no marker
  [ ! -f "$drift_calls" ] || [ ! -s "$drift_calls" ]

  # Info summary must mention the no-marker count
  [ -f "$info_log" ] && grep -qF "declare no enforcing test" "$info_log"
}

@test "marker check runs once per doc not once per section" {
  # A doc with 2 sections and 1 missing enforcing test must produce exactly
  # 1 drift entry — the check is per-doc, so it runs once regardless of how
  # many sections the doc contains.
  printf '# Feature A\n\n<!-- sharkrite-enforced-by: tests/regression/nonexistent-et-once-1836.bats -->\n\nSection A content.\n\n## Sub-section B\n\nSection B content.\n' \
    > "$RITE_PROJECT_ROOT/docs/feature-a.md"

  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/feature-a.md|1|Feature A|feature|-" \
    "docs/feature-a.md|2|Sub-section B|feature|-"

  local drift_calls="${BATS_TEST_TMPDIR}/drift_calls.log"
  local helper
  helper="$(_audit_helper "NOTHING_FOUND" "y" "" "" "" "$drift_calls")"

  run bash "$helper" <<< $'y\n'
  [ "$status" -eq 0 ]

  # The path must appear in the drift log
  [ -f "$drift_calls" ] && [ -s "$drift_calls" ]
  grep -qF "nonexistent-et-once-1836.bats" "$drift_calls"

  # The check runs once per doc: exactly 1 "reference-missing" drift call
  local entry_count
  entry_count="$(grep -c "reference-missing" "$drift_calls" || true)"
  [ "$entry_count" -eq 1 ]
}
