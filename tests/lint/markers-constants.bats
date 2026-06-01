#!/usr/bin/env bats
# Tests for Rule 13: LITERAL_MARKER_STRING
#
# Verifies that the lint rule rejects sharkrite-* literal strings in any
# file other than lib/utils/markers.sh, and passes when constants are used.

setup() {
  TEST_DIR=$(mktemp -d)
  LINT_SCRIPT="$BATS_TEST_DIRNAME/../../tools/sharkrite-lint.sh"
  # Tests place scripts inside lib/ subdirs so the linter scans them
  mkdir -p "$TEST_DIR/lib/utils" "$TEST_DIR/lib/core" "$TEST_DIR/bin" "$TEST_DIR/tools"

  # Create a minimal markers.sh so the linter's allowlist file exists
  cat > "$TEST_DIR/lib/utils/markers.sh" <<'EOF'
#!/bin/bash
[ -n "${_RITE_MARKERS_LOADED:-}" ] && return 0
readonly _RITE_MARKERS_LOADED=1
readonly RITE_MARKER_REVIEW="sharkrite-local-review"
readonly RITE_MARKER_ASSESSMENT="sharkrite-assessment"
readonly RITE_MARKER_FOLLOWUP_ISSUE="sharkrite-followup-issue"
readonly RITE_MARKER_PARENT_PR="sharkrite-parent-pr"
readonly RITE_MARKER_SOURCE_ISSUE="sharkrite-source-issue"
readonly RITE_MARKER_REVIEW_DATA="sharkrite-review-data"
readonly RITE_MARKER_CHANGES_SUMMARY="sharkrite-changes-summary"
readonly RITE_MARKER_AUTO_RESOLVED="sharkrite-auto-resolved"
readonly RITE_MARKER_STASH="sharkrite-managed-stash"
readonly RITE_MARKER_STASH_TAG="[${RITE_MARKER_STASH}]"
EOF

  # Create sharkrite-lint.sh stub so the linter doesn't flag itself
  cp "$LINT_SCRIPT" "$TEST_DIR/tools/sharkrite-lint.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Positive: literal strings trigger LITERAL_MARKER_STRING
# ---------------------------------------------------------------------------

@test "detects sharkrite-local-review literal in double quotes" {
  cat > "$TEST_DIR/lib/core/bad-review.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
RESULT=$(gh pr view 1 --json comments --jq '[.comments[] | select(.body | contains("<!-- sharkrite-local-review"))]')
EOF

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "LITERAL_MARKER_STRING" ]]
}

@test "detects sharkrite-assessment literal in double quotes" {
  cat > "$TEST_DIR/lib/core/bad-assess.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
RESULT=$(gh pr view 1 --json comments --jq '[.comments[] | select(.body | contains("sharkrite-assessment"))]')
EOF

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "LITERAL_MARKER_STRING" ]]
}

@test "detects sharkrite-parent-pr literal in single quotes" {
  cat > "$TEST_DIR/lib/core/bad-parent.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
if echo "$BODY" | grep -q 'sharkrite-parent-pr:'; then
  echo "found"
fi
EOF

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "LITERAL_MARKER_STRING" ]]
}

@test "detects sharkrite-followup-issue literal" {
  cat > "$TEST_DIR/lib/core/bad-followup.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
MARKER="sharkrite-followup-issue"
echo "$MARKER"
EOF

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "LITERAL_MARKER_STRING" ]]
}

# ---------------------------------------------------------------------------
# Negative: constants are allowed everywhere (no violation)
# ---------------------------------------------------------------------------

@test "allows RITE_MARKER_REVIEW constant in jq expression" {
  cat > "$TEST_DIR/lib/core/good-review.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
source "${RITE_LIB_DIR}/utils/markers.sh"
RESULT=$(gh pr view 1 --json comments --jq "[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_REVIEW}\"))]" || true)
EOF

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "LITERAL_MARKER_STRING" ]]
}

@test "allows RITE_MARKER_ASSESSMENT constant in jq expression" {
  cat > "$TEST_DIR/lib/core/good-assess.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
source "${RITE_LIB_DIR}/utils/markers.sh"
RESULT=$(gh pr view 1 --json comments --jq "[.comments[] | select(.body | contains(\"<!-- ${RITE_MARKER_ASSESSMENT}\"))]" || true)
EOF

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "LITERAL_MARKER_STRING" ]]
}

@test "allows RITE_MARKER_PARENT_PR constant in grep" {
  cat > "$TEST_DIR/lib/core/good-parent.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
source "${RITE_LIB_DIR}/utils/markers.sh"
if echo "$BODY" | grep -q "${RITE_MARKER_PARENT_PR}:"; then
  echo "found"
fi
EOF

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "LITERAL_MARKER_STRING" ]]
}

# ---------------------------------------------------------------------------
# Allowlist: markers.sh itself is exempt
# ---------------------------------------------------------------------------

@test "markers.sh itself is exempt from the rule" {
  # The markers.sh created in setup already contains sharkrite-* literals
  # (the readonly assignments). Verify the linter doesn't flag it.
  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  # May still pass overall — we just check no LITERAL_MARKER_STRING from markers.sh
  [[ ! "$output" =~ "markers.sh.*LITERAL_MARKER_STRING" ]]
}

# ---------------------------------------------------------------------------
# Comment lines are exempt
# ---------------------------------------------------------------------------

@test "comment lines with sharkrite- are not flagged" {
  cat > "$TEST_DIR/lib/core/commented.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# The "sharkrite-local-review" marker is written by local-review.sh
echo "ok"
EOF

  cd "$TEST_DIR/.."
  run "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "LITERAL_MARKER_STRING" ]]
}

# ---------------------------------------------------------------------------
# Codebase-wide check: zero literals remain after refactor
# ---------------------------------------------------------------------------

@test "codebase has zero remaining sharkrite-* literals outside markers.sh" {
  # Run lint against the actual project (not the temp dir)
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  run "$LINT_SCRIPT"

  # Only check the LITERAL_MARKER_STRING rule output
  if [[ "$output" =~ "LITERAL_MARKER_STRING" ]]; then
    fail "Remaining sharkrite-* literals detected: $output"
  fi
  # The run command may fail for other rules — filter to just this check
  echo "$output" | grep -v "LITERAL_MARKER_STRING" || true
}
