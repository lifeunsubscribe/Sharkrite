#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/promote-branch.sh, lib/core/docs-command.sh
# tests/regression/promote-docs-after-merge.bats
#
# Regression tests for #1435: post-merge Tier 2 doc pass in rite --promote.
#
# Tests verify:
#   1. Structural: Phase 8 call site appears after squash-merge + ledger mark.
#   2. Structural: Phase 8 region contains no bare `exit`.
#   3. Structural: TTY branch of docs_run_promote_doc_pass calls _docs_main_entries_pass.
#   4. docs_run_promote_doc_pass exits 0 and skips silently when no drift entries exist.
#   5. Non-TTY path saves proposal to doc-proposal-<branch>.md and prints resume command.

load '../helpers/setup'
load '../helpers/promote-stubs'

setup() {
  setup_test_tmpdir
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: extend the fake lib with stubs for docs-command.sh's dependencies.
# Call AFTER _write_promote_stubs_base.
# ---------------------------------------------------------------------------
_write_docs_command_stubs() {
  local _lib="$1"

  cat > "$_lib/utils/docs-map.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f docs_map_ensure >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
docs_map_ensure() { return 0; }
docs_map_path()   { echo "${RITE_STATE_DIR:-/tmp}/docs-map.tsv"; }
STUB

  cat > "$_lib/utils/doc-consent.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f record_doc_mode >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
record_doc_mode() { return 0; }
ensure_doc_mode() { return 0; }
STUB

  # drift-log.sh stubs — return zero entries by default; tests override
  # drift_log_entry_count and _docs_list_branch_entry_docs as needed.
  cat > "$_lib/utils/drift-log.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f drift_log_entry_count >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
drift_log_entry_count() { echo 0; }
_drift_entry_path()     { echo ""; }
drift_log_append()      { return 0; }
drift_log_path()        { echo ""; }
STUB
}

# ===========================================================================
# Group 1: Structural ordering in promote-branch.sh
# ===========================================================================

@test "structural: Phase 8 call follows squash-merge and ledger-mark in promote-branch.sh" {
  local _src="$RITE_REPO_ROOT/lib/core/promote-branch.sh"

  # Squash-merge landmark: the merge_method=squash REST call
  local _merge_line
  _merge_line=$(grep -n "merge_method=squash" "$_src" | head -1 | cut -d: -f1 || true)
  [ -n "$_merge_line" ] || { echo "FAIL: merge_method=squash not found in $( basename "$_src")"; return 1; }

  # Ledger mark landmark: integration_ledger_mark_promoted
  local _ledger_line
  _ledger_line=$(grep -n "integration_ledger_mark_promoted" "$_src" | head -1 | cut -d: -f1 || true)
  [ -n "$_ledger_line" ] || { echo "FAIL: integration_ledger_mark_promoted not found"; return 1; }

  # Phase 8 landmark: the Phase 8 header comment
  local _phase8_line
  _phase8_line=$(grep -n "Phase 8" "$_src" | head -1 | cut -d: -f1 || true)
  [ -n "$_phase8_line" ] || { echo "FAIL: Phase 8 header not found"; return 1; }

  # docs_run_promote_doc_pass call must also appear after Phase 8 header
  local _call_line
  _call_line=$(grep -n "docs_run_promote_doc_pass" "$_src" | tail -1 | cut -d: -f1 || true)
  [ -n "$_call_line" ] || { echo "FAIL: docs_run_promote_doc_pass call not found"; return 1; }

  [ "$_merge_line"  -lt "$_phase8_line" ] || { echo "FAIL: merge (line $_merge_line) not before Phase 8 (line $_phase8_line)";  return 1; }
  [ "$_ledger_line" -lt "$_phase8_line" ] || { echo "FAIL: ledger (line $_ledger_line) not before Phase 8 (line $_phase8_line)"; return 1; }
  [ "$_phase8_line" -le "$_call_line"   ] || { echo "FAIL: Phase 8 header (line $_phase8_line) after call (line $_call_line)";   return 1; }
}

@test "structural: Phase 8 region in promote-branch.sh contains no bare exit" {
  local _src="$RITE_REPO_ROOT/lib/core/promote-branch.sh"

  # Extract lines between "Phase 8" and "# Summary" (the next block header)
  local _start _end
  _start=$(grep -n "Phase 8" "$_src" | head -1 | cut -d: -f1 || true)
  _end=$(grep -n "# Summary" "$_src" | head -1 | cut -d: -f1 || true)
  [ -n "$_start" ] || { echo "FAIL: Phase 8 marker not found"; return 1; }
  [ -n "$_end"   ] || { echo "FAIL: Summary marker not found after Phase 8"; return 1; }

  # Extract the Phase 8 region and look for a bare `exit N` (not `|| true`, not a comment)
  # Allow: `exit 0`, `exit 1` inside comment lines; disallow on real code lines.
  local _bare_exit
  _bare_exit=$(awk -v s="$_start" -v e="$_end" \
    'NR > s && NR < e && /^[[:space:]]*exit[[:space:]]/ && !/^[[:space:]]*#/' "$_src" || true)
  if [ -n "${_bare_exit:-}" ]; then
    echo "FAIL: bare exit found in Phase 8 region:"
    echo "$_bare_exit"
    return 1
  fi
}

# ===========================================================================
# Group 2: Structural assertions in docs-command.sh
# ===========================================================================

@test "structural: TTY branch of docs_run_promote_doc_pass calls _docs_main_entries_pass" {
  local _src="$RITE_REPO_ROOT/lib/core/docs-command.sh"

  # Locate the function body boundaries
  local _fn_start _fn_end
  _fn_start=$(grep -n "^docs_run_promote_doc_pass()" "$_src" | head -1 | cut -d: -f1 || true)
  [ -n "$_fn_start" ] || { echo "FAIL: docs_run_promote_doc_pass not found in $( basename "$_src")"; return 1; }

  # Find the next top-level function after docs_run_promote_doc_pass
  _fn_end=$(awk -v start="$_fn_start" \
    'NR > start && /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ { print NR; exit }' "$_src" || true)
  [ -n "$_fn_end" ] || _fn_end=$(wc -l < "$_src")

  # The function body must reference _docs_main_entries_pass inside the TTY branch
  local _tty_call
  _tty_call=$(awk -v s="$_fn_start" -v e="$_fn_end" \
    'NR > s && NR < e && /_docs_main_entries_pass/' "$_src" || true)
  if [ -z "${_tty_call:-}" ]; then
    echo "FAIL: _docs_main_entries_pass not called inside docs_run_promote_doc_pass"
    return 1
  fi
}

# ===========================================================================
# Group 3: docs_run_promote_doc_pass functional tests
# ===========================================================================

@test "docs_run_promote_doc_pass: exits 0 and skips silently when no drift entries" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_docs_command_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$_state_dir"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"
# drift_log_entry_count returns 0 (from stub) — no override needed
docs_run_promote_doc_pass "my-integration-branch" 2>&1
RUNEOF
)

  run bash "$_runner"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "skipping"
  # No proposal file should be created
  local _safe="my-integration-branch"
  [ ! -f "$_state_dir/doc-proposal-${_safe}.md" ]
}

@test "docs_run_promote_doc_pass: non-TTY saves proposal file and prints rite docs --resume <branch>" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_docs_command_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$_state_dir"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"

# Override stubs to simulate 2 drift entries for one doc
drift_log_entry_count() { echo 2; }
_docs_list_branch_entry_docs() { printf 'docs/architecture/behavioral-design.md\n'; }

docs_run_promote_doc_pass "my-integration-branch" 2>&1
RUNEOF
)

  # Non-TTY: redirect stdin from /dev/null
  run bash "$_runner" < /dev/null
  [ "$status" -eq 0 ]

  # Resume command must be printed to stderr (captured via 2>&1 in runner)
  echo "$output" | grep -q "rite docs --resume my-integration-branch"

  # Proposal file must exist with the expected branch name
  local _proposal="$_state_dir/doc-proposal-my-integration-branch.md"
  [ -f "$_proposal" ] || { echo "FAIL: proposal file not found at $_proposal"; return 1; }

  # File must contain the branch name and pending entries count
  grep -q "my-integration-branch" "$_proposal"
  grep -q "Drift entries: 2"      "$_proposal"
  grep -q "behavioral-design.md"  "$_proposal"
}

@test "docs_run_promote_doc_pass: non-TTY handles slashes in branch name safely" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_docs_command_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$_state_dir"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"

drift_log_entry_count() { echo 1; }
_docs_list_branch_entry_docs() { printf 'README.md\n'; }

docs_run_promote_doc_pass "releases/v1.2" 2>&1
RUNEOF
)

  run bash "$_runner" < /dev/null
  [ "$status" -eq 0 ]

  # Slashes replaced with dashes in filename — must not create a nested path
  local _proposal="$_state_dir/doc-proposal-releases-v1.2.md"
  [ -f "$_proposal" ] || { echo "FAIL: proposal file not found (slash not replaced with dash)"; return 1; }

  # Resume command uses the original (un-mangled) branch name
  echo "$output" | grep -q "rite docs --resume releases/v1.2"
}

@test "docs_run_promote_doc_pass: best-effort — returns 0 even when doc pass stub errors" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_docs_command_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$_state_dir"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"

drift_log_entry_count() { echo 1; }
# _docs_list_branch_entry_docs returns a doc name but writing the proposal
# will fail because RITE_STATE_DIR points to a read-only path.
_docs_list_branch_entry_docs() { printf 'docs/foo.md\n'; }
# Make the proposal directory unwritable
chmod 000 "$_state_dir" 2>/dev/null || true

docs_run_promote_doc_pass "my-branch" 2>&1
_exit=\$?
chmod 755 "$_state_dir" 2>/dev/null || true
exit \$_exit
RUNEOF
)

  run bash "$_runner" < /dev/null
  # Must exit 0 even when file write fails — best-effort contract
  [ "$status" -eq 0 ]
}
