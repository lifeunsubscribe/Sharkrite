#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/local-review.sh
# Regression test for issue #796: warn when .github/claude-code/pr-review-instructions.md
# exists locally but is not tracked by git.
#
# A present-but-untracked file is used on the local machine yet silently absent on
# a fresh checkout / in CI, where rite falls back to the generic default without
# any indication that repo-specific instructions were expected.
#
# These tests verify the tier-1 template-selection branch in local-review.sh
# directly via sed extraction (same pattern as local-review-error-path.bats),
# so they exercise the real production code rather than a copy of it.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$PROJECT_ROOT/lib/core/local-review.sh"

  # Verify the untracked-warn block is present (marker-count guard).
  # If the block is removed or duplicated this guard fires before any test runs,
  # giving a clear diagnosis rather than a silent pass on empty extraction.
  WARN_COUNT=$(grep -c "untracked — commit it" "$SCRIPT" || true)
  if [ "$WARN_COUNT" -ne 1 ]; then
    echo "SETUP FAIL: expected exactly 1 'untracked — commit it' line in $SCRIPT, found $WARN_COUNT" >&2
    false
  fi
}

# ---------------------------------------------------------------------------
# Helper: create an isolated git repo in a temp dir with a minimal commit,
# then run the untracked-check shell fragment from local-review.sh inside it.
#
# $1 = "untracked" | "tracked" | "absent"
#
# Outputs the warnings that print_warning emitted (to stdout, captured by run).
# Exit 0 always — we're checking warning presence, not exit code.
# ---------------------------------------------------------------------------
_run_template_check() {
  local mode="$1"
  local test_dir
  test_dir=$(mktemp -d)

  # Build a minimal git repo so git ls-files --error-unmatch works correctly.
  (
    cd "$test_dir"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "root" > README.md
    git add README.md
    git commit -q -m "init"

    mkdir -p .github/claude-code

    case "$mode" in
      tracked)
        echo "# Custom review instructions" > .github/claude-code/pr-review-instructions.md
        git add .github/claude-code/pr-review-instructions.md
        git commit -q -m "add review instructions"
        ;;
      untracked)
        echo "# Custom review instructions" > .github/claude-code/pr-review-instructions.md
        # Intentionally NOT staged or committed — file is present but untracked.
        ;;
      absent)
        # File does not exist at all — tier-1 branch should not be entered.
        ;;
    esac
  )

  # Run the tier-1 template-selection logic from local-review.sh in a subprocess
  # with a controlled environment. We use the real production code via sed
  # extraction between sharkrite-extract markers, so any change to the production
  # implementation is automatically reflected here.
  #
  # The markers used here are: sharkrite-extract: template-tier1-start/end
  # (added to local-review.sh alongside this test).
  local extracted_code
  extracted_code=$(sed -n \
    '/# sharkrite-extract: template-tier1-start/,/# sharkrite-extract: template-tier1-end/p' \
    "$SCRIPT")

  [ -n "$extracted_code" ] || {
    echo "FAIL: sed extraction returned empty — sharkrite-extract markers missing in $SCRIPT" >&2
    rm -rf "$test_dir"
    return 1
  }

  # Content anchor: extraction must contain the untracked-check git call.
  [[ "$extracted_code" == *"ls-files --error-unmatch"* ]] || {
    echo "FAIL: extracted code missing ls-files --error-unmatch — wrong range extracted" >&2
    rm -rf "$test_dir"
    return 1
  }

  run bash -c "
    set -euo pipefail

    # Stubs for print helpers (matching local-review-diff-fallback.bats pattern)
    print_status()  { echo \"[STATUS] \$*\" >&2; }
    print_warning() { echo \"[WARNING] \$*\"; }
    export -f print_status print_warning

    RITE_PROJECT_ROOT='${test_dir}'
    REPO_TEMPLATE='${test_dir}/.github/claude-code/pr-review-instructions.md'
    REVIEW_TEMPLATE=''

    ${extracted_code}
  "

  rm -rf "$test_dir"
}

# ---------------------------------------------------------------------------
# Test 1: Untracked file → warning is emitted
# ---------------------------------------------------------------------------

@test "untracked review instructions: warning printed" {
  _run_template_check untracked

  # Warning line must be present (via print_warning stub → stdout)
  [[ "$output" == *"untracked"* ]] || {
    echo "Expected 'untracked' in output but got: $output" >&2
    false
  }
  [[ "$output" == *"commit it"* ]] || {
    echo "Expected 'commit it' in output but got: $output" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Test 2: Tracked file → no warning
# ---------------------------------------------------------------------------

@test "tracked review instructions: no warning printed" {
  _run_template_check tracked

  # Warning must NOT be present
  [[ "$output" != *"untracked"* ]] || {
    echo "Did not expect 'untracked' in output for tracked file but got: $output" >&2
    false
  }
  [[ "$output" != *"commit it"* ]] || {
    echo "Did not expect 'commit it' in output for tracked file but got: $output" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Test 3: Absent file → silent fallback, no warning from tier-1 branch
# ---------------------------------------------------------------------------

@test "absent review instructions: no warning (tier-1 branch not entered)" {
  _run_template_check absent

  # The tier-1 branch is not entered when the file is absent, so no warning.
  [[ "$output" != *"untracked"* ]] || {
    echo "Did not expect 'untracked' in output for absent file but got: $output" >&2
    false
  }
  [[ "$output" != *"commit it"* ]] || {
    echo "Did not expect 'commit it' in output for absent file but got: $output" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Test 4: Static source check — sharkrite-extract markers appear exactly once
# ---------------------------------------------------------------------------

@test "local-review.sh has exactly one pair of template-tier1 extract markers" {
  START_COUNT=$(grep -c '# sharkrite-extract: template-tier1-start' "$SCRIPT" || true)
  END_COUNT=$(grep -c '# sharkrite-extract: template-tier1-end' "$SCRIPT" || true)

  [ "$START_COUNT" -eq 1 ] || {
    echo "Expected 1 template-tier1-start marker, found $START_COUNT" >&2
    false
  }
  [ "$END_COUNT" -eq 1 ] || {
    echo "Expected 1 template-tier1-end marker, found $END_COUNT" >&2
    false
  }
}
