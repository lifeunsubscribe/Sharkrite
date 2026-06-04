#!/usr/bin/env bats
# Lint tests for Rule 19: RAW_MARKER_LITERAL
#
# Verifies that:
#   1. The codebase contains no raw sharkrite-* marker literals
#      (all functional code must use RITE_MARKER_* constants)
#   2. The lint rule fires on fixture files that contain raw literals
#   3. The lint rule does NOT fire on files using RITE_MARKER_* constants
#   4. Comment-only occurrences are correctly exempted

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  # Use BATS_TEST_TMPDIR so fixtures are outside the project tree.
  # Inject via RITE_LINT_EXTRA_DIRS so the linter scans them without
  # the test-fixtures-temp exclusion interfering.
  export LINT_FIXTURE_DIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}/rule19-fixtures"
  mkdir -p "$LINT_FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$LINT_FIXTURE_DIR"
}

teardown() {
  rm -rf "$LINT_FIXTURE_DIR"
  unset RITE_LINT_EXTRA_DIRS
}

# ── Codebase-sweep test ──────────────────────────────────────────────────────

@test "no raw sharkrite-* marker literals in production codebase" {
  # Uses the shipped RAW_MARKER_LITERAL lint rule (Rule 19 in tools/sharkrite-lint.sh)
  # as the authoritative check. lib/utils/markers.sh and tools/sharkrite-lint.sh are
  # exempt; tests/ is excluded from the lint scan scope.

  cd "$PROJECT_ROOT"
  # No fixture files — ensure fixture dir is empty so only the real codebase is scanned
  rm -f "$LINT_FIXTURE_DIR"/*.sh 2>/dev/null || true

  run tools/sharkrite-lint.sh

  if [[ "$output" =~ "RAW_MARKER_LITERAL" ]]; then
    echo "Found raw sharkrite-* marker literal violations:"
    echo "$output" | grep "RAW_MARKER_LITERAL"
    false
  fi
  true
}

# ── Rule-activation check ────────────────────────────────────────────────────

@test "RAW_MARKER_LITERAL rule is registered in sharkrite-lint.sh" {
  cd "$PROJECT_ROOT"
  run grep -q "RAW_MARKER_LITERAL" tools/sharkrite-lint.sh
  [ "$status" -eq 0 ]
}

# ── Violation detection ──────────────────────────────────────────────────────

@test "RAW_MARKER_LITERAL: fires on raw sharkrite-local-review literal in code" {
  cat > "$LINT_FIXTURE_DIR/bad-review-literal.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# A file that hard-codes the review marker instead of using RITE_MARKER_REVIEW
_jq_filter="[.comments[] | select(.body | contains(\"<!-- sharkrite-local-review\"))] | .[0]"
result=$(echo "{}" | jq -r "$_jq_filter" || true)
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "RAW_MARKER_LITERAL" ]]
  [[ "$output" =~ bad-review-literal\.sh ]]
}

@test "RAW_MARKER_LITERAL: fires on raw sharkrite-assessment literal in code" {
  cat > "$LINT_FIXTURE_DIR/bad-assessment-literal.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# Hard-coded assessment marker
BODY=$(echo "<!-- sharkrite-assessment --> content")
echo "$BODY"
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "RAW_MARKER_LITERAL" ]]
  [[ "$output" =~ bad-assessment-literal\.sh ]]
}

@test "RAW_MARKER_LITERAL: fires on raw sharkrite-followup-issue literal in code" {
  cat > "$LINT_FIXTURE_DIR/bad-followup-literal.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# Hard-coded followup marker
NUMS=$(echo "$body" | grep -oE "sharkrite-followup-issue:[0-9]+" | cut -d: -f2 || true)
echo "$NUMS"
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "RAW_MARKER_LITERAL" ]]
  [[ "$output" =~ bad-followup-literal\.sh ]]
}

# ── Allowlist / false-positive prevention ────────────────────────────────────

@test "RAW_MARKER_LITERAL: does not fire on RITE_MARKER_* variable references" {
  # The fixture uses ${RITE_MARKER_*} variable expansions (no bare literals).
  # We don't define the constants inline (that would itself be flagged) —
  # the fixture just references them as unexpanded variables in strings.
  cat > "$LINT_FIXTURE_DIR/good-uses-constant.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# Correct usage: RITE_MARKER_* variables — no bare sharkrite-* string literals in code
_jq="[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))] | .[0]"
result=$(echo "{}" | jq -r "$_jq" || true)
echo "$result"
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  # If RAW_MARKER_LITERAL fires, ensure it is not from our good fixture
  if [[ "$output" =~ "RAW_MARKER_LITERAL" ]]; then
    [[ ! "$output" =~ good-uses-constant\.sh ]] || {
      false  # RAW_MARKER_LITERAL falsely flagged RITE_MARKER_* variable usage
    }
  fi
}

@test "RAW_MARKER_LITERAL: does not fire on comment-only sharkrite- references" {
  cat > "$LINT_FIXTURE_DIR/good-comment-only.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# This file references sharkrite-local-review and sharkrite-assessment
# only in comments. The actual code uses RITE_MARKER_* variables.
# See lib/utils/markers.sh for the canonical constant definitions.
echo "no literal markers in code"
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  if [[ "$output" =~ "RAW_MARKER_LITERAL" ]]; then
    [[ ! "$output" =~ good-comment-only\.sh ]] || {
      false  # RAW_MARKER_LITERAL falsely flagged comment-only sharkrite- reference
    }
  fi
}
