#!/usr/bin/env bats
# Regression test for: Dev session deletes unrelated regression tests
#
# Bug history (PR #121, issue #49):
#   Claude's dev session deleted tests/regression/empty-diff-after-fetch.bats
#   while working on a lint regex fix.  The issue's Scope Boundary said:
#     DO: tweak the regex
#     DO NOT: touch unrelated tests
#   The deletion was not caught because Sharkrite had no scope enforcement.
#
# This test verifies that check_scope_boundary() in lib/utils/scope-checker.sh:
#   1. Detects files that match DO NOT bullets as violations.
#   2. Detects files NOT covered by any DO bullet as violations.
#   3. Does NOT flag files explicitly covered by DO bullets.
#   4. Returns 0 (no violations) when there is no Scope Boundary section.
#   5. Returns 0 (no violations) when issue body is empty.

setup() {
  # Find project root (tests/regression/ is 2 levels below root)
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT
  SCOPE_CHECKER="$PROJECT_ROOT/lib/utils/scope-checker.sh"
  export SCOPE_CHECKER

  # Create a temp git repo to simulate a feature branch with changed files
  TEST_REPO_DIR="${BATS_TEST_TMPDIR}/test-repo"
  export TEST_REPO_DIR
  mkdir -p "$TEST_REPO_DIR"

  cd "$TEST_REPO_DIR"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"

  # Baseline commit on main: in-scope file + two test files
  mkdir -p lib/core tests/regression
  printf "# foo\n" > lib/core/foo.sh
  printf "# unrelated test\n" > tests/regression/unrelated.bats
  printf "# related test\n" > tests/regression/related.bats
  git add -A
  git commit -q -m "initial commit"

  # Normalise branch name to 'main'
  _cur=$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD)
  if [ "$_cur" != "main" ]; then
    git branch -m "$_cur" main 2>/dev/null || true
  fi

  # Simulate origin/main pointing at the baseline commit
  git update-ref refs/remotes/origin/main refs/heads/main 2>/dev/null || true

  # Feature branch: modify in-scope file AND delete unrelated test
  git checkout -q -b feature/issue-49
  printf "# foo modified\n" > lib/core/foo.sh
  rm tests/regression/unrelated.bats
  git add -A
  git commit -q -m "fix: tweak regex (also deleted unrelated test)"
}

teardown() {
  cd "$PROJECT_ROOT"
  rm -rf "$TEST_REPO_DIR"
}

# ---------------------------------------------------------------------------
# Helper: write issue body to a temp file, run check_scope_boundary via bash
# Returns the status and output via bats 'run'
# ---------------------------------------------------------------------------
_run_scope_check_file() {
  local body_file="$1"
  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    check_scope_boundary \"\$BODY\" \"$TEST_REPO_DIR\"
  "
}

# ---------------------------------------------------------------------------
# Test 1: DO NOT bullet — deleted unrelated test is flagged as a violation
# ---------------------------------------------------------------------------
@test "DO NOT bullet: deleted unrelated test is flagged as violation" {
  local body_file="${BATS_TEST_TMPDIR}/body1.txt"
  cat > "$body_file" <<'EOF'
## Scope Boundary:
- DO: tweak the regex in lib/core/foo.sh
- DO NOT: touch unrelated tests
EOF

  _run_scope_check_file "$body_file"

  # Should return 1 (violations found)
  [ "$status" -eq 1 ]
  # Should flag the unrelated test file
  [[ "$output" == *"tests/regression/unrelated.bats"* ]]
  [[ "$output" == *"VIOLATION:"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: Unlisted file — file not covered by any DO bullet is flagged
# ---------------------------------------------------------------------------
@test "unlisted file: file not in DO bullets is flagged as violation" {
  local body_file="${BATS_TEST_TMPDIR}/body2.txt"
  # DO only covers lib/core/foo.sh — unrelated.bats is unlisted
  cat > "$body_file" <<'EOF'
## Scope Boundary:
- DO: lib/core/foo.sh
EOF

  _run_scope_check_file "$body_file"

  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION:"* ]]
  # The deleted unrelated.bats should be flagged (deleted = changed)
  [[ "$output" == *"unrelated.bats"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: In-scope file only — no violation
# ---------------------------------------------------------------------------
@test "in-scope file only: no violation when all changes are covered by DO" {
  # Create a separate branch that only touches lib/core/foo.sh
  cd "$TEST_REPO_DIR"
  git checkout -q main
  git checkout -q -b feature/scope-ok
  printf "# foo v2\n" > lib/core/foo.sh
  git add -A
  git commit -q -m "fix: only modify in-scope file"
  git update-ref refs/remotes/origin/main refs/heads/main 2>/dev/null || true

  local body_file="${BATS_TEST_TMPDIR}/body3.txt"
  cat > "$body_file" <<'EOF'
## Scope Boundary:
- DO: lib/core/foo.sh
EOF

  _run_scope_check_file "$body_file"

  [ "$status" -eq 0 ]
  [[ "$output" != *"VIOLATION:"* ]] || false
}

# ---------------------------------------------------------------------------
# Test 4: No Scope Boundary section — check passes (returns 0, no output)
# ---------------------------------------------------------------------------
@test "no scope boundary section: check returns 0 and no output" {
  local body_file="${BATS_TEST_TMPDIR}/body4.txt"
  cat > "$body_file" <<'EOF'
## Description
This issue has no scope boundary section.
Just a regular description with some requirements.

## Acceptance Criteria
- [ ] Something works
EOF

  _run_scope_check_file "$body_file"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Test 5: Empty issue body — check passes silently
# ---------------------------------------------------------------------------
@test "empty issue body: check returns 0 with no output" {
  run bash -c "
    source \"$SCOPE_CHECKER\"
    check_scope_boundary \"\" \"$TEST_REPO_DIR\"
  "

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Test 6: Directory prefix in DO bullet — matches all files inside that dir
# ---------------------------------------------------------------------------
@test "DO directory prefix: lib/core/ covers any file inside lib/core/" {
  cd "$TEST_REPO_DIR"
  git checkout -q main
  git checkout -q -b feature/dir-prefix

  printf "# modified\n" > lib/core/foo.sh
  printf "# new file\n" > lib/core/bar.sh
  git add -A
  git commit -q -m "fix: add bar.sh to lib/core"
  git update-ref refs/remotes/origin/main refs/heads/main 2>/dev/null || true

  local body_file="${BATS_TEST_TMPDIR}/body6.txt"
  cat > "$body_file" <<'EOF'
## Scope Boundary:
- DO: lib/core/
EOF

  _run_scope_check_file "$body_file"

  [ "$status" -eq 0 ]
  [[ "$output" != *"VIOLATION:"* ]] || false
}

# ---------------------------------------------------------------------------
# Test 7: parse_scope_boundary correctly extracts DO and DO NOT patterns
# ---------------------------------------------------------------------------
@test "parse_scope_boundary: extracts DO and DO NOT patterns correctly" {
  local body_file="${BATS_TEST_TMPDIR}/body7.txt"
  cat > "$body_file" <<'EOF'
**Scope Boundary**:
- DO: scope-checker helper + dev-session prompt update
- DO: lib/core/claude-workflow.sh
- DO NOT: rewrite the issue-body parsing or scope-boundary format
- DO NOT: prevent Claude from EVER touching unlisted files
EOF

  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    parse_scope_boundary \"\$BODY\"
  "

  [ "$status" -eq 0 ]
  # DO patterns present
  [[ "$output" == *"lib/core/claude-workflow.sh"* ]]
  # DO NOT patterns present
  [[ "$output" == *"rewrite the issue-body parsing"* ]]
  # DO_PATTERNS_START/END sentinels present
  [[ "$output" == *"DO_PATTERNS_START"* ]]
  [[ "$output" == *"DONOT_PATTERNS_START"* ]]
}

# ---------------------------------------------------------------------------
# Test 8: Realistic PR #121 scenario
#   Issue scope: regex tweak in lint tool + its tests
#   Claude deletes tests/regression/empty-diff-after-fetch.bats (unrelated)
#   DO NOT bullet: touch unrelated tests
# ---------------------------------------------------------------------------
@test "PR-121 scenario: deleting empty-diff-after-fetch.bats is flagged as violation" {
  cd "$TEST_REPO_DIR"
  git checkout -q main

  # Add the file that Claude would delete
  printf "# empty diff after fetch test\n" > tests/regression/empty-diff-after-fetch.bats
  git add -A
  git commit -q -m "add empty-diff test"

  git checkout -q -b feature/issue-49-realistic

  # Simulate Claude's changes: lint tool, lint test, local-review, AND delete unrelated test
  mkdir -p tools tests/lint
  printf "# lint tool v2\n" > tools/sharkrite-lint.sh
  printf "# lint test\n" > tests/lint/custom-rules.bats
  printf "# local-review changes\n" > lib/core/local-review.sh
  rm -f tests/regression/empty-diff-after-fetch.bats
  git add -A
  git commit -q -m "fix: Rule 7 function detection regex (also deleted unrelated test)"
  git update-ref refs/remotes/origin/main refs/heads/main 2>/dev/null || true
  # origin/main should point at the commit BEFORE the feature branch diverged
  git update-ref refs/remotes/origin/main "$(git rev-parse main)" 2>/dev/null || true

  local body_file="${BATS_TEST_TMPDIR}/body8.txt"
  cat > "$body_file" <<'EOF'
**Scope Boundary**:
- DO: tweak the regex
- DO: tools/sharkrite-lint.sh
- DO: tests/lint/custom-rules.bats
- DO: lib/core/local-review.sh
- DO NOT: touch unrelated tests
EOF

  _run_scope_check_file "$body_file"

  # Should detect the deletion as a violation
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION:"* ]]
  [[ "$output" == *"empty-diff-after-fetch.bats"* ]]
}
