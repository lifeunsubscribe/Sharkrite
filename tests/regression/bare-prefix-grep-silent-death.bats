#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/core/claude-workflow.sh, lib/utils/markers.sh
# Regression test for: Unanchored sharkrite marker grep causes silent death
#
# Bug history (2026-05-31):
#   Every `rite --label testing` batch died silently at Processing Issue #34.
#   Root cause: the outer guard `grep -q "sharkrite-parent-pr:"` matched issue
#   #34's body, which DOCUMENTED the marker as an example ("sharkrite-parent-pr:N").
#   The inner extraction pattern used `[0-9]+` (correctly) but the outer guard
#   had no format anchor, so any issue body mentioning the marker name triggered
#   the extraction branch. Extraction returned empty, pipefail bubbled exit-1 up,
#   set -e killed the batch silently with no error output.
#
#   Three batch logs died at this exact spot (010611, 094808, 125251 in .rite/logs/).
#   Emergency fix: commit 206f2be added `[0-9]+` to the outer guard in
#   batch-process-issues.sh. Sibling fix applied to claude-workflow.sh.
#
# This test verifies:
#   1. Bare-prefix guard (no anchor) silently kills script when body has literal marker
#   2. Anchored guard (`[0-9]+`) skips extraction when body has literal marker
#   3. Anchored guard correctly enters extraction when body has a real marker value
#   4. Lint rule BARE_MARKER_GREP detects unanchored patterns
#   5. Codebase sweep finds zero unanchored sharkrite marker greps

setup() {
  export RITE_TEST_ROOT="${BATS_TEST_TMPDIR}/rite-test"
  mkdir -p "$RITE_TEST_ROOT"

  # Fixture for lint tests — placed OUTSIDE lib/ and injected via RITE_LINT_EXTRA_DIRS.
  # Planting inside lib/test-fixtures-temp would be excluded from the main SHELL_FILES
  # scan (Rule 15 never sees it) and would spuriously trip Rule 16 (MISSING_RESOURCE_GUARD),
  # masking the real BARE_MARKER_GREP assertion. See RITE_LINT_EXTRA_DIRS contract (#307).
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export PROJECT_ROOT
  export RITE_LINT_TEST_DIR="${BATS_TEST_TMPDIR}/lint-fixtures"
  mkdir -p "$RITE_LINT_TEST_DIR"
}

teardown() {
  rm -rf "$RITE_TEST_ROOT"
  rm -rf "$RITE_LINT_TEST_DIR"
}

# ---------------------------------------------------------------------------
# Behavioral tests: demonstrates the silent-death scenario and the fix
# ---------------------------------------------------------------------------

@test "unanchored guard silently kills script when body documents the marker name" {
  # Reproduces the exact pattern from the 2026-05-31 incident:
  # An issue body that mentions "sharkrite-parent-pr:N" as documentation text
  # trips the unanchored grep -q guard, enters the extraction branch, extraction
  # returns empty, pipefail kills the script silently.
  cat > "$RITE_TEST_ROOT/unanchored-guard.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

ISSUE_BODY="This issue tracks work related to sharkrite-parent-pr:N (placeholder example)"

echo "Before guard"

# BAD: unanchored — matches even documentation placeholders like ':N'
if echo "$ISSUE_BODY" | grep -q "sharkrite-parent-pr:"; then
  # Inner extraction requires digits but the outer guard already triggered
  PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2)
  echo "Extracted: $PARENT_PR"
fi

echo "After guard"
EOF

  run bash "$RITE_TEST_ROOT/unanchored-guard.sh"

  # Script dies silently — exit non-zero, "After guard" never prints
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Before guard" ]]
  [[ ! "$output" =~ "After guard" ]]
}

@test "anchored guard skips extraction when body contains only a placeholder marker" {
  # Verifies the fix: outer guard with [0-9]+ correctly rejects placeholder text
  cat > "$RITE_TEST_ROOT/anchored-guard-placeholder.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

ISSUE_BODY="This issue tracks work related to sharkrite-parent-pr:N (placeholder example)"

echo "Before guard"

# GOOD: anchored — requires actual digits, rejects ':N' placeholder
if echo "$ISSUE_BODY" | grep -qE "sharkrite-parent-pr:[0-9]+"; then
  PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
  echo "Extracted: $PARENT_PR"
fi

echo "After guard"
EOF

  run bash "$RITE_TEST_ROOT/anchored-guard-placeholder.sh"

  # Script continues — extraction block skipped, "After guard" prints
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Before guard" ]]
  [[ "$output" =~ "After guard" ]]
  # Extraction block should NOT have been entered
  [[ ! "$output" =~ "Extracted:" ]]
}

@test "anchored guard enters extraction when body contains a real marker value" {
  # Verifies the fix doesn't break the happy path: a real marker like
  # "sharkrite-parent-pr:42" correctly enters the extraction branch
  cat > "$RITE_TEST_ROOT/anchored-guard-real.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

ISSUE_BODY="Follow-up to PR #42. sharkrite-parent-pr:42"

echo "Before guard"

# GOOD: anchored — matches real numeric markers
if echo "$ISSUE_BODY" | grep -qE "sharkrite-parent-pr:[0-9]+"; then
  PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
  echo "Extracted: $PARENT_PR"
fi

echo "After guard"
EOF

  run bash "$RITE_TEST_ROOT/anchored-guard-real.sh"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Before guard" ]]
  [[ "$output" =~ "Extracted: 42" ]]
  [[ "$output" =~ "After guard" ]]
}

@test "anchored guard skips extraction when body contains extended docs with colons" {
  # Edge case: body contains "sharkrite-parent-pr: some text" (colon followed by space)
  # Should NOT trigger extraction since there are no leading digits
  cat > "$RITE_TEST_ROOT/anchored-guard-colon-space.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

ISSUE_BODY="See the sharkrite-parent-pr: format in the docs for marker syntax"

echo "Before guard"

if echo "$ISSUE_BODY" | grep -qE "sharkrite-parent-pr:[0-9]+"; then
  PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
  echo "Extracted: $PARENT_PR"
fi

echo "After guard"
EOF

  run bash "$RITE_TEST_ROOT/anchored-guard-colon-space.sh"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Before guard" ]]
  [[ "$output" =~ "After guard" ]]
  [[ ! "$output" =~ "Extracted:" ]]
}

# ---------------------------------------------------------------------------
# Lint rule tests
# ---------------------------------------------------------------------------

@test "lint rule detects unanchored sharkrite-marker grep pattern" {
  # Create a file with the vulnerable pattern in a location the linter scans
  cat > "$RITE_LINT_TEST_DIR/bare-marker-grep.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

# BAD: outer guard without format anchor
ISSUE_BODY="some body"
if echo "$ISSUE_BODY" | grep -q "sharkrite-parent-pr:"; then
  PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
fi
EOF

  cd "$PROJECT_ROOT"
  export RITE_LINT_EXTRA_DIRS="$RITE_LINT_TEST_DIR"
  run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  [ "$status" -eq 1 ]
  [[ "$output" =~ "BARE_MARKER_GREP" ]]
  [[ "$output" =~ "bare-marker-grep.sh" ]]
}

@test "lint rule detects grep -E variant of unanchored marker pattern" {
  # Note: this test creates bare-marker-grep-e.sh dynamically in RITE_LINT_TEST_DIR.
  # A static version of this file previously existed in lib/test-fixtures-temp/ but was
  # deleted — the dynamic creation here provides equivalent (and self-contained) coverage.
  cat > "$RITE_LINT_TEST_DIR/bare-marker-grep-e.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

ISSUE_BODY="some body"
if echo "$ISSUE_BODY" | grep -qE "sharkrite-follow-up:"; then
  echo "found"
fi
EOF

  cd "$PROJECT_ROOT"
  export RITE_LINT_EXTRA_DIRS="$RITE_LINT_TEST_DIR"
  run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  [ "$status" -eq 1 ]
  [[ "$output" =~ "BARE_MARKER_GREP" ]]
}

@test "lint rule allows anchored sharkrite-marker grep with [0-9]+" {
  # The fixed pattern — anchored with [0-9]+
  # Create in RITE_TEST_ROOT (outside lib/) to avoid the linter scanning it
  cat > "$RITE_TEST_ROOT/anchored-marker-grep.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

ISSUE_BODY="some body"
if echo "$ISSUE_BODY" | grep -qE "sharkrite-parent-pr:[0-9]+"; then
  PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
fi
EOF

  # Only the fixture directory gets scanned — this file is outside it
  # Confirm no violation is flagged for this safe pattern
  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  # With no unsafe files in the lint fixture dir, should pass
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "BARE_MARKER_GREP" ]]
}

# ---------------------------------------------------------------------------
# Codebase sweep: zero unanchored sharkrite marker greps
# ---------------------------------------------------------------------------

@test "codebase has zero unanchored sharkrite marker greps in lib/" {
  # Sweep for any grep -q[E]? "sharkrite-[a-z-]+:" without a digits/format anchor.
  # Anchored patterns include: [0-9]+, [a-zA-Z0-9_-]+, [0-9]
  # This test fails if any are found — they must be patched.

  cd "$PROJECT_ROOT"

  run bash -c '
    grep -rnE '"'"'grep -q[E]? "sharkrite-[a-z-]+:"'"'"' lib/ bin/ 2>/dev/null \
      | grep -v '"'"'[0-9]+\|[a-zA-Z0-9_-]+\|[0-9]\]'"'"' \
      | grep -v '"'"'^\s*#'"'"' \
      || true
  '

  # Output should be empty — no unanchored matches
  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "FAIL: Unanchored sharkrite marker grep(s) found:"
    echo "$output"
    return 1
  }
}

@test "lint rule BARE_MARKER_GREP is defined in sharkrite-lint.sh" {
  cd "$PROJECT_ROOT"
  # Post-#952 the linter is driver + tools/lint-rules/ fragments — rule
  # bodies live in the fragments, so the assertion must search both.
  run grep -qr "BARE_MARKER_GREP" tools/sharkrite-lint.sh tools/lint-rules
  [ "$status" -eq 0 ]
}
