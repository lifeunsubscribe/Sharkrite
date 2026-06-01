#!/usr/bin/env bats
# Regression test for: bare-prefix grep on sharkrite marker causes silent death
#
# Live incident 2026-05-31: every `rite --label testing` batch died silently at
# "Processing Issue #34" with no error output. Root cause: the outer guard
#   grep -q "sharkrite-parent-pr:"
# matched issue #34's body, which DOCUMENTED the marker format as an example
# (literal text "sharkrite-parent-pr:N"). The inner extraction
#   grep -oE 'sharkrite-parent-pr:[0-9]+'
# returned empty (exit 1), pipefail bubbled exit-1 up, set -e killed the batch
# silently. Three batch logs died at this exact spot (010611, 094808, 125251).
#
# Emergency fix 206f2be patched batch-process-issues.sh. This file adds:
#   1. A regression test reproducing the scenario for claude-workflow.sh's
#      sibling instance of the same pattern.
#   2. A lint-rule test verifying UNANCHORED_MARKER_GREP catches future regressions.
#   3. A codebase sweep asserting zero remaining unanchored marker greps.

setup() {
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export PROJECT_ROOT

  # Temp dir for runtime scripts (outside lib/ so lint doesn't scan them)
  export BPSD_RUNTIME_DIR="${BATS_TEST_TMPDIR}/runtime"
  mkdir -p "$BPSD_RUNTIME_DIR"

  # Temp dir INSIDE lib/ so the linter picks it up for lint-rule tests
  export BPSD_LINT_DIR="$PROJECT_ROOT/lib/test-fixtures-temp-bpsd"
  mkdir -p "$BPSD_LINT_DIR"
}

teardown() {
  rm -rf "$BPSD_RUNTIME_DIR"
  rm -rf "$BPSD_LINT_DIR"
}

# ---------------------------------------------------------------------------
# Group 1: Reproduce the silent-death scenario
# ---------------------------------------------------------------------------

@test "bare-prefix guard silently kills script when body only documents the marker" {
  # Simulate issue #34's scenario: body TEXT describes the marker format but
  # doesn't contain an actual live marker (no digits after the colon).
  # The unanchored outer guard trips, inner extraction returns empty, set -e kills.
  cat > "$BPSD_RUNTIME_DIR/bare-guard.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

ISSUE_BODY="This issue tracks the sharkrite-parent-pr:N marker format.
It is a documentation-only reference, not a live marker."

echo "before-guard"

# BAD: unanchored — matches the documentation example
if echo "$ISSUE_BODY" | grep -q "sharkrite-parent-pr:"; then
  # Inner extraction finds no digits — returns empty — exits 1 — script dies
  PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2)
  echo "parent-pr=$PARENT_PR"
fi

echo "after-guard"
EOF

  run bash "$BPSD_RUNTIME_DIR/bare-guard.sh"

  # Script dies — "after-guard" is never printed
  [ "$status" -ne 0 ]
  [[ "$output" =~ "before-guard" ]]
  [[ ! "$output" =~ "after-guard" ]]
}

@test "anchored guard skips the block when body only documents the marker" {
  # With the [0-9]+ anchor, the outer guard correctly rejects a documentation-only
  # body. The script continues to completion without entering the extraction block.
  cat > "$BPSD_RUNTIME_DIR/anchored-guard.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

ISSUE_BODY="This issue tracks the sharkrite-parent-pr:N marker format.
It is a documentation-only reference, not a live marker."

echo "before-guard"

# GOOD: anchored — requires actual digits, documentation example doesn't match
if echo "$ISSUE_BODY" | grep -qE "sharkrite-parent-pr:[0-9]+"; then
  PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
  echo "parent-pr=$PARENT_PR"
fi

echo "after-guard"
EOF

  run bash "$BPSD_RUNTIME_DIR/anchored-guard.sh"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "before-guard" ]]
  [[ "$output" =~ "after-guard" ]]
  # Guard block was NOT entered (no "parent-pr=" in output)
  [[ ! "$output" =~ "parent-pr=" ]]
}

@test "anchored guard enters the block and extracts number when body has a live marker" {
  # Verify the anchored guard still works for the real use-case: a live marker
  # with an actual PR number.
  cat > "$BPSD_RUNTIME_DIR/anchored-live.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

ISSUE_BODY="This follow-up issue was created from PR review.
<!-- sharkrite-parent-pr:42 -->
Please address the items listed below."

echo "before-guard"

if echo "$ISSUE_BODY" | grep -qE "sharkrite-parent-pr:[0-9]+"; then
  PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
  echo "parent-pr=$PARENT_PR"
fi

echo "after-guard"
EOF

  run bash "$BPSD_RUNTIME_DIR/anchored-live.sh"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "before-guard" ]]
  [[ "$output" =~ "parent-pr=42" ]]
  [[ "$output" =~ "after-guard" ]]
}

# ---------------------------------------------------------------------------
# Group 2: Lint rule — UNANCHORED_MARKER_GREP
# ---------------------------------------------------------------------------

@test "lint rule UNANCHORED_MARKER_GREP fires on bare-prefix grep -q pattern" {
  # Place the violating file inside lib/ so the linter scans it
  cat > "$BPSD_LINT_DIR/unanchored-marker.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
BODY="some text"
if echo "$BODY" | grep -q "sharkrite-parent-pr:"; then
  echo "matched"
fi
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNANCHORED_MARKER_GREP" ]]
  [[ "$output" =~ "unanchored-marker.sh" ]]
}

@test "lint rule UNANCHORED_MARKER_GREP fires on bare-prefix grep -qE pattern" {
  cat > "$BPSD_LINT_DIR/unanchored-marker-e.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
BODY="some text"
if echo "$BODY" | grep -qE "sharkrite-followup-issue:"; then
  echo "matched"
fi
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNANCHORED_MARKER_GREP" ]]
  [[ "$output" =~ "unanchored-marker-e.sh" ]]
}

@test "lint rule UNANCHORED_MARKER_GREP does NOT fire on anchored grep with [0-9]+" {
  # A correctly anchored pattern must not produce a violation.
  # Place inside BATS tmp (outside lib/) so no pre-existing violations
  # from the fixture interfere; test lint directly on the pattern string.
  cat > "$BPSD_RUNTIME_DIR/anchored-ok.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
BODY="some text"
if echo "$BODY" | grep -qE "sharkrite-parent-pr:[0-9]+"; then
  echo "matched"
fi
EOF

  # This file is NOT in lib/, so the linter won't pick it up.
  # Verify the pattern we consider "safe" does NOT match the lint rule's detector:
  run bash -c "echo '$(cat "$BPSD_RUNTIME_DIR/anchored-ok.sh")' | grep -E \"grep\s+(-[a-zA-Z]+\s+)*['\\\"]sharkrite-[a-z-]+:['\\\"]\" || true"

  # No output means the safe pattern doesn't match the lint rule's detector
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Group 3: Codebase sweep — zero remaining unanchored marker greps in lib/
# ---------------------------------------------------------------------------

@test "codebase has zero unanchored sharkrite-marker: grep patterns in lib/" {
  # Search for bare-prefix patterns: grep (any flags) "sharkrite-<name>:"
  # Safe (anchored) patterns have [0-9], [a-z], [a-zA-Z], \d, or \w after the colon.
  # This regex finds the dangerous form: the pattern string ends with : before the closing quote.
  run bash -c "grep -rnE \"grep\s+(-[a-zA-Z]+\s+)*[\\\"']sharkrite-[a-z-]+:[\\\"']\" \
    \"$PROJECT_ROOT/lib/\" 2>/dev/null || true"

  if [ -n "$output" ]; then
    echo "FAIL: unanchored sharkrite marker grep(s) found:"
    echo "$output"
    return 1
  fi

  [ -z "$output" ]
}
