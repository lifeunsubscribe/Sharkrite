#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh
# Regression test: doc_update has its OWN model role, decoupled from doc_assessment.
#
# A doc edit is read by a human as the product's description — quality justifies
# fable. doc_assessment stays classification-grade (sonnet) for tag dedup and
# structured comparison.  The two roles must resolve independently.
#
# Test strategy:
# 1. Default: doc_update resolves to claude-fable-5 (RITE_DOC_UPDATE_MODEL unset).
# 2. Override: RITE_DOC_UPDATE_MODEL respected.
# 3. Independence: changing RITE_DOC_UPDATE_MODEL does not affect doc_assessment.
# 4. Independence: changing RITE_DOC_ASSESSMENT_MODEL does not affect doc_update.
# 5. Static: doc_update role arm present in claude.sh, backed by RITE_DOC_UPDATE_MODEL.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CLAUDE_SH="$PROJECT_ROOT/lib/providers/claude.sh"
  export PROJECT_ROOT CLAUDE_SH

  # Extract just the resolver function from claude.sh and eval it, so we test
  # the real dispatch table without sourcing the whole provider (and its side
  # effects). Mirrors the approach from tests/regression/promote-model-role.bats.
  _helper_script="$(mktemp)"
  cat > "$_helper_script" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail
_fn=$(awk '
  /^claude_provider_resolve_model[(][)]/ { in_fn=1; depth=0 }
  in_fn { print }
  in_fn && /\{/ { depth++ }
  in_fn && /\}/ { depth--; if (depth==0) { in_fn=0 } }
' "$CLAUDE_SH")
eval "$_fn"
claude_provider_resolve_model "$1"
HELPER_EOF
  chmod +x "$_helper_script"
  export _helper_script
}

teardown() {
  rm -f "${_helper_script:-}"
}

# ---------------------------------------------------------------------------
# Test 1: Default -- doc_update resolves to claude-fable-5
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: doc_update defaults to claude-fable-5" {
  unset RITE_DOC_UPDATE_MODEL 2>/dev/null || true
  run bash "$_helper_script" "doc_update"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-fable-5" ]
}

# ---------------------------------------------------------------------------
# Test 2: Override -- RITE_DOC_UPDATE_MODEL respected
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: RITE_DOC_UPDATE_MODEL override respected" {
  run env RITE_DOC_UPDATE_MODEL=claude-sonnet-4-6 bash "$_helper_script" "doc_update"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-sonnet-4-6" ]
}

# ---------------------------------------------------------------------------
# Test 3: Independence -- changing doc_update var does not affect doc_assessment
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: RITE_DOC_UPDATE_MODEL does not affect doc_assessment" {
  run env -u RITE_DOC_ASSESSMENT_MODEL \
    RITE_DOC_UPDATE_MODEL=claude-haiku-4-5 \
    bash "$_helper_script" "doc_assessment"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-sonnet-4-6" ]
}

# ---------------------------------------------------------------------------
# Test 4: Independence -- changing doc_assessment var does not affect doc_update
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: RITE_DOC_ASSESSMENT_MODEL does not affect doc_update" {
  run env -u RITE_DOC_UPDATE_MODEL \
    RITE_DOC_ASSESSMENT_MODEL=claude-opus-4-8 \
    bash "$_helper_script" "doc_update"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-fable-5" ]
}

# ---------------------------------------------------------------------------
# Test 5: Static -- doc_update role defined in claude.sh, backed by RITE_DOC_UPDATE_MODEL
# ---------------------------------------------------------------------------

@test "claude.sh: doc_update role defined and backed by RITE_DOC_UPDATE_MODEL" {
  run grep -E '^\s*doc_update\)\s+echo\s+"\$\{RITE_DOC_UPDATE_MODEL:-claude-fable-5\}"' "$CLAUDE_SH"
  [ "$status" -eq 0 ]
}
