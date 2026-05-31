#!/usr/bin/env bats
# Regression test for #77: Detect 'local' outside function scope
#
# Bug history:
# - Milestone #11: Fixed lib/core/local-review.sh:295
# - Issue #77: Fixed lib/core/claude-workflow.sh:1364 (emergency patch commit 4eace34)
# - Issue #77: Fixed 3 more instances in claude-workflow.sh (commit e58e2e8)
#
# This test ensures no new instances are introduced.

setup() {
  # Find project root (tests/ is at project root level)
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "no 'local' declarations outside function scope in codebase" {
  # Use the precise awk pattern from issue #77 acceptance criteria
  # This pattern tracks function depth via brace matching and flags 'local' at depth 0

  cd "$PROJECT_ROOT"

  # Scan all .sh files in lib/ and bin/
  # AWK pattern: track function depth via braces, flag 'local' at depth 0
  run bash -c '{ find lib -name "*.sh" -type f -print0; find bin -type f -print0; } | xargs -0 awk '"'"'/^[a-z_][a-zA-Z_0-9]*\(\) *\{/{depth++} /^\}/{depth--} /^[[:space:]]*local /{ if(depth==0) print FILENAME":"NR":"$0 }'"'"' 2>/dev/null'

  # Should produce no output (no matches)
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # If this fails, the output will show file:line:content of the violation
}

@test "lint rule catches local outside function (via make check)" {
  # Verify that the lint rule in tools/sharkrite-lint.sh is active
  # This doesn't fail the build but ensures the rule is configured

  cd "$PROJECT_ROOT"

  # Check that the lint script contains the LOCAL_OUTSIDE_FUNCTION rule
  run grep -q "LOCAL_OUTSIDE_FUNCTION" tools/sharkrite-lint.sh
  [ "$status" -eq 0 ]
}
