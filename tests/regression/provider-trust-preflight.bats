#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh, lib/providers/provider-interface.sh, lib/core/batch-process-issues.sh, lib/core/workflow-runner.sh
# tests/regression/provider-trust-preflight.bats
#
# Regression test: batch preflight must abort before processing any issue when
# the Claude CLI workspace is not trusted (CLI ≥2.1.284 trust requirement).
#
# Issue #1488 — "Fail batch preflight on untrusted workspace"
#
# Motivation: 2026-10-25 — a mid-day CLI auto-update to 2.1.284 burned 38 min
# (#1423 fix loop) and cascaded into #1424/#1430/#1473 because the trust warning
# only appeared inside [DIAG] tails, not at batch start.  A single preflight
# check at batch start names the condition and prints the fix command.
#
# Tests in this file:
#
#   STRUCTURAL (static code inspection):
#     1. claude_provider_healthcheck exists in claude.sh
#     2. healthcheck is in the provider-interface.sh alias loop
#     3. provider_healthcheck contract comment in provider-interface.sh
#     4. batch-process-issues.sh calls provider_healthcheck in preflight section
#     5. workflow-runner.sh calls provider_healthcheck in main()
#     6. PROVIDER_PREFLIGHT diag documented in CLAUDE.md
#     7. hasTrustDialogAccepted documented in CLAUDE.md
#
#   UNIT (claude_provider_healthcheck):
#     8.  Trusted workspace returns 0 (hasTrustDialogAccepted = true)
#     9.  Untrusted workspace returns 1 (hasTrustDialogAccepted absent)
#    10.  Untrusted workspace with false flag returns 1
#    11.  Missing ~/.claude.json returns 0 (no trust requirement)
#    12.  Project not in ~/.claude.json at all returns 1
#    13.  PROVIDER_PREFLIGHT diag emitted on success (outcome=trusted)
#    14.  PROVIDER_PREFLIGHT diag emitted on failure (outcome=untrusted_workspace)
#
#   BEHAVIORAL (abort message content):
#    15.  Abort message contains 'hasTrustDialogAccepted' (fix command)
#    16.  Abort message contains the project root path
#    17.  Healthy provider passes preflight with zero issues processed
#
#   PROPAGATION (batch-process-issues.sh structural checks):
#    18.  batch-process-issues.sh sources provider-interface.sh in preflight block
#    19.  batch-process-issues.sh calls load_provider in preflight block
#    20.  batch-process-issues.sh exits 1 on healthcheck failure (not continue/skip)

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CLAUDE_PROVIDER="$REPO_ROOT/lib/providers/claude.sh"
PROVIDER_INTERFACE="$REPO_ROOT/lib/providers/provider-interface.sh"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
WORKFLOW_RUNNER="$REPO_ROOT/lib/core/workflow-runner.sh"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

setup() {
  for _f in "$CLAUDE_PROVIDER" "$PROVIDER_INTERFACE" "$BATCH_PROCESSOR" \
             "$WORKFLOW_RUNNER" "$CLAUDE_MD"; do
    [ -f "$_f" ] || {
      echo "FATAL: $_f not found" >&2
      return 1
    }
  done
  _tmpdir=$(mktemp -d)
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# =============================================================================
# STRUCTURAL
# =============================================================================

@test "structural: claude_provider_healthcheck is defined in claude.sh" {
  grep -q 'claude_provider_healthcheck()' "$CLAUDE_PROVIDER" || {
    echo "FAIL: 'claude_provider_healthcheck()' not found in claude.sh" >&2
    return 1
  }
}

@test "structural: healthcheck is in provider-interface.sh alias loop" {
  grep -q 'healthcheck' "$PROVIDER_INTERFACE" || {
    echo "FAIL: 'healthcheck' not found in provider-interface.sh alias loop" >&2
    return 1
  }
}

@test "structural: provider_healthcheck contract documented in provider-interface.sh" {
  grep -q 'provider_healthcheck' "$PROVIDER_INTERFACE" || {
    echo "FAIL: 'provider_healthcheck' contract comment not in provider-interface.sh" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh calls provider_healthcheck in preflight" {
  grep -q 'provider_healthcheck' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'provider_healthcheck' not called in batch-process-issues.sh" >&2
    return 1
  }
}

@test "structural: workflow-runner.sh calls provider_healthcheck in main()" {
  grep -q 'provider_healthcheck' "$WORKFLOW_RUNNER" || {
    echo "FAIL: 'provider_healthcheck' not called in workflow-runner.sh" >&2
    return 1
  }
}

@test "structural: PROVIDER_PREFLIGHT diag event documented in CLAUDE.md" {
  grep -q 'PROVIDER_PREFLIGHT' "$CLAUDE_MD" || {
    echo "FAIL: 'PROVIDER_PREFLIGHT' not documented in CLAUDE.md" >&2
    return 1
  }
}

@test "structural: hasTrustDialogAccepted documented in CLAUDE.md" {
  grep -q 'hasTrustDialogAccepted' "$CLAUDE_MD" || {
    echo "FAIL: 'hasTrustDialogAccepted' not in CLAUDE.md" >&2
    return 1
  }
}

# =============================================================================
# UNIT: claude_provider_healthcheck
# =============================================================================

_load_healthcheck() {
  export RITE_LIB_DIR="$REPO_ROOT/lib"
  export RITE_PROJECT_ROOT="$_tmpdir/project"
  mkdir -p "$RITE_PROJECT_ROOT"
  # Silence _diag if undefined (it's defined in logging.sh which we don't source here)
  _diag() { true; }
  export HOME="$_tmpdir/home"
  mkdir -p "$HOME"
  # Source with RITE_SOURCE_FUNCTIONS_ONLY so we load only function definitions
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$CLAUDE_PROVIDER"
  set +u; set +o pipefail
}

@test "unit: trusted workspace (hasTrustDialogAccepted=true) returns 0" {
  _load_healthcheck
  cat > "$HOME/.claude.json" <<JSON
{
  "projects": {
    "${RITE_PROJECT_ROOT}": {
      "hasTrustDialogAccepted": true
    }
  }
}
JSON
  claude_provider_healthcheck "$RITE_PROJECT_ROOT"
}

@test "unit: untrusted workspace (hasTrustDialogAccepted absent) returns 1" {
  _load_healthcheck
  cat > "$HOME/.claude.json" <<JSON
{
  "projects": {
    "${RITE_PROJECT_ROOT}": {}
  }
}
JSON
  ! claude_provider_healthcheck "$RITE_PROJECT_ROOT"
}

@test "unit: untrusted workspace (hasTrustDialogAccepted=false) returns 1" {
  _load_healthcheck
  cat > "$HOME/.claude.json" <<JSON
{
  "projects": {
    "${RITE_PROJECT_ROOT}": {
      "hasTrustDialogAccepted": false
    }
  }
}
JSON
  ! claude_provider_healthcheck "$RITE_PROJECT_ROOT"
}

@test "unit: missing ~/.claude.json returns 0 (no trust requirement)" {
  _load_healthcheck
  # Do not create $HOME/.claude.json
  rm -f "$HOME/.claude.json"
  claude_provider_healthcheck "$RITE_PROJECT_ROOT"
}

@test "unit: project not in ~/.claude.json returns 1" {
  _load_healthcheck
  cat > "$HOME/.claude.json" <<JSON
{
  "projects": {
    "/some/other/project": {
      "hasTrustDialogAccepted": true
    }
  }
}
JSON
  ! claude_provider_healthcheck "$RITE_PROJECT_ROOT"
}

@test "unit: PROVIDER_PREFLIGHT diag emitted with outcome=trusted on success" {
  _load_healthcheck
  cat > "$HOME/.claude.json" <<JSON
{
  "projects": {
    "${RITE_PROJECT_ROOT}": {
      "hasTrustDialogAccepted": true
    }
  }
}
JSON
  _diag_log=""
  _diag() { _diag_log="$*"; }
  claude_provider_healthcheck "$RITE_PROJECT_ROOT"
  echo "$_diag_log" | grep -q 'PROVIDER_PREFLIGHT' || {
    echo "FAIL: PROVIDER_PREFLIGHT not in diag output: $_diag_log" >&2
    return 1
  }
  echo "$_diag_log" | grep -q 'outcome=trusted' || {
    echo "FAIL: outcome=trusted not in diag output: $_diag_log" >&2
    return 1
  }
}

@test "unit: PROVIDER_PREFLIGHT diag emitted with outcome=untrusted_workspace on failure" {
  _load_healthcheck
  cat > "$HOME/.claude.json" <<JSON
{
  "projects": {}
}
JSON
  _diag_log=""
  _diag() { _diag_log="$*"; }
  claude_provider_healthcheck "$RITE_PROJECT_ROOT" || true
  echo "$_diag_log" | grep -q 'PROVIDER_PREFLIGHT' || {
    echo "FAIL: PROVIDER_PREFLIGHT not in diag output: $_diag_log" >&2
    return 1
  }
  echo "$_diag_log" | grep -q 'outcome=untrusted_workspace' || {
    echo "FAIL: outcome=untrusted_workspace not in diag output: $_diag_log" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: abort message content
# =============================================================================

@test "behavioral: abort message contains 'hasTrustDialogAccepted'" {
  # Verify the batch-process-issues.sh abort block contains the fix command keyword.
  grep -q 'hasTrustDialogAccepted' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'hasTrustDialogAccepted' not in batch-process-issues.sh abort block" >&2
    return 1
  }
}

@test "behavioral: abort message contains project root path reference" {
  # The abort block must echo the project root path so operators know which repo to trust.
  grep -qE 'RITE_PROJECT_ROOT|project.root|project_root' "$BATCH_PROCESSOR" || {
    echo "FAIL: project root path not referenced in batch-process-issues.sh abort block" >&2
    return 1
  }
}

@test "behavioral: single-issue abort message contains 'hasTrustDialogAccepted'" {
  # workflow-runner.sh single-issue path must also show the fix command.
  grep -q 'hasTrustDialogAccepted' "$WORKFLOW_RUNNER" || {
    echo "FAIL: 'hasTrustDialogAccepted' not in workflow-runner.sh abort block" >&2
    return 1
  }
}

# =============================================================================
# PROPAGATION: batch structural checks
# =============================================================================

@test "propagation: batch-process-issues.sh sources provider-interface.sh in preflight" {
  grep -q 'source.*provider-interface' "$BATCH_PROCESSOR" || {
    echo "FAIL: provider-interface.sh not sourced in batch-process-issues.sh" >&2
    return 1
  }
}

@test "propagation: batch-process-issues.sh calls load_provider in preflight block" {
  # load_provider must be called near the provider_healthcheck call (not just inside
  # the per-issue loop). Extract the preflight block and verify both appear there.
  _preflight=$(awk '/Preflight.*provider.*trust/,/Preflight dep/' "$BATCH_PROCESSOR" || true)
  echo "$_preflight" | grep -q 'load_provider' || {
    echo "FAIL: load_provider not found in provider trust preflight block" >&2
    echo "      Ensure load_provider is called before provider_healthcheck" >&2
    return 1
  }
}

@test "propagation: batch-process-issues.sh uses exit 1 on healthcheck failure" {
  # The trust failure must abort the batch (exit 1), not continue/skip.
  _preflight=$(awk '/Preflight.*provider.*trust/,/Preflight dep/' "$BATCH_PROCESSOR" || true)
  echo "$_preflight" | grep -q 'exit 1' || {
    echo "FAIL: 'exit 1' not found in provider trust preflight abort block" >&2
    echo "      Trust failure must abort the batch (not continue or skip)" >&2
    return 1
  }
}
