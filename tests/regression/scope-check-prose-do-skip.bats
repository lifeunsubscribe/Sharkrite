#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/scope-checker.sh

# Regression tests: scope-boundary false-positives on prose DO bullets
#
# Bug (2026-07-03 batch, issues #823/#833):
#   scope_boundary_is_enforceable returned 0 (enforceable) for issues whose
#   DO bullets were pure prose mixed with bare filename references like
#   "issue-lock.sh" (no directory prefix).  _is_path_shaped matched the
#   extension and declared the scope enforceable, causing check_scope_boundary
#   to flag every file not matching that bare filename as a violation.
#
# Fix:
#   scope_boundary_is_enforceable now requires a STRONG path token — a token
#   that is both path-shaped AND contains a slash (directory component).
#   Bare filenames in prose do not qualify.
#
# Acceptance criteria this file covers:
#   1. Issue #823's verbatim body → scope_boundary_is_enforceable returns 1
#      (non-enforceable), zero violations for its three Files-to-Modify.
#   2. Both section formats (**Scope Boundary**: and ## Scope Boundary) parse
#      identically — twin fixtures for the same DO content.
#   3. Files-to-Modify from Claude Context are unioned into the allowed set
#      when scope IS enforceable (declared intent can't be a violation).
#   4. Path-likes appearing only in DO NOT bullets do not make scope enforceable.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT
  SCOPE_CHECKER="$PROJECT_ROOT/lib/utils/scope-checker.sh"
  export SCOPE_CHECKER

  # Create a temp git repo with the three Files-to-Modify from issue #823
  TEST_REPO_DIR="${BATS_TEST_TMPDIR}/test-repo"
  export TEST_REPO_DIR
  mkdir -p "$TEST_REPO_DIR"

  cd "$TEST_REPO_DIR"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"

  # Baseline commit: stub out the files that issue #823 would modify
  mkdir -p lib/core tests/regression docs/architecture
  printf "# batch processor stub\n" > lib/core/batch-process-issues.sh
  printf "# exit codes doc stub\n" > docs/architecture/exit-codes.md
  git add -A
  git commit -q -m "initial commit"

  # Normalise branch name to 'main'
  _cur=$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD)
  if [ "$_cur" != "main" ]; then
    git branch -m "$_cur" main 2>/dev/null || true
  fi

  # Simulate origin/main at the baseline
  git update-ref refs/remotes/origin/main refs/heads/main 2>/dev/null || true

  # Feature branch: make changes to all three issue #823 Files-to-Modify
  git checkout -q -b feature/issue-823-test
  printf "# batch processor modified\n" > lib/core/batch-process-issues.sh
  printf "# exit 16 added\n" > docs/architecture/exit-codes.md
  printf "# new circuit breaker test\n" > tests/regression/batch-gate-circuit-breaker.bats
  git add -A
  git commit -q -m "feat: batch gate circuit breaker"
  git update-ref refs/remotes/origin/main refs/heads/main 2>/dev/null || true
  # origin/main must point at the commit BEFORE the feature branch diverged
  git update-ref refs/remotes/origin/main "$(git rev-parse main)" 2>/dev/null || true
}

teardown() {
  cd "$PROJECT_ROOT"
  rm -rf "$TEST_REPO_DIR"
}

# =============================================================================
# 1. Enforceability: issue #823 body → non-enforceable (prose-only DO)
#
# Issue #823 "Halt batch on repeated identical gate failures":
#   Files-to-Modify: lib/core/batch-process-issues.sh,
#                    tests/regression/batch-gate-circuit-breaker.bats,
#                    docs/architecture/exit-codes.md
#   Scope Boundary DO: pure prose, no path with slash.
#
# Issue #833 "Add repo-level batch mutex" (the direct trigger of the bug):
#   DO bullet: "reusing issue-lock.sh's mkdir/pid/kill-0 pattern"
#   "issue-lock.sh" has a .sh extension → old _is_path_shaped returned true →
#   scope_boundary_is_enforceable wrongly returned 0 (enforceable) → every
#   file not matching that bare filename was flagged as a violation.
# =============================================================================

@test "issue-823 body (prose DO): scope_boundary_is_enforceable returns non-enforceable" {
  # Verbatim Scope Boundary from issue #823 (bold-label format).
  # DO bullet is pure prose — no token with a slash.
  local body_file="${BATS_TEST_TMPDIR}/issue-823.txt"
  cat > "$body_file" <<'EOF'
## Description

Batch processing continued dispatching issues even when every gate failure
shared the same import-resolution signature, minting 56+ follow-up issues in
one day. Add a circuit breaker to halt the batch when N consecutive issues fail
with the same non-empty gate signature.

## Claude Context

Files to Read:
- lib/core/batch-process-issues.sh
- docs/architecture/exit-codes.md
- tests/regression/batch-gate-circuit-breaker.bats

Files to Modify:
- lib/core/batch-process-issues.sh
- tests/regression/batch-gate-circuit-breaker.bats
- docs/architecture/exit-codes.md

Related Issues: None

## Acceptance Criteria

- [ ] Batch halts with exit 16 after N consecutive identical gate signatures
- [ ] RITE_BATCH_GATE_TRIP=0 disables the breaker
- [ ] `make check` clean

## Done Definition

Done when 3 consecutive same-signature failures halt the batch with exit 16.

**Scope Boundary**:
- DO: circuit breaker implementation + gate signature extraction + exit code doc
- DO NOT: change single-issue mode failure behavior

**Dependencies**: None
EOF

  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    scope_boundary_is_enforceable \"\$BODY\"
  "

  # DO bullet is pure prose (no slash-bearing token) → non-enforceable
  [ "$status" -eq 1 ]
}

@test "issue-833 body (bare .sh in prose DO): scope_boundary_is_enforceable returns non-enforceable" {
  # Verbatim Scope Boundary from issue #833 — the direct trigger of the bug.
  # "issue-lock.sh" has a .sh extension, which old _is_path_shaped matched,
  # incorrectly making the scope "enforceable" and flagging every file not
  # matching that bare filename.
  local body_file="${BATS_TEST_TMPDIR}/issue-833.txt"
  cat > "$body_file" <<'EOF'
## Description

Add a repo-level batch mutex to batch-process-issues.sh so concurrent rite
batch invocations fail loudly instead of contending on shared state.

## Claude Context

Files to Read:
- lib/core/batch-process-issues.sh
- lib/utils/issue-lock.sh
- docs/architecture/exit-codes.md

Files to Modify:
- lib/core/batch-process-issues.sh
- lib/utils/issue-lock.sh
- docs/architecture/exit-codes.md

Related Issues: #823

## Acceptance Criteria

- [ ] Second rite batch invocation exits 17 immediately
- [ ] `make check` clean

## Done Definition

Done when concurrent batch invocations refuse instead of contending.

**Scope Boundary**:
- DO: repo-level mutex in the batch dispatcher, reusing issue-lock.sh's mkdir/pid/kill-0 pattern
- DO: distinct exit code + docs entry
- DO NOT: queueing/waiting semantics (refuse-only)
- DO NOT: touch per-issue locks or the ps-scrape filter

**Dependencies**: None
EOF

  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    scope_boundary_is_enforceable \"\$BODY\"
  "

  # "issue-lock.sh" is a bare filename (no slash) → NOT a strong path token →
  # scope_boundary_is_enforceable must return 1 (NOT enforceable)
  [ "$status" -eq 1 ]
}

@test "issue-823 body: zero scope violations for its three declared files" {
  # When scope_boundary_is_enforceable returns non-enforceable, the caller
  # (claude-workflow.sh) skips check_scope_boundary entirely.  Verify that
  # check_scope_boundary also does not produce violations for the issue #823
  # file set when DO bullets are prose-only (relies on the same predicate fix).
  # We test this directly to confirm the check returns clean.
  local body_file="${BATS_TEST_TMPDIR}/issue-823-zero-violations.txt"
  cat > "$body_file" <<'EOF'
**Scope Boundary**:
- DO: circuit breaker implementation + gate signature extraction + exit code doc
- DO NOT: change single-issue mode failure behavior
EOF

  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    check_scope_boundary \"\$BODY\" \"$TEST_REPO_DIR\"
  "

  # No violations: prose-only DO bullets → no path can match → the check
  # produces zero violations (empty output, exit 0).
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =============================================================================
# 2. Both section formats produce identical behaviour
# =============================================================================

@test "bold-label format (**Scope Boundary**:): prose-only DO is non-enforceable" {
  local body_file="${BATS_TEST_TMPDIR}/bold-label.txt"
  cat > "$body_file" <<'EOF'
**Scope Boundary**:
- DO: circuit breaker implementation + gate signature extraction + exit code doc
- DO NOT: change single-issue mode failure behavior
EOF

  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    scope_boundary_is_enforceable \"\$BODY\"
  "

  [ "$status" -eq 1 ]
}

@test "heading format (## Scope Boundary): prose-only DO is non-enforceable" {
  local body_file="${BATS_TEST_TMPDIR}/heading-format.txt"
  cat > "$body_file" <<'EOF'
## Scope Boundary
- DO: circuit breaker implementation + gate signature extraction + exit code doc
- DO NOT: change single-issue mode failure behavior
EOF

  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    scope_boundary_is_enforceable \"\$BODY\"
  "

  [ "$status" -eq 1 ]
}

@test "both formats: parse_scope_boundary extracts identical DO patterns" {
  # Confirm the section anchor change does not affect which patterns are parsed.
  local bold_file="${BATS_TEST_TMPDIR}/bold.txt"
  local heading_file="${BATS_TEST_TMPDIR}/heading.txt"

  cat > "$bold_file" <<'EOF'
**Scope Boundary**:
- DO: circuit breaker implementation + exit code doc
- DO NOT: change single-issue mode failure behavior
EOF

  cat > "$heading_file" <<'EOF'
## Scope Boundary
- DO: circuit breaker implementation + exit code doc
- DO NOT: change single-issue mode failure behavior
EOF

  local bold_out heading_out
  bold_out=$(bash -c "source \"$SCOPE_CHECKER\"; BODY=\$(cat \"$bold_file\"); parse_scope_boundary \"\$BODY\"")
  heading_out=$(bash -c "source \"$SCOPE_CHECKER\"; BODY=\$(cat \"$heading_file\"); parse_scope_boundary \"\$BODY\"")

  # Both forms must produce the same parsed output
  [ "$bold_out" = "$heading_out" ]
  # The DO pattern text must be present in both
  [[ "$bold_out" == *"circuit breaker implementation"* ]]
  [[ "$heading_out" == *"circuit breaker implementation"* ]]
}

# =============================================================================
# 3. Files-to-Modify union: declared modification intent cannot be a violation
# =============================================================================

@test "files-to-modify union: declared files are not violations when scope is enforceable" {
  # When scope IS enforceable (DO has a real path), files listed under
  # "Files to Modify:" in Claude Context are unioned into the allowed set.
  # This means they cannot be flagged even if the DO bullet only covers
  # a different path prefix.
  #
  # Scenario: DO only declares "lib/utils/" but the issue also lists
  # lib/core/batch-process-issues.sh and docs/architecture/exit-codes.md
  # under Files to Modify.  Those must NOT be violations.
  local body_file="${BATS_TEST_TMPDIR}/ftm-union.txt"
  cat > "$body_file" <<'EOF'
## Claude Context

Files to Read:
- lib/core/batch-process-issues.sh

Files to Modify:
- lib/core/batch-process-issues.sh
- docs/architecture/exit-codes.md

## Scope Boundary

- DO: lib/utils/issue-lock.sh
- DO NOT: touch per-issue lock internals
EOF

  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    check_scope_boundary \"\$BODY\" \"$TEST_REPO_DIR\"
  "

  # lib/core/batch-process-issues.sh and docs/architecture/exit-codes.md are
  # in Files-to-Modify → unioned into allowed set → no violations.
  # tests/regression/batch-gate-circuit-breaker.bats is an added test file →
  # implicitly whitelisted by the test-path check.
  [ "$status" -eq 0 ]
  [[ "$output" != *"VIOLATION:"* ]] || false
}

@test "files-to-modify union: parse_files_to_modify extracts correct paths" {
  local body_file="${BATS_TEST_TMPDIR}/ftm-parse.txt"
  cat > "$body_file" <<'EOF'
## Claude Context

Files to Read:
- lib/core/foo.sh

Files to Modify:
- lib/core/batch-process-issues.sh
- tests/regression/batch-gate-circuit-breaker.bats
- docs/architecture/exit-codes.md

Related Issues: None
EOF

  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    parse_files_to_modify \"\$BODY\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"lib/core/batch-process-issues.sh"* ]]
  [[ "$output" == *"tests/regression/batch-gate-circuit-breaker.bats"* ]]
  [[ "$output" == *"docs/architecture/exit-codes.md"* ]]
  # Files-to-Read entries must NOT appear in the output
  [[ "$output" != *"lib/core/foo.sh"* ]] || false
}

# =============================================================================
# 4. Path-likes in DO NOT only do not make scope enforceable
# =============================================================================

@test "path-likes in DO NOT only: scope is non-enforceable" {
  # A DO NOT bullet may contain path-shaped tokens (lib/core/secret.sh).
  # Only DO bullets are considered when computing enforceability.
  # If all DO bullets are prose and only DO NOT has paths → non-enforceable.
  local body_file="${BATS_TEST_TMPDIR}/donot-paths-only.txt"
  cat > "$body_file" <<'EOF'
## Scope Boundary
- DO: address the review findings above
- DO NOT: lib/core/secret.sh
- DO NOT: lib/utils/auth.sh
EOF

  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    scope_boundary_is_enforceable \"\$BODY\"
  "

  # DO bullets are prose-only → non-enforceable, even though DO NOT has paths
  [ "$status" -eq 1 ]
}

# =============================================================================
# 5. Bare filename in DO bullet (the direct trigger of the false positive)
# =============================================================================

@test "bare .sh filename in DO prose: non-enforceable (old code triggered false positive here)" {
  # This is the exact pattern from issue #833 that triggered the false positive:
  # "DO: repo-level mutex in the batch dispatcher, reusing issue-lock.sh's pattern"
  # issue-lock.sh has a .sh extension → old _is_path_shaped returned true →
  # scope_boundary_is_enforceable returned 0 (enforceable) → every file not
  # matching "issue-lock.sh" was flagged.
  local body_file="${BATS_TEST_TMPDIR}/bare-sh-prose.txt"
  cat > "$body_file" <<'EOF'
**Scope Boundary**:
- DO: repo-level mutex in the batch dispatcher, reusing issue-lock.sh's mkdir/pid/kill-0 pattern
- DO: distinct exit code + docs entry
- DO NOT: queueing/waiting semantics (refuse-only)
- DO NOT: touch per-issue locks or the ps-scrape filter
EOF

  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    scope_boundary_is_enforceable \"\$BODY\"
  "

  # The fix: bare "issue-lock.sh" (no slash) is NOT a strong path token →
  # scope_boundary_is_enforceable returns 1 (NOT enforceable).
  [ "$status" -eq 1 ]
}

@test "bare .bats filename in DO prose: non-enforceable" {
  local body_file="${BATS_TEST_TMPDIR}/bare-bats-prose.txt"
  cat > "$body_file" <<'EOF'
## Scope Boundary
- DO: add batch-gate-circuit-breaker.bats covering the new helper
- DO NOT: change existing bats tests
EOF

  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    scope_boundary_is_enforceable \"\$BODY\"
  "

  # "batch-gate-circuit-breaker.bats" without a slash is prose-only → non-enforceable
  [ "$status" -eq 1 ]
}

# =============================================================================
# 6. Paths with slashes in DO bullets remain enforceable (regression guard)
# =============================================================================

@test "path with slash in DO: scope remains enforceable (regression guard)" {
  # Ensure the fix does NOT break cases where DO bullets have real paths.
  local body_file="${BATS_TEST_TMPDIR}/real-path-do.txt"
  cat > "$body_file" <<'EOF'
**Scope Boundary**:
- DO: lib/core/batch-process-issues.sh
- DO: docs/architecture/exit-codes.md
- DO NOT: change single-issue mode
EOF

  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    scope_boundary_is_enforceable \"\$BODY\"
  "

  # Real paths (with slashes) → enforceable
  [ "$status" -eq 0 ]
}

@test "prose with embedded slash-path: scope remains enforceable (regression guard)" {
  # "DO: tweak the regex in lib/core/foo.sh" — lib/core/foo.sh has a slash →
  # the bullet is enforceable even though it's embedded in prose.
  local body_file="${BATS_TEST_TMPDIR}/prose-slash-path.txt"
  cat > "$body_file" <<'EOF'
## Scope Boundary
- DO: tweak the regex in lib/core/foo.sh
- DO NOT: touch unrelated tests
EOF

  run bash -c "
    source \"$SCOPE_CHECKER\"
    BODY=\$(cat \"$body_file\")
    scope_boundary_is_enforceable \"\$BODY\"
  "

  # lib/core/foo.sh has a slash → strong path token → enforceable
  [ "$status" -eq 0 ]
}

# =============================================================================
# 7. _is_strong_path_token helper unit tests
# =============================================================================

@test "_is_strong_path_token: paths with slashes are strong" {
  run bash -c "
    source \"$SCOPE_CHECKER\"
    _is_strong_path_token 'lib/core/foo.sh'    || { echo 'FAIL lib/core/foo.sh'; exit 1; }
    _is_strong_path_token 'lib/core/'          || { echo 'FAIL lib/core/'; exit 1; }
    _is_strong_path_token 'lib/core/*.sh'      || { echo 'FAIL lib/core/*.sh'; exit 1; }
    _is_strong_path_token 'tests/regression/'  || { echo 'FAIL tests/regression/'; exit 1; }
    echo 'all_strong'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"all_strong"* ]]
}

@test "_is_strong_path_token: bare filenames without slash are not strong" {
  run bash -c "
    source \"$SCOPE_CHECKER\"
    _is_strong_path_token 'issue-lock.sh'              && { echo 'FAIL issue-lock.sh'; exit 1; }
    _is_strong_path_token 'foo.bats'                   && { echo 'FAIL foo.bats'; exit 1; }
    _is_strong_path_token 'batch-gate-circuit-breaker.bats' && { echo 'FAIL bats file'; exit 1; }
    _is_strong_path_token 'config.sh'                  && { echo 'FAIL config.sh'; exit 1; }
    echo 'none_strong'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"none_strong"* ]]
}

@test "_is_strong_path_token: pure prose words are not strong" {
  run bash -c "
    source \"$SCOPE_CHECKER\"
    _is_strong_path_token 'circuit'      && { echo 'FAIL circuit'; exit 1; }
    _is_strong_path_token 'breaker'      && { echo 'FAIL breaker'; exit 1; }
    _is_strong_path_token 'implementation' && { echo 'FAIL implementation'; exit 1; }
    _is_strong_path_token '*'            && { echo 'FAIL *'; exit 1; }
    echo 'none_strong'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"none_strong"* ]]
}
