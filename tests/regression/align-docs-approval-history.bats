#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh::_docs_restructure_record_decision|_docs_restructure_history_path
# tests/regression/align-docs-approval-history.bats
#
# Regression tests for #1438: approval history recording.
#
# Covers:
#   - Decision appended to history file with all required fields.
#   - File created with header when absent.
#   - Reject records a rejection decision; accept records an accepted decision.
#   - no-restructure-needed is a valid decision value.
#   - Machine-readable marker (<!-- reshist ... -->) is written correctly.
#   - Multiple decisions for the same doc accumulate (not overwritten).

load '../helpers/setup'

_history_helper() {
  local helper="${BATS_TEST_TMPDIR}/history_helper.sh"
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
_docs_restructure_record_decision "$@"
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
# AC: History file created when it does not exist.
# ---------------------------------------------------------------------------

@test "record_decision creates history file when absent" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  [ ! -f "$hist_file" ]
  run bash "$helper" "docs/foo.md" "Should foo be restructured?" "rejected" "No action needed." "5000"
  [ "$status" -eq 0 ]
  [ -f "$hist_file" ]
}

@test "history file begins with a markdown header" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Should foo be restructured?" "rejected" "No action needed." "5000"
  [ "$status" -eq 0 ]
  grep -q '^# Doc Restructure Approval History' "$hist_file"
}

# ---------------------------------------------------------------------------
# AC: All required fields present in the appended record.
# ---------------------------------------------------------------------------

@test "record_decision writes machine-readable reshist marker" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Should foo be restructured?" "rejected" "No action needed." "5000"
  [ "$status" -eq 0 ]
  grep -q '<!-- reshist doc=docs/foo.md' "$hist_file"
}

@test "record_decision embeds decision in reshist marker" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Should foo be restructured?" "rejected" "No action needed." "5000"
  [ "$status" -eq 0 ]
  grep -q 'decision=rejected' "$hist_file"
}

@test "record_decision embeds size_bytes in reshist marker" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Should foo be restructured?" "rejected" "No action needed." "5000"
  [ "$status" -eq 0 ]
  grep -q 'size_bytes=5000' "$hist_file"
}

@test "record_decision writes human-readable Decision field" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Should foo be restructured?" "rejected" "No action needed." "5000"
  [ "$status" -eq 0 ]
  grep -q '^\*\*Decision\*\*:' "$hist_file"
}

@test "record_decision writes human-readable Question field" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Should foo be restructured?" "rejected" "No action needed." "5000"
  [ "$status" -eq 0 ]
  grep -q '^\*\*Question\*\*:' "$hist_file"
}

@test "record_decision writes human-readable Rationale field" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Should foo be restructured?" "rejected" "No action needed." "5000"
  [ "$status" -eq 0 ]
  grep -q '^\*\*Rationale\*\*:' "$hist_file"
}

@test "record_decision writes human-readable Date field" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Should foo be restructured?" "rejected" "No action needed." "5000"
  [ "$status" -eq 0 ]
  grep -q '^\*\*Date\*\*:' "$hist_file"
}

@test "record_decision writes human-readable Size at decision field" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Should foo be restructured?" "rejected" "No action needed." "5000"
  [ "$status" -eq 0 ]
  grep -q '^\*\*Size at decision\*\*:' "$hist_file"
}

# ---------------------------------------------------------------------------
# AC: Decision values: accepted, rejected, no-restructure-needed.
# ---------------------------------------------------------------------------

@test "accepted decision recorded correctly" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Q?" "accepted" "User agreed." "8000"
  [ "$status" -eq 0 ]
  grep -q 'decision=accepted' "$hist_file"
}

@test "no-restructure-needed decision recorded correctly" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Q?" "no-restructure-needed" "LLM: none needed." "3000"
  [ "$status" -eq 0 ]
  grep -q 'decision=no-restructure-needed' "$hist_file"
}

# ---------------------------------------------------------------------------
# AC: Multiple decisions for the same doc accumulate (not overwritten).
# ---------------------------------------------------------------------------

@test "two decisions for same doc accumulate in history file" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Q1?" "rejected" "First." "5000"
  [ "$status" -eq 0 ]
  run bash "$helper" "docs/foo.md" "Q2?" "accepted" "Second." "7000"
  [ "$status" -eq 0 ]
  local count
  count="$(grep -c '<!-- reshist doc=docs/foo.md' "$hist_file" || true)"
  [ "$count" -eq 2 ]
}

@test "second decision does not overwrite first" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Q1?" "rejected" "First." "5000"
  run bash "$helper" "docs/foo.md" "Q2?" "accepted" "Second." "7000"
  grep -q 'size_bytes=5000' "$hist_file"
  grep -q 'size_bytes=7000' "$hist_file"
}

# ---------------------------------------------------------------------------
# AC: Decisions for different docs go to the same file.
# ---------------------------------------------------------------------------

@test "decisions for two different docs land in the same history file" {
  local helper hist_file
  helper="$(_history_helper)"
  hist_file="$RITE_STATE_DIR/doc-approval-history.md"
  run bash "$helper" "docs/foo.md" "Q?" "rejected" "No." "1000"
  run bash "$helper" "docs/bar.md" "Q?" "accepted" "Yes." "2000"
  grep -q 'doc=docs/foo.md' "$hist_file"
  grep -q 'doc=docs/bar.md' "$hist_file"
}
