#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/08-unsafe-pipe-inside-command-substitution-sile.sh, tools/lint-rules/16-missing-re-source-guard-in-lib-utils-lib-pro.sh, tools/sharkrite-lint.sh
# Regression test for: Sweep codebase for set -e + pipefail silent-death
#
# Bug pattern: VAR=$(... | grep ...) under set -euo pipefail silently kills
# the script when grep finds no match (exit 1), because the pipeline exits 1,
# command substitution returns 1, and the script dies with no error output.
#
# Fix: Add || true to all such patterns: VAR=$(... | grep ... || true)
#
# This test verifies that:
# 1. The lint rule detects unsafe patterns
# 2. A deliberately-no-match grep either fails gracefully OR continues with empty value
# 3. The script does NOT silently die with no output

setup() {
  # Create temp dir for runtime test scripts
  export RITE_TEST_ROOT="${BATS_TEST_TMPDIR}/rite-test"
  mkdir -p "$RITE_TEST_ROOT"
}

teardown() {
  rm -rf "$RITE_TEST_ROOT"
}

@test "lint rule detects unsafe VAR=\$(... | grep) pattern" {
  # Plant fixture in a BATS_TEST_TMPDIR subdir and inject via RITE_LINT_EXTRA_DIRS
  # (avoids the lib/test-fixtures-temp exclusion and the Rule 16 MISSING_RESOURCE_GUARD check)
  local _dir="${BATS_TEST_TMPDIR}/detect-unsafe-grep"
  mkdir -p "$_dir"
  cat > "$_dir/unsafe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# This is unsafe - no || true
RESULT=$(echo "foo" | grep "bar")
echo "Result: $RESULT"
EOF

  # Run the lint rule with the fixture dir injected
  cd "$BATS_TEST_DIRNAME/../.."  # Project root (tests/regression/ → project root)
  export RITE_LINT_EXTRA_DIRS="$_dir"
  SHARKRITE_LINT_ONLY=08 run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  # Should fail with violation
  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
  [[ "$output" =~ "unsafe.sh" ]]
}

@test "lint rule allows safe VAR=\$(... | grep || true) pattern" {
  # Create a test script with safe pattern
  cat > "$RITE_TEST_ROOT/safe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# This is safe - has || true
RESULT=$(echo "foo" | grep "bar" || true)
echo "Result: $RESULT"
EOF

  # Run the script - should succeed with empty result
  run bash "$RITE_TEST_ROOT/safe.sh"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Result:" ]]
}

@test "unsafe pattern silently kills script (demonstrates the bug)" {
  # Create a test script WITHOUT || true
  cat > "$RITE_TEST_ROOT/unsafe-demo.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "Starting..."
RESULT=$(echo "foo" | grep "bar")
echo "This line should never print"
echo "Result: $RESULT"
EOF

  # Run the script - should fail
  run bash "$RITE_TEST_ROOT/unsafe-demo.sh"

  # Script dies silently (exit 1, no error message from grep in a pipe)
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Starting..." ]]
  [[ ! "$output" =~ "This line should never print" ]]
}

@test "safe pattern continues gracefully when grep finds no match" {
  # Create a test script WITH || true
  cat > "$RITE_TEST_ROOT/safe-demo.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "Starting..."
RESULT=$(echo "foo" | grep "bar" || true)
echo "Continued after grep"
echo "Result: ${RESULT:-empty}"
EOF

  # Run the script - should succeed
  run bash "$RITE_TEST_ROOT/safe-demo.sh"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Starting..." ]]
  [[ "$output" =~ "Continued after grep" ]]
  [[ "$output" =~ "Result: empty" ]]
}

@test "lint rule detects multiline unsafe pattern" {
  # Plant fixture in a BATS_TEST_TMPDIR subdir and inject via RITE_LINT_EXTRA_DIRS
  local _dir="${BATS_TEST_TMPDIR}/detect-multiline-unsafe"
  mkdir -p "$_dir"
  cat > "$_dir/multiline-unsafe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
RESULT=$(git worktree list | \
  grep "pattern")
echo "Result: $RESULT"
EOF

  # Run the lint rule with the fixture dir injected
  cd "$BATS_TEST_DIRNAME/../.."  # Project root (tests/regression/ → project root)
  export RITE_LINT_EXTRA_DIRS="$_dir"
  SHARKRITE_LINT_ONLY=08 run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
  [[ "$output" =~ "multiline-unsafe.sh" ]]
}

@test "lint rule allows multiline safe pattern" {
  # Create a test script with multiline safe pattern
  cat > "$RITE_TEST_ROOT/multiline-safe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
RESULT=$(git worktree list | \
  grep "pattern" || true)
echo "Result: $RESULT"
EOF

  # Verify the safe script runs
  # (We can't run git worktree list in the test, but bash parsing should work)
  run bash -n "$RITE_TEST_ROOT/multiline-safe.sh"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Boundary tests: Rule 8 AWK lookahead flush at file boundaries
#
# The AWK program uses a pending-line buffer: when a triggering line is found
# it sets pending_line=FNR, then resolves on the NEXT line.  Three flush paths
# exist and each must be exercised:
#
#   1. FNR == 1 (start of next file) — flushes pending from previous file
#   2. END block                     — flushes pending from last/only file
#   3. Same file, next line has guard — clears pending without printing
#
# The old per-file sed lookahead behaved identically (sed returned empty string
# for next_line when the trigger was on the last line; no guard = violation).
# These tests lock in that behavioral equivalence for the AWK replacement.
# ---------------------------------------------------------------------------

@test "Rule 8 boundary: trigger on last line of file fires violation (END block)" {
  # Unsafe pattern on the very last line — no next line to resolve the lookahead.
  # The AWK END block must flush pending_line and fire the violation.
  # Plant fixture in a BATS_TEST_TMPDIR subdir and inject via RITE_LINT_EXTRA_DIRS
  local _dir="${BATS_TEST_TMPDIR}/r8-last-line"
  mkdir -p "$_dir"
  cat > "$_dir/r8-last-line-unsafe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "preamble"
RESULT=$(echo "data" | grep "pattern")
EOF

  cd "$BATS_TEST_DIRNAME/../.."
  export RITE_LINT_EXTRA_DIRS="$_dir"
  SHARKRITE_LINT_ONLY=08 run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
  [[ "$output" =~ "r8-last-line-unsafe.sh" ]]
}

@test "Rule 8 boundary: safe pattern on last line of file — no violation" {
  # Safe pattern (|| true) on the very last line — no violation expected.
  # Use RITE_LINT_EXTRA_DIRS with a temp dir outside lib/ to avoid Rule 16
  # (MISSING_RESOURCE_GUARD) firing on the fixture itself.
  local _safe_dir="${BATS_TEST_TMPDIR}/r8-safe-boundary"
  mkdir -p "$_safe_dir"
  cat > "$_safe_dir/r8-last-line-safe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "preamble"
RESULT=$(echo "data" | grep "pattern" || true)
EOF

  cd "$BATS_TEST_DIRNAME/../.."
  export RITE_LINT_EXTRA_DIRS="$_safe_dir"
  SHARKRITE_LINT_ONLY=08 run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  [[ ! "$output" =~ "r8-last-line-safe.sh" ]]
}

@test "Rule 8 boundary: single-line file with unsafe trigger fires violation" {
  # File has exactly one line (the trigger itself).
  # AWK: FNR==1 fires (nothing pending yet), then main block sets pending_line=1.
  # END block must flush and fire the violation.
  # Plant fixture in a BATS_TEST_TMPDIR subdir and inject via RITE_LINT_EXTRA_DIRS
  local _dir="${BATS_TEST_TMPDIR}/r8-single-line-unsafe"
  mkdir -p "$_dir"
  cat > "$_dir/r8-single-line-unsafe.sh" <<'EOF'
RESULT=$(echo "data" | grep "pattern")
EOF

  cd "$BATS_TEST_DIRNAME/../.."
  export RITE_LINT_EXTRA_DIRS="$_dir"
  SHARKRITE_LINT_ONLY=08 run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
  [[ "$output" =~ "r8-single-line-unsafe.sh" ]]
}

@test "Rule 8 boundary: trigger on last line of first file fires via FNR==1 of next file" {
  # When AWK processes multiple files, a pending trigger from the last line of
  # file N must be flushed at FNR==1 of file N+1 (not silently dropped).
  # Inject two fixtures in the same dir; the linter scans both in one AWK pass.
  # Plant fixtures in a BATS_TEST_TMPDIR subdir and inject via RITE_LINT_EXTRA_DIRS
  local _dir="${BATS_TEST_TMPDIR}/r8-multi-file"
  mkdir -p "$_dir"
  cat > "$_dir/r8-multi-file-a.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
RESULT=$(echo "data" | grep "pattern")
EOF
  # Second file is clean — present only to force the multi-file AWK pass
  cat > "$_dir/r8-multi-file-b.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "clean file"
EOF

  cd "$BATS_TEST_DIRNAME/../.."
  export RITE_LINT_EXTRA_DIRS="$_dir"
  SHARKRITE_LINT_ONLY=08 run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
  # Violation must reference the first file, not the second
  [[ "$output" =~ "r8-multi-file-a.sh" ]]
}

@test "Rule 8 boundary: multiline pattern where guard is on line after last trigger line" {
  # Two-line multiline pattern: trigger on line N, guard (|| true) on line N+1.
  # This is the normal multiline-safe case but ensures the lookahead resolves
  # correctly when it is also the end of the file.
  # Use RITE_LINT_EXTRA_DIRS with a temp dir outside lib/ to avoid Rule 16
  # (MISSING_RESOURCE_GUARD) firing on the fixture itself.
  local _safe_dir="${BATS_TEST_TMPDIR}/r8-multiline-boundary"
  mkdir -p "$_safe_dir"
  cat > "$_safe_dir/r8-multiline-guard-at-eof.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
RESULT=$(echo "data" | \
  grep "pattern" || true)
EOF

  cd "$BATS_TEST_DIRNAME/../.."
  export RITE_LINT_EXTRA_DIRS="$_safe_dir"
  SHARKRITE_LINT_ONLY=08 run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  [[ ! "$output" =~ "r8-multiline-guard-at-eof.sh" ]]
}

@test "codebase has zero remaining unsafe patterns" {
  cd "$(dirname "$BATS_TEST_DIRNAME")"

  # Search for patterns that look unsafe: VAR=$(... | grep ...) without || true on same line
  # This finds grep in command substitution, then filters out safe patterns
  run bash -c 'grep -rn "=\$(.*| grep" lib/ bin/ 2>/dev/null | grep -v "|| true\||| echo\|: \\\$?" || true'

  # For each match, verify it's safe via one of these patterns:
  # 1. Has || true somewhere in the next 10 lines (handles multiline)
  # 2. Pipes to head/tail which always succeeds (grep | head is safe)
  if [ -n "$output" ]; then
    while IFS=: read -r file line rest; do
      # Get a reasonable context window for multiline patterns
      context=$(sed -n "${line},$((line + 10))p" "$file" 2>/dev/null || true)

      # Check if pattern is safe: has || true OR pipes to head/tail
      if echo "$context" | grep -q '|| true'; then
        # Safe: has || true
        continue
      elif echo "$context" | grep -q '| head\|| tail'; then
        # Safe: pipes to head/tail which always succeed
        continue
      else
        fail "UNSAFE pattern without safety guard found at ${file}:${line}"
      fi
    done <<< "$output"
  fi

  # Test passes if all matches are verified safe
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Rule 8 multi-line tracking (2026-06-12): the original implementation decided
# at the NEXT line only, so a multi-line command substitution whose || true
# guard sits on the CLOSING line was falsely flagged. Live false positive:
# the two awk blocks in plan-issues.sh::_resolve_ordinal_refs_in_body (#568)
# turned main's `make check` red. The rule now scans forward until a guard
# clears the pending line, an unguarded `)` line closes it, or a 40-line cap.
# ---------------------------------------------------------------------------

# Fixtures use RITE_LINT_EXTRA_DIRS pointing at a tmp dir OUTSIDE lib/ — the
# same working pattern as the detect and boundary tests above.
# A .sh fixture placed in lib/ would (a) trip Rule 16 MISSING_RESOURCE_GUARD on
# the fixture itself and (b) be skipped anyway: the default scan excludes
# */test-fixtures-temp*. All tests in this file use the RITE_LINT_EXTRA_DIRS
# pattern to avoid both of these issues.

@test "Rule 8 multi-line: guard on closing line of awk block — no violation" {
  local _dir="${BATS_TEST_TMPDIR}/r8-closing-guard"
  mkdir -p "$_dir"
  cat > "$_dir/multiline-closing-guard.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
_body="x"
_body=$(printf '%s' "$_body" | awk '
  { lines[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      if (i > 1) printf "\n"
      printf "%s", lines[i]
    }
  }
' || true)
echo "$_body"
EOF

  cd "$BATS_TEST_DIRNAME/../.."
  export RITE_LINT_EXTRA_DIRS="$_dir"
  SHARKRITE_LINT_ONLY=08 run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  # The planted file must NOT be flagged (guard is on the closing line)
  [[ ! "$output" =~ "multiline-closing-guard.sh" ]] || {
    echo "false positive: closing-line || true not recognized" >&2
    echo "$output" >&2
    return 1
  }
}

@test "Rule 8 multi-line: unguarded closing line of awk block — violation fires" {
  local _dir="${BATS_TEST_TMPDIR}/r8-unguarded-close"
  mkdir -p "$_dir"
  cat > "$_dir/multiline-unguarded-close.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
_body="x"
_body=$(printf '%s' "$_body" | awk '
  { lines[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      printf "%s", lines[i]
    }
  }
')
echo "$_body"
EOF

  cd "$BATS_TEST_DIRNAME/../.."
  export RITE_LINT_EXTRA_DIRS="$_dir"
  SHARKRITE_LINT_ONLY=08 run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
  [[ "$output" =~ "multiline-unguarded-close.sh" ]]
}

@test "Rule 8 single-line: unguarded substitution still resolves immediately" {
  # The forward-scan must not weaken the classic single-line detection: the
  # opener line ends with ')' and is reported at once.
  local _dir="${BATS_TEST_TMPDIR}/r8-single-line"
  mkdir -p "$_dir"
  cat > "$_dir/single-line-unsafe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
COUNT=$(echo "abc" | grep -c "z")
echo "$COUNT"
EOF

  cd "$BATS_TEST_DIRNAME/../.."
  export RITE_LINT_EXTRA_DIRS="$_dir"
  SHARKRITE_LINT_ONLY=08 run tools/sharkrite-lint.sh
  unset RITE_LINT_EXTRA_DIRS

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
  [[ "$output" =~ "single-line-unsafe.sh" ]]
}
