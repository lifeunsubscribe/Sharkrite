#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh::_docs_apply_approved|_docs_main_entries_pass, lib/utils/drift-log.sh::drift_log_remove_entry
BATS_TEST_TIMEOUT=30
#
# Tests for fold-then-remove semantics on _docs_apply_approved (#1432):
#
#  1. PR body contains folded entries (doc, assertion, kind, PRs, evidence).
#  2. Entries removed from store only after gh pr create succeeds.
#  3. gh pr create failure leaves entries intact.
#  4. No ENTRY_FILE arg → no structured removal, behavior unchanged.
#  5. Structural: removal uses drift_log_remove_entry per key, not glob rm.
#
# Tests for drift_log_remove_entry (unit):
#  6. Removes exact (doc, branch, assertion) entry.
#  7. Leaves non-matching entries in same file untouched.
#  8. No-op when file does not exist.
#  9. Removing one entry from multi-entry file leaves the other.
#
# All LLM and git push/fetch calls are stubbed.

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DOCS_CMD="$PROJECT_ROOT/lib/core/docs-command.sh"
  export PROJECT_ROOT DOCS_CMD

  # Fake project: real git repo so worktree commands work
  FAKE_PROJECT="$(mktemp -d)"
  mkdir -p "$FAKE_PROJECT/.rite/state/doc-drift/main" "$FAKE_PROJECT/docs"
  printf '# Test Doc\n\n## Background\n\nOriginal content.\n' \
    > "$FAKE_PROJECT/docs/test-doc.md"
  git -C "$FAKE_PROJECT" init -q
  git -C "$FAKE_PROJECT" config user.email "test@sharkrite.local"
  git -C "$FAKE_PROJECT" config user.name "Test"
  git -C "$FAKE_PROJECT" add .
  git -C "$FAKE_PROJECT" commit -q -m "init"
  export FAKE_PROJECT

  # PATH-priority stub: intercept git push/fetch; pass through all other git commands
  STUB_BIN="$(mktemp -d)"
  STUB_CALLS_FILE="$(mktemp)"
  PR_BODY_FILE="$(mktemp)"
  REAL_GIT="$(command -v git)"
  export STUB_BIN STUB_CALLS_FILE PR_BODY_FILE REAL_GIT
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

  # Helper script: sources docs-command.sh with stubs, then dispatches $@
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
export STUB_CALLS_FILE PR_BODY_FILE

source "${DOCS_CMD}"

# Re-define stubs AFTER source (env-guarded libs overwrite pre-source stubs).
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs sentinel guard; all stubs must be post-source
load_provider()                    { return 0; }
provider_run_prompt_with_timeout() { printf 'NO_PROPOSALS_NEEDED\n'; }
provider_resolve_model()           { printf 'claude-sonnet-4-6\n'; }
docs_map_ensure()                  { return 0; }
docs_map_build()                   { return 0; }
docs_map_path()                    { printf '%s/.rite/state/docs-map.tsv\n' "${FAKE_PROJECT}"; }

# gh_safe stub: records PR body to PR_BODY_FILE; honours GH_SAFE_EXIT override
gh_safe() {
  printf 'gh_safe:%s\n' "$*" >> "${STUB_CALLS_FILE}"
  local _body="" _in_body=0
  for _arg in "$@"; do
    if [ "$_in_body" = "1" ]; then
      printf '%s' "$_arg" > "${PR_BODY_FILE}"
      _in_body=0
    fi
    [ "$_arg" = "--body" ] && _in_body=1
  done
  return "${GH_SAFE_EXIT:-0}"
}

# Expose origin/main so git worktree add can fork from it
git -C "${FAKE_PROJECT}" update-ref refs/remotes/origin/main HEAD

cd "${FAKE_PROJECT}"
"$@"
HELPER_EOF
  chmod +x "$_DOCS_HELPER"
  export _DOCS_HELPER

  # Minimal docs-map so _docs_bounded_context_for_doc can proceed
  printf '# docs-map v4 sha=abc123 built=2026-01-01T00:00:00Z\n' \
    > "$FAKE_PROJECT/.rite/state/docs-map.tsv"
  printf 'docs/test-doc.md\tabc123\t-\t1\tTest Doc\tfp1\tfeature\t-\t-\t-\n' \
    >> "$FAKE_PROJECT/.rite/state/docs-map.tsv"

  # -- drift-log.sh unit-test setup (sourced directly, no helper script) --
  source "$PROJECT_ROOT/lib/utils/config.sh" 2>/dev/null || true
  source "$PROJECT_ROOT/lib/utils/colors.sh" 2>/dev/null || true
  source "$PROJECT_ROOT/lib/utils/logging.sh" 2>/dev/null || true
  source "$PROJECT_ROOT/lib/utils/lock.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: drift-log.sh uses declare -f drift_log_append sentinel guard; no pre-source stubs defined
  source "$PROJECT_ROOT/lib/utils/drift-log.sh" 2>/dev/null || true
  set +u; set +o pipefail

  # Silence print_* in unit tests
  print_info()    { :; }
  print_warning() { :; }

  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  export RITE_PROJECT_ROOT="$FAKE_PROJECT"
  export RITE_STATE_DIR="$FAKE_PROJECT/.rite/state"
}

teardown() {
  git -C "${FAKE_PROJECT:-/dev/null}" worktree prune 2>/dev/null || true
  rm -rf "${FAKE_PROJECT:-}" "${STUB_BIN:-}" "${_DOCS_HELPER:-}"
  rm -f "${STUB_CALLS_FILE:-}" "${PR_BODY_FILE:-}"
}

# ---------------------------------------------------------------------------
# Helper: seed one structured drift entry into the main-branch store
# ---------------------------------------------------------------------------
_seed_entry() {
  local doc="${1:-docs/test-doc.md}"
  local assertion="${2:-Background is stale}"
  local kind="${3:-contradiction}"
  local pr="${4:-42}"
  local evidence="${5:-lib/core/foo.sh}"

  local entry_slug="${doc//\//--}"
  local entry_file="${FAKE_PROJECT}/.rite/state/doc-drift/main/${entry_slug}.log"
  mkdir -p "$(dirname "$entry_file")"
  printf 'doc=%s\tbranch=main\tpr=%s\tissue=-\tassertion=%s\tkind=%s\tevidence=%s\trecorded=2026-10-01T00:00:00Z\n' \
    "$doc" "$pr" "$assertion" "$kind" "$evidence" \
    >> "$entry_file"
}

# ---------------------------------------------------------------------------
# Helper: build an approved proposals dir for _docs_apply_approved
# ---------------------------------------------------------------------------
_make_approved_dir() {
  local appr_dir
  appr_dir="$(mktemp -d)"
  cat > "$appr_dir/approved_1.txt" << 'PROP_EOF'
ACTION: EDIT
FILE: docs/test-doc.md
DRIFT_REFS: pr:42
DESCRIPTION: Update Background to reflect refactored foo.sh
---CONTENT---
# Test Doc

## Background

Updated content.
PROP_EOF
  printf '%s\n' "$appr_dir"
}

# ---------------------------------------------------------------------------
# 1. PR body contains folded entry fields
# ---------------------------------------------------------------------------

@test "_docs_apply_approved: PR body contains folded entry doc, assertion, kind" {
  _seed_entry "docs/test-doc.md" "Background is stale" "contradiction" "42" "lib/core/foo.sh"

  local appr_dir entry_slug entry_file
  appr_dir="$(_make_approved_dir)"
  entry_slug="docs--test-doc.md"
  entry_file="${FAKE_PROJECT}/.rite/state/doc-drift/main/${entry_slug}.log"

  run bash "$_DOCS_HELPER" \
    _docs_apply_approved "$appr_dir" "" "" "reconcile" "main" "true" "$entry_file"
  rm -rf "$appr_dir"
  [ "$status" -eq 0 ]

  # PR body must contain key entry fields
  grep -q "docs/test-doc.md" "$PR_BODY_FILE"
  grep -q "Background is stale" "$PR_BODY_FILE"
  grep -q "contradiction" "$PR_BODY_FILE"
}

@test "_docs_apply_approved: PR body contains entry PR number and evidence" {
  _seed_entry "docs/test-doc.md" "Usage section outdated" "addition" "1301" "lib/utils/bar.sh"

  local appr_dir entry_file
  appr_dir="$(_make_approved_dir)"
  entry_file="${FAKE_PROJECT}/.rite/state/doc-drift/main/docs--test-doc.md.log"

  run bash "$_DOCS_HELPER" \
    _docs_apply_approved "$appr_dir" "" "" "reconcile" "main" "true" "$entry_file"
  rm -rf "$appr_dir"
  [ "$status" -eq 0 ]

  grep -q "1301" "$PR_BODY_FILE"
  grep -q "lib/utils/bar.sh" "$PR_BODY_FILE"
}

# ---------------------------------------------------------------------------
# 2. Entries removed after gh pr create succeeds
# ---------------------------------------------------------------------------

@test "_docs_apply_approved: entry file removed after successful gh pr create" {
  _seed_entry "docs/test-doc.md" "Background is stale" "contradiction" "42" "lib/core/foo.sh"

  local appr_dir entry_file
  appr_dir="$(_make_approved_dir)"
  entry_file="${FAKE_PROJECT}/.rite/state/doc-drift/main/docs--test-doc.md.log"

  [ -f "$entry_file" ]

  run bash "$_DOCS_HELPER" \
    _docs_apply_approved "$appr_dir" "" "" "reconcile" "main" "true" "$entry_file"
  rm -rf "$appr_dir"
  [ "$status" -eq 0 ]

  # Entry file should be gone after the single entry was removed
  [ ! -f "$entry_file" ]
}

# ---------------------------------------------------------------------------
# 3. gh pr create failure leaves entries intact
# ---------------------------------------------------------------------------

@test "_docs_apply_approved: entry file intact when gh pr create fails" {
  _seed_entry "docs/test-doc.md" "Background is stale" "contradiction" "42" "lib/core/foo.sh"

  local appr_dir entry_file
  appr_dir="$(_make_approved_dir)"
  entry_file="${FAKE_PROJECT}/.rite/state/doc-drift/main/docs--test-doc.md.log"

  # Override gh_safe exit to simulate failure
  GH_SAFE_EXIT=1 run bash "$_DOCS_HELPER" \
    _docs_apply_approved "$appr_dir" "" "" "reconcile" "main" "true" "$entry_file"
  rm -rf "$appr_dir"

  # _docs_apply_approved returns 0 even when PR creation fails (warns + moves on)
  [ "$status" -eq 0 ]

  # Entry file must still exist — entries not removed on PR failure
  [ -f "$entry_file" ]
}

# ---------------------------------------------------------------------------
# 4. No ENTRY_FILE arg → no structured removal (legacy behavior preserved)
# ---------------------------------------------------------------------------

@test "_docs_apply_approved: without ENTRY_FILE arg, no structured entries touched" {
  _seed_entry "docs/test-doc.md" "Background is stale" "contradiction" "42" "lib/core/foo.sh"

  local appr_dir entry_file
  appr_dir="$(_make_approved_dir)"
  entry_file="${FAKE_PROJECT}/.rite/state/doc-drift/main/docs--test-doc.md.log"

  # Call without 7th arg (ENTRY_FILE absent)
  run bash "$_DOCS_HELPER" \
    _docs_apply_approved "$appr_dir" "" "" "reconcile" "main"
  rm -rf "$appr_dir"
  [ "$status" -eq 0 ]

  # Entry file must still exist — no ENTRY_FILE passed, so removal is skipped
  [ -f "$entry_file" ]
}

# ---------------------------------------------------------------------------
# 5. Structural: removal uses drift_log_remove_entry, not glob rm
# ---------------------------------------------------------------------------

@test "structural: _docs_apply_approved uses drift_log_remove_entry per key, not glob rm" {
  # Grep the implementation for drift_log_remove_entry calls (not rm -f glob)
  grep -q "drift_log_remove_entry" "$PROJECT_ROOT/lib/core/docs-command.sh"
  # Confirm the removal loop is NOT doing a bare rm on the entry file
  ! grep -n 'rm.*entry_file\|rm.*_aa_entry_file\|rm -rf.*doc-drift' \
    "$PROJECT_ROOT/lib/core/docs-command.sh" | grep -v '#' | grep -q '.'
}

# ---------------------------------------------------------------------------
# 6. drift_log_remove_entry: removes exact (doc, branch, assertion) entry
# ---------------------------------------------------------------------------

@test "drift_log_remove_entry: removes matching entry from file" {
  local doc="docs/architecture/foo.md"
  local branch="main"
  local assertion="Gate Block-on-Any"

  drift_log_append "$doc" "$branch" "97" "42" "$assertion" "addition" "lib/utils/test-gate.sh"

  local entry_file
  entry_file="$(_drift_entry_path "$doc" "$branch")"
  [ -f "$entry_file" ]

  drift_log_remove_entry "$doc" "$branch" "$assertion"

  [ ! -f "$entry_file" ]
}

# ---------------------------------------------------------------------------
# 7. drift_log_remove_entry: leaves non-matching entries untouched
# ---------------------------------------------------------------------------

@test "drift_log_remove_entry: non-matching entry in same file is preserved" {
  local doc="docs/architecture/foo.md"
  local branch="main"

  drift_log_append "$doc" "$branch" "97" "42" "Assertion A" "addition" "evidence"
  drift_log_append "$doc" "$branch" "98" "43" "Assertion B" "addition" "evidence"

  local entry_file
  entry_file="$(_drift_entry_path "$doc" "$branch")"
  local initial_count
  initial_count="$(grep -c '^doc=' "$entry_file" || true)"
  [ "$initial_count" -eq 2 ]

  drift_log_remove_entry "$doc" "$branch" "Assertion A"

  local remaining_count
  remaining_count="$(grep -c '^doc=' "$entry_file" || true)"
  [ "$remaining_count" -eq 1 ]
  grep -q "assertion=Assertion B" "$entry_file"
}

# ---------------------------------------------------------------------------
# 8. drift_log_remove_entry: no-op when file does not exist
# ---------------------------------------------------------------------------

@test "drift_log_remove_entry: no-op when entry file absent" {
  run drift_log_remove_entry "docs/nonexistent.md" "main" "Some assertion"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 9. drift_log_remove_entry: removing one entry from multi-entry file
# ---------------------------------------------------------------------------

@test "drift_log_remove_entry: file deleted when last entry removed" {
  local doc="docs/myfile.md"
  local branch="main"

  drift_log_append "$doc" "$branch" "100" "-" "Only assertion" "addition" "evidence"

  local entry_file
  entry_file="$(_drift_entry_path "$doc" "$branch")"
  [ -f "$entry_file" ]

  drift_log_remove_entry "$doc" "$branch" "Only assertion"

  [ ! -f "$entry_file" ]
}
