#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh::_docs_restructure_should_propose|_docs_restructure_history_lookup|_docs_restructure_history_path
# tests/regression/align-docs-restructure-stability.bats
#
# Regression tests for #1438: restructure assessment stability suppression rule.
#
# Covers:
#   - No prior history → proposal raised.
#   - Prior decision + doc NOT grown past threshold → proposal suppressed.
#   - Prior decision + doc grown AT threshold → proposal raised.
#   - Prior decision + doc grown ABOVE threshold → proposal raised.
#   - Prior decision + doc grown just BELOW threshold → proposal suppressed.
#   - Recorded size of 0 → proposal raised (can't compute growth).

load '../helpers/setup'

# ---------------------------------------------------------------------------
# Shared helper: write a helper script that sources docs-command.sh and
# calls the function under test with the given arguments.
# ---------------------------------------------------------------------------
_stability_helper() {
  local helper="${BATS_TEST_TMPDIR}/stability_helper.sh"
  cat > "$helper" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="${RITE_LIB_DIR}"
export RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT}"
export RITE_STATE_DIR="${RITE_STATE_DIR}"
source "${RITE_LIB_DIR}/core/docs-command.sh"
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs function-sentinel guard; post-source stubs preserved
load_provider() { return 0; }
provider_run_prompt_with_timeout() { echo "NO_PROPOSALS_NEEDED"; }
provider_resolve_model() { echo "claude-sonnet-4-6"; }
docs_map_path() { echo "${RITE_PROJECT_ROOT}/docs/docs-map.tsv"; }
docs_map_build() { return 0; }
docs_map_ensure() { return 0; }
docs_resolve_doc_scope() { echo "docs/foo.md"; }
FUNC="${1:-_docs_restructure_should_propose}"
shift
"$FUNC" "$@"
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
  mkdir -p "$RITE_STATE_DIR"
  mkdir -p "$RITE_PROJECT_ROOT/docs"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: write a history entry directly to the approval history file.
# ---------------------------------------------------------------------------
_write_history_entry() {
  local doc="$1" decision="$2" size_bytes="$3" date="${4:-2026-01-01}"
  local hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  if [ ! -f "$hist_file" ]; then
    printf '# Doc Restructure Approval History\n\n' > "$hist_file"
  fi
  printf '<!-- reshist doc=%s decision=%s size_bytes=%s date=%s -->\n' \
    "$doc" "$decision" "$size_bytes" "$date" >> "$hist_file"
  printf '## %s\n\n' "$doc" >> "$hist_file"
  printf '**Decision**: %s\n**Size at decision**: %s bytes\n\n' \
    "$decision" "$size_bytes" >> "$hist_file"
}

# ---------------------------------------------------------------------------
# AC: No prior history — proposal raised (exit 0).
# ---------------------------------------------------------------------------

@test "no history entry → should_propose returns 0 (raise)" {
  local helper
  helper="$(_stability_helper)"
  run bash "$helper" _docs_restructure_should_propose "docs/foo.md" 10000
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC: Prior decision, doc has NOT grown past threshold → suppress (exit 1).
# ---------------------------------------------------------------------------

@test "prior decision, no growth → should_propose returns 1 (suppress)" {
  _write_history_entry "docs/foo.md" "rejected" "10000"
  local helper
  helper="$(_stability_helper)"
  # Current size = 10000 (0% growth), threshold defaults to 25%
  run bash "$helper" _docs_restructure_should_propose "docs/foo.md" 10000
  [ "$status" -eq 1 ]
}

@test "prior decision, growth just below threshold (24%) → suppress" {
  _write_history_entry "docs/foo.md" "rejected" "10000"
  local helper
  helper="$(_stability_helper)"
  # 10000 * 1.24 = 12400 → 24% growth, threshold=25
  run bash "$helper" _docs_restructure_should_propose "docs/foo.md" 12400
  [ "$status" -eq 1 ]
}

@test "prior decision, growth below threshold with custom threshold → suppress" {
  _write_history_entry "docs/foo.md" "accepted" "20000"
  local helper
  helper="$(_stability_helper)"
  # 20000 * 1.09 = 21800 → 9% growth, threshold=10
  RITE_DOC_RESTRUCTURE_REGROWTH_PCT=10 run bash "$helper" \
    _docs_restructure_should_propose "docs/foo.md" 21800
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC: Prior decision, doc has grown AT threshold → raise (exit 0).
# ---------------------------------------------------------------------------

@test "prior decision, growth AT threshold (25%) → should_propose returns 0 (raise)" {
  _write_history_entry "docs/foo.md" "rejected" "10000"
  local helper
  helper="$(_stability_helper)"
  # 10000 * 1.25 = 12500 → exactly 25% growth
  run bash "$helper" _docs_restructure_should_propose "docs/foo.md" 12500
  [ "$status" -eq 0 ]
}

@test "prior decision, growth exactly at custom threshold (10%) → raise" {
  _write_history_entry "docs/foo.md" "rejected" "20000"
  local helper
  helper="$(_stability_helper)"
  # 20000 * 1.10 = 22000 → exactly 10% growth
  RITE_DOC_RESTRUCTURE_REGROWTH_PCT=10 run bash "$helper" \
    _docs_restructure_should_propose "docs/foo.md" 22000
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC: Prior decision, doc has grown ABOVE threshold → raise (exit 0).
# ---------------------------------------------------------------------------

@test "prior decision, growth above threshold (50%) → should_propose returns 0 (raise)" {
  _write_history_entry "docs/foo.md" "rejected" "10000"
  local helper
  helper="$(_stability_helper)"
  # 10000 * 1.50 = 15000 → 50% growth
  run bash "$helper" _docs_restructure_should_propose "docs/foo.md" 15000
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC: Recorded size is 0 → cannot compute growth — raise (exit 0).
# ---------------------------------------------------------------------------

@test "recorded size 0 in history → should_propose returns 0 (raise)" {
  _write_history_entry "docs/foo.md" "rejected" "0"
  local helper
  helper="$(_stability_helper)"
  run bash "$helper" _docs_restructure_should_propose "docs/foo.md" 10000
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC: history_lookup returns empty when no entry exists.
# ---------------------------------------------------------------------------

@test "history_lookup returns empty when history file absent" {
  local helper
  helper="$(_stability_helper)"
  run bash "$helper" _docs_restructure_history_lookup "docs/foo.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "history_lookup returns decision and size_bytes when entry exists" {
  _write_history_entry "docs/foo.md" "rejected" "42000"
  local helper
  helper="$(_stability_helper)"
  run bash "$helper" _docs_restructure_history_lookup "docs/foo.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rejected"* ]]
  [[ "$output" == *"42000"* ]]
}

@test "history_lookup returns most recent entry when multiple entries exist" {
  _write_history_entry "docs/foo.md" "rejected" "10000" "2026-01-01"
  _write_history_entry "docs/foo.md" "accepted" "20000" "2026-06-01"
  local helper
  helper="$(_stability_helper)"
  run bash "$helper" _docs_restructure_history_lookup "docs/foo.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted"* ]]
  [[ "$output" == *"20000"* ]]
}

# ---------------------------------------------------------------------------
# AC: history_path returns path inside RITE_STATE_DIR.
# ---------------------------------------------------------------------------

@test "history_path returns path under RITE_STATE_DIR" {
  local helper
  helper="$(_stability_helper)"
  run bash "$helper" _docs_restructure_history_path
  [ "$status" -eq 0 ]
  [[ "$output" == *"doc-approval-history.md"* ]]
  [[ "$output" == *"$RITE_STATE_DIR"* ]]
}
