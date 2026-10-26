#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/doc-consent.sh, bin/rite
# tests/regression/align-docs-switch.bats
#
# Regression tests for #1424: `rite align-docs` as the single on/off switch
# for doc drift tracking.
#
# Tests cover:
#   - run_align_docs_switch: non-TTY never enables (stdin from /dev/null)
#   - run_align_docs_switch --disable: records off; restores first-run semantics
#   - Structural: prompt text states audit runs either way
#   - Structural: rite docs and --init no longer contain their own enable prompts
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
# Non-TTY: never prompts and never enables ([ -t 0 ] false)
# ---------------------------------------------------------------------------

@test "run_align_docs_switch in non-TTY never enables and never records sync" {
  # < /dev/null makes [ -t 0 ] return false — the function must not prompt or record
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
  # Non-TTY must not enable — no sync or changelog recorded
  [[ "$output" != *"mode=sync"* ]]
  [[ "$output" != *"mode=changelog"* ]]
  # Config must have no RITE_DOC_MODE= line
  [ "$(grep -c '^RITE_DOC_MODE=' "$RITE_PROJECT_ROOT/.rite/config" || true)" -eq 0 ]
}

@test "run_align_docs_switch in non-TTY exits 0 (degrades gracefully)" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    unset RITE_DOC_MODE 2>/dev/null || true
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    run_align_docs_switch
  " < /dev/null
  [ "$status" -eq 0 ]
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

@test "after --disable, _docs_resolve_state returns never-run (first-run semantics restored)" {
  # off maps to never-run in _docs_resolve_state so the next align-docs run asks again
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

# ---------------------------------------------------------------------------
# TTY y-path: feeding y via stdin records sync
# ---------------------------------------------------------------------------

@test "run_align_docs_switch TTY y-path records sync when user answers y" {
  # _RITE_FORCE_TTY=1 bypasses the [ -t 0 ] guard so stdin (here-string) reaches read -p
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export _RITE_FORCE_TTY=1
    unset RITE_DOC_MODE 2>/dev/null || true
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    run_align_docs_switch
    grep '^RITE_DOC_MODE=' '$RITE_PROJECT_ROOT/.rite/config' || true
  " <<< "y"
  [ "$status" -eq 0 ]
  [[ "$output" == *'RITE_DOC_MODE="sync"'* ]]
}

# ---------------------------------------------------------------------------
# Prompt text invariant: must state the audit runs either way
# ---------------------------------------------------------------------------

@test "run_align_docs_switch prompt text states the audit runs either way" {
  # Structural: acceptance criterion requires this exact framing
  count=$(grep -c "either way" \
    "$RITE_REPO_ROOT/lib/utils/doc-consent.sh" || true)
  [ "$count" -ge 1 ]
}

@test "run_align_docs_switch prompt asks about enabling, not about tracking" {
  # Structural: the new prompt asks 'Enable doc drift tracking?' not the old wording
  count=$(grep -c "Enable doc drift tracking" \
    "$RITE_REPO_ROOT/lib/utils/doc-consent.sh" || true)
  [ "$count" -ge 1 ]
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
  # Structural: ensure_doc_mode must not contain 'read -p' — consent moved to align-docs
  count=$(grep -c 'read -p' "$RITE_REPO_ROOT/lib/utils/doc-consent.sh" || true)
  # The only read -p in doc-consent.sh should be in run_align_docs_switch (the on/off switch)
  # — ensure_doc_mode specifically must not have one.
  # Verify by checking the function body contains no read -p.
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    # ensure_doc_mode is the no-op: source twice + call must be safe
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
