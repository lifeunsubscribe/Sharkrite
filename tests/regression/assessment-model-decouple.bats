#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh, lib/core/assess-review-issues.sh, lib/core/assess-and-resolve.sh
# Regression test: RITE_ASSESSMENT_MODEL is independent of RITE_REVIEW_MODEL
# Issue #1187
#
# Bug: assess-and-resolve.sh extracted the model from the review marker and
# exported RITE_ASSESSMENT_MODEL="$REVIEW_MODEL", so finding assessment always
# ran on the review model. Pinning review to fable-5 (2026-10-10) silently
# moved every assessment call — the highest-count LLM call in the fix loop —
# onto the most expensive model. Same bug class as #341 (doc_assessment).
#
# Fix: claude_provider_resolve_model gains an "assessment" role backed by
# RITE_ASSESSMENT_MODEL (default: claude-sonnet-4-6). assess-review-issues.sh
# resolves EFFECTIVE_MODEL via $(provider_resolve_model assessment); the
# review-marker inherit in assess-and-resolve.sh is deleted.
#
# Test strategy mirrors tests/regression/doc-assessment-model-decouple.bats:
# 1. Default: assessment resolves to claude-sonnet-4-6.
# 2. Override: RITE_ASSESSMENT_MODEL respected.
# 3. Independence: RITE_REVIEW_MODEL=claude-fable-5 does not affect assessment.
# 4. Static: assess-review-issues.sh uses the assessment role, no
#    :-$RITE_REVIEW_MODEL fallback.
# 5. Static: the review-marker inherit is gone from assess-and-resolve.sh.
# 6. Static: RITE_ASSESSMENT_MODEL documented in config example + configuration.md.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CLAUDE_SH="$PROJECT_ROOT/lib/providers/claude.sh"
  ASSESS_REVIEW="$PROJECT_ROOT/lib/core/assess-review-issues.sh"
  ASSESS_RESOLVE="$PROJECT_ROOT/lib/core/assess-and-resolve.sh"
  export PROJECT_ROOT CLAUDE_SH ASSESS_REVIEW ASSESS_RESOLVE

  # Minimal helper that extracts just the resolver function and calls it
  # (same pattern as doc-assessment-model-decouple.bats).
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
for role in "$@"; do
  echo "$role:$(claude_provider_resolve_model "$role")"
done
HELPER_EOF
  chmod +x "$_helper_script"
  export _helper_script
}

teardown() {
  rm -f "${_helper_script:-}"
}

# ---------------------------------------------------------------------------
# Test 1: Default -- assessment resolves to claude-sonnet-4-6
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: assessment defaults to claude-sonnet-4-6" {
  run env -u RITE_ASSESSMENT_MODEL bash "$_helper_script" "assessment"
  [ "$status" -eq 0 ]
  [ "$output" = "assessment:claude-sonnet-4-6" ]
}

# ---------------------------------------------------------------------------
# Test 2: Override -- RITE_ASSESSMENT_MODEL respected
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: RITE_ASSESSMENT_MODEL override respected" {
  run env RITE_ASSESSMENT_MODEL=claude-opus-4-8 bash "$_helper_script" "assessment"
  [ "$status" -eq 0 ]
  [ "$output" = "assessment:claude-opus-4-8" ]
}

# ---------------------------------------------------------------------------
# Test 3: Independence -- RITE_REVIEW_MODEL does not leak into assessment
# (the live bug: review pinned to fable ran all assessments on fable)
# ---------------------------------------------------------------------------

@test "claude_provider_resolve_model: RITE_REVIEW_MODEL=fable does not affect assessment" {
  run env -u RITE_ASSESSMENT_MODEL RITE_REVIEW_MODEL=claude-fable-5 \
    bash "$_helper_script" "review" "assessment"
  [ "$status" -eq 0 ]
  [[ "$output" == *"review:claude-fable-5"* ]]
  [[ "$output" == *"assessment:claude-sonnet-4-6"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: Static -- assess-review-issues.sh resolves via the assessment role
# ---------------------------------------------------------------------------

@test "assess-review-issues.sh: EFFECTIVE_MODEL resolved via assessment role, no review fallback" {
  # Must use the provider-agnostic resolver with the assessment role
  # (NOT claude_provider_resolve_model — lib/core stays provider-agnostic, Rule 32).
  local role_count
  role_count=$(grep -c 'EFFECTIVE_MODEL=$(provider_resolve_model assessment)' "$ASSESS_REVIEW" || true)
  [ "$role_count" -eq 1 ]

  # The old inherit-with-review-fallback assignment must be gone.
  local fallback_count
  fallback_count=$(grep -c 'RITE_ASSESSMENT_MODEL:-\$RITE_REVIEW_MODEL' "$ASSESS_REVIEW" || true)
  [ "$fallback_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 5: Static -- review-marker inherit deleted from assess-and-resolve.sh
# ---------------------------------------------------------------------------

@test "assess-and-resolve.sh: no extract_review_model, no RITE_ASSESSMENT_MODEL export" {
  local extract_count
  extract_count=$(grep -c 'extract_review_model' "$ASSESS_RESOLVE" || true)
  [ "$extract_count" -eq 0 ]

  local export_count
  export_count=$(grep -c 'export RITE_ASSESSMENT_MODEL' "$ASSESS_RESOLVE" || true)
  [ "$export_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 6: Static -- RITE_ASSESSMENT_MODEL documented (Rule 36 + configuration.md)
# ---------------------------------------------------------------------------

@test "RITE_ASSESSMENT_MODEL documented in config example and configuration.md" {
  local example_count
  example_count=$(grep -c 'RITE_ASSESSMENT_MODEL' "$PROJECT_ROOT/config/rite.conf.example" || true)
  [ "$example_count" -ge 1 ]

  local doc_count
  doc_count=$(grep -c 'RITE_ASSESSMENT_MODEL' "$PROJECT_ROOT/docs/configuration.md" || true)
  [ "$doc_count" -ge 1 ]
}
