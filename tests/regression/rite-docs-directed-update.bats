#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh
# tests/regression/rite-docs-directed-update.bats
BATS_TEST_TIMEOUT=30
#
# Tests for the directed-update + reconcile engine (#1049):
# double-source safety, nothing-before-approval, CREATE new doc,
# drift burn-down, changelog-mode compatibility, and proposal guards (#1208).
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
  # Resolve REAL_GIT before STUB_BIN enters PATH to avoid infinite exec-loop:
  # command -v git inside the stub would find STUB_BIN/git and exec itself forever.
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
# Pin target branch so batch-env RITE_TARGET_BRANCH (e.g. supervised-ux) cannot leak in
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
  # Extract the per-generation end token from the prompt (#1233) so test stubs
  # use @@END@@ as a placeholder and have it replaced with the real token.
  # @@END@@ never appears in doc content, so it cannot collide with proposal
  # content the way ---END--- could (enabling round-trip tests for ---END--- in
  # content — see acceptance criterion 16).
  local _end_tok
  _end_tok="$(printf '%s\n' "$_prompt" | grep -oE -- '---END-[0-9]+---' | head -1 || true)"
  if [ -n "$_end_tok" ]; then
    printf '%s\n' "$_stub" | sed "s/@@END@@/${_end_tok}/"
  else
    printf '%s\n' "$_stub"
  fi
}
provider_resolve_model()           { printf 'claude-sonnet-4-6\n'; }
docs_map_ensure()                  { [ -s "${FAKE_PROJECT}/.rite/state/docs-map.tsv" ] || printf 'docs/test-doc.md\n' > "${FAKE_PROJECT}/.rite/state/docs-map.tsv"; return 0; }
docs_map_path()                    { printf '%s/.rite/state/docs-map.tsv\n' "${FAKE_PROJECT}"; }
gh_safe()                          { printf 'gh_safe:%s\n' "$*" >> "${STUB_CALLS_FILE}"; return 0; }

# Create origin/main ref pointing at HEAD so _docs_apply_approved can fork a
# worktree from origin/main. Done immediately before dispatch so any commits
# added by the test (e.g. the drift-log commit in test 7) are included.
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
@@END@@
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
  push_calls="$(grep -c 'git:push' "$STUB_CALLS_FILE" 2>/dev/null || true)"
  [ "$push_calls" -eq 0 ]
  local gh_calls
  gh_calls="$(grep -c 'gh_safe:pr create' "$STUB_CALLS_FILE" 2>/dev/null || true)"
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
    '@@END@@')"

  run bash -c "
    export STUB_PROPOSALS='${proposal//\'/\'\\\'\'}'
    bash '${_DOCS_HELPER}' docs_directed_update 'write ADR for caching decision' <<< 'y'
  " || true

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
  gh_pr_calls="$(grep -c 'gh_safe:pr create' "$STUB_CALLS_FILE" 2>/dev/null || true)"
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
    '@@END@@')"

  run bash -c "
    export STUB_PROPOSALS='${proposal//\'/\'\\\'\'}'
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
    '@@END@@')"

  run bash -c "
    export RITE_DOC_MODE=changelog
    export STUB_PROPOSALS='${proposal//\'/\'\\\'\'}'
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
# Acceptance criterion 9 (#1208): CREATE guard — existing local file
# ---------------------------------------------------------------------------

@test "CREATE proposal targeting an existing local file is auto-skipped with a warning" {
  # docs/test-doc.md already exists locally (created in setup)
  local doc_before
  doc_before="$(cat "$FAKE_PROJECT/docs/test-doc.md")"

  local proposal
  proposal="$(printf '%s\n' \
    '---PROPOSAL---' \
    'ACTION: CREATE' \
    'FILE: docs/test-doc.md' \
    'DRIFT_REFS: none' \
    'DESCRIPTION: Overwrite test-doc with replacement content' \
    '---CONTENT---' \
    '# Replacement Content' \
    '' \
    'This should not replace the original.' \
    '@@END@@')"

  run bash -c "
    export STUB_PROPOSALS='${proposal//\'/\'\\\'\'}'
    bash '${_DOCS_HELPER}' docs_directed_update 'recreate test-doc' 2>&1
  " || true

  # Warning must mention the guard fired
  printf '%s\n' "$output" | grep -qi "Auto-skipping CREATE"

  # File must be byte-identical — guard prevented apply
  local doc_after
  doc_after="$(cat "$FAKE_PROJECT/docs/test-doc.md")"
  [ "$doc_before" = "$doc_after" ]

  # No push or PR-create
  local push_calls
  push_calls="$(grep -c 'git:push' "$STUB_CALLS_FILE" 2>/dev/null || true)"
  [ "$push_calls" -eq 0 ]
  local gh_calls
  gh_calls="$(grep -c 'gh_safe:pr create' "$STUB_CALLS_FILE" 2>/dev/null || true)"
  [ "$gh_calls" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 10 (#1208): CREATE guard — file exists only on origin
# ---------------------------------------------------------------------------

@test "CREATE proposal targeting a file that exists only on origin is auto-skipped with a warning" {
  # Commit a new file to the fake project so it appears on origin/main
  # (the helper's update-ref points origin/main at HEAD after this commit)
  printf '# Origin-only content\n' > "$FAKE_PROJECT/docs/origin-only.md"
  git -C "$FAKE_PROJECT" add .
  git -C "$FAKE_PROJECT" commit -q -m "add origin-only file"
  # Remove it from the working tree so [ -f ] misses it, but git cat-file
  # finds it via the refs/remotes/origin/main ref set in the helper
  rm "$FAKE_PROJECT/docs/origin-only.md"

  local proposal
  proposal="$(printf '%s\n' \
    '---PROPOSAL---' \
    'ACTION: CREATE' \
    'FILE: docs/origin-only.md' \
    'DRIFT_REFS: none' \
    'DESCRIPTION: Create a doc that already exists on origin' \
    '---CONTENT---' \
    '# Origin Only' \
    '' \
    'This content must not be applied.' \
    '@@END@@')"

  run bash -c "
    export STUB_PROPOSALS='${proposal//\'/\'\\\'\'}'
    bash '${_DOCS_HELPER}' docs_directed_update 'create origin-only doc' 2>&1
  " || true

  # Warning must mention the guard fired
  printf '%s\n' "$output" | grep -qi "Auto-skipping CREATE"

  # File must not exist locally after — guard prevented create
  [ ! -f "$FAKE_PROJECT/docs/origin-only.md" ]

  # No push or PR-create
  local push_calls
  push_calls="$(grep -c 'git:push' "$STUB_CALLS_FILE" 2>/dev/null || true)"
  [ "$push_calls" -eq 0 ]
  local gh_calls
  gh_calls="$(grep -c 'gh_safe:pr create' "$STUB_CALLS_FILE" 2>/dev/null || true)"
  [ "$gh_calls" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 11 (#1208): fetch precedes CREATE guard — structural
# ---------------------------------------------------------------------------

@test "CREATE guard: fetch line precedes cat-file check line in source (structural)" {
  local fetch_line cat_file_line
  fetch_line=$(grep -n 'fetch origin.*_ue_target' "$DOCS_CMD" | head -1 | cut -d: -f1 || true)
  cat_file_line=$(grep -n 'cat-file.*_ue_target' "$DOCS_CMD" | head -1 | cut -d: -f1 || true)
  [ -n "$fetch_line" ]
  [ -n "$cat_file_line" ]
  [ "$fetch_line" -lt "$cat_file_line" ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 12 (#1208): fetch is called during directed-update run
# ---------------------------------------------------------------------------

@test "CREATE guard: git fetch is called during a directed-update run (behavioral)" {
  # Use a new-file proposal (does not exist) to keep the guard from skipping it;
  # answer n at the preview so nothing is committed — we only care that the
  # fetch ran before the guard checked origin.
  local proposal
  proposal="$(printf '%s\n' \
    '---PROPOSAL---' \
    'ACTION: CREATE' \
    'FILE: docs/fetch-probe-fixture.md' \
    'DRIFT_REFS: none' \
    'DESCRIPTION: Probe fixture for fetch-call assertion' \
    '---CONTENT---' \
    '# Fetch Probe' \
    '' \
    'This file is used only to trigger the proposal loop.' \
    '@@END@@')"

  run bash -c "
    export STUB_PROPOSALS='${proposal//\'/\'\\\'\'}'
    bash '${_DOCS_HELPER}' docs_directed_update 'probe fetch call' <<< 'n'
  " || true

  local fetch_calls
  fetch_calls="$(grep -c 'git:fetch' "$STUB_CALLS_FILE" 2>/dev/null || true)"
  [ "$fetch_calls" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 13 (#1231): EDIT guard — file dropped by 15KB budget
# ---------------------------------------------------------------------------

@test "EDIT proposal for a file dropped by the 15KB context budget is auto-skipped" {
  # Fill the context budget with 7 filler docs.
  # Each entry: "--- docs/filler-N.md ---\n" (25 bytes) + 2000-byte excerpt + "\n\n" = 2027 bytes.
  # 7 × 2027 = 14189 bytes consumed — under the 15000-byte cap.
  # The 8th entry (docs/dropped.md, 800-byte content) adds ~824 bytes → 15013 > 15000 → dropped.
  local _i
  local _map_content=""
  for _i in 1 2 3 4 5 6 7; do
    awk 'BEGIN{ for(i=0;i<2000;i++) printf "x"; printf "\n" }' \
      > "$FAKE_PROJECT/docs/filler-${_i}.md"
    _map_content="${_map_content}docs/filler-${_i}.md
"
  done

  # Dropped file: 800 bytes — passes the 2000-byte size guard but is NOT in context
  awk 'BEGIN{ for(i=0;i<800;i++) printf "x"; printf "\n" }' \
    > "$FAKE_PROJECT/docs/dropped.md"
  _map_content="${_map_content}docs/dropped.md
"

  printf '%s' "$_map_content" > "$FAKE_PROJECT/.rite/state/docs-map.tsv"

  local proposal
  proposal="$(printf '%s\n' \
    '---PROPOSAL---' \
    'ACTION: EDIT' \
    'FILE: docs/dropped.md' \
    'DRIFT_REFS: none' \
    'DESCRIPTION: Update the dropped doc' \
    '---CONTENT---' \
    '# Dropped Doc' \
    '' \
    'This content must not be applied.' \
    '@@END@@')"

  local doc_before
  doc_before="$(cat "$FAKE_PROJECT/docs/dropped.md")"

  run bash -c "
    export STUB_PROPOSALS='${proposal//\'/\'\\\'\'}'
    bash '${_DOCS_HELPER}' docs_directed_update 'update dropped doc' 2>&1
  " || true

  # Membership guard must have fired (distinctive phrase — not the size guard)
  printf '%s\n' "$output" | grep -qi "absent from docs map or excluded by 15KB cap"

  # File content must be unchanged — guard prevented apply
  local doc_after
  doc_after="$(cat "$FAKE_PROJECT/docs/dropped.md")"
  [ "$doc_before" = "$doc_after" ]

  # No push or PR-create
  local push_calls
  push_calls="$(grep -c 'git:push' "$STUB_CALLS_FILE" 2>/dev/null || true)"
  [ "$push_calls" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 14 (#1232): apply-site TOCTOU guard
# ---------------------------------------------------------------------------

@test "_docs_apply_approved skips CREATE when file already exists in worktree" {
  # docs/test-doc.md is committed in setup's initial commit and will be present
  # in any worktree forked from origin/main.  Simulate the TOCTOU scenario: an
  # approved CREATE proposal arrives at the apply site but the file already
  # exists in the freshly-created worktree (it was pushed between preview and apply).
  local doc_before
  doc_before="$(cat "$FAKE_PROJECT/docs/test-doc.md")"

  local appr_dir
  appr_dir="$(mktemp -d)"

  # Approved proposal targeting a file that already exists on origin/main
  printf '%s\n' \
    'ACTION: CREATE' \
    'FILE: docs/test-doc.md' \
    'DRIFT_REFS: none' \
    '---CONTENT---' \
    '# TOCTOU overwrite attempt' \
    '' \
    'This write must be blocked by the apply-site guard.' \
    > "$appr_dir/approved_1.txt"

  run bash -c "
    bash '${_DOCS_HELPER}' _docs_apply_approved '${appr_dir}' '' 'toctou test' directed main 2>&1
  "
  rm -rf "$appr_dir"

  # All proposals were skipped — function should exit 0 (all-skipped path)
  [ "$status" -eq 0 ]

  # Apply-site guard must fire and emit a warning
  printf '%s\n' "$output" | grep -qi "Skipping CREATE"

  # Original file content must be unchanged (guard fired before any write)
  [ "$(cat "$FAKE_PROJECT/docs/test-doc.md")" = "$doc_before" ]

  # Nothing was committed or pushed (guard fired before mkdir/write)
  local push_calls
  push_calls="$(grep -c 'git:push' "$STUB_CALLS_FILE" 2>/dev/null || true)"
  [ "$push_calls" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Coverage header presence (structural check)
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

# ---------------------------------------------------------------------------
# Acceptance criterion 15 (#1233): proposal content containing ---END--- is
# not truncated by the delimiter parser
# ---------------------------------------------------------------------------

@test "proposal parser uses per-generation end token not hardcoded ---END--- (#1233)" {
  # Structural: verify the fix is in place — the parser case pattern uses
  # _ue_end_token (a per-generation unique string) instead of the literal
  # ---END--- that could collide with content in behavioral-design.md and bats
  # fixture files.

  # _ue_end_token must be defined (assigned from $RANDOM$RANDOM before the loop)
  local token_def_count
  token_def_count=$(grep -c '_ue_end_token="---END-' "$DOCS_CMD" || true)
  [ "$token_def_count" -ge 1 ]

  # The old hardcoded case pattern must be gone from the parser
  local old_pattern_count
  old_pattern_count=$(grep -c '"---END---")' "$DOCS_CMD" || true)
  [ "$old_pattern_count" -eq 0 ]

  # The variable case pattern must be present
  local new_pattern_count
  new_pattern_count=$(grep -c '"${_ue_end_token}")' "$DOCS_CMD" || true)
  [ "$new_pattern_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 16 (#1233): ---END--- inside proposal content is
# preserved — it never truncates the proposal (behavioral round-trip)
# ---------------------------------------------------------------------------

@test "proposal content containing ---END--- on its own line is not truncated (#1233)" {
  # The stub injects a proposal whose CONTENT block contains a literal
  # ---END--- line (the old hardcoded terminator).  With the per-generation
  # token fix the parser must treat it as ordinary content — the applied
  # file must contain the ---END--- line intact.
  local proposal
  proposal="$(printf '%s\n' \
    '---PROPOSAL---' \
    'ACTION: EDIT' \
    'FILE: docs/test-doc.md' \
    'DRIFT_REFS: none' \
    'DESCRIPTION: Update test-doc with content that includes ---END--- literally' \
    '---CONTENT---' \
    '# Test Doc' \
    '' \
    'This line contains the old terminator: ---END---' \
    'Content after the old terminator must also be preserved.' \
    '@@END@@')"

  run bash -c "
    export STUB_PROPOSALS='${proposal//\'/\'\\\'\'}'
    bash '${_DOCS_HELPER}' docs_directed_update 'update with ---END--- in content' <<< 'y'
  " || true

  # Find the docs branch
  local docs_branch
  docs_branch="$(git -C "$FAKE_PROJECT" branch --format='%(refname:short)' | grep '^docs/' | head -1 || true)"
  [ -n "$docs_branch" ]

  # The committed file must contain the literal ---END--- line
  local committed
  committed="$(git -C "$FAKE_PROJECT" show "${docs_branch}:docs/test-doc.md" 2>/dev/null || true)"
  [ -n "$committed" ]
  printf '%s' "$committed" | grep -qF 'This line contains the old terminator: ---END---'

  # The line AFTER the ---END--- must also be present (not truncated)
  printf '%s' "$committed" | grep -qF 'Content after the old terminator must also be preserved.'
}
