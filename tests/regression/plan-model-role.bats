#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh, lib/core/plan-issues.sh, bin/rite
# Regression test: `rite plan` has its OWN model role, decoupled from review.
#
# Bug: plan-issues.sh passed "" as the model arg to provider_run_streaming_prompt.
# An empty model falls through to claude_provider_resolve_model "review" ->
# RITE_REVIEW_MODEL (opus). Planning — the highest-stakes reasoning stage (must
# honor ADRs, must not hallucinate fixtures) — was invisibly coupled to the review
# model. Moving review off opus would have silently downgraded planning with it.
# The same trap put bin/rite's doc auto-discovery classification on opus too.
#
# Fix: claude_provider_resolve_model gains a "plan" role backed by RITE_PLAN_MODEL
# (default: claude-opus-4-8). plan-issues.sh passes $(provider_resolve_model plan);
# bin/rite's classification passes $(provider_resolve_model triage). No bare "".
#
# Test strategy:
# 1. Default: plan resolves to claude-opus-4-8 (RITE_PLAN_MODEL unset).
# 2. Override: RITE_PLAN_MODEL respected.
# 3. Independence: RITE_REVIEW_MODEL=sonnet does NOT change plan (stays opus default).
# 4. Independence: plan and review resolve independently when both set.
# 5. Static: plan role present in claude.sh, backed by RITE_PLAN_MODEL.
# 6. Static: plan-issues.sh passes an explicit "plan" model (no bare "").
# 7. Static: bin/rite doc classification passes an explicit model (no bare "").

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CLAUDE_SH="$PROJECT_ROOT/lib/providers/claude.sh"
  PLAN_ISSUES="$PROJECT_ROOT/lib/core/plan-issues.sh"
  RITE_BIN="$PROJECT_ROOT/bin/rite"
  export PROJECT_ROOT CLAUDE_SH PLAN_ISSUES RITE_BIN

  # Extract just the resolver function from claude.sh and eval it, so we test the
  # real dispatch table without sourcing the whole provider (and its side effects).
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
# Test 1: Default -- plan resolves to claude-opus-4-8
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: plan defaults to claude-opus-4-8" {
  unset RITE_PLAN_MODEL 2>/dev/null || true
  run bash "$_helper_script" "plan"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-4-8" ]
}

# ---------------------------------------------------------------------------
# Test 2: Override -- RITE_PLAN_MODEL respected
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: RITE_PLAN_MODEL override respected" {
  run env RITE_PLAN_MODEL=claude-sonnet-4-6 bash "$_helper_script" "plan"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-sonnet-4-6" ]
}

# ---------------------------------------------------------------------------
# Test 3: THE regression -- moving review off opus must NOT downgrade plan
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: RITE_REVIEW_MODEL=sonnet does not affect plan" {
  # review switched to sonnet, plan var unset -> plan must still be opus (its own default)
  run env RITE_REVIEW_MODEL=claude-sonnet-4-6 bash "$_helper_script" "plan"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-4-8" ]
}

# ---------------------------------------------------------------------------
# Test 4: Independence -- plan and review resolve independently
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: plan and review are fully independent" {
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
echo "plan:$(claude_provider_resolve_model plan)"
TWO_ROLE_EOF
  chmod +x "$two_role_script"

  run env RITE_REVIEW_MODEL=claude-sonnet-4-6 RITE_PLAN_MODEL=claude-opus-4-8 \
    bash "$two_role_script"
  rm -f "$two_role_script"

  [ "$status" -eq 0 ]
  [[ "$output" == *"review:claude-sonnet-4-6"* ]]
  [[ "$output" == *"plan:claude-opus-4-8"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: Static -- plan role defined in claude.sh, backed by RITE_PLAN_MODEL
# ---------------------------------------------------------------------------

@test "claude.sh: plan role defined and backed by RITE_PLAN_MODEL" {
  run grep -E '^\s*plan\)\s+echo\s+"\$\{RITE_PLAN_MODEL:-claude-opus-4-8\}"' "$CLAUDE_SH"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 6: Static -- plan-issues.sh passes an explicit "plan" model (no bare "")
# ---------------------------------------------------------------------------

@test "plan-issues.sh: streaming calls pass an explicit plan model, never \"\"" {
  local stream_calls
  stream_calls=$(grep 'provider_run_streaming_prompt' "$PLAN_ISSUES" || true)
  [ -n "$stream_calls" ]

  # No streaming call may pass "" as the model (2nd positional arg).
  local bare_empty
  bare_empty=$(echo "$stream_calls" | grep -cE 'provider_run_streaming_prompt[[:space:]]+"[^"]*"[[:space:]]+""' || true)
  [ "$bare_empty" -eq 0 ]

  # Every streaming call resolves the plan role explicitly.
  local total_calls plan_calls
  total_calls=$(echo "$stream_calls" | wc -l | tr -d ' ')
  plan_calls=$(echo "$stream_calls" | grep -c 'provider_resolve_model plan' || true)
  [ "$plan_calls" -eq "$total_calls" ]
}

# ---------------------------------------------------------------------------
# Test 7: Static -- bin/rite doc classification passes an explicit model (no bare "")
# ---------------------------------------------------------------------------

@test "bin/rite: doc classification passes an explicit model, never \"\"" {
  # The classification call must not fall through to the review default.
  local bare_empty
  bare_empty=$(grep -cE 'provider_run_prompt[[:space:]]+"[^"]*"[[:space:]]+""' "$RITE_BIN" || true)
  [ "$bare_empty" -eq 0 ]

  # It resolves an explicit role via the agnostic alias.
  run grep -E 'provider_run_prompt "\$_classify_prompt" "\$\(provider_resolve_model triage\)"' "$RITE_BIN"
  [ "$status" -eq 0 ]
}
