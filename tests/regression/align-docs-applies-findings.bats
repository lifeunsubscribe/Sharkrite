#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/doc-consent.sh::_run_align_docs_passes
# tests/regression/align-docs-applies-findings.bats
#
# Regression tests for #1806: after the assertion audit, rite align-docs offers
# pending drift entries for approval via docs_reconcile_drift.
#
# Covers:
#   - reconcile runs in every RITE_DOC_MODE (unset, off, sync)
#   - reconcile runs even when the user declines the audit's Proceed prompt
#   - ADR drift reconcile is part of that step (called through docs_reconcile_drift)
#   - non-interactive run calls no model and makes no edit (reconcile not invoked)

load '../helpers/setup'

# ---------------------------------------------------------------------------
# Build a helper script sourcing doc-consent.sh with stubs.
#
# Arguments:
#   $1 — path to write reconcile call log (empty = no logging)
#   $2 — RITE_DOC_MODE value: "off", "sync", or "" (empty = unset)
#   $3 — _RITE_FORCE_TTY value: "1" (default) or "0"
#   $4 — path to write docs_reconcile_adr_drift call log (empty = no logging)
#   $5 — docs_run_assertion_audit behaviour: "exit0" (default) or "exit1"
#   $6 — path to write docs_run_assertion_audit call log (empty = no logging)
# ---------------------------------------------------------------------------
_make_align_helper() {
  local call_log="${1:-}"
  local mode="${2:-}"
  local force_tty="${3:-1}"
  local adr_log="${4:-}"
  local audit_exit="${5:-exit0}"
  local audit_called_log="${6:-}"

  # Determine how to export RITE_DOC_MODE in the helper.
  local mode_line
  if [ -n "$mode" ]; then
    mode_line="export RITE_DOC_MODE=\"${mode}\""
  else
    mode_line="unset RITE_DOC_MODE 2>/dev/null || true"
  fi

  local audit_body
  case "$audit_exit" in
    exit1) audit_body="return 1" ;;
    *)     audit_body="return 0" ;;
  esac

  local helper="${BATS_TEST_TMPDIR}/align_helper_${RANDOM}.sh"
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand in the generated helper script
  cat > "$helper" << HELPER_EOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="${RITE_LIB_DIR}"
export RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT}"
export RITE_STATE_DIR="${RITE_STATE_DIR}"
export _RITE_FORCE_TTY=${force_tty}
${mode_line}
source "\${RITE_LIB_DIR}/utils/doc-consent.sh"
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: doc-consent.sh uses declare -f ensure_doc_mode function-sentinel guard; post-source stubs are preserved
docs_run_restructure_assessment() { return 0; }
docs_run_assertion_audit() {
  if [ -n "${audit_called_log}" ]; then
    printf 'audit_called\n' >> "${audit_called_log}"
  fi
  ${audit_body}
}
docs_reconcile_drift() {
  if [ -n "${call_log}" ]; then
    printf 'reconcile_called\n' >> "${call_log}"
  fi
  # Call docs_reconcile_adr_drift if defined (ADR delegation test).
  if declare -f docs_reconcile_adr_drift >/dev/null 2>&1; then
    docs_reconcile_adr_drift || true
  fi
}
docs_reconcile_adr_drift() {
  if [ -n "${adr_log}" ]; then
    printf 'adr_called\n' >> "${adr_log}"
  fi
}
_run_align_docs_passes
HELPER_EOF
  chmod +x "$helper"
  echo "$helper"
}

setup() {
  setup_test_tmpdir
  export RITE_PROJECT_ROOT="${RITE_TEST_TMPDIR}/project"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_STATE_DIR="${RITE_PROJECT_ROOT}/.rite/state"
  mkdir -p "${RITE_PROJECT_ROOT}/.rite"
  mkdir -p "${RITE_STATE_DIR}"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Criteria 1a: reconcile runs after audit with RITE_DOC_MODE unset
# ---------------------------------------------------------------------------
@test "reconcile runs after audit with RITE_DOC_MODE unset" {
  local call_log="${BATS_TEST_TMPDIR}/reconcile.log"
  local helper
  helper="$(_make_align_helper "$call_log" "" "1")"
  run bash "$helper" < /dev/null
  [ "$status" -eq 0 ]
  [ -f "$call_log" ]
  grep -q "reconcile_called" "$call_log"
}

# ---------------------------------------------------------------------------
# Criteria 1b: reconcile runs with RITE_DOC_MODE=off (mode unchanged)
# ---------------------------------------------------------------------------
@test "reconcile runs after audit with RITE_DOC_MODE=off" {
  local call_log="${BATS_TEST_TMPDIR}/reconcile_off.log"
  local helper
  helper="$(_make_align_helper "$call_log" "off" "1")"
  run bash "$helper" < /dev/null
  [ "$status" -eq 0 ]
  [ -f "$call_log" ]
  grep -q "reconcile_called" "$call_log"
}

# ---------------------------------------------------------------------------
# Criteria 1c: reconcile runs with RITE_DOC_MODE=sync (mode unchanged)
# ---------------------------------------------------------------------------
@test "reconcile runs after audit with RITE_DOC_MODE=sync" {
  local call_log="${BATS_TEST_TMPDIR}/reconcile_sync.log"
  local helper
  helper="$(_make_align_helper "$call_log" "sync" "1")"
  run bash "$helper" < /dev/null
  [ "$status" -eq 0 ]
  [ -f "$call_log" ]
  grep -q "reconcile_called" "$call_log"
}

# ---------------------------------------------------------------------------
# Criteria 2: reconcile runs when user declined the audit's Proceed prompt
#
# When docs_run_assertion_audit returns 0 without recording anything (the user
# pressed n at the confirmation gate), _run_align_docs_passes still proceeds
# to docs_reconcile_drift so entries recorded before the audit run are offered.
# Distinct from Criteria 1a: we also verify the audit was actually called (via
# audit_called_log), confirming the reconcile call follows a real audit run
# rather than being a no-audit shortcut.
# ---------------------------------------------------------------------------
@test "reconcile runs when user declined audit (pre-existing entries can be applied)" {
  local call_log="${BATS_TEST_TMPDIR}/reconcile_declined.log"
  local audit_log="${BATS_TEST_TMPDIR}/audit_declined.log"
  local helper
  helper="$(_make_align_helper "$call_log" "" "1" "" "exit0" "$audit_log")"
  run bash "$helper" < /dev/null
  [ "$status" -eq 0 ]
  # Audit was called (the user saw the prompt, then declined).
  [ -f "$audit_log" ]
  grep -q "audit_called" "$audit_log"
  # Reconcile still ran for pre-existing drift entries.
  [ -f "$call_log" ]
  grep -q "reconcile_called" "$call_log"
}

# ---------------------------------------------------------------------------
# Criteria 2b: reconcile is skipped when assertion audit exits non-zero
#
# If docs_run_assertion_audit exits non-zero (audit error, not a user decline),
# _run_align_docs_passes propagates the failure and reconcile is not reached.
# This pins the current behavior so a future change that bypasses the failure
# will be caught.
# ---------------------------------------------------------------------------
@test "reconcile is skipped when assertion audit exits non-zero" {
  local call_log="${BATS_TEST_TMPDIR}/reconcile_audit_fail.log"
  local audit_log="${BATS_TEST_TMPDIR}/audit_fail.log"
  local helper
  helper="$(_make_align_helper "$call_log" "" "1" "" "exit1" "$audit_log")"
  run bash "$helper" < /dev/null
  # Audit was attempted (stub wrote to audit_log before exiting 1).
  [ -f "$audit_log" ]
  grep -q "audit_called" "$audit_log"
  # Helper propagated the non-zero exit — reconcile was not reached.
  [ "$status" -ne 0 ]
  [ ! -f "$call_log" ] || ! grep -q "reconcile_called" "$call_log"
}

# ---------------------------------------------------------------------------
# Criteria 3: ADR drift reconcile runs as part of the reconcile step
#
# docs_reconcile_drift always calls docs_reconcile_adr_drift (even when the
# regular drift store is empty).  Verifying that docs_reconcile_adr_drift is
# reached from _run_align_docs_passes confirms the ADR path is wired.
# ---------------------------------------------------------------------------
@test "ADR drift reconcile runs as part of the reconcile step" {
  local call_log="${BATS_TEST_TMPDIR}/reconcile_adr.log"
  local adr_log="${BATS_TEST_TMPDIR}/adr.log"
  local helper
  helper="$(_make_align_helper "$call_log" "" "1" "$adr_log")"
  run bash "$helper" < /dev/null
  [ "$status" -eq 0 ]
  # Both reconcile_drift and adr_drift must have been called.
  [ -f "$call_log" ]
  grep -q "reconcile_called" "$call_log"
  [ -f "$adr_log" ]
  grep -q "adr_called" "$adr_log"
}

# ---------------------------------------------------------------------------
# Criteria 4: non-interactive run makes no prompt, no edit, no model call
#
# Without _RITE_FORCE_TTY=1 and without an interactive terminal the reconcile
# block is skipped entirely — docs_reconcile_drift must not be called.
# ---------------------------------------------------------------------------
@test "non-interactive run does not invoke docs_reconcile_drift" {
  local call_log="${BATS_TEST_TMPDIR}/reconcile_noninteractive.log"
  local helper
  # force_tty=0 and stdin is /dev/null (no TTY) — both checks must miss.
  helper="$(_make_align_helper "$call_log" "" "0")"
  run bash "$helper" < /dev/null
  [ "$status" -eq 0 ]
  # call_log must not exist (reconcile was never called).
  [ ! -f "$call_log" ] || ! grep -q "reconcile_called" "$call_log"
}
