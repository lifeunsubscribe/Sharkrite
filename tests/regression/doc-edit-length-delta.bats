#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh::_docs_proposal_guards
# tests/regression/doc-edit-length-delta.bats
BATS_TEST_TIMEOUT=15
#
# Tests for the two computed preview guards added to every doc-proposal preview:
#
#  Guard 1 — length-neutrality:
#    1a. Old/new/delta are displayed in the preview output
#    1b. Growth > threshold with no stated reason → visible FLAG line
#    1c. Growth <= threshold → no FLAG line
#    1d. Shrinkage → no FLAG line (flag only fires on growth)
#
#  Guard 2 — shipped-product-only:
#    2a. Date patterns in proposed text → FLAG line listing them
#    2b. Committer names in proposed text → FLAG line listing them
#    2c. No date patterns → no date FLAG line
#    2d. No committer names → no name FLAG line
#    2e. Multiple date patterns → all appear in output
#
#  General:
#    3a. No auto-reject path: function always returns 0

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DOCS_CMD="$PROJECT_ROOT/lib/core/docs-command.sh"
  export PROJECT_ROOT DOCS_CMD

  # Minimal fake project for git calls inside docs-command.sh
  FAKE_PROJECT="$(mktemp -d)"
  git -C "$FAKE_PROJECT" init -q
  git -C "$FAKE_PROJECT" config user.email "test@sharkrite.local"
  git -C "$FAKE_PROJECT" config user.name "Test Author"
  touch "$FAKE_PROJECT/README.md"
  git -C "$FAKE_PROJECT" add .
  git -C "$FAKE_PROJECT" commit -q -m "init"
  export FAKE_PROJECT

  # Helper script: sources docs-command.sh and exposes _docs_proposal_guards
  HELPER="$(mktemp)"
  export HELPER
  cat > "$HELPER" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail

export RITE_LIB_DIR="${PROJECT_ROOT}/lib"
export RITE_PROJECT_ROOT="${FAKE_PROJECT}"
export RITE_STATE_DIR="${FAKE_PROJECT}/.rite/state"
export RITE_TARGET_BRANCH=main

source "${DOCS_CMD}"

# Re-define provider stubs AFTER source (env-guarded libs overwrite pre-source stubs)
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs sentinel; load_provider and provider_* stubs must be post-source
load_provider()                    { return 0; }
provider_run_prompt_with_timeout() { echo "NO_PROPOSALS_NEEDED"; }
provider_resolve_model()           { echo "stub-model"; }
gh_safe()                          { return 0; }
docs_map_ensure()                  { return 0; }
docs_map_path()                    { echo "${RITE_STATE_DIR}/docs-map.tsv"; }

# Invoke _docs_proposal_guards with args forwarded from environment:
#   OLD_BYTES NEW_BYTES CONTENT DESC THRESHOLD COMMITTER_NAMES
_docs_proposal_guards \
  "${GUARD_OLD:-0}" \
  "${GUARD_NEW:-0}" \
  "${GUARD_CONTENT:-}" \
  "${GUARD_DESC:-}" \
  "${GUARD_THRESHOLD:-15}" \
  "${GUARD_NAMES:-}"
HELPER_EOF
  chmod +x "$HELPER"
}

teardown() {
  rm -rf "$FAKE_PROJECT" "$HELPER"
}

# ---------------------------------------------------------------------------
# Guard 1a: old/new/delta display
# ---------------------------------------------------------------------------

@test "1a: size line shows old → new bytes for EDIT" {
  GUARD_OLD=100 GUARD_NEW=110 GUARD_CONTENT="some content" \
    GUARD_THRESHOLD=15 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Size: 100 → 110 bytes"* ]]
}

@test "1a: size line shows +delta for growth" {
  GUARD_OLD=100 GUARD_NEW=120 GUARD_CONTENT="some content" \
    GUARD_THRESHOLD=50 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"+20 bytes"* ]]
}

@test "1a: size line shows new file for CREATE (old_bytes=0)" {
  GUARD_OLD=0 GUARD_NEW=200 GUARD_CONTENT="new file content" \
    GUARD_THRESHOLD=15 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"new file, 200 bytes"* ]]
}

# ---------------------------------------------------------------------------
# Guard 1b: growth > threshold → FLAG
# ---------------------------------------------------------------------------

@test "1b: growth > threshold emits FLAG line" {
  GUARD_OLD=100 GUARD_NEW=120 GUARD_CONTENT="extra content" \
    GUARD_THRESHOLD=15 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[FLAG]"*"Growth"* ]]
}

@test "1b: FLAG line mentions the threshold percentage" {
  GUARD_OLD=100 GUARD_NEW=125 GUARD_CONTENT="extra content" \
    GUARD_THRESHOLD=15 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"15%"* ]]
}

# ---------------------------------------------------------------------------
# Guard 1c: growth <= threshold → no FLAG
# ---------------------------------------------------------------------------

@test "1c: growth exactly at threshold does not emit FLAG" {
  # 15 bytes growth on 100 bytes = exactly 15% — should NOT flag
  GUARD_OLD=100 GUARD_NEW=115 GUARD_CONTENT="padded" \
    GUARD_THRESHOLD=15 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" != *"[FLAG]"*"Growth"* ]]
}

@test "1c: small growth does not emit FLAG" {
  GUARD_OLD=1000 GUARD_NEW=1010 GUARD_CONTENT="minor change" \
    GUARD_THRESHOLD=15 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" != *"[FLAG]"*"Growth"* ]]
}

# ---------------------------------------------------------------------------
# Guard 1d: shrinkage does not emit FLAG
# ---------------------------------------------------------------------------

@test "1d: shrinkage does not emit growth FLAG" {
  GUARD_OLD=200 GUARD_NEW=100 GUARD_CONTENT="shorter" \
    GUARD_THRESHOLD=15 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" != *"[FLAG]"*"Growth"* ]]
}

# ---------------------------------------------------------------------------
# Guard 2a: date patterns → FLAG
# ---------------------------------------------------------------------------

@test "2a: ISO date in content triggers date FLAG" {
  GUARD_OLD=100 GUARD_NEW=102 \
    GUARD_CONTENT="Updated on 2026-10-26 to fix the bug." \
    GUARD_THRESHOLD=50 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[FLAG]"*"Date patterns"* ]]
  [[ "$output" == *"2026-10-26"* ]]
}

@test "2a: month-year pattern in content triggers date FLAG" {
  GUARD_OLD=100 GUARD_NEW=102 \
    GUARD_CONTENT="Released in October 2026 for general availability." \
    GUARD_THRESHOLD=50 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[FLAG]"*"Date patterns"* ]]
}

@test "2a: US-format date in content triggers date FLAG" {
  GUARD_OLD=100 GUARD_NEW=102 \
    GUARD_CONTENT="Deadline: 10/26/2026 for this feature." \
    GUARD_THRESHOLD=50 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[FLAG]"*"Date patterns"* ]]
}

# ---------------------------------------------------------------------------
# Guard 2b: committer names → FLAG
# ---------------------------------------------------------------------------

@test "2b: committer name in content triggers name FLAG" {
  GUARD_OLD=100 GUARD_NEW=102 \
    GUARD_CONTENT="Implemented by Alice Smith per ADR-042." \
    GUARD_THRESHOLD=50 \
    GUARD_NAMES="Alice Smith" \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[FLAG]"*"Committer names"* ]]
  [[ "$output" == *"Alice Smith"* ]]
}

# ---------------------------------------------------------------------------
# Guard 2c: no date patterns → no date FLAG
# ---------------------------------------------------------------------------

@test "2c: prose without dates produces no date FLAG" {
  GUARD_OLD=100 GUARD_NEW=102 \
    GUARD_CONTENT="This feature improves throughput by batching requests." \
    GUARD_THRESHOLD=50 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Date patterns"* ]]
}

# ---------------------------------------------------------------------------
# Guard 2d: no committer names in content → no name FLAG
# ---------------------------------------------------------------------------

@test "2d: prose without committer names produces no name FLAG" {
  GUARD_OLD=100 GUARD_NEW=102 \
    GUARD_CONTENT="This feature improves throughput by batching requests." \
    GUARD_THRESHOLD=50 \
    GUARD_NAMES="Alice Smith
Bob Jones" \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Committer names"* ]]
}

# ---------------------------------------------------------------------------
# Guard 2e: multiple date patterns all appear
# ---------------------------------------------------------------------------

@test "2e: multiple distinct date patterns all listed in FLAG output" {
  GUARD_OLD=100 GUARD_NEW=110 \
    GUARD_CONTENT="Born 2020-01-01; last updated 2026-10-26." \
    GUARD_THRESHOLD=50 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2020-01-01"* ]]
  [[ "$output" == *"2026-10-26"* ]]
}

# ---------------------------------------------------------------------------
# Guard 3a: no auto-reject — function always exits 0
# ---------------------------------------------------------------------------

@test "3a: function returns 0 on over-threshold growth" {
  GUARD_OLD=100 GUARD_NEW=200 GUARD_CONTENT="doubled content" \
    GUARD_THRESHOLD=15 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
}

@test "3a: function returns 0 on date FLAG" {
  GUARD_OLD=100 GUARD_NEW=102 \
    GUARD_CONTENT="Released 2026-10-26 for production." \
    GUARD_THRESHOLD=50 \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
}

@test "3a: function returns 0 on committer name FLAG" {
  GUARD_OLD=100 GUARD_NEW=102 \
    GUARD_CONTENT="Alice Smith wrote this." \
    GUARD_THRESHOLD=50 \
    GUARD_NAMES="Alice Smith" \
    run bash "$HELPER"
  [ "$status" -eq 0 ]
}
