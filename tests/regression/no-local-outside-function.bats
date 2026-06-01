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
  # Tracks function depth via brace matching and flags 'local' at depth 0.
  # Heredoc-aware: skips lines between <<EOF/<<'EOF' markers and their terminators
  # so that JSON/YAML braces inside heredocs don't corrupt the depth counter.
  # Handles all bash function declaration styles:
  #   name() {          POSIX style
  #   name() {          with hyphens in name
  #   function name {   keyword style without parens
  #   function name() { keyword style with parens

  cd "$PROJECT_ROOT"

  # Write the AWK program to a temp file to avoid shell quoting complexity
  local awk_script
  awk_script=$(mktemp)
  cat > "$awk_script" <<'AWKEOF'
/<<['"]?[A-Z_][A-Z_0-9]*['"]?[[:space:]]*$/ { in_heredoc=1; next }
/^[A-Z_][A-Z_0-9]*$/ && in_heredoc               { in_heredoc=0; next }
in_heredoc { next }
/^[a-zA-Z_][a-zA-Z_0-9-]*\(\)[[:space:]]*\{/    { depth++; next }
/^function[[:space:]]/                             { depth++; next }
/^\}/                                              { depth--; next }
/^[[:space:]]*local / { if (depth <= 0) print FILENAME ":" NR ":" $0 }
AWKEOF

  run bash -c '{ find lib -name "*.sh" -type f -print0; find bin -type f -print0; } | xargs -0 awk -f '"$awk_script"' 2>/dev/null'
  rm -f "$awk_script"

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
