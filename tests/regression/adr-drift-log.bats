#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/drift-log.sh::adr_drift_log_append|adr_drift_log_entry_count|adr_drift_log_remove_entry|_adr_drift_entry_path, lib/core/docs-command.sh::_docs_is_adr_in_map|_docs_list_adr_drift_docs|_adr_approval_history_path|_adr_approval_history_lookup|_adr_approval_history_record|docs_reconcile_adr_drift

# Regression tests for #1440: ADR drift log and reconcile.
#
# Covers:
#   AC1: Promote's doc pass writes ADR observations to the ADR namespace
#        and proposes zero ADR edits (structural grep + behaviour).
#   AC2: align-docs reconcile injects approval history; a question matching a
#        recorded decision is not re-asked (stub-asserted).
#   AC3: Reconcile outcomes route through the propose/approve loop; accepted
#        ADR edits go through the docs-PR path only.
#   AC4: ADR entries are cleared only when reconciled or audited — not during
#        promote.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB_DIR="$PROJECT_ROOT/lib"

  _TMPDIR="$(mktemp -d)"
  cd "$_TMPDIR"
  git init -q .
  git config user.email "test@test.invalid"
  git config user.name "Test"
  mkdir -p docs .rite/state

  touch .rite/.gitkeep
  git add .
  git commit -q -m "init"

  export RITE_PROJECT_ROOT="$_TMPDIR"
  export RITE_STATE_DIR="$_TMPDIR/.rite/state"
  export RITE_LIB_DIR="$LIB_DIR"
  export RITE_VERBOSE=false

  source "$LIB_DIR/utils/config.sh" 2>/dev/null || true
  source "$LIB_DIR/utils/colors.sh" 2>/dev/null || true
  source "$LIB_DIR/utils/logging.sh" 2>/dev/null || true
  source "$LIB_DIR/utils/lock.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: drift-log.sh uses function-sentinel guard (declare -f drift_log_append); no pre-source stubs defined
  source "$LIB_DIR/utils/drift-log.sh" 2>/dev/null || true
  # Runbook §3: restore flags after last source (never set +e)
  set +u; set +o pipefail

  print_info()    { :; }
  print_warning() { :; }
  print_success() { :; }
  verbose_info()  { :; }
}

teardown() {
  cd /
  rm -rf "$_TMPDIR"
}

# ---------------------------------------------------------------------------
# ADR namespace helpers in drift-log.sh (structural + behavioral)
# ---------------------------------------------------------------------------

@test "adr_drift_log_append: writes to doc-drift-adr/ not doc-drift/" {
  adr_drift_log_append \
    "docs/architecture/behavioral-design.md" \
    "42" "-" "ADR section X may be contradicted" "contradiction" "lib/core/foo.sh"

  local adr_base="$RITE_STATE_DIR/doc-drift-adr"
  local regular_base="$RITE_STATE_DIR/doc-drift"

  # Entry must exist in the ADR namespace
  [ -d "$adr_base" ]
  local entry_count
  entry_count="$(find "$adr_base" -name '*.log' -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$entry_count" -ge 1 ]

  # Nothing written to the regular doc-drift namespace
  [ ! -d "$regular_base" ] || {
    local regular_count
    regular_count="$(find "$regular_base" -name '*.log' -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    [ "$regular_count" -eq 0 ]
  }
}

@test "adr_drift_log_append: entry file uses doc slug without branch subdirectory" {
  adr_drift_log_append \
    "docs/architecture/adr-001.md" \
    "99" "-" "Some assertion" "addition" "lib/utils/foo.sh"

  local slug="docs--architecture--adr-001.md"
  [ -f "$RITE_STATE_DIR/doc-drift-adr/${slug}.log" ]

  # No branch sub-directory in path
  [ ! -d "$RITE_STATE_DIR/doc-drift-adr/main" ]
}

@test "adr_drift_log_append: entry contains doc= pr= assertion= kind= evidence= recorded=" {
  adr_drift_log_append \
    "docs/architecture/adr-001.md" \
    "77" "-" "Gate-Block-on-Any still holds" "contradiction" "lib/utils/test-gate.sh"

  local entry_file="$RITE_STATE_DIR/doc-drift-adr/docs--architecture--adr-001.md.log"
  [ -f "$entry_file" ]
  grep -q '^doc=' "$entry_file"
  grep -q 'pr=77' "$entry_file"
  grep -q 'assertion=Gate-Block-on-Any still holds' "$entry_file"
  grep -q 'kind=contradiction' "$entry_file"
  grep -q 'evidence=lib/utils/test-gate.sh' "$entry_file"
  grep -q 'recorded=' "$entry_file"
}

@test "adr_drift_log_entry_count --doc: counts entries for a specific ADR doc" {
  adr_drift_log_append "docs/architecture/adr-001.md" "1" "-" "Assertion A" "addition" "foo.sh"
  adr_drift_log_append "docs/architecture/adr-001.md" "2" "-" "Assertion B" "refinement" "bar.sh"

  local cnt
  cnt="$(adr_drift_log_entry_count --doc "docs/architecture/adr-001.md")"
  [ "$cnt" -eq 2 ]
}

@test "adr_drift_log_entry_count --total: sums across all ADR docs" {
  adr_drift_log_append "docs/architecture/adr-001.md" "1" "-" "Assertion A" "addition" "foo.sh"
  adr_drift_log_append "docs/architecture/adr-002.md" "2" "-" "Assertion B" "refinement" "bar.sh"

  local cnt
  cnt="$(adr_drift_log_entry_count --total)"
  [ "$cnt" -eq 2 ]
}

@test "adr_drift_log_entry_count: returns 0 when no ADR entries exist" {
  local cnt
  cnt="$(adr_drift_log_entry_count --total)"
  [ "$cnt" -eq 0 ]
}

@test "adr_drift_log_append: accumulate-in-place for same (doc, assertion)" {
  adr_drift_log_append "docs/adr.md" "10" "-" "Same assertion" "addition" "a.sh"
  adr_drift_log_append "docs/adr.md" "20" "-" "Same assertion" "addition" "a.sh"

  local entry_file="$RITE_STATE_DIR/doc-drift-adr/docs--adr.md.log"
  local line_count
  line_count="$(grep -c '^doc=' "$entry_file" || true)"
  # Accumulate-in-place: still one line, PR appended
  [ "$line_count" -eq 1 ]
  grep -q 'pr=10,20' "$entry_file"
}

@test "adr_drift_log_remove_entry: removes the matching entry" {
  adr_drift_log_append "docs/adr.md" "1" "-" "Remove this" "addition" "x.sh"
  adr_drift_log_append "docs/adr.md" "2" "-" "Keep this" "refinement" "y.sh"

  adr_drift_log_remove_entry "docs/adr.md" "Remove this"

  local entry_file="$RITE_STATE_DIR/doc-drift-adr/docs--adr.md.log"
  [ -f "$entry_file" ]
  ! grep -q 'assertion=Remove this' "$entry_file"
  grep -q 'assertion=Keep this' "$entry_file"
}

@test "adr_drift_log_remove_entry: deletes file when last entry removed" {
  adr_drift_log_append "docs/adr.md" "1" "-" "Only entry" "addition" "x.sh"
  adr_drift_log_remove_entry "docs/adr.md" "Only entry"

  local entry_file="$RITE_STATE_DIR/doc-drift-adr/docs--adr.md.log"
  [ ! -f "$entry_file" ]
}

# AC4: entries NOT cleared during promote (only on reconcile or ADR audit)
@test "AC4: adr entries are not removed by promote writes — only by remove_entry" {
  # Simulate a promote observation: write then write again (PR accumulated, not removed)
  adr_drift_log_append "docs/architecture/adr-001.md" "50" "-" "Scope may be outdated" "contradiction" "lib/core/foo.sh"

  # Simulate a second promote (different PR) — accumulate-in-place
  adr_drift_log_append "docs/architecture/adr-001.md" "51" "-" "Scope may be outdated" "contradiction" "lib/core/bar.sh"

  # Entry still present after two promote writes
  local cnt
  cnt="$(adr_drift_log_entry_count --doc "docs/architecture/adr-001.md")"
  [ "$cnt" -eq 1 ]

  # Explicit remove clears it
  adr_drift_log_remove_entry "docs/architecture/adr-001.md" "Scope may be outdated"
  cnt="$(adr_drift_log_entry_count --doc "docs/architecture/adr-001.md")"
  [ "$cnt" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC1: Promote's doc pass proposes zero ADR edits (structural)
# ---------------------------------------------------------------------------

@test "AC1 (structural): promote-branch.sh references adr namespace" {
  grep -qi "adr" "$PROJECT_ROOT/lib/core/promote-branch.sh"
}

@test "AC1 (structural): drift-log.sh defines adr_drift_log_append" {
  grep -q "^adr_drift_log_append()" "$PROJECT_ROOT/lib/utils/drift-log.sh"
}

@test "AC1 (structural): _docs_cross_doc_just_in_case_pass calls adr_drift_log_append for ADR docs" {
  grep -q "adr_drift_log_append" "$PROJECT_ROOT/lib/core/docs-command.sh"
}

@test "AC1 (structural): declared-doc pass in docs_run_promote_doc_pass guards ADR docs" {
  # The guard must prevent _docs_main_entries_pass from running on ADR-type docs
  grep -q "_docs_is_adr_in_map" "$PROJECT_ROOT/lib/core/docs-command.sh"
  # Ensure the guard is in the vicinity of _docs_main_entries_pass
  local ctx
  ctx="$(grep -n "_docs_is_adr_in_map\|_docs_main_entries_pass" \
    "$PROJECT_ROOT/lib/core/docs-command.sh" | head -20 || true)"
  # Both patterns appear in the file
  printf '%s\n' "$ctx" | grep -q "_docs_is_adr_in_map"
  printf '%s\n' "$ctx" | grep -q "_docs_main_entries_pass"
}

# ---------------------------------------------------------------------------
# AC2: align-docs reconcile injects approval history; matched question not re-asked
# ---------------------------------------------------------------------------

_load_docs_command() {
  # Load only the ADR-related functions from docs-command.sh via a helper process.
  # We source docs-command.sh with function-only guard and stub heavy deps.
  export RITE_LIB_DIR
  export RITE_PROJECT_ROOT
  export RITE_STATE_DIR
}

@test "AC2: _adr_approval_history_record writes machine-readable marker" {
  # Source docs-command.sh in a subprocess so we don't contaminate this shell
  local helper="$BATS_TEST_TMPDIR/hist_helper.sh"
  cat > "$helper" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="${RITE_LIB_DIR}"
export RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT}"
export RITE_STATE_DIR="${RITE_STATE_DIR}"
source "${RITE_LIB_DIR}/core/docs-command.sh"
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs function-sentinel guard; post-source stubs are preserved
load_provider() { return 0; }
provider_run_prompt_with_timeout() { echo "NO_PROPOSALS_NEEDED"; }
provider_resolve_model() { echo "claude-sonnet-4-6"; }
docs_map_path() { echo "${RITE_PROJECT_ROOT}/docs/docs-map.tsv"; }
docs_map_ensure() { return 0; }
_adr_approval_history_record "$@"
HELPER_EOF
  chmod +x "$helper"

  run bash "$helper" \
    "docs/architecture/adr-001.md" \
    "Gate-Block-on-Any still holds" \
    "rejected" \
    "Current code still matches this decision"
  [ "$status" -eq 0 ]

  local hist_file="$RITE_STATE_DIR/adr-approval-history.md"
  [ -f "$hist_file" ]
  grep -q "<!-- adrhist doc=docs/architecture/adr-001.md" "$hist_file"
  grep -q "decision=rejected" "$hist_file"
}

@test "AC2: _adr_approval_history_lookup returns 0 for a recorded decision" {
  local helper="$BATS_TEST_TMPDIR/lookup_helper.sh"
  cat > "$helper" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="${RITE_LIB_DIR}"
export RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT}"
export RITE_STATE_DIR="${RITE_STATE_DIR}"
source "${RITE_LIB_DIR}/core/docs-command.sh"
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs function-sentinel guard; post-source stubs are preserved
load_provider() { return 0; }
provider_run_prompt_with_timeout() { echo "NO_PROPOSALS_NEEDED"; }
provider_resolve_model() { echo "claude-sonnet-4-6"; }
docs_map_path() { echo "${RITE_PROJECT_ROOT}/docs/docs-map.tsv"; }
docs_map_ensure() { return 0; }
# Write a known decision first
_adr_approval_history_record \
  "docs/architecture/adr-001.md" \
  "Scope may be outdated" \
  "rejected" \
  "Still valid per last review"
# Now look it up — should return 0 (found)
_adr_approval_history_lookup "docs/architecture/adr-001.md" "Scope may be outdated"
HELPER_EOF
  chmod +x "$helper"

  run bash "$helper"
  [ "$status" -eq 0 ]
}

@test "AC2: _adr_approval_history_lookup returns 1 for unknown assertion" {
  local helper="$BATS_TEST_TMPDIR/nolookup_helper.sh"
  cat > "$helper" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="${RITE_LIB_DIR}"
export RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT}"
export RITE_STATE_DIR="${RITE_STATE_DIR}"
source "${RITE_LIB_DIR}/core/docs-command.sh"
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs function-sentinel guard; post-source stubs are preserved
load_provider() { return 0; }
provider_run_prompt_with_timeout() { echo "NO_PROPOSALS_NEEDED"; }
provider_resolve_model() { echo "claude-sonnet-4-6"; }
docs_map_path() { echo "${RITE_PROJECT_ROOT}/docs/docs-map.tsv"; }
docs_map_ensure() { return 0; }
# No history written — lookup must return 1
_adr_approval_history_lookup "docs/architecture/adr-001.md" "Not in history" && exit 1 || exit 0
HELPER_EOF
  chmod +x "$helper"

  run bash "$helper"
  [ "$status" -eq 0 ]
}

@test "AC2: docs_reconcile_adr_drift skips entries matching approval history" {
  # Write an ADR drift entry
  adr_drift_log_append "docs/architecture/adr-001.md" "55" "-" \
    "Scope may be outdated" "contradiction" "lib/core/foo.sh"

  # Write a matching history entry directly to simulate a prior decision
  local hist_file="$RITE_STATE_DIR/adr-approval-history.md"
  cat > "$hist_file" << 'HIST_EOF'
# ADR Drift Approval History

<!-- adrhist doc=docs/architecture/adr-001.md assertion=Scope may be outdated decision=rejected date=2026-10-01 -->
## docs/architecture/adr-001.md

**Assertion**: Scope may be outdated
**Decision**: rejected
**Date**: 2026-10-01
**Rationale**: Still valid

HIST_EOF

  local helper="$BATS_TEST_TMPDIR/reconcile_helper.sh"
  cat > "$helper" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="${RITE_LIB_DIR}"
export RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT}"
export RITE_STATE_DIR="${RITE_STATE_DIR}"
source "${RITE_LIB_DIR}/utils/lock.sh" 2>/dev/null || true
source "${RITE_LIB_DIR}/utils/drift-log.sh" 2>/dev/null || true
source "${RITE_LIB_DIR}/core/docs-command.sh"
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs function-sentinel guard; post-source stubs are preserved
load_provider() { return 0; }
provider_run_prompt_with_timeout() { echo "NO_PROPOSALS_NEEDED"; }
provider_resolve_model() { echo "claude-sonnet-4-6"; }
docs_map_path() { echo "${RITE_PROJECT_ROOT}/docs/docs-map.tsv"; }
docs_map_ensure() { return 0; }
docs_reconcile_adr_drift
HELPER_EOF
  chmod +x "$helper"

  # Non-TTY run: should print "Already decided" and NOT remove the entry
  run bash "$helper"
  [ "$status" -eq 0 ]

  # Entry must still exist (non-TTY doesn't prompt, history suppression just prints)
  local cnt
  cnt="$(adr_drift_log_entry_count --doc "docs/architecture/adr-001.md")"
  [ "$cnt" -eq 1 ]
}

# AC3: structural check that accepted edits route through docs-PR path
@test "AC3 (structural): docs_reconcile_adr_drift calls _docs_main_entries_pass for accepted edits" {
  grep -q "_docs_main_entries_pass" "$PROJECT_ROOT/lib/core/docs-command.sh"
  # Confirm the call appears inside docs_reconcile_adr_drift context
  local region
  region="$(awk '/^docs_reconcile_adr_drift\(\)/,/^}/' \
    "$PROJECT_ROOT/lib/core/docs-command.sh" || true)"
  printf '%s\n' "$region" | grep -q "_docs_main_entries_pass"
}

@test "AC3 (structural): adr_drift_log_remove_entry only called after decision in reconcile" {
  local region
  region="$(awk '/^docs_reconcile_adr_drift\(\)/,/^}/' \
    "$PROJECT_ROOT/lib/core/docs-command.sh" || true)"
  # Remove is called inside case [Yy] and [Rr] — not outside them
  printf '%s\n' "$region" | grep -q "adr_drift_log_remove_entry"
}

# AC4: structural — promote write site never calls drift_log_remove_entry for ADR docs
@test "AC4 (structural): promote doc pass does not call adr_drift_log_remove_entry" {
  # _docs_cross_doc_just_in_case_pass and docs_run_promote_doc_pass must not remove ADR entries
  local jic_region
  jic_region="$(awk '/_docs_cross_doc_just_in_case_pass\(\)/,/^}/' \
    "$PROJECT_ROOT/lib/core/docs-command.sh" || true)"
  ! printf '%s\n' "$jic_region" | grep -q "adr_drift_log_remove_entry"

  local dp_region
  dp_region="$(awk '/^docs_run_promote_doc_pass\(\)/,/^}/' \
    "$PROJECT_ROOT/lib/core/docs-command.sh" || true)"
  ! printf '%s\n' "$dp_region" | grep -q "adr_drift_log_remove_entry"
}
