#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh, lib/utils/config.sh
# Regression test: RITE_DOC_ASSESSMENT_MODEL is independent of RITE_REVIEW_MODEL
# Issue #341
#
# Bug: assess-documentation.sh had no model var and fell through to
# claude_provider_resolve_model "review" -> RITE_REVIEW_MODEL. Setting
# RITE_REVIEW_MODEL=opus for quality-critical review silently promoted doc
# assessment to opus too, inflating wall-clock 3-6x and firing the watchdog.
#
# Fix: claude_provider_resolve_model gains a "doc_assessment" role backed by
# RITE_DOC_ASSESSMENT_MODEL (default: claude-sonnet-4-6). Every
# provider_run_prompt_with_timeout call in assess-documentation.sh now passes
# $(provider_resolve_model doc_assessment) — the provider-agnostic alias — instead of "".
#
# Test strategy:
# 1. Default: doc_assessment resolves to claude-sonnet-4-6 (RITE_DOC_ASSESSMENT_MODEL unset).
# 2. Override: RITE_DOC_ASSESSMENT_MODEL=claude-opus-4-8 -> doc_assessment uses opus.
# 3. Independence: RITE_REVIEW_MODEL=claude-sonnet-4-6 AND RITE_DOC_ASSESSMENT_MODEL=claude-opus-4-8
#    -> review uses sonnet, doc_assessment uses opus (no cross-contamination).
# 4. Independence (reverse): RITE_REVIEW_MODEL=claude-opus-4-8 AND no RITE_DOC_ASSESSMENT_MODEL
#    -> review uses opus, doc_assessment still uses sonnet default.
# 5. Static check: every provider_run_prompt_with_timeout call in assess-documentation.sh
#    passes a non-empty model arg (no bare "" falling through to review default).
# 6. Static check: doc_assessment role present in claude_provider_resolve_model.
# 7. Static check: RITE_DOC_ASSESSMENT_MODEL documented in configuration.md.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CLAUDE_SH="$PROJECT_ROOT/lib/providers/claude.sh"
  ASSESS_DOC="$PROJECT_ROOT/lib/core/assess-documentation.sh"
  export PROJECT_ROOT CLAUDE_SH ASSESS_DOC

  # Write a minimal helper script that loads the resolver and calls it.
  # This avoids complex heredoc-in-bash-c quoting.
  _helper_script="$(mktemp)"
  cat > "$_helper_script" << 'HELPER_EOF'
#!/bin/bash
set -euo pipefail
# Source just the resolver function by extracting it with awk, then eval it.
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
# Test 1: Default -- doc_assessment resolves to claude-sonnet-4-6
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: doc_assessment defaults to claude-sonnet-4-6" {
  unset RITE_DOC_ASSESSMENT_MODEL 2>/dev/null || true
  run bash "$_helper_script" "doc_assessment"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-sonnet-4-6" ]
}

# ---------------------------------------------------------------------------
# Test 2: Override -- RITE_DOC_ASSESSMENT_MODEL=claude-opus-4-8 uses opus
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: RITE_DOC_ASSESSMENT_MODEL override respected" {
  run env RITE_DOC_ASSESSMENT_MODEL=claude-opus-4-8 bash "$_helper_script" "doc_assessment"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-4-8" ]
}

# ---------------------------------------------------------------------------
# Test 3: Independence -- review=sonnet AND doc_assessment=opus -> no cross-contamination
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: review and doc_assessment are fully independent" {
  # Write a two-role helper
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
echo "doc:$(claude_provider_resolve_model doc_assessment)"
TWO_ROLE_EOF
  chmod +x "$two_role_script"

  run env RITE_REVIEW_MODEL=claude-sonnet-4-6 RITE_DOC_ASSESSMENT_MODEL=claude-opus-4-8 \
    bash "$two_role_script"
  rm -f "$two_role_script"

  [ "$status" -eq 0 ]
  [[ "$output" == *"review:claude-sonnet-4-6"* ]]
  [[ "$output" == *"doc:claude-opus-4-8"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: Independence (reverse) -- RITE_REVIEW_MODEL=opus does not affect doc_assessment
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: RITE_REVIEW_MODEL=opus does not affect doc_assessment" {
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
echo "doc:$(claude_provider_resolve_model doc_assessment)"
TWO_ROLE_EOF
  chmod +x "$two_role_script"

  # RITE_REVIEW_MODEL=opus, but RITE_DOC_ASSESSMENT_MODEL is unset -> doc still uses sonnet default
  run env RITE_REVIEW_MODEL=claude-opus-4-8 bash "$two_role_script"
  rm -f "$two_role_script"

  [ "$status" -eq 0 ]
  [[ "$output" == *"review:claude-opus-4-8"* ]]
  # doc_assessment must still be sonnet (its own default) even though RITE_REVIEW_MODEL=opus
  [[ "$output" == *"doc:claude-sonnet-4-6"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: Static check -- every provider_run_prompt_with_timeout call in
# assess-documentation.sh passes a non-empty model arg (no bare "")
# ---------------------------------------------------------------------------

@test "assess-documentation.sh: all provider_run_prompt_with_timeout calls use explicit model arg" {
  # Find all provider_run_prompt_with_timeout call lines in the file.
  local call_lines
  call_lines=$(grep 'provider_run_prompt_with_timeout' "$ASSESS_DOC" || true)

  [ -n "$call_lines" ]

  # No call should pass empty string "" as the model arg (second positional arg)
  local bare_empty_count
  bare_empty_count=$(echo "$call_lines" | grep -c 'provider_run_prompt_with_timeout.*""' || true)
  [ "$bare_empty_count" -eq 0 ]

  # All calls should reference the provider-agnostic resolver: provider_resolve_model
  # doc_assessment (NOT the claude-prefixed claude_provider_resolve_model — lib/core
  # must stay provider-agnostic; enforced by lint Rule 32 DIRECT_PROVIDER_CALL).
  local explicit_model_count
  explicit_model_count=$(echo "$call_lines" | grep -c 'provider_resolve_model doc_assessment' || true)
  local total_calls
  total_calls=$(echo "$call_lines" | wc -l | tr -d ' ')

  [ "$explicit_model_count" -eq "$total_calls" ]
}

# ---------------------------------------------------------------------------
# Test 6: Static check -- doc_assessment role present in claude_provider_resolve_model
# ---------------------------------------------------------------------------

@test "claude.sh: doc_assessment role defined in claude_provider_resolve_model" {
  local doc_assessment_count
  doc_assessment_count=$(grep -c 'doc_assessment' "$CLAUDE_SH" || true)
  [ "$doc_assessment_count" -ge 1 ]

  # Must reference RITE_DOC_ASSESSMENT_MODEL
  local var_count
  var_count=$(grep -c 'RITE_DOC_ASSESSMENT_MODEL' "$CLAUDE_SH" || true)
  [ "$var_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 7: Static check -- RITE_DOC_ASSESSMENT_MODEL documented in configuration.md
# ---------------------------------------------------------------------------

@test "docs/configuration.md: RITE_DOC_ASSESSMENT_MODEL documented" {
  local config_doc="$PROJECT_ROOT/docs/configuration.md"
  [ -f "$config_doc" ]

  local doc_count
  doc_count=$(grep -c 'RITE_DOC_ASSESSMENT_MODEL' "$config_doc" || true)
  [ "$doc_count" -ge 1 ]
}
