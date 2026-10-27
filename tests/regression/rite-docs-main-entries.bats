#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh::_docs_apply_approved
BATS_TEST_TIMEOUT=30
#
# Tests for the _docs_apply_approved happy path (#1519):
# ensure that an approved EDIT proposal commits the change, pushes the docs
# branch, and opens a PR — the highest-consequence path previously untested.
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
  # Resolve REAL_GIT before STUB_BIN enters PATH to avoid infinite exec-loop
  REAL_GIT="$(command -v git)"
  export STUB_BIN STUB_CALLS_FILE REAL_GIT

  # git wrapper: pass through everything except push and fetch
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

  # Write helper script used by run-based tests
  _DOCS_HELPER="$(mktemp)"
  cat > "$_DOCS_HELPER" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail

export RITE_LIB_DIR="${PROJECT_ROOT}/lib"
export RITE_PROJECT_ROOT="${FAKE_PROJECT}"
export RITE_DATA_DIR=".rite"
export RITE_STATE_DIR="${FAKE_PROJECT}/.rite/state"
# Pin target branch so batch-env RITE_TARGET_BRANCH cannot leak in
export RITE_TARGET_BRANCH=main

export PATH="${STUB_BIN}:${PATH}"
export STUB_CALLS_FILE

source "${DOCS_CMD}"

# Re-define stubs AFTER source (env-guarded libs overwrite pre-source stubs)
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs sentinel guard; gh_safe stub must be post-source because gh-retry.sh uses _RITE_GH_RETRY_LOADED env guard which overwrites pre-source definitions
load_provider()                    { return 0; }
provider_run_prompt_with_timeout() { printf '%s\n' "${STUB_PROPOSALS:-NO_PROPOSALS_NEEDED}"; }
provider_resolve_model()           { printf 'claude-sonnet-4-6\n'; }
docs_map_ensure()                  { [ -s "${FAKE_PROJECT}/.rite/state/docs-map.tsv" ] || printf 'docs/test-doc.md\n' > "${FAKE_PROJECT}/.rite/state/docs-map.tsv"; return 0; }
docs_map_path()                    { printf '%s/.rite/state/docs-map.tsv\n' "${FAKE_PROJECT}"; }
gh_safe()                          { printf 'gh_safe:%s\n' "$*" >> "${STUB_CALLS_FILE}"; return 0; }

# Create origin/main ref pointing at HEAD so _docs_apply_approved can fork a
# worktree from origin/main. Done immediately before dispatch so any commits
# added by the test are included.
git -C "${FAKE_PROJECT}" update-ref refs/remotes/origin/main HEAD

# Invoke the requested function with all remaining args
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
# Approval path: EDIT proposal → commit + push + PR created (#1519)
# ---------------------------------------------------------------------------

@test "_docs_apply_approved with EDIT proposal commits change, pushes branch, and creates PR" {
  # The TOCTOU guard test (criterion 14 in rite-docs-directed-update.bats) covers
  # the skip path (CREATE for an existing file).  This test covers the happy
  # path: an EDIT proposal for an existing file should be committed to a docs
  # branch, pushed to origin, and a PR should be opened via gh_safe.
  #
  # This directly tests _docs_apply_approved arg order and proposal-file format
  # compatibility — the call site in _docs_update_engine passes five positional
  # args (APPROVED_DIR DRIFT_PATH INSTRUCTIONS MODE TARGET_BRANCH); if arg order
  # drifted, the push/PR assertions below would catch it.

  local appr_dir
  appr_dir="$(mktemp -d)"

  # Approved EDIT proposal: docs/test-doc.md already exists in the fake project
  # (committed in setup) so the TOCTOU guard will NOT fire.
  printf '%s\n' \
    'ACTION: EDIT' \
    'FILE: docs/test-doc.md' \
    'DRIFT_REFS: none' \
    'DESCRIPTION: Update test-doc for approval-path test' \
    '---CONTENT---' \
    '# Test Doc' \
    '' \
    'Content updated by the approval-path test.' \
    > "$appr_dir/approved_1.txt"

  run bash -c "
    bash '${_DOCS_HELPER}' _docs_apply_approved '${appr_dir}' '' 'approval path test' directed main 2>&1
  "
  rm -rf "$appr_dir"

  [ "$status" -eq 0 ]

  # Push must have been called exactly once
  local push_calls
  push_calls="$(grep -c 'git:push' "$STUB_CALLS_FILE" 2>/dev/null || true)"
  [ "$push_calls" -eq 1 ]

  # PR creation must have been attempted via gh_safe pr create
  local pr_calls
  pr_calls="$(grep -c 'gh_safe:pr create' "$STUB_CALLS_FILE" 2>/dev/null || true)"
  [ "$pr_calls" -eq 1 ]
}
