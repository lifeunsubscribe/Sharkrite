#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh::_docs_cross_doc_just_in_case_pass|_docs_jic_covers_for_doc|docs_run_promote_doc_pass
# tests/regression/promote-just-in-case-pass.bats
#
# Regression tests for #1435: cross-doc just-in-case pass in promote doc pass.
#
# Acceptance criteria verified:
#   1. Deterministic stage: clean intersection (empty) ends with no provider call.
#   2. Non-empty intersection → one bounded triage call; entry written for implicated doc.
#   3. Declared doc (already in drift store for branch) is excluded from the sweep.
#   4. The pass NEVER proposes or applies edits — structural grep confirms no edit call.

load '../helpers/setup'
load '../helpers/promote-stubs'

setup() {
  setup_test_tmpdir
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: extend the fake lib with stubs for docs-command.sh dependencies.
# Adds docs-map.sh, drift-log.sh, doc-consent.sh, markers.sh stubs
# suitable for testing the just-in-case pass.
# ---------------------------------------------------------------------------
_write_jic_docs_stubs() {
  local _lib="$1"
  local _fake_tsv="${2:-}"  # path to a fake docs-map.tsv (optional)

  cat > "$_lib/utils/doc-consent.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f record_doc_mode >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
record_doc_mode() { return 0; }
ensure_doc_mode()  { return 0; }
STUB

  cat > "$_lib/utils/markers.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f rite_markers_loaded >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
rite_markers_loaded() { return 0; }
RITE_MARKER_REVIEW="sharkrite-local-review"
RITE_MARKER_ASSESSMENT="sharkrite-assessment"
RITE_MARKER_FOLLOWUP="sharkrite-followup-issue"
RITE_MARKER_TEST_COVERS="sharkrite-test-covers"
RITE_MARKER_ENFORCED_BY="sharkrite-enforced-by"
export RITE_MARKER_REVIEW RITE_MARKER_ASSESSMENT RITE_MARKER_FOLLOWUP
export RITE_MARKER_TEST_COVERS RITE_MARKER_ENFORCED_BY
STUB

  # drift-log.sh stub: drift_log_append logs to a file for assertion
  cat > "$_lib/utils/drift-log.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f drift_log_entry_count >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
_DRIFT_VALID_KINDS="addition refinement contradiction test-scope reference-missing"
drift_log_entry_count() { echo 0; }
_drift_entry_path()     { echo ""; }
drift_log_path()        { echo ""; }
drift_log_append() {
  # Log each call for test assertions: "doc kind assertion"
  local _dl_log="${RITE_JIC_CALL_LOG:-/dev/null}"
  printf 'drift_log_append doc=%s kind=%s\n' "${1:-}" "${6:-}" >> "$_dl_log"
  return 0
}
STUB

  # docs-map.sh stub: provides minimal functions for the just-in-case pass
  cat > "$_lib/utils/docs-map.sh" << STUB
#!/bin/bash
set -euo pipefail
if declare -f docs_map_build >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
docs_map_build()   { return 0; }
docs_map_ensure()  { return 0; }
docs_map_path()    { echo "\${RITE_STATE_DIR:-/tmp}/docs-map.tsv"; }
docs_map_adr_links()        { return 0; }
docs_map_enforcing_tests()  { return 0; }
STUB
}

# ---------------------------------------------------------------------------
# Helper: write a minimal docs-map.tsv with one doc and optional fake bats
# fixture. Returns the TSV path.
# ---------------------------------------------------------------------------
_write_fake_docs_map() {
  local _state_dir="$1"
  local _tsv="${_state_dir}/docs-map.tsv"
  # v4 header + one doc row (only file_path column matters for the pass)
  printf '# docs-map v4 sha=abc built=2026-01-01\n' > "$_tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "docs/feature-a.md" "abc" "false" "1" "Overview" "fp1" "feature" "-" "-" "-" >> "$_tsv"
  echo "$_tsv"
}

# ===========================================================================
# Group 1: Clean intersection → no provider call (AC #1)
# ===========================================================================

@test "jic pass: clean intersection makes zero provider calls and returns 0" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_jic_docs_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  local _call_log="$RITE_TEST_TMPDIR/calls.log"
  mkdir -p "$_state_dir"
  touch "$_call_log"

  # Create fake docs-map.tsv with docs/feature-a.md
  local _tsv="$_state_dir/docs-map.tsv"
  printf '# docs-map v4 sha=abc built=2026-01-01\n' > "$_tsv"
  printf '%s\t-\t-\t-\t-\t-\tfeature\t-\t-\t-\n' "docs/feature-a.md" >> "$_tsv"

  # Create a fake bats file that covers lib/utils/foo.sh
  local _bats_dir="$RITE_TEST_TMPDIR/tests"
  mkdir -p "$_bats_dir"
  local _bats="$_bats_dir/test-a.bats"
  printf '#!/usr/bin/env bats\n' > "$_bats"
  printf '# sharkrite-test-covers: lib/utils/foo.sh\n' >> "$_bats"

  # Use a file-based counter: provider_run_prompt_with_timeout is called inside
  # $() in the real implementation, so a shell variable counter always reads 0
  # in the parent (subshell-safe pattern from test 2).
  local _pcount_file="$RITE_TEST_TMPDIR/pcount.txt"
  printf '0\n' > "$_pcount_file"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
export RITE_JIC_CALL_LOG="$_call_log"
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"

# Override docs_map_enforcing_tests to return our fake bats file
docs_map_enforcing_tests() { printf '%s\n' "$_bats"; }
# Override provider_run_prompt_with_timeout to record calls (file-based, subshell-safe)
provider_run_prompt_with_timeout() {
  local _c; _c=\$(cat "$_pcount_file"); printf '%d\n' \$(( _c + 1 )) > "$_pcount_file"
  echo "[]"; return 0
}
# _docs_list_branch_entry_docs: no declared docs for this branch
_docs_list_branch_entry_docs() { return 0; }

# Diff: lib/utils/bar.sh — does NOT match foo.sh
_docs_cross_doc_just_in_case_pass "my-branch" "42" "lib/utils/bar.sh" 2>&1
RUNEOF
)

  run bash "$_runner"
  [ "$status" -eq 0 ]
  # Provider must NOT have been called (file counter must still be 0)
  [ "$(cat "$_pcount_file")" = "0" ]
  # No drift entries should be logged
  [ ! -s "$_call_log" ] || [ "$(wc -l < "$_call_log")" -eq 0 ]
}

# ===========================================================================
# Group 2: Non-empty intersection → triage call + entry written (AC #2)
# ===========================================================================

@test "jic pass: non-empty intersection calls triage once and writes drift entry" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_jic_docs_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  local _call_log="$RITE_TEST_TMPDIR/calls.log"
  mkdir -p "$_state_dir"
  touch "$_call_log"

  local _tsv="$_state_dir/docs-map.tsv"
  printf '# docs-map v4 sha=abc built=2026-01-01\n' > "$_tsv"
  printf '%s\t-\t-\t-\t-\t-\tfeature\t-\t-\t-\n' "docs/feature-a.md" >> "$_tsv"

  # Fake bats covering lib/utils/foo.sh
  local _bats_dir="$RITE_TEST_TMPDIR/tests"
  mkdir -p "$_bats_dir"
  local _bats="$_bats_dir/test-a.bats"
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/utils/foo.sh\n' > "$_bats"

  # Use a file-based counter: provider_run_prompt_with_timeout runs inside a
  # $() subshell so a shell variable counter would always read 0 in the parent.
  local _pcount_file="$RITE_TEST_TMPDIR/pcount.txt"
  printf '0\n' > "$_pcount_file"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
export RITE_JIC_CALL_LOG="$_call_log"
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"

docs_map_enforcing_tests() { printf '%s\n' "$_bats"; }

provider_run_prompt_with_timeout() {
  # Increment file-based counter (subshell-safe)
  local _c; _c=\$(cat "$_pcount_file"); printf '%d\n' \$(( _c + 1 )) > "$_pcount_file"
  # Return JSON indicating docs/feature-a.md is implicated
  printf '[{"doc":"docs/feature-a.md","implicated":true,"kind":"test-scope","assertion":"test coverage changed"}]\n'
  return 0
}
_docs_list_branch_entry_docs() { return 0; }

# Diff: lib/utils/foo.sh — matches the covers path
_docs_cross_doc_just_in_case_pass "my-branch" "42" "lib/utils/foo.sh" 2>&1
RUNEOF
)

  run bash "$_runner"
  [ "$status" -eq 0 ]
  # Provider must have been called exactly once
  [ "$(cat "$_pcount_file")" = "1" ]
  # drift_log_append must have been called for docs/feature-a.md
  [ -s "$_call_log" ]
  grep -q "doc=docs/feature-a.md" "$_call_log"
  grep -q "kind=test-scope" "$_call_log"
}

# ===========================================================================
# Group 3: Declared doc excluded from sweep (AC #3)
# ===========================================================================

@test "jic pass: declared doc with existing entries is excluded from intersection" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_jic_docs_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  local _call_log="$RITE_TEST_TMPDIR/calls.log"
  mkdir -p "$_state_dir"
  touch "$_call_log"

  # Two docs in map: feature-a (declared/has entries) and feature-b (not declared)
  local _tsv="$_state_dir/docs-map.tsv"
  printf '# docs-map v4 sha=abc built=2026-01-01\n' > "$_tsv"
  printf '%s\t-\t-\t-\t-\t-\tfeature\t-\t-\t-\n' "docs/feature-a.md" >> "$_tsv"
  printf '%s\t-\t-\t-\t-\t-\tfeature\t-\t-\t-\n' "docs/feature-b.md" >> "$_tsv"

  # Fake bats for feature-a covering lib/utils/foo.sh
  local _bats_dir="$RITE_TEST_TMPDIR/tests"
  mkdir -p "$_bats_dir"
  local _bats_a="$_bats_dir/test-a.bats"
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/utils/foo.sh\n' > "$_bats_a"

  # Use a file-based counter (subshell-safe — provider_run_prompt_with_timeout
  # is called inside $() in the real implementation).
  local _pcount_file="$RITE_TEST_TMPDIR/pcount.txt"
  printf '0\n' > "$_pcount_file"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
export RITE_JIC_CALL_LOG="$_call_log"
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"

# feature-a has enforcing tests covering foo.sh; feature-b has none
docs_map_enforcing_tests() {
  case "\$1" in
    docs/feature-a.md) printf '%s\n' "$_bats_a" ;;
    *) return 0 ;;
  esac
}

provider_run_prompt_with_timeout() {
  # Increment file-based counter (subshell-safe)
  local _c; _c=\$(cat "$_pcount_file"); printf '%d\n' \$(( _c + 1 )) > "$_pcount_file"
  # If the prompt mentions feature-a, the declared-doc exclusion failed
  if printf '%s\n' "\$1" | grep -q "feature-a"; then
    echo "DECLARED_DOC_LEAKED_INTO_RESIDUE" >&2
  fi
  printf '[]\n'
  return 0
}

# feature-a is the declared doc for this branch
_docs_list_branch_entry_docs() { printf 'docs/feature-a.md\n'; }

# Diff: lib/utils/foo.sh — matches feature-a's covers path
# Provider should NOT be called (feature-a excluded; feature-b has empty fingerprint)
_docs_cross_doc_just_in_case_pass "my-branch" "42" "lib/utils/foo.sh" 2>&1
RUNEOF
)

  run bash "$_runner"
  [ "$status" -eq 0 ]
  # Provider must NOT have been called (no residue after exclusion of declared doc,
  # and feature-b has no enforcing tests so its fingerprint set is empty)
  [ "$(cat "$_pcount_file")" = "0" ]
  # No drift entries written
  [ ! -s "$_call_log" ] || [ "$(wc -l < "$_call_log")" -eq 0 ]
}

# ===========================================================================
# Group 4: Structural — never edits any doc (AC #4)
# ===========================================================================

@test "structural: _docs_cross_doc_just_in_case_pass never calls doc-editing functions" {
  local _src="$RITE_REPO_ROOT/lib/core/docs-command.sh"

  # Find function body boundaries
  local _fn_start _fn_end
  _fn_start=$(grep -n "^_docs_cross_doc_just_in_case_pass()" "$_src" | head -1 | cut -d: -f1 || true)
  [ -n "$_fn_start" ] || { echo "FAIL: _docs_cross_doc_just_in_case_pass not found"; return 1; }

  _fn_end=$(awk -v start="$_fn_start" \
    'NR > start && /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ { print NR; exit }' "$_src" || true)
  [ -n "$_fn_end" ] || _fn_end=$(wc -l < "$_src" || true)

  # The function body must NOT call any editing functions.
  # Skip comment lines — the next function's header comment (which sits between
  # the closing } and the next function definition) mentions _docs_main_entries_pass
  # in its description; that must not trip this assertion.
  local _edit_calls
  _edit_calls=$(awk -v s="$_fn_start" -v e="$_fn_end" \
    'NR > s && NR < e && !/^[[:space:]]*#/ && /_docs_main_entries_pass|docs_directed_update|_mp_raw|_docs_apply/' \
    "$_src" || true)
  if [ -n "${_edit_calls:-}" ]; then
    echo "FAIL: edit function called from _docs_cross_doc_just_in_case_pass:"
    echo "$_edit_calls"
    return 1
  fi

  # Must reference drift_log_append (entry writes are allowed)
  local _entry_call
  _entry_call=$(awk -v s="$_fn_start" -v e="$_fn_end" \
    'NR > s && NR < e && /drift_log_append/' "$_src" || true)
  if [ -z "${_entry_call:-}" ]; then
    echo "FAIL: drift_log_append not found in _docs_cross_doc_just_in_case_pass body"
    return 1
  fi
}

# ===========================================================================
# Group 5: Glob covers-header intersection (unquoted case pattern, SC2254)
# ===========================================================================

@test "jic pass: glob covers-header (lib/utils/*.sh) matches specific file in diff" {
  # Verifies that a bats header 'lib/utils/*.sh' is correctly treated as a glob
  # pattern (not a literal string) when intersected with the diff.  This is the
  # behaviour guarded by the SC2254 disable on the case statement in
  # _docs_jic_covers_for_doc.
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_promote_stubs_base "$_lib"
  _write_jic_docs_stubs "$_lib"

  local _state_dir="$RITE_TEST_TMPDIR/state"
  local _call_log="$RITE_TEST_TMPDIR/calls.log"
  mkdir -p "$_state_dir"
  touch "$_call_log"

  local _tsv="$_state_dir/docs-map.tsv"
  printf '# docs-map v4 sha=abc built=2026-01-01\n' > "$_tsv"
  printf '%s\t-\t-\t-\t-\t-\tfeature\t-\t-\t-\n' "docs/feature-a.md" >> "$_tsv"

  # Bats file declares a GLOB path lib/utils/*.sh (not a literal)
  local _bats_dir="$RITE_TEST_TMPDIR/tests"
  mkdir -p "$_bats_dir"
  local _bats="$_bats_dir/test-glob.bats"
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/utils/*.sh\n' > "$_bats"

  local _pcount_file="$RITE_TEST_TMPDIR/pcount.txt"
  printf '0\n' > "$_pcount_file"

  local _runner
  _runner=$(_write_promote_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_STATE_DIR="$_state_dir"
export RITE_JIC_CALL_LOG="$_call_log"
source "$RITE_REPO_ROOT/lib/core/docs-command.sh"

docs_map_enforcing_tests() { printf '%s\n' "$_bats"; }
provider_run_prompt_with_timeout() {
  local _c; _c=\$(cat "$_pcount_file"); printf '%d\n' \$(( _c + 1 )) > "$_pcount_file"
  printf '[{"doc":"docs/feature-a.md","implicated":true,"kind":"test-scope","assertion":"glob match"}]\n'
  return 0
}
_docs_list_branch_entry_docs() { return 0; }

# Diff: lib/utils/config.sh — matched by the glob lib/utils/*.sh
_docs_cross_doc_just_in_case_pass "my-branch" "42" "lib/utils/config.sh" 2>&1
RUNEOF
)

  run bash "$_runner"
  [ "$status" -eq 0 ]
  # Glob matched → provider must have been called exactly once
  [ "$(cat "$_pcount_file")" = "1" ]
  # Drift entry must have been written for docs/feature-a.md
  [ -s "$_call_log" ]
  grep -q "doc=docs/feature-a.md" "$_call_log"
}
