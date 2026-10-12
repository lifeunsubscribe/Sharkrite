#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh
# tests/regression/rite-docs-directed-update.bats
#
# Tests for the directed-update + reconcile engine (#1049):
# double-source safety, nothing-before-approval, CREATE new doc,
# drift burn-down, and changelog-mode compatibility.
#
# All LLM provider calls are stubbed via post-source function overrides.
# Stub git push/fetch via PATH-priority stub bin; gh_safe overridden after source.

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DOCS_CMD="$PROJECT_ROOT/lib/core/docs-command.sh"
  export PROJECT_ROOT DOCS_CMD

  # Fake project: real git repo with an initial commit so worktrees work
  FAKE_PROJECT="$(mktemp -d)"
  mkdir -p "$FAKE_PROJECT/.rite/state" "$FAKE_PROJECT/docs"
  printf '# Test Doc\n\nOriginal content.\n' > "$FAKE_PROJECT/docs/test-doc.md"
  git -C "$FAKE_PROJECT" init -q
  git -C "$FAKE_PROJECT" config user.email "test@sharkrite.local"
  git -C "$FAKE_PROJECT" config user.name "Test"
  git -C "$FAKE_PROJECT" add .
  git -C "$FAKE_PROJECT" commit -q -m "init"
  export FAKE_PROJECT

  # Stub bin: intercepts git push/fetch without hitting the network
  STUB_BIN="$(mktemp -d)"
  STUB_CALLS_FILE="$(mktemp)"
  export STUB_BIN STUB_CALLS_FILE

  # git wrapper: pass through everything except push and fetch
  cat > "$STUB_BIN/git" << 'GITSTUB'
#!/bin/bash
for _a in "$@"; do
  case "$_a" in
    push)  printf 'git:push\n' >> "${STUB_CALLS_FILE}"; exit 0 ;;
    fetch) printf 'git:fetch\n' >> "${STUB_CALLS_FILE}"; exit 0 ;;
  esac
done
exec "$(command -v git)" "$@"
GITSTUB
  chmod +x "$STUB_BIN/git"

  # Write helper script used by run-based tests
  _DOCS_HELPER="$(mktemp)"
  cat > "$_DOCS_HELPER" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail

export RITE_LIB_DIR="${PROJECT_ROOT}/lib"
export RITE_PROJECT_ROOT="${FAKE_PROJECT}"
export RITE_DATA_DIR=".rite"
export RITE_STATE_DIR="${FAKE_PROJECT}/.rite/state"

export PATH="${STUB_BIN}:${PATH}"
export STUB_CALLS_FILE

source "${DOCS_CMD}"

# Re-define stubs AFTER source (env-guarded libs overwrite pre-source stubs)
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs sentinel guard; gh_safe stub must be post-source because gh-retry.sh uses _RITE_GH_RETRY_LOADED env guard which overwrites pre-source definitions
load_provider()                    { return 0; }
provider_run_prompt_with_timeout() { printf '%s\n' "${STUB_PROPOSALS:-NO_PROPOSALS_NEEDED}"; }
provider_resolve_model()           { printf 'claude-sonnet-4-6\n'; }
docs_map_ensure()                  { touch "${FAKE_PROJECT}/.rite/state/docs-map.tsv"; return 0; }
docs_map_path()                    { printf '%s/.rite/state/docs-map.tsv\n' "${FAKE_PROJECT}"; }
gh_safe()                          { printf 'gh_safe:%s\n' "$*" >> "${STUB_CALLS_FILE}"; return 0; }

# Invoke the requested function with all remaining args
"$@"
HELPER_EOF
  chmod +x "$_DOCS_HELPER"
  export _DOCS_HELPER
}

teardown() {
  rm -rf "${FAKE_PROJECT:-}" "${STUB_BIN:-}" "${_DOCS_HELPER:-}"
  rm -f "${STUB_CALLS_FILE:-}"
  # Prune any orphaned worktrees the test may have created
  git -C "${FAKE_PROJECT:-/dev/null}" worktree prune 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Acceptance criterion 1: double-source safety + function existence
# ---------------------------------------------------------------------------

@test "docs_directed_update and docs_reconcile_drift are declared after double source" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$PROJECT_ROOT/lib'
    export RITE_PROJECT_ROOT='$FAKE_PROJECT'
    export RITE_DATA_DIR='.rite'
    source '$PROJECT_ROOT/lib/core/docs-command.sh'
    source '$PROJECT_ROOT/lib/core/docs-command.sh'
    declare -f docs_directed_update docs_reconcile_drift >/dev/null && echo OK
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 2: model discipline
# ---------------------------------------------------------------------------

@test "docs-command.sh calls provider_resolve_model doc_assessment and has no model vars" {
  local doc_assess_count
  doc_assess_count=$(grep -c 'provider_resolve_model doc_assessment' "$DOCS_CMD" || true)
  [ "$doc_assess_count" -ge 1 ]

  # No direct RITE_*_MODEL reads
  local model_var_count
  model_var_count=$(grep -cE '\$\{?RITE_[A-Z_]+_MODEL' "$DOCS_CMD" || true)
  [ "$model_var_count" -eq 0 ]

  # No direct claude_provider_* calls (Rule 32)
  local direct_provider_count
  direct_provider_count=$(grep -c 'claude_provider_' "$DOCS_CMD" || true)
  [ "$direct_provider_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 3: integration-aware base (≥2 sites)
# ---------------------------------------------------------------------------

@test "docs-command.sh references RITE_TARGET_BRANCH:-main at least twice" {
  local count
  count=$(grep -c 'RITE_TARGET_BRANCH:-main' "$DOCS_CMD" || true)
  [ "$count" -ge 2 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 4: reconcile wired (≥2 occurrences)
# ---------------------------------------------------------------------------

@test "docs_reconcile_drift appears at definition plus at least one call site" {
  local count
  count=$(grep -c 'docs_reconcile_drift' "$DOCS_CMD" || true)
  [ "$count" -ge 2 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 5: nothing written before approval
# ---------------------------------------------------------------------------

@test "answering n at the preview leaves the working tree and drift log unchanged" {
  # Drift log with one entry (should not be modified on 'n')
  local drift_log="$FAKE_PROJECT/docs/sharkrite-drift-log.md"
  cat > "$drift_log" << 'DRIFT_EOF'
# Sharkrite Drift Log

<!-- sharkrite-doc-drift pr:999 issue:1 recorded:2026-01-01T00:00:00Z -->
**Changed files**: lib/core/foo.sh
**Implicated docs**:
- docs/test-doc.md — "Original content"
**Suspected inaccuracy**: foo changed
<!-- /sharkrite-doc-drift -->
DRIFT_EOF
  git -C "$FAKE_PROJECT" add "$drift_log"
  git -C "$FAKE_PROJECT" commit -q -m "add drift log"

  local drift_before
  drift_before="$(cat "$drift_log")"
  local doc_before
  doc_before="$(cat "$FAKE_PROJECT/docs/test-doc.md")"

  # Stub: provider returns one EDIT proposal for docs/test-doc.md
  local proposal
  proposal="$(cat << 'PROP_EOF'
---PROPOSAL---
ACTION: EDIT
FILE: docs/test-doc.md
DRIFT_REFS: pr:999
DESCRIPTION: Update to reflect foo change
---CONTENT---
# Test Doc

Updated content for foo change.
---END---
PROP_EOF
)"

  # Answer 'n' at the preview prompt → nothing applied
  run bash -c "
    export STUB_PROPOSALS='${proposal//\'/\'\\\'\'}'
    bash '${_DOCS_HELPER}' docs_directed_update 'update docs for foo' <<< 'n'
  "
  # Exit code from docs_directed_update may be 0 (no changes approved is normal)

  # Working tree must be byte-identical
  local drift_after
  drift_after="$(cat "$drift_log")"
  local doc_after
  doc_after="$(cat "$FAKE_PROJECT/docs/test-doc.md")"

  [ "$drift_before" = "$drift_after" ]
  [ "$doc_before" = "$doc_after" ]

  # No git push or gh_safe calls
  local push_calls
  push_calls="$(grep -c 'git:push' "$STUB_CALLS_FILE" 2>/dev/null || echo 0)"
  [ "$push_calls" -eq 0 ]
  local gh_calls
  gh_calls="$(grep -c 'gh_safe:pr create' "$STUB_CALLS_FILE" 2>/dev/null || echo 0)"
  [ "$gh_calls" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 6: directed update can CREATE a new doc
# ---------------------------------------------------------------------------

@test "answering y creates the new file on the docs branch" {
  local proposal
  # Use printf to build the proposal without heredoc-in-a-string issues
  proposal="$(printf '%s\n' \
    '---PROPOSAL---' \
    'ACTION: CREATE' \
    'FILE: docs/adr-999-fixture.md' \
    'DRIFT_REFS: none' \
    'DESCRIPTION: New ADR for the caching decision' \
    '---CONTENT---' \
    '# ADR 999 — Caching Strategy' \
    '' \
    'This is a fixture ADR created by the test.' \
    '---END---')"

  run bash -c "
    export STUB_PROPOSALS=\"\$(printf '%s' '${proposal//\'/\'\\\'\'}\')\"
    bash '${_DOCS_HELPER}' docs_directed_update 'write ADR for caching decision' <<< 'y'
  " || true  # allow non-zero (e.g. push stub returns 0 but the subshell may still propagate)

  # Find the docs branch created by the engine
  local docs_branch
  docs_branch="$(git -C "$FAKE_PROJECT" branch --format='%(refname:short)' | grep '^docs/' | head -1 || true)"
  [ -n "$docs_branch" ]

  # The ADR fixture must be committed on that branch
  local file_content
  file_content="$(git -C "$FAKE_PROJECT" show "${docs_branch}:docs/adr-999-fixture.md" 2>/dev/null || true)"
  [ -n "$file_content" ]
  printf '%s' "$file_content" | grep -q "ADR 999"

  # gh_safe pr create must have been called
  local gh_pr_calls
  gh_pr_calls="$(grep -c 'gh_safe:pr create' "$STUB_CALLS_FILE" 2>/dev/null || echo 0)"
  [ "$gh_pr_calls" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 7: burn-down semantics
# ---------------------------------------------------------------------------

@test "approving a proposal covering pr:888 removes that entry from the drift log" {
  local drift_log="$FAKE_PROJECT/docs/sharkrite-drift-log.md"
  cat > "$drift_log" << 'DRIFT_EOF'
# Sharkrite Drift Log

<!-- sharkrite-doc-drift pr:888 issue:2 recorded:2026-01-01T00:00:00Z -->
**Changed files**: lib/core/bar.sh
**Implicated docs**:
- docs/test-doc.md — "Original content"
**Suspected inaccuracy**: bar changed
<!-- /sharkrite-doc-drift -->
DRIFT_EOF
  git -C "$FAKE_PROJECT" add "$drift_log"
  git -C "$FAKE_PROJECT" commit -q -m "add drift entry pr:888"

  local proposal
  proposal="$(printf '%s\n' \
    '---PROPOSAL---' \
    'ACTION: EDIT' \
    'FILE: docs/test-doc.md' \
    'DRIFT_REFS: pr:888' \
    'DESCRIPTION: Update test-doc to reflect bar change' \
    '---CONTENT---' \
    '# Test Doc' \
    '' \
    'Updated after bar change.' \
    '---END---')"

  run bash -c "
    export STUB_PROPOSALS=\"\$(printf '%s' '${proposal//\'/\'\\\'\'}\')\"
    bash '${_DOCS_HELPER}' docs_directed_update 'update docs for bar' <<< 'y'
  " || true

  # Find the docs branch
  local docs_branch
  docs_branch="$(git -C "$FAKE_PROJECT" branch --format='%(refname:short)' | grep '^docs/' | head -1 || true)"
  [ -n "$docs_branch" ]

  # The drift entry for pr:888 must NOT appear in the committed drift log
  local committed_drift
  committed_drift="$(git -C "$FAKE_PROJECT" show "${docs_branch}:docs/sharkrite-drift-log.md" 2>/dev/null || echo "")"
  if [ -n "$committed_drift" ]; then
    # If the file still exists, pr:888 entry must be gone
    ! printf '%s' "$committed_drift" | grep -q 'pr:888'
  fi
  # If the file was deleted (last entry drained), that's also correct
}

# ---------------------------------------------------------------------------
# Acceptance criterion 8: works in changelog mode
# ---------------------------------------------------------------------------

@test "docs_directed_update applies after approval in changelog mode (no consent gate check)" {
  # No doc-sync.md → changelog mode; should not bail before approval
  export RITE_DOC_MODE=changelog

  local proposal
  proposal="$(printf '%s\n' \
    '---PROPOSAL---' \
    'ACTION: CREATE' \
    'FILE: docs/adr-998-changelog-mode.md' \
    'DRIFT_REFS: none' \
    'DESCRIPTION: ADR created from changelog mode' \
    '---CONTENT---' \
    '# ADR 998 — Changelog Mode Test' \
    '' \
    'Created while in changelog mode.' \
    '---END---')"

  run bash -c "
    export RITE_DOC_MODE=changelog
    export STUB_PROPOSALS=\"\$(printf '%s' '${proposal//\'/\'\\\'\'}\')\"
    bash '${_DOCS_HELPER}' docs_directed_update 'create ADR for changelog mode test' <<< 'y'
  " || true

  # File must appear on a docs branch (engine ran despite no doc-sync.md)
  local docs_branch
  docs_branch="$(git -C "$FAKE_PROJECT" branch --format='%(refname:short)' | grep '^docs/' | head -1 || true)"
  [ -n "$docs_branch" ]

  local file_content
  file_content="$(git -C "$FAKE_PROJECT" show "${docs_branch}:docs/adr-998-changelog-mode.md" 2>/dev/null || true)"
  [ -n "$file_content" ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 9: coverage header presence (structural check)
# ---------------------------------------------------------------------------

@test "coverage header is present on this bats file" {
  local count
  count=$(head -2 "$BATS_TEST_FILENAME" | grep -c 'sharkrite-test-covers: lib/core/docs-command.sh' || true)
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# No auto-merge guard
# ---------------------------------------------------------------------------

@test "docs-command.sh never calls pr merge (no auto-merge)" {
  local count
  count=$(grep -c 'pr merge' "$DOCS_CMD" || true)
  [ "$count" -eq 0 ]
}
