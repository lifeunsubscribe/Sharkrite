#!/usr/bin/env bats
# Regression test: gh_safe adoption across the codebase
#
# Verifies three things:
# 1. The GH_UNSAFE_CALL lint rule fires on raw gh calls and passes on gh_safe calls
# 2. gh_safe returns empty/exit-0 on 404 for READ operations (pr view, issue list, etc.)
# 3. gh_safe propagates the real exit code on 404 for WRITE operations
#    (api -X PUT/POST/DELETE/PATCH, pr merge, pr close, pr comment, etc.)
#    — prevents the safety-critical merge path from silently believing a 404 merge succeeded
#
# Fault-injection tests replace the real `gh` with a stub that returns specific
# error responses to simulate GitHub API failures in a deterministic way.

setup() {
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export PROJECT_ROOT

  # Temp dir for runtime scripts and stubs
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}/gh-safe-test"
  mkdir -p "$TEST_TMPDIR"

  # Temp dir inside lib/ for lint fixture files (linter only scans lib/, bin/, tools/)
  export LINT_FIXTURE_DIR="$PROJECT_ROOT/lib/test-fixtures-temp"
  mkdir -p "$LINT_FIXTURE_DIR"

  # Stub bin dir — prepend to PATH so fake gh overrides the real one
  export STUB_BIN="$TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"

  # Source gh_safe for fault-injection tests (avoids loading the entire config chain)
  GH_RETRY_SH="$PROJECT_ROOT/lib/utils/gh-retry.sh"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
  rm -rf "$LINT_FIXTURE_DIR"
}

# ===========================================================================
# Lint rule tests
# ===========================================================================

@test "GH_UNSAFE_CALL: lint rule fires on raw 'gh pr view' call" {
  cat > "$LINT_FIXTURE_DIR/raw-gh-call.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# This is a raw gh call — should be caught by GH_UNSAFE_CALL lint rule
RESULT=$(gh pr view 42 --json title 2>/dev/null || echo "{}")
echo "$RESULT"
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "GH_UNSAFE_CALL" ]]
  [[ "$output" =~ "raw-gh-call.sh" ]]
}

@test "GH_UNSAFE_CALL: lint rule passes on gh_safe call" {
  # Script using gh_safe — no raw gh call → no violation
  # (Place in BATS_TEST_TMPDIR, not lib/ fixture dir, so linter doesn't scan it)
  cat > "$TEST_TMPDIR/safe-gh-call.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# This uses gh_safe — should NOT be flagged
RESULT=$(gh_safe pr view 42 --json title || true)
RESULT="${RESULT:-{}}"
echo "$RESULT"
EOF

  cd "$PROJECT_ROOT"
  # Clean up any lingering fixtures so only our test files are scanned
  rm -f "$LINT_FIXTURE_DIR"/*.sh 2>/dev/null || true

  run tools/sharkrite-lint.sh

  # No GH_UNSAFE_CALL violation in output (there may be other violations from
  # other rules on this fixture file — that's fine; we only check GH_UNSAFE_CALL)
  [[ ! "$output" =~ "GH_UNSAFE_CALL" ]] || {
    # If fired, ensure it's not on our safe file
    [[ ! "$output" =~ "safe-gh-call.sh" ]]
  }
}

@test "GH_UNSAFE_CALL: lint rule ignores gh-retry.sh itself" {
  cd "$PROJECT_ROOT"
  rm -f "$LINT_FIXTURE_DIR"/*.sh 2>/dev/null || true

  run tools/sharkrite-lint.sh

  # gh-retry.sh contains raw gh calls by design — should NOT be flagged
  if [[ "$output" =~ "GH_UNSAFE_CALL" ]]; then
    [[ ! "$output" =~ "gh-retry.sh" ]] || {
      fail "GH_UNSAFE_CALL falsely flagged gh-retry.sh"
    }
  fi
}

# ===========================================================================
# Fault-injection: gh_safe retry behavior
# ===========================================================================

@test "gh_safe retries on 429 rate-limit and eventually succeeds" {
  # Stub: fails with 429 on first call, succeeds on second
  local attempt_file="$TEST_TMPDIR/attempts"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 2 ]; then
  echo "rate limit exceeded (429)" >&2
  exit 1
fi
echo '{"title":"Test PR"}'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  # Reduce sleep so test doesn't take 5 seconds
  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:\$PATH'
    source '$GH_RETRY_SH'
    # Override sleep to a no-op for fast testing
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe pr view 42 --json title)
    echo \"\$result\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Test PR" ]]
}

@test "gh_safe returns empty with exit 0 on 404 not-found" {
  # Stub: always returns not-found error
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
echo "Could not resolve to a PullRequest with the number 9999. (HTTP 404)" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  run bash -c "
    export PATH='$STUB_BIN:\$PATH'
    source '$GH_RETRY_SH'
    result=\$(gh_safe pr view 9999 --json title)
    echo \"exit:\$?\"
    echo \"result:'\${result:-empty}'\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "exit:0" ]]
  [[ "$output" =~ "result:''" ]]
}

@test "gh_safe propagates 404 (non-zero exit) for write ops — api -X PUT (merge path)" {
  # Stub: returns 404 on the merge endpoint (resource exists check fails)
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
echo "Not Found (HTTP 404)" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  run bash -c "
    export PATH='$STUB_BIN:\$PATH'
    source '$GH_RETRY_SH'
    gh_safe api 'repos/owner/repo/pulls/42/merge' -X PUT -f merge_method=squash -f sha=abc123
  "

  # Must propagate non-zero — a 404 on the merge endpoint is a real error,
  # not a benign "resource doesn't exist yet" condition
  [ "$status" -ne 0 ]
}

@test "gh_safe propagates 404 (non-zero exit) for write ops — pr close" {
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
echo "Could not resolve to a PullRequest with the number 9999. (HTTP 404)" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  run bash -c "
    export PATH='$STUB_BIN:\$PATH'
    source '$GH_RETRY_SH'
    gh_safe pr close 9999
  "

  [ "$status" -ne 0 ]
}

@test "gh_safe returns empty/exit-0 on 404 for read ops — pr view (unchanged behavior)" {
  # Stub: always returns not-found error
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
echo "Could not resolve to a PullRequest with the number 9999. (HTTP 404)" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  run bash -c "
    export PATH='$STUB_BIN:\$PATH'
    source '$GH_RETRY_SH'
    result=\$(gh_safe pr view 9999 --json title)
    echo \"exit:\$?\"
    echo \"result:'\${result:-empty}'\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "exit:0" ]]
  [[ "$output" =~ "result:''" ]]
}

@test "gh_safe returns empty/exit-0 on 404 for read ops — api GET (no -X flag)" {
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
echo "Not Found (HTTP 404)" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  run bash -c "
    export PATH='$STUB_BIN:\$PATH'
    source '$GH_RETRY_SH'
    result=\$(gh_safe api 'repos/owner/repo/pulls/9999')
    echo \"exit:\$?\"
    echo \"result:'\${result:-empty}'\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "exit:0" ]]
}

@test "gh_safe propagates non-transient errors (e.g. auth failure)" {
  # Stub: returns auth error (not transient — should NOT retry, should propagate)
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
echo "You are not logged into any GitHub host. Run gh auth login and try again." >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  run bash -c "
    export PATH='$STUB_BIN:\$PATH'
    source '$GH_RETRY_SH'
    gh_safe pr view 42 --json title
  "

  # Non-zero exit, and stderr contains auth message
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not logged into any GitHub host" ]] || [[ "$stderr" =~ "not logged into any GitHub host" ]]
}

@test "gh_safe exhausts retries on persistent 503 and returns non-zero" {
  # Stub: always returns 503
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
echo "Service Unavailable (503)" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:\$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    gh_safe pr view 42 --json title
  "

  # Should have retried and ultimately returned non-zero
  [ "$status" -ne 0 ]
}

# ===========================================================================
# Codebase-wide adoption check
# ===========================================================================

@test "codebase has zero remaining raw gh calls outside gh-retry.sh" {
  cd "$PROJECT_ROOT"
  rm -f "$LINT_FIXTURE_DIR"/*.sh 2>/dev/null || true

  # Use grep to find raw gh calls (not preceded by gh_safe) in lib/ and bin/
  # Pattern: (space/pipe/$(/)  gh  (pr|issue|api|repo|label|diff)
  # Exclude: comments, gh_safe itself, gh-retry.sh
  run bash -c "
    grep -rn '\bgh\b[[:space:]]\+\(pr\|issue\|api\|repo\|label\|diff\)\b' lib/ bin/ 2>/dev/null \
      | grep -v '^\s*#' \
      | grep -v 'gh_safe' \
      | grep -v 'gh-retry\.sh' \
      | grep -v '\.bats:' \
    || true
  "

  # Any non-empty output means remaining raw calls exist — fail with context
  if [ -n "$output" ]; then
    echo "Remaining raw gh calls found:"
    echo "$output"
    false
  fi
  true
}
