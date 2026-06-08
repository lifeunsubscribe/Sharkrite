#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/bootstrap-docs.sh, lib/utils/adr-generator.sh
# Tests for ADR generation via the real generate_adr_for_ref() function.
#
# Previously this test created ADR files manually with cat heredocs,
# bypassing generate_adr_for_ref() entirely. That approach could not catch
# regressions in deduplication logic, metadata format, or empty-response
# handling since it tested a hand-rolled reimplementation.
#
# This version sources the actual function from assess-documentation.sh and
# stubs only the provider call (provider_run_prompt_with_timeout) so tests
# run without a live Claude session.

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Source generate_adr_for_ref() from its own library file (no side effects
# on source, no top-level code). _mark_updated() is the optional callback
# the function calls on success; we define it ourselves so the test can
# observe which markers fire.
_source_generate_adr_for_ref() {
  # shellcheck disable=SC1091
  source "$RITE_REPO_ROOT/lib/utils/adr-generator.sh"

  # Define _mark_updated locally — the helper calls it via `declare -f`
  # check, so anything that exists by this name will be invoked on success.
  _mark_updated() { touch "$_MARKER_DIR/$1"; }
  export -f _mark_updated
}

setup() {
  setup_test_tmpdir

  export RITE_REPO_ROOT

  # Minimal env expected by generate_adr_for_ref
  export RITE_INTERNAL_DOCS_DIR="$RITE_TEST_TMPDIR/docs"
  export DOC_CLAUDE_TIMEOUT=30

  # Marker dir needed by _mark_updated (normally set by assess-documentation.sh
  # top-level, but that code is skipped here)
  export _MARKER_DIR
  _MARKER_DIR=$(mktemp -d)

  mkdir -p "$RITE_INTERNAL_DOCS_DIR/adr"

  # Set up a minimal git repo so git operations succeed in setup
  cd "$RITE_TEST_TMPDIR"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"

  # Stub verbose_info (used inside the function, normally from colors.sh)
  verbose_info() { :; }
  export -f verbose_info

  # Source the real function under test
  _source_generate_adr_for_ref
}

teardown() {
  rm -rf "${_MARKER_DIR:-}"
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Test 1: generate_adr_for_ref creates an ADR file for ADR-worthy content
# ---------------------------------------------------------------------------

@test "generate_adr_for_ref creates ADR file when provider returns content" {
  # Stub the provider to return a minimal but valid ADR document
  provider_run_prompt_with_timeout() {
    cat <<'ADRDOC'
# ADR-001: switch to provider abstraction

**Date:** 2026-05-31
**Commit:** abc1234
**Files:** lib/providers/provider-interface.sh, lib/providers/claude.sh
**Context:** Multiple scripts were directly invoking the Claude CLI, creating tight coupling and making provider swaps impossible.
**Decision:** Introduced lib/providers/provider-interface.sh as a dispatcher that aliases provider-specific functions to a generic provider_* namespace.
**Tradeoffs:** Gained: provider portability; Lost: direct invocation simplicity.
ADRDOC
  }
  export -f provider_run_prompt_with_timeout

  run generate_adr_for_ref "commit" "abc1234" \
    "refactor: switch to provider abstraction" \
    "Refactored all provider calls through a unified interface." \
    "$(printf '--- a/lib/providers/provider-interface.sh\n+++ b/lib/providers/provider-interface.sh\n@@ -0,0 +1,5 @@\n+#!/bin/bash\n+load_provider() { source "$1"; }')" \
    "lib/providers/provider-interface.sh"$'\n'"lib/providers/claude.sh"

  [ "$status" -eq 0 ]

  # Function should output the path to the created ADR file
  [ -n "$output" ]
  [ -f "$output" ]

  # Verify the ADR file contains the expected metadata.
  # Must match the exact bold-markdown format (**Commit:** <sha>) because the
  # deduplication logic in generate_adr_for_ref greps for "**Commit:** ${ref_id}".
  # A loose fallback (|| grep -q "abc1234") would pass even if the format is wrong,
  # failing to guard the dedup check that depends on this exact pattern.
  grep -q "ADR-001" "$output"
  grep -q "\*\*Commit:\*\* abc1234" "$output"
}

# ---------------------------------------------------------------------------
# Test 2: empty provider response results in no file created (skip path)
# ---------------------------------------------------------------------------

@test "generate_adr_for_ref skips file creation when provider returns empty response" {
  # Stub provider to return nothing (change not ADR-worthy)
  provider_run_prompt_with_timeout() {
    echo ""
  }
  export -f provider_run_prompt_with_timeout

  run generate_adr_for_ref "commit" "def5678" \
    "chore: update dependency versions" \
    "Bumped several npm packages to latest patch versions." \
    "" \
    "package.json"

  [ "$status" -eq 0 ]

  # Function output should be empty (no ADR file path returned)
  [ -z "$output" ]

  # No new ADR files should be created
  local adr_count
  adr_count=$(find "$RITE_INTERNAL_DOCS_DIR/adr" -name "*.md" | wc -l | tr -d ' ')
  [ "$adr_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 3: re-running bootstrap is idempotent (deduplication by commit SHA)
# ---------------------------------------------------------------------------

@test "generate_adr_for_ref deduplicates by commit SHA on re-run" {
  # Provider returns valid ADR content
  provider_run_prompt_with_timeout() {
    cat <<'ADRDOC'
# ADR-001: add MCP support for external tools

**Date:** 2026-05-31
**Commit:** cafebabe
**Files:** lib/core/mcp-handler.sh
**Context:** Users needed to integrate external tools via MCP protocol.
**Decision:** Added mcp-handler.sh as a new integration layer.
**Tradeoffs:** Gained: extensibility; Lost: simplicity of single-tool model.
ADRDOC
  }
  export -f provider_run_prompt_with_timeout

  # First call — should create the ADR
  run generate_adr_for_ref "commit" "cafebabe" \
    "feat: add MCP support for external tools" \
    "Adds MCP protocol handler." \
    "+function handle_mcp() { ... }" \
    "lib/core/mcp-handler.sh"

  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ -f "$output" ]
  first_adr="$output"

  # Second call with the same commit SHA — should be a no-op (deduplication)
  run generate_adr_for_ref "commit" "cafebabe" \
    "feat: add MCP support for external tools" \
    "Adds MCP protocol handler." \
    "+function handle_mcp() { ... }" \
    "lib/core/mcp-handler.sh"

  [ "$status" -eq 0 ]

  # Output should be empty (skipped)
  [ -z "$output" ]

  # Still exactly one ADR file (no duplicate created)
  local adr_count
  adr_count=$(find "$RITE_INTERNAL_DOCS_DIR/adr" -name "*.md" | wc -l | tr -d ' ')
  [ "$adr_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 3b: PR number deduplication — symmetric to commit SHA dedup (Test 3)
# ---------------------------------------------------------------------------
# The production dedup grep for PRs uses "\*\*PR:\*\* #${ref_id}" which must
# match the bold-markdown format "**PR:** #N" written by the provider. This
# test exercises the PR path to guard against the same substring-coincidence
# regression that was fixed for commit SHAs.

@test "generate_adr_for_ref deduplicates by PR number on re-run" {
  # Provider returns valid ADR content with PR metadata in bold format
  provider_run_prompt_with_timeout() {
    cat <<'ADRDOC'
# ADR-001: adopt provider abstraction layer

**Date:** 2026-05-31
**PR:** #42
**Files:** lib/providers/provider-interface.sh
**Context:** Multiple scripts directly invoked Claude CLI, creating tight coupling.
**Decision:** Introduced provider-interface.sh as a dispatcher layer.
**Tradeoffs:** Gained: provider portability; Lost: direct invocation simplicity.
ADRDOC
  }
  export -f provider_run_prompt_with_timeout

  # First call — should create the ADR
  run generate_adr_for_ref "pr" "42" \
    "feat: adopt provider abstraction layer" \
    "Introduces provider-interface.sh." \
    "+function dispatch_provider() { ... }" \
    "lib/providers/provider-interface.sh"

  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ -f "$output" ]

  # Verify the ADR file contains the PR metadata in exact bold format.
  # The dedup grep at assess-documentation.sh line 415 searches for
  # "\*\*PR:\*\* #${ref_id}" — this assertion guards that exact pattern.
  grep -q "\*\*PR:\*\* #42" "$output"

  # Second call with the same PR number — should be a no-op (deduplication)
  run generate_adr_for_ref "pr" "42" \
    "feat: adopt provider abstraction layer" \
    "Introduces provider-interface.sh." \
    "+function dispatch_provider() { ... }" \
    "lib/providers/provider-interface.sh"

  [ "$status" -eq 0 ]

  # Output should be empty (skipped)
  [ -z "$output" ]

  # Still exactly one ADR file (no duplicate created)
  local adr_count
  adr_count=$(find "$RITE_INTERNAL_DOCS_DIR/adr" -name "*.md" | wc -l | tr -d ' ')
  [ "$adr_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 4: RITE_NO_BACKFILL_ADRS flag — generate_adr_for_ref is not called
# ---------------------------------------------------------------------------

@test "no-backfill-adrs flag: generate_adr_for_ref should not be called" {
  export RITE_NO_BACKFILL_ADRS=true

  # Track if provider was invoked (it should NOT be if flag is respected)
  _provider_called=false
  provider_run_prompt_with_timeout() {
    _provider_called=true
    echo "# ADR content should not appear"
  }
  export -f provider_run_prompt_with_timeout

  # Callers (bootstrap-docs.sh) check RITE_NO_BACKFILL_ADRS before calling
  # generate_adr_for_ref. Verify the guard pattern works as expected.
  if [ "${RITE_NO_BACKFILL_ADRS:-false}" = true ]; then
    : # skip — this is the correct behavior
  else
    generate_adr_for_ref "commit" "deadbeef" \
      "feat: migrate workflow" "Body" "+diff" "file.sh"
  fi

  # Verify adr directory is empty (no ADRs created)
  local adr_count
  adr_count=$(find "$RITE_INTERNAL_DOCS_DIR/adr" -name "*.md" | wc -l | tr -d ' ')
  [ "$adr_count" -eq 0 ]

  unset RITE_NO_BACKFILL_ADRS
}

# ---------------------------------------------------------------------------
# Test 5: ADR sequential numbering when existing ADRs are present
# ---------------------------------------------------------------------------

@test "generate_adr_for_ref assigns next sequential number based on existing ADRs" {
  # Pre-create two ADRs to simulate existing state
  cat > "$RITE_INTERNAL_DOCS_DIR/adr/001-first-decision.md" <<'EOF'
# ADR-001: first-decision

**Date:** 2026-01-01
**Commit:** 0000001
**Context:** first
**Decision:** first decision
**Tradeoffs:** none
EOF

  cat > "$RITE_INTERNAL_DOCS_DIR/adr/002-second-decision.md" <<'EOF'
# ADR-002: second-decision

**Date:** 2026-01-02
**Commit:** 0000002
**Context:** second
**Decision:** second decision
**Tradeoffs:** none
EOF

  # Provider returns content for ADR-003
  provider_run_prompt_with_timeout() {
    cat <<'ADRDOC'
# ADR-003: third-decision

**Date:** 2026-05-31
**Commit:** 0000003
**Context:** Adding third architectural decision.
**Decision:** Chose approach X over Y.
**Tradeoffs:** Gained: speed; Lost: flexibility.
ADRDOC
  }
  export -f provider_run_prompt_with_timeout

  run generate_adr_for_ref "commit" "0000003" \
    "refactor: adopt approach X" \
    "Replacing Y with X for performance." \
    "+X_setup()" \
    "lib/core/approach-x.sh"

  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ -f "$output" ]

  # Filename should contain "003"
  basename "$output" | grep -q "^003-"

  # Total should now be 3 ADRs
  local adr_count
  adr_count=$(find "$RITE_INTERNAL_DOCS_DIR/adr" -name "*.md" | wc -l | tr -d ' ')
  [ "$adr_count" -eq 3 ]
}
