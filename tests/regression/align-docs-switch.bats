#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/doc-consent.sh, bin/rite
# tests/regression/align-docs-switch.bats
#
# Regression tests for #1424 and #1805: `rite align-docs` as the audit entry
# point and on/off switch for doc drift tracking.
#
# Tests cover:
#   - run_align_docs_switch: runs passes in every state (unset, off, sync) without prompting
#   - run_align_docs_switch --disable: records off
#   - run_align_docs_switch --enable: records sync, works without a terminal
#   - Structural: prompt function is gone; rite docs and --init no longer have enable prompts
#   - bin/rite dispatch: align-docs routes to run_align_docs_switch

load '../helpers/setup'

setup() {
  setup_test_tmpdir
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/project"
  export RITE_DATA_DIR=".rite"
  mkdir -p "$RITE_PROJECT_ROOT/.rite"
  printf '# .rite/config\n' > "$RITE_PROJECT_ROOT/.rite/config"
  export RITE_INSTALL_DIR="$RITE_REPO_ROOT"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_STATE_DIR="$RITE_PROJECT_ROOT/.rite/state"
  mkdir -p "$RITE_STATE_DIR"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Library shape
# ---------------------------------------------------------------------------

@test "doc-consent.sh defines run_align_docs_switch after source" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    declare -f run_align_docs_switch >/dev/null && echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# every state: plain rite align-docs runs passes without prompting
# ---------------------------------------------------------------------------

@test "every state: run_align_docs_switch with mode unset exits 0 without prompting" {
  # Non-TTY: passes skip with an info message (TTY guard in _run_align_docs_passes).
  # No prompt, no mode change.
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    unset RITE_DOC_MODE 2>/dev/null || true
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    run_align_docs_switch
    echo \"mode=\${RITE_DOC_MODE:-}\"
  " < /dev/null
  [ "$status" -eq 0 ]
  # Must not change the mode
  [[ "$output" != *"mode=sync"* ]]
  [[ "$output" != *"mode=off"* ]]
  # Config must have no RITE_DOC_MODE= line written
  [ "$(grep -c '^RITE_DOC_MODE=' "$RITE_PROJECT_ROOT/.rite/config" || true)" -eq 0 ]
}

@test "every state: run_align_docs_switch with mode=off exits 0 without prompting" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export RITE_DOC_MODE=off
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    run_align_docs_switch
    echo \"mode=\${RITE_DOC_MODE:-}\"
  " < /dev/null
  [ "$status" -eq 0 ]
  # Mode must remain off (not changed by plain align-docs)
  [[ "$output" == *"mode=off"* ]]
}

@test "every state: run_align_docs_switch with mode=sync runs both passes" {
  # Verifies the passes are invoked regardless of consent state.
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export RITE_DOC_MODE=sync
    export _RITE_FORCE_TTY=1
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    docs_run_restructure_assessment() { echo 'RESTRUCTURE_RAN'; }
    docs_run_assertion_audit() { echo 'AUDIT_RAN'; }
    run_align_docs_switch
  " < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESTRUCTURE_RAN"* ]]
  [[ "$output" == *"AUDIT_RAN"* ]]
}

# ---------------------------------------------------------------------------
# --disable: records off and restores first-run semantics
# ---------------------------------------------------------------------------

@test "run_align_docs_switch --disable records off when mode is sync" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export RITE_DOC_MODE=sync
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    run_align_docs_switch --disable
    grep '^RITE_DOC_MODE=' '$RITE_PROJECT_ROOT/.rite/config' || true
  " < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *'RITE_DOC_MODE="off"'* ]]
}

@test "run_align_docs_switch --disable exits 0" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export RITE_DOC_MODE=sync
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    run_align_docs_switch --disable
  " < /dev/null
  [ "$status" -eq 0 ]
}

@test "after --disable, _docs_resolve_state returns never-run (rite docs audit path)" {
  # off maps to never-run in _docs_resolve_state — rite docs uses never-run to show
  # the prompt message; rite align-docs itself ignores this state and always runs passes.
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_DOC_MODE=off
    source '$RITE_REPO_ROOT/lib/core/docs-command.sh'
    _docs_resolve_state
  "
  [ "$status" -eq 0 ]
  [ "$output" = "never-run" ]
}

# --disable works in non-TTY (no prompt needed)
@test "run_align_docs_switch --disable in non-TTY records off" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export RITE_DOC_MODE=changelog
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    run_align_docs_switch --disable
    echo \"mode=\${RITE_DOC_MODE:-}\"
  " < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=off"* ]]
}

# ---------------------------------------------------------------------------
# Already-enabled: exits 0 without prompting
# ---------------------------------------------------------------------------

@test "run_align_docs_switch when mode=sync exits 0 without prompting" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export RITE_DOC_MODE=sync
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    run_align_docs_switch
  " < /dev/null
  [ "$status" -eq 0 ]
}

@test "run_align_docs_switch when mode=sync runs both align-docs passes" {
  # Verifies the already-enabled path invokes _run_align_docs_passes (restructure
  # assessment + assertion audit). Uses _RITE_FORCE_TTY=1 to satisfy the TTY guard
  # inside _run_align_docs_passes when stdin is /dev/null. Stubs are defined after
  # source so the function-sentinel re-source guard on doc-consent.sh cannot
  # overwrite them.
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export RITE_DOC_MODE=sync
    export _RITE_FORCE_TTY=1
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    docs_run_restructure_assessment() { echo 'RESTRUCTURE_RAN'; }
    docs_run_assertion_audit() { echo 'AUDIT_RAN'; }
    run_align_docs_switch
  " < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESTRUCTURE_RAN"* ]]
  [[ "$output" == *"AUDIT_RAN"* ]]
}

# ---------------------------------------------------------------------------
# enable: --enable records sync and works without a terminal
# ---------------------------------------------------------------------------

@test "--enable records sync when mode is unset" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    unset RITE_DOC_MODE 2>/dev/null || true
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    run_align_docs_switch --enable
    grep '^RITE_DOC_MODE=' '$RITE_PROJECT_ROOT/.rite/config' || true
  " < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *'RITE_DOC_MODE="sync"'* ]]
}

@test "--enable records sync when mode is off (re-enables)" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export RITE_DOC_MODE=off
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    run_align_docs_switch --enable
    grep '^RITE_DOC_MODE=' '$RITE_PROJECT_ROOT/.rite/config' || true
  " < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *'RITE_DOC_MODE="sync"'* ]]
}

@test "--enable exits 0 in non-TTY (works without a terminal)" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    unset RITE_DOC_MODE 2>/dev/null || true
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    run_align_docs_switch --enable
  " < /dev/null
  [ "$status" -eq 0 ]
}

@test "--enable with a doc name exits 1" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    run_align_docs_switch --enable behavioral-design
  " < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not accept doc names"* ]]
}

# ---------------------------------------------------------------------------
# Structural: "run again" message removed (#1654)
# ---------------------------------------------------------------------------

@test "doc-consent.sh no longer contains the 'run again' message" {
  count=$(grep -c "again to start" \
    "$RITE_REPO_ROOT/lib/utils/doc-consent.sh" || true)
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Structural: prompt function gone; --enable/--disable are the mode-change path
# ---------------------------------------------------------------------------

@test "_align_docs_prompt_and_record is gone (prompt removed in #1805)" {
  count=$(grep -c "_align_docs_prompt_and_record" \
    "$RITE_REPO_ROOT/lib/utils/doc-consent.sh" || true)
  [ "$count" -eq 0 ]
}

@test "run_align_docs_switch does not contain 'read -p' (no prompt)" {
  # Only --enable/--disable change mode; the plain path never prompts.
  local body
  body="$(declare -f run_align_docs_switch 2>/dev/null || grep -A100 '^run_align_docs_switch()' \
    "$RITE_REPO_ROOT/lib/utils/doc-consent.sh" | head -60 || true)"
  count=$(grep -c "read -p" <<< "$body" || true)
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Structural: rite docs and --init no longer have enable prompts
# ---------------------------------------------------------------------------

@test "docs-command.sh does NOT contain an enable prompt (consent owned by align-docs)" {
  count=$(grep -c "Track doc drift for this repo? \[y/N\]" \
    "$RITE_REPO_ROOT/lib/core/docs-command.sh" || true)
  [ "$count" -eq 0 ]
}

@test "bin/rite --init does NOT contain an enable prompt (consent owned by align-docs)" {
  count=$(grep -c "Track doc drift for this repo? \[y/N\]" \
    "$RITE_REPO_ROOT/bin/rite" || true)
  [ "$count" -eq 0 ]
}

@test "ensure_doc_mode no longer prompts (is a permanent no-op)" {
  # doc-consent.sh must not contain 'read -p' anywhere (prompt removed in #1805).
  count=$(grep -c 'read -p' "$RITE_REPO_ROOT/lib/utils/doc-consent.sh" || true)
  [ "$count" -eq 0 ]
  # Verify ensure_doc_mode is callable twice without error.
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    ensure_doc_mode
    ensure_doc_mode
    echo OK
  " < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# bin/rite dispatch
# ---------------------------------------------------------------------------

@test "bin/rite has align-docs) parser case" {
  count=$(grep -c '^    align-docs)$' "$RITE_REPO_ROOT/bin/rite" || true)
  [ "$count" -ge 1 ]
}

@test "bin/rite dispatches align-docs mode to run_align_docs_switch" {
  count=$(grep -c 'run_align_docs_switch' "$RITE_REPO_ROOT/bin/rite" || true)
  [ "$count" -ge 1 ]
}

@test "resolve_dispatch_key returns 'align-docs' for align-docs mode" {
  eval "$(sed -n '/^# --- resolve_dispatch_key (pure)/,/^# --- end resolve_dispatch_key/p' \
    "$RITE_REPO_ROOT/bin/rite")"
  set +u; set +o pipefail

  run resolve_dispatch_key "align-docs" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "align-docs" ]
}
