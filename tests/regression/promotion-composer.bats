#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/promotion-composer.sh
# Regression tests for the promotion PR body composer.
#
# Tests verify:
# 1. Re-source safety: both functions are defined after double-source.
# 2. Provider failure path: fallback body emitted, exit 0, Closes lines present.
# 3. Empty LLM output path: same as failure (fallback, exit 0, Closes lines).
# 4. LLM success path: narrative emitted AND deterministic Closes tail appended.
# 5. Deterministic tail is present in ALL paths (LLM does not own Closes lines).
# 6. Explicit promote role used (no bare "" model arg).
#
# Stub strategy (per test runbook §2):
#   - Binaries (git, gh, jq) stubbed by PATH manipulation with a fake bin dir.
#   - Library functions (integration_ledger_entries, provider_run_prompt_with_timeout,
#     provider_resolve_model) stubbed as shell functions AFTER the last source call.
#   - gh_safe and git_fetch_safe stubbed as shell functions AFTER sources.
#   - set -u flags restored after sourcing (runbook §3).

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT

  # Build a minimal fake-bin directory for external commands the composer calls.
  # Binaries here intercept calls from subshells spawned by the composer.
  FAKE_BIN="${BATS_TEST_TMPDIR}/fake-bin"
  mkdir -p "$FAKE_BIN"

  # Stub: git — return empty output for all calls (diff --stat, show, etc.)
  # Handles the -C <dir> cwd-override flag that the composer passes for
  # cwd-robustness (CLAUDE.md: "CWD after worktree removal" convention).
  cat > "$FAKE_BIN/git" << 'GIT_STUB'
#!/bin/bash
# Minimal git stub: diff --stat returns a summary line; show returns nothing.
# Skip leading -C <dir> option pair so the subcommand always lands on $1.
if [ "${1:-}" = "-C" ]; then
  shift 2
fi
case "${1:-}" in
  diff)   echo " 5 files changed, 42 insertions(+), 7 deletions(-)" ;;
  show)   echo "commit deadbeef" ;;
  fetch)  exit 0 ;;
  *)      exit 0 ;;
esac
GIT_STUB
  chmod +x "$FAKE_BIN/git"

  # Stub: jq — pass through basic json extraction patterns used by composer
  cat > "$FAKE_BIN/jq" << 'JQ_STUB'
#!/bin/bash
# Minimal jq stub: return predictable values for the fields the composer reads.
case "${*:-}" in
  *".title"*)   echo "Test PR title" ;;
  *".state"*)   echo "MERGED" ;;
  *".body"*)    echo "Test PR body" ;;
  *".labels"*)  echo "priority-high, phase-1" ;;
  *)            cat ;;
esac
JQ_STUB
  chmod +x "$FAKE_BIN/jq"

  # Stub: bc — for arithmetic on diff line counts
  cat > "$FAKE_BIN/bc" << 'BC_STUB'
#!/bin/bash
# Minimal bc stub: sum the integers piped to it.
expr "$(cat)" || echo 0
BC_STUB
  chmod +x "$FAKE_BIN/bc"

  export FAKE_BIN
  export PATH="$FAKE_BIN:$PATH"

  # Set minimal env vars the composer needs
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  export RITE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  export RITE_PROJECT_ROOT="$PROJECT_ROOT"
  mkdir -p "$RITE_STATE_DIR/integration-branches"

  # A minimal ledger file for branch 'release/test'
  cat > "$RITE_STATE_DIR/integration-branches/release%test.log" << 'LEDGER'
issue=42	pr=97	sha=deadbeef1234567890abcdef1234567890abcdef	merged_at=2026-07-01T00:00:00Z	promoted=false
issue=43	pr=98	sha=cafebabe1234567890abcdef1234567890abcdef	merged_at=2026-07-02T00:00:00Z	promoted=false
LEDGER

  # The branch name used in tests. Note: integration-ledger uses the branch name
  # as a path segment; we use 'test-branch' (no slash) to keep paths simple.
  TEST_BRANCH="test-branch"
  cat > "$RITE_STATE_DIR/integration-branches/${TEST_BRANCH}.log" << 'LEDGER2'
issue=42	pr=97	sha=deadbeef1234567890abcdef1234567890abcdef	merged_at=2026-07-01T00:00:00Z	promoted=false
issue=43	pr=98	sha=cafebabe1234567890abcdef1234567890abcdef	merged_at=2026-07-02T00:00:00Z	promoted=false
LEDGER2
  export TEST_BRANCH

  CONTEXT_FILE="${BATS_TEST_TMPDIR}/context.txt"
  export CONTEXT_FILE
}

teardown() {
  # Clean up temp state
  rm -rf "${BATS_TEST_TMPDIR}/state" "${FAKE_BIN:-/nonexistent}"
  unset RITE_STATE_DIR RITE_LIB_DIR RITE_PROJECT_ROOT TEST_BRANCH CONTEXT_FILE
}

# ---------------------------------------------------------------------------
# Helper: source the composer and stub all dependencies in the calling shell.
# Must be called inside a subshell or test body — stubs are function-scoped.
# Per runbook §2: stub AFTER the last source call.
# Per runbook §3: restore set flags after sourcing.
# ---------------------------------------------------------------------------
_source_with_stubs() {
  # Source the lib (dependencies are lazy-loaded inside promotion-composer.sh,
  # but we stub them out as functions first to prevent network calls).
  # The lazy-load guards check 'declare -f', so defining stubs before sourcing
  # would be clobbered by env-var-guarded libs (runbook §2: re-stub after source).

  # Source just the composer; suppress its lazy-load sourcing errors in test env.
  # We'll define stub functions afterward.
  # shellcheck source=/dev/null
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$PROJECT_ROOT/lib/utils/promotion-composer.sh" \
    2>/dev/null || true
  set +e; set +u; set +o pipefail  # restore after sourcing (runbook §3 + set +e)

  # Stub: integration_ledger_entries (re-stub after source per runbook §2)
  integration_ledger_entries() {
    local branch="$1"
    local ledger="$RITE_STATE_DIR/integration-branches/${branch}.log"
    [ -f "$ledger" ] && cat "$ledger" || true
  }

  # Stub: gh_safe
  gh_safe() {
    case "${1:-}" in
      pr)
        # Return minimal JSON for pr view calls
        printf '{"title":"Test PR title","body":"Test PR body line 1\nTest PR body line 2","state":"MERGED","comments":[]}\n'
        ;;
      issue)
        printf '{"labels":[{"name":"priority-high"}],"body":"Issue body line 1"}\n'
        ;;
    esac
  }

  # Stub: git_fetch_safe (no-op)
  git_fetch_safe() { return 0; }

  # Stub: print_warning (to stderr, as in production)
  print_warning() { echo "WARNING: $*" >&2; }
}

# ---------------------------------------------------------------------------
# Test 1: Re-source safety -- both functions defined after double-source
# ---------------------------------------------------------------------------

@test "promotion-composer.sh: defines gather_promotion_context and compose_promotion_pr_body" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$PROJECT_ROOT/lib'
    export RITE_STATE_DIR='${BATS_TEST_TMPDIR}/state'
    export RITE_PROJECT_ROOT='$PROJECT_ROOT'
    source '$PROJECT_ROOT/lib/utils/promotion-composer.sh' 2>/dev/null
    source '$PROJECT_ROOT/lib/utils/promotion-composer.sh' 2>/dev/null
    declare -f gather_promotion_context compose_promotion_pr_body >/dev/null && echo PASS
  "
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

# ---------------------------------------------------------------------------
# Test 2: Provider failure path -- fallback emitted, exit 0, Closes lines present
# ---------------------------------------------------------------------------

@test "compose_promotion_pr_body: provider failure → fallback body, exit 0, Closes lines" {
  # Write a minimal context file
  printf '## Ledger entries (branch: %s)\n\n' "$TEST_BRANCH" > "$CONTEXT_FILE"
  printf 'issue=42\tpr=97\tsha=deadbeef\tmerged_at=2026-07-01\tpromoted=false\n' >> "$CONTEXT_FILE"
  printf 'issue=43\tpr=98\tsha=cafebabe\tmerged_at=2026-07-02\tpromoted=false\n' >> "$CONTEXT_FILE"

  run bash << EOF
set +e
export RITE_LIB_DIR="$PROJECT_ROOT/lib"
export RITE_STATE_DIR="$RITE_STATE_DIR"
export RITE_PROJECT_ROOT="$PROJECT_ROOT"
export PATH="$FAKE_BIN:\$PATH"

# Source composer (suppress dependency-load errors in test env).
# The source file runs set -euo pipefail; restore ALL three flags afterward
# so that compose_promotion_pr_body's best-effort guards (|| true) work
# correctly and don't kill the subshell (runbook §3 + set +e).
RITE_SOURCE_FUNCTIONS_ONLY=1 source "$PROJECT_ROOT/lib/utils/promotion-composer.sh" 2>/dev/null || true
set +e; set +u; set +o pipefail

# Stubs (re-defined after source per runbook §2)
integration_ledger_entries() {
  local branch="\$1"
  local ledger="$RITE_STATE_DIR/integration-branches/\${branch}.log"
  [ -f "\$ledger" ] && cat "\$ledger" || true
}
gh_safe() {
  case "\${1:-}" in
    pr)   printf '{"title":"PR title for #%s","body":"Body","state":"MERGED","comments":[]}\n' "\${3:-0}" ;;
    issue) printf '{"labels":[{"name":"priority-high"}],"body":"Issue body"}\n' ;;
  esac
}
git_fetch_safe() { return 0; }
print_warning() { echo "WARNING: \$*" >&2; }

# Stub provider_resolve_model
provider_resolve_model() { echo "claude-opus-4-8"; }

# Stub: provider_run_prompt_with_timeout returns FAILURE (exit 1)
provider_run_prompt_with_timeout() { return 1; }

compose_promotion_pr_body "$TEST_BRANCH" "$CONTEXT_FILE"
exit \$?
EOF

  [ "$status" -eq 0 ]
  # Fallback body must include per-issue Closes lines
  [[ "$output" == *"Closes #42"* ]]
  [[ "$output" == *"Closes #43"* ]]
  # Constituent issues section must be present
  [[ "$output" == *"## Constituent issues"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: Empty LLM output path -- fallback emitted, exit 0, Closes lines
# ---------------------------------------------------------------------------

@test "compose_promotion_pr_body: empty LLM output → fallback body, exit 0, Closes lines" {
  printf '## Ledger entries\n\n' > "$CONTEXT_FILE"
  printf 'issue=42\tpr=97\tsha=deadbeef\tmerged_at=2026-07-01\tpromoted=false\n' >> "$CONTEXT_FILE"

  run bash << EOF
set +e
export RITE_LIB_DIR="$PROJECT_ROOT/lib"
export RITE_STATE_DIR="$RITE_STATE_DIR"
export RITE_PROJECT_ROOT="$PROJECT_ROOT"
export PATH="$FAKE_BIN:\$PATH"

RITE_SOURCE_FUNCTIONS_ONLY=1 source "$PROJECT_ROOT/lib/utils/promotion-composer.sh" 2>/dev/null || true
set +e; set +u; set +o pipefail

integration_ledger_entries() {
  cat "$RITE_STATE_DIR/integration-branches/${TEST_BRANCH}.log" 2>/dev/null || true
}
gh_safe() {
  case "\${1:-}" in
    pr)   printf '{"title":"Empty LLM PR","body":"Body","state":"MERGED","comments":[]}\n' ;;
    issue) printf '{"labels":[{"name":"enhancement"}],"body":"body"}\n' ;;
  esac
}
git_fetch_safe() { return 0; }
print_warning() { echo "WARNING: \$*" >&2; }
provider_resolve_model() { echo "claude-opus-4-8"; }
# Stub: LLM returns empty string (exit 0 but empty output — must trigger fallback)
provider_run_prompt_with_timeout() { printf ''; return 0; }

compose_promotion_pr_body "$TEST_BRANCH" "$CONTEXT_FILE"
exit \$?
EOF

  [ "$status" -eq 0 ]
  [[ "$output" == *"Closes #42"* ]]
  [[ "$output" == *"## Constituent issues"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: LLM success path -- narrative emitted AND Closes tail appended
# ---------------------------------------------------------------------------

@test "compose_promotion_pr_body: LLM success → narrative output + Closes tail" {
  printf '## Ledger entries\n\n' > "$CONTEXT_FILE"
  printf 'issue=42\tpr=97\tsha=deadbeef\tmerged_at=2026-07-01\tpromoted=false\n' >> "$CONTEXT_FILE"

  run bash << EOF
set +e
export RITE_LIB_DIR="$PROJECT_ROOT/lib"
export RITE_STATE_DIR="$RITE_STATE_DIR"
export RITE_PROJECT_ROOT="$PROJECT_ROOT"
export PATH="$FAKE_BIN:\$PATH"

RITE_SOURCE_FUNCTIONS_ONLY=1 source "$PROJECT_ROOT/lib/utils/promotion-composer.sh" 2>/dev/null || true
set +e; set +u; set +o pipefail

integration_ledger_entries() {
  cat "$RITE_STATE_DIR/integration-branches/${TEST_BRANCH}.log" 2>/dev/null || true
}
gh_safe() {
  case "\${1:-}" in
    pr)   printf '{"title":"Narrative PR","body":"Body","state":"MERGED","comments":[]}\n' ;;
    issue) printf '{"labels":[{"name":"enhancement"}],"body":"body"}\n' ;;
  esac
}
git_fetch_safe() { return 0; }
print_warning() { echo "WARNING: \$*" >&2; }
provider_resolve_model() { echo "claude-opus-4-8"; }
# Stub: LLM returns a valid narrative (no Closes lines — caller appends those)
provider_run_prompt_with_timeout() {
  printf '## Summary\nThis is the LLM-generated promotion narrative.\n\n## Changes\n- Issue 42 implemented feature X.\n\n## Risk and quality\nLow risk.\n'
  return 0
}

compose_promotion_pr_body "$TEST_BRANCH" "$CONTEXT_FILE"
exit \$?
EOF

  [ "$status" -eq 0 ]
  # LLM narrative present
  [[ "$output" == *"LLM-generated promotion narrative"* ]]
  # Deterministic tail always appended (even in success path)
  [[ "$output" == *"## Constituent issues"* ]]
  [[ "$output" == *"Closes #42"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: already-promoted entries are EXCLUDED from Closes tail
# ---------------------------------------------------------------------------

@test "compose_promotion_pr_body: promoted=true entries excluded from Closes tail" {
  # Write a ledger with one promoted and one unpromoted entry
  cat > "$RITE_STATE_DIR/integration-branches/${TEST_BRANCH}.log" << 'MIXED_LEDGER'
issue=10	pr=50	sha=aaaabeef1234567890abcdef1234567890abcdef	merged_at=2026-06-01T00:00:00Z	promoted=true
issue=42	pr=97	sha=deadbeef1234567890abcdef1234567890abcdef	merged_at=2026-07-01T00:00:00Z	promoted=false
MIXED_LEDGER

  printf '## Ledger entries\n\n' > "$CONTEXT_FILE"

  run bash << EOF
set +e
export RITE_LIB_DIR="$PROJECT_ROOT/lib"
export RITE_STATE_DIR="$RITE_STATE_DIR"
export RITE_PROJECT_ROOT="$PROJECT_ROOT"
export PATH="$FAKE_BIN:\$PATH"

RITE_SOURCE_FUNCTIONS_ONLY=1 source "$PROJECT_ROOT/lib/utils/promotion-composer.sh" 2>/dev/null || true
set +e; set +u; set +o pipefail

integration_ledger_entries() {
  cat "$RITE_STATE_DIR/integration-branches/${TEST_BRANCH}.log" 2>/dev/null || true
}
gh_safe() {
  case "\${1:-}" in
    pr)   printf '{"title":"PR title","body":"Body","state":"MERGED","comments":[]}\n' ;;
    issue) printf '{"labels":[],"body":"body"}\n' ;;
  esac
}
git_fetch_safe() { return 0; }
print_warning() { echo "WARNING: \$*" >&2; }
provider_resolve_model() { echo "claude-opus-4-8"; }
provider_run_prompt_with_timeout() { return 1; }  # force fallback

compose_promotion_pr_body "$TEST_BRANCH" "$CONTEXT_FILE"
exit \$?
EOF

  [ "$status" -eq 0 ]
  # Issue 42 (promoted=false) must be in Closes tail
  [[ "$output" == *"Closes #42"* ]]
  # Issue 10 (promoted=true) must NOT appear in Closes tail
  [[ "$output" != *"Closes #10"* ]]
}

# ---------------------------------------------------------------------------
# Tests 6-7: gather_promotion_context behavioral coverage
#
# gather_promotion_context writes to an output FILE (not stdout), so tests
# read the file after calling it.  Dependencies are stubbed as shell
# functions inside _source_with_stubs.
# ---------------------------------------------------------------------------

@test "gather_promotion_context: writes section headers to output file" {
  local out_file="${BATS_TEST_TMPDIR}/ctx.txt"

  # Run in a subshell so stubs don't leak.
  run bash << EOF
set +e
export RITE_LIB_DIR="$PROJECT_ROOT/lib"
export RITE_STATE_DIR="$RITE_STATE_DIR"
export RITE_PROJECT_ROOT="$PROJECT_ROOT"
export PATH="$FAKE_BIN:\$PATH"

RITE_SOURCE_FUNCTIONS_ONLY=1 source "$PROJECT_ROOT/lib/utils/promotion-composer.sh" 2>/dev/null || true
set +e; set +u; set +o pipefail

integration_ledger_entries() {
  cat "$RITE_STATE_DIR/integration-branches/${TEST_BRANCH}.log" 2>/dev/null || true
}
gh_safe() {
  case "\${1:-}" in
    pr)   printf '{"title":"Test PR","body":"Body","state":"MERGED","comments":[]}\n' ;;
    issue) printf '{"labels":[{"name":"priority-high"}],"body":"Issue body"}\n' ;;
  esac
}
git_fetch_safe() { return 0; }
print_warning() { echo "WARNING: \$*" >&2; }

gather_promotion_context "$TEST_BRANCH" "$out_file"
# Print the file contents to stdout so 'run' can capture them for assertions.
cat "$out_file"
exit 0
EOF

  [ "$status" -eq 0 ]
  # Section headers must be present
  [[ "$output" == *"## Ledger entries"* ]]
  [[ "$output" == *"## Per-issue context"* ]]
  [[ "$output" == *"## Aggregate diff stats"* ]]
  [[ "$output" == *"## Sync-conflict history"* ]]
  # Per-entry header present (issue 42 from the ledger)
  [[ "$output" == *"### Issue #42"* ]]
}

@test "gather_promotion_context: patch snips are truncated when context cap is hit" {
  local out_file="${BATS_TEST_TMPDIR}/ctx-cap.txt"

  run bash << EOF
set +e
export RITE_LIB_DIR="$PROJECT_ROOT/lib"
export RITE_STATE_DIR="$RITE_STATE_DIR"
export RITE_PROJECT_ROOT="$PROJECT_ROOT"
export PATH="$FAKE_BIN:\$PATH"

RITE_SOURCE_FUNCTIONS_ONLY=1 source "$PROJECT_ROOT/lib/utils/promotion-composer.sh" 2>/dev/null || true
set +e; set +u; set +o pipefail

integration_ledger_entries() {
  cat "$RITE_STATE_DIR/integration-branches/${TEST_BRANCH}.log" 2>/dev/null || true
}
gh_safe() {
  case "\${1:-}" in
    pr)   printf '{"title":"Cap Test PR","body":"Body","state":"MERGED","comments":[]}\n' ;;
    issue) printf '{"labels":[],"body":"body"}\n' ;;
  esac
}
git_fetch_safe() { return 0; }
print_warning() { echo "WARNING: \$*" >&2; }

# Set a tiny cap so the snip section is guaranteed to exceed it.
# The per-issue context (headers + PR info) already fills several hundred
# bytes; a 512-byte cap forces the truncation branch.
_PROMOTION_CONTEXT_CAP_BYTES=512

gather_promotion_context "$TEST_BRANCH" "$out_file"
cat "$out_file"
exit 0
EOF

  [ "$status" -eq 0 ]
  # Required section headers still appear (written before snips)
  [[ "$output" == *"## Ledger entries"* ]]
  [[ "$output" == *"## Per-issue context"* ]]
  # Truncation marker or omission notice must appear — confirms cap branch ran
  { [[ "$output" == *"truncated at context cap"* ]] || [[ "$output" == *"context cap reached"* ]]; }
}

# ---------------------------------------------------------------------------
# Test 8: Static -- composer uses provider_resolve_model promote (Rule 31/32)
# ---------------------------------------------------------------------------

@test "promotion-composer.sh: uses provider_resolve_model promote, never bare \"\" model" {
  local composer="$PROJECT_ROOT/lib/utils/promotion-composer.sh"

  # Rule 32: no direct claude_provider_* calls
  run grep -n "claude_provider_" "$composer"
  [ "$status" -ne 0 ] || [ -z "$output" ]

  # Rule 31: no bare "" model arg to provider_run_prompt*
  local bare_empty
  bare_empty=$(grep -E 'provider_run_prompt[^(]*\s+""' "$composer" || true)
  [ -z "$bare_empty" ]

  # Must use provider_resolve_model promote
  run grep -n "provider_resolve_model promote" "$composer"
  [ "$status" -eq 0 ]
}
