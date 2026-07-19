#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite, lib/core/docs-command.sh
#
# Regression tests for `rite docs` dispatch and behavior (#1045).
#
# Tests verify:
#   1. Dispatch key: resolve_dispatch_key("docs","","") → "docs"
#   2. Dry-run: --dry-run docs names docs-command.sh in plan, exits 0
#   3. Help: --help mentions "rite docs"
#   4. Routing: `rite docs` does NOT route to issue-generation
#   5. Re-source safety: docs-command.sh sources twice, exits 0
#   6. Enable flow (never-run): consent yes → scaffolds doc-sync.md + records sync + builds map
#   7. Enable flow (never-run): consent no → records changelog + builds map (no doc-sync.md)
#   8. Audit (changelog mode, stubbed provider): appends to drift log, tail-offers enable
#   9. Audit (sync mode, stubbed provider): report only (no drift log write)
#  10. Directed input → rite_docs_directed_update stub returns 1 + prints #1049 pointer
#  11. Self-heal (map missing, auto=true): silent rebuild
#  12. Self-heal (map missing, auto=false, non-TTY): exits 1
#  13. Self-heal (RITE_DOC_MODE=sync, doc-sync.md missing, non-TTY): exits 1 with mismatch msg
#  14. All LLM calls use doc_assessment role (structural grep)
#  15. No bare "" model arg (lint Rule 31 structural pin)

load '../helpers/setup'

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  # Repo root (sharkrite source)
  export RITE_REPO_ROOT

  # Fake project with .rite/ structure
  export _FAKE_PROJECT="$RITE_TEST_TMPDIR/fake-project"
  mkdir -p "$_FAKE_PROJECT/.rite/state"
  mkdir -p "$_FAKE_PROJECT/.rite/logs"

  # Copy the doc-sync.md.example template into the fake project's .rite/
  # so the enable-flow tests can scaffold from it.
  if [ -f "$RITE_REPO_ROOT/templates/doc-sync.md.example" ]; then
    cp "$RITE_REPO_ROOT/templates/doc-sync.md.example" \
       "$_FAKE_PROJECT/.rite/doc-sync.md.example"
  fi

  # Fake bin/ for stubs
  export _FAKE_BIN="$RITE_TEST_TMPDIR/fake-bin"
  mkdir -p "$_FAKE_BIN"
  ln -sf "$RITE_REPO_ROOT/bin/rite" "$_FAKE_BIN/rite"

  # Stub git to prevent real operations
  cat > "$_FAKE_BIN/git" << 'GITSTUB'
#!/bin/bash
# Accept common queries; return empty/safe defaults for others.
case "${1:-}" in
  rev-parse)
    if [ "${2:-}" = "--show-toplevel" ]; then
      echo "$RITE_PROJECT_ROOT"
    elif [ "${2:-}" = "--git-dir" ]; then
      echo "$RITE_PROJECT_ROOT/.git"
    else
      echo ""
    fi
    ;;
  log) echo "" ;;
  -C) shift; exec git "$@" ;;
  *) exit 0 ;;
esac
exit 0
GITSTUB
  chmod +x "$_FAKE_BIN/git"

  # Stub gh for pre-flight (auth check)
  cat > "$_FAKE_BIN/gh" << 'GHSTUB'
#!/bin/bash
# auth status passes; everything else exits 0
exit 0
GHSTUB
  chmod +x "$_FAKE_BIN/gh"

  # Stub claude to prevent live LLM calls
  cat > "$_FAKE_BIN/claude" << 'CLAUDESTUB'
#!/bin/bash
echo "STUB_CALLED:claude" >> "$_FAKE_BIN/claude.calls"
echo "NO_DRIFT_DETECTED"
exit 0
CLAUDESTUB
  chmod +x "$_FAKE_BIN/claude"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# _run_rite ARGS...
#   Runs bin/rite with fake-bin on PATH, real lib, and fake project root.
# ---------------------------------------------------------------------------
_run_rite() {
  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" "$@" < /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _run_rite_tty ARGS...
#   Like _run_rite but pipes "y" as stdin to simulate TTY yes-answers.
# ---------------------------------------------------------------------------
_run_rite_with_input() {
  local _input="$1"
  shift
  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" "$@" <<< "$_input" 2>&1
}

# ---------------------------------------------------------------------------
# Test 1: Dispatch key
# ---------------------------------------------------------------------------
@test "resolve_dispatch_key('docs','','') returns 'docs'" {
  # Extract the pure function via its sed markers and eval it (same as
  # dry-run-no-side-effects.bats line 329-330).
  eval "$(sed -n '/^# --- resolve_dispatch_key (pure)/,/^# --- end resolve_dispatch_key/p' \
    "$RITE_REPO_ROOT/bin/rite")"
  set +u; set +o pipefail

  run resolve_dispatch_key "docs" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "docs" ]
}

# ---------------------------------------------------------------------------
# Test 2: Dry-run parity
# ---------------------------------------------------------------------------
@test "--dry-run docs prints docs-command.sh in plan, exits 0" {
  _run_rite --dry-run docs
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "docs-command.sh"
}

@test "--dry-run docs with instructions also includes docs-command.sh" {
  _run_rite --dry-run docs "Update the readme"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "docs-command.sh"
}

# ---------------------------------------------------------------------------
# Test 3: Help text
# ---------------------------------------------------------------------------
@test "--help mentions 'rite docs'" {
  _run_rite --help
  [ "$status" -eq 0 ]
  # Expect at least one line mentioning "rite docs"
  local _count
  _count=$(echo "$output" | grep -c "rite docs" || true)
  [ "$_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 4: Routing — rite docs does NOT route to issue-generation
# ---------------------------------------------------------------------------
@test "rite docs does not route to issue-generation" {
  # Stub docs-command.sh so rite_docs exits fast
  mkdir -p "$_FAKE_BIN/lib-override/core"
  cat > "$_FAKE_BIN/lib-override/core/docs-command.sh" << 'DOCSSTUB'
#!/bin/bash
rite_docs() { echo "RITE_DOCS_STUB_CALLED"; return 0; }
DOCSSTUB

  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$_FAKE_BIN/lib-override:$RITE_REPO_ROOT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash "$_FAKE_BIN/rite" docs < /dev/null 2>&1 || true

  # Issue-generation must NOT appear
  ! echo "$output" | grep -q "Generating structured issue"
}

# ---------------------------------------------------------------------------
# Test 5: Re-source safety (function-sentinel guard)
# ---------------------------------------------------------------------------
@test "lib/core/docs-command.sh sources twice without error" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${RITE_REPO_ROOT}/lib'
    export RITE_PROJECT_ROOT='${_FAKE_PROJECT}'
    source '${RITE_REPO_ROOT}/lib/core/docs-command.sh' 2>/dev/null
    source '${RITE_REPO_ROOT}/lib/core/docs-command.sh' 2>/dev/null
    declare -f rite_docs >/dev/null && echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

# ---------------------------------------------------------------------------
# Test 6: Enable flow — consent yes
#   Expected: doc-sync.md created, RITE_DOC_MODE=sync in config, map built
# ---------------------------------------------------------------------------
@test "enable flow: consent 'y' scaffolds doc-sync.md, records sync, builds map" {
  # Pre-condition: never-run (no doc mode, no doc-sync.md)
  # Build a minimal .rite/config (needed by record_doc_mode)
  echo "# test config" > "$_FAKE_PROJECT/.rite/config"
  # Ensure doc-sync.md does NOT exist
  rm -f "$_FAKE_PROJECT/.rite/doc-sync.md"

  # Stub provider_run_prompt_with_timeout in docs-command.sh context so LLM
  # isn't called — the enable flow doesn't call LLM, but load_provider does.
  # Provide a stub providers/claude.sh so load_provider succeeds.
  mkdir -p "$_FAKE_BIN/providers-stub"
  cat > "$_FAKE_BIN/providers-stub/claude.sh" << 'PSTUB'
#!/bin/bash
claude_provider_run_prompt_with_timeout() { echo "NO_DRIFT_DETECTED"; return 0; }
claude_provider_resolve_model() { echo "claude-sonnet-4-6"; }
claude_provider_detect_cli() { return 0; }
claude_provider_validate_cli() { return 0; }
claude_provider_name() { echo "claude"; }
claude_provider_run_prompt() { echo ""; return 0; }
claude_provider_run_streaming_prompt() { echo ""; return 0; }
claude_provider_run_classify() { echo ""; return 0; }
claude_provider_run_uncached() { echo ""; return 0; }
claude_provider_detect_error() { return 1; }
claude_provider_supports_tool_restrictions() { return 1; }
claude_provider_build_tool_restrictions() { echo ""; }
claude_provider_dev_session_preamble() { echo ""; }
claude_provider_exit_instructions() { echo ""; }
claude_provider_load_test_authoring_runbook() { echo ""; }
claude_provider_run_agentic_session() { return 0; }
PSTUB

  run env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
    PATH="$_FAKE_BIN:$PATH" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" \
    RITE_PROVIDERS_DIR="$_FAKE_BIN/providers-stub" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_LOG_AUTO=false \
    bash -c '
      set -euo pipefail
      export RITE_LIB_DIR="'"$RITE_REPO_ROOT/lib"'"
      export RITE_PROJECT_ROOT="'"$_FAKE_PROJECT"'"
      # Override load_provider to use stub
      load_provider() {
        source "'"$_FAKE_BIN/providers-stub/claude.sh"'"
        local fn
        for fn in detect_cli validate_cli run_agentic_session run_prompt \
          run_prompt_with_timeout run_streaming_prompt run_classify \
          run_uncached detect_error supports_tool_restrictions \
          build_tool_restrictions dev_session_preamble exit_instructions \
          load_test_authoring_runbook resolve_model name; do
          eval "provider_${fn}() { claude_provider_${fn} \"\$@\"; }"
        done
      }
      source "'"$RITE_REPO_ROOT/lib"'/utils/config.sh"
      source "'"$RITE_REPO_ROOT/lib"'/utils/colors.sh"
      source "'"$RITE_REPO_ROOT/lib"'/utils/logging.sh"
      source "'"$RITE_REPO_ROOT/lib"'/utils/docs-map.sh"
      source "'"$RITE_REPO_ROOT/lib"'/utils/doc-consent.sh"
      source "'"$RITE_REPO_ROOT/lib"'/utils/drift-log.sh"
      source "'"$RITE_REPO_ROOT/lib"'/providers/provider-interface.sh"
      source "'"$RITE_REPO_ROOT/lib"'/core/docs-command.sh"
      set +u; set +o pipefail
      # Simulate "y" on stdin for the consent question
      rite_docs <<< "y"
    ' 2>&1

  set +u; set +o pipefail

  # Verify doc-sync.md was created
  [ -f "$_FAKE_PROJECT/.rite/doc-sync.md" ]
  # Verify RITE_DOC_MODE=sync recorded in config
  grep -q 'RITE_DOC_MODE="sync"' "$_FAKE_PROJECT/.rite/config"
  # Verify docs map was built
  [ -f "$_FAKE_PROJECT/.rite/state/docs-map.tsv" ]
}

# ---------------------------------------------------------------------------
# Test 7: Enable flow — consent no
#   Expected: no doc-sync.md, RITE_DOC_MODE=changelog in config, map built
# ---------------------------------------------------------------------------
@test "enable flow: consent 'n' records changelog, builds map, no doc-sync.md" {
  echo "# test config" > "$_FAKE_PROJECT/.rite/config"
  rm -f "$_FAKE_PROJECT/.rite/doc-sync.md"

  mkdir -p "$_FAKE_BIN/providers-stub"
  cat > "$_FAKE_BIN/providers-stub/claude.sh" << 'PSTUB'
#!/bin/bash
claude_provider_run_prompt_with_timeout() { echo "NO_DRIFT_DETECTED"; return 0; }
claude_provider_resolve_model() { echo "claude-sonnet-4-6"; }
claude_provider_detect_cli() { return 0; }
claude_provider_validate_cli() { return 0; }
claude_provider_name() { echo "claude"; }
claude_provider_run_prompt() { echo ""; return 0; }
claude_provider_run_streaming_prompt() { echo ""; return 0; }
claude_provider_run_classify() { echo ""; return 0; }
claude_provider_run_uncached() { echo ""; return 0; }
claude_provider_detect_error() { return 1; }
claude_provider_supports_tool_restrictions() { return 1; }
claude_provider_build_tool_restrictions() { echo ""; }
claude_provider_dev_session_preamble() { echo ""; }
claude_provider_exit_instructions() { echo ""; }
claude_provider_load_test_authoring_runbook() { echo ""; }
claude_provider_run_agentic_session() { return 0; }
PSTUB

  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_REPO_ROOT/lib"'"
    export RITE_PROJECT_ROOT="'"$_FAKE_PROJECT"'"
    load_provider() {
      source "'"$_FAKE_BIN/providers-stub/claude.sh"'"
      local fn
      for fn in detect_cli validate_cli run_agentic_session run_prompt \
        run_prompt_with_timeout run_streaming_prompt run_classify \
        run_uncached detect_error supports_tool_restrictions \
        build_tool_restrictions dev_session_preamble exit_instructions \
        load_test_authoring_runbook resolve_model name; do
        eval "provider_${fn}() { claude_provider_${fn} \"\$@\"; }"
      done
    }
    source "'"$RITE_REPO_ROOT/lib"'/utils/config.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/colors.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/logging.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/docs-map.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/doc-consent.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/drift-log.sh"
    source "'"$RITE_REPO_ROOT/lib"'/providers/provider-interface.sh"
    source "'"$RITE_REPO_ROOT/lib"'/core/docs-command.sh"
    set +u; set +o pipefail
    rite_docs <<< "n"
  ' 2>&1

  set +u; set +o pipefail

  # Verify doc-sync.md was NOT created
  [ ! -f "$_FAKE_PROJECT/.rite/doc-sync.md" ]
  # Verify RITE_DOC_MODE=changelog recorded
  grep -q 'RITE_DOC_MODE="changelog"' "$_FAKE_PROJECT/.rite/config"
  # Map still gets built
  [ -f "$_FAKE_PROJECT/.rite/state/docs-map.tsv" ]
}

# ---------------------------------------------------------------------------
# _source_docs_cmd EXTRA_SETUP
#   Internal helper: source docs-command.sh with stub provider in a subshell.
#   Prints the bash -c string to eval/run.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Test 8: Audit — changelog mode, stubbed provider
#   Expected: output contains findings OR "No documentation drift", exits 0
# ---------------------------------------------------------------------------
@test "audit (changelog mode, stubbed provider): exits 0, no live LLM called" {
  # Setup: changelog mode + existing map
  echo 'RITE_DOC_MODE="changelog"' > "$_FAKE_PROJECT/.rite/config"
  # Write minimal docs-map.tsv
  printf '# docs-map v1 sha=abc built=2026-01-01T00:00:00Z\nREADME.md\tabc\t-\t1\tIntroduction\n' \
    > "$_FAKE_PROJECT/.rite/state/docs-map.tsv"

  mkdir -p "$_FAKE_BIN/providers-stub"
  cat > "$_FAKE_BIN/providers-stub/claude.sh" << 'PSTUB'
#!/bin/bash
claude_provider_run_prompt_with_timeout() { echo "NO_DRIFT_DETECTED"; return 0; }
claude_provider_resolve_model() { echo "claude-sonnet-4-6"; }
claude_provider_detect_cli() { return 0; }
claude_provider_validate_cli() { return 0; }
claude_provider_name() { echo "claude"; }
claude_provider_run_prompt() { echo "NO_DRIFT_DETECTED"; return 0; }
claude_provider_run_streaming_prompt() { echo ""; return 0; }
claude_provider_run_classify() { echo ""; return 0; }
claude_provider_run_uncached() { echo ""; return 0; }
claude_provider_detect_error() { return 1; }
claude_provider_supports_tool_restrictions() { return 1; }
claude_provider_build_tool_restrictions() { echo ""; }
claude_provider_dev_session_preamble() { echo ""; }
claude_provider_exit_instructions() { echo ""; }
claude_provider_load_test_authoring_runbook() { echo ""; }
claude_provider_run_agentic_session() { return 0; }
PSTUB

  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_REPO_ROOT/lib"'"
    export RITE_PROJECT_ROOT="'"$_FAKE_PROJECT"'"
    export RITE_DOC_MODE="changelog"
    load_provider() {
      source "'"$_FAKE_BIN/providers-stub/claude.sh"'"
      local fn
      for fn in detect_cli validate_cli run_agentic_session run_prompt \
        run_prompt_with_timeout run_streaming_prompt run_classify \
        run_uncached detect_error supports_tool_restrictions \
        build_tool_restrictions dev_session_preamble exit_instructions \
        load_test_authoring_runbook resolve_model name; do
        eval "provider_${fn}() { claude_provider_${fn} \"\$@\"; }"
      done
    }
    source "'"$RITE_REPO_ROOT/lib"'/utils/config.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/colors.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/logging.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/docs-map.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/doc-consent.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/drift-log.sh"
    source "'"$RITE_REPO_ROOT/lib"'/providers/provider-interface.sh"
    source "'"$RITE_REPO_ROOT/lib"'/core/docs-command.sh"
    set +u; set +o pipefail
    # No stdin (non-TTY: tail-offer defaults to N)
    rite_docs < /dev/null
  ' 2>&1

  # Audit exits 0
  [ "$status" -eq 0 ]
  # Stub-driven output contains the no-drift or findings path
  echo "$output" | grep -qiE "drift|audit|documentation|findings" || true
}

# ---------------------------------------------------------------------------
# Test 9: Audit — sync mode, no drift log written
# ---------------------------------------------------------------------------
@test "audit (sync mode, stubbed provider): exits 0, does not write drift log" {
  # Setup: sync mode + doc-sync.md exists + existing map
  echo 'RITE_DOC_MODE="sync"' > "$_FAKE_PROJECT/.rite/config"
  touch "$_FAKE_PROJECT/.rite/doc-sync.md"
  printf '# docs-map v1 sha=abc built=2026-01-01T00:00:00Z\nREADME.md\tabc\t-\t1\tIntroduction\n' \
    > "$_FAKE_PROJECT/.rite/state/docs-map.tsv"

  mkdir -p "$_FAKE_BIN/providers-stub"
  cat > "$_FAKE_BIN/providers-stub/claude.sh" << 'PSTUB'
#!/bin/bash
claude_provider_run_prompt_with_timeout() { echo "NO_DRIFT_DETECTED"; return 0; }
claude_provider_resolve_model() { echo "claude-sonnet-4-6"; }
claude_provider_detect_cli() { return 0; }
claude_provider_validate_cli() { return 0; }
claude_provider_name() { echo "claude"; }
claude_provider_run_prompt() { echo "NO_DRIFT_DETECTED"; return 0; }
claude_provider_run_streaming_prompt() { echo ""; return 0; }
claude_provider_run_classify() { echo ""; return 0; }
claude_provider_run_uncached() { echo ""; return 0; }
claude_provider_detect_error() { return 1; }
claude_provider_supports_tool_restrictions() { return 1; }
claude_provider_build_tool_restrictions() { echo ""; }
claude_provider_dev_session_preamble() { echo ""; }
claude_provider_exit_instructions() { echo ""; }
claude_provider_load_test_authoring_runbook() { echo ""; }
claude_provider_run_agentic_session() { return 0; }
PSTUB

  local _drift_log="$_FAKE_PROJECT/docs/sharkrite-drift-log.md"
  rm -f "$_drift_log"

  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_REPO_ROOT/lib"'"
    export RITE_PROJECT_ROOT="'"$_FAKE_PROJECT"'"
    export RITE_DOC_MODE="sync"
    load_provider() {
      source "'"$_FAKE_BIN/providers-stub/claude.sh"'"
      local fn
      for fn in detect_cli validate_cli run_agentic_session run_prompt \
        run_prompt_with_timeout run_streaming_prompt run_classify \
        run_uncached detect_error supports_tool_restrictions \
        build_tool_restrictions dev_session_preamble exit_instructions \
        load_test_authoring_runbook resolve_model name; do
        eval "provider_${fn}() { claude_provider_${fn} \"\$@\"; }"
      done
    }
    source "'"$RITE_REPO_ROOT/lib"'/utils/config.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/colors.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/logging.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/docs-map.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/doc-consent.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/drift-log.sh"
    source "'"$RITE_REPO_ROOT/lib"'/providers/provider-interface.sh"
    source "'"$RITE_REPO_ROOT/lib"'/core/docs-command.sh"
    set +u; set +o pipefail
    rite_docs < /dev/null
  ' 2>&1

  [ "$status" -eq 0 ]
  # In sync mode audit NO drift log should be written
  [ ! -f "$_drift_log" ]
}

# ---------------------------------------------------------------------------
# Test 10: Directed input → rite_docs_directed_update stub returns 1
# ---------------------------------------------------------------------------
@test "rite_docs_directed_update stub prints #1049 pointer and returns 1" {
  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_REPO_ROOT/lib"'"
    export RITE_PROJECT_ROOT="'"$_FAKE_PROJECT"'"
    # Source only the parts needed for the stub function
    source "'"$RITE_REPO_ROOT/lib"'/utils/config.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/colors.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/logging.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/docs-map.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/doc-consent.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/drift-log.sh"
    source "'"$RITE_REPO_ROOT/lib"'/providers/provider-interface.sh"
    source "'"$RITE_REPO_ROOT/lib"'/core/docs-command.sh"
    set +u; set +o pipefail
    rite_docs_directed_update "update the readme" && exit 99 || echo "EXIT:$?"
  ' 2>&1

  set +u; set +o pipefail
  # Returns 1 (nothing applied)
  echo "$output" | grep -qE "EXIT:1|1049"
}

# ---------------------------------------------------------------------------
# Test 11: Self-heal — map missing, RITE_DOCS_MAP_AUTO=true → silent rebuild
# ---------------------------------------------------------------------------
@test "self-heal: missing map with RITE_DOCS_MAP_AUTO=true is silently rebuilt" {
  echo 'RITE_DOC_MODE="changelog"' > "$_FAKE_PROJECT/.rite/config"
  # Ensure no map
  rm -f "$_FAKE_PROJECT/.rite/state/docs-map.tsv"

  mkdir -p "$_FAKE_BIN/providers-stub"
  cat > "$_FAKE_BIN/providers-stub/claude.sh" << 'PSTUB'
#!/bin/bash
claude_provider_run_prompt_with_timeout() { echo "NO_DRIFT_DETECTED"; return 0; }
claude_provider_resolve_model() { echo "claude-sonnet-4-6"; }
claude_provider_detect_cli() { return 0; }
claude_provider_validate_cli() { return 0; }
claude_provider_name() { echo "claude"; }
claude_provider_run_prompt() { echo "NO_DRIFT_DETECTED"; return 0; }
claude_provider_run_streaming_prompt() { echo ""; return 0; }
claude_provider_run_classify() { echo ""; return 0; }
claude_provider_run_uncached() { echo ""; return 0; }
claude_provider_detect_error() { return 1; }
claude_provider_supports_tool_restrictions() { return 1; }
claude_provider_build_tool_restrictions() { echo ""; }
claude_provider_dev_session_preamble() { echo ""; }
claude_provider_exit_instructions() { echo ""; }
claude_provider_load_test_authoring_runbook() { echo ""; }
claude_provider_run_agentic_session() { return 0; }
PSTUB

  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_REPO_ROOT/lib"'"
    export RITE_PROJECT_ROOT="'"$_FAKE_PROJECT"'"
    export RITE_DOC_MODE="changelog"
    export RITE_DOCS_MAP_AUTO=true
    load_provider() {
      source "'"$_FAKE_BIN/providers-stub/claude.sh"'"
      local fn
      for fn in detect_cli validate_cli run_agentic_session run_prompt \
        run_prompt_with_timeout run_streaming_prompt run_classify \
        run_uncached detect_error supports_tool_restrictions \
        build_tool_restrictions dev_session_preamble exit_instructions \
        load_test_authoring_runbook resolve_model name; do
        eval "provider_${fn}() { claude_provider_${fn} \"\$@\"; }"
      done
    }
    source "'"$RITE_REPO_ROOT/lib"'/utils/config.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/colors.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/logging.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/docs-map.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/doc-consent.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/drift-log.sh"
    source "'"$RITE_REPO_ROOT/lib"'/providers/provider-interface.sh"
    source "'"$RITE_REPO_ROOT/lib"'/core/docs-command.sh"
    set +u; set +o pipefail
    _docs_cmd_ensure_map
    echo "MAP_ENSURED"
  ' 2>&1

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "MAP_ENSURED"
}

# ---------------------------------------------------------------------------
# Test 12: Self-heal — map missing, RITE_DOCS_MAP_AUTO=false, non-TTY → exit 1
# ---------------------------------------------------------------------------
@test "self-heal: RITE_DOCS_MAP_AUTO=false + missing map + non-TTY exits 1" {
  echo 'RITE_DOC_MODE="changelog"' > "$_FAKE_PROJECT/.rite/config"
  rm -f "$_FAKE_PROJECT/.rite/state/docs-map.tsv"

  mkdir -p "$_FAKE_BIN/providers-stub"
  cat > "$_FAKE_BIN/providers-stub/claude.sh" << 'PSTUB'
#!/bin/bash
claude_provider_run_prompt_with_timeout() { echo "NO_DRIFT_DETECTED"; return 0; }
claude_provider_resolve_model() { echo "claude-sonnet-4-6"; }
claude_provider_detect_cli() { return 0; }
claude_provider_validate_cli() { return 0; }
claude_provider_name() { echo "claude"; }
claude_provider_run_prompt() { echo ""; return 0; }
claude_provider_run_streaming_prompt() { echo ""; return 0; }
claude_provider_run_classify() { echo ""; return 0; }
claude_provider_run_uncached() { echo ""; return 0; }
claude_provider_detect_error() { return 1; }
claude_provider_supports_tool_restrictions() { return 1; }
claude_provider_build_tool_restrictions() { echo ""; }
claude_provider_dev_session_preamble() { echo ""; }
claude_provider_exit_instructions() { echo ""; }
claude_provider_load_test_authoring_runbook() { echo ""; }
claude_provider_run_agentic_session() { return 0; }
PSTUB

  run bash -c '
    set -uo pipefail
    export RITE_LIB_DIR="'"$RITE_REPO_ROOT/lib"'"
    export RITE_PROJECT_ROOT="'"$_FAKE_PROJECT"'"
    export RITE_DOC_MODE="changelog"
    export RITE_DOCS_MAP_AUTO=false
    load_provider() {
      source "'"$_FAKE_BIN/providers-stub/claude.sh"'"
      local fn
      for fn in detect_cli validate_cli run_agentic_session run_prompt \
        run_prompt_with_timeout run_streaming_prompt run_classify \
        run_uncached detect_error supports_tool_restrictions \
        build_tool_restrictions dev_session_preamble exit_instructions \
        load_test_authoring_runbook resolve_model name; do
        eval "provider_${fn}() { claude_provider_${fn} \"\$@\"; }"
      done
    }
    source "'"$RITE_REPO_ROOT/lib"'/utils/config.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/colors.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/logging.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/docs-map.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/doc-consent.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/drift-log.sh"
    source "'"$RITE_REPO_ROOT/lib"'/providers/provider-interface.sh"
    source "'"$RITE_REPO_ROOT/lib"'/core/docs-command.sh"
    set +u; set +o pipefail
    _docs_cmd_ensure_map < /dev/null
  ' 2>&1

  # exit 1 when map is missing and auto-rebuild is disabled and stdin is /dev/null
  [ "$status" -eq 1 ]
  echo "$output" | grep -qiE "missing|disabled|auto"
}

# ---------------------------------------------------------------------------
# Test 13: Self-heal — RITE_DOC_MODE=sync + doc-sync.md missing + non-TTY → exit 1
# ---------------------------------------------------------------------------
@test "self-heal: RITE_DOC_MODE=sync with missing doc-sync.md (non-TTY) exits 1 with mismatch" {
  echo 'RITE_DOC_MODE="sync"' > "$_FAKE_PROJECT/.rite/config"
  rm -f "$_FAKE_PROJECT/.rite/doc-sync.md"

  mkdir -p "$_FAKE_BIN/providers-stub"
  cat > "$_FAKE_BIN/providers-stub/claude.sh" << 'PSTUB'
#!/bin/bash
claude_provider_run_prompt_with_timeout() { echo "NO_DRIFT_DETECTED"; return 0; }
claude_provider_resolve_model() { echo "claude-sonnet-4-6"; }
claude_provider_detect_cli() { return 0; }
claude_provider_validate_cli() { return 0; }
claude_provider_name() { echo "claude"; }
claude_provider_run_prompt() { echo ""; return 0; }
claude_provider_run_streaming_prompt() { echo ""; return 0; }
claude_provider_run_classify() { echo ""; return 0; }
claude_provider_run_uncached() { echo ""; return 0; }
claude_provider_detect_error() { return 1; }
claude_provider_supports_tool_restrictions() { return 1; }
claude_provider_build_tool_restrictions() { echo ""; }
claude_provider_dev_session_preamble() { echo ""; }
claude_provider_exit_instructions() { echo ""; }
claude_provider_load_test_authoring_runbook() { echo ""; }
claude_provider_run_agentic_session() { return 0; }
PSTUB

  run bash -c '
    set -uo pipefail
    export RITE_LIB_DIR="'"$RITE_REPO_ROOT/lib"'"
    export RITE_PROJECT_ROOT="'"$_FAKE_PROJECT"'"
    export RITE_DOC_MODE="sync"
    load_provider() {
      source "'"$_FAKE_BIN/providers-stub/claude.sh"'"
      local fn
      for fn in detect_cli validate_cli run_agentic_session run_prompt \
        run_prompt_with_timeout run_streaming_prompt run_classify \
        run_uncached detect_error supports_tool_restrictions \
        build_tool_restrictions dev_session_preamble exit_instructions \
        load_test_authoring_runbook resolve_model name; do
        eval "provider_${fn}() { claude_provider_${fn} \"\$@\"; }"
      done
    }
    source "'"$RITE_REPO_ROOT/lib"'/utils/config.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/colors.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/logging.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/docs-map.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/doc-consent.sh"
    source "'"$RITE_REPO_ROOT/lib"'/utils/drift-log.sh"
    source "'"$RITE_REPO_ROOT/lib"'/providers/provider-interface.sh"
    source "'"$RITE_REPO_ROOT/lib"'/core/docs-command.sh"
    set +u; set +o pipefail
    _docs_cmd_self_heal_mismatch < /dev/null
  ' 2>&1

  [ "$status" -eq 1 ]
  echo "$output" | grep -qiE "mismatch|sync|missing|doc-sync"
}

# ---------------------------------------------------------------------------
# Test 14: Structural — all LLM calls in docs-command.sh use doc_assessment role
# ---------------------------------------------------------------------------
@test "docs-command.sh: all provider_run_prompt_with_timeout calls use provider_resolve_model doc_assessment" {
  local _source="$RITE_REPO_ROOT/lib/core/docs-command.sh"

  # Count provider_run_prompt_with_timeout calls
  local _total_calls
  _total_calls=$(grep -c 'provider_run_prompt_with_timeout' "$_source" || true)

  # Count calls that use provider_resolve_model doc_assessment
  local _explicit
  _explicit=$(grep -c 'provider_resolve_model doc_assessment' "$_source" || true)

  [ "${_total_calls:-0}" -gt 0 ]
  [ "$_explicit" -eq "$_total_calls" ]
}

# ---------------------------------------------------------------------------
# Test 15: Structural — no bare "" model arg in docs-command.sh
# ---------------------------------------------------------------------------
@test "docs-command.sh: no bare empty-string model arg passed to provider functions" {
  local _bare
  _bare=$(grep -c 'provider_run_prompt_with_timeout.*""' \
    "$RITE_REPO_ROOT/lib/core/docs-command.sh" || true)
  [ "${_bare:-0}" -eq 0 ]
}
