#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh::_claude_model_fallback_preflight|claude_provider_resolve_model|claude_provider_healthcheck|_claude_provider_resolve_model_raw
# Regression tests for RITE_MODEL_FALLBACK opt-in model fallback (issue #1613).
#
# When RITE_MODEL_FALLBACK is set, provider_healthcheck probes each distinct
# configured model and substitutes the fallback for any that are capped.
# When unset, behavior is byte-identical to today (no probes, no substitution).

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT

  export TEST_TMPDIR="${BATS_TEST_TMPDIR}/model-fallback-test"
  mkdir -p "$TEST_TMPDIR"

  # Stub bin dir — prepend to PATH so fake claude overrides the real one
  export STUB_BIN="$TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"

  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  export RITE_PROJECT_ROOT="$TEST_TMPDIR/repo"
  mkdir -p "$RITE_PROJECT_ROOT"

  # Track per-model call args
  export CALL_LOG="$TEST_TMPDIR/call-log"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Helper: write a stub that returns a cap phrase when called with --model fable
# but succeeds for any other model.
# ---------------------------------------------------------------------------
_make_selective_cap_stub() {
  printf '#!/bin/bash\n' > "$STUB_BIN/claude"
  # Log all args so tests can inspect what models were probed
  printf 'echo "$*" >> "%s"\n' "$CALL_LOG" >> "$STUB_BIN/claude"
  # Emit cap phrase when the capped model is requested
  printf 'for arg in "$@"; do\n' >> "$STUB_BIN/claude"
  printf '  if [ "$arg" = "claude-fable-5-1" ]; then\n' >> "$STUB_BIN/claude"
  printf '    echo "You'"'"'re out of usage credits." >&2\n' >> "$STUB_BIN/claude"
  printf '    exit 1\n' >> "$STUB_BIN/claude"
  printf '  fi\n' >> "$STUB_BIN/claude"
  printf 'done\n' >> "$STUB_BIN/claude"
  printf 'echo "ok"\n' >> "$STUB_BIN/claude"
  printf 'exit 0\n' >> "$STUB_BIN/claude"
  chmod +x "$STUB_BIN/claude"
}

# ---------------------------------------------------------------------------
# Helper: write a stub where ALL models are capped (total exhaustion scenario).
# ---------------------------------------------------------------------------
_make_all_capped_stub() {
  printf '#!/bin/bash\n' > "$STUB_BIN/claude"
  printf 'echo "$*" >> "%s"\n' "$CALL_LOG" >> "$STUB_BIN/claude"
  printf 'echo "You'"'"'re out of usage credits." >&2\n' >> "$STUB_BIN/claude"
  printf 'exit 1\n' >> "$STUB_BIN/claude"
  chmod +x "$STUB_BIN/claude"
}

# ---------------------------------------------------------------------------
# Helper: write a healthy stub that succeeds for every model.
# ---------------------------------------------------------------------------
_make_healthy_stub() {
  printf '#!/bin/bash\n' > "$STUB_BIN/claude"
  printf 'echo "$*" >> "%s"\n' "$CALL_LOG" >> "$STUB_BIN/claude"
  printf 'echo "ok"\n' >> "$STUB_BIN/claude"
  printf 'exit 0\n' >> "$STUB_BIN/claude"
  chmod +x "$STUB_BIN/claude"
}

# ---------------------------------------------------------------------------
# Test 1: unset RITE_MODEL_FALLBACK → resolve_model returns unchanged, no probe
# ---------------------------------------------------------------------------
@test "RITE_MODEL_FALLBACK unset: resolve_model returns pinned model unchanged" {
  _make_healthy_stub

  run bash -c "
    export PATH=\"$STUB_BIN:\$PATH\"
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    # Explicit pinned model
    export RITE_REVIEW_MODEL='claude-fable-5-1'
    unset RITE_MODEL_FALLBACK
    source '$RITE_LIB_DIR/providers/provider-interface.sh'
    load_provider 'claude'
    provider_detect_cli 2>/dev/null || true
    provider_healthcheck 2>/dev/null
    provider_resolve_model 'review'
  "
  [ "$status" -eq 0 ]
  # Last line of output must be the pinned model (not a fallback)
  [[ "$output" == *"claude-fable-5-1"* ]]
  # No probes should have been issued (call log has only the trust-check --print call,
  # which uses no --model flag)
  [ -f "$CALL_LOG" ]
  # No --model flag should appear in any call when fallback is unset
  ! grep -q -- "--model" "$CALL_LOG"
}

# ---------------------------------------------------------------------------
# Test 2: one capped model → that role resolves to fallback, warning emitted
# ---------------------------------------------------------------------------
@test "RITE_MODEL_FALLBACK set: capped model causes fallback substitution with warning" {
  _make_selective_cap_stub

  run bash -c "
    export PATH=\"$STUB_BIN:\$PATH\"
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_REVIEW_MODEL='claude-fable-5-1'
    export RITE_MODEL_FALLBACK='claude-sonnet-4-6'
    source '$RITE_LIB_DIR/providers/provider-interface.sh'
    load_provider 'claude'
    provider_detect_cli 2>/dev/null || true
    provider_healthcheck 2>&1
    echo \"RESOLVED:\$(provider_resolve_model 'review')\"
  " 2>&1
  [ "$status" -eq 0 ]
  # Output must contain the fallback substitution warning
  [[ "$output" == *"Model fallback"* ]]
  [[ "$output" == *"claude-fable-5-1"* ]]
  [[ "$output" == *"claude-sonnet-4-6"* ]]
  # resolve_model must return the fallback
  [[ "$output" == *"RESOLVED:claude-sonnet-4-6"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: total exhaustion (fallback also capped) → no substitution; cap path fires
# ---------------------------------------------------------------------------
@test "RITE_MODEL_FALLBACK set: fallback also capped → resolve returns original model" {
  _make_all_capped_stub

  run bash -c "
    export PATH=\"$STUB_BIN:\$PATH\"
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_REVIEW_MODEL='claude-fable-5-1'
    export RITE_MODEL_FALLBACK='claude-sonnet-4-6'
    source '$RITE_LIB_DIR/providers/provider-interface.sh'
    load_provider 'claude'
    provider_detect_cli 2>/dev/null || true
    # healthcheck may exit non-zero when trust check fails under all-cap stub,
    # but we continue to test resolve_model behavior
    provider_healthcheck 2>/dev/null || true
    echo \"RESOLVED:\$(provider_resolve_model 'review')\"
  " 2>&1
  # resolve_model must return the original pinned model (not the fallback)
  [[ "$output" == *"RESOLVED:claude-fable-5-1"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: role already pinned to fallback model → no self-substitution
# ---------------------------------------------------------------------------
@test "RITE_MODEL_FALLBACK set: role pinned to same model as fallback → no substitution" {
  _make_selective_cap_stub

  run bash -c "
    export PATH=\"$STUB_BIN:\$PATH\"
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    # dev role is sonnet — same as fallback; fable is capped but no role uses it here
    export RITE_CLAUDE_MODEL='claude-sonnet-4-6'
    export RITE_MODEL_FALLBACK='claude-sonnet-4-6'
    source '$RITE_LIB_DIR/providers/provider-interface.sh'
    load_provider 'claude'
    provider_detect_cli 2>/dev/null || true
    provider_healthcheck 2>/dev/null
    echo \"RESOLVED:\$(provider_resolve_model 'dev')\"
  " 2>&1
  [ "$status" -eq 0 ]
  # Must resolve to sonnet (same as fallback — no loop, no substitution)
  [[ "$output" == *"RESOLVED:claude-sonnet-4-6"* ]]
  # No fallback warning should appear (self-substitution skipped)
  ! [[ "$output" == *"Model fallback: role=dev"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: Cross-process -- subprocess inherits capped-model memo
# ---------------------------------------------------------------------------
@test "RITE_MODEL_FALLBACK: subprocess inherits capped-model memo after healthcheck" {
  _make_selective_cap_stub

  # Child script re-sources the provider without running healthcheck.
  # The idempotent _RITE_CAPPED_MODELS="${_RITE_CAPPED_MODELS:-}" must preserve
  # the value exported by the parent rather than wipe it on re-source.
  local _child="$TEST_TMPDIR/child-resolve.sh"
  printf '#!/bin/bash\n' > "$_child"
  printf 'set -euo pipefail\n' >> "$_child"
  printf 'source "$RITE_LIB_DIR/providers/provider-interface.sh"\n' >> "$_child"
  printf 'load_provider claude\n' >> "$_child"
  printf 'provider_resolve_model review\n' >> "$_child"
  chmod +x "$_child"

  run bash -c "
    export PATH=\"$STUB_BIN:\$PATH\"
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_REVIEW_MODEL='claude-fable-5-1'
    export RITE_MODEL_FALLBACK='claude-sonnet-4-6'
    source '$RITE_LIB_DIR/providers/provider-interface.sh'
    load_provider 'claude'
    provider_detect_cli 2>/dev/null || true
    provider_healthcheck 2>/dev/null
    bash \"$_child\"
  " 2>&1
  [ "$status" -eq 0 ]
  # Child must return the fallback: it inherited the exported _RITE_CAPPED_MODELS
  # and the idempotent := preserved it on re-source of claude.sh
  [[ "$output" == *"claude-sonnet-4-6"* ]]
}
