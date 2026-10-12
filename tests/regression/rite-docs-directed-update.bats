#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh
# tests/regression/rite-docs-directed-update.bats
#
# Tests for the directed doc-update engine (#1049): docs_directed_update,
# docs_reconcile_drift, _docs_parse_proposals, _docs_drift_load_entries,
# _docs_drift_burn_entries, and the preview → approve/skip loop.
#
# All LLM provider and git/gh calls are stubbed; no network calls.
# Stubs are defined AFTER sourcing docs-command.sh (Rule 2: env-guarded libs
# like gh-retry.sh are sourced by docs-command.sh and would overwrite
# pre-source stubs — post-source definitions win).

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# A minimal valid LLM response containing one UPDATE proposal.
FIXTURE_LLM_UPDATE='<<PROPOSAL>>
FILE: docs/test-fixture.md
ACTION: UPDATE
DRIFT_COVERS: 1
<<PROPOSAL_BODY>>
# Test Fixture Doc
Updated content.
<<END_PROPOSAL>>'

# A minimal valid LLM response containing one CREATE proposal.
FIXTURE_LLM_CREATE='<<PROPOSAL>>
FILE: docs/adr-999-fixture.md
ACTION: CREATE
DRIFT_COVERS:
<<PROPOSAL_BODY>>
# ADR-999 Fixture

Decision: use fixture.
<<END_PROPOSAL>>'

# A minimal drift log with one entry (marker matches the real format).
_make_drift_log() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'DRIFT_LOG_EOF'
# Sharkrite Drift Log

---

<!-- sharkrite-doc-drift pr:1 issue:- recorded:2026-01-01T00:00:00Z -->
**Changed files**: lib/core/foo.sh
**Implicated docs**:
- docs/test-fixture.md — "Overview"
**Suspected inaccuracy**: Overview may be out of date
<!-- /sharkrite-doc-drift -->
DRIFT_LOG_EOF
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DOCS_CMD="$PROJECT_ROOT/lib/core/docs-command.sh"
  export PROJECT_ROOT DOCS_CMD

  FAKE_PROJECT="$(mktemp -d)"
  mkdir -p "$FAKE_PROJECT/.rite/state"
  mkdir -p "$FAKE_PROJECT/docs"
  # Minimal docs-map.tsv so docs_map_ensure is a no-op
  touch "$FAKE_PROJECT/.rite/state/docs-map.tsv"
  export FAKE_PROJECT

  # Write the common helper script used by integration tests.
  # All stubs are defined AFTER the source so post-source overrides take effect
  # (Rule 2: gh-retry.sh has an env-var guard that would overwrite pre-source stubs).
  _DOCS_HELPER="$(mktemp)"
  cat > "$_DOCS_HELPER" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail
# Set RITE_MARKER_DOC_DRIFT before source so markers.sh sourcing in docs-command.sh
# finds it already set (markers.sh has its own re-source guard that would otherwise
# need the real lib path).
export RITE_MARKER_DOC_DRIFT="${RITE_MARKER_DOC_DRIFT:-sharkrite-doc-drift}"
source "${DOCS_CMD}"
set +u; set +o pipefail

# Stubs defined AFTER source — last definition wins.
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs sentinel; gh-retry.sh uses _RITE_GH_RETRY_LOADED env guard which would overwrite pre-source gh_safe; stubs defined post-source to ensure they win
load_provider()                       { return 0; }
provider_resolve_model()              { echo "stub-model"; }
provider_run_prompt_with_timeout()    { printf '%s' "${STUB_LLM_OUTPUT:-NO_CHANGES_NEEDED}"; }
docs_map_ensure()                     { return 0; }
docs_map_path()                       { echo "${RITE_PROJECT_ROOT}/.rite/state/docs-map.tsv"; }
drift_log_path()                      { echo "${RITE_PROJECT_ROOT}/docs/sharkrite-drift-log.md"; }
drift_log_entry_count()               { echo "${STUB_DRIFT_COUNT:-0}"; }
_docs_build_map_context()             { echo "- docs/test-fixture.md (Overview)"; }
_docs_apply_approved() {
  printf 'APPLY_CALLED:%s:%s\n' "$1" "$3" >> "${RITE_PROJECT_ROOT}/.rite/state/apply.calls"
  return 0
}
print_info()    { printf '[info] %s\n' "$*" >&2; }
print_warning() { printf '[warn] %s\n' "$*" >&2; }
print_success() { printf '[ok]   %s\n' "$*" >&2; }
print_status()  { printf '[...] %s\n' "$*" >&2; }

# Run the function passed as first arg with remaining args.
"$@"
HELPER_EOF
  chmod +x "$_DOCS_HELPER"
  export _DOCS_HELPER FIXTURE_LLM_UPDATE FIXTURE_LLM_CREATE
}

teardown() {
  rm -rf "${FAKE_PROJECT:-}"
  rm -f "${_DOCS_HELPER:-}"
}

# ===========================================================================
# 1. Structural / static checks
# ===========================================================================

@test "coverage header is present on line 2" {
  local second_line
  second_line="$(sed -n '2p' "$BATS_TEST_FILENAME")"
  echo "$second_line" | grep -q "sharkrite-test-covers: lib/core/docs-command.sh"
}

@test "docs_directed_update and docs_reconcile_drift are defined after double-source" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export RITE_MARKER_DOC_DRIFT='sharkrite-doc-drift'
    source '${DOCS_CMD}'
    source '${DOCS_CMD}'
    declare -f docs_directed_update docs_reconcile_drift >/dev/null && echo OK
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "all LLM calls use provider_resolve_model doc_assessment" {
  local count
  count="$(grep -c 'provider_resolve_model doc_assessment' "$PROJECT_ROOT/lib/core/docs-command.sh" || true)"
  [ "$count" -ge 1 ]
}

@test "no direct RITE_*_MODEL variable reads in docs-command.sh" {
  local count
  count="$(grep -cE 'RITE_[A-Z_]*_MODEL' "$PROJECT_ROOT/lib/core/docs-command.sh" || true)"
  [ "$count" -eq 0 ]
}

@test "RITE_TARGET_BRANCH:-main appears at least twice (worktree fork + gh pr create)" {
  local count
  count="$(grep -c 'RITE_TARGET_BRANCH:-main' "$PROJECT_ROOT/lib/core/docs-command.sh" || true)"
  [ "$count" -ge 2 ]
}

@test "docs_reconcile_drift has a definition and at least one call site" {
  local count
  count="$(grep -c 'docs_reconcile_drift' "$PROJECT_ROOT/lib/core/docs-command.sh" || true)"
  [ "$count" -ge 2 ]
}

@test "no gh pr merge in docs-command.sh (no auto-merge)" {
  local count
  count="$(grep -c 'pr merge' "$PROJECT_ROOT/lib/core/docs-command.sh" || true)"
  [ "$count" -eq 0 ]
}

# ===========================================================================
# 2. _docs_parse_proposals unit tests
# ===========================================================================

@test "_docs_parse_proposals: parses UPDATE proposal into structured files" {
  local out_dir
  out_dir="$(mktemp -d)"
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export RITE_MARKER_DOC_DRIFT='sharkrite-doc-drift'
    source '${DOCS_CMD}'
    set +u; set +o pipefail
    out_dir='${out_dir}'
    llm_out='${FIXTURE_LLM_UPDATE}'
    count=\"\$(_docs_parse_proposals \"\$llm_out\" \"\$out_dir\")\"
    echo \"count=\$count\"
    echo \"file=\$(cat \"\$out_dir/proposal_1_file.txt\" 2>/dev/null || true)\"
    echo \"action=\$(cat \"\$out_dir/proposal_1_action.txt\" 2>/dev/null || true)\"
    echo \"drift=\$(cat \"\$out_dir/proposal_1_drift.txt\" 2>/dev/null || true)\"
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "count=1"
  echo "$output" | grep -q "file=docs/test-fixture.md"
  echo "$output" | grep -q "action=UPDATE"
  echo "$output" | grep -q "drift=1"
  rm -rf "$out_dir"
}

@test "_docs_parse_proposals: parses CREATE proposal with ACTION=CREATE" {
  local out_dir
  out_dir="$(mktemp -d)"
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export RITE_MARKER_DOC_DRIFT='sharkrite-doc-drift'
    source '${DOCS_CMD}'
    set +u; set +o pipefail
    out_dir='${out_dir}'
    llm_out='${FIXTURE_LLM_CREATE}'
    count=\"\$(_docs_parse_proposals \"\$llm_out\" \"\$out_dir\")\"
    echo \"count=\$count\"
    echo \"file=\$(cat \"\$out_dir/proposal_1_file.txt\" 2>/dev/null || true)\"
    echo \"action=\$(cat \"\$out_dir/proposal_1_action.txt\" 2>/dev/null || true)\"
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "count=1"
  echo "$output" | grep -q "file=docs/adr-999-fixture.md"
  echo "$output" | grep -q "action=CREATE"
  rm -rf "$out_dir"
}

@test "_docs_parse_proposals: empty output produces count 0" {
  local out_dir
  out_dir="$(mktemp -d)"
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export RITE_MARKER_DOC_DRIFT='sharkrite-doc-drift'
    source '${DOCS_CMD}'
    set +u; set +o pipefail
    _docs_parse_proposals 'NO_CHANGES_NEEDED' '${out_dir}'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  rm -rf "$out_dir"
}

# ===========================================================================
# 3. _docs_drift_load_entries unit tests
# ===========================================================================

@test "_docs_drift_load_entries: parses one entry from drift log" {
  _make_drift_log "$FAKE_PROJECT/docs/sharkrite-drift-log.md"
  local out_dir
  out_dir="$(mktemp -d)"
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export RITE_MARKER_DOC_DRIFT='sharkrite-doc-drift'
    source '${DOCS_CMD}'
    set +u; set +o pipefail
    count=\"\$(_docs_drift_load_entries '${FAKE_PROJECT}/docs/sharkrite-drift-log.md' '${out_dir}')\"
    echo \"count=\$count\"
    [ -f '${out_dir}/entry_1.txt' ] && echo 'entry1_exists=yes'
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "count=1"
  echo "$output" | grep -q "entry1_exists=yes"
  rm -rf "$out_dir"
}

@test "_docs_drift_load_entries: returns 0 when log does not exist" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export RITE_MARKER_DOC_DRIFT='sharkrite-doc-drift'
    source '${DOCS_CMD}'
    set +u; set +o pipefail
    _docs_drift_load_entries '/nonexistent/path.md' '/tmp'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ===========================================================================
# 4. _docs_drift_burn_entries unit tests
# ===========================================================================

@test "_docs_drift_burn_entries: removes specified entry, leaves others intact" {
  # Create a drift log with two entries.
  local log_path="${FAKE_PROJECT}/docs/sharkrite-drift-log.md"
  mkdir -p "$(dirname "$log_path")"
  cat > "$log_path" <<'TWOENTRY_EOF'
# Sharkrite Drift Log

---

<!-- sharkrite-doc-drift pr:1 issue:- recorded:2026-01-01T00:00:00Z -->
**Changed files**: lib/core/foo.sh
**Implicated docs**:
- docs/a.md — "Section A"
**Suspected inaccuracy**: A is stale
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:2 issue:- recorded:2026-02-01T00:00:00Z -->
**Changed files**: lib/core/bar.sh
**Implicated docs**:
- docs/b.md — "Section B"
**Suspected inaccuracy**: B is stale
<!-- /sharkrite-doc-drift -->
TWOENTRY_EOF

  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export RITE_MARKER_DOC_DRIFT='sharkrite-doc-drift'
    source '${DOCS_CMD}'
    set +u; set +o pipefail
    remaining=\"\$(_docs_drift_burn_entries '${log_path}' '1')\"
    echo \"remaining=\$remaining\"
    [ -f '${log_path}' ] && echo 'log_exists=yes'
    grep -q 'pr:2' '${log_path}' && echo 'entry2_kept=yes'
    grep -q 'pr:1' '${log_path}' && echo 'entry1_kept=yes' || true
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "remaining=1"
  echo "$output" | grep -q "log_exists=yes"
  echo "$output" | grep -q "entry2_kept=yes"
  # Entry 1 must have been removed
  run grep -c "pr:1" "$log_path"
  [ "$output" = "0" ]
}

@test "_docs_drift_burn_entries: draining last entry deletes the log file" {
  _make_drift_log "$FAKE_PROJECT/docs/sharkrite-drift-log.md"

  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export RITE_MARKER_DOC_DRIFT='sharkrite-doc-drift'
    source '${DOCS_CMD}'
    set +u; set +o pipefail
    remaining=\"\$(_docs_drift_burn_entries '${FAKE_PROJECT}/docs/sharkrite-drift-log.md' '1')\"
    echo \"remaining=\$remaining\"
    [ ! -f '${FAKE_PROJECT}/docs/sharkrite-drift-log.md' ] && echo 'log_deleted=yes' || echo 'log_exists=yes'
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "remaining=0"
  echo "$output" | grep -q "log_deleted=yes"
}

# ===========================================================================
# 5. Integration: answer 'n' → no changes applied
# ===========================================================================

@test "answering 'n' at preview leaves working tree and drift log byte-identical" {
  _make_drift_log "$FAKE_PROJECT/docs/sharkrite-drift-log.md"
  local drift_log_before
  drift_log_before="$(cat "$FAKE_PROJECT/docs/sharkrite-drift-log.md")"
  # Note original tree state (apply.calls must not exist after answering n)

  run bash -c "
    export DOCS_CMD='${DOCS_CMD}'
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export STUB_LLM_OUTPUT='${FIXTURE_LLM_UPDATE}'
    echo 'n' | bash '${_DOCS_HELPER}' docs_directed_update 'update the overview'
  "
  [ "$status" -eq 0 ]

  # No apply calls must have been recorded.
  run test -f "$FAKE_PROJECT/.rite/state/apply.calls"
  [ "$status" -ne 0 ]

  # Drift log must be byte-identical to before the run.
  local drift_log_after
  drift_log_after="$(cat "$FAKE_PROJECT/docs/sharkrite-drift-log.md")"
  [ "$drift_log_before" = "$drift_log_after" ]
}

# ===========================================================================
# 6. Integration: CREATE proposal → preview shows, approval calls apply
# ===========================================================================

@test "CREATE proposal: approval calls _docs_apply_approved with correct instruction" {
  run bash -c "
    export DOCS_CMD='${DOCS_CMD}'
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export STUB_LLM_OUTPUT='${FIXTURE_LLM_CREATE}'
    echo 'y' | bash '${_DOCS_HELPER}' docs_directed_update 'write an ADR for the caching decision'
  "
  [ "$status" -eq 0 ]
  [ -f "$FAKE_PROJECT/.rite/state/apply.calls" ]
  grep -q "APPLY_CALLED:write an ADR for the caching decision" \
    "$FAKE_PROJECT/.rite/state/apply.calls"
}

@test "CREATE proposal: preview output contains NEW FILE marker" {
  run bash -c "
    export DOCS_CMD='${DOCS_CMD}'
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export STUB_LLM_OUTPUT='${FIXTURE_LLM_CREATE}'
    echo 'n' | bash '${_DOCS_HELPER}' docs_directed_update 'create ADR'
  " 2>&1
  # The preview is printed on stderr; we check the combined output here.
  echo "$output" | grep -qE "NEW FILE|adr-999-fixture.md"
}

# ===========================================================================
# 7. Integration: burn-down semantics
# ===========================================================================

@test "approved UPDATE covering drift entry 1: apply is called and drift index passed" {
  _make_drift_log "$FAKE_PROJECT/docs/sharkrite-drift-log.md"

  run bash -c "
    export DOCS_CMD='${DOCS_CMD}'
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export STUB_LLM_OUTPUT='${FIXTURE_LLM_UPDATE}'
    echo 'y' | bash '${_DOCS_HELPER}' docs_directed_update 'update overview'
  "
  [ "$status" -eq 0 ]
  # _docs_apply_approved stub records count as third arg.
  [ -f "$FAKE_PROJECT/.rite/state/apply.calls" ]
  grep -q "APPLY_CALLED:update overview:1" "$FAKE_PROJECT/.rite/state/apply.calls"
}

@test "_docs_drift_burn_entries: last-entry drain deletes file (burn-down unit)" {
  # Re-check via a direct unit test that the acceptance criterion is satisfied.
  _make_drift_log "$FAKE_PROJECT/docs/sharkrite-drift-log.md"
  [ -f "$FAKE_PROJECT/docs/sharkrite-drift-log.md" ]

  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export RITE_MARKER_DOC_DRIFT='sharkrite-doc-drift'
    source '${DOCS_CMD}'
    set +u; set +o pipefail
    _docs_drift_burn_entries '${FAKE_PROJECT}/docs/sharkrite-drift-log.md' '1'
  "
  [ "$status" -eq 0 ]
  [ ! -f "$FAKE_PROJECT/docs/sharkrite-drift-log.md" ]
}

# ===========================================================================
# 8. Integration: works in changelog mode (consent gate not checked)
# ===========================================================================

@test "directed update applies in changelog mode without consent gate check" {
  # No .rite/doc-sync.md → changelog mode. docs_directed_update must NOT check
  # the consent gate before applying an explicitly approved change.
  [ ! -f "$FAKE_PROJECT/.rite/doc-sync.md" ]
  export RITE_DOC_MODE=changelog

  run bash -c "
    export DOCS_CMD='${DOCS_CMD}'
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export RITE_DOC_MODE=changelog
    export STUB_LLM_OUTPUT='${FIXTURE_LLM_UPDATE}'
    echo 'y' | bash '${_DOCS_HELPER}' docs_directed_update 'update in changelog mode'
  "
  [ "$status" -eq 0 ]
  [ -f "$FAKE_PROJECT/.rite/state/apply.calls" ]
}

# ===========================================================================
# 9. docs_reconcile_drift: zero entries → info and exit 0
# ===========================================================================

@test "docs_reconcile_drift exits 0 when no drift log exists" {
  [ ! -f "$FAKE_PROJECT/docs/sharkrite-drift-log.md" ]

  run bash -c "
    export DOCS_CMD='${DOCS_CMD}'
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    bash '${_DOCS_HELPER}' docs_reconcile_drift
  "
  [ "$status" -eq 0 ]
}

@test "docs_reconcile_drift exits 0 when drift log has no entries" {
  # Write a drift log with a header only (no entries).
  cat > "$FAKE_PROJECT/docs/sharkrite-drift-log.md" <<'EMPTY_LOG_EOF'
# Sharkrite Drift Log

---
EMPTY_LOG_EOF

  run bash -c "
    export DOCS_CMD='${DOCS_CMD}'
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    bash '${_DOCS_HELPER}' docs_reconcile_drift
  "
  [ "$status" -eq 0 ]
}

@test "docs_reconcile_drift: answer 'y' calls _docs_apply_approved with reconcile instruction" {
  _make_drift_log "$FAKE_PROJECT/docs/sharkrite-drift-log.md"

  run bash -c "
    export DOCS_CMD='${DOCS_CMD}'
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export STUB_LLM_OUTPUT='${FIXTURE_LLM_UPDATE}'
    echo 'y' | bash '${_DOCS_HELPER}' docs_reconcile_drift
  "
  [ "$status" -eq 0 ]
  [ -f "$FAKE_PROJECT/.rite/state/apply.calls" ]
  grep -q "APPLY_CALLED:reconcile" "$FAKE_PROJECT/.rite/state/apply.calls"
}

# ===========================================================================
# 10. _docs_apply_approved integration: real git worktree + stubbed gh_safe
# ===========================================================================

# Helper: initialise FAKE_PROJECT as a bare-clone "origin" so _docs_apply_approved
# can fork a worktree from origin/main, commit, and push back.
_init_git_origin() {
  local fake_root="$1"
  # Bare repo acts as origin
  local bare="${fake_root}/.rite/bare-origin"
  git init --bare "$bare" >/dev/null 2>&1
  # Point default branch to main so clones and pushes use main, not master.
  git -C "$bare" symbolic-ref HEAD refs/heads/main

  # Seeded working clone that has origin set to the bare repo
  local seed="${fake_root}/.rite/seed-clone"
  git clone "$bare" "$seed" >/dev/null 2>&1
  git -C "$seed" config user.email "test@example.com"
  git -C "$seed" config user.name "Test"
  # Commit a minimal docs file so main is non-empty
  mkdir -p "${seed}/docs"
  printf '# Test Fixture Doc\nOriginal content.\n' > "${seed}/docs/test-fixture.md"
  git -C "$seed" add . >/dev/null 2>&1
  git -C "$seed" commit -m "seed" >/dev/null 2>&1
  git -C "$seed" push origin HEAD:main >/dev/null 2>&1

  # Point FAKE_PROJECT's origin remote at the bare repo
  git -C "$fake_root" init >/dev/null 2>&1
  git -C "$fake_root" config user.email "test@example.com"
  git -C "$fake_root" config user.name "Test"
  git -C "$fake_root" remote add origin "$bare" 2>/dev/null || true
  git -C "$fake_root" fetch origin >/dev/null 2>&1
}

@test "_docs_apply_approved: writes proposal to docs branch and creates PR" {
  # Set up a local bare-clone origin so push succeeds without network.
  _init_git_origin "$FAKE_PROJECT"

  # Build a minimal proposal directory with one UPDATE proposal.
  local prop_dir
  prop_dir="$(mktemp -d)"
  printf 'docs/test-fixture.md' > "${prop_dir}/proposal_1_file.txt"
  printf 'UPDATE'               > "${prop_dir}/proposal_1_action.txt"
  printf ''                     > "${prop_dir}/proposal_1_drift.txt"
  printf '# Test Fixture Doc\nUpdated content by apply test.\n' \
    > "${prop_dir}/proposal_1_content.txt"

  # Capture gh_safe pr create args without hitting GitHub.
  local gh_call_log="${FAKE_PROJECT}/.rite/state/gh.calls"

  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export RITE_MARKER_DOC_DRIFT='sharkrite-doc-drift'
    # Pin: the gate inherits the session's RITE_TARGET_BRANCH (e.g. an integration
    # branch under --branch); the fork must target the fixture's main (issue #1049 review Item 1).
    export RITE_TARGET_BRANCH=main
    source '${DOCS_CMD}'
    set +u; set +o pipefail

    # Stubs — defined after source so env-guarded re-source guards don't overwrite them.
    # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs sentinel guard; stubs defined post-source to win
    drift_log_path()       { echo '${FAKE_PROJECT}/docs/drift-log.md'; }
    drift_log_entry_count(){ echo '0'; }
    print_info()    { printf '[info] %s\n' \"\$*\" >&2; }
    print_warning() { printf '[warn] %s\n' \"\$*\" >&2; }
    print_success() { printf '[ok]   %s\n' \"\$*\" >&2; }
    gh_safe() {
      printf 'gh_safe:%s\n' \"\$*\" >> '${gh_call_log}'
      # Simulate 'pr create' returning a URL; 'pr edit' is a no-op.
      case \"\$1 \$2\" in
        'pr create') echo 'https://github.com/test/repo/pull/99' ;;
      esac
    }

    _docs_apply_approved 'test instruction' '${prop_dir}' 1
  "
  [ "$status" -eq 0 ]

  # The docs branch must contain the updated file content.
  local branch
  branch="$(git -C "$FAKE_PROJECT" branch -r --list 'origin/docs/directed-update-*' | head -1 | tr -d ' ')"
  [ -n "$branch" ]
  local content
  content="$(git -C "$FAKE_PROJECT" show "${branch}:docs/test-fixture.md" 2>/dev/null || true)"
  echo "$content" | grep -q "Updated content by apply test"

  # gh_safe must have been called with pr create (no --label in the create call).
  [ -f "$gh_call_log" ]
  grep -q "pr create" "$gh_call_log"
  # --label must NOT appear on the create line (best-effort edit handles it separately).
  ! grep "pr create" "$gh_call_log" | grep -q -- "--label"
  # Best-effort label edit must have been attempted.
  grep -q "pr edit" "$gh_call_log"

  rm -rf "$prop_dir"
}

@test "_docs_apply_approved: drift log burn-down deletes log when last entry drained" {
  _init_git_origin "$FAKE_PROJECT"
  _make_drift_log "$FAKE_PROJECT/docs/drift-log.md"
  # Also seed the drift log into the bare origin so the worktree clone has it.
  local seed_clone
  seed_clone="$(mktemp -d)"
  git clone "${FAKE_PROJECT}/.rite/bare-origin" "$seed_clone" >/dev/null 2>&1
  git -C "$seed_clone" config user.email "test@example.com"
  git -C "$seed_clone" config user.name "Test"
  mkdir -p "${seed_clone}/docs"
  cp "$FAKE_PROJECT/docs/drift-log.md" "${seed_clone}/docs/drift-log.md"
  git -C "$seed_clone" add . >/dev/null 2>&1
  git -C "$seed_clone" commit -m "add drift log" >/dev/null 2>&1
  git -C "$seed_clone" push origin HEAD:main >/dev/null 2>&1
  rm -rf "$seed_clone"

  local prop_dir
  prop_dir="$(mktemp -d)"
  printf 'docs/test-fixture.md' > "${prop_dir}/proposal_1_file.txt"
  printf 'UPDATE'               > "${prop_dir}/proposal_1_action.txt"
  printf '1'                    > "${prop_dir}/proposal_1_drift.txt"
  printf '# Test Fixture Doc\nBurn-down test.\n' \
    > "${prop_dir}/proposal_1_content.txt"

  local gh_call_log="${FAKE_PROJECT}/.rite/state/gh-burn.calls"

  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${PROJECT_ROOT}/lib'
    export RITE_PROJECT_ROOT='${FAKE_PROJECT}'
    export RITE_DATA_DIR='.rite'
    export RITE_MARKER_DOC_DRIFT='sharkrite-doc-drift'
    # Pin: the gate inherits the session's RITE_TARGET_BRANCH (see section-10 sibling above).
    export RITE_TARGET_BRANCH=main
    source '${DOCS_CMD}'
    set +u; set +o pipefail

    # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs sentinel guard; stubs defined post-source to win
    drift_log_path()       { echo '${FAKE_PROJECT}/docs/drift-log.md'; }
    drift_log_entry_count(){ local _f=\"\${1:-}\"; [ -f \"\$_f\" ] || { echo '0'; return 0; }; grep -c 'sharkrite-doc-drift pr:[0-9]' \"\$_f\" || true; }
    print_info()    { printf '[info] %s\n' \"\$*\" >&2; }
    print_warning() { printf '[warn] %s\n' \"\$*\" >&2; }
    print_success() { printf '[ok]   %s\n' \"\$*\" >&2; }
    gh_safe() {
      printf 'gh_safe:%s\n' \"\$*\" >> '${gh_call_log}'
      case \"\$1 \$2\" in
        'pr create') echo 'https://github.com/test/repo/pull/100' ;;
      esac
    }

    _docs_apply_approved 'burn-down test' '${prop_dir}' 1
  " 2>&1
  [ "$status" -eq 0 ]
  # Burn-down must have executed — a silently-skipped block would never print this.
  echo "$output" | grep -q "Drift log fully drained"

  # Verify the docs branch does NOT contain the drift log (it was fully drained).
  local branch
  branch="$(git -C "$FAKE_PROJECT" branch -r --list 'origin/docs/directed-update-*' | tail -1 | tr -d ' ')"
  [ -n "$branch" ]
  # drift-log.md should be absent from the docs branch (deleted by burn-down).
  run git -C "$FAKE_PROJECT" show "${branch}:docs/drift-log.md" 2>&1
  [ "$status" -ne 0 ]

  rm -rf "$prop_dir"
}
