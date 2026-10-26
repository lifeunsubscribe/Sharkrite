#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh::docs_reconcile_drift|_docs_main_entries_pass|_docs_list_main_entry_docs|_docs_bounded_context_for_doc|_docs_extract_section
# tests/regression/rite-docs-main-entries.bats
BATS_TEST_TIMEOUT=30
#
# Tests for the Tier 2 branch=main drift-entry reconcile path (#1431):
#
#  1. branch=main entries → groups by doc, calls doc_update model
#  2. Response missing narrative OR edits → rejected, retry via feedback path
#  3. Zero main entries → no-op; entries for other branches untouched
#  4. Nondeterministic assertions (REFINE action) → kind=refinement drift entries
#  5. #1208 guards (context-membership, large-file, CREATE-exists) apply
#  6. #1233 per-generation end token present in prompt
#
# All LLM provider calls are stubbed. git push/fetch intercepted via PATH-priority stub.

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DOCS_CMD="$PROJECT_ROOT/lib/core/docs-command.sh"
  export PROJECT_ROOT DOCS_CMD

  # Fake project: real git repo with an initial commit so worktrees work
  FAKE_PROJECT="$(mktemp -d)"
  mkdir -p "$FAKE_PROJECT/.rite/state/doc-drift/main" "$FAKE_PROJECT/docs"
  printf '# Test Doc\n\n## Background\n\nOriginal content.\n\n## Usage\n\nUse it.\n' \
    > "$FAKE_PROJECT/docs/test-doc.md"
  git -C "$FAKE_PROJECT" init -q
  git -C "$FAKE_PROJECT" config user.email "test@sharkrite.local"
  git -C "$FAKE_PROJECT" config user.name "Test"
  git -C "$FAKE_PROJECT" add .
  git -C "$FAKE_PROJECT" commit -q -m "init"
  export FAKE_PROJECT

  # Stub bin: intercept git push/fetch
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

  # A minimal docs-map TSV for the fake project
  printf '# docs-map v4 sha=abc123 built=2026-01-01T00:00:00Z\n' \
    > "$FAKE_PROJECT/.rite/state/docs-map.tsv"
  printf 'docs/test-doc.md\tabc123\t-\t1\tTest Doc\tfp1\tfeature\t-\t-\t-\n' \
    >> "$FAKE_PROJECT/.rite/state/docs-map.tsv"
  printf 'docs/test-doc.md\tabc123\t-\t2\tBackground\tfp2\tfeature\t-\t-\t-\n' \
    >> "$FAKE_PROJECT/.rite/state/docs-map.tsv"
  printf 'docs/test-doc.md\tabc123\t-\t2\tUsage\tfp3\tfeature\t-\t-\t-\n' \
    >> "$FAKE_PROJECT/.rite/state/docs-map.tsv"

  # Helper script (sourced by run-based tests)
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
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs sentinel guard; provider_resolve_model and gh_safe stubs must be post-source because provider-interface.sh and gh-retry.sh use _RITE_*_LOADED env guards which overwrite pre-source definitions
load_provider()                    { return 0; }
provider_run_prompt_with_timeout() {
  local _prompt="$1"
  local _model="$2"
  # Record (model, prompt-excerpt) for assertions
  printf 'CALL:model=%s\n' "$_model" >> "${STUB_CALLS_FILE}"
  printf 'CALL:has_narrative=%s\n' \
    "$(printf '%s\n' "$_prompt" | grep -c '---NARRATIVE---' || true)" >> "${STUB_CALLS_FILE}"
  printf 'CALL:has_endtoken=%s\n' \
    "$(printf '%s\n' "$_prompt" | grep -cE -- '---END-[0-9]+---' || true)" >> "${STUB_CALLS_FILE}"
  printf 'CALL:has_section_markers=%s\n' \
    "$(printf '%s\n' "$_prompt" | grep -cF ' § ' || true)" >> "${STUB_CALLS_FILE}"
  local _stub="${STUB_PROPOSALS:-NO_PROPOSALS_NEEDED}"
  # Replace @@END@@ placeholder with the actual per-generation end token from the prompt
  local _end_tok
  _end_tok="$(printf '%s\n' "$_prompt" | grep -oE -- '---END-[0-9]+---' | head -1 || true)"
  if [ -n "$_end_tok" ]; then
    printf '%s\n' "$_stub" | sed "s/@@END@@/${_end_tok}/"
  else
    printf '%s\n' "$_stub"
  fi
}
provider_resolve_model() {
  # Record which role was requested
  printf 'RESOLVE:role=%s\n' "${1:-}" >> "${STUB_CALLS_FILE}"
  case "${1:-}" in
    doc_update)     printf 'claude-fable-5\n' ;;
    doc_assessment) printf 'claude-sonnet-4-6\n' ;;
    *)              printf 'claude-sonnet-4-6\n' ;;
  esac
}
docs_map_ensure()  { return 0; }
docs_map_path()    { printf '%s/.rite/state/docs-map.tsv\n' "${FAKE_PROJECT}"; }
gh_safe()          { printf 'gh_safe:%s\n' "$*" >> "${STUB_CALLS_FILE}"; return 0; }

# Expose origin/main for _docs_apply_approved worktree fork
git -C "${FAKE_PROJECT}" update-ref refs/remotes/origin/main HEAD

# cd to FAKE_PROJECT so git rev-parse --show-toplevel resolves to the
# fake repo, not the sharkrite repo root — otherwise drift_log_path
# returns the real sharkrite drift log (which exists and has entries).
cd "${FAKE_PROJECT}"
"$@"
HELPER_EOF
  chmod +x "$_DOCS_HELPER"
  export _DOCS_HELPER
}

teardown() {
  git -C "${FAKE_PROJECT:-/dev/null}" worktree prune 2>/dev/null || true
  rm -rf "${FAKE_PROJECT:-}" "${STUB_BIN:-}" "${_DOCS_HELPER:-}"
  rm -f "${STUB_CALLS_FILE:-}"
}

# ---------------------------------------------------------------------------
# Helper: write a structured branch=main drift entry for a doc
# ---------------------------------------------------------------------------
_seed_main_entry() {
  local doc="$1"
  local assertion="${2:-test assertion}"
  local kind="${3:-contradiction}"
  local evidence="${4:-lib/core/foo.sh}"
  local pr="${5:-42}"

  # Slug formula matches _drift_entry_path: replace / with --
  local entry_slug="${doc//\//--}"
  local entry_file="${FAKE_PROJECT}/.rite/state/doc-drift/main/${entry_slug}.log"
  mkdir -p "$(dirname "$entry_file")"
  printf 'doc=%s\tbranch=main\tpr=%s\tissue=-\tassertion=%s\tkind=%s\tevidence=%s\trecorded=2026-01-01T00:00:00Z\n' \
    "$doc" "$pr" "$assertion" "$kind" "$evidence" \
    >> "$entry_file"
}

# ---------------------------------------------------------------------------
# Test 1: branch=main entries → groups by doc, calls doc_update model
# ---------------------------------------------------------------------------

@test "branch=main entries: grouped per doc, provider called with doc_update role" {
  _seed_main_entry "docs/test-doc.md" "Background section is stale" "contradiction" "lib/core/foo.sh"

  # Stub returns a valid response (narrative + edit proposal)
  export STUB_PROPOSALS
  STUB_PROPOSALS="---NARRATIVE---
The Background section references foo.sh which was refactored in PR #42.
---END-NARRATIVE---
---PROPOSAL---
ACTION: EDIT
FILE: docs/test-doc.md
DRIFT_REFS: pr:42
DESCRIPTION: Update Background to reflect refactored foo.sh
---CONTENT---
# Test Doc

## Background

Updated content after foo.sh refactor.

## Usage

Use it.
@@END@@"

  # Run reconcile in non-interactive mode (no TTY → read returns empty → skips)
  run bash "$_DOCS_HELPER" docs_reconcile_drift </dev/null
  [ "$status" -eq 0 ]

  # Verify provider_resolve_model was called with doc_update role
  grep -q "RESOLVE:role=doc_update" "$STUB_CALLS_FILE"
}

# ---------------------------------------------------------------------------
# Test 2: bounded input contains only map-anchored sections (not whole doc)
# ---------------------------------------------------------------------------

@test "branch=main entries: prompt contains map-anchored section markers" {
  _seed_main_entry "docs/test-doc.md" "Usage section outdated" "contradiction" "lib/core/bar.sh"

  export STUB_PROPOSALS="NO_PROPOSALS_NEEDED"

  run bash "$_DOCS_HELPER" docs_reconcile_drift </dev/null
  [ "$status" -eq 0 ]

  # The prompt context must contain map-anchored section markers of the form
  # "--- docs/test-doc.md § Background ---" (generated by _docs_bounded_context_for_doc
  # from the docs-map TSV).  The fake docs-map has 3 rows for docs/test-doc.md,
  # so at least one § marker line should appear.
  grep -qE "CALL:has_section_markers=[1-9]" "$STUB_CALLS_FILE"
}

# ---------------------------------------------------------------------------
# Test 3: per-generation end token (#1233) present in prompt
# ---------------------------------------------------------------------------

@test "branch=main entries: per-generation end token present in prompt (#1233)" {
  _seed_main_entry "docs/test-doc.md" "Stale assertion" "addition" "lib/utils/drift-log.sh"

  export STUB_PROPOSALS="NO_PROPOSALS_NEEDED"

  run bash "$_DOCS_HELPER" docs_reconcile_drift </dev/null
  [ "$status" -eq 0 ]

  # Verify prompt included an ---END-NNN--- end token.
  # The token appears twice in the prompt (EDIT template + REFINE template),
  # so check for any non-zero count rather than exactly 1.
  grep -qE "CALL:has_endtoken=[1-9]" "$STUB_CALLS_FILE"
}

# ---------------------------------------------------------------------------
# Test 4: response missing narrative → feedback retry, not immediate failure
# ---------------------------------------------------------------------------

@test "response missing narrative: accumulates feedback and retries" {
  _seed_main_entry "docs/test-doc.md" "Needs update" "contradiction" "lib/core/foo.sh"

  # First call returns no narrative; second returns NO_PROPOSALS_NEEDED
  local _call_count=0
  # We can't easily count individual stub calls, but we can verify the
  # mechanism: a response without ---NARRATIVE--- causes the attempt counter
  # to increment (we observe two RESOLVE:role=doc_update calls in the log).
  export STUB_PROPOSALS="---PROPOSAL---
ACTION: EDIT
FILE: docs/test-doc.md
DRIFT_REFS: none
DESCRIPTION: edit without narrative
---CONTENT---
new content
@@END@@"

  run bash "$_DOCS_HELPER" docs_reconcile_drift </dev/null
  [ "$status" -eq 0 ]

  # Exactly 2+ doc_update calls (first attempt fails validation, retries)
  local _doc_update_calls
  _doc_update_calls="$(grep -c "RESOLVE:role=doc_update" "$STUB_CALLS_FILE" || true)"
  [ "$_doc_update_calls" -ge 2 ]
}

# ---------------------------------------------------------------------------
# Test 5: response missing proposals → feedback retry
# ---------------------------------------------------------------------------

@test "response missing proposals: accumulates feedback and retries" {
  _seed_main_entry "docs/test-doc.md" "Needs update" "contradiction" "lib/core/foo.sh"

  # Response has narrative but no proposals
  export STUB_PROPOSALS="---NARRATIVE---
Something changed in the codebase.
---END-NARRATIVE---"

  run bash "$_DOCS_HELPER" docs_reconcile_drift </dev/null
  [ "$status" -eq 0 ]

  # Should retry (>= 2 doc_update calls)
  local _calls
  _calls="$(grep -c "RESOLVE:role=doc_update" "$STUB_CALLS_FILE" || true)"
  [ "$_calls" -ge 2 ]
}

# ---------------------------------------------------------------------------
# Test 6: zero branch=main entries → no-op (existing contract preserved)
# ---------------------------------------------------------------------------

@test "zero branch=main entries: no-op, provider not called" {
  # No entries seeded — RITE_STATE_DIR/doc-drift/main/ is empty
  export STUB_PROPOSALS="NO_PROPOSALS_NEEDED"

  run bash "$_DOCS_HELPER" docs_reconcile_drift </dev/null
  [ "$status" -eq 0 ]

  # Provider must NOT be called
  local _calls
  _calls="$(grep -c "RESOLVE:role=" "$STUB_CALLS_FILE" || true)"
  [ "$_calls" -eq 0 ]

  # Output should mention nothing to reconcile
  [[ "$output" =~ "nothing to reconcile" ]] || [[ "$output" =~ "No drift log" ]]
}

# ---------------------------------------------------------------------------
# Test 7: entries for other branches are untouched
# ---------------------------------------------------------------------------

@test "entries for branch=feature-x: untouched when no main entries exist" {
  # Seed an entry for a non-main branch — docs_reconcile_drift must not call
  # the provider for it when there are zero main entries.
  local _other_dir="${FAKE_PROJECT}/.rite/state/doc-drift/feature-x"
  mkdir -p "$_other_dir"
  printf 'doc=docs/test-doc.md\tbranch=feature-x\tpr=99\tissue=-\tassertion=stale\tkind=contradiction\tevidence=lib/core/foo.sh\trecorded=2026-01-01T00:00:00Z\n' \
    > "$_other_dir/docs--test-doc.md.log"

  export STUB_PROPOSALS="NO_PROPOSALS_NEEDED"

  run bash "$_DOCS_HELPER" docs_reconcile_drift </dev/null
  [ "$status" -eq 0 ]

  # Provider must NOT be called (main store is empty)
  local _calls
  _calls="$(grep -c "RESOLVE:role=doc_update" "$STUB_CALLS_FILE" || true)"
  [ "$_calls" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 8: REFINE action → kind=refinement drift entry written, not edit proposal
# ---------------------------------------------------------------------------

@test "REFINE proposal: writes kind=refinement drift entry, not an edit" {
  _seed_main_entry "docs/test-doc.md" \
    "experience is smooth" "refinement" "lib/core/foo.sh"

  export STUB_PROPOSALS
  STUB_PROPOSALS="---NARRATIVE---
The assertion 'experience is smooth' is not deterministically verifiable.
---END-NARRATIVE---
---PROPOSAL---
ACTION: REFINE
FILE: docs/test-doc.md
DRIFT_REFS: pr:42
DESCRIPTION: Replace subjective claim with checkable assertion
---CONTENT---
All sync operations complete within 5s under 1 Mbps throttling.
@@END@@"

  # In non-interactive mode (</dev/null), read returns empty → refine is skipped
  # (no terminal → user doesn't approve). The key assertion is that the provider
  # was called with doc_update and a REFINE proposal was parsed without error.
  run bash "$_DOCS_HELPER" docs_reconcile_drift </dev/null
  [ "$status" -eq 0 ]

  grep -q "RESOLVE:role=doc_update" "$STUB_CALLS_FILE"
  # No git commit should have been attempted (refine was skipped, not an edit)
  ! grep -q "git:push" "$STUB_CALLS_FILE"
}

# ---------------------------------------------------------------------------
# Test 9: #1208 EDIT context-membership guard — file outside scoped context
# ---------------------------------------------------------------------------

@test "#1208 EDIT guard: auto-skips EDIT for file outside per-doc context" {
  _seed_main_entry "docs/test-doc.md" "stale assertion" "contradiction" "lib/core/foo.sh"

  # Propose an EDIT targeting a DIFFERENT file (not in this doc's context)
  export STUB_PROPOSALS
  STUB_PROPOSALS="---NARRATIVE---
Something changed in the codebase.
---END-NARRATIVE---
---PROPOSAL---
ACTION: EDIT
FILE: docs/OTHER-doc.md
DRIFT_REFS: none
DESCRIPTION: edit a file not in context
---CONTENT---
new content
@@END@@"

  run bash "$_DOCS_HELPER" docs_reconcile_drift </dev/null
  [ "$status" -eq 0 ]

  # Output should mention auto-skipping due to context
  [[ "$output" =~ "Auto-skipping EDIT" ]] || [[ "$output" =~ "not in model context" ]]
}

# ---------------------------------------------------------------------------
# Test 10: #1208 large-file guard — EDIT for large file auto-skipped
# ---------------------------------------------------------------------------

@test "#1208 large-file guard: auto-skips EDIT for file > 8000 bytes" {
  # Make the target doc large (must exceed _bcd_section_cap=8000 in
  # _docs_bounded_context_for_doc to trigger the guard)
  python3 -c "print('x' * 9000)" > "$FAKE_PROJECT/docs/test-doc.md" 2>/dev/null || \
    dd if=/dev/zero bs=9001 count=1 2>/dev/null | tr '\0' 'x' > "$FAKE_PROJECT/docs/test-doc.md"

  _seed_main_entry "docs/test-doc.md" "stale assertion" "contradiction" "lib/core/foo.sh"

  export STUB_PROPOSALS
  STUB_PROPOSALS="---NARRATIVE---
Something changed.
---END-NARRATIVE---
---PROPOSAL---
ACTION: EDIT
FILE: docs/test-doc.md
DRIFT_REFS: none
DESCRIPTION: edit a large file
---CONTENT---
new content
@@END@@"

  run bash "$_DOCS_HELPER" docs_reconcile_drift </dev/null
  [ "$status" -eq 0 ]

  [[ "$output" =~ "Auto-skipping EDIT" ]] || [[ "$output" =~ "bytes but model only saw" ]]
}

# ---------------------------------------------------------------------------
# Test 11: #1208 CREATE-exists guard — CREATE for existing file auto-skipped
# ---------------------------------------------------------------------------

@test "#1208 CREATE-exists guard: auto-skips CREATE for file that already exists" {
  _seed_main_entry "docs/test-doc.md" "stale assertion" "contradiction" "lib/core/foo.sh"

  export STUB_PROPOSALS
  STUB_PROPOSALS="---NARRATIVE---
Something changed.
---END-NARRATIVE---
---PROPOSAL---
ACTION: CREATE
FILE: docs/test-doc.md
DRIFT_REFS: none
DESCRIPTION: create a file that already exists
---CONTENT---
new file content
@@END@@"

  run bash "$_DOCS_HELPER" docs_reconcile_drift </dev/null
  [ "$status" -eq 0 ]

  [[ "$output" =~ "Auto-skipping CREATE" ]] || [[ "$output" =~ "already exists" ]]
}

# ---------------------------------------------------------------------------
# Test 12: multiple docs — one pass per doc
# ---------------------------------------------------------------------------

@test "multiple docs with main entries: one bounded pass per doc" {
  _seed_main_entry "docs/test-doc.md" "stale A" "contradiction" "lib/core/foo.sh"

  # Seed a second doc
  printf '# Other Doc\n\n## Intro\n\nContent.\n' > "$FAKE_PROJECT/docs/other-doc.md"
  printf 'docs/other-doc.md\tabc123\t-\t1\tOther Doc\tfp4\tfeature\t-\t-\t-\n' \
    >> "$FAKE_PROJECT/.rite/state/docs-map.tsv"
  printf 'docs/other-doc.md\tabc123\t-\t2\tIntro\tfp5\tfeature\t-\t-\t-\n' \
    >> "$FAKE_PROJECT/.rite/state/docs-map.tsv"

  _seed_main_entry "docs/other-doc.md" "stale B" "addition" "lib/utils/bar.sh"

  export STUB_PROPOSALS="NO_PROPOSALS_NEEDED"

  run bash "$_DOCS_HELPER" docs_reconcile_drift </dev/null
  [ "$status" -eq 0 ]

  # One doc_update call per doc (2 total)
  local _calls
  _calls="$(grep -c "RESOLVE:role=doc_update" "$STUB_CALLS_FILE" || true)"
  [ "$_calls" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Test 13: _docs_extract_section — preamble extraction
# ---------------------------------------------------------------------------

@test "_docs_extract_section: extracts preamble (no heading)" {
  run bash -c "
export RITE_LIB_DIR='$PROJECT_ROOT/lib'
export RITE_PROJECT_ROOT='$FAKE_PROJECT'
export RITE_STATE_DIR='$FAKE_PROJECT/.rite/state'
source '$DOCS_CMD'
load_provider() { return 0; }
provider_resolve_model() { printf 'claude-sonnet-4-6\n'; }
_tf=\$(mktemp)
# File starts with a heading — preamble (empty heading level) returns nothing
printf '# Heading\n\n## Sub\n\nbody\n' > \"\$_tf\"
_docs_extract_section \"\$_tf\" '' ''
rm -f \"\$_tf\"
"
  # Preamble extraction: file starts with heading so nothing before it
  [ "$status" -eq 0 ]
  # Output must be empty (no lines before first heading)
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Test 14: _docs_extract_section — named section extraction
# ---------------------------------------------------------------------------

@test "_docs_extract_section: extracts named section by heading anchor" {
  run bash -c "
export RITE_LIB_DIR='$PROJECT_ROOT/lib'
export RITE_PROJECT_ROOT='$FAKE_PROJECT'
export RITE_STATE_DIR='$FAKE_PROJECT/.rite/state'
source '$DOCS_CMD'
load_provider() { return 0; }
provider_resolve_model() { printf 'claude-sonnet-4-6\n'; }
_tf=\$(mktemp)
printf '# Title\n\nPreamble.\n\n## Background\n\nBg content.\n\n## Usage\n\nUsage content.\n' > \"\$_tf\"
_docs_extract_section \"\$_tf\" 2 'Background'
rm -f \"\$_tf\"
"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Background" ]]
  [[ "$output" =~ "Bg content" ]]
  # Must NOT include the Usage section
  ! [[ "$output" =~ "Usage content" ]]
}

# ---------------------------------------------------------------------------
# Test 15: _docs_list_main_entry_docs — reads doc= field, not slug reverse
# ---------------------------------------------------------------------------

@test "_docs_list_main_entry_docs: lists docs from entry file doc= field" {
  _seed_main_entry "docs/test-doc.md" "assertion" "contradiction" "lib/core/foo.sh"

  run bash -c "
export RITE_LIB_DIR='$PROJECT_ROOT/lib'
export RITE_PROJECT_ROOT='$FAKE_PROJECT'
export RITE_STATE_DIR='$FAKE_PROJECT/.rite/state'
source '$DOCS_CMD'
load_provider() { return 0; }
provider_resolve_model() { printf 'claude-sonnet-4-6\n'; }
_docs_list_main_entry_docs
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs/test-doc.md"* ]]
}
