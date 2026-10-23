#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite, lib/core/docs-command.sh
# tests/regression/rite-docs-dispatch.bats
#
# Tests for the `rite docs` verb (#1045): parser wiring, dispatch key,
# state resolution (_docs_resolve_state), consent flow, audit routing,
# directed-update seam, and self-heal behavior.
#
# All LLM provider calls are stubbed via post-source function overrides.
# The stub helper sourced docs-command.sh with the real lib so all
# structural dependencies load; stubs are re-defined after the source
# to override the real implementations.

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
  export FAKE_PROJECT

  # Write a helper script that sources docs-command.sh with stubs.
  # Single-quoted heredoc: variable refs (${DOCS_CMD} etc.) stay literal and are
  # resolved from the environment when the helper runs, not at write time.
  _DOCS_HELPER="$(mktemp)"
  cat > "$_DOCS_HELPER" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail
source "${DOCS_CMD}"

# Override external-call functions AFTER source (last definition wins in bash).
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs sentinel guard; stubs intentionally defined after source to override real implementations
load_provider() { return 0; }
provider_run_prompt_with_timeout() { echo "${DOCS_AUDIT_OUTPUT:-NOTHING_FOUND}"; }
provider_resolve_model() { echo "claude-sonnet-4-6"; }
docs_map_build() {
  echo "MAP_BUILT" >> "${RITE_PROJECT_ROOT}/.rite/state/docs-map-build.calls"
  touch "${RITE_PROJECT_ROOT}/.rite/state/docs-map.tsv"
}
docs_map_path() { echo "${RITE_PROJECT_ROOT}/.rite/state/docs-map.tsv"; }
docs_map_ensure() {
  touch "${RITE_PROJECT_ROOT}/.rite/state/docs-map.tsv"
  return 0
}
record_doc_mode() {
  echo "$1" >> "${RITE_PROJECT_ROOT}/.rite/state/recorded-mode.log"
}
drift_log_path() { echo "${RITE_PROJECT_ROOT}/docs/sharkrite-drift-log.md"; }
drift_log_append() {
  echo "drift_log_append:$*" >> "${RITE_PROJECT_ROOT}/.rite/state/drift-log.calls"
}
drift_log_entry_count() { echo "0"; }

rite_docs "$@"
HELPER_EOF
  chmod +x "$_DOCS_HELPER"
  export _DOCS_HELPER
}

teardown() {
  rm -rf "${FAKE_PROJECT:-}"
  rm -f "${_DOCS_HELPER:-}"
}

# ---------------------------------------------------------------------------
# Static checks — structural invariants verified by grep
# ---------------------------------------------------------------------------

@test "bin/rite parser has docs) case before ARGS catch-all" {
  local count
  count=$(grep -c '^    docs)$' "$PROJECT_ROOT/bin/rite" || true)
  [ "$count" -ge 1 ]
}

@test "resolve_dispatch_key returns 'docs' for docs mode" {
  eval "$(sed -n '/^# --- resolve_dispatch_key (pure)/,/^# --- end resolve_dispatch_key/p' "$PROJECT_ROOT/bin/rite")"
  eval "$(sed -n '/^# --- resolve_dispatch_plan (pure)/,/^# --- end resolve_dispatch_plan/p' "$PROJECT_ROOT/bin/rite")"
  set +u; set +o pipefail

  run resolve_dispatch_key "docs" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "docs" ]
}

@test "resolve_dispatch_plan names docs-command.sh for docs mode" {
  eval "$(sed -n '/^# --- resolve_dispatch_key (pure)/,/^# --- end resolve_dispatch_key/p' "$PROJECT_ROOT/bin/rite")"
  eval "$(sed -n '/^# --- resolve_dispatch_plan (pure)/,/^# --- end resolve_dispatch_plan/p' "$PROJECT_ROOT/bin/rite")"
  set +u; set +o pipefail

  run resolve_dispatch_plan "docs"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "docs-command.sh"
}

@test "CLAUDE.md architecture section references docs-command.sh" {
  local count
  count=$(grep -c 'docs-command.sh' "$PROJECT_ROOT/CLAUDE.md" || true)
  [ "$count" -ge 1 ]
}

@test "docs-command.sh uses provider_resolve_model doc_assessment and no bare empty model" {
  # Must call provider_resolve_model with the doc_assessment role (Rule 31/32 compliance)
  local doc_assess_count
  doc_assess_count=$(grep -c 'provider_resolve_model doc_assessment' "$PROJECT_ROOT/lib/core/docs-command.sh" || true)
  [ "$doc_assess_count" -ge 1 ]

  # Must not pass empty string "" as the model arg (PROVIDER_MODEL_FALLTHROUGH lint rule)
  local bare_count
  bare_count=$(grep -c 'provider_run_prompt_with_timeout.*""' "$PROJECT_ROOT/lib/core/docs-command.sh" || true)
  [ "$bare_count" -eq 0 ]
}

@test "docs-command.sh re-source guard uses declare -f rite_docs sentinel" {
  local count
  count=$(grep -c 'declare -f rite_docs' "$PROJECT_ROOT/lib/core/docs-command.sh" || true)
  [ "$count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# _docs_resolve_state unit tests — state logic only, no LLM calls
# ---------------------------------------------------------------------------

@test "_docs_resolve_state: no RITE_DOC_MODE → never-run" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$PROJECT_ROOT/lib'
    export RITE_PROJECT_ROOT='$FAKE_PROJECT'
    export RITE_DATA_DIR='.rite'
    unset RITE_DOC_MODE 2>/dev/null || true
    source '$PROJECT_ROOT/lib/core/docs-command.sh'
    _docs_resolve_state
  "
  [ "$status" -eq 0 ]
  [ "$output" = "never-run" ]
}

@test "_docs_resolve_state: a leftover .rite/doc-sync.md is ignored (retired switch)" {
  touch "$FAKE_PROJECT/.rite/doc-sync.md"
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$PROJECT_ROOT/lib'
    export RITE_PROJECT_ROOT='$FAKE_PROJECT'
    export RITE_DATA_DIR='.rite'
    unset RITE_DOC_MODE 2>/dev/null || true
    source '$PROJECT_ROOT/lib/core/docs-command.sh'
    _docs_resolve_state
  "
  [ "$status" -eq 0 ]
  [ "$output" = "never-run" ]
}

@test "_docs_resolve_state: RITE_DOC_MODE=off → never-run (asks again, like first time)" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$PROJECT_ROOT/lib'
    export RITE_PROJECT_ROOT='$FAKE_PROJECT'
    export RITE_DATA_DIR='.rite'
    export RITE_DOC_MODE='off'
    source '$PROJECT_ROOT/lib/core/docs-command.sh'
    _docs_resolve_state
  "
  [ "$status" -eq 0 ]
  [ "$output" = "never-run" ]
}

@test "_docs_resolve_state: RITE_DOC_MODE=changelog and no file → changelog" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$PROJECT_ROOT/lib'
    export RITE_PROJECT_ROOT='$FAKE_PROJECT'
    export RITE_DATA_DIR='.rite'
    export RITE_DOC_MODE='changelog'
    source '$PROJECT_ROOT/lib/core/docs-command.sh'
    _docs_resolve_state
  "
  [ "$status" -eq 0 ]
  [ "$output" = "changelog" ]
}

@test "_docs_resolve_state: RITE_DOC_MODE=sync → sync (no doc-sync.md needed)" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$PROJECT_ROOT/lib'
    export RITE_PROJECT_ROOT='$FAKE_PROJECT'
    export RITE_DATA_DIR='.rite'
    export RITE_DOC_MODE='sync'
    source '$PROJECT_ROOT/lib/core/docs-command.sh'
    _docs_resolve_state
  "
  [ "$status" -eq 0 ]
  [ "$output" = "sync" ]
}

# ---------------------------------------------------------------------------
# rite_docs dispatch tests — consent flow, audit, directed-update seam
# All tests run with < /dev/null so prompts take the default-no branch.
# ---------------------------------------------------------------------------

@test "never-run + non-TTY (consent-no branch) records off" {
  # Explicitly clear RITE_DOC_MODE: the gate runs bats in a shell that may have
  # RITE_DOC_MODE=changelog exported (set by ensure_doc_mode in workflow-runner),
  # which would redirect to the audit path and never call record_doc_mode.
  run env \
    RITE_LIB_DIR="$PROJECT_ROOT/lib" \
    RITE_PROJECT_ROOT="$FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOG_AUTO=false \
    RITE_DOC_MODE= \
    bash "$_DOCS_HELPER" < /dev/null 2>&1
  [ "$status" -eq 0 ]
  [ -f "$FAKE_PROJECT/.rite/state/recorded-mode.log" ]
  grep -qx "off" "$FAKE_PROJECT/.rite/state/recorded-mode.log"
}

@test "never-run + non-TTY consent-no branch builds docs map" {
  run env \
    RITE_LIB_DIR="$PROJECT_ROOT/lib" \
    RITE_PROJECT_ROOT="$FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_DOC_MODE= \
    RITE_LOG_AUTO=false \
    bash "$_DOCS_HELPER" < /dev/null 2>&1
  [ "$status" -eq 0 ]
  [ -f "$FAKE_PROJECT/.rite/state/docs-map-build.calls" ]
  grep -q "MAP_BUILT" "$FAKE_PROJECT/.rite/state/docs-map-build.calls"
}

@test "never-run + non-TTY consent-no branch does NOT create .rite/doc-sync.md" {
  run env \
    RITE_LIB_DIR="$PROJECT_ROOT/lib" \
    RITE_PROJECT_ROOT="$FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_DOC_MODE= \
    RITE_LOG_AUTO=false \
    bash "$_DOCS_HELPER" < /dev/null 2>&1
  [ "$status" -eq 0 ]
  [ ! -f "$FAKE_PROJECT/.rite/doc-sync.md" ]
}

@test "changelog state + no args → audit path (not directed-update)" {
  # Pre-create docs-map.tsv so _docs_ensure_map skips rebuild
  touch "$FAKE_PROJECT/.rite/state/docs-map.tsv"
  run env \
    RITE_LIB_DIR="$PROJECT_ROOT/lib" \
    RITE_PROJECT_ROOT="$FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_DOC_MODE="changelog" \
    RITE_LOG_AUTO=false \
    bash "$_DOCS_HELPER" < /dev/null 2>&1
  [ "$status" -eq 0 ]
  # Audit completed (NOTHING_FOUND from stub) — no directed-update sentinel in output
  ! echo "$output" | grep -q "Directed doc updates land"
}

@test "sync state + no args → audit path reports only (no tail-offer)" {
  # doc-sync.md present = sync state
  touch "$FAKE_PROJECT/.rite/doc-sync.md"
  touch "$FAKE_PROJECT/.rite/state/docs-map.tsv"
  run env \
    RITE_LIB_DIR="$PROJECT_ROOT/lib" \
    RITE_PROJECT_ROOT="$FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_LOG_AUTO=false \
    bash "$_DOCS_HELPER" < /dev/null 2>&1
  [ "$status" -eq 0 ]
  # Sync mode audit reports only — the tail-offer ("changelog" only) must not appear
  ! echo "$output" | grep -q "Directed doc updates land"
}

@test "any state + instructions routes to directed-update engine" {
  touch "$FAKE_PROJECT/.rite/state/docs-map.tsv"
  run env \
    RITE_LIB_DIR="$PROJECT_ROOT/lib" \
    RITE_PROJECT_ROOT="$FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_DOC_MODE="changelog" \
    RITE_LOG_AUTO=false \
    bash "$_DOCS_HELPER" "update the architecture section" < /dev/null 2>&1
  # The real _docs_update_engine is now implemented (#1049 landed).
  # Provider call is stubbed to return "NOTHING_FOUND" → engine prints "Generating doc proposals"
  # then "No actionable proposals in LLM output" and exits 0.
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Generating doc proposals"
}

# ---------------------------------------------------------------------------
# Self-heal: missing map and mismatch state
# ---------------------------------------------------------------------------

@test "self-heal: RITE_DOCS_MAP_AUTO=false + missing map + non-TTY exits 1" {
  # Map file absent + auto-rebuild disabled + non-TTY → _docs_ensure_map returns 1
  run env \
    RITE_LIB_DIR="$PROJECT_ROOT/lib" \
    RITE_PROJECT_ROOT="$FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_DOC_MODE="changelog" \
    RITE_DOCS_MAP_AUTO="false" \
    RITE_LOG_AUTO=false \
    bash "$_DOCS_HELPER" < /dev/null 2>&1
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Audit DRIFT-parsing and drift-log appender tests (#1045 acceptance criteria)
# ---------------------------------------------------------------------------

@test "audit: DRIFT line from provider appended via drift-log stub" {
  # Minimal map with one doc entry so the inventory is non-empty
  mkdir -p "$FAKE_PROJECT/docs"
  printf 'docs/arch.md\t1\t## Overview\t3\tOverview\n' \
    > "$FAKE_PROJECT/.rite/state/docs-map.tsv"
  printf '# Arch\n\n## Overview\ncontent\n' > "$FAKE_PROJECT/docs/arch.md"

  run env \
    RITE_LIB_DIR="$PROJECT_ROOT/lib" \
    RITE_PROJECT_ROOT="$FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_DOC_MODE="changelog" \
    DOCS_AUDIT_OUTPUT='DRIFT: docs/arch.md — "Overview" — section describes old behavior' \
    RITE_LOG_AUTO=false \
    bash "$_DOCS_HELPER" < /dev/null 2>&1
  [ "$status" -eq 0 ]
  [ -f "$FAKE_PROJECT/.rite/state/drift-log.calls" ]
  grep -q "drift_log_append" "$FAKE_PROJECT/.rite/state/drift-log.calls"
}

@test "audit: suspected inaccuracy text is passed to drift_log_append" {
  mkdir -p "$FAKE_PROJECT/docs"
  printf 'docs/arch.md\t1\t## Overview\t3\tOverview\n' \
    > "$FAKE_PROJECT/.rite/state/docs-map.tsv"
  printf '# Arch\n\n## Overview\ncontent\n' > "$FAKE_PROJECT/docs/arch.md"

  run env \
    RITE_LIB_DIR="$PROJECT_ROOT/lib" \
    RITE_PROJECT_ROOT="$FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_DOC_MODE="changelog" \
    DOCS_AUDIT_OUTPUT='DRIFT: docs/arch.md — "Overview" — section describes old behavior' \
    RITE_LOG_AUTO=false \
    bash "$_DOCS_HELPER" < /dev/null 2>&1
  [ "$status" -eq 0 ]
  grep -q "section describes old behavior" "$FAKE_PROJECT/.rite/state/drift-log.calls"
}

@test "audit: NOTHING_FOUND from provider skips drift_log_append" {
  mkdir -p "$FAKE_PROJECT/docs"
  printf 'docs/arch.md\t1\t## Overview\t3\tOverview\n' \
    > "$FAKE_PROJECT/.rite/state/docs-map.tsv"
  printf '# Arch\n\n## Overview\ncontent\n' > "$FAKE_PROJECT/docs/arch.md"

  run env \
    RITE_LIB_DIR="$PROJECT_ROOT/lib" \
    RITE_PROJECT_ROOT="$FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    RITE_DOC_MODE="changelog" \
    DOCS_AUDIT_OUTPUT="NOTHING_FOUND" \
    RITE_LOG_AUTO=false \
    bash "$_DOCS_HELPER" < /dev/null 2>&1
  [ "$status" -eq 0 ]
  [ ! -f "$FAKE_PROJECT/.rite/state/drift-log.calls" ]
}
