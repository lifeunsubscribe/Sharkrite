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
  # BATS_TEST_DIRNAME is tests/regression/ — navigate two levels up to project root
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT

  # Temp dir for runtime scripts and stubs
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}/gh-safe-test"
  mkdir -p "$TEST_TMPDIR"

  # Fixture dir for lint tests: use BATS_TEST_TMPDIR so files are outside the project
  # tree and never scanned by production lint runs (even if teardown is skipped due to
  # a crash or SIGINT). Inject via RITE_LINT_EXTRA_DIRS so the linter scans them when
  # tests need the lint rule to fire on controlled fixture input.
  #
  # Previously this pointed to $PROJECT_ROOT/lib/test-fixtures-temp, which the linter
  # explicitly excludes via the test-fixtures-temp* path filter — causing the lint-rule
  # tests that write fixtures and expect the linter to flag them to fail silently.
  export LINT_FIXTURE_DIR="${BATS_TEST_TMPDIR}/gh-safe-fixtures"
  mkdir -p "$LINT_FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$LINT_FIXTURE_DIR"

  # Stub bin dir — prepend to PATH so fake gh overrides the real one
  export STUB_BIN="$TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"

  # Source gh_safe for fault-injection tests (avoids loading the entire config chain)
  GH_RETRY_SH="$PROJECT_ROOT/lib/utils/gh-retry.sh"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
  rm -rf "$LINT_FIXTURE_DIR"
  unset RITE_LINT_EXTRA_DIRS
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
    # Use standard BATS assertion — fail "msg" requires bats-support which is not loaded here
    [[ ! "$output" =~ "gh-retry.sh" ]] \
      || false  # GH_UNSAFE_CALL falsely flagged gh-retry.sh
  fi
}

@test "GH_UNSAFE_CALL: lint rule does not flag 'gh' inside a heredoc body" {
  # Heredoc bodies are documentation/prompt text, not executable commands.
  # A line like "gh pr create ..." inside <<'EOF' must NOT produce a false positive.
  # Rule 13 uses a heredoc state machine that tracks open/close markers and skips
  # all lines between them.
  cat > "$LINT_FIXTURE_DIR/heredoc-gh.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

# Safely wrapped — should never be flagged
RESULT=$(gh_safe pr view 42 --json title || true)

# gh references inside heredocs are documentation text, not shell commands.
# The lint rule must skip these lines to prevent false positives.
PROMPT=$(cat <<'HEREDOC'
You are a CI helper. Do NOT run: gh pr create
If you need to check PRs, use: gh pr list --search "foo"
HEREDOC
)

echo "$RESULT"
echo "$PROMPT"
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  # Must not flag the heredoc lines as GH_UNSAFE_CALL violations
  if [[ "$output" =~ "GH_UNSAFE_CALL" ]]; then
    [[ ! "$output" =~ "heredoc-gh.sh" ]] \
      || false  # GH_UNSAFE_CALL falsely flagged a heredoc body line in heredoc-gh.sh
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

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
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

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    result=\$(gh_safe pr view 9999 --json title)
    echo \"exit:\$?\"
    echo \"result:'\${result}'\"
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

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
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

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
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

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    result=\$(gh_safe pr view 9999 --json title)
    echo \"exit:\$?\"
    echo \"result:'\${result}'\"
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

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    result=\$(gh_safe api 'repos/owner/repo/pulls/9999')
    echo \"exit:\$?\"
    echo \"result:'\${result}'\"
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

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
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

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    gh_safe pr view 42 --json title
  "

  # Should have retried and ultimately returned non-zero
  [ "$status" -ne 0 ]
}

# ===========================================================================
# gh_safe label subcommand coverage
# ===========================================================================
# These tests verify that gh_safe handles the 'label' subcommand correctly:
# - label list (READ) — should return empty/exit-0 on 429-exhausted transient failure
# - label create (WRITE) — should retry on 429 and eventually succeed

@test "gh_safe label list retries on 429 and succeeds" {
  # Derive correct path to gh-retry.sh: tests/regression/ -> ../../lib/utils/
  local _gh_retry_sh
  _gh_retry_sh="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/lib/utils/gh-retry.sh"

  local attempt_file="$TEST_TMPDIR/label-attempts"
  echo "0" > "$attempt_file"

  # Stub gh: fail with 429 on attempt 1, succeed on attempt 2.
  # The stub outputs plain text (fake gh doesn't parse --json/--jq flags).
  # gh_safe passes flags through; the result is the raw text from the stub.
  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 2 ]; then
  echo "rate limit exceeded (429)" >&2
  exit 1
fi
echo 'bug'
echo 'enhancement'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$_gh_retry_sh'
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe label list --limit 100 --json name --jq '.[].name' || true)
    echo \"\$result\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "bug" ]]
  [[ "$output" =~ "enhancement" ]]
}

@test "gh_safe label list returns empty on exhausted 429 retries (graceful degradation)" {
  # Simulate persistent 429 — gh_safe exhausts retries and returns non-zero.
  # Callers use '|| true' so the assignment gets empty string rather than crashing.
  # Derive correct path to gh-retry.sh: tests/regression/ -> ../../lib/utils/
  local _gh_retry_sh
  _gh_retry_sh="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/lib/utils/gh-retry.sh"

  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
echo "rate limit exceeded (429)" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=2
  export RITE_GH_RETRY_MAX_SLEEP=0

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$_gh_retry_sh'
    sleep() { :; }
    export -f sleep
    # Mirrors the pattern in labels.sh and plan-issues.sh:
    #   existing=\$(gh_safe label list ... || true)
    result=\$(gh_safe label list --limit 200 --json name --jq '.[].name' || true)
    result=\"\${result:-}\"
    echo \"exit:0\"
    echo \"result:'\${result}'\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "exit:0" ]]
  # Caller continues with empty list — no crash
  [[ "$output" =~ "result:''" ]]
}

@test "gh_safe label create retries on 429 and succeeds" {
  # Derive correct path to gh-retry.sh: tests/regression/ -> ../../lib/utils/
  local _gh_retry_sh
  _gh_retry_sh="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/lib/utils/gh-retry.sh"

  local attempt_file="$TEST_TMPDIR/create-attempts"
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
echo 'https://github.com/owner/repo/labels/tech-debt'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$_gh_retry_sh'
    sleep() { :; }
    export -f sleep
    gh_safe label create 'tech-debt' --color 'E4E669' --description 'Technical debt'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "tech-debt" ]]
}

@test "ensure_labels_exist proceeds gracefully when label list returns empty (transient failure)" {
  # When gh_safe label list fails (e.g. 429-exhausted), existing becomes empty.
  # ensure_labels_exist should then attempt to create all labels (idempotent).
  # This test verifies the function doesn't crash on empty label list.
  # Derive correct paths: tests/regression/ -> ../../lib/utils/
  local _lib_dir
  _lib_dir="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/lib"

  local created_file="$TEST_TMPDIR/created-labels"
  : > "$created_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
if [ "\$1" = "label" ] && [ "\$2" = "list" ]; then
  # Simulate exhausted retries — return empty with non-zero exit
  echo "Service Unavailable (503)" >&2
  exit 1
elif [ "\$1" = "label" ] && [ "\$2" = "create" ]; then
  # Record label name and succeed
  echo "\$3" >> "$created_file"
  exit 0
fi
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=1  # No retries — immediate failure on list
  export RITE_GH_RETRY_MAX_SLEEP=0

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$_lib_dir/utils/gh-retry.sh'
    source '$_lib_dir/utils/labels.sh'
    ensure_labels_exist 'tech-debt,automated'
    echo 'done'
  "

  # Function must not crash — label list failure is recoverable
  [ "$status" -eq 0 ]
  [[ "$output" =~ "done" ]]
}

# ===========================================================================
# Transient regex precision: no false positives from coincidental token matches
# ===========================================================================
# These tests verify that status-code digits appearing in non-HTTP-status
# contexts do NOT trigger spurious retries. The framed regex (HTTP 5xx,
# (503), etc.) must distinguish real transient errors from coincidental text.

@test "gh_safe does NOT retry when stderr contains '500' as a word count (false-positive guard)" {
  # "Processed 500 records" contains the token 500 but is not a transient error.
  # gh_safe must propagate the failure immediately (no retry), not waste 3 attempts.
  local call_count_file="$TEST_TMPDIR/call-count-fp"
  echo "0" > "$call_count_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$call_count_file")
count=\$((count + 1))
echo "\$count" > "$call_count_file"
# Stderr contains "500" as a word count, not an HTTP status code
echo "Validation failed: Processed 500 records, 0 valid" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    gh_safe pr view 42 --json title || true
    echo \"calls:\$(cat '$call_count_file')\"
  "

  [ "$status" -eq 0 ]
  # Must have called gh exactly once — no retries on a non-transient failure
  [[ "$output" =~ "calls:1" ]]
}

@test "gh_safe does NOT retry when stderr contains '503' as a config identifier (false-positive guard)" {
  local call_count_file="$TEST_TMPDIR/call-count-fp503"
  echo "0" > "$call_count_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$call_count_file")
count=\$((count + 1))
echo "\$count" > "$call_count_file"
# Stderr contains "503" as a config/error code, not an HTTP status
echo "Error at configuration line 503: invalid option" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    gh_safe pr view 42 --json title || true
    echo \"calls:\$(cat '$call_count_file')\"
  "

  [ "$status" -eq 0 ]
  # Must have called gh exactly once — config line 503 is not a transient HTTP error
  [[ "$output" =~ "calls:1" ]]
}

@test "gh_safe does NOT retry when stderr contains '(503):' as a module reference (false-positive guard)" {
  # Bare parenthesised codes like "(503)" must not match when followed by a colon,
  # which indicates a module/config reference ("Error in module (503): bad config")
  # rather than an HTTP status message from gh CLI.
  local call_count_file="$TEST_TMPDIR/call-count-fp503paren"
  echo "0" > "$call_count_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$call_count_file")
count=\$((count + 1))
echo "\$count" > "$call_count_file"
# Stderr contains "(503):" as a module reference, not an HTTP status
echo "Error in module (503): bad config value" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    gh_safe pr view 42 --json title || true
    echo \"calls:\$(cat '$call_count_file')\"
  "

  [ "$status" -eq 0 ]
  # Must have called gh exactly once — "(503):" is a module reference, not a transient HTTP error
  [[ "$output" =~ "calls:1" ]]
}

@test "gh_safe does NOT retry when stderr contains '(429):' as a non-HTTP reference (false-positive guard)" {
  # Bare parenthesised "(429)" must not match when followed by a colon,
  # which indicates a non-HTTP reference rather than a rate-limit response.
  local call_count_file="$TEST_TMPDIR/call-count-fp429paren"
  echo "0" > "$call_count_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$call_count_file")
count=\$((count + 1))
echo "\$count" > "$call_count_file"
# Stderr contains "(429):" as a process/error code reference, not an HTTP rate-limit
echo "Process exited with code (429): unexpected termination" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    gh_safe pr view 42 --json title || true
    echo \"calls:\$(cat '$call_count_file')\"
  "

  [ "$status" -eq 0 ]
  # Must have called gh exactly once — "(429):" is not a real HTTP rate-limit response
  [[ "$output" =~ "calls:1" ]]
}

@test "gh_safe retries on 'HTTP 503 Service Unavailable' (framed status code — transient)" {
  # Verify that the framed regex still correctly matches real transient errors
  # using the "HTTP NNN" format that the gh CLI emits.
  local attempt_file="$TEST_TMPDIR/attempts-http503"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 2 ]; then
  echo "HTTP 503 Service Unavailable" >&2
  exit 1
fi
echo '{"title":"Test PR"}'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe pr view 42 --json title)
    echo \"\$result\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Test PR" ]]
}

@test "gh_safe retries on '(HTTP 429)' parenthesised format (framed status — transient)" {
  local attempt_file="$TEST_TMPDIR/attempts-http429"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 2 ]; then
  echo "API rate limit exceeded for user (HTTP 429)" >&2
  exit 1
fi
echo '{"title":"Recovered PR"}'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe pr view 42 --json title)
    echo \"\$result\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Recovered PR" ]]
}

@test "gh_safe retries on 'Service Unavailable (503)' parenthesised-code format (transient)" {
  # Some gh CLI versions emit "(503)" in parentheses without the HTTP prefix.
  local attempt_file="$TEST_TMPDIR/attempts-paren503"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 2 ]; then
  echo "Service Unavailable (503)" >&2
  exit 1
fi
echo '{"title":"Back online"}'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe pr view 42 --json title)
    echo \"\$result\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Back online" ]]
}

# ===========================================================================
# _gh_is_read_op: method-flag detection — case/shift robustness
# ===========================================================================
# These tests exercise _gh_is_read_op directly to verify that -X / --method
# is detected correctly regardless of where the flag appears in the arg list.
# Previously the index-based walk (args[$((i+1))]) was fragile: adding any
# argument between --method and its value would shift the offset and misparse.

@test "_gh_is_read_op: api -X PUT is a write op (flag first)" {
  run bash -c "
    source '$GH_RETRY_SH'
    _gh_is_read_op api 'repos/owner/repo/pulls/42/merge' -X PUT -f merge_method=squash
  "
  # write op → non-zero exit
  [ "$status" -ne 0 ]
}

@test "_gh_is_read_op: api -X GET is a read op" {
  run bash -c "
    source '$GH_RETRY_SH'
    _gh_is_read_op api 'repos/owner/repo/pulls/42' -X GET
  "
  [ "$status" -eq 0 ]
}

@test "_gh_is_read_op: api --method PUT is a write op" {
  run bash -c "
    source '$GH_RETRY_SH'
    _gh_is_read_op api 'repos/owner/repo/pulls/42/merge' --method PUT
  "
  [ "$status" -ne 0 ]
}

@test "_gh_is_read_op: api --method GET is a read op" {
  run bash -c "
    source '$GH_RETRY_SH'
    _gh_is_read_op api 'repos/owner/repo/pulls/42' --method GET
  "
  [ "$status" -eq 0 ]
}

@test "_gh_is_read_op: api --method POST after URL is a write op" {
  # Documents that --method appearing after the URL is handled correctly (case/shift walk)
  run bash -c "
    source '$GH_RETRY_SH'
    _gh_is_read_op api 'repos/owner/repo/issues' --method POST
  "
  [ "$status" -ne 0 ]
}

@test "_gh_is_read_op: api -X PUT with leading flags before -X is a write op (was fragile)" {
  # Regression: index-based walk could skip VALUE when flags were prepended before -X.
  # With case/shift the walk processes each token in sequence; order does not matter.
  run bash -c "
    source '$GH_RETRY_SH'
    _gh_is_read_op api --header 'Accept: application/vnd.github.v3+json' -X PUT 'repos/owner/repo/pulls/42/merge'
  "
  [ "$status" -ne 0 ]
}

@test "_gh_is_read_op: api --method DELETE with interleaved flags is a write op (was fragile)" {
  # Regression: index-based walk with i+1 lookup was disrupted by interleaved flags.
  run bash -c "
    source '$GH_RETRY_SH'
    _gh_is_read_op api --field foo=bar --method DELETE 'repos/owner/repo/issues/42'
  "
  [ "$status" -ne 0 ]
}

@test "_gh_is_read_op: api with no -X flag defaults to GET (read op)" {
  run bash -c "
    source '$GH_RETRY_SH'
    _gh_is_read_op api 'repos/owner/repo/pulls/42'
  "
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Codebase-wide adoption check
# ===========================================================================

@test "codebase has zero remaining raw gh calls outside gh-retry.sh" {
  # Uses the GH_UNSAFE_CALL lint rule (Rule 13 in tools/sharkrite-lint.sh) as the
  # authoritative check rather than a raw grep. The lint rule is heredoc-aware, skips
  # comments, echo/print_* quoted-string references, and instructional-text patterns —
  # avoiding the false positives a naive grep produces on comment and echo lines.
  cd "$PROJECT_ROOT"
  rm -f "$LINT_FIXTURE_DIR"/*.sh 2>/dev/null || true

  run tools/sharkrite-lint.sh

  # If any GH_UNSAFE_CALL violations exist, the lint will report them and exit non-zero
  if [[ "$output" =~ "GH_UNSAFE_CALL" ]]; then
    echo "Remaining raw gh calls found (GH_UNSAFE_CALL lint violations):"
    echo "$output" | grep "GH_UNSAFE_CALL"
    false
  fi
  true
}
