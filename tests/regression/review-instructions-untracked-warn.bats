#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/local-review.sh
# tests/regression/review-instructions-untracked-warn.bats
#
# Regression tests for issue #794/#796/#804/#805/#787:
# Warn when .github/claude-code/pr-review-instructions.md is present locally
# but git-untracked, so users discover the file won't be used on fresh
# checkouts or in CI before a review runs with inconsistent instructions.
#
# Verifies:
# 1. Untracked file → warning emitted (tier-1 selected, git ls-files fails)
# 2. Tracked file → no warning (tier-1 selected, git ls-files succeeds)
# 3. Absent file → no warning, silent fallback (tier-2/3 path unchanged)
# 4. Static check: the ls-files guard and warning text are present in local-review.sh
#
# The script body of local-review.sh cannot be sourced in tests — it requires
# gh, config, a real PR number, and network access. Instead, behavioral tests
# extract the template-selection block via sharkrite-extract markers and run it
# in a minimal bash -c subprocess with stubbed helpers and a shim PATH for git.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  # RITE_PROJECT_ROOT is the fake repo root; SHIM_DIR overrides PATH for git
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/project"
  mkdir -p "$RITE_PROJECT_ROOT/.github/claude-code"

  export SHIM_DIR="$RITE_TEST_TMPDIR/shims"
  mkdir -p "$SHIM_DIR"
  export PATH="$SHIM_DIR:$PATH"

  SCRIPT="$RITE_REPO_ROOT/lib/core/local-review.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: extract the template-selection block from local-review.sh using
# sharkrite-extract markers and run it in an isolated bash -c subprocess.
#
# Outputs: bats $status and $output from `run`.
# Arguments: none (uses REPO_TEMPLATE, RITE_PROJECT_ROOT, SHIM_DIR from env)
# ---------------------------------------------------------------------------
_run_template_selection() {
  local block
  block=$(sed -n '/# sharkrite-extract: template-selection-start/,/# sharkrite-extract: template-selection-end/p' "$SCRIPT")
  [ -n "$block" ] || { echo "FAIL: sharkrite-extract markers missing from $SCRIPT" >&2; return 1; }

  run bash -c "
    set -euo pipefail
    export PATH=\"$SHIM_DIR:\$PATH\"
    RITE_PROJECT_ROOT=\"$RITE_PROJECT_ROOT\"
    RITE_INSTALL_DIR=\"$RITE_TEST_TMPDIR/install\"
    REPO_TEMPLATE=\"\$RITE_PROJECT_ROOT/.github/claude-code/pr-review-instructions.md\"
    RITE_TEMPLATE=\"\$RITE_INSTALL_DIR/templates/github/claude-code/pr-review-instructions.md\"

    # Logging stubs: print_warning goes to stdout so bats \$output captures it.
    # print_status/print_success go to stderr (not relevant to these tests).
    print_status()  { echo \"[STATUS] \$*\" >&2; }
    print_warning() { echo \"[WARNING] \$*\"; }
    print_success() { echo \"[SUCCESS] \$*\" >&2; }

    $block

    echo \"TEMPLATE_SELECTED:\${REVIEW_TEMPLATE:-NONE}\"
  "
}

# ---------------------------------------------------------------------------
# Test 1: untracked file → warning is emitted
# ---------------------------------------------------------------------------

@test "untracked review instructions: emits untracked warning" {
  # Create the instructions file but do NOT track it in git
  echo "# custom review" > "$RITE_PROJECT_ROOT/.github/claude-code/pr-review-instructions.md"

  # git shim: ls-files --error-unmatch exits 1 (file untracked)
  cat > "$SHIM_DIR/git" <<'EOF'
#!/bin/bash
if [[ "$*" == *"ls-files"*"--error-unmatch"* ]]; then
  exit 1
fi
# Passthrough for any other git calls (shouldn't occur in this block)
command git "$@"
EOF
  chmod +x "$SHIM_DIR/git"

  _run_template_selection

  [ "$status" -eq 0 ]
  # Warning must be present
  [[ "$output" == *"untracked"* ]]
  [[ "$output" == *"commit it"* ]]
  # Tier-1 must still be selected (file is used locally)
  [[ "$output" == *"TEMPLATE_SELECTED:"*".github/claude-code/pr-review-instructions.md"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: tracked file → no warning
# ---------------------------------------------------------------------------

@test "tracked review instructions: no untracked warning emitted" {
  echo "# custom review" > "$RITE_PROJECT_ROOT/.github/claude-code/pr-review-instructions.md"

  # git shim: ls-files --error-unmatch exits 0 (file is tracked)
  cat > "$SHIM_DIR/git" <<'EOF'
#!/bin/bash
if [[ "$*" == *"ls-files"*"--error-unmatch"* ]]; then
  exit 0
fi
command git "$@"
EOF
  chmod +x "$SHIM_DIR/git"

  _run_template_selection

  [ "$status" -eq 0 ]
  # No warning
  [[ "$output" != *"untracked"* ]]
  # Tier-1 still selected
  [[ "$output" == *"TEMPLATE_SELECTED:"*".github/claude-code/pr-review-instructions.md"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: absent file → no warning, falls through to tier-2/3
# ---------------------------------------------------------------------------

@test "absent review instructions: no warning, falls back silently" {
  # File does not exist — no git shim needed (git ls-files never reached)
  # Provide a passthrough git shim to prevent accidental real git calls
  cat > "$SHIM_DIR/git" <<'EOF'
#!/bin/bash
# Should not be called when REPO_TEMPLATE does not exist
echo "UNEXPECTED git call: $*" >&2
exit 1
EOF
  chmod +x "$SHIM_DIR/git"

  _run_template_selection

  [ "$status" -eq 0 ]
  # No untracked warning
  [[ "$output" != *"untracked"* ]]
  # Tier-1 not selected (file absent); tier-2 also absent → NONE
  [[ "$output" == *"TEMPLATE_SELECTED:NONE"* ]]
  # git shim must NOT have been called (no "UNEXPECTED git call" in output)
  [[ "$output" != *"UNEXPECTED git call"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: static check — guard and warning text present in local-review.sh
# ---------------------------------------------------------------------------

@test "local-review.sh contains ls-files untracked guard and warning text" {
  # The git ls-files --error-unmatch pattern must be present
  GUARD_COUNT=$(grep -c "ls-files --error-unmatch" "$SCRIPT" || true)
  [ "$GUARD_COUNT" -ge 1 ]

  # The warning message must mention "untracked"
  WARN_COUNT=$(grep -c "untracked" "$SCRIPT" || true)
  [ "$WARN_COUNT" -ge 1 ]

  # The warning message must mention committing the file
  COMMIT_COUNT=$(grep -c "commit it" "$SCRIPT" || true)
  [ "$COMMIT_COUNT" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Test 5: static check — sharkrite-extract markers are present exactly once
# ---------------------------------------------------------------------------

@test "local-review.sh template-selection sharkrite-extract markers appear exactly once" {
  START_COUNT=$(grep -c "sharkrite-extract: template-selection-start" "$SCRIPT" || true)
  END_COUNT=$(grep -c "sharkrite-extract: template-selection-end" "$SCRIPT" || true)

  [ "$START_COUNT" -eq 1 ] || {
    echo "Expected exactly 1 template-selection-start marker, found $START_COUNT" >&2
    false
  }
  [ "$END_COUNT" -eq 1 ] || {
    echo "Expected exactly 1 template-selection-end marker, found $END_COUNT" >&2
    false
  }
}
