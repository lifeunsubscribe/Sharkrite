#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh::docs_resume_proposal
# tests/regression/rite-docs-resume.bats
#
# Regression tests for #1434: rite docs --resume <branch>
#
# Tests verify:
#   1. docs_resume_proposal loads saved proposal and calls _docs_main_entries_pass per listed doc.
#   2. docs_resume_proposal removes the proposal file after all docs are processed.
#   3. docs_resume_proposal exits 1 and lists available candidates when proposal file is missing.
#   4. Slash-containing branch names resolve to dash-separated filename correctly.
#   5. Non-TTY invocation preserves proposal file and exits 1.
#   6. Proposal file kept when _docs_main_entries_pass fails.
#   7. rite_docs dispatches --resume <branch> to docs_resume_proposal.

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
# Test 1: calls _docs_main_entries_pass for each doc in the saved proposal
# ===========================================================================

@test "docs_resume_proposal calls _docs_main_entries_pass for each doc in saved proposal" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_docs_command_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$_state_dir"

  cat > "$_state_dir/doc-proposal-my-branch.md" << 'PROPEOF'
# Pending doc proposal: my-branch

Docs with pending entries:
- docs/architecture/behavioral-design.md
- README.md

Drift entries: 2
PROPEOF

  local _calllog="$RITE_TEST_TMPDIR/calllog.txt"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
export _RITE_FORCE_TTY=1
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"
_docs_main_entries_pass() {
  read -r _unused <&0 2>/dev/null || true
  printf 'CALLED:%s\n' "\$1" >> "$_calllog"
  return 0
}
docs_resume_proposal "my-branch" 2>&1
RUNEOF
)

  run bash "$_runner"
  [ "$status" -eq 0 ]
  grep -q "CALLED:docs/architecture/behavioral-design.md" "$_calllog"
  grep -q "CALLED:README.md" "$_calllog"
}

# ===========================================================================
# Test 2: removes proposal file after processing
# ===========================================================================

@test "docs_resume_proposal removes proposal file after all docs are processed" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_docs_command_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$_state_dir"

  cat > "$_state_dir/doc-proposal-my-branch.md" << 'PROPEOF'
# Pending doc proposal: my-branch

Docs with pending entries:
- docs/adr.md

Drift entries: 1
PROPEOF

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
export _RITE_FORCE_TTY=1
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"
_docs_main_entries_pass() { return 0; }
docs_resume_proposal "my-branch" 2>&1
RUNEOF
)

  run bash "$_runner"
  [ "$status" -eq 0 ]
  [ ! -f "$_state_dir/doc-proposal-my-branch.md" ]
}

# ===========================================================================
# Test 3: exits 1 with candidate listing when proposal file is missing
# ===========================================================================

@test "docs_resume_proposal exits 1 and lists available candidates when proposal file is missing" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_docs_command_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$_state_dir"

  # Create an unrelated proposal as a candidate
  touch "$_state_dir/doc-proposal-other-branch.md"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"
docs_resume_proposal "nonexistent-branch" 2>&1
RUNEOF
)

  run bash "$_runner"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "doc-proposal-other-branch.md"
}

# ===========================================================================
# Test 4: slash-containing branch names resolve to dash-separated filename
# ===========================================================================

@test "docs_resume_proposal resolves slash-containing branch name to dash-separated filename" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_docs_command_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$_state_dir"

  # Proposal file uses dashes; branch arg uses slashes
  cat > "$_state_dir/doc-proposal-releases-v1.2.md" << 'PROPEOF'
# Pending doc proposal: releases/v1.2

Docs with pending entries:
- README.md

Drift entries: 1
PROPEOF

  local _calllog="$RITE_TEST_TMPDIR/calllog.txt"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
export _RITE_FORCE_TTY=1
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"
_docs_main_entries_pass() {
  read -r _unused <&0 2>/dev/null || true
  printf 'CALLED:%s\n' "\$1" >> "$_calllog"
  return 0
}
docs_resume_proposal "releases/v1.2" 2>&1
RUNEOF
)

  run bash "$_runner"
  [ "$status" -eq 0 ]
  grep -q "CALLED:README.md" "$_calllog"
  # Proposal file must be cleaned up
  [ ! -f "$_state_dir/doc-proposal-releases-v1.2.md" ]
}

# ===========================================================================
# Test 5: non-TTY preserves proposal file and exits 1
# ===========================================================================

@test "docs_resume_proposal preserves proposal file and exits 1 when no TTY" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_docs_command_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$_state_dir"

  cat > "$_state_dir/doc-proposal-my-branch.md" << 'PROPEOF'
# Pending doc proposal: my-branch

Docs with pending entries:
- docs/adr.md

Drift entries: 1
PROPEOF

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
# _RITE_FORCE_TTY not set — no TTY in test subprocess
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"
_docs_main_entries_pass() { return 0; }
docs_resume_proposal "my-branch" 2>&1
RUNEOF
)

  run bash "$_runner"
  [ "$status" -eq 1 ]
  # Proposal must be preserved when no TTY
  [ -f "$_state_dir/doc-proposal-my-branch.md" ]
}

# ===========================================================================
# Test 6: proposal file kept when _docs_main_entries_pass fails
# ===========================================================================

@test "docs_resume_proposal keeps proposal file when _docs_main_entries_pass fails" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_docs_command_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$_state_dir"

  cat > "$_state_dir/doc-proposal-my-branch.md" << 'PROPEOF'
# Pending doc proposal: my-branch

Docs with pending entries:
- docs/adr.md

Drift entries: 1
PROPEOF

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
export _RITE_FORCE_TTY=1
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"
_docs_main_entries_pass() { return 1; }
docs_resume_proposal "my-branch" 2>&1
RUNEOF
)

  run bash "$_runner"
  [ "$status" -eq 1 ]
  # Proposal must be preserved when apply failed
  [ -f "$_state_dir/doc-proposal-my-branch.md" ]
}

# ===========================================================================
# Test 7: rite_docs dispatches --resume <branch> to docs_resume_proposal
# ===========================================================================

@test "rite_docs dispatches --resume branch to docs_resume_proposal with branch arg stripped" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_docs_command_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  mkdir -p "$_state_dir"

  local _calllog="$RITE_TEST_TMPDIR/calllog.txt"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"
docs_resume_proposal() {
  printf 'RESUME_CALLED:%s\n' "\$1" >> "$_calllog"
  return 0
}
rite_docs "--resume my-feature-branch" 2>&1
RUNEOF
)

  run bash "$_runner"
  [ "$status" -eq 0 ]
  grep -q "RESUME_CALLED:my-feature-branch" "$_calllog"
}
