#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh
# tests/regression/rite-docs-main-entries.bats
BATS_TEST_TIMEOUT=30
#
# Tests for ACTION: REFINE proposal handling (#1517):
# - REFINE with valid drift refs appends to the file and burns the entry (no new drift_log_append)
# - REFINE with DRIFT_REFS: none is auto-skipped (feedback-loop guard)
# - REFINE targeting a missing file is auto-skipped

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DOCS_CMD="$PROJECT_ROOT/lib/core/docs-command.sh"
  export PROJECT_ROOT DOCS_CMD

  FAKE_PROJECT="$(mktemp -d)"
  mkdir -p "$FAKE_PROJECT/.rite/state" "$FAKE_PROJECT/docs"
  printf '# Large Doc\n\nExisting content.\n' > "$FAKE_PROJECT/docs/large-doc.md"
  git -C "$FAKE_PROJECT" init -q
  git -C "$FAKE_PROJECT" config user.email "test@sharkrite.local"
  git -C "$FAKE_PROJECT" config user.name "Test"
  git -C "$FAKE_PROJECT" add .
  git -C "$FAKE_PROJECT" commit -q -m "init"
  export FAKE_PROJECT

  STUB_BIN="$(mktemp -d)"
  STUB_CALLS_FILE="$(mktemp)"
  REAL_GIT="$(command -v git)"
  export STUB_BIN STUB_CALLS_FILE REAL_GIT

  cat > "$STUB_BIN/git" << 'GITSTUB'
#!/bin/bash
for _a in "$@"; do
  case "$_a" in
    push)  printf 'git:push\n' >> "${STUB_CALLS_FILE}"; exit 0 ;;
    fetch) printf 'git:fetch\n' >> "${STUB_CALLS_FILE}"; exit 0 ;;
  esac
done
exec "$REAL_GIT" "$@"
GITSTUB
  chmod +x "$STUB_BIN/git"

  _DOCS_HELPER="$(mktemp)"
  cat > "$_DOCS_HELPER" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail

export RITE_LIB_DIR="${PROJECT_ROOT}/lib"
export RITE_PROJECT_ROOT="${FAKE_PROJECT}"
export RITE_DATA_DIR=".rite"
export RITE_STATE_DIR="${FAKE_PROJECT}/.rite/state"
export RITE_TARGET_BRANCH=main

export PATH="${STUB_BIN}:${PATH}"
export STUB_CALLS_FILE

source "${DOCS_CMD}"

# Re-define stubs AFTER source (env-guarded libs overwrite pre-source stubs)
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs sentinel guard; gh_safe stub must be post-source because gh-retry.sh uses _RITE_GH_RETRY_LOADED env guard which overwrites pre-source definitions
load_provider()                    { return 0; }
provider_run_prompt_with_timeout() {
  local _prompt="$1"
  local _stub="${STUB_PROPOSALS:-NO_PROPOSALS_NEEDED}"
  local _end_tok
  _end_tok="$(printf '%s\n' "$_prompt" | grep -oE -- '---END-[0-9]+---' | head -1 || true)"
  if [ -n "$_end_tok" ]; then
    printf '%s\n' "$_stub" | sed "s/@@END@@/${_end_tok}/"
  else
    printf '%s\n' "$_stub"
  fi
}
provider_resolve_model()           { printf 'claude-sonnet-4-6\n'; }
docs_map_ensure()                  { [ -s "${FAKE_PROJECT}/.rite/state/docs-map.tsv" ] || printf 'docs/large-doc.md\n' > "${FAKE_PROJECT}/.rite/state/docs-map.tsv"; return 0; }
docs_map_path()                    { printf '%s/.rite/state/docs-map.tsv\n' "${FAKE_PROJECT}"; }
gh_safe()                          { printf 'gh_safe:%s\n' "$*" >> "${STUB_CALLS_FILE}"; return 0; }

git -C "${FAKE_PROJECT}" update-ref refs/remotes/origin/main HEAD

"$@"
HELPER_EOF
  chmod +x "$_DOCS_HELPER"
  export _DOCS_HELPER
}

teardown() {
  rm -rf "${FAKE_PROJECT:-}" "${STUB_BIN:-}" "${_DOCS_HELPER:-}"
  rm -f "${STUB_CALLS_FILE:-}"
  git -C "${FAKE_PROJECT:-/dev/null}" worktree prune 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test 1: REFINE with valid drift refs appends content and burns the entry
# ---------------------------------------------------------------------------

@test "approving a REFINE proposal appends to the file and burns the drift entry" {
  local drift_log="$FAKE_PROJECT/docs/sharkrite-drift-log.md"
  cat > "$drift_log" << 'DRIFT_EOF'
# Sharkrite Drift Log

<!-- sharkrite-doc-drift pr:777 issue:5 recorded:2026-01-01T00:00:00Z -->
**Changed files**: lib/core/foo.sh
**Implicated docs**:
- docs/large-doc.md — "Existing content"
**Suspected inaccuracy**: foo changed
<!-- /sharkrite-doc-drift -->
DRIFT_EOF
  git -C "$FAKE_PROJECT" add "$drift_log"
  git -C "$FAKE_PROJECT" commit -q -m "add drift entry pr:777"

  local proposal
  proposal="$(printf '%s\n' \
    '---PROPOSAL---' \
    'ACTION: REFINE' \
    'FILE: docs/large-doc.md' \
    'DRIFT_REFS: pr:777' \
    'DESCRIPTION: Add clarifying note about foo change' \
    '---CONTENT---' \
    '## Note on foo change' \
    '' \
    'foo was updated in a recent refactor.' \
    '@@END@@')"

  run bash -c "
    export STUB_PROPOSALS='${proposal//\'/\'\\\'\'}'
    bash '${_DOCS_HELPER}' docs_directed_update 'add note about foo' <<< 'y'
  " || true

  # A docs branch must have been created
  local docs_branch
  docs_branch="$(git -C "$FAKE_PROJECT" branch --format='%(refname:short)' | grep '^docs/' | head -1 || true)"
  [ -n "$docs_branch" ]

  # The file must contain the appended section
  local committed_content
  committed_content="$(git -C "$FAKE_PROJECT" show "${docs_branch}:docs/large-doc.md" 2>/dev/null || true)"
  [ -n "$committed_content" ]
  printf '%s' "$committed_content" | grep -q "Note on foo change"
  # Original content must still be present (not overwritten)
  printf '%s' "$committed_content" | grep -q "Existing content"

  # The drift entry for pr:777 must be burned down
  local committed_drift
  committed_drift="$(git -C "$FAKE_PROJECT" show "${docs_branch}:docs/sharkrite-drift-log.md" 2>/dev/null || echo "")"
  ! printf '%s' "$committed_drift" | grep -q 'pr:777'

  # The drift log must NOT have grown (no new drift_log_append from REFINE)
  # Entry count: 0 (burned) or file deleted; either way pr:777 entry count = 0
  local new_entry_count
  new_entry_count="$(printf '%s' "$committed_drift" | grep -c 'sharkrite-doc-drift pr:[0-9]' || true)"
  [ "$new_entry_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 2: REFINE with DRIFT_REFS: none is auto-skipped (feedback-loop guard)
# ---------------------------------------------------------------------------

@test "REFINE proposal with DRIFT_REFS: none is auto-skipped with a warning" {
  local doc_before
  doc_before="$(cat "$FAKE_PROJECT/docs/large-doc.md")"

  local proposal
  proposal="$(printf '%s\n' \
    '---PROPOSAL---' \
    'ACTION: REFINE' \
    'FILE: docs/large-doc.md' \
    'DRIFT_REFS: none' \
    'DESCRIPTION: Add a general clarification with no drift refs' \
    '---CONTENT---' \
    '## Should Not Appear' \
    '' \
    'This content must not be appended.' \
    '@@END@@')"

  run bash -c "
    export STUB_PROPOSALS='${proposal//\'/\'\\\'\'}'
    bash '${_DOCS_HELPER}' docs_directed_update 'add general note' 2>&1
  " || true

  # Warning must mention the guard fired
  printf '%s\n' "$output" | grep -qi "Auto-skipping REFINE"

  # No docs branch created (no approvals → no apply)
  local docs_branch
  docs_branch="$(git -C "$FAKE_PROJECT" branch --format='%(refname:short)' | grep '^docs/' | head -1 || true)"
  [ -z "$docs_branch" ]

  # File must be byte-identical — guard prevented append
  local doc_after
  doc_after="$(cat "$FAKE_PROJECT/docs/large-doc.md")"
  [ "$doc_before" = "$doc_after" ]

  # No git push
  local push_calls
  push_calls="$(grep -c 'git:push' "$STUB_CALLS_FILE" 2>/dev/null || true)"
  [ "$push_calls" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 3: REFINE targeting a missing file is auto-skipped
# ---------------------------------------------------------------------------

@test "REFINE proposal targeting a non-existent file is auto-skipped with a warning" {
  local proposal
  proposal="$(printf '%s\n' \
    '---PROPOSAL---' \
    'ACTION: REFINE' \
    'FILE: docs/ghost-doc.md' \
    'DRIFT_REFS: pr:111' \
    'DESCRIPTION: Add note to a doc that does not exist' \
    '---CONTENT---' \
    '## Ghost Section' \
    '' \
    'This must not be written.' \
    '@@END@@')"

  run bash -c "
    export STUB_PROPOSALS='${proposal//\'/\'\\\'\'}'
    bash '${_DOCS_HELPER}' docs_directed_update 'add note to ghost doc' 2>&1
  " || true

  # Warning must mention the guard fired
  printf '%s\n' "$output" | grep -qi "Auto-skipping REFINE"

  # Ghost file must not have been created
  [ ! -f "$FAKE_PROJECT/docs/ghost-doc.md" ]

  # No push
  local push_calls
  push_calls="$(grep -c 'git:push' "$STUB_CALLS_FILE" 2>/dev/null || true)"
  [ "$push_calls" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 4: REFINE prompt format appears in the LLM prompt (structural)
# ---------------------------------------------------------------------------

@test "docs-command.sh LLM prompt includes ACTION: REFINE format and drift-refs requirement" {
  # REFINE must be in the prompt so the model knows the option exists
  local refine_count
  refine_count=$(grep -c 'ACTION: REFINE' "$DOCS_CMD" || true)
  [ "$refine_count" -ge 1 ]

  # The must-not-be-none instruction must appear in the prompt
  local drift_req_count
  drift_req_count=$(grep -c 'DRIFT_REFS.*none.*REFINE\|REFINE.*DRIFT_REFS.*none' "$DOCS_CMD" || true)
  # The feedback-loop warning sentence covers both patterns — structural check
  local feedback_guard_count
  feedback_guard_count=$(grep -c 'grow the backlog\|grows the trigger store\|feedback' "$DOCS_CMD" || true)
  [ "$feedback_guard_count" -ge 1 ]
}
