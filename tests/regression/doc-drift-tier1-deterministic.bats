#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh::_record_tier1_drift_entries

# Regression tests for _record_tier1_drift_entries Trigger C behavior.
#
# Trigger C fires when the PR's head branch has a declared-doc state file at
# RITE_STATE_DIR/declared-doc-<branch-slug>.txt. This tests the "one entry per
# PR" design decision resolved in issue #1509: distinct PRs declaring the same
# doc must produce separate entries, each preserving its own branch evidence.
#
# Covers:
#   1. Trigger C fires when declared-doc state file exists for the PR branch.
#   2. Trigger C entry includes branch name in suspected-inaccuracy evidence.
#   3. Two distinct PRs declaring the same doc produce two separate entries.
#   4. Trigger C does not fire when no declared-doc state file exists.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB_DIR="$PROJECT_ROOT/lib"

  # Fresh temp git repo for each test.
  _TMPDIR="$(mktemp -d)"
  cd "$_TMPDIR"
  git init -q .
  git config user.email "test@test.invalid"
  git config user.name "Test"
  touch .gitkeep
  git add .gitkeep
  git commit -q -m "init"

  export RITE_PROJECT_ROOT="$_TMPDIR"
  export RITE_STATE_DIR="$_TMPDIR/.rite/state"
  mkdir -p "$RITE_STATE_DIR"
  export RITE_LIB_DIR="$LIB_DIR"
  export RITE_VERBOSE=false
  export RITE_DOC_MODE="changelog"

  # Pre-stub load_provider: provider-interface.sh uses a function-sentinel guard
  # (declare -f load_provider); this stub is preserved on source and prevents the
  # real Claude provider from loading. _record_tier1_drift_entries is deterministic
  # (Tier 1) and makes zero provider calls.
  load_provider() { :; }

  # Source function definitions only; internal imports load the dependency chain.
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: assess-documentation.sh uses a function-sentinel guard (declare -f update_conventions_from_marker); load_provider pre-stub is preserved because provider-interface.sh also uses a function-sentinel guard (declare -f load_provider) and returns immediately when load_provider is already defined.
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$LIB_DIR/core/assess-documentation.sh" 2>/dev/null || true

  # Runbook §3: restore flags after last source (never set +e).
  set +u; set +o pipefail

  # Re-stub print_* AFTER last source (runbook §2: env-guarded libs overwrite pre-source stubs).
  print_info() { :; }
  print_warning() { :; }
  verbose_info() { :; }
  print_error() { :; }
}

teardown() {
  cd /
  rm -rf "$_TMPDIR"
}

# ---------------------------------------------------------------------------
# 1. Trigger C fires when declared-doc state file exists
# ---------------------------------------------------------------------------

@test "_record_tier1_drift_entries: Trigger C fires and records entry when state file exists" {
  printf 'docs/architecture/behavioral-design.md' \
    > "$RITE_STATE_DIR/declared-doc-fix-issue-42.txt"

  _record_tier1_drift_entries \
    "42" "Closes #40" "lib/core/foo.sh" "main" "fix/issue-42"

  _log_path="$(drift_log_path)"
  [ -f "$_log_path" ]
  _count="$(drift_log_entry_count "$_log_path")"
  [ "$_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 2. Entry includes branch evidence (per-PR discriminator)
# ---------------------------------------------------------------------------

@test "_record_tier1_drift_entries: Trigger C entry includes branch in suspected-inaccuracy" {
  printf 'docs/architecture/behavioral-design.md' \
    > "$RITE_STATE_DIR/declared-doc-fix-issue-42.txt"

  _record_tier1_drift_entries \
    "42" "Closes #40" "lib/core/foo.sh" "main" "fix/issue-42"

  _log_path="$(drift_log_path)"
  grep -q "fix/issue-42" "$_log_path"
}

# ---------------------------------------------------------------------------
# 3. Two distinct PRs declaring the same doc produce two separate entries
#    (anti-regression for issue #1509: Trigger C collapsing PR evidence)
# ---------------------------------------------------------------------------

@test "_record_tier1_drift_entries: two distinct PRs declaring the same doc produce two separate entries" {
  # PR 100 on branch fix/issue-100, declares docs/arch.md
  printf 'docs/architecture/behavioral-design.md' \
    > "$RITE_STATE_DIR/declared-doc-fix-issue-100.txt"

  _record_tier1_drift_entries \
    "100" "Closes #95" "lib/core/foo.sh" "main" "fix/issue-100"

  # PR 200 on a different branch, declares the SAME doc
  printf 'docs/architecture/behavioral-design.md' \
    > "$RITE_STATE_DIR/declared-doc-fix-issue-200.txt"

  _record_tier1_drift_entries \
    "200" "Closes #195" "lib/utils/bar.sh" "main" "fix/issue-200"

  _log_path="$(drift_log_path)"
  _count="$(drift_log_entry_count "$_log_path")"
  # Must produce exactly two entries — no collapse.
  [ "$_count" -eq 2 ]

  # Each entry must carry its own PR number.
  grep -q "pr:100" "$_log_path"
  grep -q "pr:200" "$_log_path"

  # Each entry must carry its own branch evidence.
  grep -q "fix/issue-100" "$_log_path"
  grep -q "fix/issue-200" "$_log_path"
}

# ---------------------------------------------------------------------------
# 4. Trigger C does not fire when no declared-doc state file exists
# ---------------------------------------------------------------------------

@test "_record_tier1_drift_entries: no drift entry when no declared-doc state file" {
  # No state file created for this branch.
  _record_tier1_drift_entries \
    "55" "Closes #50" "lib/core/foo.sh" "main" "fix/issue-55"

  _log_path="$(drift_log_path)"
  # Log file should not exist (no trigger fired).
  [ ! -f "$_log_path" ]
}
