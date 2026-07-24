#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh
# Regression test: `rite --promote` has its OWN model role, decoupled from review.
#
# The same trap that hit plan (invisibly coupled to RITE_REVIEW_MODEL via ""):
# moving review off opus must not silently downgrade promotion narratives.
#
# Test strategy:
# 1. Default: promote resolves to claude-opus-4-8 (RITE_PROMOTE_MODEL unset).
# 2. Override: RITE_PROMOTE_MODEL respected.
# 3. Independence: RITE_REVIEW_MODEL=sonnet does NOT change promote (stays opus).
# 4. Independence: promote and review resolve independently when both set.
# 5. Static: promote role arm present in claude.sh, backed by RITE_PROMOTE_MODEL.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CLAUDE_SH="$PROJECT_ROOT/lib/providers/claude.sh"
  export PROJECT_ROOT CLAUDE_SH

  # Extract just the resolver function from claude.sh and eval it, so we test
  # the real dispatch table without sourcing the whole provider (and its side
  # effects). Mirrors the approach from tests/regression/plan-model-role.bats.
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
# Test 1: Default -- promote resolves to claude-opus-4-8
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: promote defaults to claude-opus-4-8" {
  unset RITE_PROMOTE_MODEL 2>/dev/null || true
  run bash "$_helper_script" "promote"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-4-8" ]
}

# ---------------------------------------------------------------------------
# Test 2: Override -- RITE_PROMOTE_MODEL respected
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: RITE_PROMOTE_MODEL override respected" {
  run env RITE_PROMOTE_MODEL=claude-sonnet-4-6 bash "$_helper_script" "promote"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-sonnet-4-6" ]
}

# ---------------------------------------------------------------------------
# Test 3: THE regression -- moving review off opus must NOT downgrade promote
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: RITE_REVIEW_MODEL=sonnet does not affect promote" {
  # review switched to sonnet, promote var unset -> promote must still be opus
  run env RITE_REVIEW_MODEL=claude-sonnet-4-6 bash "$_helper_script" "promote"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-4-8" ]
}

# ---------------------------------------------------------------------------
# Test 4: Independence -- promote and review resolve independently
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: promote and review are fully independent" {
  local two_role_script
  two_role_script="$(mktemp)"
  cat > "$two_role_script" << 'TWO_ROLE_EOF'
#!/bin/bash
set -euo pipefail
_fn=$(awk '
  /^claude_provider_resolve_model[(][)]/ { in_fn=1; depth=0 }
  in_fn { print }
  in_fn && /\{/ { depth++ }
  in_fn && /\}/ { depth--; if (depth==0) { in_fn=0 } }
' "$CLAUDE_SH")
eval "$_fn"
echo "review:$(claude_provider_resolve_model review)"
echo "promote:$(claude_provider_resolve_model promote)"
TWO_ROLE_EOF
  chmod +x "$two_role_script"

  run env RITE_REVIEW_MODEL=claude-sonnet-4-6 RITE_PROMOTE_MODEL=claude-opus-4-8 \
    bash "$two_role_script"
  rm -f "$two_role_script"

  [ "$status" -eq 0 ]
  [[ "$output" == *"review:claude-sonnet-4-6"* ]]
  [[ "$output" == *"promote:claude-opus-4-8"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: Static -- promote role defined in claude.sh, backed by RITE_PROMOTE_MODEL
# ---------------------------------------------------------------------------

@test "claude.sh: promote role defined and backed by RITE_PROMOTE_MODEL" {
  run grep -E '^\s*promote\)\s+echo\s+"\$\{RITE_PROMOTE_MODEL:-claude-opus-4-8\}"' "$CLAUDE_SH"
  [ "$status" -eq 0 ]
}
